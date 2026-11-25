import Accelerate
import CoreGraphics
import Foundation
import MapKit

/// Which stored buckets, and which loose stretches of time, one range draws.
struct MapTileRangePlan: Equatable, Sendable {
    /// All-time, year, and month buckets whose sum is the range's whole months.
    var buckets: [Int]
    /// Parts of the range that don't fill a month, drawn straight from the store.
    var partial: [DateInterval]
    var includeUndated: Bool

    /// All Time reads one record per tile. Anything else is whole months, then the leftover days
    /// at either end. A month counts as whole when the range covers it up to
    /// now, so This Month and This Year need no loose days.
    static func make(
        interval: DateInterval,
        isAllTime: Bool,
        includeUndated: Bool,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapTileRangePlan {
        if isAllTime {
            return MapTileRangePlan(buckets: [MapTileBucket.allTime], partial: [], includeUndated: includeUndated)
        }
        var buckets: [Int] = []
        var partial: [DateInterval] = []
        let last = MapTileBucket.month(containing: max(interval.end.addingTimeInterval(-1), interval.start), calendar: calendar)
        var month = MapTileBucket.month(containing: interval.start, calendar: calendar)
        var covered: [Int] = []
        while month <= last {
            let span = MapTileBucket.interval(ofMonth: month, calendar: calendar)
            if interval.start <= span.start, interval.end >= min(span.end, max(now, span.start.addingTimeInterval(1))) {
                covered.append(month)
            } else {
                let start = max(interval.start, span.start), end = min(interval.end, span.end)
                if end > start { partial.append(DateInterval(start: start, end: end)) }
            }
            month = MapTileBucket.nextMonth(month)
        }
        // No year sums: they would be a third copy of everything on disk, and a year is twelve
        // small reads per tile.
        buckets = covered
        return MapTileRangePlan(buckets: buckets, partial: partial, includeUndated: includeUndated)
    }
}

/// Trips and stays for the loose days of a range, read from the store and tiled per level when a
/// level is first drawn. Small by construction: at most two partial months.
final class MapTileLooseData: @unchecked Sendable {
    let values: MapTileSourceValues
    private var tilesByLevel: [Int: [MapTileKey: MapTileContent]] = [:]
    private let lock = NSLock()

    init(values: MapTileSourceValues) {
        self.values = values
    }

    func tiles(level: Int) -> [MapTileKey: MapTileContent] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tilesByLevel[level] { return cached }
        var tiles: [MapTileKey: MapTileContent] = [:]
        for track in values.tracks { MapTileTiler.add(track, levels: [level], keepTrips: true, into: &tiles) }
        for stay in values.stays { MapTileTiler.add(stay, levels: [level], into: &tiles) }
        tilesByLevel[level] = tiles
        return tiles
    }
}

/// A decoded record placed on the map: its tile's origin in map points (unwrapped, so a tile can
/// be drawn a world over) and its cell size.
struct MapPlacedTile {
    let record: MapTileRecord
    let originX: Double
    let originY: Double
    let cell: Double
    let isLong: Bool
}

/// Draws Routes, Heat, and Fog from the tile pyramid with `MapCoverageRenderer`'s look: the same
/// bitmap geometry, colours, line widths, kernel, reveal radii, and feathering. What it reads is
/// the visible tiles at one level, so its cost follows the screen, not the history.
enum MapTileCompositor {
    struct Input: @unchecked Sendable {
        var database: MapTileDatabase?
        var plan: MapTileRangePlan
        var loose: MapTileLooseData?
        var modes: Set<TransportMode>?
    }

    /// More visible tiles than this means the level is too fine for the bitmap; go coarser.
    static let maximumTiles = 160
    /// Route pieces per stroke.
    static let routeStrokeBatch = 96
    /// Visible pieces past which Routes and Fog step to a coarser level. Ordinary history stays
    /// well under it; only a dense tangle of distinct tracks reaches it, where one more pixel of
    /// merging can't be seen.
    static let routePieceBudget = 30_000

