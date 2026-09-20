import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

/// UserDefaults keys for map route appearance. Snapping controls belong to WS4.
enum MapRouteShadingSettings {
    static let shadeRoutesBySpeedKey = "map.shadeRoutesBySpeed"
}

/// MapKit-for-SwiftUI gradient quirks (verified Sep 2026): use a plain `Gradient`
/// (not `LinearGradient`); keep every stop opaque; cap stops at 16.
enum RouteGradientRendering {
    static let maximumStopCount = 16

    /// Feature flag for a future `MKGradientPolylineRenderer` path if SwiftUI
    /// gradient polylines lag on pan/zoom. Default stays on the SwiftUI path.
    static var usesMapKitRendererFallback: Bool {
        UserDefaults.standard.bool(forKey: "map.useMKGradientPolylineRenderer")
    }
}

extension MovesPalette {
    /// Approximate standard map canvas used to pre-blend "75% opacity" states
    /// into opaque colours (MapKit renders translucent gradient stops as a
    /// single solid colour).
    static var mapCanvas: Color {
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
            }
            return UIColor(red: 0.94, green: 0.93, blue: 0.90, alpha: 1)
        })
    }

    /// Mixes `color` toward the map canvas so the result stays fully opaque.
    static func opaqueRouteColor(_ color: Color, opacity: Double) -> Color {
        let clamped = min(max(opacity, 0), 1)
        if clamped >= 0.999 {
            return color
        }
        return color.mix(with: mapCanvas, by: 1 - clamped)
    }
}

/// A polyline ready to draw on a timeline, detail, or share map.
struct RenderedRoute: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let usesHighAccuracyRouteTracking: Bool
    let usesHealthWorkoutRoute: Bool
    let transportMode: TransportMode
    /// Normalised 0…1 speed per vertex. `nil` when shading is unavailable.
    let speedFractions: [Float]?
    let confidence: RouteMatchConfidence
    let origin: TimelineItemOrigin

    init(
        id: String,
        coordinates: [CLLocationCoordinate2D],
        usesHighAccuracyRouteTracking: Bool,
        usesHealthWorkoutRoute: Bool,
        transportMode: TransportMode,
        speedFractions: [Float]? = nil,
        confidence: RouteMatchConfidence = .unknown,
        origin: TimelineItemOrigin = .sensor
    ) {
        self.id = id
        self.coordinates = coordinates
        self.usesHighAccuracyRouteTracking = usesHighAccuracyRouteTracking
        self.usesHealthWorkoutRoute = usesHealthWorkoutRoute
        self.transportMode = transportMode
        self.speedFractions = speedFractions
        self.confidence = confidence
        self.origin = origin
    }

    /// Builds a route from a stored move. Pass precomputed `speedFractions`
    /// after an off-main profile build; otherwise a matching cache is used.
    static func make(
        from move: MoveSegment,
        coordinates: [CLLocationCoordinate2D],
        speedFractions: [Float]? = nil
    ) -> RenderedRoute {
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        let fractions = speedFractions
            ?? SpeedProfileBuilder.cachedFractions(
                for: move,
                coordinateCount: coordinates.count,
                signature: signature
            )
        return RenderedRoute(
            id: move.id.uuidString,
            coordinates: coordinates,
            usesHighAccuracyRouteTracking: move.usesHighAccuracyRouteTracking,
            usesHealthWorkoutRoute: move.usesHealthWorkoutRoute,
            transportMode: move.transportMode,
            speedFractions: fractions,
            confidence: resolvedConfidence(for: move),
            origin: move.origin
        )
    }

    static func resolvedConfidence(for move: MoveSegment) -> RouteMatchConfidence {
        if move.usesHealthWorkoutRoute || move.usesHighAccuracyRouteTracking {
            return .recorded
        }
        if move.hasManualRouteCoordinates, move.routeMatchConfidence == .unknown {
            return .high
        }
        return move.routeMatchConfidence
    }

    var shadowCoordinates: [CLLocationCoordinate2D] {
        guard transportMode == .plane,
              let start = coordinates.first,
              let end = coordinates.last else {
            return []
        }
        return [start, end]
    }

    /// Mode colour only. Health and route-tracking no longer replace this tint.
    var tint: Color {
        MovesPalette.transport(transportMode)
    }

    /// Thin inner stroke so recorded Health / GPS legs stay recognisable.
    var recordedOverlayTint: Color? {
        if usesHealthWorkoutRoute {
            return MovesPalette.healthRoute
        }
        if usesHighAccuracyRouteTracking {
            return MovesPalette.routeTracking
        }
        return nil
    }

    var shadowTint: Color {
        MovesPalette.opaqueRouteColor(tint, opacity: 0.32)
    }

    var lineWidth: CGFloat {
        switch transportMode {
        case .plane:
            return 4.5
        case .train:
            return 4.25
        default:
            return 4
        }
    }

    var overlayLineWidth: CGFloat {
        max(lineWidth - 2.25, 1.25)
    }

    var shadowLineWidth: CGFloat {
        transportMode == .plane ? 2.5 : 0
    }

    /// Visual opacity before pre-blending toward the map canvas.
    var strokeOpacity: Double {
        switch confidence {
        case .medium:
            return 0.75
        case .estimated:
            return 0.60
        case .recorded, .high, .unknown:
            return 1
        }
    }

    /// Opaque `Gradient` that follows the polyline. Always a plain `Gradient`.
    func strokeGradient(shadeBySpeed: Bool, emphasis: Double = 1) -> Gradient {
        let opacity = strokeOpacity * min(max(emphasis, 0), 1)
        let stops = RouteGradientStops.make(
            coordinates: coordinates,
            speedFractions: shadeBySpeed ? speedFractions : nil,
            base: tint,
            opacity: opacity
        )
        return Gradient(stops: stops)
    }
}

