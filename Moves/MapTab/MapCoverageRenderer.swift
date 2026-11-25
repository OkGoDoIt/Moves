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
    /// Heat kernel radius on screen, whatever the zoom: where a single trip fades out.
    static let heatRadiusPoints = 20.0
    /// The Gaussian behind it; at 2.5 sigma a lone line is down to a few percent.
    static var heatSigmaPoints: Double { heatRadiusPoints / 2.5 }
    /// Fog reveals this much ground around every route and stay…
    static let fogGroundRadiusMeters = 180.0
    /// …but never less than this on screen, so a day's outing shows at any zoom.
    static let fogMinimumRadiusPoints = 12.0
    static let fogMaximumRadiusPoints = 150.0
    /// Feather as a share of the reveal radius.
    static let fogFeather = 0.42
    /// Each side of the bitmap reaches this share of the viewport past the screen edge.
    static let paddingFraction = 0.5
    static let maximumPixelsPerPoint = 0.75
    static let pixelBudget = 700_000.0
    /// Blur sigma, in pixels, beyond which resolution drops; a softer image doesn't need more.
    static let maximumSigmaPixels = 16.0
    /// One hour at a stay weighs as much as half a pass along a route, up to this many hours.
    static let stayHoursCap = 12.0
    static let stayPassesPerHour = 0.5

    static func veilColor(isDark: Bool) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        isDark ? (0.0, 0.01, 0.03, 0.66) : (0.13, 0.15, 0.19, 0.58)
    }

    static func fogRadiusPoints(metersPerPoint: Double) -> Double {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return fogMinimumRadiusPoints }
        return min(max(fogGroundRadiusMeters / metersPerPoint, fogMinimumRadiusPoints), fogMaximumRadiusPoints)
    }

    static func geometry(for request: MapCoverageRenderRequest, blurSigmaPoints: Double) -> MapRasterGeometry? {
        let viewport = request.viewport
        guard viewport.width > 0, viewport.height > 0,
              request.viewSize.width > 1, request.viewSize.height > 1 else { return nil }
        let pointsPerMapPoint = Double(request.viewSize.width) / viewport.width
        let padX = viewport.width * paddingFraction
        let padY = viewport.height * paddingFraction
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
            return nil
        case .heat:
            guard let geometry = geometry(for: request, blurSigmaPoints: heatSigmaPoints) else { return nil }
            image = try renderHeat(subset, geometry: geometry, isDark: request.isDark)
            bounds = geometry.bounds
        case .fog:
            let probe = geometry(for: request, blurSigmaPoints: fogMinimumRadiusPoints * fogFeather)
            guard let probe else { return nil }
            let radius = fogRadiusPoints(metersPerPoint: probe.metersPerPoint)
            guard let geometry = geometry(for: request, blurSigmaPoints: radius * fogFeather) else { return nil }
            image = try renderFog(subset, geometry: geometry, radiusPoints: radius, isDark: request.isDark)
            bounds = geometry.bounds
        }
        guard let image else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return MapCoverageRaster(image: image, bounds: bounds, layer: request.layer, isDark: request.isDark, renderMilliseconds: elapsed)
    }

    // MARK: Heat

    /// Density in "passes": one trip along a line reads as about 1 at its centre.
    static func heatDensity(_ subset: MapActivitySubset, geometry: MapRasterGeometry) throws -> [Float] {
        let width = geometry.width, height = geometry.height
        let sigma = heatSigmaPoints * geometry.pixelsPerPoint
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

            for track in subset.tracks {
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

    /// Reveal mask, 0 (fogged) to 1 (seen), feathered.
    static func fogMask(_ subset: MapActivitySubset, geometry: MapRasterGeometry, radiusPoints: Double) throws -> [Float] {
        let width = geometry.width, height = geometry.height
        let radius = radiusPoints * geometry.pixelsPerPoint
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [Float](repeating: 0, count: width * height) }
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
        for track in subset.tracks where track.mode != .plane {
            // A flight is travel, not ground explored.
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
        for chunk in subset.undatedCoverage {
            try Task.checkCancellation()
            for shift in MapRasterGeometry.worldOffsets(for: chunk.bounds, in: cull) {
                for point in chunk.points {
                    disc(point, radius: radius, offset: shift)
                }
            }
        }
        context.fillPath()

        guard let data = context.data else { return [Float](repeating: 0, count: width * height) }
        var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: context.bytesPerRow)
        var mask = [Float](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { raw in
            var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageConvert_Planar8toPlanarF(&source, &destination, 1, 0, vImage_Flags(kvImageNoFlags))
        }
        gaussianBlur(&mask, width: width, height: height, sigma: radius * fogFeather)
        return mask
    }

    static func renderFog(_ subset: MapActivitySubset, geometry: MapRasterGeometry, radiusPoints: Double, isDark: Bool) throws -> CGImage? {
        let mask = try fogMask(subset, geometry: geometry, radiusPoints: radiusPoints)
        try Task.checkCancellation()
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
    private(set) var latestActivity: CLLocationCoordinate2D?
    private(set) var loadFailed = false

    @ObservationIgnored private var index: MapActivityIndex?
    @ObservationIgnored private var builtRevision: Int?
    @ObservationIgnored private var wantedRevision = 0
    @ObservationIgnored private var indexTask: Task<MapActivityIndex, Error>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var subsetCache: (key: SubsetKey, subset: MapActivitySubset)?
    @ObservationIgnored private var lastUpdate: Update?
    @ObservationIgnored private var hasCheckedVisitedCells = false
    nonisolated private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "MapCoverage")

    private struct SubsetKey: Equatable {
        let revision: Int
        let interval: DateInterval
        let modes: Set<TransportMode>?
        let includeUndated: Bool
        let layer: MapCoverageLayer
    }

    struct Update {
        var container: ModelContainer
        var revision: Int
        var request: MapCoverageRenderRequest
        var interval: DateInterval
        var modes: Set<TransportMode>?
        var includeUndated: Bool
    }

    /// Starts a render for the current camera and range after `delay`, reusing the index unless
    /// the store changed. A stale index draws while a fresh one builds.
    func update(_ update: Update, delay: Duration = .milliseconds(80)) {
        lastUpdate = update
        wantedRevision = update.revision
        renderTask?.cancel()
        guard update.request.layer != .routes else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.render(update)
        }
    }

    private func render(_ update: Update) async {
        guard let index = await currentIndex(container: update.container) else { return }
        guard !Task.isCancelled else { return }
        let key = SubsetKey(
            revision: builtRevision ?? -1,
            interval: update.interval,
            modes: update.modes,
            includeUndated: update.includeUndated,
            layer: update.request.layer
        )
        let subset: MapActivitySubset
        if let subsetCache, subsetCache.key == key {
            subset = subsetCache.subset
        } else {
            subset = index.subset(interval: update.interval, modes: update.modes, includeUndated: update.includeUndated)
            subsetCache = (key, subset)
        }
        let request = update.request
        let work = Task.detached(priority: .userInitiated) {
            try MapCoverageRenderer.render(subset, request: request)
        }
        let result = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let result else { return }
        raster = result
        Self.log.notice("\(request.layer.rawValue, privacy: .public) render \(result.renderMilliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(subset.tracks.count, privacy: .public) tracks, \(subset.stays.count, privacy: .public) stays")
    }

    /// The index for the newest revision if it is ready; otherwise the last one while a rebuild
    /// runs, which re-renders when it lands. Waits only when there is none at all.
    private func currentIndex(container: ModelContainer) async -> MapActivityIndex? {
        if builtRevision != wantedRevision, indexTask == nil {
            startIndexBuild(container: container)
        }
        if let index { return index }
        guard let indexTask else { return nil }
        _ = try? await indexTask.value
        return index
    }

    private func startIndexBuild(container: ModelContainer) {
        let revision = wantedRevision
        Self.log.notice("index build for revision \(revision, privacy: .public)")
        if !hasCheckedVisitedCells {
            // Visited cells are a derived cache; this rebuilds them once per `builtVersion`.
            hasCheckedVisitedCells = true
            Task { try? await VisitedCellStore.ensureBuilt(container: container) }
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> MapActivityIndex in
            await TimelineSchemaUpgrader.waitUntilFinished()
            let started = DispatchTime.now().uptimeNanoseconds
            let built = try MapActivityIndexBuilder.build(container: container)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Self.log.notice("index built in \(elapsed, format: .fixed(precision: 1), privacy: .public) ms: \(built.tracks.count, privacy: .public) tracks, \(built.stays.count, privacy: .public) stays, \(built.pointCount, privacy: .public) points")
            return built
        }
        indexTask = task
        Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            self.indexTask = nil
            switch result {
            case .success(let built):
                let hadIndex = self.index != nil
                self.index = built
                self.builtRevision = revision
                self.latestActivity = built.latestActivity
                self.loadFailed = false
                self.subsetCache = nil
                if revision != self.wantedRevision {
                    // The store moved on while this built. Catch up after a breather.
                    try? await Task.sleep(for: .seconds(2))
                    if self.indexTask == nil, let last = self.lastUpdate {
                        self.startIndexBuild(container: last.container)
                    }
                } else if hadIndex, let last = self.lastUpdate {
                    self.update(last, delay: .zero)
                }
            case .failure(let error):
                Self.log.error("index build failed: \(String(describing: error), privacy: .public)")
                self.loadFailed = self.index == nil
            }
        }
    }
}

/// Places the current bitmap over the map so it pans and zooms with the camera. Fog keeps its
/// veil past the bitmap's edges, and a soft clearing keeps the location dot readable.
struct MapCoverageOverlay: View {
    let raster: MapCoverageRaster?
    let layer: MapCoverageLayer
    let camera: MercatorRect?
    let userLocation: CLLocationCoordinate2D?
    let isDark: Bool

    private static let clearingRadius: CGFloat = 15

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
