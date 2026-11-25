import CoreLocation
import FogOfWorldKit
import Foundation
import MapKit
import OSLog
import SwiftData

/// Plain values for one stretch of time, copied out of SwiftData on a private context.
struct MapTileSourceValues: Sendable {
    var tracks: [MapTileTrack] = []
    var stays: [MapTileStay] = []
    /// Every move's span and mode, drawable or not, for the scrubber.
    var spans: [MapHistogramSpan] = []
    var excludedTrips = 0
}

/// Reads what the tiles are built from. Every call takes its own context, fetches a bounded
/// window, and returns plain values: no model outlives the call.
enum MapTileSource {
    /// Months between the first recorded move or stay and `now`, newest first.
    static func months(container: ModelContainer, now: Date, calendar: Calendar) throws -> [Int] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var firstMove = FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)])
        firstMove.fetchLimit = 1
        var firstVisit = FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\.arrivalDate)])
        firstVisit.fetchLimit = 1
        let earliest = [try context.fetch(firstMove).first?.startDate, try context.fetch(firstVisit).first?.arrivalDate]
            .compactMap { $0 }
            .min()
        guard let earliest else { return [] }
        // Nothing real predates GPS phones; a corrupt date must not mean a century of empty months.
        let floor = calendar.date(from: DateComponents(year: 1995, month: 1, day: 1)) ?? .distantPast
        var month = MapTileBucket.month(containing: max(min(earliest, now), floor), calendar: calendar)
        let last = MapTileBucket.month(containing: now, calendar: calendar)
        var result: [Int] = []
        while month <= last {
            result.append(month)
            month = MapTileBucket.nextMonth(month)
        }
        return result.reversed()
    }

    /// Changes whenever anything the month's tiles are drawn from changes: its trips' times, modes
    /// and lengths, its stays' times and places, and how many fixes it has. Stable across launches.
    static func signature(of interval: DateInterval, container: ModelContainer) throws -> String {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let start = interval.start, end = interval.end

        var moves = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { $0.startDate >= start && $0.startDate < end && $0.dayTimeline != nil },
            sortBy: [SortDescriptor(\.startDate)]
        )
        moves.propertiesToFetch = [\.id, \.startDate, \.endDate, \.transportModeRawValue, \.distanceMeters, \.originRaw]
        moves.includePendingChanges = false
        let moveRows = try context.fetch(moves)
        // Rows that share a start time come back in any order, so each row hashes on its own
        // and the month adds them up.
        var total: UInt64 = 0
        for move in moveRows {
            var row = StableHash()
            row.combine(move.id.uuidString)
            row.combine(move.startDate.timeIntervalSinceReferenceDate)
            row.combine(move.endDate.timeIntervalSinceReferenceDate)
            row.combine(move.transportModeRawValue)
            row.combine(move.distanceMeters)
            row.combine(move.originRaw)
            total &+= row.value
        }

        var visits = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { $0.arrivalDate >= start && $0.arrivalDate < end && $0.dayTimeline != nil },
            sortBy: [SortDescriptor(\.arrivalDate)]
        )
        visits.propertiesToFetch = [\.id, \.arrivalDate, \.departureDate, \.latitude, \.longitude]
        visits.includePendingChanges = false
        let visitRows = try context.fetch(visits)
        for visit in visitRows {
            var row = StableHash()
            row.combine(visit.id.uuidString)
            row.combine(visit.arrivalDate.timeIntervalSinceReferenceDate)
            row.combine(visit.departureDate?.timeIntervalSinceReferenceDate ?? -1)
            row.combine(visit.latitude)
            row.combine(visit.longitude)
            total &+= row.value &* 0x9E37_79B9_7F4A_7C15
        }

        var samples = FetchDescriptor<LocationSample>(predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end })
        samples.includePendingChanges = false
        let sampleCount = try context.fetchCount(samples)
        return "\(moveRows.count).\(visitRows.count).\(sampleCount).\(String(total, radix: 36))"
    }

    /// Trips starting and stays arriving inside `interval` (`overlapping` widens that to anything
    /// that overlaps it, for a part of a month drawn straight from the store).
    static func values(
        in interval: DateInterval,
        overlapping: Bool = false,
        container: ModelContainer,
        now: Date = .now
    ) throws -> MapTileSourceValues {
        var result = MapTileSourceValues()
        // A trip or stay that started before the window can still overlap it; none lasts this long.
        let lead: TimeInterval = overlapping ? 3 * 86_400 : 0
        let start = interval.start.addingTimeInterval(-lead), end = interval.end
        let windowStart = interval.start
        var offset = 0
        let pageSize = 200
        while true {
            try Task.checkCancellation()
            let count = try autoreleasepool { () throws -> Int in
                // A context per page lets each page's models go once it is copied.
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var moves = FetchDescriptor<MoveSegment>(
                    predicate: #Predicate { $0.startDate >= start && $0.startDate < end && $0.dayTimeline != nil },
                    sortBy: [SortDescriptor(\.startDate)]
                )
                moves.fetchOffset = offset
                moves.fetchLimit = pageSize
                moves.includePendingChanges = false
                moves.relationshipKeyPathsForPrefetching = [\.samplesStorage, \.startPlace, \.endPlace]
                let page = try context.fetch(moves)
                for move in page where !move.isDeleted {
                    if overlapping, move.endDate <= windowStart { continue }
                    result.spans.append(MapHistogramSpan(start: move.startDate, end: move.endDate, mode: move.transportMode))
                    guard MapActivityIndexBuilder.isDrawable(move) else {
                        result.excludedTrips += 1
                        continue
                    }
                    let points = MapActivityIndexBuilder.renderedCoordinates(for: move).compactMap { coordinate -> MercatorPoint? in
                        guard MapRegionFactory.isUsableCoordinate(coordinate) else { return nil }
                        return MercatorPoint(coordinate)
                    }
                    guard points.count > 1 else { continue }
                    result.tracks.append(MapTileTrack(
                        id: move.id,
                        start: move.startDate,
                        end: max(move.endDate, move.startDate),
                        mode: move.transportMode,
                        distanceMeters: move.distanceMeters,
                        points: MapActivityIndex.unwrapped(points)
                    ))
                }
                return page.count
            }
            offset += count
            if count < pageSize { break }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        var visits = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { $0.arrivalDate >= start && $0.arrivalDate < end && $0.dayTimeline != nil },
            sortBy: [SortDescriptor(\.arrivalDate)]
        )
        visits.propertiesToFetch = [\.arrivalDate, \.departureDate, \.latitude, \.longitude]
        visits.includePendingChanges = false
        for visit in try context.fetch(visits) where !visit.isDeleted {
            guard MapRegionFactory.isUsableCoordinate(visit.coordinate) else { continue }
            let departure = visit.departureDate
                ?? min(max(now, visit.arrivalDate), visit.arrivalDate.addingTimeInterval(MapTileSource.openStayLimit))
            if overlapping, departure <= windowStart { continue }
            result.stays.append(MapTileStay(point: MercatorPoint(visit.coordinate), arrival: visit.arrivalDate,
                                            departure: max(departure, visit.arrivalDate)))
        }
        return result
    }

    /// An open stay counts until now, but never more than a day.
    static let openStayLimit: TimeInterval = 86_400

    /// One trip by id, as the Routes layer draws it, for showing a tapped trip on its own.
    static func track(id: UUID, container: ModelContainer) throws -> MapTileTrack? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id && $0.dayTimeline != nil })
        descriptor.fetchLimit = 1
        descriptor.relationshipKeyPathsForPrefetching = [\.samplesStorage, \.startPlace, \.endPlace]
        guard let move = try context.fetch(descriptor).first, !move.isDeleted else { return nil }
        let points = MapActivityIndexBuilder.renderedCoordinates(for: move).compactMap { coordinate -> MercatorPoint? in
            MapRegionFactory.isUsableCoordinate(coordinate) ? MercatorPoint(coordinate) : nil
        }
        guard points.count > 1 else { return nil }
        return MapTileTrack(id: move.id, start: move.startDate, end: max(move.endDate, move.startDate), mode: move.transportMode,
                            distanceMeters: move.distanceMeters, points: MapActivityIndex.unwrapped(points))
    }

    /// Changes when the imported coverage file does.
    static func undatedSignature(url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modified)-\(size)"
    }
}

