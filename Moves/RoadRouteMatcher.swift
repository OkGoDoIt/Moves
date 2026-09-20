//
//  RoadRouteMatcher.swift
//  Moves
//
//  Snaps a move onto the road/path network when the recorded fixes support it,
//  and records an honest confidence + one-line summary when they do not.
//

import BackgroundTasks
import CoreLocation
import Foundation
import MapKit
import SwiftData

// MARK: - Snapping level

/// Global aggressiveness for automatic path matching. Per-move Path still wins.
enum RouteSnappingLevel: String, CaseIterable, Identifiable {
    case conservative
    case normal
    case off

    /// `@AppStorage` key for Settings → Map.
    static let storageKey = "routing.snappingLevel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .normal: return "Normal"
        case .off: return "Off"
        }
    }

    /// Reads the stored setting, defaulting to Normal.
    static var stored: RouteSnappingLevel {
        RouteSnappingLevel(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .normal
    }
}

// MARK: - Directions provider

/// A MapKit directions response reduced to polylines so tests can inject fakes.
protocol DirectionsProvider: Sendable {
    /// Returns candidate routes from `start` to `end` for one transport type.
    func routes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        requestsAlternateRoutes: Bool
    ) async throws -> [[CLLocationCoordinate2D]]
}

/// Production provider wrapping `MKDirections`.
struct MapKitDirectionsProvider: DirectionsProvider {
    func routes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        requestsAlternateRoutes: Bool
    ) async throws -> [[CLLocationCoordinate2D]] {
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: start)
        request.destination = Self.mapItem(for: end)
        request.transportType = transportType
        request.requestsAlternateRoutes = requestsAlternateRoutes
        let response = try await MKDirections(request: request).calculate()
        return response.routes.compactMap { route in
            let coordinates = route.polyline.allCoordinates
            return coordinates.count > 1 ? coordinates : nil
        }
    }

    private static func mapItem(for coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #unavailable(iOS 26.0) {
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return MKMapItem(location: location, address: nil)
    }
}

// MARK: - Match result

/// Outcome of resolving a displayed path, including honesty metadata.
struct RouteMatchResolution: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let cacheable: Bool
    let rejected: Bool
    let confidence: RouteMatchConfidence
    let summary: String
    /// True when at least one MapKit (or fake) polyline was kept.
    let usedNetworkRoute: Bool

    init(
        coordinates: [CLLocationCoordinate2D],
        cacheable: Bool,
        rejected: Bool,
        confidence: RouteMatchConfidence,
        summary: String,
        usedNetworkRoute: Bool = false
    ) {
        self.coordinates = coordinates
        self.cacheable = cacheable
        self.rejected = rejected
        self.confidence = confidence
        self.summary = summary
        self.usedNetworkRoute = usedNetworkRoute
    }
}

// MARK: - Density

/// How many intermediate fixes a move has per recorded kilometre.
enum RouteMatchDensity: Equatable {
    /// Route tracking, Health, or a dense import. Windowed matching.
    case dense
    /// Typical significant-change data. One waypoint chain.
    case sparse
    /// Start and end only. Estimated directions, or a dashed straight line.
    case endpoints

    /// Intermediate samples per recorded kilometre.
    static func classify(
        intermediateSampleCount: Int,
        recordedMeters: CLLocationDistance
    ) -> RouteMatchDensity {
        let kilometres = max(recordedMeters / 1_000, 0.0001)
        let density = Double(max(intermediateSampleCount, 0)) / kilometres
        if density >= 5 {
            return .dense
        }
        if density >= 1 {
            return .sparse
        }
        return .endpoints
    }
}

// MARK: - Input snapshot

/// Sendable snapshot of a move so matching can run off the model object.
struct RouteMatchInput: Sendable {
    let policy: RouteMatchPolicy
    let transportMode: TransportMode
    let fallback: [CLLocationCoordinate2D]
    let intermediateSampleCount: Int
    let medianHorizontalAccuracy: CLLocationAccuracy
    let hasStartPlace: Bool
    let hasEndPlace: Bool
    let usesRouteTracking: Bool
    let sampleSpeeds: [Double]
    let snappingLevel: RouteSnappingLevel
    let duration: TimeInterval

    var recordedMeters: CLLocationDistance {
        routeDistance(for: fallback)
    }

    var density: RouteMatchDensity {
        RouteMatchDensity.classify(
            intermediateSampleCount: intermediateSampleCount,
            recordedMeters: recordedMeters
        )
    }

    var forceRoads: Bool {
        policy == .roads
    }

    var allowsNetworkMatching: Bool {
        switch snappingLevel {
        case .off:
            return policy == .roads
        case .conservative, .normal:
            return policy != .recorded && policy != .manual
        }
    }
}

// MARK: - Matcher

@MainActor
enum RoadRouteMatcher {
    private static let memo = RouteMatchMemo()
    private static let transientFallbackMemoTTL: TimeInterval = 3 * 60
    private static let rejectedMemoTTL: TimeInterval = 24 * 60 * 60
    private static let algorithmVersion = "snap-v1"
    private static let denseWindowMeters: CLLocationDistance = 400
    private static let endpointsMinimumMeters: CLLocationDistance = 300
    private static let sparseLengthRatio = 1.3
    private static let walkingOffPathFraction = 0.30

    /// Injectable directions backend. Tests replace this with a fake.
    static var directionsProvider: any DirectionsProvider = MapKitDirectionsProvider()

    /// When set, overrides `RouteSnappingLevel.stored` so tests stay deterministic.
    static var snappingLevelOverride: RouteSnappingLevel?

    static var currentSnappingLevel: RouteSnappingLevel {
        snappingLevelOverride ?? RouteSnappingLevel.stored
    }

    /// Restores production defaults and empties memo/limiter state between tests.
    static func resetTestHooks() async {
        directionsProvider = MapKitDirectionsProvider()
        snappingLevelOverride = nil
        await memo.reset()
        await DirectionsRequestLimiter.shared.reset()
    }