/// Dashed estimated paths and dotted photo-inferred paths.
enum RouteStrokeStyle {
    static func make(for route: RenderedRoute, lineWidth: CGFloat? = nil) -> StrokeStyle {
        let width = lineWidth ?? route.lineWidth
        let dash: [CGFloat]
        if route.origin == .photoInferred {
            dash = [1.5, 5]
        } else if route.confidence == .estimated {
            dash = [7, 6]
        } else {
            dash = []
        }
        return StrokeStyle(
            lineWidth: width,
            lineCap: .round,
            lineJoin: .round,
            dash: dash
        )
    }
}

enum RouteGradientStops {
    static func make(
        coordinates: [CLLocationCoordinate2D],
        speedFractions: [Float]?,
        base: Color,
        opacity: Double
    ) -> [Gradient.Stop] {
        let solid = MovesPalette.opaqueRouteColor(base, opacity: opacity)
        guard coordinates.count > 1 else {
            return [
                Gradient.Stop(color: solid, location: 0),
                Gradient.Stop(color: solid, location: 1)
            ]
        }

        guard let speedFractions, speedFractions.count == coordinates.count else {
            return [
                Gradient.Stop(color: solid, location: 0),
                Gradient.Stop(color: solid, location: 1)
            ]
        }

        let locations = SpeedProfileBuilder.cumulativeDistanceFractions(along: coordinates)
        var bucketCount = RouteGradientRendering.maximumStopCount
        var pairs = mergedStops(locations: locations, fractions: speedFractions, bucketCount: bucketCount)
        while pairs.count > RouteGradientRendering.maximumStopCount, bucketCount > 2 {
            bucketCount /= 2
            pairs = mergedStops(locations: locations, fractions: speedFractions, bucketCount: bucketCount)
        }
        if pairs.count > RouteGradientRendering.maximumStopCount {
            pairs = evenlySpacedStops(
                locations: locations,
                fractions: speedFractions,
                count: RouteGradientRendering.maximumStopCount
            )
        }

        return pairs.map { location, fraction in
            Gradient.Stop(
                color: MovesPalette.opaqueRouteColor(
                    MovesPalette.speedShade(base: base, fraction: Double(fraction)),
                    opacity: opacity
                ),
                location: CGFloat(location)
            )
        }
    }

    private static func mergedStops(
        locations: [Double],
        fractions: [Float],
        bucketCount: Int
    ) -> [(Double, Float)] {
        guard let firstLocation = locations.first,
              let lastLocation = locations.last,
              let firstFraction = fractions.first,
              let lastFraction = fractions.last else {
            return []
        }

        var stops: [(Double, Float)] = [(firstLocation, firstFraction)]
        var previousBucket = bucket(for: firstFraction, count: bucketCount)
        for index in fractions.indices.dropFirst() {
            let currentBucket = bucket(for: fractions[index], count: bucketCount)
            if currentBucket != previousBucket {
                stops.append((locations[index], fractions[index]))
                previousBucket = currentBucket
            }
        }
        if stops.last?.0 != lastLocation {
            stops.append((lastLocation, lastFraction))
        }
        return stops
    }

