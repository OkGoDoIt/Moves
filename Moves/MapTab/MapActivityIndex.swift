import CoreLocation
import FogOfWorldKit
import Foundation
import MapKit
import SwiftData

/// A Web Mercator point in MapKit map points (`MKMapPoint` units, y grows southward).
struct MercatorPoint: Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        let point = MKMapPoint(coordinate)
        self.init(x: point.x, y: point.y)
    }

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: x, y: y).coordinate
    }
}

/// An axis-aligned rectangle in map points.
struct MercatorRect: Hashable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init(_ rect: MKMapRect) {
        self.init(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
    }

    static let empty = MercatorRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var midX: Double { (minX + maxX) / 2 }
    var midY: Double { (minY + maxY) / 2 }
    var isEmpty: Bool { !(maxX >= minX && maxY >= minY) }

    mutating func include(_ point: MercatorPoint) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }

    func intersects(_ other: MercatorRect) -> Bool {
        !isEmpty && !other.isEmpty
            && minX <= other.maxX && other.minX <= maxX
            && minY <= other.maxY && other.minY <= maxY
    }

    func insetBy(dx: Double, dy: Double) -> MercatorRect {
        MercatorRect(minX: minX + dx, minY: minY + dy, maxX: maxX - dx, maxY: maxY - dy)
    }
}

/// A run of at most `MapActivityIndex.chunkSize` points with its bounding box, so a render
/// skips everything off screen without walking it.
struct MapActivityChunk: Sendable {
    let bounds: MercatorRect
    let points: [MercatorPoint]

    init(points: [MercatorPoint]) {
        var bounds = MercatorRect.empty
        for point in points { bounds.include(point) }
        self.bounds = bounds
        self.points = points
    }
}

/// One move's drawn path, copied out of SwiftData.
struct MapActivityTrack: Sendable {
    var id = UUID()
    let start: Date
    let end: Date
    let mode: TransportMode
    var distanceMeters = 0.0
    let chunks: [MapActivityChunk]
}

/// One stay, copied out of SwiftData.
struct MapActivityStay: Sendable {
    let point: MercatorPoint
    let arrival: Date
    let departure: Date

    var dwell: TimeInterval { max(departure.timeIntervalSince(arrival), 0) }
}

/// Plain-value snapshot of everything Heat and Fog draw: every move's rendered route, every
/// stay, and the separately stored undated Fog coverage. Built off the main thread on its own
/// context; it holds no SwiftData models.
struct MapActivityIndex: Sendable {
    static let chunkSize = 256

    var tracks: [MapActivityTrack] = []
    var stays: [MapActivityStay] = []
    /// Undated imported coverage, one chunk per Fog block. Only All Time shows it.
    var undatedCoverage: [MapActivityChunk] = []
    /// Trips left out by `MapActivityIndexBuilder.isPlausibleTrip`.
    var excludedTripCount = 0

    /// `computedFingerprint()`, worked out once off the main thread when built or loaded.
    var fingerprint = 0

