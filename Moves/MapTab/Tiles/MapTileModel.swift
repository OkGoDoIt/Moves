import CoreGraphics
import Foundation
import MapKit

// The Map tab's tile pyramid. Every level splits the world (2^28 map points across) into square
// tiles of `cellsPerTile` cells; a cell is 2^level map points. Geometry is stored per tile as
// quantised, deduplicated pieces: a road driven 400 times is one segment with a count of 400, so
// what a tile costs to draw depends on how much ground it covers, not how much history it has.

/// Pyramid levels and tile addressing.
enum MapTileLevels {
    /// Quantisation cells along one side of a tile. Tile-relative coordinates fit in 16 bits, and
    /// a tile is big enough that a trip crosses few of them.
    static let cellsPerTile = 4_096
    /// Finest stored level: a cell is 4 map points (about 0.6 m at the equator, less towards the
    /// poles), under GPS precision and under a pixel at street zoom.
    static let finestLevel = 2
    /// Coarsest level: one tile is the whole world (2^28 map points = 2^16 cells × 2^12).
    static let coarsestLevel = 16
    /// Every other level is stored: drawing from one a step finer costs at most twice the pieces,
    /// and the pyramid is half the size.
    static let all = Array(stride(from: finestLevel, through: coarsestLevel, by: 2))
    /// A segment spanning more tiles than this at a level (a flight, a long fixless leg) is kept
    /// once in that level's long-segment record instead of being cut into every tile it crosses.
    static let maximumTilesPerSegment = 64

    static func cellSize(_ level: Int) -> Double { exp2(Double(level)) }
    static func tileSize(_ level: Int) -> Double { cellSize(level) * Double(cellsPerTile) }
    static func tilesPerSide(_ level: Int) -> Int { 1 << (coarsestLevel - level) }

    /// The coarsest stored level whose cells are no bigger than `mapPoints`, so quantising to it
    /// moves nothing by more than half that distance.
    static func level(forCellAtMost mapPoints: Double) -> Int {
        guard mapPoints.isFinite, mapPoints > 0 else { return finestLevel }
        let exact = min(max(Int(floor(log2(mapPoints))), finestLevel), coarsestLevel)
        return all.last { $0 <= exact } ?? finestLevel
    }

    /// The next stored level up, or nil at the top.
    static func coarser(than level: Int) -> Int? {
        all.first { $0 > level }
    }

    /// Floor division that also works for negative tile indices left of the antimeridian.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}

/// One tile of one level; `x == -1, y == -1` is the level's long-segment record.
struct MapTileKey: Hashable, Sendable {
    let level: Int
    let x: Int
    let y: Int

    static func long(_ level: Int) -> MapTileKey { MapTileKey(level: level, x: -1, y: -1) }
    var isLong: Bool { x < 0 }
}

/// Time buckets a tile can be stored under.
enum MapTileBucket {
    /// Everything ever recorded, dated.
    static let allTime = 0
    /// Imported Fog of World coverage, which has no dates.
    static let undated = 1

    static func month(year: Int, month: Int) -> Int { year * 100 + month }
    static func year(_ year: Int) -> Int { year * 100 }
    static func isMonth(_ bucket: Int) -> Bool { bucket >= 100_000 && bucket % 100 != 0 }
    static func yearBucket(ofMonth bucket: Int) -> Int { bucket / 100 * 100 }

    static func month(containing date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return month(year: parts.year ?? 2000, month: parts.month ?? 1)
    }

    static func interval(ofMonth bucket: Int, calendar: Calendar) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: bucket / 100, month: bucket % 100, day: 1)) ?? .distantPast
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func previousMonth(_ bucket: Int) -> Int {
        let year = bucket / 100, month = bucket % 100
        return month == 1 ? self.month(year: year - 1, month: 12) : self.month(year: year, month: month - 1)
    }

    static func nextMonth(_ bucket: Int) -> Int {
        let year = bucket / 100, month = bucket % 100
        return month == 12 ? self.month(year: year + 1, month: 1) : self.month(year: year, month: month + 1)
    }
}