    private static func evenlySpacedStops(
        locations: [Double],
        fractions: [Float],
        count: Int
    ) -> [(Double, Float)] {
        guard count > 1, locations.count == fractions.count, !locations.isEmpty else {
            return []
        }
        return (0..<count).map { index in
            let target = Double(index) / Double(count - 1)
            let nearest = nearestIndex(to: target, in: locations)
            return (target, fractions[nearest])
        }
    }

    private static func nearestIndex(to target: Double, in locations: [Double]) -> Int {
        var best = 0
        var bestDelta = abs(locations[0] - target)
        for index in locations.indices.dropFirst() {
            let delta = abs(locations[index] - target)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    private static func bucket(for fraction: Float, count: Int) -> Int {
        let clamped = min(max(Double(fraction), 0), 1)
        return min(Int((clamped * Double(count - 1)).rounded()), count - 1)
    }

    static func bucket(for fraction: Float) -> Int {
        bucket(for: fraction, count: RouteGradientRendering.maximumStopCount)
    }
}

/// Core Graphics strokes for map snapshots (collapsed header and share cards).
enum RouteSnapshotStroke {
    static func draw(
        _ route: RenderedRoute,
        in snapshot: MKMapSnapshotter.Snapshot,
        shadeBySpeed: Bool,
        emphasis: Double = 1,
        lineWidth: CGFloat? = nil
    ) {
        let width = lineWidth ?? route.lineWidth
        let opacity = route.strokeOpacity * min(max(emphasis, 0), 1)
        let dash = RouteStrokeStyle.make(for: route, lineWidth: width).dash

        if route.shadowCoordinates.count > 1 {
            strokePath(
                coordinates: route.shadowCoordinates,
                in: snapshot,
                color: UIColor(route.shadowTint),
                lineWidth: route.shadowLineWidth,
                dash: []
            )
        }

        strokeBucketed(
            coordinates: route.coordinates,
            speedFractions: shadeBySpeed ? route.speedFractions : nil,
            base: route.tint,
            opacity: opacity,
            lineWidth: width,
            dash: dash,
            in: snapshot
        )

        if let overlay = route.recordedOverlayTint {
            strokePath(
                coordinates: route.coordinates,
                in: snapshot,
                color: UIColor(MovesPalette.opaqueRouteColor(overlay, opacity: emphasis)),
                lineWidth: max(width - 2.25, 1.25),
                dash: dash
            )
        }
    }

    private static func strokeBucketed(
        coordinates: [CLLocationCoordinate2D],
        speedFractions: [Float]?,
        base: Color,
        opacity: Double,
        lineWidth: CGFloat,
        dash: [CGFloat],
        in snapshot: MKMapSnapshotter.Snapshot
    ) {
        guard coordinates.count > 1 else { return }

        let solid = UIColor(MovesPalette.opaqueRouteColor(base, opacity: opacity))
        guard let speedFractions, speedFractions.count == coordinates.count else {
            strokePath(
                coordinates: coordinates,
                in: snapshot,
                color: solid,
                lineWidth: lineWidth,
                dash: dash
            )
            return
        }

        var runStart = 0
        var currentBucket = RouteGradientStops.bucket(for: speedFractions[0])
        for index in 1..<coordinates.count {
            let bucket = RouteGradientStops.bucket(for: speedFractions[index])
            if bucket != currentBucket {
                strokePath(
                    coordinates: Array(coordinates[runStart...index]),
                    in: snapshot,
                    color: UIColor(
                        MovesPalette.opaqueRouteColor(
                            MovesPalette.speedShade(
                                base: base,
                                fraction: Double(speedFractions[runStart])
                            ),
                            opacity: opacity
                        )
                    ),
                    lineWidth: lineWidth,
                    dash: dash
                )
                runStart = index
                currentBucket = bucket
            }
        }
        strokePath(
            coordinates: Array(coordinates[runStart...]),
            in: snapshot,
            color: UIColor(
                MovesPalette.opaqueRouteColor(
                    MovesPalette.speedShade(
                        base: base,
                        fraction: Double(speedFractions[runStart])
                    ),
                    opacity: opacity
                )
            ),
            lineWidth: lineWidth,
            dash: dash
        )
    }

    static func strokePath(
        coordinates: [CLLocationCoordinate2D],
        in snapshot: MKMapSnapshotter.Snapshot,
        color: UIColor,
        lineWidth: CGFloat,
        dash: [CGFloat]
    ) {
        guard coordinates.count > 1, lineWidth > 0 else { return }

        let path = UIBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }

        for (index, coordinate) in coordinates.enumerated() {
            let point = snapshot.point(for: coordinate)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        color.setStroke()
        path.stroke()
    }
}