    /// Summarises everything the layers draw, so a rebuild that changed nothing visible can be
    /// recognised and dropped.
    func computedFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(tracks.count)
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(track.mode)
            hasher.combine(track.start)
            hasher.combine(track.end)
            for chunk in track.chunks {
                hasher.combine(chunk.points.count)
                hasher.combine(chunk.points.first)
                hasher.combine(chunk.points.last)
                hasher.combine(chunk.bounds)
            }
        }
        hasher.combine(stays.count)
        for stay in stays {
            hasher.combine(stay.point)
            hasher.combine(stay.arrival)
            hasher.combine(stay.departure)
        }
        hasher.combine(undatedCoverage.count)
        hasher.combine(undatedCoverage.reduce(0) { $0 + $1.points.count })
        return hasher.finalize()
    }

    var pointCount: Int {
        tracks.reduce(0) { $0 + $1.chunks.reduce(0) { $0 + $1.points.count } }
            + undatedCoverage.reduce(0) { $0 + $1.points.count }
    }

    /// The last place anything happened, for opening the map somewhere useful.
    var latestActivity: CLLocationCoordinate2D? {
        let lastStay = stays.max { $0.departure < $1.departure }
        let lastTrack = tracks.max { $0.end < $1.end }
        switch (lastStay, lastTrack) {
        case let (stay?, track?):
            if track.end > stay.departure, let point = track.chunks.last?.points.last {
                return point.coordinate
            }
            return stay.point.coordinate
        case let (stay?, nil):
            return stay.point.coordinate
        case let (nil, track?):
            return track.chunks.last?.points.last?.coordinate
        case (nil, nil):
            return nil
        }
    }

    /// A path that crosses the antimeridian keeps going past the world's edge instead of
    /// jumping back across the whole map; renders draw it again one world-width over.
    static func unwrapped(_ points: [MercatorPoint]) -> [MercatorPoint] {
        let world = MKMapSize.world.width
        var result: [MercatorPoint] = []
        result.reserveCapacity(points.count)
        var shift = 0.0
        for point in points {
            if let previous = result.last {
                let dx = point.x + shift - previous.x
                if dx > world / 2 { shift -= world } else if dx < -world / 2 { shift += world }
            }
            result.append(MercatorPoint(x: point.x + shift, y: point.y))
        }
        return result
    }

    /// Splits a path into overlapping chunks so consecutive chunks still join up.
    static func chunks(for points: [MercatorPoint]) -> [MapActivityChunk] {
        guard points.count > 1 else { return points.isEmpty ? [] : [MapActivityChunk(points: points)] }
        var result: [MapActivityChunk] = []
        var start = 0
        while start < points.count - 1 {
            let end = min(start + chunkSize, points.count)
            result.append(MapActivityChunk(points: Array(points[start..<end])))
            start = end - 1
        }
        return result
    }

    /// What one range and set of modes draws.
    func subset(interval: DateInterval, modes: Set<TransportMode>?, includeUndated: Bool) -> MapActivitySubset {
        MapActivitySubset(
            tracks: tracks.filter { track in
                track.start < interval.end && track.end > interval.start
                    && (modes?.contains(track.mode) ?? true)
            },
            stays: stays.filter { $0.arrival < interval.end && $0.departure > interval.start },
            undatedCoverage: includeUndated ? undatedCoverage : []
        )
    }
}

/// The part of the index one range shows.
struct MapActivitySubset: Sendable {
    var tracks: [MapActivityTrack]
    var stays: [MapActivityStay]
    var undatedCoverage: [MapActivityChunk]

    /// The trip whose line passes closest to `point`, if any is within `tolerance` map points.
    /// Only chunks whose bounding box is within reach are measured.
    func nearestTrack(to point: MercatorPoint, within tolerance: Double) -> MapActivityTrack? {
        let world = MKMapSize.world.width
        var best: (track: MapActivityTrack, distance: Double)?
        for track in tracks {
            for chunk in track.chunks {
                for shift in [0, -world, world] {
                    let p = MercatorPoint(x: point.x - shift, y: point.y)
                    let b = chunk.bounds
                    guard p.x >= b.minX - tolerance, p.x <= b.maxX + tolerance,
                          p.y >= b.minY - tolerance, p.y <= b.maxY + tolerance else { continue }
                    let points = chunk.points
                    for index in points.indices.dropLast() {
                        let d = Self.distance(from: p, toSegment: points[index], points[index + 1])
                        if d <= tolerance, d < (best?.distance ?? .infinity) {
                            best = (track, d)
                        }
                    }
                    if points.count == 1 {
                        let d = Self.distance(from: p, toSegment: points[0], points[0])
                        if d <= tolerance, d < (best?.distance ?? .infinity) { best = (track, d) }
                    }
                }
            }
        }
        return best?.track
    }

    static func distance(from p: MercatorPoint, toSegment a: MercatorPoint, _ b: MercatorPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }
}