/// A straight piece of route inside one tile, in cell units relative to the tile (or absolute for
/// a long-segment record). Endpoints are ordered so a road driven either way is the same key.
struct MapTileSegment: Hashable, Sendable {
    var mode: UInt8
    var x0: Int32
    var y0: Int32
    var x1: Int32
    var y1: Int32

    init(mode: UInt8, x0: Int32, y0: Int32, x1: Int32, y1: Int32) {
        self.mode = mode
        if (x0, y0) <= (x1, y1) {
            (self.x0, self.y0, self.x1, self.y1) = (x0, y0, x1, y1)
        } else {
            (self.x0, self.y0, self.x1, self.y1) = (x1, y1, x0, y0)
        }
    }
}

/// A cell, in the same units as `MapTileSegment`.
struct MapTileCell: Hashable, Sendable {
    var x: Int32
    var y: Int32
}

/// What one tile holds for one bucket while it is built or merged.
struct MapTileContent: Sendable {
    struct SegmentValue: Sendable {
        var count: Int64
        /// The newest trip along this piece, for tapping a route. Only month records keep it.
        var trip: UUID?
        var tripStart: Double
    }

    struct StayValue: Sendable {
        var count: Int64
        /// Hours of dwell, each stay capped at `MapCoverageRenderer.stayHoursCap`, summed.
        var hours: Double
    }

    var segments: [MapTileSegment: SegmentValue] = [:]
    var stays: [MapTileCell: StayValue] = [:]
    var undated: Set<MapTileCell> = []

    var isEmpty: Bool { segments.isEmpty && stays.isEmpty && undated.isEmpty }

    mutating func addSegment(_ segment: MapTileSegment, count: Int64 = 1, trip: UUID?, tripStart: Double) {
        if var value = segments[segment] {
            value.count += count
            if let trip, tripStart >= value.tripStart || value.trip == nil {
                value.trip = trip
                value.tripStart = tripStart
            }
            segments[segment] = value
        } else {
            segments[segment] = SegmentValue(count: count, trip: trip, tripStart: tripStart)
        }
    }

    mutating func addStay(_ cell: MapTileCell, count: Int64 = 1, hours: Double) {
        if var value = stays[cell] {
            value.count += count
            value.hours += hours
            stays[cell] = value
        } else {
            stays[cell] = StayValue(count: count, hours: hours)
        }
    }

    /// Adds `other` once (`sign` 1) or takes it away (`sign` -1). Aggregates keep counts only, so
    /// a month can be swapped out of the all-time and year sums without rereading other months.
    mutating func merge(_ other: MapTileContent, sign: Int64 = 1, keepTrips: Bool = false) {
        for (segment, value) in other.segments {
            let count = (segments[segment]?.count ?? 0) + sign * value.count
            if count <= 0 {
                segments[segment] = nil
            } else if keepTrips {
                var merged = segments[segment] ?? SegmentValue(count: 0, trip: nil, tripStart: -.infinity)
                merged.count = count
                if let trip = value.trip, value.tripStart >= merged.tripStart || merged.trip == nil {
                    merged.trip = trip
                    merged.tripStart = value.tripStart
                }
                segments[segment] = merged
            } else {
                segments[segment] = SegmentValue(count: count, trip: nil, tripStart: 0)
            }
        }
        for (cell, value) in other.stays {
            let count = (stays[cell]?.count ?? 0) + sign * value.count
            if count <= 0 {
                stays[cell] = nil
            } else {
                stays[cell] = StayValue(count: count, hours: max((stays[cell]?.hours ?? 0) + Double(sign) * value.hours, 0))
            }
        }
        if sign > 0 { undated.formUnion(other.undated) } else { undated.subtract(other.undated) }
    }
}

/// Plain values for one trip, copied out of SwiftData.
struct MapTileTrack: Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let mode: TransportMode
    let distanceMeters: Double
    /// Map points, unwrapped across the antimeridian.
    let points: [MercatorPoint]
}

/// Plain values for one stay.
struct MapTileStay: Sendable {
    let point: MercatorPoint
    let arrival: Date
    let departure: Date

    /// Heat weight in hours, capped like the renderer caps it.
    var hours: Double { min(max(departure.timeIntervalSince(arrival), 0) / 3_600, MapCoverageRenderer.stayHoursCap) }
}