/// FNV-1a, 64 bits: unlike `Hasher`, the same input hashes the same on every launch.
struct StableHash {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
    }

    mutating func combine(_ double: Double) {
        withUnsafeBytes(of: double.bitPattern) { combine($0) }
    }

    mutating func combine(_ string: String) {
        var string = string
        string.withUTF8 { combine(UnsafeRawBufferPointer($0)) }
        combine(0 as Double)
    }
}

/// When the builder may run. Pure, so the rule is testable.
enum MapTileBuildPolicy {
    enum Decision: Equatable {
        case run
        case pause
    }

    /// Hot or saving power: wait, except for this month and last, which new capture changes and
    /// without which the Map would have nothing current to show. Critical heat waits for everything.
    static func decision(thermalState: ProcessInfo.ThermalState, isLowPowerMode: Bool, isRecentMonth: Bool) -> Decision {
        switch thermalState {
        case .critical:
            return .pause
        case .serious:
            return isRecentMonth ? .run : .pause
        case .nominal, .fair:
            return isLowPowerMode && !isRecentMonth ? .pause : .run
        @unknown default:
            return .pause
        }
    }

    static func current(isRecentMonth: Bool) -> Decision {
        decision(thermalState: ProcessInfo.processInfo.thermalState,
                 isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                 isRecentMonth: isRecentMonth)
    }
}