    static func matchedCoordinates(for move: MoveSegment) async -> [CLLocationCoordinate2D] {
        let coordinates = await resolveDisplayedCoordinates(for: move)
        let displayedDistance = routeDistance(for: coordinates)
        if abs(move.distanceMeters - displayedDistance) > 0.01 {
            move.distanceMeters = displayedDistance
        }
        return coordinates
    }

    private static func resolveDisplayedCoordinates(for move: MoveSegment) async -> [CLLocationCoordinate2D] {
        if let manualCoordinates = move.manualRouteCoordinates {
            apply(resolution: .manual(manualCoordinates), to: move)
            return manualCoordinates
        }

        if move.routeMatchPolicy == .manual {
            move.routeMatchPolicy = .auto
        }

        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let cacheKey = matchCacheKey(for: move, fallback: fallback)
        let cacheSignature = matchCacheSignature(for: move, fallback: fallback)
        let input = RouteMatchInput(move: move, fallback: fallback, snappingLevel: currentSnappingLevel)

        if move.routeMatchPolicy == .recorded {
            let coordinates = recordedCoordinates(fallback: fallback, for: move)
            let resolution = RouteMatchResolution(
                coordinates: coordinates,
                cacheable: true,
                rejected: false,
                confidence: .recorded,
                summary: RouteMatchSummaries.recorded(usesRouteTracking: move.usesHighAccuracyRouteTracking)
            )
            await memo.storePersistent(coordinates, for: cacheKey)
            move.storeCachedRouteCoordinates(coordinates, signature: cacheSignature)
            apply(resolution: resolution, to: move)
            return coordinates
        }

        if let cached = move.cachedRouteCoordinates(for: cacheSignature) {
            await memo.storePersistent(cached, for: cacheKey)
            return cached
        }

        if let cached = await memo.cached(for: cacheKey) {
            switch cached {
            case .persistent(let coordinates):
                move.storeCachedRouteCoordinates(coordinates, signature: cacheSignature)
                return coordinates
            case .transient(let coordinates):
                return coordinates
            case .rejected(let resolution):
                apply(resolution: resolution, to: move)
                return resolution.coordinates
            }
        }

        if let task = await memo.inFlightTask(for: cacheKey) {
            let result = await task.value
            await persist(result, on: move, cacheKey: cacheKey, cacheSignature: cacheSignature)
            return result.coordinates
        }

        let provider = directionsProvider
        let task = Task.detached(priority: .utility) {
            await resolveCoordinates(input: input, provider: provider)
        }
        await memo.setInFlightTask(task, for: cacheKey)

        let result = await task.value
        await memo.setInFlightTask(nil, for: cacheKey)
        await persist(result, on: move, cacheKey: cacheKey, cacheSignature: cacheSignature)
        return result.coordinates
    }

    static func matchedManualCoordinates(
        for anchors: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) async -> [CLLocationCoordinate2D] {
        let coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
            anchors,
            minimumDistanceMeters: 6
        )
        let input = RouteMatchInput.manualAnchors(coordinates, transportMode: transportMode)
        let result = await resolveCoordinates(
            input: input,
            provider: directionsProvider,
            anchorsOverride: coordinates
        )
        return result.coordinates
    }

    static func routeAnchors(
        for fallback: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) -> [CLLocationCoordinate2D] {
        routeAnchorIndices(for: fallback, transportMode: transportMode)
            .map { fallback[$0] }
    }

    static func routeAnchorIndices(
        for fallback: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) -> [Int] {
        RouteCoordinateOps.sampleAnchorIndices(
            from: fallback,
            maximumCount: anchorLimit(for: transportMode)
        )
    }

    private static func persist(
        _ result: RouteMatchResolution,
        on move: MoveSegment,
        cacheKey: Int,
        cacheSignature: String
    ) async {
        apply(resolution: result, to: move)
        if result.rejected {
            await memo.storeRejected(result, for: cacheKey, ttl: rejectedMemoTTL)
            return
        }
        if result.cacheable {
            await memo.storePersistent(result.coordinates, for: cacheKey)
            move.storeCachedRouteCoordinates(result.coordinates, signature: cacheSignature)
        } else {
            await memo.storeTransient(
                result.coordinates,
                for: cacheKey,
                ttl: transientFallbackMemoTTL
            )
        }
    }

    private static func apply(resolution: RouteMatchResolution, to move: MoveSegment) {
        move.routeMatchConfidence = resolution.confidence
        move.routeMatchSummary = resolution.summary
        if resolution.summary == RouteMatchSummaries.manual {
            move.routeMatchPolicy = .manual
        }
    }

    private static func recordedCoordinates(
        fallback: [CLLocationCoordinate2D],
        for move: MoveSegment
    ) -> [CLLocationCoordinate2D] {
        RouteCoordinateOps.dedupeSequentialCoordinates(
            fallback,
            minimumDistanceMeters: MoveRouteGeometry.highAccuracyDisplayDedupeDistance(for: move)
        )
    }

    private static func matchCacheSignature(
        for move: MoveSegment,
        fallback: [CLLocationCoordinate2D]
    ) -> String {
        [
            algorithmVersion,
            move.routeMatchPolicy.rawValue,
            currentSnappingLevel.rawValue,
            MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        ]
        .joined(separator: "|")
    }

    private static func matchCacheKey(
        for move: MoveSegment,
        fallback: [CLLocationCoordinate2D]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(algorithmVersion)
        hasher.combine(move.routeMatchPolicy.rawValue)
        hasher.combine(currentSnappingLevel.rawValue)
        hasher.combine(MoveRouteGeometry.cacheKey(for: move, fallback: fallback))
        return hasher.finalize()
    }
}

extension RouteMatchResolution {
    static func manual(_ coordinates: [CLLocationCoordinate2D]) -> RouteMatchResolution {
        RouteMatchResolution(
            coordinates: coordinates,
            cacheable: true,
            rejected: false,
            confidence: .unknown,
            summary: RouteMatchSummaries.manual
        )
    }
}