/// Cuts plain trips, stays, and imported cells into tile contents for a set of levels.
enum MapTileTiler {
    static func modeIndex(_ mode: TransportMode) -> UInt8 {
        UInt8(TransportMode.allCases.firstIndex(of: mode) ?? TransportMode.allCases.count - 1)
    }

    static func mode(_ index: UInt8) -> TransportMode {
        Int(index) < TransportMode.allCases.count ? TransportMode.allCases[Int(index)] : .unknown
    }

    static func add(
        _ track: MapTileTrack,
        levels: [Int],
        keepTrips: Bool,
        into tiles: inout [MapTileKey: MapTileContent]
    ) {
        guard track.points.count > 1 else { return }
        let mode = modeIndex(track.mode)
        let trip = keepTrips ? track.id : nil
        let start = track.start.timeIntervalSinceReferenceDate
        for level in levels {
            let cell = MapTileLevels.cellSize(level)
            // Cell units. Drop points within half a cell of the last one, then simplify to half a
            // cell: nothing visible at this level moves by more than a cell.
            var units: [CGPoint] = []
            units.reserveCapacity(track.points.count)
            for (index, point) in track.points.enumerated() {
                let next = CGPoint(x: point.x / cell, y: point.y / cell)
                if let last = units.last, index != track.points.count - 1 {
                    let dx = next.x - last.x, dy = next.y - last.y
                    if dx * dx + dy * dy < 0.25 { continue }
                }
                units.append(next)
            }
            let kept = MapCoverageRenderer.simplified(units, tolerance: 0.5)
            if kept.count < 2 || kept.allSatisfy({ round($0.x) == round(kept[0].x) && round($0.y) == round(kept[0].y) }) {
                // The whole trip fits in one cell: a dot.
                addPiece(from: kept[0], to: kept[0], mode: mode, level: level, trip: trip, start: start, into: &tiles)
                continue
            }
            for (a, b) in zip(kept, kept.dropFirst()) {
                addPiece(from: a, to: b, mode: mode, level: level, trip: trip, start: start, into: &tiles)
            }
        }
    }

    /// One straight piece, clipped into each tile it crosses, or kept whole if it crosses many.
    static func addPiece(
        from a: CGPoint,
        to b: CGPoint,
        mode: UInt8,
        level: Int,
        trip: UUID?,
        start: Double,
        into tiles: inout [MapTileKey: MapTileContent]
    ) {
        let size = Double(MapTileLevels.cellsPerTile)
        let n = MapTileLevels.tilesPerSide(level)
        let minTX = Int(floor(min(a.x, b.x) / size)), maxTX = Int(floor(max(a.x, b.x) / size))
        let minTY = max(Int(floor(min(a.y, b.y) / size)), 0), maxTY = min(Int(floor(max(a.y, b.y) / size)), n - 1)
        guard minTY <= maxTY else { return }
        if (maxTX - minTX + 1) * (maxTY - minTY + 1) > MapTileLevels.maximumTilesPerSegment {
            let segment = MapTileSegment(mode: mode, x0: Int32(a.x.rounded()), y0: Int32(a.y.rounded()),
                                         x1: Int32(b.x.rounded()), y1: Int32(b.y.rounded()))
            tiles[.long(level), default: MapTileContent()].addSegment(segment, trip: trip, tripStart: start)
            return
        }
        for tx in minTX...maxTX {
            for ty in minTY...maxTY {
                let ox = Double(tx) * size, oy = Double(ty) * size
                let piece: (CGPoint, CGPoint)
                if minTX == maxTX, minTY == maxTY {
                    piece = (a, b)
                } else {
                    guard let clipped = clip(a, b, to: CGRect(x: ox, y: oy, width: size, height: size)) else { continue }
                    piece = clipped
                }
                let wrapped = tx - MapTileLevels.floorDiv(tx, n) * n
                let segment = MapTileSegment(
                    mode: mode,
                    x0: Int32((piece.0.x - ox).rounded()), y0: Int32((piece.0.y - oy).rounded()),
                    x1: Int32((piece.1.x - ox).rounded()), y1: Int32((piece.1.y - oy).rounded())
                )
                // A sliver across a tile corner rounds to nothing; the neighbours draw it.
                if segment.x0 == segment.x1, segment.y0 == segment.y1, a != b { continue }
                tiles[MapTileKey(level: level, x: wrapped, y: ty), default: MapTileContent()]
                    .addSegment(segment, trip: trip, tripStart: start)
            }
        }
    }

