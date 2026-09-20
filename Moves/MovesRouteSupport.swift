//
//  MovesRouteSupport.swift
//  Raul
//
//  Shared route rendering helpers used by timeline and detail views.
//

import Foundation
import SwiftUI
import MapKit
import UIKit

enum MovesPalette {
    static let backgroundTop = Color(uiColor: .systemGroupedBackground)
    static let backgroundBottom = Color(uiColor: .secondarySystemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.45)
    static let rail = Color(uiColor: .separator).opacity(0.75)
    static let textFieldBackground = Color(uiColor: .tertiarySystemBackground)
    static let frostedFill = Color(uiColor: .tertiarySystemFill)
    static let place = Color("MovesPlace")
    static let move = Color("MovesMove")
    static let start = Color("MovesStart")
    static let routeTracking = Color("MovesRouteTracking")
    static let healthRoute = Color(uiColor: .systemPink)

    static func transport(_ mode: TransportMode) -> Color {
        Color(transportColorAssetName(for: mode))
    }

    static func transportColorAssetName(for mode: TransportMode) -> String {
        switch mode {
        case .walking:
            return "MovesTransportWalking"
        case .running:
            return "MovesTransportRunning"
        case .swimming:
            return "MovesTransportBoat"
        case .cycling:
            return "MovesTransportCycling"
        case .automotive:
            return "MovesTransportAutomotive"
        case .train:
            return "MovesTransportTrain"
        case .plane:
            return "MovesTransportPlane"
        case .boat:
            return "MovesTransportBoat"
        case .stationary, .unknown:
            return "MovesTransportUnknown"
        }
    }

    /// Lightens `base` as `fraction` goes from 0 (slow) to 1 (fast).
    static func speedShade(base: Color, fraction: Double) -> Color {
        let t = min(max(fraction, 0), 1)
        return base.mix(with: .white, by: t * 0.42)
    }
}

enum DurationFormatter {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func text(for duration: TimeInterval) -> String {
        formatter.string(from: max(duration, 0)) ?? "0m"
    }

    /// One-line stay or chip duration. Sub-minute stays are `<1m`, not `0m`.
    static func compactText(for duration: TimeInterval) -> String {
        if duration < 60 {
            return String(localized: "<1m")
        }
        return text(for: duration)
    }
}

struct LiveRouteTrackingSnapshot {
    let startDate: Date
    let latestDate: Date
    let sampleCount: Int
    let distanceMeters: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]

    var id: String {
        [
            Int(startDate.timeIntervalSince1970.rounded()),
            Int(latestDate.timeIntervalSince1970.rounded()),
            sampleCount,
            Int(distanceMeters.rounded())
        ]
        .map(String.init)
        .joined(separator: "|")
    }

    var duration: TimeInterval {
        max(latestDate.timeIntervalSince(startDate), 0)
    }
}

struct RouteCoordinateStoragePoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteCoordinateStorage {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> Data? {
        let payload = coordinates.map(RouteCoordinateStoragePoint.init)
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data?) -> [CLLocationCoordinate2D] {
        guard let data else { return [] }

        guard let payload = try? decoder.decode([RouteCoordinateStoragePoint].self, from: data) else {
            return []
        }

        return payload.map(\.coordinate)
    }
}