extension RouteMatchInput {
    @MainActor
    init(move: MoveSegment, fallback: [CLLocationCoordinate2D], snappingLevel: RouteSnappingLevel) {
        let samples = move.samples.preferredRouteDisplaySamples
        let accuracies = samples.map(\.horizontalAccuracy).filter { $0 > 0 }
        self.policy = move.routeMatchPolicy
        self.transportMode = move.transportMode
        self.fallback = fallback
        self.intermediateSampleCount = samples.count
        self.medianHorizontalAccuracy = Self.median(accuracies)
        self.hasStartPlace = move.startPlace != nil
        self.hasEndPlace = move.endPlace != nil
        self.usesRouteTracking = move.usesHighAccuracyRouteTracking
        self.sampleSpeeds = samples.map(\.speed)
        self.snappingLevel = snappingLevel
        self.duration = move.timelineDuration
    }

    static func manualAnchors(
        _ coordinates: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) -> RouteMatchInput {
        RouteMatchInput(
            policy: .manual,
            transportMode: transportMode,
            fallback: coordinates,
            intermediateSampleCount: max(coordinates.count - 2, 0),
            medianHorizontalAccuracy: 0,
            hasStartPlace: true,
            hasEndPlace: true,
            usesRouteTracking: false,
            sampleSpeeds: [],
            snappingLevel: .normal,
            duration: 0
        )
    }