/// The activity index saved between launches, so opening the Map draws at once from the last
/// copy while a fresh one builds. It is a disposable cache: any change to the store's files
/// marks it stale, and an unreadable or old-format file is ignored.
enum MapActivityIndexCache {
    static let formatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x4D_41_50_31 // "MAP1"

    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapActivityIndex.bin")
    }

    /// Changes whenever the store's files are written. Cheap: two file attribute reads.
    static func signature(for container: ModelContainer) -> String? {
        guard let configuration = container.configurations.first, !configuration.isStoredInMemoryOnly else { return nil }
        let url = configuration.url
        guard url.isFileURL, url.path != "/dev/null", FileManager.default.fileExists(atPath: url.path) else { return nil }
        let paths = [url.path, url.path + "-wal"]
        let parts = [url.path] + paths.map { path -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(modified)-\(size)"
        }
        return parts.joined(separator: "|")
    }

    static func save(_ index: MapActivityIndex, signature: String, to url: URL = defaultURL) throws {
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        put(magic)
        put(formatVersion)
        let signatureBytes = Array(signature.utf8)
        put(UInt32(signatureBytes.count))
        data.append(contentsOf: signatureBytes)
        put(UInt32(index.excludedTripCount))
        let modes = TransportMode.allCases
        put(UInt32(index.tracks.count))
        for track in index.tracks {
            withUnsafeBytes(of: track.id.uuid) { data.append(contentsOf: $0) }
            put(track.start.timeIntervalSinceReferenceDate)
            put(track.end.timeIntervalSinceReferenceDate)
            put(UInt8(modes.firstIndex(of: track.mode) ?? 0))
            put(track.distanceMeters)
            put(UInt32(track.chunks.count))
            for chunk in track.chunks {
                put(UInt32(chunk.points.count))
                for point in chunk.points {
                    put(point.x)
                    put(point.y)
                }
            }
        }
        put(UInt32(index.stays.count))
        for stay in index.stays {
            put(stay.point.x)
            put(stay.point.y)
            put(stay.arrival.timeIntervalSinceReferenceDate)
            put(stay.departure.timeIntervalSinceReferenceDate)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The saved index and the signature it was built for. Undated coverage is not part of it.
    static func load(from url: URL = defaultURL) -> (index: MapActivityIndex, signature: String)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0
        func take<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard take(UInt32.self) == magic, take(UInt32.self) == formatVersion,
              let signatureLength = take(UInt32.self).map(Int.init),
              offset + signatureLength <= data.count else { return nil }
        let signature = String(decoding: data[offset..<(offset + signatureLength)], as: UTF8.self)
        offset += signatureLength
        var index = MapActivityIndex()
        let modes = TransportMode.allCases
        guard let excluded = take(UInt32.self), let trackCount = take(UInt32.self) else { return nil }
        index.excludedTripCount = Int(excluded)
        index.tracks.reserveCapacity(Int(trackCount))
        for _ in 0..<trackCount {
            guard let uuid = take(uuid_t.self), let start = take(Double.self), let end = take(Double.self),
                  let mode = take(UInt8.self), let distance = take(Double.self),
                  let chunkCount = take(UInt32.self) else { return nil }
            var chunks: [MapActivityChunk] = []
            chunks.reserveCapacity(Int(chunkCount))
            for _ in 0..<chunkCount {
                guard let pointCount = take(UInt32.self), offset + Int(pointCount) * 16 <= data.count else { return nil }
                var points: [MercatorPoint] = []
                points.reserveCapacity(Int(pointCount))
                for _ in 0..<pointCount {
                    guard let x = take(Double.self), let y = take(Double.self) else { return nil }
                    points.append(MercatorPoint(x: x, y: y))
                }
                chunks.append(MapActivityChunk(points: points))
            }
            index.tracks.append(MapActivityTrack(
                id: UUID(uuid: uuid),
                start: Date(timeIntervalSinceReferenceDate: start),
                end: Date(timeIntervalSinceReferenceDate: end),
                mode: Int(mode) < modes.count ? modes[Int(mode)] : .unknown,
                distanceMeters: distance,
                chunks: chunks
            ))
        }
        guard let stayCount = take(UInt32.self) else { return nil }
        for _ in 0..<stayCount {
            guard let x = take(Double.self), let y = take(Double.self),
                  let arrival = take(Double.self), let departure = take(Double.self) else { return nil }
            index.stays.append(MapActivityStay(
                point: MercatorPoint(x: x, y: y),
                arrival: Date(timeIntervalSinceReferenceDate: arrival),
                departure: Date(timeIntervalSinceReferenceDate: departure)
            ))
        }
        return (index, signature)
    }
}