@MainActor
func liveRouteTrackingSnapshot(
    for dayTimeline: DayTimeline,
    captureManager: MovesLocationCaptureManager
) -> LiveRouteTrackingSnapshot? {
    guard let endsAt = captureManager.temporaryRouteTrackingEndsAt, endsAt > .now else {
        return nil
    }

    let sortedSamples = dayTimeline.samples.sorted(by: { $0.timestamp < $1.timestamp })
    let preferredSamples = sortedSamples.preferredRouteDisplaySamples

    let liveSamples = liveRouteSessionSamples(
        from: preferredSamples,
        startedAt: captureManager.temporaryRouteTrackingStartedAt
    )

    let startDate = captureManager.temporaryRouteTrackingStartedAt
        ?? liveSamples.first?.timestamp
        ?? captureManager.lastCaptureAt
        ?? endsAt
    let latestDate = liveSamples.last?.timestamp ?? captureManager.lastCaptureAt ?? startDate
    let anchorCoordinate = liveRouteAnchorCoordinate(for: dayTimeline, startDate: startDate)

    var coordinates = liveSamples.map(\.coordinate)
    if let anchorCoordinate {
        coordinates.insert(anchorCoordinate, at: 0)
    }

    coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
        coordinates,
        minimumDistanceMeters: 4
    )

    return LiveRouteTrackingSnapshot(
        startDate: startDate,
        latestDate: latestDate,
        sampleCount: liveSamples.count,
        distanceMeters: routeDistance(for: coordinates),
        coordinates: coordinates
    )
}

func liveRouteSessionSamples(
    from preferredSamples: [LocationSample],
    startedAt: Date?
) -> [LocationSample] {
    guard !preferredSamples.isEmpty else { return [] }

    if let startedAt {
        return preferredSamples.filter { $0.timestamp >= startedAt }
    }

    guard let lastSample = preferredSamples.last else {
        return []
    }

    let maximumGap: TimeInterval = 90 * 60
    var sessionSamples: [LocationSample] = [lastSample]
    var previousSample = lastSample

    for sample in preferredSamples.dropLast().reversed() {
        let gap = previousSample.timestamp.timeIntervalSince(sample.timestamp)
        if gap > maximumGap {
            break
        }

        sessionSamples.insert(sample, at: 0)
        previousSample = sample
    }

    return sessionSamples
}

func liveRouteAnchorCoordinate(
    for dayTimeline: DayTimeline,
    startDate: Date
) -> CLLocationCoordinate2D? {
    let sortedPlaces = dayTimeline.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
    if let anchorPlace = sortedPlaces.last(where: { $0.arrivalDate <= startDate }) {
        return anchorPlace.coordinate
    }
    return sortedPlaces.last?.coordinate
}

func routeDistance(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    guard coordinates.count > 1 else { return 0 }

    return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
        partialResult + RouteCoordinateOps.distanceMeters(from: pair.0, to: pair.1)
    }
}

enum MapRegionFactory {
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latitudeDelta = max((maxLat - minLat) * 1.5, 0.01)
        let longitudeDelta = max((maxLon - minLon) * 1.5, 0.01)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

enum MoveRouteGeometry {
    private static let routeMatchingVersion = "route-v9-plausibility-fallback"

    static func rawCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        let sampleCoordinates = move.samples.preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map(\.coordinate)

        if move.usesHealthWorkoutRoute, sampleCoordinates.count > 1 {
            return RouteCoordinateOps.dedupeSequentialCoordinates(
                sampleCoordinates,
                minimumDistanceMeters: rawCoordinateDedupeDistance(for: move)
            )
        }

        var coordinates: [CLLocationCoordinate2D] = []
        if let start = move.startPlace?.coordinate {
            coordinates.append(start)
        }
        coordinates.append(contentsOf: sampleCoordinates)
        if let end = move.endPlace?.coordinate {
            coordinates.append(end)
        }

