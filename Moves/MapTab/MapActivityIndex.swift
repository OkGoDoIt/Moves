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
    let start: Date
    let end: Date
    let mode: TransportMode
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
                    let coordinates = renderedCoordinates(for: move)
                    let points = coordinates.compactMap { coordinate -> MercatorPoint? in
                        guard MapRegionFactory.isUsableCoordinate(coordinate) else { return nil }
                        return MercatorPoint(coordinate)
                    }
                    guard points.count > 1 else { continue }
                    index.tracks.append(MapActivityTrack(
                        start: move.startDate,
                        end: max(move.endDate, move.startDate),
                        mode: move.transportMode,
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

    /// The geometry the Routes layer draws — a hand-drawn route, else the road-matched cache when
    /// it still matches the move, else the recorded fixes — without passing through inaccurate
    /// fixes. A road match built through one of those is skipped too.
    static func renderedCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        if let manual = move.manualRouteCoordinates { return manual }
        let samples = move.samples.preferredRouteDisplaySamples
        let hasInaccurateFix = samples.contains { !isAccurateEnough($0) }
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
        let fixes = samples.filter(isAccurateEnough)
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