    private static func median(_ values: [CLLocationAccuracy]) -> CLLocationAccuracy {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Core algorithm (off the model object)

extension RoadRouteMatcher {
    fileprivate static func resolveCoordinates(
        input: RouteMatchInput,
        provider: any DirectionsProvider,
        anchorsOverride: [CLLocationCoordinate2D]? = nil
    ) async -> RouteMatchResolution {
        guard input.fallback.count > 1 else {
            return RouteMatchResolution(
                coordinates: input.fallback,
                cacheable: true,
                rejected: false,
                confidence: .unknown,
                summary: RouteMatchSummaries.recorded(usesRouteTracking: input.usesRouteTracking)
            )
        }

        if let override = anchorsOverride {
            return await matchAnchorChain(
                fallback: override,
                input: input,
                provider: provider,
                useSampledAnchors: false,
                forceAccept: true
            )
        }

        switch input.transportMode {
        case .boat, .swimming:
            return unsappedResolution(input: input, coordinates: input.fallback)
        case .plane:
            let coordinates = input.density == .dense
                ? input.fallback
                : PlaneRouteGeometry.arcCoordinates(from: input.fallback)
            return unsappedResolution(
                input: input,
                coordinates: coordinates,
                planeArc: input.density != .dense
            )
        case .train:
            return unsappedResolution(input: input, coordinates: input.fallback)
        case .walking, .running, .cycling, .automotive, .stationary, .unknown:
            break
        }

        if input.policy == .recorded {
            return RouteMatchResolution(
                coordinates: input.fallback,
                cacheable: true,
                rejected: false,
                confidence: .recorded,
                summary: RouteMatchSummaries.recorded(usesRouteTracking: input.usesRouteTracking)
            )
        }

        if !input.allowsNetworkMatching {
            return unsappedResolution(input: input, coordinates: input.fallback)
        }

        if mapTransportTypes(for: input.transportMode).isEmpty {
            return unsappedResolution(input: input, coordinates: input.fallback)
        }

        switch input.density {
        case .dense:
            return await matchDenseWindows(input: input, provider: provider)
        case .sparse:
            return await matchSparseWaypoints(input: input, provider: provider)
        case .endpoints:
            return await matchEndpoints(input: input, provider: provider)
        }
    }

    private static func unsappedResolution(
        input: RouteMatchInput,
        coordinates: [CLLocationCoordinate2D],
        planeArc: Bool = false
    ) -> RouteMatchResolution {
        let confidence: RouteMatchConfidence
        let summary: String
        if planeArc {
            confidence = .estimated
            summary = RouteMatchSummaries.estimatedGreatCircle
        } else if input.density == .dense || input.usesRouteTracking {
            confidence = .recorded
            summary = RouteMatchSummaries.recorded(usesRouteTracking: input.usesRouteTracking)
        } else {
            confidence = .estimated
            summary = input.intermediateSampleCount == 0
                ? RouteMatchSummaries.estimatedNoFixes
                : RouteMatchSummaries.estimated
        }
        return RouteMatchResolution(
            coordinates: coordinates,
            cacheable: true,
            rejected: false,
            confidence: confidence,
            summary: summary
        )
    }

    private static func matchDenseWindows(
        input: RouteMatchInput,
        provider: any DirectionsProvider
    ) async -> RouteMatchResolution {
        let fallback = input.fallback
        let corridor = RouteMatchPlausibility.corridorMeters(
            for: input.transportMode,
            medianAccuracy: input.medianHorizontalAccuracy
        )
        var matchedCoordinates: [CLLocationCoordinate2D] = []
        var attemptedNetworkMatch = false
        var sawRouteCandidate = false
        var throttled = false
        var matchedFixCount = 0
        var offPathFixCount = 0
        var usedOffPathRaw = false
        var snappedAnyWindow = false
        var deviationSamples: [CLLocationDistance] = []

        let windows = denseWindows(in: fallback, maximumSpanMeters: denseWindowMeters)
        for window in windows {
            let recordedSegment = Array(fallback[window.start...window.end])
            let start = fallback[window.start]
            let end = fallback[window.end]
            let segmentDistance = RouteCoordinateOps.distanceMeters(from: start, to: end)

            if segmentDistance < minimumMatchDistance(for: input.transportMode)
                || segmentDistance > denseWindowMeters {
                RouteCoordinateOps.append(recordedSegment, to: &matchedCoordinates)
                continue
            }

            attemptedNetworkMatch = true
            let segmentResult = await routeSegment(
                from: start,
                to: end,
                transportTypes: mapTransportTypes(for: input.transportMode),
                recordedSegment: recordedSegment,
                input: input,
                provider: provider,
                requestsAlternateRoutes: true,
                corridorMeters: corridor,
                maximumLengthRatio: nil
            )
            sawRouteCandidate = sawRouteCandidate || segmentResult.hadRouteCandidates
            if segmentResult.throttled {
                throttled = true
                break
            }

            let intermediates = Array(recordedSegment.dropFirst().dropLast())
            let referencePath = segmentResult.coordinates ?? segmentResult.bestCandidate
            if let referencePath {
                let offPath = intermediates.filter {
                    RouteMatchPlausibility.distance(from: $0, to: referencePath) > corridor
                }
                offPathFixCount += offPath.count
                matchedFixCount += intermediates.count
                deviationSamples.append(contentsOf: intermediates.map {
                    RouteMatchPlausibility.distance(from: $0, to: referencePath)
                })

                let offPathFraction = intermediates.isEmpty
                    ? 0
                    : Double(offPath.count) / Double(intermediates.count)
                let keepRawOffNetwork = shouldKeepWalkingOffNetwork(
                    input: input,
                    offPathFraction: offPathFraction
                )
                if !input.forceRoads && (keepRawOffNetwork || segmentResult.coordinates == nil) {
                    if keepRawOffNetwork {
                        usedOffPathRaw = true
                    }
                    RouteCoordinateOps.append(recordedSegment, to: &matchedCoordinates)
                } else {
                    snappedAnyWindow = true
                    RouteCoordinateOps.append(referencePath, to: &matchedCoordinates)
                }
            } else {
                offPathFixCount += intermediates.count
                matchedFixCount += intermediates.count
                RouteCoordinateOps.append(recordedSegment, to: &matchedCoordinates)
            }
        }

        if throttled {
            return RouteMatchResolution(
                coordinates: fallback,
                cacheable: false,
                rejected: false,
                confidence: .unknown,
                summary: RouteMatchSummaries.estimated
            )
        }

        let resolved = RouteCoordinateOps.dedupeSequentialCoordinates(
            matchedCoordinates.isEmpty ? fallback : matchedCoordinates,
            minimumDistanceMeters: 6
        )

        if attemptedNetworkMatch, !sawRouteCandidate, !input.forceRoads {
            return RouteMatchResolution(
                coordinates: fallback,
                cacheable: false,
                rejected: false,
                confidence: input.usesRouteTracking ? .recorded : .unknown,
                summary: RouteMatchSummaries.recorded(usesRouteTracking: input.usesRouteTracking)
            )
        }

        let offPathFraction = matchedFixCount == 0
            ? 0
            : Double(offPathFixCount) / Double(matchedFixCount)
        let summary: String
        let confidence: RouteMatchConfidence
        if usedOffPathRaw || (offPathFraction >= walkingOffPathFraction && input.transportMode == .walking) {
            summary = RouteMatchSummaries.partlyOffPath
            confidence = snappedAnyWindow ? .high : .recorded
        } else if snappedAnyWindow {
            summary = RouteMatchSummaries.matched(
                mode: input.transportMode,
                percentWithinCorridor: percentWithin(
                    deviationSamples,
                    corridor: corridor
                ),
                typicalDeviationMeters: typicalDeviationMeters(deviationSamples)
            )
            confidence = .high
        } else {
            summary = RouteMatchSummaries.recorded(usesRouteTracking: input.usesRouteTracking)
            confidence = .recorded
        }

        return RouteMatchResolution(
            coordinates: resolved,
            cacheable: true,
            rejected: false,
            confidence: confidence,
            summary: summary,
            usedNetworkRoute: snappedAnyWindow
        )
    }

    private static func matchSparseWaypoints(
        input: RouteMatchInput,
        provider: any DirectionsProvider
    ) async -> RouteMatchResolution {
        let result = await matchAnchorChain(
            fallback: input.fallback,
            input: input,
            provider: provider,
            useSampledAnchors: true,
            forceAccept: input.forceRoads
        )
        if result.rejected || !result.cacheable {
            return result
        }

        if !result.usedNetworkRoute, !input.forceRoads {
            return RouteMatchResolution(
                coordinates: input.fallback,
                cacheable: false,
                rejected: true,
                confidence: .estimated,
                summary: RouteMatchSummaries.estimated
            )
        }

        let corridor = RouteMatchPlausibility.corridorMeters(
            for: input.transportMode,
            medianAccuracy: input.medianHorizontalAccuracy
        ) * 2
        let matchedDistance = routeDistance(for: result.coordinates)
        let recordedDistance = max(input.recordedMeters, 1)
        let lengthOK = matchedDistance <= recordedDistance * sparseLengthRatio
        let pointsOK = RouteMatchPlausibility.allIntermediateFixes(
            input.fallback,
            lieWithin: corridor,
            of: result.coordinates
        )

        if input.forceRoads || (lengthOK && pointsOK) {
            let deviations = input.fallback.dropFirst().dropLast().map {
                RouteMatchPlausibility.distance(from: $0, to: result.coordinates)
            }
            return RouteMatchResolution(
                coordinates: result.coordinates,
                cacheable: true,
                rejected: false,
                confidence: .medium,
                summary: RouteMatchSummaries.matched(
                    mode: input.transportMode,
                    percentWithinCorridor: percentWithin(Array(deviations), corridor: corridor),
                    typicalDeviationMeters: typicalDeviationMeters(Array(deviations))
                ),
                usedNetworkRoute: true
            )
        }

        return RouteMatchResolution(
            coordinates: input.fallback,
            cacheable: false,
            rejected: true,
            confidence: .estimated,
            summary: RouteMatchSummaries.estimated
        )
    }

    private static func matchEndpoints(
        input: RouteMatchInput,
        provider: any DirectionsProvider
    ) async -> RouteMatchResolution {
        let fallback = input.fallback
        let straight = [fallback.first, fallback.last].compactMap { $0 }

        let estimatedStraight = RouteMatchResolution(
            coordinates: straight.count > 1 ? straight : fallback,
            cacheable: true,
            rejected: false,
            confidence: .estimated,
            summary: RouteMatchSummaries.estimatedNoFixes
        )

        if input.snappingLevel == .conservative, !input.forceRoads {
            return estimatedStraight
        }

        let modesAllowingEstimate: Set<TransportMode> = [.automotive, .cycling, .walking]
        guard input.hasStartPlace,
              input.hasEndPlace,
              modesAllowingEstimate.contains(input.transportMode),
              input.recordedMeters >= endpointsMinimumMeters,
              let start = fallback.first,
              let end = fallback.last else {
            return estimatedStraight
        }

        let segmentResult = await routeSegment(
            from: start,
            to: end,
            transportTypes: mapTransportTypes(for: input.transportMode),
            recordedSegment: fallback,
            input: input,
            provider: provider,
            requestsAlternateRoutes: true,
            corridorMeters: RouteMatchPlausibility.corridorMeters(
                for: input.transportMode,
                medianAccuracy: input.medianHorizontalAccuracy
            ) * 2,
            maximumLengthRatio: 2.0
        )

        if segmentResult.throttled {
            return RouteMatchResolution(
                coordinates: estimatedStraight.coordinates,
                cacheable: false,
                rejected: false,
                confidence: .estimated,
                summary: RouteMatchSummaries.estimatedNoFixes
            )
        }

        if let snapped = segmentResult.coordinates {
            return RouteMatchResolution(
                coordinates: snapped,
                cacheable: true,
                rejected: false,
                confidence: .estimated,
                summary: RouteMatchSummaries.estimatedNoFixes,
                usedNetworkRoute: true
            )
        }

        return estimatedStraight
    }

    private static func matchAnchorChain(
        fallback: [CLLocationCoordinate2D],
        input: RouteMatchInput,
        provider: any DirectionsProvider,
        useSampledAnchors: Bool,
        forceAccept: Bool
    ) async -> RouteMatchResolution {
        let transportTypes = mapTransportTypes(for: input.transportMode)
        guard !transportTypes.isEmpty else {
            return unsappedResolution(input: input, coordinates: fallback)
        }

        let anchorIndices = useSampledAnchors
            ? routeAnchorIndices(for: fallback, transportMode: input.transportMode)
            : Array(fallback.indices)
        guard anchorIndices.count > 1 else {
            return unsappedResolution(input: input, coordinates: fallback)
        }

        var matchedCoordinates: [CLLocationCoordinate2D] = []
        var matchedSegmentCount = 0
        var attemptedNetworkMatch = false
        var sawRouteCandidate = false
        let corridor = RouteMatchPlausibility.corridorMeters(
            for: input.transportMode,
            medianAccuracy: input.medianHorizontalAccuracy
        )

        for pair in zip(anchorIndices, anchorIndices.dropFirst()) {
            let startIndex = pair.0
            let endIndex = pair.1
            let start = fallback[startIndex]
            let end = fallback[endIndex]
            let recordedSegment = Array(fallback[startIndex...endIndex])
            let segmentDistance = RouteCoordinateOps.distanceMeters(from: start, to: end)

            if segmentDistance < minimumMatchDistance(for: input.transportMode) {
                RouteCoordinateOps.append(recordedSegment, to: &matchedCoordinates)
                continue
            }

            attemptedNetworkMatch = true
            let segmentResult = await routeSegment(
                from: start,
                to: end,
                transportTypes: transportTypes,
                recordedSegment: recordedSegment,
                input: input,
                provider: provider,
                requestsAlternateRoutes: true,
                corridorMeters: corridor,
                maximumLengthRatio: nil
            )
            sawRouteCandidate = sawRouteCandidate || segmentResult.hadRouteCandidates

            if segmentResult.throttled {
                return RouteMatchResolution(
                    coordinates: fallback,
                    cacheable: false,
                    rejected: false,
                    confidence: .unknown,
                    summary: RouteMatchSummaries.estimated
                )
            }

            if let snappedSegment = segmentResult.coordinates {
                matchedSegmentCount += 1
                RouteCoordinateOps.append(snappedSegment, to: &matchedCoordinates)
            } else {
                RouteCoordinateOps.append(recordedSegment, to: &matchedCoordinates)
            }
        }

        if matchedSegmentCount > 0 {
            let resolvedCoordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
                matchedCoordinates,
                minimumDistanceMeters: 6
            )
            let acceptable = RouteMatchPlausibility.isAcceptable(
                resolvedCoordinates,
                comparedTo: fallback,
                transportMode: input.transportMode,
                corridorMeters: corridor,
                medianAccuracy: input.medianHorizontalAccuracy
            )
            if forceAccept || acceptable {
                return RouteMatchResolution(
                    coordinates: resolvedCoordinates,
                    cacheable: true,
                    rejected: false,
                    confidence: .medium,
                    summary: RouteMatchSummaries.matched(
                        mode: input.transportMode,
                        percentWithinCorridor: 100,
                        typicalDeviationMeters: Int(corridor.rounded())
                    ),
                    usedNetworkRoute: true
                )
            }

            return RouteMatchResolution(
                coordinates: fallback,
                cacheable: false,
                rejected: true,
                confidence: .estimated,
                summary: RouteMatchSummaries.estimated
            )
        }

        return RouteMatchResolution(
            coordinates: fallback,
            cacheable: sawRouteCandidate || !attemptedNetworkMatch,
            rejected: false,
            confidence: .estimated,
            summary: RouteMatchSummaries.estimated
        )
    }

    private struct RouteSegmentResult {
        var coordinates: [CLLocationCoordinate2D]?
        var bestCandidate: [CLLocationCoordinate2D]?
        var throttled: Bool
        var hadRouteCandidates: Bool
    }

    private static func routeSegment(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportTypes: [MKDirectionsTransportType],
        recordedSegment: [CLLocationCoordinate2D],
        input: RouteMatchInput,
        provider: any DirectionsProvider,
        requestsAlternateRoutes: Bool,
        corridorMeters: CLLocationDistance,
        maximumLengthRatio: Double?
    ) async -> RouteSegmentResult {
        var hadRouteCandidates = false
        var bestOverall: [CLLocationCoordinate2D]?

        for transportType in transportTypes {
            guard await DirectionsRequestLimiter.shared.reserveSlot() else {
                RouteMatchBackgroundTask.scheduleNextRun()
                return RouteSegmentResult(
                    coordinates: nil,
                    bestCandidate: bestOverall,
                    throttled: true,
                    hadRouteCandidates: hadRouteCandidates
                )
            }

            do {
                let candidates = try await provider.routes(
                    from: start,
                    to: end,
                    transportType: transportType,
                    requestsAlternateRoutes: requestsAlternateRoutes
                )
                hadRouteCandidates = hadRouteCandidates || !candidates.isEmpty

                let scored = candidates.filter { $0.count > 1 }
                if let closest = scored.min(by: { lhs, rhs in
                    RouteMatchPlausibility.selectionScore(for: lhs, comparedTo: recordedSegment)
                        < RouteMatchPlausibility.selectionScore(for: rhs, comparedTo: recordedSegment)
                }) {
                    if bestOverall == nil
                        || RouteMatchPlausibility.selectionScore(for: closest, comparedTo: recordedSegment)
                        < RouteMatchPlausibility.selectionScore(for: bestOverall ?? closest, comparedTo: recordedSegment) {
                        bestOverall = closest
                    }
                }

                let acceptable = scored.filter { candidate in
                    RouteMatchPlausibility.isAcceptable(
                        candidate,
                        comparedTo: recordedSegment,
                        transportMode: input.transportMode,
                        corridorMeters: corridorMeters,
                        maximumLengthRatio: maximumLengthRatio,
                        medianAccuracy: input.medianHorizontalAccuracy
                    )
                }

                let pool = input.forceRoads ? scored : acceptable
                if let bestCandidate = pool.min(by: { lhs, rhs in
                    RouteMatchPlausibility.selectionScore(for: lhs, comparedTo: recordedSegment)
                        < RouteMatchPlausibility.selectionScore(for: rhs, comparedTo: recordedSegment)
                }) {
                    return RouteSegmentResult(
                        coordinates: bestCandidate,
                        bestCandidate: bestOverall ?? bestCandidate,
                        throttled: false,
                        hadRouteCandidates: hadRouteCandidates
                    )
                }
            } catch {
                let throttled = await DirectionsRequestLimiter.shared.registerFailure(error)
                if throttled {
                    RouteMatchBackgroundTask.scheduleNextRun()
                    return RouteSegmentResult(
                        coordinates: nil,
                        bestCandidate: bestOverall,
                        throttled: true,
                        hadRouteCandidates: hadRouteCandidates
                    )
                }
                continue
            }
        }

        return RouteSegmentResult(
            coordinates: nil,
            bestCandidate: bestOverall,
            throttled: false,
            hadRouteCandidates: hadRouteCandidates
        )
    }

    private static func denseWindows(
        in coordinates: [CLLocationCoordinate2D],
        maximumSpanMeters: CLLocationDistance
    ) -> [(start: Int, end: Int)] {
        guard coordinates.count > 1 else { return [] }

        var windows: [(Int, Int)] = []
        var start = 0
        while start < coordinates.count - 1 {
            var end = start + 1
            while end + 1 < coordinates.count {
                let span = RouteCoordinateOps.distanceMeters(
                    from: coordinates[start],
                    to: coordinates[end + 1]
                )
                if span > maximumSpanMeters {
                    break
                }
                end += 1
            }
            windows.append((start, end))
            start = end
        }
        return windows
    }

    private static func shouldKeepWalkingOffNetwork(
        input: RouteMatchInput,
        offPathFraction: Double
    ) -> Bool {
        guard input.transportMode == .walking, offPathFraction >= walkingOffPathFraction else {
            return false
        }
        return walkingSpeedIsPlausible(input: input)
    }

    private static func walkingSpeedIsPlausible(input: RouteMatchInput) -> Bool {
        let measured = input.sampleSpeeds.filter { $0 >= 0 }
        if let median = measured.sorted().dropFirst(measured.count / 2).first {
            return (0.3...3.5).contains(median)
        }
        guard input.duration > 0 else { return true }
        let speed = input.recordedMeters / input.duration
        return (0.3...3.5).contains(speed)
    }

    private static func percentWithin(
        _ deviations: [CLLocationDistance],
        corridor: CLLocationDistance
    ) -> Int {
        guard !deviations.isEmpty else { return 100 }
        let inside = deviations.filter { $0 <= corridor }.count
        return Int((Double(inside) / Double(deviations.count) * 100).rounded())
    }

    private static func typicalDeviationMeters(_ deviations: [CLLocationDistance]) -> Int {
        guard !deviations.isEmpty else { return 0 }
        let sorted = deviations.sorted()
        return max(Int(sorted[sorted.count / 2].rounded()), 1)
    }

    fileprivate static func mapTransportTypes(for mode: TransportMode) -> [MKDirectionsTransportType] {
        switch mode {
        case .automotive:
            return [.automobile, .walking]
        case .walking, .running:
            return [.walking]
        case .cycling:
            return [.cycling, .walking]
        case .train, .plane, .swimming, .boat, .stationary, .unknown:
            return []
        }
    }

    fileprivate static func minimumMatchDistance(for mode: TransportMode) -> CLLocationDistance {
        switch mode {
        case .walking, .running:
            return 25
        case .cycling:
            return 35
        case .automotive:
            return 20
        case .train:
            return 90
        case .plane:
            return 120
        case .swimming, .boat, .stationary, .unknown:
            return 60
        }
    }

    fileprivate static func anchorLimit(for mode: TransportMode) -> Int {
        switch mode {
        case .walking, .running, .cycling, .automotive:
            return 6
        case .train:
            return 5
        case .plane:
            return 2
        case .swimming, .boat, .stationary, .unknown:
            return 4
        }
    }
}

// MARK: - Summaries

enum RouteMatchSummaries {
    static let estimatedNoFixes = "Estimated: no fixes between places"
    static let estimated = "Estimated"
    static let estimatedGreatCircle = "Estimated great-circle path"
    static let manual = "Manual"
    static let partlyOffPath = "Partly off-path (park/beach)"