    static func render(_ request: MapCoverageRenderRequest, input: Input) throws -> MapCoverageRaster? {
        let started = DispatchTime.now().uptimeNanoseconds
        let r = MapCoverageRenderer.self
        let image: CGImage?
        let bounds: MercatorRect
        switch request.layer {
        case .routes:
            guard let geometry = r.geometry(for: request, blurSigmaPoints: 0.1, padding: r.routePaddingFraction,
                                            maximumPixelsPerPoint: r.routePixelsPerPoint, pixelBudget: r.routePixelBudget) else { return nil }
            image = try renderRoutes(geometry: geometry, input: input, isDark: request.isDark)
            bounds = geometry.bounds
        case .heat:
            let sigma = r.heatSigmaPoints(metersPerPoint: r.metersPerPoint(for: request))
            guard let geometry = r.geometry(for: request, blurSigmaPoints: sigma) else { return nil }
            image = try renderHeat(geometry: geometry, input: input, isDark: request.isDark)
            bounds = geometry.bounds
        case .fog:
            let scale = r.metersPerPoint(for: request)
            let radius = r.fogRadiusPoints(metersPerPoint: scale)
            let undatedRadius = r.undatedRadiusMeters(metersPerPoint: scale) / scale
            guard let geometry = r.geometry(for: request, blurSigmaPoints: min(radius, undatedRadius) * r.fogFeather) else { return nil }
            image = try renderFog(geometry: geometry, input: input, radiusPoints: radius, undatedRadiusPoints: undatedRadius, isDark: request.isDark)
            bounds = geometry.bounds
        }
        guard let image else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return MapCoverageRaster(image: image, bounds: bounds, layer: request.layer, isDark: request.isDark, renderMilliseconds: elapsed)
    }

    // MARK: Reading tiles

    /// The level for a bitmap whose features may move by at most `pixels` pixels, coarsened until
    /// the visible tiles are few.
    static func level(geometry: MapRasterGeometry, cellPixels: Double, cull: MercatorRect) -> Int {
        var level = MapTileLevels.level(forCellAtMost: cellPixels / geometry.scale)
        while let next = MapTileLevels.coarser(than: level) {
            let size = MapTileLevels.tileSize(level)
            let columns = floor(cull.maxX / size) - floor(cull.minX / size) + 1
            let rows = floor(cull.maxY / size) - floor(cull.minY / size) + 1
            if columns * rows <= Double(maximumTiles) { break }
            level = next
        }
        return level
    }