    static func add(_ stay: MapTileStay, levels: [Int], into tiles: inout [MapTileKey: MapTileContent]) {
        let hours = stay.hours
        for level in levels {
            guard let (key, cell) = cell(for: stay.point, level: level) else { continue }
            tiles[key, default: MapTileContent()].addStay(cell, hours: hours)
        }
    }

    static func addUndated(_ point: MercatorPoint, levels: [Int], into tiles: inout [MapTileKey: MapTileContent]) {
        for level in levels {
            guard let (key, cell) = cell(for: point, level: level) else { continue }
            tiles[key, default: MapTileContent()].undated.insert(cell)
        }
    }

    /// The tile and tile-relative cell a point falls in; cells are drawn at their centres.
    static func cell(for point: MercatorPoint, level: Int) -> (MapTileKey, MapTileCell)? {
        let size = MapTileLevels.cellsPerTile
        let n = MapTileLevels.tilesPerSide(level)
        let cellSize = MapTileLevels.cellSize(level)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let cx = Int(floor(point.x / cellSize)), cy = Int(floor(point.y / cellSize))
        let tx = MapTileLevels.floorDiv(cx, size), ty = MapTileLevels.floorDiv(cy, size)
        guard ty >= 0, ty < n else { return nil }
        let wrapped = tx - MapTileLevels.floorDiv(tx, n) * n
        return (MapTileKey(level: level, x: wrapped, y: ty),
                MapTileCell(x: Int32(cx - tx * size), y: Int32(cy - ty * size)))
    }

    /// Liang–Barsky clip of a segment to a rectangle.
    static func clip(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0 = 0.0, t1 = 1.0
        let edges: [(Double, Double)] = [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)]
        for (p, q) in edges {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 {
                    if r > t1 { return nil }
                    t0 = max(t0, r)
                } else {
                    if r < t0 { return nil }
                    t1 = min(t1, r)
                }
            }
        }
        guard t0 <= t1 else { return nil }
        return (CGPoint(x: a.x + dx * t0, y: a.y + dy * t0), CGPoint(x: a.x + dx * t1, y: a.y + dy * t1))
    }
}

/// A tile record decoded for drawing: flat arrays, no hashing.
struct MapTileRecord: Sendable {
    var isAbsolute = false
    /// Mode index per segment.
    var segmentModes: [UInt8] = []
    /// x0, y0, x1, y1 per segment, in cell units.
    var segmentCoordinates: [Int32] = []
    var segmentCounts: [UInt32] = []
    /// Index into `trips` per segment, when the record keeps trips.
    var segmentTrips: [UInt32] = []
    var trips: [(id: UUID, start: Double)] = []
    /// x, y per stay cell.
    var stayCoordinates: [Int32] = []
    var stayCounts: [UInt32] = []
    var stayHours: [Float] = []
    /// x, y per imported cell.
    var undatedCoordinates: [Int32] = []

    var segmentCount: Int { segmentModes.count }
    var stayCount: Int { stayCounts.count }
    var undatedCount: Int { undatedCoordinates.count / 2 }
}

/// Binary form of a tile record: compact, versioned by the database's format version.
enum MapTileCodec {
    private static let absoluteFlag: UInt8 = 1
    private static let tripsFlag: UInt8 = 2
    /// The rest of the record is LZFSE-compressed. Records on disk are; ones made in memory to
    /// draw loose days are not.
    private static let compressedFlag: UInt8 = 0x80

    static func encode(_ content: MapTileContent, absolute: Bool, keepTrips: Bool, compress: Bool = false) -> Data {
        let raw = rawEncode(content, absolute: absolute, keepTrips: keepTrips)
        guard compress, raw.count > 64, let packed = try? (raw as NSData).compressed(using: .lzfse) as Data,
              packed.count < raw.count else { return raw }
        var data = Data([compressedFlag])
        data.append(packed)
        return data
    }