    static func recorded(usesRouteTracking: Bool) -> String {
        usesRouteTracking ? "Recorded (route tracking)" : "Recorded"
    }

    static func matched(
        mode: TransportMode,
        percentWithinCorridor: Int,
        typicalDeviationMeters: Int
    ) -> String {
        let surface: String
        switch mode {
        case .walking, .running:
            surface = "footpaths"
        case .cycling:
            surface = "paths"
        default:
            surface = "roads"
        }
        return "Matched to \(surface) · \(percentWithinCorridor)% of fixes within \(typicalDeviationMeters) m"
    }
}

// MARK: - Plausibility

enum RouteMatchPlausibility {
    static func isAcceptable(
        _ matched: [CLLocationCoordinate2D],
        comparedTo recorded: [CLLocationCoordinate2D],
        transportMode: TransportMode,
        corridorMeters: CLLocationDistance? = nil,
        maximumLengthRatio: Double? = nil,
        medianAccuracy: CLLocationAccuracy = 0
    ) -> Bool {
        guard matched.count > 1 else { return false }
        guard recorded.count > 2 else { return true }

        let recordedDistance = routeDistance(for: recorded)
        guard recordedDistance >= 50 else { return true }

        let matchedDistance = routeDistance(for: matched)
        let ratio = maximumLengthRatio ?? Self.maximumLengthRatio(for: transportMode)
        let maximumDistance = max(
            recordedDistance * ratio,
            recordedDistance + absoluteLengthAllowance(for: transportMode)
        )
        guard matchedDistance <= maximumDistance else {
            return false
        }

        let corridor = corridorMeters ?? Self.corridorMeters(
            for: transportMode,
            medianAccuracy: medianAccuracy
        )
        let maximumDeviation = maximumRecordedPointDeviation(recorded, from: matched)
        return maximumDeviation <= corridor
    }

