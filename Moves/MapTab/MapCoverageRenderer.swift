import Accelerate
import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import Observation
import OSLog
import SwiftData
import SwiftUI

/// What one Heat or Fog bitmap is drawn for.
struct MapCoverageRenderRequest: Equatable, Sendable {
    var layer: MapCoverageLayer
    /// The visible map, in map points.
    var viewport: MercatorRect
    /// The map's size on screen, in points.
    var viewSize: CGSize
    var isDark: Bool
}

/// A finished bitmap and the map rectangle it covers. It is larger than the screen, so panning
/// and zooming move and scale it until the next one is ready.
struct MapCoverageRaster: @unchecked Sendable {
    let image: CGImage
    let bounds: MercatorRect
    let layer: MapCoverageLayer
    let isDark: Bool
    let renderMilliseconds: Double
}

/// Pixel grid for one bitmap: map points to pixels, y down.
struct MapRasterGeometry: Equatable, Sendable {
    let bounds: MercatorRect
    let width: Int
    let height: Int
    /// Pixels per map point.
    let scale: Double
    /// Pixels per screen point.
    let pixelsPerPoint: Double
    /// Ground metres per screen point at the viewport's centre.
    let metersPerPoint: Double

    /// `offset` shifts the point by whole world widths, for drawing across the antimeridian.
    func pixel(_ point: MercatorPoint, offset: Double = 0) -> (x: Double, y: Double) {
        ((point.x + offset - bounds.minX) * scale, (point.y - bounds.minY) * scale)
    }

    /// `bounds` widened by `pixels` on every side, for culling.
    func cullRect(marginPixels pixels: Double) -> MercatorRect {
        let margin = pixels / scale
        return bounds.insetBy(dx: -margin, dy: -margin)
    }

    /// The whole-world shifts at which something inside `rect` lands in `cull`. Usually just 0;
    /// near the antimeridian, a copy one world over.
    static func worldOffsets(for rect: MercatorRect, in cull: MercatorRect) -> [Double] {
        let world = MKMapSize.world.width
        return [0, -world, world, -2 * world, 2 * world].filter { offset in
            !rect.isEmpty && rect.minX + offset <= cull.maxX && rect.maxX + offset >= cull.minX
                && rect.minY <= cull.maxY && rect.maxY >= cull.minY
        }
    }

    static func worldOffsets(for point: MercatorPoint, in cull: MercatorRect) -> [Double] {
        worldOffsets(for: MercatorRect(minX: point.x, minY: point.y, maxX: point.x, maxY: point.y), in: cull)
    }
}

/// Draws Heat (a blurred density surface) and Fog (a veil with feathered reveals) into bitmaps.
/// Pure and synchronous; callers run it off the main thread.
enum MapCoverageRenderer {
    // Level of detail. Footprints are set on screen, then fixed on the ground for a whole zoom
    // level: one level per doubling of metres per point, like map tile zoom levels. Zooming out
    // a level doubles every footprint on the ground, so detail merges into coarser areas; zooming
    // in halves it, so detail resolves. Within a level the bitmap only scales with the camera.

    /// Heat kernel radius on screen at the middle of a level: where a single trip fades out.
    static let heatRadiusPoints = 20.0
    /// The Gaussian behind it; at 2.5 sigma a lone line is down to a few percent.
    static var heatSigmaPoints: Double { heatRadiusPoints / 2.5 }
    /// GPS can't place a trip closer than this, so street zoom never sharpens past it.
    static let heatMinimumSigmaMeters = 6.0
    /// Fog reveal radius on screen at the middle of a level…
    static let fogRevealPoints = 18.0
    /// …but never less than this on the ground around a route or stay.
    static let fogMinimumRadiusMeters = 30.0
    /// Imported Fog of World cells are about 10 m; zoomed all the way in they keep that detail.
    static let undatedMinimumRadiusMeters = 7.0
    /// Feather as a share of the reveal radius.
    static let fogFeather = 0.42