    private static func rawEncode(_ content: MapTileContent, absolute: Bool, keepTrips: Bool) -> Data {
        var data = Data()
        data.reserveCapacity(16 + content.segments.count * (keepTrips ? 17 : 13) + content.stays.count * 12)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        func coordinate(_ value: Int32) {
            if absolute { put(value) } else { put(UInt16(clamping: value)) }
        }
        put((absolute ? absoluteFlag : 0) | (keepTrips ? tripsFlag : 0))
        var tripIndex: [UUID: UInt32] = [:]
        if keepTrips {
            var trips: [(UUID, Double)] = []
            for value in content.segments.values {
                guard let trip = value.trip, tripIndex[trip] == nil else { continue }
                tripIndex[trip] = UInt32(trips.count)
                trips.append((trip, value.tripStart))
            }
            put(UInt32(trips.count))
            for (id, start) in trips {
                withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
                put(start)
            }
        }
        put(UInt32(content.segments.count))
        for (segment, value, forward) in chained(content.segments) {
            put(segment.mode)
            if forward {
                coordinate(segment.x0)
                coordinate(segment.y0)
                coordinate(segment.x1)
                coordinate(segment.y1)
            } else {
                coordinate(segment.x1)
                coordinate(segment.y1)
                coordinate(segment.x0)
                coordinate(segment.y0)
            }
            put(UInt32(clamping: value.count))
            if keepTrips { put(value.trip.flatMap { tripIndex[$0] } ?? UInt32.max) }
        }
        put(UInt32(content.stays.count))
        for (cell, value) in content.stays {
            coordinate(cell.x)
            coordinate(cell.y)
            put(UInt32(clamping: value.count))
            put(Float(value.hours))
        }
        put(UInt32(content.undated.count))
        for cell in content.undated {
            coordinate(cell.x)
            coordinate(cell.y)
        }
        return data
    }

    /// Segments ordered and oriented so that, wherever one piece ends where the next of the same
    /// mode begins, they follow each other: drawing then joins them into one polyline instead of
    /// capping every piece, which is most of what stroking costs.
    static func chained(_ segments: [MapTileSegment: MapTileContent.SegmentValue])
        -> [(MapTileSegment, MapTileContent.SegmentValue, Bool)] {
        struct End: Hashable { let mode: UInt8; let x: Int32; let y: Int32 }
        let items = Array(segments)
        var byEnd: [End: [Int]] = [:]
        byEnd.reserveCapacity(items.count * 2)
        for (index, item) in items.enumerated() {
            let s = item.key
            byEnd[End(mode: s.mode, x: s.x0, y: s.y0), default: []].append(index)
            byEnd[End(mode: s.mode, x: s.x1, y: s.y1), default: []].append(index)
        }
        var used = [Bool](repeating: false, count: items.count)
        var result: [(MapTileSegment, MapTileContent.SegmentValue, Bool)] = []
        result.reserveCapacity(items.count)
        func next(from end: End) -> Int? {
            guard let candidates = byEnd[end] else { return nil }
            return candidates.first { !used[$0] }
        }
        for start in items.indices where !used[start] {
            used[start] = true
            let first = items[start]
            result.append((first.key, first.value, true))
            var tip = End(mode: first.key.mode, x: first.key.x1, y: first.key.y1)
            while let index = next(from: tip) {
                used[index] = true
                let s = items[index].key
                let forward = s.x0 == tip.x && s.y0 == tip.y
                result.append((s, items[index].value, forward))
                tip = forward ? End(mode: s.mode, x: s.x1, y: s.y1) : End(mode: s.mode, x: s.x0, y: s.y0)
            }
        }
        return result
    }