    static func selectionScore(
        for matched: [CLLocationCoordinate2D],
        comparedTo recorded: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        guard !recorded.isEmpty else {
            return routeDistance(for: matched)
        }

        let meanDeviation = recorded.reduce(0) { partialResult, coordinate in
            partialResult + distance(from: coordinate, to: matched)
        } / Double(recorded.count)
        let lengthDifference = abs(routeDistance(for: matched) - routeDistance(for: recorded))
        return meanDeviation + (lengthDifference * 0.05)
    }

    /// Walking 25 m, cycling 35 m, automotive 60 m, scaled up by GPS accuracy.
    static func corridorMeters(
        for mode: TransportMode,
        medianAccuracy: CLLocationAccuracy
    ) -> CLLocationDistance {
        let base: CLLocationDistance
        switch mode {
        case .walking, .running:
            base = 25
        case .cycling:
            base = 35
        case .automotive:
            base = 60
        case .train:
            base = 80
        case .swimming, .plane, .boat, .stationary, .unknown:
            base = 60
        }
        return max(base, medianAccuracy)
    }

    static func allIntermediateFixes(
        _ recorded: [CLLocationCoordinate2D],
        lieWithin meters: CLLocationDistance,
        of matched: [CLLocationCoordinate2D]
    ) -> Bool {
        recorded.dropFirst().dropLast().allSatisfy { coordinate in
            distance(from: coordinate, to: matched) <= meters
        }
    }