    /// The zoom level for a scale: log2 of metres per point, rounded. Higher is coarser.
    static func detailLevel(metersPerPoint: Double) -> Int {
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return 0 }
        return min(max(Int(log2(metersPerPoint).rounded()), -8), 24)
    }

    /// Metres per point that every footprint in `level` is sized for.
    static func levelMetersPerPoint(_ level: Int) -> Double {
        exp2(Double(level))
    }

    static func fogRadiusMeters(metersPerPoint: Double) -> Double {
        max(fogMinimumRadiusMeters, fogRevealPoints * levelMetersPerPoint(detailLevel(metersPerPoint: metersPerPoint)))
    }

    static func undatedRadiusMeters(metersPerPoint: Double) -> Double {
        max(undatedMinimumRadiusMeters, fogRevealPoints * levelMetersPerPoint(detailLevel(metersPerPoint: metersPerPoint)))
    }

    static func heatSigmaMeters(metersPerPoint: Double) -> Double {
        max(heatMinimumSigmaMeters, heatSigmaPoints * levelMetersPerPoint(detailLevel(metersPerPoint: metersPerPoint)))
    }

    /// The fog reveal radius on screen at this exact scale.
    static func fogRadiusPoints(metersPerPoint: Double) -> Double {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return fogRevealPoints }
        return fogRadiusMeters(metersPerPoint: metersPerPoint) / metersPerPoint
    }

    static func heatSigmaPoints(metersPerPoint: Double) -> Double {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return heatSigmaPoints }
        return heatSigmaMeters(metersPerPoint: metersPerPoint) / metersPerPoint
    }

    /// Ground metres per screen point at the viewport's centre.
    static func metersPerPoint(for request: MapCoverageRenderRequest) -> Double {
        guard request.viewport.width > 0, request.viewSize.width > 0 else { return .nan }
        let latitude = MercatorPoint(x: request.viewport.midX, y: request.viewport.midY).coordinate.latitude
        return MKMetersPerMapPointAtLatitude(latitude) * request.viewport.width / Double(request.viewSize.width)
    }
    /// Each side of the bitmap reaches this share of the viewport past the screen edge.
    static let paddingFraction = 0.5
    /// Heat and Fog are blurred, so two points to a pixel is plenty; smaller bitmaps render and
    /// reach the screen faster.
    static let maximumPixelsPerPoint = 0.5
    static let pixelBudget = 500_000.0
    /// Blur sigma, in pixels, beyond which resolution drops; a softer image doesn't need more.
    static let maximumSigmaPixels = 16.0
    /// One hour at a stay weighs as much as half a pass along a route, up to this many hours.
    static let stayHoursCap = 12.0
    static let stayPassesPerHour = 0.5

    static func veilColor(isDark: Bool) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        // The dark map is already near black, so a dark veil barely shows there. In dark mode
        // fog is a grey haze over unvisited ground instead, and the visited map stays crisp.
        isDark ? (0.28, 0.30, 0.35, 0.66) : (0.13, 0.15, 0.19, 0.58)
    }

    static func geometry(
        for request: MapCoverageRenderRequest,
        blurSigmaPoints: Double,
        padding: Double = paddingFraction,
        maximumPixelsPerPoint: Double = maximumPixelsPerPoint,
        pixelBudget: Double = pixelBudget
    ) -> MapRasterGeometry? {
        let viewport = request.viewport
        guard viewport.width > 0, viewport.height > 0,
              request.viewSize.width > 1, request.viewSize.height > 1 else { return nil }
        let pointsPerMapPoint = Double(request.viewSize.width) / viewport.width
        let padX = viewport.width * padding
        let padY = viewport.height * padding
        let bounds = viewport.insetBy(dx: -padX, dy: -padY)
        let widthPoints = bounds.width * pointsPerMapPoint
        let heightPoints = bounds.height * pointsPerMapPoint
        let pixelsPerPoint = min(
            maximumPixelsPerPoint,
            (pixelBudget / max(widthPoints * heightPoints, 1)).squareRoot(),
            max(0.12, maximumSigmaPixels / max(blurSigmaPoints, 0.1))
        )
        let scale = pointsPerMapPoint * pixelsPerPoint
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 2, height > 2 else { return nil }
        let latitude = MercatorPoint(x: viewport.midX, y: viewport.midY).coordinate.latitude
        let metersPerPoint = MKMetersPerMapPointAtLatitude(latitude) / pointsPerMapPoint
        return MapRasterGeometry(
            bounds: bounds,
            width: width,
            height: height,
            scale: scale,
            pixelsPerPoint: pixelsPerPoint,
            metersPerPoint: metersPerPoint
        )
    }

    static func render(_ subset: MapActivitySubset, request: MapCoverageRenderRequest) throws -> MapCoverageRaster? {
        let started = DispatchTime.now().uptimeNanoseconds
        let image: CGImage?
        let bounds: MercatorRect
        switch request.layer {
        case .routes:
            guard let geometry = geometry(
                for: request,
                blurSigmaPoints: 0.1,
                padding: routePaddingFraction,
                maximumPixelsPerPoint: routePixelsPerPoint,
                pixelBudget: routePixelBudget
            ) else { return nil }
            image = try renderRoutes(subset, geometry: geometry, isDark: request.isDark)
            bounds = geometry.bounds
        case .heat:
            let sigma = heatSigmaPoints(metersPerPoint: metersPerPoint(for: request))
            guard let geometry = geometry(for: request, blurSigmaPoints: sigma) else { return nil }
            image = try renderHeat(subset, geometry: geometry, isDark: request.isDark)
            bounds = geometry.bounds
        case .fog:
            let scale = metersPerPoint(for: request)
            let radius = fogRadiusPoints(metersPerPoint: scale)
            let undatedRadius = undatedRadiusMeters(metersPerPoint: scale) / scale
            guard let geometry = geometry(for: request, blurSigmaPoints: min(radius, undatedRadius) * fogFeather) else { return nil }
            image = try renderFog(subset, geometry: geometry, radiusPoints: radius, undatedRadiusPoints: undatedRadius, isDark: request.isDark)
            bounds = geometry.bounds
        }
        guard let image else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return MapCoverageRaster(image: image, bounds: bounds, layer: request.layer, isDark: request.isDark, renderMilliseconds: elapsed)
    }

    // MARK: Routes

    /// Above this many trips (or stays) in a range, Routes draws them into a bitmap; below it,
    /// each is a map polyline or annotation.
    static let routeRasterThreshold = 150
    static let routeLineWidthPoints = 3.0
    static let routeCasingWidthPoints = 5.0
    static let stayDotRadiusPoints = 3.5
    /// Lines need more pixels than blurred layers to stay crisp, so less padding.
    static let routePaddingFraction = 0.3
    static let routePixelsPerPoint = 2.0
    static let routePixelBudget = 2_400_000.0
    /// Douglas–Peucker tolerance: about half a pixel.
    static let routeSimplificationPixels = 0.5

    /// Douglas–Peucker on pixel coordinates. Keeps the first and last point.
    static func simplified(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        let toleranceSquared = tolerance * tolerance
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var worst = -1.0
            var worstIndex = first
            for index in (first + 1)..<last {
                let p = points[index]
                let distanceSquared: Double
                if lengthSquared == 0 {
                    distanceSquared = (p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)
                } else {
                    let cross = (p.x - a.x) * dy - (p.y - a.y) * dx
                    distanceSquared = cross * cross / lengthSquared
                }
                if distanceSquared > worst {
                    worst = distanceSquared
                    worstIndex = index
                }
            }
            if worst > toleranceSquared {
                keep[worstIndex] = true
                stack.append((first, worstIndex))
                stack.append((worstIndex, last))
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    /// Mode colours from the app's asset catalog, resolved for light or dark.
    static func routeColor(_ mode: TransportMode, isDark: Bool) -> CGColor {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let color = UIColor(named: MovesPalette.transportColorAssetName(for: mode)) ?? .systemBlue
        return color.resolvedColor(with: traits).cgColor
    }

    static func placeColor(isDark: Bool) -> CGColor {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        return (UIColor(named: "MovesPlace") ?? .systemGreen).resolvedColor(with: traits).cgColor
    }

    /// Every trip in the range as a mode-coloured line with a casing, simplified for this zoom
    /// and culled to the bitmap, then the stays as small dots.
    static func renderRoutes(_ subset: MapActivitySubset, geometry: MapRasterGeometry, isDark: Bool) throws -> CGImage? {
        let width = geometry.width, height = geometry.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let ppp = geometry.pixelsPerPoint
        let cull = geometry.cullRect(marginPixels: routeCasingWidthPoints * ppp)
        let step = max(routeSimplificationPixels, 0.5)

        // Simplify once, draw twice: casings under every line, then the lines.
        var paths: [(CGPath, TransportMode)] = []
        paths.reserveCapacity(subset.tracks.count)
        for track in subset.tracks {
            try Task.checkCancellation()
            for chunk in track.chunks {
                for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: cull) {
                    var pixels: [CGPoint] = []
                    pixels.reserveCapacity(chunk.points.count)
                    for (index, point) in chunk.points.enumerated() {
                        let pixel = geometry.pixel(point, offset: shift)
                        let next = CGPoint(x: pixel.x, y: pixel.y)
                        if let last = pixels.last, index != chunk.points.count - 1 {
                            let dx = next.x - last.x, dy = next.y - last.y
                            if dx * dx + dy * dy < step * step { continue }
                        }
                        pixels.append(next)
                    }
                    let kept = simplified(pixels, tolerance: routeSimplificationPixels)
                    guard kept.count > 1 else { continue }
                    let path = CGMutablePath()
                    path.addLines(between: kept)
                    paths.append((path, track.mode))
                }
            }
        }

        context.setLineWidth(CGFloat(routeCasingWidthPoints * ppp))
        context.setStrokeColor(isDark ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.85))
        for (path, _) in paths {
            context.addPath(path)
            context.strokePath()
        }
        context.setLineWidth(CGFloat(routeLineWidthPoints * ppp))
        let colors = Dictionary(uniqueKeysWithValues: TransportMode.allCases.map { ($0, routeColor($0, isDark: isDark)) })
        for (path, mode) in paths {
            context.setStrokeColor(colors[mode] ?? routeColor(.unknown, isDark: isDark))
            context.addPath(path)
            context.strokePath()
        }

        // Stays: one dot per few points, with a ring so they read on top of lines.
        let radius = stayDotRadiusPoints * ppp
        let grid = max(radius * 1.5, 1)
        var drawn = Set<Int64>()
        let ring = CGMutablePath(), dots = CGMutablePath()
        for stay in subset.stays {
            for shift in MapRasterGeometry.worldOffsets(for: stay.point, in: cull) {
                let pixel = geometry.pixel(stay.point, offset: shift)
                guard pixel.x > -radius, pixel.y > -radius, pixel.x < Double(width) + radius, pixel.y < Double(height) + radius else { continue }
                let key = (Int64((pixel.x / grid).rounded(.down)) << 32) ^ Int64((pixel.y / grid).rounded(.down))
                guard drawn.insert(key).inserted else { continue }
                let outer = radius + 1.5 * ppp
                ring.addEllipse(in: CGRect(x: pixel.x - outer, y: pixel.y - outer, width: outer * 2, height: outer * 2))
                dots.addEllipse(in: CGRect(x: pixel.x - radius, y: pixel.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(ring)
        context.fillPath()
        context.setFillColor(placeColor(isDark: isDark))
        context.addPath(dots)
        context.fillPath()
        return context.makeImage()
    }

    // MARK: Heat

    /// Density in "passes": one trip along a line reads as about 1 at its centre.
    static func heatDensity(_ subset: MapActivitySubset, geometry: MapRasterGeometry) throws -> [Float] {
        let width = geometry.width, height = geometry.height
        // Accumulated and blurred at this bitmap's own resolution, with a kernel sized for the
        // zoom level: coarser zoomed out, down to street detail zoomed in.
        let sigma = heatSigmaPoints(metersPerPoint: geometry.metersPerPoint) * geometry.pixelsPerPoint
        var density = [Float](repeating: 0, count: width * height)
        let cull = geometry.cullRect(marginPixels: sigma * 3)
        let maxX = Double(width) - 1.001, maxY = Double(height) - 1.001

        try density.withUnsafeMutableBufferPointer { buffer in
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
            func walk(from a: (x: Double, y: Double), to b: (x: Double, y: Double)) {
                guard let (p, q) = clip(a, b, width: Double(width), height: Double(height)) else { return }
                let dx = q.x - p.x, dy = q.y - p.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { return }
                let steps = max(1, Int((length / 0.8).rounded(.up)))
                let weight = length / Double(steps)
                for step in 0..<steps {
                    let t = (Double(step) + 0.5) / Double(steps)
                    deposit(p.x + dx * t, p.y + dy * t, weight)
                }
            }

            for track in subset.tracks where MapCoverageLayer.heat.draws(track.mode) {
                try Task.checkCancellation()
                for chunk in track.chunks {
                    for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: cull) {
                        var last: (x: Double, y: Double)?
                        let lastIndex = chunk.points.count - 1
                        for (index, point) in chunk.points.enumerated() {
                            let pixel = geometry.pixel(point, offset: shift)
                            guard let previous = last else {
                                last = pixel
                                continue
                            }
                            let dx = pixel.x - previous.x, dy = pixel.y - previous.y
                            // Decimate by zoom: points closer than a pixel add nothing visible.
                            if dx * dx + dy * dy < 1, index != lastIndex { continue }
                            walk(from: previous, to: pixel)
                            last = pixel
                        }
                    }
                }
            }

            let stayWeightPerHour = stayPassesPerHour * (2 * Double.pi).squareRoot() * sigma
            for stay in subset.stays {
                let hours = min(stay.dwell / 3_600, stayHoursCap)
                guard hours > 0 else { continue }
                for shift in MapRasterGeometry.worldOffsets(for: stay.point, in: cull) {
                    let pixel = geometry.pixel(stay.point, offset: shift)
                    deposit(pixel.x, pixel.y, hours * stayWeightPerHour)
                }
            }
        }

        gaussianBlur(&density, width: width, height: height, sigma: sigma)
        var normalizer = Float((2 * Double.pi).squareRoot() * sigma)
        vDSP_vsmul(density, 1, &normalizer, &density, 1, vDSP_Length(density.count))
        return density
    }

    /// Log curve against a high percentile, so one home cluster doesn't flatten everything else.
    static func heatReference(_ density: [Float]) -> Float {
        let bins = 256
        let lower: Float = -6, upper: Float = 12
        var histogram = [Int](repeating: 0, count: bins)
        var counted = 0
        for value in density where value > 0.05 {
            let bin = Int((log2(value) - lower) / (upper - lower) * Float(bins - 1))
            histogram[min(max(bin, 0), bins - 1)] += 1
            counted += 1
        }
        guard counted > 0 else { return 4 }
        let target = Int(Double(counted) * 0.985)
        var running = 0
        for (bin, count) in histogram.enumerated() {
            running += count
            if running >= target {
                let value = exp2(lower + Float(bin) / Float(bins - 1) * (upper - lower))
                return min(max(value, 4), 400)
            }
        }
        return 4
    }

    static func renderHeat(_ subset: MapActivitySubset, geometry: MapRasterGeometry, isDark: Bool) throws -> CGImage? {
        let density = try heatDensity(subset, geometry: geometry)
        try Task.checkCancellation()
        return heatImage(density: density, geometry: geometry, isDark: isDark)
    }

    /// Colours a blurred, normalised density grid.
    static func heatImage(density: [Float], geometry: MapRasterGeometry, isDark: Bool) -> CGImage? {
        let reference = heatReference(density)
        let lut = heatLUT(isDark: isDark)
        let scale = 255 / log1p(reference)
        var pixels = [UInt32](repeating: 0, count: density.count)
        pixels.withUnsafeMutableBufferPointer { out in
            density.withUnsafeBufferPointer { values in
                for index in 0..<values.count {
                    let value = values[index]
                    guard value > 0.01 else { continue }
                    out[index] = lut[min(Int(log1p(value) * scale), 255)]
                }
            }
        }
        return makeImage(pixels: pixels, width: geometry.width, height: geometry.height)
    }

    /// Transparent → cool → warm, from the app's own colours (Move blue, route-tracking teal,
    /// start amber) ending in a deep orange.
    static func heatLUT(isDark: Bool) -> [UInt32] {
        typealias Stop = (t: Double, r: Double, g: Double, b: Double, a: Double)
        let boost = isDark ? 0.06 : 0
        let stops: [Stop] = [
            (0.00, 0.16, 0.52, 0.93, 0),
            (0.10, 0.16, 0.52, 0.93, 0.34 + boost),
            (0.35, 0.02, 0.69, 0.78, 0.60 + boost),
            (0.68, 0.95, 0.64, 0.18, 0.78 + boost),
            (1.00, 0.91, 0.33, 0.17, 0.88 + boost)
        ]
        return (0..<256).map { index in
            let t = Double(index) / 255
            let upper = stops.firstIndex { $0.t >= t } ?? stops.count - 1
            let a = stops[max(upper - 1, 0)], b = stops[upper]
            let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
            // Ease the opening alpha so faint edges fade instead of stopping.
            let alpha = a.a + (b.a - a.a) * (upper == 1 ? f * f * (3 - 2 * f) : f)
            return packPremultiplied(
                red: a.r + (b.r - a.r) * f,
                green: a.g + (b.g - a.g) * f,
                blue: a.b + (b.b - a.b) * f,
                alpha: alpha
            )
        }
    }

    // MARK: Fog

    /// A white-on-black 8-bit canvas, y down, for one reveal pass.
    static func revealCanvas(width: Int, height: Int, radius: Double) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setFillColor(gray: 1, alpha: 1)
        context.setLineWidth(CGFloat(radius * 2))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        return context
    }

    /// The canvas as 0…1 floats, feathered by `sigma` pixels.
    static func feathered(_ context: CGContext, sigma: Double) -> [Float] {
        let width = context.width, height = context.height
        var mask = [Float](repeating: 0, count: width * height)
        guard let data = context.data else { return mask }
        var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: context.bytesPerRow)
        mask.withUnsafeMutableBytes { raw in
            var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageConvert_Planar8toPlanarF(&source, &destination, 1, 0, vImage_Flags(kvImageNoFlags))
        }
        gaussianBlur(&mask, width: width, height: height, sigma: sigma)
        return mask
    }

    /// Reveal mask, 0 (fogged) to 1 (seen), feathered. Routes and stays reveal `radiusPoints`;
    /// imported coverage reveals `undatedRadiusPoints`, which can be finer when zoomed right in.
    static func fogMask(
        _ subset: MapActivitySubset,
        geometry: MapRasterGeometry,
        radiusPoints: Double,
        undatedRadiusPoints: Double? = nil
    ) throws -> [Float] {
        let width = geometry.width, height = geometry.height
        let radius = radiusPoints * geometry.pixelsPerPoint
        guard let context = revealCanvas(width: width, height: height, radius: radius) else {
            return [Float](repeating: 0, count: width * height)
        }

        let cull = geometry.cullRect(marginPixels: radius * 2)
        // A wide round stroke hides any bend tighter than a fraction of its radius, and stroking
        // thousands of overlapping joins is what makes a zoomed-out fog slow.
        let minimumStep = max(1, radius * 0.3)

        // Stays, imported coverage, and routes smaller than a fraction of the radius are discs.
        // Discs closer than half a radius look the same as one, so draw one per half-radius cell,
        // filled in small batches: one fill of thousands of overlapping shapes is slow.
        let grid = max(radius / 2, 1)
        var drawn = Set<Int64>()
        var pendingDiscs = 0
        func disc(_ point: MercatorPoint, radius r: Double, offset: Double) {
            let pixel = geometry.pixel(point, offset: offset)
            guard pixel.x > -r, pixel.y > -r, pixel.x < Double(width) + r, pixel.y < Double(height) + r else { return }
            let key = (Int64((pixel.x / grid).rounded(.down)) << 32) ^ Int64((pixel.y / grid).rounded(.down))
            guard drawn.insert(key).inserted else { return }
            context.addEllipse(in: CGRect(x: pixel.x - r, y: pixel.y - r, width: r * 2, height: r * 2))
            pendingDiscs += 1
            if pendingDiscs >= 128 {
                context.fillPath()
                pendingDiscs = 0
            }
        }

        // Each run is stroked on its own: a stroke's cost grows with how much of its own outline
        // overlaps, and separate strokes don't overlap each other.
        for track in subset.tracks where MapCoverageLayer.fog.draws(track.mode) {
            try Task.checkCancellation()
            for chunk in track.chunks {
                let spanX = chunk.bounds.width * geometry.scale, spanY = chunk.bounds.height * geometry.scale
                for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: cull) {
                    if spanX < minimumStep, spanY < minimumStep {
                        disc(MercatorPoint(x: chunk.bounds.midX, y: chunk.bounds.midY), radius: radius, offset: shift)
                        continue
                    }
                    let path = CGMutablePath()
                    var last: (x: Double, y: Double)?
                    let lastIndex = chunk.points.count - 1
                    for (index, point) in chunk.points.enumerated() {
                        let pixel = geometry.pixel(point, offset: shift)
                        if let previous = last {
                            let dx = pixel.x - previous.x, dy = pixel.y - previous.y
                            if dx * dx + dy * dy < minimumStep * minimumStep, index != lastIndex { continue }
                            path.addLine(to: CGPoint(x: pixel.x, y: pixel.y))
                        } else {
                            path.move(to: CGPoint(x: pixel.x, y: pixel.y))
                        }
                        last = pixel
                    }
                    if pendingDiscs > 0 {
                        context.fillPath()
                        pendingDiscs = 0
                    }
                    context.addPath(path)
                    context.strokePath()
                }
            }
        }

        for stay in subset.stays {
            for shift in MapRasterGeometry.worldOffsets(for: stay.point, in: cull) {
                disc(stay.point, radius: radius * 1.1, offset: shift)
            }
        }
        let undatedRadius = (undatedRadiusPoints ?? radiusPoints) * geometry.pixelsPerPoint
        let undatedCull = geometry.cullRect(marginPixels: undatedRadius * 2)
        let visibleUndated = subset.undatedCoverage.filter { !MapRasterGeometry.worldOffsets(for: $0.bounds, in: undatedCull).isEmpty }
        let separateUndated = !visibleUndated.isEmpty && abs(undatedRadius - radius) > 0.5
        if !separateUndated {
            for chunk in visibleUndated {
                try Task.checkCancellation()
                for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: cull) {
                    for point in chunk.points {
                        disc(point, radius: radius, offset: shift)
                    }
                }
            }
        }
        context.fillPath()
        var mask = feathered(context, sigma: radius * fogFeather)
        guard separateUndated, let cells = revealCanvas(width: width, height: height, radius: undatedRadius) else { return mask }

        // Imported cells at their own, finer footprint, merged by the same half-radius grid.
        let cellGrid = max(undatedRadius / 2, 1)
        var cellsDrawn = Set<Int64>()
        var pendingCells = 0
        for chunk in visibleUndated {
            try Task.checkCancellation()
            for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: undatedCull) {
                for point in chunk.points {
                    let pixel = geometry.pixel(point, offset: shift)
                    let r = undatedRadius
                    guard pixel.x > -r, pixel.y > -r, pixel.x < Double(width) + r, pixel.y < Double(height) + r else { continue }
                    let key = (Int64((pixel.x / cellGrid).rounded(.down)) << 32) ^ Int64((pixel.y / cellGrid).rounded(.down))
                    guard cellsDrawn.insert(key).inserted else { continue }
                    cells.addEllipse(in: CGRect(x: pixel.x - r, y: pixel.y - r, width: r * 2, height: r * 2))
                    pendingCells += 1
                    if pendingCells >= 128 {
                        cells.fillPath()
                        pendingCells = 0
                    }
                }
            }
        }
        cells.fillPath()
        let cellMask = feathered(cells, sigma: undatedRadius * fogFeather)
        vDSP_vmax(mask, 1, cellMask, 1, &mask, 1, vDSP_Length(mask.count))
        return mask
    }

    static func renderFog(
        _ subset: MapActivitySubset,
        geometry: MapRasterGeometry,
        radiusPoints: Double,
        undatedRadiusPoints: Double? = nil,
        isDark: Bool
    ) throws -> CGImage? {
        let mask = try fogMask(subset, geometry: geometry, radiusPoints: radiusPoints, undatedRadiusPoints: undatedRadiusPoints)
        try Task.checkCancellation()
        return fogImage(mask: mask, geometry: geometry, isDark: isDark)
    }

    /// The veil over a 0…1 reveal mask.
    static func fogImage(mask: [Float], geometry: MapRasterGeometry, isDark: Bool) -> CGImage? {
        let veil = veilColor(isDark: isDark)
        // 256 veil strengths, from full fog to fully revealed.
        let lut: [UInt32] = (0..<256).map { index in
            let seen = min(Double(index) / 255 * 1.2, 1)
            return packPremultiplied(red: veil.red, green: veil.green, blue: veil.blue, alpha: veil.alpha * (1 - seen))
        }
        var pixels = [UInt32](repeating: lut[0], count: mask.count)
        pixels.withUnsafeMutableBufferPointer { out in
            mask.withUnsafeBufferPointer { values in
                for index in 0..<values.count {
                    let value = values[index]
                    guard value > 0.002 else { continue }
                    out[index] = lut[min(Int(value * 255), 255)]
                }
            }
        }
        return makeImage(pixels: pixels, width: geometry.width, height: geometry.height)
    }

    // MARK: Shared

    /// Separable Gaussian, in place.
    static func gaussianBlur(_ values: inout [Float], width: Int, height: Int, sigma: Double) {
        guard sigma > 0.3 else { return }
        let radius = Int((sigma * 3).rounded(.up))
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var scratch = [Float](repeating: 0, count: values.count)
        let rowBytes = width * MemoryLayout<Float>.size
        values.withUnsafeMutableBytes { valuesRaw in
            scratch.withUnsafeMutableBytes { scratchRaw in
                var a = vImage_Buffer(data: valuesRaw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var b = vImage_Buffer(data: scratchRaw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                let flags = vImage_Flags(kvImageBackgroundColorFill)
                vImageConvolve_PlanarF(&a, &b, nil, 0, 0, kernel, 1, UInt32(kernel.count), 0, flags)
                vImageConvolve_PlanarF(&b, &a, nil, 0, 0, kernel, UInt32(kernel.count), 1, 0, flags)
            }
        }
    }

    /// Liang–Barsky clip of a segment to the bitmap, so a long leg that crosses it from far away
    /// costs only the pixels it covers.
    static func clip(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), width: Double, height: Double)
        -> ((x: Double, y: Double), (x: Double, y: Double))? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0 = 0.0, t1 = 1.0
        let edges: [(Double, Double)] = [(-dx, a.x + 1), (dx, width + 1 - a.x), (-dy, a.y + 1), (dy, height + 1 - a.y)]
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
        return ((a.x + dx * t0, a.y + dy * t0), (a.x + dx * t1, a.y + dy * t1))
    }

    /// RGBA bytes in memory order, premultiplied.
    static func packPremultiplied(red: Double, green: Double, blue: Double, alpha: Double) -> UInt32 {
        let a = min(max(alpha, 0), 1)
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        let r = byte(red * a), g = byte(green * a), b = byte(blue * a), al = byte(a)
        return r | (g << 8) | (b << 16) | (al << 24)
    }

    static func unpack(_ pixel: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        (UInt8(pixel & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8((pixel >> 16) & 0xFF), UInt8(pixel >> 24))
    }

    static func makeImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Keeps the activity index and the current Heat or Fog bitmap for the Map tab. Index builds and
/// renders run detached; a newer request cancels the older render.
@Observable
@MainActor
final class MapCoverageController {
    private(set) var raster: MapCoverageRaster?
    /// Counts finished bitmaps, so views can react to each one.
    private(set) var rasterGeneration = 0
    private(set) var latestActivity: CLLocationCoordinate2D?
    private(set) var loadFailed = false

    /// Counts index replacements, so views can read counts again.
    private(set) var indexGeneration = 0

    @ObservationIgnored private var index: MapActivityIndex?
    @ObservationIgnored private var builtRevision: Int?
    @ObservationIgnored private var wantedRevision = 0
    @ObservationIgnored private var indexTask: Task<MapActivityIndex, Error>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var subsetCache: (key: SubsetKey, subset: MapActivitySubset)?
    @ObservationIgnored private var lastUpdate: Update?
    @ObservationIgnored private var hasCheckedVisitedCells = false
    @ObservationIgnored private var hasTriedSavedIndex = false
    @ObservationIgnored private var lastBuildFinished: Date?
    @ObservationIgnored private var deferredBuild: Task<Void, Never>?
    @ObservationIgnored private var countsCache: (key: SubsetKey, counts: (tracks: Int, stays: Int))?
    @ObservationIgnored private var rasterCache: [(key: RasterKey, raster: MapCoverageRaster)] = []
    @ObservationIgnored private var memoryWarning: NSObjectProtocol?
    nonisolated private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "MapCoverage")
    /// Finished bitmaps kept for panning back or switching layers back, by total size.
    static let rasterCacheBytes = 48 * 1_048_576

    private struct SubsetKey: Equatable {
        let generation: Int
        let interval: DateInterval
        let modes: Set<TransportMode>?
        let includeUndated: Bool
    }

    /// What makes two bitmaps interchangeable: everything but the exact viewport, which only
    /// has to fall inside a cached bitmap's padded bounds.
    struct RasterKey: Hashable {
        let layer: MapCoverageLayer
        let interval: DateInterval
        let modes: Set<TransportMode>?
        let includeUndated: Bool
        let level: Int
        let isDark: Bool
        let indexGeneration: Int
        let viewWidth: Double
        let viewHeight: Double
    }

    struct Update {
        var container: ModelContainer
        var revision: Int
        var request: MapCoverageRenderRequest
        var interval: DateInterval
        var modes: Set<TransportMode>?
        var includeUndated: Bool
        /// The All Time preset, which reads the all-time tiles.
        var isAllTime = false
    }

    // MARK: Tiles

    /// Draw from the tile pyramid. `MOVES_MAP_TILES=0` draws from the in-memory index instead,
    /// for measuring one against the other.
    static let usesTiles = ProcessInfo.processInfo.environment["MOVES_MAP_TILES"] != "0"

    /// Months built so far, and whether a first build is still catching up.
    private(set) var buildProgress = MapTileBuildProgress()
    /// Per-month counts, bounds, and minutes, for range sizes and the scrubber.
    private(set) var summaries: [MapMonthSummary] = []
    /// Each summary's month, worked out once so a scrubber tick does no calendar arithmetic.
    @ObservationIgnored private var summarySpans: [DateInterval] = []
    @ObservationIgnored private var tileStores: (reader: MapTileDatabase, writer: MapTileDatabase)?
    @ObservationIgnored private var tileStoreFailed = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncedRevision: Int?
    @ObservationIgnored private var lastSyncFinished: Date?
    @ObservationIgnored private var loose: (key: LooseKey, data: MapTileLooseData)?
    @ObservationIgnored private var commitRedraw: Task<Void, Never>?
    @ObservationIgnored private var lastCommitRedraw: Date = .distantPast
    @ObservationIgnored private let tileDirectory: URL

    private struct LooseKey: Equatable {
        let partial: [DateInterval]
        let revision: Int
    }

    /// Shows the quiet catch-up line: a first build with more than a couple of months to go.
    var isCatchingUp: Bool {
        !buildProgress.isFinished && buildProgress.monthsToBuild - buildProgress.monthsBuilt > 2
    }

    /// Where the pyramid lives and which store it is for. An in-memory store (the simulator's demo
    /// data, tests) gets a file of its own that no other launch reuses.
    nonisolated static func tileStoreLocation(for container: ModelContainer, directory: URL) -> (url: URL, identity: String) {
        if let configuration = container.configurations.first, !configuration.isStoredInMemoryOnly,
           configuration.url.isFileURL, configuration.url.path != "/dev/null" {
            return (directory.appendingPathComponent("tiles.sqlite"), configuration.url.path)
        }
        return (directory.appendingPathComponent("memory-\(ObjectIdentifier(container).hashValue).sqlite"), "memory-\(UUID().uuidString)")
    }

    private func openTiles(container: ModelContainer) async {
        guard tileStores == nil, !tileStoreFailed else { return }
        let directory = tileDirectory
        let opened = await Task.detached(priority: .userInitiated) { () -> (MapTileDatabase, MapTileDatabase, [MapMonthSummary])? in
            let location = MapCoverageController.tileStoreLocation(for: container, directory: directory)
            guard let writer = try? MapTileDatabase(url: location.url, storeIdentity: location.identity),
                  let reader = try? MapTileDatabase(url: location.url, storeIdentity: location.identity) else { return nil }
            return (reader, writer, reader.summaries())
        }.value
        guard tileStores == nil else { return }
        guard let opened else {
            tileStoreFailed = true
            loadFailed = true
            Self.log.error("tile store could not be opened")
            return
        }
        tileStores = (opened.0, opened.1)
        adoptSummaries(opened.2)
    }

    private func adoptSummaries(_ summaries: [MapMonthSummary]) {
        self.summaries = summaries
        let calendar = Calendar.autoupdatingCurrent
        summarySpans = summaries.map { MapTileBucket.interval(ofMonth: $0.bucket, calendar: calendar) }
        indexGeneration += 1
        subsetCache = nil
        countsCache = nil
        rasterCache.removeAll()
        if let latest = summaries.reversed().lazy.compactMap(\.latest).first {
            let coordinate = MercatorPoint(x: latest[0], y: latest[1]).coordinate
            if latestActivity?.latitude != coordinate.latitude || latestActivity?.longitude != coordinate.longitude {
                latestActivity = coordinate
            }
        }
    }

    /// Starts bringing the tiles up to date for the newest revision, unless one is running, the
    /// last finished moments ago, or the app is leaving.
    private func startSyncIfNeeded(container: ModelContainer) {
        guard Self.usesTiles, !isSuspended, syncTask == nil, syncedRevision != wantedRevision, let stores = tileStores else { return }
        if let finished = lastSyncFinished, Date().timeIntervalSince(finished) < Self.minimumRebuildInterval {
            scheduleDeferredBuild(container: container, after: Self.minimumRebuildInterval - Date().timeIntervalSince(finished))
            return
        }
        let revision = wantedRevision
        if !hasCheckedVisitedCells {
            hasCheckedVisitedCells = true
            Task { try? await VisitedCellStore.ensureBuilt(container: container) }
        }
        let writer = stores.writer
        syncTask = Task.detached(priority: .utility) { [weak self] in
            await TimelineSchemaUpgrader.waitUntilFinished()
            do {
                _ = try await MapTileBuilder.sync(
                    container: container,
                    database: writer,
                    onProgress: { [weak self] progress in await self?.setBuildProgress(progress) },
                    onCommit: { [weak self] summaries in await self?.tilesCommitted(summaries) }
                )
                await self?.syncFinished(revision: revision, container: container, failed: false)
            } catch is CancellationError {
                await self?.syncFinished(revision: nil, container: container, failed: false)
            } catch {
                MapCoverageController.log.error("tile sync failed: \(String(describing: error), privacy: .public)")
                await self?.syncFinished(revision: nil, container: container, failed: true)
            }
        }
    }

    private func setBuildProgress(_ progress: MapTileBuildProgress) {
        if buildProgress != progress { buildProgress = progress }
    }

    private func syncFinished(revision: Int?, container: ModelContainer, failed: Bool) {
        syncTask = nil
        guard let revision else { return }
        syncedRevision = revision
        lastSyncFinished = Date()
        if revision != wantedRevision, !isSuspended {
            // The store moved on while this ran; catch up after the usual breather.
            startSyncIfNeeded(container: container)
        }
    }

    /// New months are on disk: redraw what's on screen, at most about once a second while a long
    /// build commits month after month.
    private func tilesCommitted(_ summaries: [MapMonthSummary]) {
        adoptSummaries(summaries)
        guard !isSuspended, commitRedraw == nil else { return }
        let wait = max(0, 1.0 - Date().timeIntervalSince(lastCommitRedraw))
        commitRedraw = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.commitRedraw = nil
            self.lastCommitRedraw = Date()
            if let last = self.lastUpdate, !self.isSuspended { self.update(last, delay: .zero) }
        }
    }

    /// Plain values for a range's loose days, read once per range and store revision.
    private func looseData(for partial: [DateInterval], container: ModelContainer) async -> MapTileLooseData? {
        guard !partial.isEmpty else { return nil }
        let key = LooseKey(partial: partial, revision: wantedRevision)
        if let loose, loose.key == key { return loose.data }
        let data = await Task.detached(priority: .userInitiated) { () -> MapTileLooseData? in
            var values = MapTileSourceValues()
            for interval in partial {
                guard let part = try? MapTileSource.values(in: interval, overlapping: true, container: container) else { return nil }
                values.tracks += part.tracks
                values.stays += part.stays
            }
            return MapTileLooseData(values: values)
        }.value
        if let data { loose = (key, data) }
        return data
    }

    private func tileInput(for update: Update) async -> MapTileCompositor.Input? {
        await openTiles(container: update.container)
        guard let stores = tileStores else { return nil }
        let plan = MapTileRangePlan.make(interval: update.interval, isAllTime: update.isAllTime, includeUndated: update.includeUndated)
        let loose = await looseData(for: plan.partial, container: update.container)
        return MapTileCompositor.Input(database: stores.reader, plan: plan, loose: loose, modes: update.modes)
    }

    /// Whether every month a range touches has been built, so its counts can be trusted.
    func summariesCover(_ interval: DateInterval) -> Bool {
        guard !summaries.isEmpty else { return false }
        if buildProgress.isFinished || buildProgress.monthsToBuild <= buildProgress.monthsBuilt { return true }
        let calendar = Calendar.autoupdatingCurrent
        let built = Set(summaries.map(\.bucket))
        var month = MapTileBucket.month(containing: interval.start, calendar: calendar)
        let last = MapTileBucket.month(containing: min(interval.end, .now), calendar: calendar)
        while month <= last {
            if !built.contains(month) { return false }
            month = MapTileBucket.nextMonth(month)
        }
        return true
    }

    /// Trips and stays a range holds, from the month summaries: whole months exactly, loose days
    /// by their day counts. Cheap enough for every scrubber tick.
    private func summaryCounts(interval: DateInterval, modes: Set<TransportMode>?) -> (tracks: Int, stays: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let allowed = MapTileCompositor.allowedModes(modes)
        var tracks = 0.0, stays = 0
        for (summary, span) in zip(summaries, summarySpans) {
            guard span.end > interval.start, span.start < interval.end else { continue }
            let trips = summary.tripsByMode.enumerated().reduce(0) { $0 + (allowed[$1.offset] ? $1.element : 0) }
            if interval.start <= span.start, interval.end >= span.end {
                tracks += Double(trips)
                stays += summary.stays
                continue
            }
            let share = summary.trips > 0 ? Double(trips) / Double(summary.trips) : 0
            for day in 0..<31 {
                guard let start = calendar.date(byAdding: .day, value: day, to: span.start), start < span.end else { break }
                let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? start, span.end)
                guard end > interval.start, start < interval.end else { continue }
                tracks += Double(summary.dayTrips[day]) * share
                stays += summary.dayStays[day]
            }
        }
        return (Int(tracks.rounded()), stays)
    }

    /// The trip drawn closest to a tap, loaded by id with its full route.
    func trip(near point: MercatorPoint, tolerance: Double, mapPointsPerPoint: Double) async -> MapActivityTrack? {
        guard let update = lastUpdate else { return nil }
        guard Self.usesTiles else { return track(near: point, tolerance: tolerance) }
        guard let input = await tileInput(for: update) else { return nil }
        let container = update.container
        return await Task.detached(priority: .userInitiated) { () -> MapActivityTrack? in
            guard let id = MapTileCompositor.trip(near: point, tolerance: tolerance, mapPointsPerPoint: mapPointsPerPoint, input: input),
                  let track = try? MapTileSource.track(id: id, container: container) else { return nil }
            return MapActivityTrack(id: track.id, start: track.start, end: track.end, mode: track.mode,
                                    distanceMeters: track.distanceMeters, chunks: MapActivityIndex.chunks(for: track.points))
        }.value
    }

    init(tileDirectory: URL = MapTileDatabase.defaultDirectory) {
        self.tileDirectory = tileDirectory
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rasterCache.removeAll() }
        }
    }

    func rasterKey(for update: Update) -> RasterKey {
        RasterKey(
            layer: update.request.layer,
            interval: update.interval,
            modes: update.modes,
            includeUndated: update.includeUndated,
            level: MapCoverageRenderer.detailLevel(metersPerPoint: MapCoverageRenderer.metersPerPoint(for: update.request)),
            isDark: update.request.isDark,
            indexGeneration: indexGeneration,
            viewWidth: Double(update.request.viewSize.width),
            viewHeight: Double(update.request.viewSize.height)
        )
    }

    /// A finished bitmap for this layer, range, modes, zoom level, and appearance that already
    /// covers the viewport, if one is cached.
    func cachedRaster(for update: Update) -> MapCoverageRaster? {
        guard index != nil || tileStores != nil else { return nil }
        let key = rasterKey(for: update)
        let viewport = update.request.viewport
        guard let position = rasterCache.lastIndex(where: { entry in
            entry.key == key
                && entry.raster.bounds.minX <= viewport.minX && entry.raster.bounds.maxX >= viewport.maxX
                && entry.raster.bounds.minY <= viewport.minY && entry.raster.bounds.maxY >= viewport.maxY
        }) else { return nil }
        let entry = rasterCache.remove(at: position)
        rasterCache.append(entry)
        return entry.raster
    }

    func remember(_ raster: MapCoverageRaster, for key: RasterKey) {
        rasterCache.append((key, raster))
        var bytes = rasterCache.reduce(0) { $0 + $1.raster.image.bytesPerRow * $1.raster.image.height }
        while bytes > Self.rasterCacheBytes, rasterCache.count > 1 {
            let dropped = rasterCache.removeFirst()
            bytes -= dropped.raster.image.bytesPerRow * dropped.raster.image.height
        }
    }

    /// Shows a cached bitmap at once when one covers the camera; otherwise starts a render after
    /// `delay`, reusing the index unless the store changed. A stale index draws while a fresh one
    /// builds.
    /// True while the app is leaving the foreground: nothing new is built or drawn.
    private(set) var isSuspended = false

    /// Leaving the app must be instant: stop every build and render, and start nothing new.
    func suspend() {
        isSuspended = true
        renderTask?.cancel()
        renderTask = nil
        deferredBuild?.cancel()
        deferredBuild = nil
        indexTask?.cancel()
        syncTask?.cancel()
        commitRedraw?.cancel()
        commitRedraw = nil
    }

    /// Back in the foreground; the next update draws again.
    func resume() {
        isSuspended = false
    }

    /// Whether a render or deferred rebuild is queued.
    var hasQueuedWork: Bool {
        renderTask != nil || deferredBuild != nil
    }

    func update(_ update: Update, delay: Duration = .milliseconds(40)) {
        lastUpdate = update
        wantedRevision = update.revision
        renderTask?.cancel()
        renderTask = nil
        guard !isSuspended else { return }
        if let cached = cachedRaster(for: update) {
            if raster?.image !== cached.image {
                raster = cached
                rasterGeneration += 1
                MapPerformanceProbe.shared.layerDrawn(update.request.layer)
            }
            // A store change alone doesn't redraw: if the rebuilt index differs, adopting it
            // clears this cache and asks for a fresh bitmap.
            if Self.usesTiles {
                startSyncIfNeeded(container: update.container)
            } else if builtRevision != wantedRevision, indexTask == nil, deferredBuild == nil {
                Task { [weak self] in _ = await self?.currentIndex(container: update.container) }
            }
            return
        }
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.render(update)
        }
    }

    /// The trips and stays for a range and mode set, filtered once and kept while it repeats.
    private func subset(for update: Update, in index: MapActivityIndex) -> MapActivitySubset {
        let key = SubsetKey(generation: indexGeneration, interval: update.interval, modes: update.modes, includeUndated: update.includeUndated)
        if let subsetCache, subsetCache.key == key { return subsetCache.subset }
        let subset = index.subset(interval: update.interval, modes: update.modes, includeUndated: update.includeUndated)
        subsetCache = (key, subset)
        return subset
    }

    /// How many trips and stays a range draws, once the index is ready.
    func counts(interval: DateInterval, modes: Set<TransportMode>?) -> (tracks: Int, stays: Int)? {
        let key = SubsetKey(generation: indexGeneration, interval: interval, modes: modes, includeUndated: false)
        if let countsCache, countsCache.key == key { return countsCache.counts }
        if Self.usesTiles {
            guard summariesCover(interval) else { return nil }
            let counts = summaryCounts(interval: interval, modes: modes)
            countsCache = (key, counts)
            return counts
        }
        guard let index else { return nil }
        var tracks = 0, stays = 0
        for track in index.tracks where track.start < interval.end && track.end > interval.start && (modes?.contains(track.mode) ?? true) {
            tracks += 1
        }
        for stay in index.stays where stay.arrival < interval.end && stay.departure > interval.start {
            stays += 1
        }
        countsCache = (key, (tracks, stays))
        return (tracks, stays)
    }

    /// A region framing everything a range draws, from the index's chunk bounds.
    func region(interval: DateInterval, modes: Set<TransportMode>?) -> MKCoordinateRegion? {
        if Self.usesTiles {
            var bounds = MercatorRect.empty
            for (summary, span) in zip(summaries, summarySpans) {
                guard span.end > interval.start, span.start < interval.end, let b = summary.bounds, b.count == 4 else { continue }
                bounds.include(MercatorPoint(x: b[0], y: b[1]))
                bounds.include(MercatorPoint(x: b[2], y: b[3]))
            }
            guard !bounds.isEmpty else { return nil }
            return MapRegionFactory.region(for: [MercatorPoint(x: bounds.minX, y: bounds.minY).coordinate,
                                                 MercatorPoint(x: bounds.maxX, y: bounds.maxY).coordinate])
        }
        guard let index else { return nil }
        let subset = index.subset(interval: interval, modes: modes, includeUndated: false)
        var coordinates: [CLLocationCoordinate2D] = []
        for track in subset.tracks {
            for chunk in track.chunks where !chunk.bounds.isEmpty {
                coordinates.append(MercatorPoint(x: chunk.bounds.minX, y: chunk.bounds.minY).coordinate)
                coordinates.append(MercatorPoint(x: chunk.bounds.maxX, y: chunk.bounds.maxY).coordinate)
            }
        }
        coordinates += subset.stays.map(\.point.coordinate)
        guard !coordinates.isEmpty else { return nil }
        return MapRegionFactory.region(for: coordinates)
    }

    /// The trip drawn closest to `point` in the current range, within `tolerance` map points.
    func track(near point: MercatorPoint, tolerance: Double) -> MapActivityTrack? {
        guard let index, let update = lastUpdate else { return nil }
        return subset(for: update, in: index).nearestTrack(to: point, within: tolerance)
    }

    private func render(_ update: Update) async {
        if Self.usesTiles {
            await renderTiles(update)
            return
        }
        guard let index = await currentIndex(container: update.container) else { return }
        guard !Task.isCancelled, !isSuspended else { return }
        let subset = subset(for: update, in: index)
        let key = rasterKey(for: update)
        let request = update.request
        let work = Task.detached(priority: .userInitiated) {
            try MapCoverageRenderer.render(subset, request: request)
        }
        let result = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, !isSuspended, let result else { return }
        raster = result
        rasterGeneration += 1
        MapPerformanceProbe.shared.layerDrawn(request.layer)
        if key.indexGeneration == indexGeneration { remember(result, for: key) }
        Self.log.notice("\(request.layer.rawValue, privacy: .public) render \(result.renderMilliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(subset.tracks.count, privacy: .public) tracks, \(subset.stays.count, privacy: .public) stays")
    }

    private func renderTiles(_ update: Update) async {
        guard let input = await tileInput(for: update) else { return }
        startSyncIfNeeded(container: update.container)
        guard !Task.isCancelled, !isSuspended else { return }
        let key = rasterKey(for: update)
        let request = update.request
        let work = Task.detached(priority: .userInitiated) {
            try MapTileCompositor.render(request, input: input)
        }
        let result = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, !isSuspended, let result else { return }
        raster = result
        rasterGeneration += 1
        MapPerformanceProbe.shared.layerDrawn(request.layer)
        if key.indexGeneration == indexGeneration { remember(result, for: key) }
        Self.log.notice("\(request.layer.rawValue, privacy: .public) tile render \(result.renderMilliseconds, format: .fixed(precision: 1), privacy: .public) ms, buckets \(input.plan.buckets.count, privacy: .public), loose \(input.plan.partial.count, privacy: .public)")
    }

    /// Makes sure an index is available before the tab decides how to draw a range: the saved
    /// copy if there is one, otherwise the first build. Off the main thread either way.
    func prepare(container: ModelContainer) async {
        if Self.usesTiles {
            await openTiles(container: container)
            startSyncIfNeeded(container: container)
            return
        }
        _ = await currentIndex(container: container)
    }

    /// Records a store change, so the next update brings the tiles up to date.
    func noteRevision(_ revision: Int, container: ModelContainer) {
        wantedRevision = revision
        startSyncIfNeeded(container: container)
    }

    /// The index for the newest revision if it is ready; otherwise the saved copy from the last
    /// launch, or the last one built, while a rebuild runs and re-renders when it lands.
    private func currentIndex(container: ModelContainer) async -> MapActivityIndex? {
        if index == nil, !hasTriedSavedIndex {
            hasTriedSavedIndex = true
            await loadSavedIndex(container: container)
        }
        if builtRevision != wantedRevision, indexTask == nil, !isSuspended {
            if index != nil, let finished = lastBuildFinished, Date().timeIntervalSince(finished) < Self.minimumRebuildInterval {
                scheduleDeferredBuild(container: container, after: Self.minimumRebuildInterval - Date().timeIntervalSince(finished))
            } else {
                startIndexBuild(container: container)
            }
        }
        if let index { return index }
        guard let indexTask else { return nil }
        _ = try? await indexTask.value
        return index
    }

    private func loadSavedIndex(container: ModelContainer) async {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let signature = MapActivityIndexCache.signature(for: container) else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (index: MapActivityIndex, isFresh: Bool)? in
            // A copy saved for another store (another account or a test store) is never shown.
            guard var saved = MapActivityIndexCache.load(),
                  saved.signature.split(separator: "|").first == signature.split(separator: "|").first else { return nil }
            saved.index.undatedCoverage = (try? MapActivityIndexBuilder.undatedCoverageChunks(from: FogCoverageArchive.load())) ?? []
            saved.index.fingerprint = saved.index.computedFingerprint()
            return (saved.index, saved.signature == signature)
        }.value
        guard let loaded, index == nil else { return }
        adopt(loaded.index)
        if loaded.isFresh { builtRevision = wantedRevision }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Self.log.notice("saved index loaded in \(elapsed, format: .fixed(precision: 1), privacy: .public) ms, \(loaded.isFresh ? "fresh" : "stale", privacy: .public): \(loaded.index.tracks.count, privacy: .public) tracks, \(loaded.index.stays.count, privacy: .public) stays")
    }

    func adopt(_ built: MapActivityIndex) {
        index = built
        indexGeneration += 1
        latestActivity = built.latestActivity
        loadFailed = false
        subsetCache = nil
        rasterCache.removeAll()
    }

    /// Saves to trips arrive in bursts while background work runs; rebuild at most this often
    /// while an index is already showing.
    static let minimumRebuildInterval: TimeInterval = 30

    private func scheduleDeferredBuild(container: ModelContainer, after delay: TimeInterval) {
        guard deferredBuild == nil else { return }
        deferredBuild = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(delay, 0.1)))
            guard let self, !Task.isCancelled else { return }
            self.deferredBuild = nil
            if Self.usesTiles {
                self.lastSyncFinished = nil
                self.startSyncIfNeeded(container: container)
            } else if self.builtRevision != self.wantedRevision, self.indexTask == nil {
                self.startIndexBuild(container: container)
            }
        }
    }

    private func startIndexBuild(container: ModelContainer) {
        let revision = wantedRevision
        Self.log.notice("index build for revision \(revision, privacy: .public)")
        if !hasCheckedVisitedCells {
            // Visited cells are a derived cache; this rebuilds them once per `builtVersion`.
            hasCheckedVisitedCells = true
            Task { try? await VisitedCellStore.ensureBuilt(container: container) }
        }
        let signature = MapActivityIndexCache.signature(for: container)
        let task = Task.detached(priority: .userInitiated) { () throws -> MapActivityIndex in
            await TimelineSchemaUpgrader.waitUntilFinished()
            let started = DispatchTime.now().uptimeNanoseconds
            let built = try MapActivityIndexBuilder.build(container: container)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Self.log.notice("index built in \(elapsed, format: .fixed(precision: 1), privacy: .public) ms: \(built.tracks.count, privacy: .public) tracks, \(built.stays.count, privacy: .public) stays, \(built.pointCount, privacy: .public) points, \(built.excludedTripCount, privacy: .public) implausible trips left out")
            if let signature {
                try? MapActivityIndexCache.save(built, signature: signature)
            }
            return built
        }
        indexTask = task
        Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            self.indexTask = nil
            switch result {
            case .success(let built):
                self.lastBuildFinished = Date()
                let hadIndex = self.index != nil
                let unchanged = hadIndex && self.index?.fingerprint == built.fingerprint
                if !unchanged {
                    // A rebuild with the same trips, stays, and geometry keeps the current
                    // index, bitmaps, and caches; nothing on screen would change.
                    self.adopt(built)
                }
                self.builtRevision = revision
                if hadIndex, !unchanged, let last = self.lastUpdate {
                    self.update(last, delay: .zero)
                }
                if revision != self.wantedRevision {
                    // The store moved on while this built. Catch up after a breather.
                    try? await Task.sleep(for: .seconds(2))
                    if self.indexTask == nil, let last = self.lastUpdate {
                        self.startIndexBuild(container: last.container)
                    }
                }
            case .failure(let error):
                // Cancelled on the way to the background: build again once back.
                guard !(error is CancellationError) else { return }
                Self.log.error("index build failed: \(String(describing: error), privacy: .public)")
                self.loadFailed = self.index == nil
            }
        }
    }
}