    /// Visible records for `buckets` (plus loose days) at `level`. Several records for one tile
    /// are merged into one when `merge` is set, so a road in twelve month records draws once.
    static func placedTiles(level: Int, cull: MercatorRect, buckets: [Int], loose: MapTileLooseData?,
                            database: MapTileDatabase?, merge: Bool) -> [MapPlacedTile] {
        let size = MapTileLevels.tileSize(level)
        let n = MapTileLevels.tilesPerSide(level)
        let cell = MapTileLevels.cellSize(level)
        let xMin = Int(floor(cull.minX / size)), xMax = min(Int(floor(cull.maxX / size)), Int(floor(cull.minX / size)) + n - 1)
        let yMin = max(Int(floor(cull.minY / size)), 0), yMax = min(Int(floor(cull.maxY / size)), n - 1)
        guard xMin <= xMax, yMin <= yMax else { return [] }
        var columns: [Int: [Int]] = [:]
        for tx in xMin...xMax {
            columns[tx - MapTileLevels.floorDiv(tx, n) * n, default: []].append(tx)
        }
        // Contiguous runs of wrapped columns, one query each.
        let wrapped = columns.keys.sorted()
        var runs: [ClosedRange<Int>] = []
        for x in wrapped {
            if let last = runs.last, last.upperBound + 1 == x {
                runs[runs.count - 1] = last.lowerBound...x
            } else {
                runs.append(x...x)
            }
        }
        struct TileID: Hashable { let x: Int; let y: Int }
        var records: [TileID: [MapTileRecord]] = [:]
        var longSeen = Set<Int>()
        if let database, !buckets.isEmpty {
            for run in runs {
                for row in database.records(level: level, buckets: buckets, x: run, y: yMin...yMax) {
                    if row.x < 0 {
                        guard longSeen.insert(row.bucket).inserted else { continue }
                    }
                    guard let record = MapTileCodec.decode(row.data) else { continue }
                    records[TileID(x: row.x, y: row.y), default: []].append(record)
                }
            }
        }
        if let loose {
            for (key, content) in loose.tiles(level: level) {
                let visible = key.isLong || (columns[key.x] != nil && key.y >= yMin && key.y <= yMax)
                guard visible, let record = MapTileCodec.decode(MapTileCodec.encode(content, absolute: key.isLong, keepTrips: true)) else { continue }
                records[TileID(x: key.x, y: key.y), default: []].append(record)
            }
        }
        var placed: [MapPlacedTile] = []
        for (id, list) in records {
            var record = list[0]
            if merge, list.count > 1 {
                var content = MapTileContent()
                for item in list { content.merge(MapTileCodec.content(of: item)) }
                record = MapTileCodec.decode(MapTileCodec.encode(content, absolute: id.x < 0, keepTrips: false)) ?? record
                placed.append(contentsOf: place(record, id.x, id.y, columns: columns, size: size, cell: cell))
            } else {
                for item in list {
                    placed.append(contentsOf: place(item, id.x, id.y, columns: columns, size: size, cell: cell))
                }
            }
        }
        return placed
    }

    private static func place(_ record: MapTileRecord, _ x: Int, _ y: Int, columns: [Int: [Int]], size: Double, cell: Double) -> [MapPlacedTile] {
        if x < 0 {
            return [MapPlacedTile(record: record, originX: 0, originY: 0, cell: cell, isLong: true)]
        }
        return (columns[x] ?? []).map { tx in
            MapPlacedTile(record: record, originX: Double(tx) * size, originY: Double(y) * size, cell: cell, isLong: false)
        }
    }

    static func allowedModes(_ modes: Set<TransportMode>?, in layer: MapCoverageLayer = .routes) -> [Bool] {
        TransportMode.allCases.map { layer.draws($0) && (modes?.contains($0) ?? true) }
    }