    /// Flat arrays for drawing. Nil for a truncated or foreign record.
    static func decode(_ data: Data) -> MapTileRecord? {
        if let first = data.first, first & compressedFlag != 0 {
            guard let raw = try? (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data,
                  raw.first.map({ $0 & compressedFlag == 0 }) == true else { return nil }
            return decode(raw)
        }
        return data.withUnsafeBytes { raw -> MapTileRecord? in
            var offset = 0
            func take<T>(_ type: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= raw.count else { return nil }
                defer { offset += size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            guard let flags = take(UInt8.self) else { return nil }
            var record = MapTileRecord()
            record.isAbsolute = flags & absoluteFlag != 0
            let keepTrips = flags & tripsFlag != 0
            let absolute = record.isAbsolute
            func coordinate() -> Int32? {
                absolute ? take(Int32.self) : take(UInt16.self).map(Int32.init)
            }
            if keepTrips {
                guard let count = take(UInt32.self), offset + Int(count) * 24 <= raw.count else { return nil }
                record.trips.reserveCapacity(Int(count))
                for _ in 0..<count {
                    guard let uuid = take(uuid_t.self), let start = take(Double.self) else { return nil }
                    record.trips.append((UUID(uuid: uuid), start))
                }
            }
            guard let segmentCount = take(UInt32.self) else { return nil }
            let n = Int(segmentCount)
            let coordinateSize = absolute ? 4 : 2
            guard offset + n * (1 + 4 * coordinateSize + 4 + (keepTrips ? 4 : 0)) <= raw.count else { return nil }
            record.segmentModes.reserveCapacity(n)
            record.segmentCoordinates.reserveCapacity(n * 4)
            record.segmentCounts.reserveCapacity(n)
            if keepTrips { record.segmentTrips.reserveCapacity(n) }
            for _ in 0..<n {
                guard let mode = take(UInt8.self), let x0 = coordinate(), let y0 = coordinate(),
                      let x1 = coordinate(), let y1 = coordinate(), let count = take(UInt32.self) else { return nil }
                record.segmentModes.append(mode)
                record.segmentCoordinates.append(contentsOf: [x0, y0, x1, y1])
                record.segmentCounts.append(count)
                if keepTrips {
                    guard let trip = take(UInt32.self) else { return nil }
                    record.segmentTrips.append(trip)
                }
            }
            guard let stayCount = take(UInt32.self) else { return nil }
            for _ in 0..<stayCount {
                guard let x = coordinate(), let y = coordinate(), let count = take(UInt32.self), let hours = take(Float.self) else { return nil }
                record.stayCoordinates.append(contentsOf: [x, y])
                record.stayCounts.append(count)
                record.stayHours.append(hours)
            }
            guard let undatedCount = take(UInt32.self) else { return nil }
            record.undatedCoordinates.reserveCapacity(Int(undatedCount) * 2)
            for _ in 0..<undatedCount {
                guard let x = coordinate(), let y = coordinate() else { return nil }
                record.undatedCoordinates.append(contentsOf: [x, y])
            }
            return record
        }
    }

    /// Back to mergeable content, for swapping a month out of the aggregates.
    static func content(of record: MapTileRecord) -> MapTileContent {
        var content = MapTileContent()
        content.segments.reserveCapacity(record.segmentCount)
        for index in 0..<record.segmentCount {
            let c = index * 4
            let segment = MapTileSegment(mode: record.segmentModes[index],
                                         x0: record.segmentCoordinates[c], y0: record.segmentCoordinates[c + 1],
                                         x1: record.segmentCoordinates[c + 2], y1: record.segmentCoordinates[c + 3])
            var trip: (id: UUID, start: Double)?
            if index < record.segmentTrips.count, Int(record.segmentTrips[index]) < record.trips.count {
                trip = record.trips[Int(record.segmentTrips[index])]
            }
            content.segments[segment] = MapTileContent.SegmentValue(count: Int64(record.segmentCounts[index]),
                                                                    trip: trip?.id, tripStart: trip?.start ?? 0)
        }
        for index in 0..<record.stayCount {
            content.stays[MapTileCell(x: record.stayCoordinates[index * 2], y: record.stayCoordinates[index * 2 + 1])] =
                MapTileContent.StayValue(count: Int64(record.stayCounts[index]), hours: Double(record.stayHours[index]))
        }
        for index in 0..<record.undatedCount {
            content.undated.insert(MapTileCell(x: record.undatedCoordinates[index * 2], y: record.undatedCoordinates[index * 2 + 1]))
        }
        return content
    }
}