/// The camera as it moves. Only the bitmap overlay reads it, so a pan redraws the overlay's
/// position and nothing else on the Map tab.
@Observable
@MainActor
final class MapCameraState {
    var rect: MercatorRect?
}

/// Places the current bitmap over the map so it pans and zooms with the camera. Fog keeps its
/// veil past the bitmap's edges, and a soft clearing keeps the location dot readable.
struct MapCoverageOverlay: View {
    /// Read here rather than by the tab, so a new bitmap redraws only this overlay.
    let controller: MapCoverageController
    let layer: MapCoverageLayer
    let cameraState: MapCameraState
    let userLocation: CLLocationCoordinate2D?
    let isDark: Bool
    /// A trip drawn above the Routes bitmap, as selected.
    var highlight: MapActivityTrack?

    var body: some View {
        MapCoverageOverlayContent(
            raster: controller.raster,
            layer: layer,
            camera: cameraState.rect,
            userLocation: userLocation,
            isDark: isDark,
            highlight: highlight
        )
    }
}

private struct MapCoverageOverlayContent: View {
    let raster: MapCoverageRaster?
    let layer: MapCoverageLayer
    let camera: MercatorRect?
    let userLocation: CLLocationCoordinate2D?
    let isDark: Bool
    let highlight: MapActivityTrack?

