import SwiftUI

/// Country outlines in Equal Earth, ready to draw. Equal Earth keeps every country at its
/// true size next to the others, so Greenland does not outweigh Africa.
///
/// Map space: x runs 0…1 across the world, y grows downward at the same scale.
struct WorldMapGeometry: Sendable {
    struct Country: Sendable {
        let code: String
        /// Simplified for the whole world at phone size.
        let outline: Path
        /// Everything the bundled borders hold, for zooming in.
        let fullOutline: Path
        let bounds: CGRect
        /// The country's largest piece; what a tiny marker and a zoom center on.
        let mainBounds: CGRect
    }

    static let aspectRatio = CGFloat(bounds.width / bounds.height)

    /// The world without Antarctica.
    static let bounds: CGRect = {
        let top = project(longitude: centralMeridian, latitude: 83.7).y
        let bottom = project(longitude: centralMeridian, latitude: -56).y
        return CGRect(x: 0, y: top, width: 1, height: bottom - top)
    }()

    /// Built once, off the main actor.
    private static let building = Task.detached(priority: .userInitiated) { WorldMapGeometry.build() }
    static func load() async -> WorldMapGeometry? { await building.value }

    let countries: [Country]

    /// The country under a point, or the marked country whose dot is within `slop`.
    func country(at point: CGPoint, slop: CGFloat, marked: Set<String>) -> Country? {
        if let hit = countries.first(where: { $0.bounds.contains(point) && $0.fullOutline.contains(point, eoFill: true) }) {
            return hit
        }
        return countries
            .filter { marked.contains($0.code) }
            .map { ($0, hypot($0.mainBounds.midX - point.x, $0.mainBounds.midY - point.y)) }
            .filter { $0.1 <= slop }
            .min { $0.1 < $1.1 }?.0
    }

