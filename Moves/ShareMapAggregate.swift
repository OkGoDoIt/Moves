import BackgroundTasks
import CoreLocation
import CryptoKit
import Foundation
import OSLog
import SwiftData

struct ShareMapAggregateTrack {
    let id: UUID
    let transportMode: TransportMode
    let coordinates: [CLLocationCoordinate2D]
    /// Calendar day containing the move, used by the Map tab histogram and filters.
    let dayStart: Date
    let startDate: Date
    let endDate: Date
    let distanceMeters: CLLocationDistance

    init(
        id: UUID,
        transportMode: TransportMode,
        coordinates: [CLLocationCoordinate2D],
        dayStart: Date = .distantPast,
        startDate: Date = .distantPast,
        endDate: Date = .distantPast,
        distanceMeters: CLLocationDistance = 0
    ) {
        self.id = id
        self.transportMode = transportMode
        self.coordinates = coordinates
        self.dayStart = dayStart
        self.startDate = startDate
        self.endDate = endDate
        self.distanceMeters = distanceMeters
    }
}

@Model
final class ShareMapAggregate {
    var periodKey: String = ""
    var periodRawValue: String = ""
    var periodStart: Date = Date.now
    var sourceSignature: String = ""
    var generatedAt: Date = Date.now

    @Attribute(.externalStorage)
    var tracksData: Data? = nil

    init(
        periodKey: String,
        period: MovesSharePeriod,
        periodStart: Date,
        sourceSignature: String,
        tracksData: Data
    ) {
        self.periodKey = periodKey
        self.periodRawValue = period.rawValue
        self.periodStart = periodStart
        self.sourceSignature = sourceSignature
        self.generatedAt = .now
        self.tracksData = tracksData
    }
}

enum ShareMapAggregateStore {
    private struct StoredTrack: Codable {
        let id: UUID
        let transportModeRawValue: String
        let coordinatesData: Data
        let dayStart: Date?
        let startDate: Date?
        let endDate: Date?
        let distanceMeters: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case transportModeRawValue
            case coordinatesData
            case dayStart
            case startDate
            case endDate
            case distanceMeters
        }