        return RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates,
            minimumDistanceMeters: rawCoordinateDedupeDistance(for: move)
        )
    }

    static func rawCoordinateDedupeDistance(for move: MoveSegment) -> CLLocationDistance {
        move.usesHealthWorkoutRoute ? 0 : 6
    }

    static func highAccuracyDisplayDedupeDistance(for move: MoveSegment) -> CLLocationDistance {
        move.usesHealthWorkoutRoute ? 0 : 4
    }

    static func cacheSignature(for move: MoveSegment, fallback: [CLLocationCoordinate2D]) -> String {
        var components: [String] = [
            routeMatchingVersion,
            move.id.uuidString,
            move.transportMode.rawValue,
            String(Int(move.timelineStartDate.timeIntervalSince1970.rounded())),
            String(Int(move.endDate.timeIntervalSince1970.rounded())),
            String(fallback.count)
        ]

        components.reserveCapacity(components.count + fallback.count)
        components.append(contentsOf: fallback.map { coordinate in
            let latitude = Int((coordinate.latitude * 10_000).rounded())
            let longitude = Int((coordinate.longitude * 10_000).rounded())
            return "\(latitude):\(longitude)"
        })

        return components.joined(separator: "|")
    }

    static func cacheKey(for move: MoveSegment, fallback: [CLLocationCoordinate2D]) -> Int {
        var hasher = Hasher()
        hasher.combine(routeMatchingVersion)
        hasher.combine(move.id)
        hasher.combine(move.transportMode.rawValue)
        hasher.combine(Int(move.timelineStartDate.timeIntervalSince1970.rounded()))
        hasher.combine(Int(move.endDate.timeIntervalSince1970.rounded()))
        hasher.combine(fallback.count)

        for coordinate in fallback {
            hasher.combine(Int((coordinate.latitude * 10_000).rounded()))
            hasher.combine(Int((coordinate.longitude * 10_000).rounded()))
        }

        return hasher.finalize()
    }
}

extension MoveSegment {
    var hasManualRouteCoordinates: Bool {
        manualRouteCoordinatesData != nil
    }

    var manualRouteCoordinates: [CLLocationCoordinate2D]? {
        let coordinates = RouteCoordinateStorage.decode(manualRouteCoordinatesData)
        return coordinates.count > 1 ? coordinates : nil
    }

    var preferredRouteCoordinates: [CLLocationCoordinate2D]? {
        manualRouteCoordinates
    }

    func storeManualRouteCoordinates(_ coordinates: [CLLocationCoordinate2D]) {
        manualRouteCoordinatesData = RouteCoordinateStorage.encode(coordinates)
    }

    func clearManualRouteCoordinates() {
        manualRouteCoordinatesData = nil
    }

    var routeDisplayTint: Color {
        MovesPalette.transport(transportMode)
    }
}

enum RouteCoordinateOps {
    static func dedupeSequentialCoordinates(
        _ coordinates: [CLLocationCoordinate2D],
        minimumDistanceMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }

        var deduped: [CLLocationCoordinate2D] = [first]
        deduped.reserveCapacity(coordinates.count)

        for coordinate in coordinates.dropFirst() {
            if distanceMeters(from: deduped[deduped.count - 1], to: coordinate) < minimumDistanceMeters {
                continue
            }
            deduped.append(coordinate)
        }

        if deduped.count == 1,
           let last = coordinates.last,
           distanceMeters(from: first, to: last) > 0 {
            deduped.append(last)
        }