    /// Calls `body` with each visible segment's endpoints in bitmap pixels, once per world copy.
    static func forEachSegment(
        _ tiles: [MapPlacedTile],
        geometry: MapRasterGeometry,
        cull: MercatorRect,
        allowed: [Bool],
        _ body: (_ mode: Int, _ a: CGPoint, _ b: CGPoint, _ count: UInt32) -> Void
    ) {
        let scale = geometry.scale
        let marginX = (cull.maxX - geometry.bounds.maxX) * scale
        let maxX = Double(geometry.width) + marginX, maxY = Double(geometry.height) + marginX
        for tile in tiles {
            let record = tile.record
            let s = tile.cell * scale
            let coordinates = record.segmentCoordinates
            if tile.isLong {
                for index in 0..<record.segmentCount where allowed[Int(record.segmentModes[index])] {
                    let c = index * 4
                    let ax = Double(coordinates[c]) * tile.cell, ay = Double(coordinates[c + 1]) * tile.cell
                    let bx = Double(coordinates[c + 2]) * tile.cell, by = Double(coordinates[c + 3]) * tile.cell
                    let rect = MercatorRect(minX: min(ax, bx), minY: min(ay, by), maxX: max(ax, bx), maxY: max(ay, by))
                    for shift in MapRasterGeometry.worldOffsets(for: rect, in: cull) {
                        let a = geometry.pixel(MercatorPoint(x: ax, y: ay), offset: shift)
                        let b = geometry.pixel(MercatorPoint(x: bx, y: by), offset: shift)
                        body(Int(record.segmentModes[index]), CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y), record.segmentCounts[index])
                    }
                }
                continue
            }
            let px0 = (tile.originX - geometry.bounds.minX) * scale
            let py0 = (tile.originY - geometry.bounds.minY) * scale
            for index in 0..<record.segmentCount where allowed[Int(record.segmentModes[index])] {
                let c = index * 4
                let ax = px0 + Double(coordinates[c]) * s, ay = py0 + Double(coordinates[c + 1]) * s
                let bx = px0 + Double(coordinates[c + 2]) * s, by = py0 + Double(coordinates[c + 3]) * s
                if max(ax, bx) < -marginX || min(ax, bx) > maxX || max(ay, by) < -marginX || min(ay, by) > maxY { continue }
                body(Int(record.segmentModes[index]), CGPoint(x: ax, y: ay), CGPoint(x: bx, y: by), record.segmentCounts[index])
            }
        }
    }

    /// Calls `body` with each stay cell's centre in pixels, its stay count, and its hours.
    static func forEachStay(_ tiles: [MapPlacedTile], geometry: MapRasterGeometry, _ body: (CGPoint, UInt32, Float) -> Void) {
        let scale = geometry.scale
        for tile in tiles where !tile.isLong {
            let record = tile.record
            let s = tile.cell * scale
            let px0 = (tile.originX - geometry.bounds.minX) * scale, py0 = (tile.originY - geometry.bounds.minY) * scale
            for index in 0..<record.stayCount {
                let x = px0 + (Double(record.stayCoordinates[index * 2]) + 0.5) * s
                let y = py0 + (Double(record.stayCoordinates[index * 2 + 1]) + 0.5) * s
                body(CGPoint(x: x, y: y), record.stayCounts[index], record.stayHours[index])
            }
        }
    }

    // MARK: Routes

    static func renderRoutes(geometry: MapRasterGeometry, input: Input, isDark: Bool) throws -> CGImage? {
        let r = MapCoverageRenderer.self
        let width = geometry.width, height = geometry.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let ppp = geometry.pixelsPerPoint
        let cull = geometry.cullRect(marginPixels: r.routeCasingWidthPoints * ppp)
        // Within a pixel, like the renderer's half-pixel simplification either side of the line.
        var level = level(geometry: geometry, cellPixels: 1, cull: cull)
        let modeCount = TransportMode.allCases.count
        var tiles: [MapPlacedTile] = []
        // Endpoint pairs per mode.
        var pieces: [[CGPoint]] = []
        while true {
            tiles = placedTiles(level: level, cull: cull, buckets: input.plan.buckets, loose: input.loose,
                                database: input.database, merge: true)
            try Task.checkCancellation()
            pieces = (0..<modeCount).map { _ in [CGPoint]() }
            var total = 0
            forEachSegment(tiles, geometry: geometry, cull: cull, allowed: allowedModes(input.modes)) { mode, a, b, _ in
                pieces[mode].append(a)
                pieces[mode].append(b)
                total += 1
            }
            // Too dense to tell apart at this zoom anyway: merge more, so a pan stays quick.
            guard total > routePieceBudget, let coarser = MapTileLevels.coarser(than: level) else { break }
            level = coarser
        }
        try Task.checkCancellation()
        // Pieces that follow on join into one polyline; paths stay small, since one path of a
        // hundred thousand pieces strokes far slower than a thousand paths of a hundred.
        func stroke(_ points: [CGPoint]) throws {
            var index = 0
            while index < points.count {
                let path = CGMutablePath()
                var count = 0
                var tip: CGPoint?
                while index < points.count, count < routeStrokeBatch || tip == points[index] {
                    if tip != points[index] { path.move(to: points[index]) }
                    path.addLine(to: points[index + 1])
                    tip = points[index + 1]
                    index += 2
                    count += 1
                }
                context.addPath(path)
                context.strokePath()
            }
            try Task.checkCancellation()
        }
        // Casings under every line, then the lines, the most common mode first so rarer ones read on top.
        let order = (0..<modeCount).filter { !pieces[$0].isEmpty }.sorted { pieces[$0].count > pieces[$1].count }
        context.setLineWidth(CGFloat(r.routeCasingWidthPoints * ppp))
        context.setStrokeColor(isDark ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.85))
        for mode in order { try stroke(pieces[mode]) }
        context.setLineWidth(CGFloat(r.routeLineWidthPoints * ppp))
        for mode in order {
            context.setStrokeColor(r.routeColor(MapTileTiler.mode(UInt8(mode)), isDark: isDark))
            try stroke(pieces[mode])
        }

        let radius = r.stayDotRadiusPoints * ppp
        let grid = max(radius * 1.5, 1)
        var drawn = Set<Int64>()
        let ring = CGMutablePath(), dots = CGMutablePath()
        forEachStay(tiles, geometry: geometry) { pixel, _, _ in
            guard pixel.x > -radius, pixel.y > -radius, pixel.x < Double(width) + radius, pixel.y < Double(height) + radius else { return }
            let key = (Int64((pixel.x / grid).rounded(.down)) << 32) ^ Int64((pixel.y / grid).rounded(.down))
            guard drawn.insert(key).inserted else { return }
            let outer = radius + 1.5 * ppp
            ring.addEllipse(in: CGRect(x: pixel.x - outer, y: pixel.y - outer, width: outer * 2, height: outer * 2))
            dots.addEllipse(in: CGRect(x: pixel.x - radius, y: pixel.y - radius, width: radius * 2, height: radius * 2))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(ring)
        context.fillPath()
        context.setFillColor(r.placeColor(isDark: isDark))
        context.addPath(dots)
        context.fillPath()
        return context.makeImage()
    }

    // MARK: Heat

    static func heatDensity(geometry: MapRasterGeometry, input: Input) throws -> [Float] {
        let r = MapCoverageRenderer.self
        let width = geometry.width, height = geometry.height
        let sigma = r.heatSigmaPoints(metersPerPoint: geometry.metersPerPoint) * geometry.pixelsPerPoint
        var density = [Float](repeating: 0, count: width * height)
        let cull = geometry.cullRect(marginPixels: sigma * 3)
        // A cell no bigger than a pixel: deposits land where the renderer's would.
        let level = level(geometry: geometry, cellPixels: 1, cull: cull)
        let tiles = placedTiles(level: level, cull: cull, buckets: input.plan.buckets, loose: input.loose,
                                database: input.database, merge: false)
        try Task.checkCancellation()
        let maxX = Double(width) - 1.001, maxY = Double(height) - 1.001
        density.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            func deposit(_ x: Double, _ y: Double, _ weight: Double) {
                guard x >= 0, y >= 0, x <= maxX, y <= maxY else { return }
                let x0 = Int(x), y0 = Int(y)
                let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                let w = Float(weight)
                let row = y0 * width + x0
                base[row] += w * (1 - fx) * (1 - fy)
                base[row + 1] += w * fx * (1 - fy)
                base[row + width] += w * (1 - fx) * fy
                base[row + width + 1] += w * fx * fy
            }
            forEachSegment(tiles, geometry: geometry, cull: cull, allowed: allowedModes(input.modes, in: .heat)) { _, a, b, count in
                guard let (p, q) = MapCoverageRenderer.clip((a.x, a.y), (b.x, b.y), width: Double(width), height: Double(height)) else { return }
                let dx = q.x - p.x, dy = q.y - p.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { return }
                let steps = max(1, Int((length / 0.8).rounded(.up)))
                let weight = length / Double(steps) * Double(count)
                for step in 0..<steps {
                    let t = (Double(step) + 0.5) / Double(steps)
                    deposit(p.x + dx * t, p.y + dy * t, weight)
                }
            }
            let stayWeightPerHour = r.stayPassesPerHour * (2 * Double.pi).squareRoot() * sigma
            forEachStay(tiles, geometry: geometry) { pixel, _, hours in
                guard hours > 0 else { return }
                deposit(pixel.x, pixel.y, Double(hours) * stayWeightPerHour)
            }
        }
        r.gaussianBlur(&density, width: width, height: height, sigma: sigma)
        var normalizer = Float((2 * Double.pi).squareRoot() * sigma)
        vDSP_vsmul(density, 1, &normalizer, &density, 1, vDSP_Length(density.count))
        return density
    }

    static func renderHeat(geometry: MapRasterGeometry, input: Input, isDark: Bool) throws -> CGImage? {
        let density = try heatDensity(geometry: geometry, input: input)
        try Task.checkCancellation()
        return MapCoverageRenderer.heatImage(density: density, geometry: geometry, isDark: isDark)
    }

    // MARK: Fog

    static func fogMask(geometry: MapRasterGeometry, input: Input, radiusPoints: Double, undatedRadiusPoints: Double?) throws -> [Float] {
        let r = MapCoverageRenderer.self
        let width = geometry.width, height = geometry.height
        let radius = radiusPoints * geometry.pixelsPerPoint
        guard let context = r.revealCanvas(width: width, height: height, radius: radius) else {
            return [Float](repeating: 0, count: width * height)
        }
        let cull = geometry.cullRect(marginPixels: radius * 2)
        let minimumStep = max(1, radius * 0.3)
        let allowed = allowedModes(input.modes, in: .fog)
        var level = level(geometry: geometry, cellPixels: minimumStep, cull: cull)
        var tiles: [MapPlacedTile] = []
        var pieces: [CGPoint] = []
        while true {
            tiles = placedTiles(level: level, cull: cull, buckets: input.plan.buckets, loose: input.loose,
                                database: input.database, merge: true)
            try Task.checkCancellation()
            pieces.removeAll(keepingCapacity: true)
            forEachSegment(tiles, geometry: geometry, cull: cull, allowed: allowed) { _, a, b, _ in
                pieces.append(a)
                pieces.append(b)
            }
            guard pieces.count / 2 > routePieceBudget, let coarser = MapTileLevels.coarser(than: level) else { break }
            level = coarser
        }

        let grid = max(radius / 2, 1)
        var drawn = Set<Int64>()
        var pendingDiscs = 0
        func disc(_ pixel: CGPoint, radius r: Double, in context: CGContext, grid: Double, drawn: inout Set<Int64>, pending: inout Int) {
            guard pixel.x > -r, pixel.y > -r, pixel.x < Double(width) + r, pixel.y < Double(height) + r else { return }
            let key = (Int64((pixel.x / grid).rounded(.down)) << 32) ^ Int64((pixel.y / grid).rounded(.down))
            guard drawn.insert(key).inserted else { return }
            context.addEllipse(in: CGRect(x: pixel.x - r, y: pixel.y - r, width: r * 2, height: r * 2))
            pending += 1
            if pending >= 128 {
                context.fillPath()
                pending = 0
            }
        }

        // Strokes in small batches: one stroke's cost grows with how much of its outline overlaps.
        // Pieces that follow on join into one polyline.
        var stroke = CGMutablePath()
        var pendingStrokes = 0
        var tip: CGPoint?
        var discs: [CGPoint] = []
        var index = 0
        while index < pieces.count {
            let a = pieces[index], b = pieces[index + 1]
            index += 2
            let dx = b.x - a.x, dy = b.y - a.y
            if dx * dx + dy * dy < minimumStep * minimumStep, tip != a {
                discs.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                continue
            }
            if tip != a {
                if pendingStrokes >= 64 {
                    context.addPath(stroke)
                    context.strokePath()
                    stroke = CGMutablePath()
                    pendingStrokes = 0
                }
                stroke.move(to: a)
            }
            stroke.addLine(to: b)
            tip = b
            pendingStrokes += 1
        }
        if pendingStrokes > 0 {
            context.addPath(stroke)
            context.strokePath()
        }
        for point in discs {
            disc(point, radius: radius, in: context, grid: grid, drawn: &drawn, pending: &pendingDiscs)
        }
        forEachStay(tiles, geometry: geometry) { pixel, _, _ in
            disc(pixel, radius: radius * 1.1, in: context, grid: grid, drawn: &drawn, pending: &pendingDiscs)
        }

        // Imported cells, read at a level fine enough for their own footprint.
        let undatedRadius = (undatedRadiusPoints ?? radiusPoints) * geometry.pixelsPerPoint
        var undated: [CGPoint] = []
        if input.plan.includeUndated, let database = input.database {
            let undatedCull = geometry.cullRect(marginPixels: undatedRadius * 2)
            let undatedLevel = self.level(geometry: geometry, cellPixels: max(min(undatedRadius, radius) / 2, 1), cull: undatedCull)
            let undatedTiles = placedTiles(level: undatedLevel, cull: undatedCull, buckets: [MapTileBucket.undated],
                                           loose: nil, database: database, merge: false)
            let scale = geometry.scale
            for tile in undatedTiles where !tile.isLong {
                let s = tile.cell * scale
                let px0 = (tile.originX - geometry.bounds.minX) * scale, py0 = (tile.originY - geometry.bounds.minY) * scale
                let coordinates = tile.record.undatedCoordinates
                for index in 0..<tile.record.undatedCount {
                    undated.append(CGPoint(x: px0 + (Double(coordinates[index * 2]) + 0.5) * s,
                                           y: py0 + (Double(coordinates[index * 2 + 1]) + 0.5) * s))
                }
            }
        }
        let separateUndated = !undated.isEmpty && abs(undatedRadius - radius) > 0.5
        if !separateUndated {
            for point in undated {
                disc(point, radius: radius, in: context, grid: grid, drawn: &drawn, pending: &pendingDiscs)
            }
        }
        context.fillPath()
        try Task.checkCancellation()
        var mask = r.feathered(context, sigma: radius * r.fogFeather)
        guard separateUndated, let cells = r.revealCanvas(width: width, height: height, radius: undatedRadius) else { return mask }
        let cellGrid = max(undatedRadius / 2, 1)
        var cellsDrawn = Set<Int64>()
        var pendingCells = 0
        for point in undated {
            disc(point, radius: undatedRadius, in: cells, grid: cellGrid, drawn: &cellsDrawn, pending: &pendingCells)
        }
        cells.fillPath()
        let cellMask = r.feathered(cells, sigma: undatedRadius * r.fogFeather)
        vDSP_vmax(mask, 1, cellMask, 1, &mask, 1, vDSP_Length(mask.count))
        return mask
    }

    static func renderFog(geometry: MapRasterGeometry, input: Input, radiusPoints: Double, undatedRadiusPoints: Double?, isDark: Bool) throws -> CGImage? {
        let mask = try fogMask(geometry: geometry, input: input, radiusPoints: radiusPoints, undatedRadiusPoints: undatedRadiusPoints)
        try Task.checkCancellation()
        return MapCoverageRenderer.fogImage(mask: mask, geometry: geometry, isDark: isDark)
    }

    // MARK: Tapping

    /// The trip drawn closest to `point` within `tolerance` map points, from the month records of
    /// the tiles around it (and the loose days), preferring the newest trip on a shared road.
    static func trip(near point: MercatorPoint, tolerance: Double, mapPointsPerPoint: Double, input: Input) -> UUID? {
        // The level the Routes bitmap is drawn at for this zoom, about half a pixel at 2 px per point.
        let level = MapTileLevels.level(forCellAtMost: mapPointsPerPoint / 4)
        let size = MapTileLevels.tileSize(level)
        let n = MapTileLevels.tilesPerSide(level)
        let reach = MercatorRect(minX: point.x - tolerance, minY: point.y - tolerance, maxX: point.x + tolerance, maxY: point.y + tolerance)
        var tiles: [(record: MapTileRecord, originX: Double, originY: Double, isLong: Bool)] = []
        let monthRange: ClosedRange<Int>?
        if input.plan.buckets == [MapTileBucket.allTime] {
            monthRange = 100_001...999_912
        } else if let first = input.plan.buckets.min(), let last = input.plan.buckets.max() {
            monthRange = (first % 100 == 0 ? first + 1 : first)...(last % 100 == 0 ? last + 12 : last)
        } else {
            monthRange = nil
        }
        let wanted = Set(input.plan.buckets)
        if let database = input.database, let monthRange {
            for tx in Int(floor(reach.minX / size))...Int(floor(reach.maxX / size)) {
                let wrapped = tx - MapTileLevels.floorDiv(tx, n) * n
                let yRange = max(Int(floor(reach.minY / size)), 0)...min(Int(floor(reach.maxY / size)), n - 1)
                for row in database.monthRecords(level: level, months: monthRange, x: wrapped...wrapped, y: yRange) {
                    // A month counts if the plan reads it directly or through its year.
                    guard wanted.contains(MapTileBucket.allTime) || wanted.contains(row.bucket)
                            || wanted.contains(MapTileBucket.yearBucket(ofMonth: row.bucket)),
                          let record = MapTileCodec.decode(row.data) else { continue }
                    tiles.append((record, Double(tx) * size, Double(row.y) * size, row.x < 0))
                }
            }
        }
        if let loose = input.loose {
            for (key, content) in loose.tiles(level: level) {
                guard let record = MapTileCodec.decode(MapTileCodec.encode(content, absolute: key.isLong, keepTrips: true)) else { continue }
                tiles.append((record, Double(key.x) * size, Double(key.y) * size, key.isLong))
            }
        }
        let allowed = allowedModes(input.modes)
        let cell = MapTileLevels.cellSize(level)
        let world = MKMapSize.world.width
        var best: (id: UUID, distance: Double, start: Double)?
        for tile in tiles {
            let record = tile.record
            for index in 0..<record.segmentCount where allowed[Int(record.segmentModes[index])] {
                guard index < record.segmentTrips.count, Int(record.segmentTrips[index]) < record.trips.count else { continue }
                let c = index * 4
                let ox = tile.isLong ? 0 : tile.originX, oy = tile.isLong ? 0 : tile.originY
                let a = MercatorPoint(x: ox + Double(record.segmentCoordinates[c]) * cell, y: oy + Double(record.segmentCoordinates[c + 1]) * cell)
                let b = MercatorPoint(x: ox + Double(record.segmentCoordinates[c + 2]) * cell, y: oy + Double(record.segmentCoordinates[c + 3]) * cell)
                for shift in tile.isLong ? [0, -world, world] : [0] {
                    let p = MercatorPoint(x: point.x - shift, y: point.y)
                    let d = MapActivitySubset.distance(from: p, toSegment: a, b)
                    guard d <= tolerance else { continue }
                    let trip = record.trips[Int(record.segmentTrips[index])]
                    // Within a pixel or two of each other, the newer trip wins.
                    let slack = tolerance * 0.15
                    if let current = best {
                        if d < current.distance - slack || (abs(d - current.distance) <= slack && trip.start > current.start) {
                            best = (trip.id, d, trip.start)
                        }
                    } else {
                        best = (trip.id, d, trip.start)
                    }
                }
            }
        }
        return best?.id
    }
}