    static func distance(
        from coordinate: CLLocationCoordinate2D,
        to polyline: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        guard let first = polyline.first else {
            return .greatestFiniteMagnitude
        }
        guard polyline.count > 1 else {
            return RouteCoordinateOps.distanceMeters(from: coordinate, to: first)
        }

        let point = MKMapPoint(coordinate)
        var minimumDistance = CLLocationDistance.greatestFiniteMagnitude

        for pair in zip(polyline, polyline.dropFirst()) {
            let start = MKMapPoint(pair.0)
            let end = MKMapPoint(pair.1)
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let squaredLength = (deltaX * deltaX) + (deltaY * deltaY)

            let projection: MKMapPoint
            if squaredLength == 0 {
                projection = start
            } else {
                let rawFraction = (
                    ((point.x - start.x) * deltaX) +
                    ((point.y - start.y) * deltaY)
                ) / squaredLength
                let fraction = min(max(rawFraction, 0), 1)
                projection = MKMapPoint(
                    x: start.x + (deltaX * fraction),
                    y: start.y + (deltaY * fraction)
                )
            }

            minimumDistance = min(minimumDistance, point.distance(to: projection))
        }

        return minimumDistance
    }

    private static func maximumRecordedPointDeviation(
        _ recorded: [CLLocationCoordinate2D],
        from matched: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        let intermediatePoints = recorded.dropFirst().dropLast()
        return intermediatePoints.reduce(0) { maximum, coordinate in
            max(maximum, distance(from: coordinate, to: matched))
        }
    }

    private static func maximumLengthRatio(for mode: TransportMode) -> Double {
        switch mode {
        case .walking, .running:
            return 1.45
        case .cycling, .automotive:
            return 1.5
        case .train:
            return 1.8
        case .swimming, .plane, .boat, .stationary, .unknown:
            return 2
        }
    }