    /// A viewport around the given countries' main pieces, with room to breathe.
    func viewport(around codes: Set<String>) -> CGRect {
        let frames = countries.filter { codes.contains($0.code) }.map(\.mainBounds)
        guard let first = frames.first else { return Self.bounds }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let width = max(union.width * 1.25, union.height * 1.25 * Self.aspectRatio, 0.12)
        let size = CGSize(width: width, height: width / Self.aspectRatio)
        return Self.clamped(CGRect(
            x: union.midX - size.width / 2,
            y: union.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    /// Keeps a viewport inside the world and no closer than `maximumZoom`.
    static func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, bounds.width / maximumZoom), bounds.width)
        let height = width / aspectRatio
        return CGRect(
            x: min(max(rect.midX - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max(rect.midY - height / 2, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    static let maximumZoom: CGFloat = 16

    // MARK: - Projection

    /// Chosen so the map's edge falls in the Bering Strait and splits no country.
    private static let centralMeridian = 11.0
    private static let halfWidth = equalEarth(longitude: 180, latitude: 0).x

    static func project(longitude: Double, latitude: Double) -> CGPoint {
        let point = equalEarth(longitude: longitude - centralMeridian, latitude: latitude)
        return CGPoint(x: 0.5 + point.x / (2 * halfWidth), y: -point.y / (2 * halfWidth))
    }

    /// Longitude counted from the map's left edge, so nothing wraps.
    static func projectWrapping(longitude: Double, latitude: Double) -> CGPoint {
        project(longitude: longitude < centralMeridian - 180 ? longitude + 360 : longitude, latitude: latitude)
    }

    private static func equalEarth(longitude: Double, latitude: Double) -> (x: Double, y: Double) {
        let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796
        let root3 = 3.0.squareRoot()
        let theta = asin(root3 / 2 * sin(latitude * .pi / 180))
        let t2 = theta * theta
        let t6 = t2 * t2 * t2
        let x = 2 * root3 * (longitude * .pi / 180) * cos(theta)
            / (3 * (9 * a4 * t6 * t2 + 7 * a3 * t6 + 3 * a2 * t2 + a1))
        let y = theta * (a4 * t6 * t2 + a3 * t6 + a2 * t2 + a1)
        return (x, y)
    }

    // MARK: - Building

    /// About half a pixel with the whole world on a phone.
    private static let tolerance = 0.0005

    private static func build() -> WorldMapGeometry? {
        guard let polygons = OfflineVisitGeography.resolver?.polygonsByCountry() else { return nil }
        let countries = polygons.compactMap { code, pieces -> Country? in
            // Disputed slivers have no code of their own, and Antarctica is off the map.
            guard code.count == 2, code != "AQ" else { return nil }
            var outline = Path()
            var fullOutline = Path()
            var bounds = CGRect.null
            var mainBounds = CGRect.null
            for piece in pieces {
                // The few pieces past the Bering Strait join the right edge.
                let isWrapped = piece.first.map { ring in ring.allSatisfy { $0[0] < centralMeridian - 180 + 0.5 } } ?? false
                for (index, ring) in piece.enumerated() where ring.count >= 4 {
                    let points = ring.map { project(longitude: isWrapped ? $0[0] + 360 : $0[0], latitude: $0[1]) }
                    fullOutline.addLines(points)
                    fullOutline.closeSubpath()
                    let frame = frame(of: points)
                    if index == 0 {
                        bounds = bounds.union(frame)
                        if mainBounds.isNull || frame.width * frame.height > mainBounds.width * mainBounds.height {
                            mainBounds = frame
                        }
                    }
                    // Islands under a pixel only add noise at world size.
                    guard max(frame.width, frame.height) > tolerance * 2 else { continue }
                    let simple = simplified(points)
                    guard simple.count >= 3 else { continue }
                    outline.addLines(simple)
                    outline.closeSubpath()
                }
            }
            guard !bounds.isNull else { return nil }
            return Country(code: code, outline: outline, fullOutline: fullOutline, bounds: bounds, mainBounds: mainBounds)
        }
        return WorldMapGeometry(countries: countries.sorted { $0.code < $1.code })
    }

    private static func frame(of points: [CGPoint]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Douglas–Peucker.
    private static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 4 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        // A closed ring starts and ends on one point; its far side splits it in two.
        let far = points.indices.max {
            hypot(points[$0].x - points[0].x, points[$0].y - points[0].y)
                < hypot(points[$1].x - points[0].x, points[$1].y - points[0].y)
        } ?? points.count / 2
        keep[far] = true
        var stack = [(0, far), (far, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), .leastNonzeroMagnitude)
            var worst = start, distance = CGFloat(0)
            for index in (start + 1)..<end {
                let offset = abs(dy * (points[index].x - a.x) - dx * (points[index].y - a.y)) / length
                if offset > distance { distance = offset; worst = index }
            }
            if distance > tolerance {
                keep[worst] = true
                stack.append((start, worst))
                stack.append((worst, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

/// What the map shows: which countries stand out, and any city dots.
struct WorldMapContent: Equatable {
    struct Dot: Equatable, Sendable {
        let point: CGPoint
        let weight: CGFloat
    }

    /// Countries of the chosen period.
    var visited: Set<String> = []
    /// Countries from other years, drawn fainter.
    var visitedBefore: Set<String> = []
    var selected: String?
    /// With dots, countries step back to a tint so the dots carry the map.
    var dots: [Dot] = []
}

/// The world, drawn. Visited countries are solid and the rest are dimmed.
struct WorldMapCanvas: View, Animatable, Equatable {
    let geometry: WorldMapGeometry
    let content: WorldMapContent
    var viewport: CGRect = WorldMapGeometry.bounds

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(viewport.origin.x, viewport.origin.y), .init(viewport.width, viewport.height)) }
        set {
            viewport = CGRect(
                x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second
            )
        }
    }

    /// Redrawing every outline is the costliest thing on the page, so the map draws again
    /// only when what it shows changes. The geometry is built once per launch.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewport == rhs.viewport
            && lhs.content == rhs.content
            && lhs.geometry.countries.count == rhs.geometry.countries.count
    }

    /// Smaller than this on screen, a visited country gets a dot so it can be seen.
    private static let smallestVisible: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let scale = size.width / viewport.width
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -viewport.minX, y: -viewport.minY)
            let showsDetail = viewport.width < WorldMapGeometry.bounds.width * 0.6
            let border = GraphicsContext.Shading.color(MovesPalette.backgroundTop)

            var map = context
            map.concatenate(transform)
            var markers: [(CGPoint, Color)] = []
            for country in geometry.countries where country.bounds.intersects(viewport) {
                let path = showsDetail ? country.fullOutline : country.outline
                map.fill(path, with: .color(fill(country.code)), style: FillStyle(eoFill: true))
                map.stroke(path, with: border, lineWidth: (showsDetail ? 0.5 : 0.4) / scale)
                let isMarked = content.visited.contains(country.code) || content.visitedBefore.contains(country.code)
                if isMarked, max(country.mainBounds.width, country.mainBounds.height) * scale < Self.smallestVisible {
                    let center = CGPoint(x: country.mainBounds.midX, y: country.mainBounds.midY).applying(transform)
                    markers.append((center, fill(country.code)))
                }
            }
            if let selected = geometry.countries.first(where: { $0.code == content.selected }) {
                // Thin, or the line would cover a small country it is meant to point out.
                map.stroke(
                    selected.fullOutline,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: (showsDetail ? 1 : 0.6) / scale, lineJoin: .round)
                )
            }
            for (center, color) in markers {
                let frame = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: frame), with: .color(color))
                context.stroke(Path(ellipseIn: frame), with: border, lineWidth: 1)
            }
            for dot in content.dots {
                let center = dot.point.applying(transform)
                let radius = 2 + 2.5 * dot.weight
                let frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: frame), with: .color(MovesPalette.place))
                context.stroke(Path(ellipseIn: frame), with: border, lineWidth: 0.75)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(_ code: String) -> Color {
        if content.visited.contains(code) {
            return content.dots.isEmpty ? MovesPalette.place : MovesPalette.place.opacity(0.42)
        }
        if content.visitedBefore.contains(code) {
            return MovesPalette.place.opacity(content.dots.isEmpty ? 0.42 : 0.2)
        }
        return Color(uiColor: .systemGray4)
    }
}

/// The map with touch: pinch, drag, double-tap to zoom, and tap a country to pick it.
struct WorldMapView: View {
    let geometry: WorldMapGeometry
    let content: WorldMapContent
    @Binding var viewport: CGRect
    var onSelect: (String?) -> Void