        init(
            id: UUID,
            transportModeRawValue: String,
            coordinatesData: Data,
            dayStart: Date?,
            startDate: Date?,
            endDate: Date?,
            distanceMeters: Double?
        ) {
            self.id = id
            self.transportModeRawValue = transportModeRawValue
            self.coordinatesData = coordinatesData
            self.dayStart = dayStart
            self.startDate = startDate
            self.endDate = endDate
            self.distanceMeters = distanceMeters
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            transportModeRawValue = try container.decode(String.self, forKey: .transportModeRawValue)
            coordinatesData = try container.decode(Data.self, forKey: .coordinatesData)
            dayStart = try container.decodeIfPresent(Date.self, forKey: .dayStart)
            startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
            endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
            distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters)
        }
    }

    static func supports(_ period: MovesSharePeriod) -> Bool {
        period == .month || period == .year
    }

    static func periodKey(
        for period: MovesSharePeriod,
        date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard supports(period) else { return nil }
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year else { return nil }
        if period == .year {
            return "year:" + String(year)
        }
        guard let month = components.month else { return nil }
        return String(format: "month:%04d-%02d", year, month)
    }

    /// The fields of one move or place that decide whether a stored aggregate still holds.
    struct SourceRow: Sendable {
        let id: String
        let dayStart: Date
        let text: String
    }

    static func moveRow(_ move: MoveSegment, dayStart: Date) -> SourceRow {
        let storedRouteBytes = (move.manualRouteCoordinatesData?.count ?? 0)
            + (move.routeCacheCoordinatesData?.count ?? 0)
        let id = move.id.uuidString
        return SourceRow(
            id: id,
            dayStart: dayStart,
            text: [
                id,
                move.transportModeRawValue,
                String(move.startDate.timeIntervalSinceReferenceDate),
                String(move.endDate.timeIntervalSinceReferenceDate),
                String(Int(move.distanceMeters.rounded())),
                move.routeCacheSignature ?? "",
                String(storedRouteBytes)
            ].joined(separator: ":")
        )
    }

    static func placeRow(_ place: VisitPlace, dayStart: Date) -> SourceRow {
        let id = place.id.uuidString
        return SourceRow(
            id: id,
            dayStart: dayStart,
            text: [
                id,
                String(place.arrivalDate.timeIntervalSinceReferenceDate),
                String(place.departureDate?.timeIntervalSinceReferenceDate ?? 0),
                String(Int((place.latitude * 100_000).rounded())),
                String(Int((place.longitude * 100_000).rounded()))
            ].joined(separator: ":")
        )
    }

    static func sourceSignature(for timelines: [DayTimeline]) -> String {
        sourceSignature(
            moves: timelines.flatMap { day in day.moves.map { moveRow($0, dayStart: day.dayStart) } },
            places: timelines.flatMap { day in day.places.map { placeRow($0, dayStart: day.dayStart) } }
        )
    }

    static func sourceSignature(moves: [SourceRow], places: [SourceRow]) -> String {
        let source = [moves, places]
            .map { rows in rows.sorted { $0.id < $1.id }.map(\.text).joined(separator: ",") }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "tracks-v3:" + digest
    }

    static func cachedTracks(
        for period: MovesSharePeriod,
        periodStart: Date,
        timelines: [DayTimeline],
        in context: ModelContext
    ) -> [ShareMapAggregateTrack]? {
        guard let key = periodKey(for: period, date: periodStart) else { return nil }
        var descriptor = FetchDescriptor<ShareMapAggregate>(
            predicate: #Predicate { $0.periodKey == key },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let aggregate = try? context.fetch(descriptor).first,
              aggregate.sourceSignature == sourceSignature(for: timelines),
              let data = aggregate.tracksData else {
            return nil
        }
        return decodeTracks(data)
    }

    static func encodeTracks(_ tracks: [ShareMapAggregateTrack]) throws -> Data {
        let stored = tracks.map {
            StoredTrack(
                id: $0.id,
                transportModeRawValue: $0.transportMode.rawValue,
                coordinatesData: RouteCoordinateStorage.encode($0.coordinates) ?? Data(),
                dayStart: $0.dayStart,
                startDate: $0.startDate,
                endDate: $0.endDate,
                distanceMeters: $0.distanceMeters
            )
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(stored)
    }

    private static func decodeTracks(_ data: Data) -> [ShareMapAggregateTrack]? {
        guard let stored = try? PropertyListDecoder().decode([StoredTrack].self, from: data) else {
            return nil
        }
        return stored.compactMap { track in
            let coordinates = RouteCoordinateStorage.decode(track.coordinatesData)
            guard coordinates.count > 1 else { return nil }
            return ShareMapAggregateTrack(
                id: track.id,
                transportMode: TransportMode(rawValue: track.transportModeRawValue) ?? .unknown,
                coordinates: coordinates,
                dayStart: track.dayStart ?? .distantPast,
                startDate: track.startDate ?? .distantPast,
                endDate: track.endDate ?? .distantPast,
                distanceMeters: track.distanceMeters ?? 0
            )
        }
    }
}

enum ShareMapAggregateBuilder {
    private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "ShareMapAggregate")

    /// Reads the store into plain values before doing any work with them.
    ///
    /// This runs on its own context while the reconciler, CloudKit, and the person's
    /// edits delete rows on others. Touching a model whose row has gone aborts the
    /// process with nothing to catch, so nothing here walks a relationship lazily:
    /// each fetch names what it needs up front and is copied out at once.
    private struct Source {
        var moves: [ShareMapAggregateStore.SourceRow]
        var places: [ShareMapAggregateStore.SourceRow]

        init(in context: ModelContext) throws {
            var moveFetch = FetchDescriptor<MoveSegment>()
            moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline]
            moves = try context.fetch(moveFetch).compactMap { move in
                move.dayTimeline.map { ShareMapAggregateStore.moveRow(move, dayStart: $0.dayStart) }
            }
            var placeFetch = FetchDescriptor<VisitPlace>()
            placeFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline]
            places = try context.fetch(placeFetch).compactMap { place in
                place.dayTimeline.map { ShareMapAggregateStore.placeRow(place, dayStart: $0.dayStart) }
            }
        }
    }

    static func refreshAll(in modelContainer: ModelContainer) async {
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                let source = try Source(in: context)
                for period in [MovesSharePeriod.month, .year] {
                    let moves = Dictionary(grouping: source.moves) { period.start(for: $0.dayStart) }
                    let places = Dictionary(grouping: source.places) { period.start(for: $0.dayStart) }
                    for periodStart in Set(moves.keys).union(places.keys).sorted() {
                        try Task.checkCancellation()
                        try rebuildIfNeeded(
                            moves: moves[periodStart] ?? [],
                            places: places[periodStart] ?? [],
                            period: period,
                            periodStart: periodStart,
                            in: context
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("Could not refresh map aggregates: \(error.localizedDescription, privacy: .public)")
            }
        }
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    static func refresh(
        period: MovesSharePeriod,
        periodStart: Date,
        in modelContainer: ModelContainer
    ) async {
        guard ShareMapAggregateStore.supports(period) else { return }
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                let source = try Source(in: context)
                try rebuildIfNeeded(
                    moves: source.moves.filter { period.contains($0.dayStart, periodStart: periodStart) },
                    places: source.places.filter { period.contains($0.dayStart, periodStart: periodStart) },
                    period: period,
                    periodStart: period.start(for: periodStart),
                    in: context
                )
            } catch is CancellationError {
                return
            } catch {
                log.error("Could not refresh requested map aggregate: \(error.localizedDescription, privacy: .public)")
            }
        }
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    private static func rebuildIfNeeded(
        moves: [ShareMapAggregateStore.SourceRow],
        places: [ShareMapAggregateStore.SourceRow],
        period: MovesSharePeriod,
        periodStart: Date,
        in context: ModelContext
    ) throws {
        guard !moves.isEmpty || !places.isEmpty,
              let key = ShareMapAggregateStore.periodKey(for: period, date: periodStart) else { return }
        let signature = ShareMapAggregateStore.sourceSignature(moves: moves, places: places)
        let descriptor = FetchDescriptor<ShareMapAggregate>(
            predicate: #Predicate { $0.periodKey == key },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        let existing = try context.fetch(descriptor)
        if existing.first?.sourceSignature == signature, existing.first?.tracksData != nil {
            return
        }

        let tracks = try tracks(for: period, periodStart: periodStart, in: context)
        try Task.checkCancellation()
        let data = try ShareMapAggregateStore.encodeTracks(tracks)

        let aggregate: ShareMapAggregate
        if let current = existing.first {
            aggregate = current
            aggregate.periodRawValue = period.rawValue
            aggregate.periodStart = periodStart
            aggregate.sourceSignature = signature
            aggregate.generatedAt = .now
            aggregate.tracksData = data
        } else {
            aggregate = ShareMapAggregate(
                periodKey: key,
                period: period,
                periodStart: periodStart,
                sourceSignature: signature,
                tracksData: data
            )
            context.insert(aggregate)
        }
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }
        try context.save()
        log.info("Stored \(tracks.count) tracks for \(key, privacy: .public)")
    }

    private static func tracks(
        for period: MovesSharePeriod,
        periodStart: Date,
        in context: ModelContext
    ) throws -> [ShareMapAggregateTrack] {
        guard let interval = period.dateInterval(containing: periodStart) else { return [] }
        // A move belongs to the day it started on, but editing its times can leave it
        // a little way outside. Read a day either side and keep what the day says.
        let lowerBound = interval.start.addingTimeInterval(-24 * 60 * 60)
        let upperBound = interval.end.addingTimeInterval(24 * 60 * 60)
        var fetch = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { $0.startDate >= lowerBound && $0.startDate < upperBound },
            sortBy: [SortDescriptor(\.startDate)]
        )
        fetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace, \.endPlace, \.samplesStorage]

        let maximumCoordinateCount = period == .year ? 80 : 120
        return try context.fetch(fetch).compactMap { move -> ShareMapAggregateTrack? in
            guard !Task.isCancelled,
                  let dayStart = move.dayTimeline?.dayStart,
                  period.contains(dayStart, periodStart: periodStart) else { return nil }
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let routeSignature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            let coordinates = move.manualRouteCoordinates
                ?? move.cachedRouteCoordinates(for: routeSignature)
                ?? fallback
            guard coordinates.count > 1 else { return nil }
            return ShareMapAggregateTrack(
                id: move.id,
                transportMode: move.transportMode,
                coordinates: downsampled(coordinates, maximumCount: maximumCoordinateCount),
                dayStart: dayStart,
                startDate: move.startDate,
                endDate: move.endDate,
                distanceMeters: move.distanceMeters
            )
        }
    }

    private static func downsampled(
        _ coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[min(Int((Double(index) * step).rounded()), coordinates.count - 1)]
        }
    }
}

enum ShareMapAggregateBackgroundTask {
    /// Must stay in sync with `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`,
    /// which declares it as `$(PRODUCT_BUNDLE_IDENTIFIER).shareMapAggregates`.
    static let taskIdentifier = "\(MovesAppIdentity.bundleIdentifier).shareMapAggregates"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func scheduleNextRun(now: Date = .now) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNextRun()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.sharedContainer() }
                await ShareMapAggregateBuilder.refreshAll(in: container)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