    private static func absoluteLengthAllowance(for mode: TransportMode) -> CLLocationDistance {
        switch mode {
        case .walking, .running:
            return 500
        case .cycling:
            return 800
        case .automotive:
            return 1_500
        case .train:
            return 3_000
        case .swimming, .plane, .boat, .stationary, .unknown:
            return 1_500
        }
    }
}

// MARK: - Memo

actor RouteMatchMemo {
    enum CacheEntry {
        case persistent([CLLocationCoordinate2D])
        case transient([CLLocationCoordinate2D])
        case rejected(RouteMatchResolution)
    }

    private struct TransientCacheEntry {
        let coordinates: [CLLocationCoordinate2D]
        let expiresAt: Date
    }

    private struct RejectedCacheEntry {
        let resolution: RouteMatchResolution
        let expiresAt: Date
    }

    private var cache: [Int: [CLLocationCoordinate2D]] = [:]
    private var transientCache: [Int: TransientCacheEntry] = [:]
    private var rejectedCache: [Int: RejectedCacheEntry] = [:]
    private var inFlightTasks: [Int: Task<RouteMatchResolution, Never>] = [:]

    func cached(for key: Int, now: Date = .now) -> CacheEntry? {
        if let persistent = cache[key] {
            return .persistent(persistent)
        }

        if let rejected = rejectedCache[key] {
            if rejected.expiresAt <= now {
                rejectedCache.removeValue(forKey: key)
            } else {
                return .rejected(rejected.resolution)
            }
        }

        guard let transient = transientCache[key] else {
            return nil
        }

        if transient.expiresAt <= now {
            transientCache.removeValue(forKey: key)
            return nil
        }

        return .transient(transient.coordinates)
    }

    func storePersistent(_ coordinates: [CLLocationCoordinate2D], for key: Int) {
        cache[key] = coordinates
        transientCache.removeValue(forKey: key)
        rejectedCache.removeValue(forKey: key)
    }

    func storeTransient(
        _ coordinates: [CLLocationCoordinate2D],
        for key: Int,
        ttl: TimeInterval,
        now: Date = .now
    ) {
        guard ttl > 0 else { return }
        transientCache[key] = TransientCacheEntry(
            coordinates: coordinates,
            expiresAt: now.addingTimeInterval(ttl)
        )
        rejectedCache.removeValue(forKey: key)
    }

    func storeRejected(
        _ resolution: RouteMatchResolution,
        for key: Int,
        ttl: TimeInterval,
        now: Date = .now
    ) {
        guard ttl > 0 else { return }
        rejectedCache[key] = RejectedCacheEntry(
            resolution: resolution,
            expiresAt: now.addingTimeInterval(ttl)
        )
        transientCache.removeValue(forKey: key)
        cache.removeValue(forKey: key)
    }

    func inFlightTask(for key: Int) -> Task<RouteMatchResolution, Never>? {
        inFlightTasks[key]
    }

    func setInFlightTask(_ task: Task<RouteMatchResolution, Never>?, for key: Int) {
        inFlightTasks[key] = task
    }

    func reset() {
        cache = [:]
        transientCache = [:]
        rejectedCache = [:]
        inFlightTasks = [:]
    }
}

// MARK: - Limiter

actor DirectionsRequestLimiter {
    static let shared = DirectionsRequestLimiter()

    static let maxRequestsPerWindow = 42
    static let maxRequestsPerDay = 400

    private let windowDuration: TimeInterval = 60
    private var requestDates: [Date] = []
    private var cooldownUntil: Date?
    private var dayStamp = ""
    private var requestsToday = 0

    func reserveSlot(now: Date = .now) -> Bool {
        prune(now)

        if let cooldownUntil, now < cooldownUntil {
            return false
        }

        let today = Self.dayKey(now)
        if today != dayStamp {
            dayStamp = today
            requestsToday = 0
        }

        if requestsToday >= Self.maxRequestsPerDay {
            return false
        }

        guard requestDates.count < Self.maxRequestsPerWindow else {
            return false
        }

        requestDates.append(now)
        requestsToday += 1
        return true
    }

    func registerFailure(_ error: Error, now: Date = .now) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "GEOErrorDomain" else {
            return false
        }

        var resetAfterSeconds: TimeInterval?
        if let number = nsError.userInfo["timeUntilReset"] as? NSNumber {
            resetAfterSeconds = number.doubleValue
        } else if let value = nsError.userInfo["timeUntilReset"] as? Double {
            resetAfterSeconds = value
        } else if let value = nsError.userInfo["timeUntilReset"] as? Int {
            resetAfterSeconds = Double(value)
        } else if
            let details = nsError.userInfo["details"] as? [[String: Any]],
            let first = details.first,
            let value = first["timeUntilReset"] {
            if let number = value as? NSNumber {
                resetAfterSeconds = number.doubleValue
            } else if let double = value as? Double {
                resetAfterSeconds = double
            } else if let int = value as? Int {
                resetAfterSeconds = Double(int)
            }
        }

        guard nsError.code == -3 || resetAfterSeconds != nil else {
            return false
        }

        let cooldown = max(resetAfterSeconds ?? 60, 1)
        cooldownUntil = now.addingTimeInterval(cooldown)
        return true
    }

    func reset() {
        requestDates = []
        cooldownUntil = nil
        dayStamp = ""
        requestsToday = 0
    }

    private func prune(_ now: Date) {
        requestDates.removeAll { now.timeIntervalSince($0) >= windowDuration }
        if let cooldownUntil, now >= cooldownUntil {
            self.cooldownUntil = nil
        }
    }

    private static func dayKey(_ now: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

// MARK: - Background retry for imports

enum RouteMatchBackgroundTask {
    /// Must stay in sync with `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
    static let taskIdentifier = "\(MovesAppIdentity.bundleIdentifier).routeMatching"

    static func register() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func scheduleNextRun(now: Date = .now) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(26 * 60 * 60)
        request.earliestBeginDate = tomorrow
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNextRun()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                await rematchPendingMoves(in: container)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }

    @MainActor
    private static func rematchPendingMoves(in container: ModelContainer) async {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.routeMatchPolicyRaw == "auto" && move.routeCacheCoordinatesData == nil
            }
        )
        descriptor.fetchLimit = 40
        guard let moves = try? context.fetch(descriptor) else { return }

        for move in moves {
            _ = await RoadRouteMatcher.matchedCoordinates(for: move)
            if Task.isCancelled { break }
        }
        try? context.save()
    }
}

extension MKPolyline {
    var allCoordinates: [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }

        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