    @GestureState private var panStart: CGRect?
    @GestureState private var pinchStart: CGRect?
    /// A pinch also moves like a drag; the drag sits out until the fingers lift.
    @State private var isPanSuspended = false

    private var isZoomed: Bool { viewport.width < WorldMapGeometry.bounds.width * 0.98 }

    var body: some View {
        GeometryReader { proxy in
            WorldMapCanvas(geometry: geometry, content: content, viewport: viewport)
                .equatable()
                .contentShape(Rectangle())
                .gesture(tap(in: proxy.size))
                .gesture(pan(in: proxy.size), isEnabled: isZoomed)
                .simultaneousGesture(pinch(in: proxy.size))
        }
        .aspectRatio(WorldMapGeometry.aspectRatio, contentMode: .fit)
        .clipped()
    }

    private func tap(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let point = mapPoint(value.location, in: size)
                withAnimation(.smooth(duration: 0.35)) {
                    viewport = isZoomed && viewport.width < WorldMapGeometry.bounds.width / 8
                        ? WorldMapGeometry.bounds
                        : zoomed(from: viewport, by: 2.5, around: point)
                }
            }
            .exclusively(before: SpatialTapGesture().onEnded { value in
                let point = mapPoint(value.location, in: size)
                let slop = 16 / size.width * viewport.width
                onSelect(geometry.country(
                    at: point,
                    slop: slop,
                    marked: content.visited.union(content.visitedBefore)
                )?.code)
            })
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($panStart) { _, start, _ in start = start ?? viewport }
            .onChanged { value in
                guard !isPanSuspended else { return }
                let start = panStart ?? viewport
                let scale = start.width / size.width
                viewport = WorldMapGeometry.clamped(start.offsetBy(
                    dx: -value.translation.width * scale,
                    dy: -value.translation.height * scale
                ))
            }
            .onEnded { _ in isPanSuspended = false }
    }

    private func pinch(in size: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .updating($pinchStart) { _, start, _ in start = start ?? viewport }
            .onChanged { value in
                isPanSuspended = panStart != nil
                let start = pinchStart ?? viewport
                let anchor = CGPoint(
                    x: start.minX + value.startAnchor.x * start.width,
                    y: start.minY + value.startAnchor.y * start.height
                )
                viewport = zoomed(from: start, by: value.magnification, around: anchor)
            }
    }

    private func mapPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: viewport.minX + location.x / size.width * viewport.width,
            y: viewport.minY + location.y / size.height * viewport.height
        )
    }

    /// Zooms so the map under `anchor` stays under the finger.
    private func zoomed(from rect: CGRect, by factor: CGFloat, around anchor: CGPoint) -> CGRect {
        let width = min(
            max(rect.width / max(factor, 0.01), WorldMapGeometry.bounds.width / WorldMapGeometry.maximumZoom),
            WorldMapGeometry.bounds.width
        )
        let ratio = width / rect.width
        return WorldMapGeometry.clamped(CGRect(
            x: anchor.x - (anchor.x - rect.minX) * ratio,
            y: anchor.y - (anchor.y - rect.minY) * ratio,
            width: width,
            height: width / WorldMapGeometry.aspectRatio
        ))
    }
}