        return deduped
    }

    static func sampleAnchors(
        from coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        sampleAnchorIndices(from: coordinates, maximumCount: maximumCount)
            .map { coordinates[$0] }
    }

    static func sampleAnchorIndices(
        from coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [Int] {
        guard !coordinates.isEmpty else { return [] }
        guard maximumCount > 1 else { return [coordinates.startIndex] }
        guard coordinates.count > maximumCount else {
            return Array(coordinates.indices)
        }

        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        var sampledIndices: [Int] = []
        sampledIndices.reserveCapacity(maximumCount)

        for index in 0..<maximumCount {
            let rawIndex = Int((Double(index) * step).rounded(.toNearestOrAwayFromZero))
            sampledIndices.append(min(rawIndex, coordinates.count - 1))
        }

        var dedupedIndices: [Int] = []
        dedupedIndices.reserveCapacity(sampledIndices.count)

        for index in sampledIndices {
            guard dedupedIndices.last != index else { continue }

            let isEndpoint = index == coordinates.startIndex || index == coordinates.index(before: coordinates.endIndex)
            if !isEndpoint,
               let previousIndex = dedupedIndices.last,
               distanceMeters(from: coordinates[previousIndex], to: coordinates[index]) < 25 {
                continue
            }

            dedupedIndices.append(index)
        }

        let lastIndex = coordinates.index(before: coordinates.endIndex)
        if dedupedIndices.last != lastIndex {
            dedupedIndices.append(lastIndex)
        }

        return dedupedIndices
    }

    static func append(_ coordinates: [CLLocationCoordinate2D], to route: inout [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        if route.isEmpty {
            route.append(contentsOf: coordinates)
            return
        }

        let first = coordinates[coordinates.startIndex]
        if let last = route.last, distanceMeters(from: last, to: first) < 4 {
            route.append(contentsOf: coordinates.dropFirst())
            return
        }

        route.append(contentsOf: coordinates)
    }

    static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}

enum PlaneRouteGeometry {
    static func arcCoordinates(from fallback: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let start = fallback.first, let end = fallback.last else {
            return fallback
        }

        guard RouteCoordinateOps.distanceMeters(from: start, to: end) > 15 else {
            return [start, end]
        }

        return arcCoordinates(from: start, to: end)
    }

    private static func arcCoordinates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let latitudeDelta = end.latitude - start.latitude
        let longitudeDelta = end.longitude - start.longitude
        let vectorLength = max(hypot(latitudeDelta, longitudeDelta), 0.0001)

        let midpoint = CLLocationCoordinate2D(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2
        )

        let perpendicular = CLLocationCoordinate2D(
            latitude: -longitudeDelta / vectorLength,
            longitude: latitudeDelta / vectorLength
        )

        let span = max(abs(latitudeDelta), abs(longitudeDelta))
        let curvature = min(max(span * 0.35, 0.02), 5.5)
        let preferredVerticalDirection = midpoint.latitude >= 0 ? 1.0 : -1.0
        let bendSign = (perpendicular.latitude * preferredVerticalDirection) >= 0 ? 1.0 : -1.0

        var controlLatitude = midpoint.latitude + (perpendicular.latitude * curvature * bendSign)
        let controlLongitude = midpoint.longitude + (perpendicular.longitude * curvature * bendSign)

        // Keep the arch consistently above the shadow line in the north and below in the south.
        if (controlLatitude - midpoint.latitude) * preferredVerticalDirection <= 0 {
            controlLatitude = midpoint.latitude + (preferredVerticalDirection * max(curvature * 0.28, 0.012))
        }

        controlLatitude = min(max(controlLatitude, -85), 85)

        let control = CLLocationCoordinate2D(
            latitude: controlLatitude,
            longitude: controlLongitude
        )

        let pointCount = max(min(Int(span * 14), 84), 28)
        return (0...pointCount).map { index in
            let t = Double(index) / Double(pointCount)
            let inverseT = 1 - t

            let latitude =
                (inverseT * inverseT * start.latitude) +
                (2 * inverseT * t * control.latitude) +
                (t * t * end.latitude)

            let longitude =
                (inverseT * inverseT * start.longitude) +
                (2 * inverseT * t * control.longitude) +
                (t * t * end.longitude)

            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}

@MainActor
enum ManualRouteGeometry {
    static func waypoints(
        for route: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) -> [CLLocationCoordinate2D] {
        guard route.count > 1 else { return route }

        if transportMode == .boat {
            return RouteCoordinateOps.sampleAnchors(from: route, maximumCount: 8)
        }

        return RoadRouteMatcher.routeAnchors(for: route, transportMode: transportMode)
    }

    static func editAnchors(
        currentRoute: [CLLocationCoordinate2D],
        draggedCoordinate: CLLocationCoordinate2D,
        transportMode: TransportMode,
        closestIndex: Int
    ) -> [CLLocationCoordinate2D] {
        guard currentRoute.count > 1 else {
            return currentRoute
        }

        var anchors = waypoints(for: currentRoute, transportMode: transportMode)
        let insertionIndex = nearestInsertionIndex(
            in: anchors,
            originalRoute: currentRoute,
            closestIndex: closestIndex
        )
        anchors.insert(draggedCoordinate, at: insertionIndex)
        return RouteCoordinateOps.dedupeSequentialCoordinates(
            anchors,
            minimumDistanceMeters: transportMode == .boat ? 3 : 6
        )
    }

    static func previewAnchors(
        currentRoute: [CLLocationCoordinate2D],
        draggedCoordinate: CLLocationCoordinate2D,
        transportMode: TransportMode,
        closestIndex: Int
    ) -> [CLLocationCoordinate2D] {
        guard currentRoute.count > 1 else {
            return currentRoute
        }

        let anchors = editAnchors(
            currentRoute: currentRoute,
            draggedCoordinate: draggedCoordinate,
            transportMode: transportMode,
            closestIndex: closestIndex
        )

        if transportMode == .boat {
            return splineCoordinates(for: anchors)
        }

        return anchors
    }

    static func committedCoordinates(
        currentRoute: [CLLocationCoordinate2D],
        draggedCoordinate: CLLocationCoordinate2D,
        transportMode: TransportMode,
        closestIndex: Int
    ) async -> [CLLocationCoordinate2D] {
        guard currentRoute.count > 1 else {
            return currentRoute
        }

        if transportMode == .boat {
            return previewAnchors(
                currentRoute: currentRoute,
                draggedCoordinate: draggedCoordinate,
                transportMode: transportMode,
                closestIndex: closestIndex
            )
        }

        let anchors = editAnchors(
            currentRoute: currentRoute,
            draggedCoordinate: draggedCoordinate,
            transportMode: transportMode,
            closestIndex: closestIndex
        )
        return await RoadRouteMatcher.matchedManualCoordinates(
            for: anchors,
            transportMode: transportMode
        )
    }

    private static func nearestInsertionIndex(
        in anchors: [CLLocationCoordinate2D],
        originalRoute: [CLLocationCoordinate2D],
        closestIndex: Int
    ) -> Int {
        guard anchors.count > 1 else { return anchors.endIndex }
        guard !originalRoute.isEmpty else { return anchors.endIndex }

        let clampedIndex = min(max(closestIndex, 0), originalRoute.count - 1)
        let closestCoordinate = originalRoute[clampedIndex]

        let nearestAnchorIndex = anchors.enumerated().min { lhs, rhs in
            RouteCoordinateOps.distanceMeters(from: lhs.element, to: closestCoordinate)
                < RouteCoordinateOps.distanceMeters(from: rhs.element, to: closestCoordinate)
        }?.offset ?? anchors.count / 2

        if nearestAnchorIndex == 0 { return 1 }
        if nearestAnchorIndex >= anchors.count - 1 { return anchors.count - 1 }
        return nearestAnchorIndex
    }

    private static func splineCoordinates(for anchors: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard anchors.count > 2 else {
            return anchors
        }

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(anchors.count * 12)

        for index in 0..<(anchors.count - 1) {
            let p0 = anchors[max(index - 1, 0)]
            let p1 = anchors[index]
            let p2 = anchors[index + 1]
            let p3 = anchors[min(index + 2, anchors.count - 1)]

            for step in 0..<12 {
                let t = Double(step) / 12.0
                coordinates.append(catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }

        if let last = anchors.last {
            coordinates.append(last)
        }

        return RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates,
            minimumDistanceMeters: 3
        )
    }

    private static func catmullRom(
        p0: CLLocationCoordinate2D,
        p1: CLLocationCoordinate2D,
        p2: CLLocationCoordinate2D,
        p3: CLLocationCoordinate2D,
        t: Double
    ) -> CLLocationCoordinate2D {
        let t2 = t * t
        let t3 = t2 * t

        func value(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) -> Double {
            0.5 * (
                (2 * v1) +
                (-v0 + v2) * t +
                (2 * v0 - 5 * v1 + 4 * v2 - v3) * t2 +
                (-v0 + 3 * v1 - 3 * v2 + v3) * t3
            )
        }

        return CLLocationCoordinate2D(
            latitude: value(p0.latitude, p1.latitude, p2.latitude, p3.latitude),
            longitude: value(p0.longitude, p1.longitude, p2.longitude, p3.longitude)
        )
    }
}