/// How far a sync has got, for the quiet catch-up line.
struct MapTileBuildProgress: Equatable, Sendable {
    var monthsToBuild = 0
    var monthsBuilt = 0
    var isPaused = false
    var isFinished = false
}

/// Brings the tile pyramid up to date with the store, a month at a time, newest first.
enum MapTileBuilder {
    nonisolated static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "MapTiles")

    /// Tiles one month's values at every level, plus its summary.
    static func build(month bucket: Int, values: MapTileSourceValues, calendar: Calendar) -> (tiles: [MapTileKey: MapTileContent], summary: MapMonthSummary) {
        var tiles: [MapTileKey: MapTileContent] = [:]
        var summary = MapMonthSummary(bucket: bucket)
        summary.excludedTrips = values.excludedTrips
        var bounds = MercatorRect.empty
        var latest: (point: MercatorPoint, time: Date)?
        func day(_ date: Date) -> Int { min(max(calendar.component(.day, from: date) - 1, 0), 30) }
        for track in values.tracks {
            MapTileTiler.add(track, levels: MapTileLevels.all, keepTrips: true, into: &tiles)
            summary.tripsByMode[Int(MapTileTiler.modeIndex(track.mode))] += 1
            summary.dayTrips[day(track.start)] += 1
            for point in track.points { bounds.include(point) }
            if let last = track.points.last, track.end > (latest?.time ?? .distantPast) { latest = (last, track.end) }
        }
        for stay in values.stays {
            MapTileTiler.add(stay, levels: MapTileLevels.all, into: &tiles)
            summary.stays += 1
            summary.dayStays[day(stay.arrival)] += 1
            bounds.include(stay.point)
            if stay.departure >= (latest?.time ?? .distantPast) { latest = (stay.point, stay.departure) }
        }
        for span in values.spans {
            let minutes = max(span.end.timeIntervalSince(span.start), 0) / 60
            summary.dayMinutesByMode[Int(MapTileTiler.modeIndex(span.mode))][day(span.start)] += minutes
        }
        if !bounds.isEmpty { summary.bounds = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY] }
        if let latest { summary.latest = [latest.point.x, latest.point.y, latest.time.timeIntervalSinceReferenceDate] }
        return (tiles, summary)
    }

    /// Imported coverage at every level.
    static func undatedTiles(from blocks: [FogBlock]) throws -> [MapTileKey: MapTileContent] {
        var tiles: [MapTileKey: MapTileContent] = [:]
        for chunk in try MapActivityIndexBuilder.undatedCoverageChunks(from: blocks) {
            try Task.checkCancellation()
            for point in chunk.points {
                MapTileTiler.addUndated(point, levels: MapTileLevels.all, into: &tiles)
            }
        }
        return tiles
    }

    /// Checks every month's signature, newest first, and rebuilds the ones that changed. Commits
    /// in small batches so a kill loses at most a batch, and reports each commit. Throws
    /// `CancellationError` the moment it is cancelled.
    static func sync(
        container: ModelContainer,
        database: MapTileDatabase,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = .now,
        undatedCoverageURL: URL = FogCoverageArchive.url,
        policy: @Sendable (_ isRecentMonth: Bool) -> MapTileBuildPolicy.Decision = { MapTileBuildPolicy.current(isRecentMonth: $0) },
        batchSeconds: Double = 1.0,
        onProgress: @Sendable (MapTileBuildProgress) async -> Void = { _ in },
        onCommit: @Sendable ([MapMonthSummary]) async -> Void = { _ in }
    ) async throws -> MapTileSyncResult {
        var result = MapTileSyncResult()
        let started = DispatchTime.now().uptimeNanoseconds
        let months = try MapTileSource.months(container: container, now: now, calendar: calendar)
        let stored = database.monthSignatures()
        let recent = Set(months.prefix(2))
        var progress = MapTileBuildProgress()
        var batch: [MapTileDatabase.MonthBuild] = []
        var batchStarted = DispatchTime.now().uptimeNanoseconds
        var built = 0, checked = 0

        // Months never built before are the bulk of a first build; count them for the catch-up line.
        progress.monthsToBuild = months.filter { stored[$0] == nil }.count
        await onProgress(progress)

        func flush() async throws {
            guard !batch.isEmpty else { return }
            try database.commit(batch)
            built += batch.count
            result.rebuilt += batch.map(\.bucket)
            progress.monthsBuilt += batch.filter { stored[$0.bucket] == nil }.count
            batch.removeAll()
            batchStarted = DispatchTime.now().uptimeNanoseconds
            await onCommit(database.summaries())
            await onProgress(progress)
        }

        for month in months {
            try Task.checkCancellation()
            while policy(recent.contains(month)) == .pause {
                try await flush()
                if !progress.isPaused {
                    progress.isPaused = true
                    await onProgress(progress)
                    log.notice("tile build paused: thermal state or Low Power Mode")
                }
                try await Task.sleep(for: .seconds(5))
            }
            if progress.isPaused {
                progress.isPaused = false
                await onProgress(progress)
            }
            let interval = MapTileBucket.interval(ofMonth: month, calendar: calendar)
            let signature = try MapTileSource.signature(of: interval, container: container)
            checked += 1
            if stored[month] != signature {
                let monthStarted = DispatchTime.now().uptimeNanoseconds
                let values = try MapTileSource.values(in: interval, container: container, now: now)
                try Task.checkCancellation()
                let (tiles, summary) = build(month: month, values: values, calendar: calendar)
                batch.append(MapTileDatabase.MonthBuild(bucket: month, signature: signature, summary: summary, tiles: tiles))
                let ms = Double(DispatchTime.now().uptimeNanoseconds - monthStarted) / 1_000_000
                log.notice("tile month \(month, privacy: .public): \(values.tracks.count, privacy: .public) trips, \(values.stays.count, privacy: .public) stays, \(tiles.count, privacy: .public) tiles, \(ms, format: .fixed(precision: 0), privacy: .public) ms")
                // The newest month goes in alone so the first picture comes quickly.
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - batchStarted) / 1e9
                if built == 0 || elapsed > batchSeconds || batch.count >= 6 {
                    try await flush()
                }
            }
            await Task.yield()
        }
        try await flush()

        // Months that no longer exist (history deleted or moved).
        for month in stored.keys where !months.contains(month) {
            try Task.checkCancellation()
            try database.removeMonth(month)
            built += 1
            result.removed.append(month)
        }

        let undatedSignature = MapTileSource.undatedSignature(url: undatedCoverageURL)
        if database.meta("undated") != undatedSignature {
            let blocks = (try? FogCoverageArchive.load(from: undatedCoverageURL)) ?? []
            try database.replaceUndated(try undatedTiles(from: blocks), signature: undatedSignature)
            built += 1
            result.rebuiltUndated = true
        }
        if built > 0 {
            if built > 6 { database.checkpoint() }
            await onCommit(database.summaries())
        }
        progress.isFinished = true
        await onProgress(progress)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        log.notice("tile sync \(ms, format: .fixed(precision: 0), privacy: .public) ms: \(checked, privacy: .public) months checked, \(built, privacy: .public) rebuilt, \(database.sizeOnDisk() / 1_024, privacy: .public) KB on disk")
        return result
    }
}

/// What one sync changed.
struct MapTileSyncResult: Sendable {
    var rebuilt: [Int] = []
    var removed: [Int] = []
    var rebuiltUndated = false
}