enum MapActivityIndexBuilder {
    private static let pageSize = 400
    /// An open stay counts until now, but never more than a day.
    private static let openStayLimit: TimeInterval = 86_400

    /// Copies values out of the store on a context of its own. Call off the main thread.
    static func build(container: ModelContainer, now: Date = .now, undatedCoverageURL: URL = FogCoverageArchive.url) throws -> MapActivityIndex {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var index = MapActivityIndex()

        var moves = FetchDescriptor<MoveSegment>(sortBy: [SortDescriptor(\.startDate)])
        moves.fetchLimit = pageSize
        moves.includePendingChanges = false
        moves.relationshipKeyPathsForPrefetching = [\.samplesStorage, \.startPlace, \.endPlace]
        var offset = 0
        while true {
            try Task.checkCancellation()
            moves.fetchOffset = offset
            let count = try autoreleasepool { () throws -> Int in
                let page = try context.fetch(moves)
                for move in page where !move.isDeleted {
                    guard isDrawable(move) else {
                        index.excludedTripCount += 1
                        continue
                    }
                    let coordinates = renderedCoordinates(for: move)
                    let points = coordinates.compactMap { coordinate -> MercatorPoint? in
                        guard MapRegionFactory.isUsableCoordinate(coordinate) else { return nil }
                        return MercatorPoint(coordinate)
                    }
                    guard points.count > 1 else { continue }
                    index.tracks.append(MapActivityTrack(
                        id: move.id,
                        start: move.startDate,
                        end: max(move.endDate, move.startDate),
                        mode: move.transportMode,
                        distanceMeters: move.distanceMeters,
                        chunks: MapActivityIndex.chunks(for: MapActivityIndex.unwrapped(points))
                    ))
                }
                return page.count
            }
            offset += count
            if count < pageSize { break }
        }

        var visits = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)])
        visits.includePendingChanges = false
        for visit in try context.fetch(visits) where !visit.isDeleted {
            guard MapRegionFactory.isUsableCoordinate(visit.coordinate) else { continue }
            let departure = visit.departureDate
                ?? min(max(now, visit.arrivalDate), visit.arrivalDate.addingTimeInterval(openStayLimit))
            index.stays.append(MapActivityStay(
                point: MercatorPoint(visit.coordinate),
                arrival: visit.arrivalDate,
                departure: max(departure, visit.arrivalDate)
            ))
        }

        index.undatedCoverage = try undatedCoverageChunks(from: FogCoverageArchive.load(from: undatedCoverageURL))
        index.fingerprint = index.computedFingerprint()
        return index
    }

    /// Fixes worse than this are kilometres off often enough to paint places never visited.
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 100

    /// Whether a fix is good enough to draw Heat or reveal Fog. Negative accuracy means invalid;
    /// zero is what many imports store when the file has none, so it stays.
    static func isAccurateEnough(_ sample: LocationSample) -> Bool {
        sample.horizontalAccuracy >= 0
            && sample.horizontalAccuracy <= maximumHorizontalAccuracy
            && CLLocationCoordinate2DIsValid(sample.coordinate)
    }

    /// A fix that can shape a route: accurate, and not a photo-library history point. History
    /// points place stays; joining unrelated photos with lines invents travel.
    static func isRouteFix(_ sample: LocationSample) -> Bool {
        sample.source != .photoLibrary && isAccurateEnough(sample)
    }

    /// Longer than this with no fixes of its own is a gap between two stays, not a trip.
    static let maximumFixlessTripDuration: TimeInterval = 6 * 3_600
    /// Slower than this over more than `slowTripMinimumDistance` with no fixes is a gap too.
    static let minimumFixlessTripSpeed = 0.2
    static let slowTripMinimumDistance = 2_000.0

    /// The one rule for which trips the Map draws. A trip with no fixes of its own between its
    /// endpoints only knows where it started and ended; when its duration is implausible for its
    /// length, it is a gap between unrelated stays (often photos hours or days apart), so it gets
    /// no route, no Heat, and no Fog corridor. Its endpoint stays still count.
    static func isPlausibleTrip(
        duration: TimeInterval,
        distanceMeters: Double,
        ownFixCount: Int,
        hasManualRoute: Bool
    ) -> Bool {
        if hasManualRoute || ownFixCount > 0 { return true }
        if duration > maximumFixlessTripDuration { return false }
        if distanceMeters > slowTripMinimumDistance, distanceMeters / max(duration, 1) < minimumFixlessTripSpeed { return false }
        return true
    }

    static func isDrawable(_ move: MoveSegment) -> Bool {
        let duration = max(move.endDate.timeIntervalSince(move.startDate), 0)
        var distance = move.distanceMeters
        if distance <= 0, let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate {
            distance = RouteCoordinateOps.distanceMeters(from: start, to: end)
        }
        return isPlausibleTrip(
            duration: duration,
            distanceMeters: distance,
            ownFixCount: move.samples.reduce(0) { $0 + (isRouteFix($1) ? 1 : 0) },
            hasManualRoute: move.manualRouteCoordinatesData != nil
        )
    }

    /// The geometry the Routes layer draws — a hand-drawn route, else the road-matched cache when
    /// it still matches the move, else the recorded fixes — without passing through inaccurate
    /// fixes or photo-library points. A road match built through one of those is skipped too.
    static func renderedCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        if let manual = move.manualRouteCoordinates { return manual }
        let samples = move.samples.preferredRouteDisplaySamples
        let hasInaccurateFix = samples.contains { !isRouteFix($0) }
        if move.routeCacheCoordinatesData != nil, !hasInaccurateFix {
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            if let cached = move.cachedRouteCoordinates(for: signature), cached.count > 1 {
                return cached
            }
            return fallback
        }
        return accurateRawCoordinates(for: move, samples: samples)
    }

    /// `MoveRouteGeometry.rawCoordinates` with inaccurate fixes left out.
    static func accurateRawCoordinates(for move: MoveSegment, samples: [LocationSample]) -> [CLLocationCoordinate2D] {
        let fixes = samples.filter(isRouteFix)
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.coordinate)
        var coordinates: [CLLocationCoordinate2D] = []
        let isWorkout = samples.contains { $0.source == .healthWorkoutRoute }
        if !isWorkout || fixes.count < 2, let start = move.startPlace?.coordinate {
            coordinates.append(start)
        }
        coordinates.append(contentsOf: fixes)
        if !isWorkout || fixes.count < 2, let end = move.endPlace?.coordinate {
            coordinates.append(end)
        }
        return RouteCoordinateOps.dedupeSequentialCoordinates(coordinates, minimumDistanceMeters: isWorkout ? 0 : 6)
    }

    /// One chunk per Fog block, each set cell becoming its centre point.
    static func undatedCoverageChunks(from blocks: [FogBlock]) throws -> [MapActivityChunk] {
        let dimension = Double(FogRasterV1.globalCellDimension)
        let world = MKMapSize.world
        var result: [MapActivityChunk] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            try Task.checkCancellation()
            let tileX = block.tileID % 512, tileY = block.tileID / 512
            let x0 = (tileX * 128 + block.localX) * 64
            let y0 = (tileY * 128 + block.localY) * 64
            var points: [MercatorPoint] = []
            for y in 0..<64 {
                for x in 0..<64 where block.bitmap.contains(x: x, y: y) {
                    points.append(MercatorPoint(
                        x: (Double(x0 + x) + 0.5) / dimension * world.width,
                        y: (Double(y0 + y) + 0.5) / dimension * world.height
                    ))
                }
            }
            if !points.isEmpty {
                result.append(MapActivityChunk(points: points))
            }
        }
        return result
    }
}