    private static let clearingRadius: CGFloat = 15

    private func highlightPath(in size: CGSize) -> Path? {
        guard let highlight, let camera, camera.width > 0, camera.height > 0 else { return nil }
        let sx = size.width / camera.width, sy = size.height / camera.height
        let shift = 0.0
        var path = Path()
        for chunk in highlight.chunks {
            guard let first = chunk.points.first else { continue }
            path.move(to: CGPoint(x: (first.x + shift - camera.minX) * sx, y: (first.y - camera.minY) * sy))
            for point in chunk.points.dropFirst() {
                path.addLine(to: CGPoint(x: (point.x + shift - camera.minX) * sx, y: (point.y - camera.minY) * sy))
            }
        }
        return path
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if layer == .fog {
                    let veil = MapCoverageRenderer.veilColor(isDark: isDark)
                    let color = Color(.sRGB, red: veil.red, green: veil.green, blue: veil.blue, opacity: veil.alpha)
                    if let frame = imageFrame(in: size) {
                        // Veil beyond the bitmap, shown only if the camera outruns it.
                        ForEach(Array(outsideRects(frame, size: size).enumerated()), id: \.offset) { _, rect in
                            color.frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        }
                    } else {
                        color
                    }
                }
                if let raster = shownRaster, let frame = imageFrame(in: size) {
                    Image(decorative: raster.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if let highlight, let path = highlightPath(in: size) {
                    path.stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    path.stroke(MovesPalette.transport(highlight.mode), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                }
                if let dot = userPoint(in: size) {
                    // Just the dot's own footprint, so it reads above the layer without a ring.
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                             center: .center, startRadius: 0, endRadius: Self.clearingRadius))
                        .frame(width: Self.clearingRadius * 2, height: Self.clearingRadius * 2)
                        .offset(x: dot.x - Self.clearingRadius, y: dot.y - Self.clearingRadius)
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shownRaster: MapCoverageRaster? {
        guard let raster, raster.layer == layer, raster.isDark == isDark else { return nil }
        return raster
    }

    private func imageFrame(in size: CGSize) -> CGRect? {
        guard let raster = shownRaster, let camera, camera.width > 0, camera.height > 0 else { return nil }
        let sx = size.width / camera.width
        let sy = size.height / camera.height
        return CGRect(
            x: (raster.bounds.minX - camera.minX) * sx,
            y: (raster.bounds.minY - camera.minY) * sy,
            width: raster.bounds.width * sx,
            height: raster.bounds.height * sy
        )
    }

    private func outsideRects(_ frame: CGRect, size: CGSize) -> [CGRect] {
        let screen = CGRect(origin: .zero, size: size)
        guard !frame.contains(screen) else { return [] }
        let clipped = frame.intersection(screen)
        guard !clipped.isNull, !clipped.isEmpty else { return [screen] }
        return [
            CGRect(x: 0, y: 0, width: size.width, height: clipped.minY),
            CGRect(x: 0, y: clipped.maxY, width: size.width, height: size.height - clipped.maxY),
            CGRect(x: 0, y: clipped.minY, width: clipped.minX, height: clipped.height),
            CGRect(x: clipped.maxX, y: clipped.minY, width: size.width - clipped.maxX, height: clipped.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private func userPoint(in size: CGSize) -> CGPoint? {
        guard let userLocation, let camera, camera.width > 0, CLLocationCoordinate2DIsValid(userLocation) else { return nil }
        let point = MercatorPoint(userLocation)
        let x = (point.x - camera.minX) / camera.width * size.width
        let y = (point.y - camera.minY) / camera.height * size.height
        guard x > -40, y > -40, x < size.width + 40, y < size.height + 40 else { return nil }
        return CGPoint(x: x, y: y)
    }
}
