import CoreLocation
import Foundation
import MapKit
import SwiftData

/// A nearby name the user can pick in the rename sheet.
struct NearbyPlaceCandidate: Identifiable, Equatable {
    /// Whether the candidate is already a learned place or an Apple search hit.
    enum Source: Equatable {
        case knownPlace(id: UUID)
        case search
    }

    var id: String
    var name: String
    var subtitle: String?
    var distanceMeters: CLLocationDistance
    var latitude: Double
    var longitude: Double
    var source: Source
    var confirmedVisitCount: Int
}

/// A map search result that tests can inject without calling `MKLocalSearch`.
struct NearbySearchHit: Equatable, Sendable {
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double
}

/// Looks up Apple Places / addresses around a coordinate.
protocol LocalPlaceSearching: Sendable {
    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit]
}

/// Production searcher wrapping `MKLocalSearch` / points-of-interest requests.
struct MapKitLocalPlaceSearcher: LocalPlaceSearching {
    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response: MKLocalSearch.Response
        if trimmed.isEmpty {
            let request = MKLocalPointsOfInterestRequest(
                center: coordinate,
                radius: NearbyPlaceSuggester.searchRadius
            )
            response = try await MKLocalSearch(request: request).start()
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = [.pointOfInterest, .address]
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: NearbyPlaceSuggester.searchRadius * 2,
                longitudinalMeters: NearbyPlaceSuggester.searchRadius * 2
            )
            response = try await MKLocalSearch(request: request).start()
        }

        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems.compactMap { item in
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            let coordinate = Self.coordinate(of: item)
            let distance = origin.distance(
                from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            guard distance <= NearbyPlaceSuggester.searchRadius * 1.25 else { return nil }
            return NearbySearchHit(
                name: name,
                subtitle: Self.subtitle(of: item),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }

    private static func subtitle(of item: MKMapItem) -> String? {
        let address = item.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address, !address.isEmpty, address != item.name {
            return address
        }
        return nil
    }
}

/// Merges learned places with Apple search hits for the rename sheet.
///
/// Known places within 250 m come first (most confirmed visits, then nearest).
/// Apple POIs fill the remaining slots. Names the user has rejected at nearby
/// learned places are omitted.
struct NearbyPlaceSuggester {
    static let searchRadius: CLLocationDistance = 250
    static let maximumCandidates = 5

    var searcher: any LocalPlaceSearching

    init(searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()) {
        self.searcher = searcher
    }

    /// Loads Apple hits then merges them with `knownPlaces`.
    func suggestions(
        for visit: VisitPlace,
        knownPlaces: [KnownPlace],
        query: String?
    ) async -> [NearbyPlaceCandidate] {
        await suggestions(near: visit.coordinate, knownPlaces: knownPlaces, query: query)
    }

    /// Coordinate-based lookup used by the confirm form when the pin moves.
    func suggestions(
        near coordinate: CLLocationCoordinate2D,
        knownPlaces: [KnownPlace],
        query: String?,
        limit: Int = maximumCandidates
    ) async -> [NearbyPlaceCandidate] {
        let hits: [NearbySearchHit]
        do {
            hits = try await searcher.search(near: coordinate, query: query)
        } catch {
            hits = []
        }
        return Self.merge(
            visitCoordinate: coordinate,
            knownPlaces: knownPlaces,
            searchHits: hits,
            query: query,
            limit: limit
        )
    }

    /// Pure merge used by tests and by the sheet's two-phase load (known places first).
    static func merge(
        visitCoordinate: CLLocationCoordinate2D,
        knownPlaces: [KnownPlace],
        searchHits: [NearbySearchHit],
        query: String?,
        limit: Int = maximumCandidates
    ) -> [NearbyPlaceCandidate] {
        let origin = CLLocation(latitude: visitCoordinate.latitude, longitude: visitCoordinate.longitude)
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let nearbyKnown = knownPlaces.filter { place in
            origin.distance(
                from: CLLocation(latitude: place.centerLatitude, longitude: place.centerLongitude)
            ) <= searchRadius
        }

        let rejected = Set(
            nearbyKnown
                .flatMap(\.rejectedAutoLabels)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        func matchesQuery(_ name: String) -> Bool {
            guard !trimmedQuery.isEmpty else { return true }
            return name.localizedCaseInsensitiveContains(trimmedQuery)
        }

        let knownCandidates: [NearbyPlaceCandidate] = nearbyKnown.compactMap { place in
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, matchesQuery(name) else { return nil }
            let distance = origin.distance(
                from: CLLocation(latitude: place.centerLatitude, longitude: place.centerLongitude)
            )
            return NearbyPlaceCandidate(
                id: "known-\(place.id.uuidString)",
                name: name,
                subtitle: place.locality,
                distanceMeters: distance,
                latitude: place.centerLatitude,
                longitude: place.centerLongitude,
                source: .knownPlace(id: place.id),
                confirmedVisitCount: place.confirmedVisitCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.confirmedVisitCount != rhs.confirmedVisitCount {
                return lhs.confirmedVisitCount > rhs.confirmedVisitCount
            }
            return lhs.distanceMeters < rhs.distanceMeters
        }

        let knownNames = Set(knownCandidates.map { $0.name.lowercased() })

        let searchCandidates: [NearbyPlaceCandidate] = searchHits.compactMap { hit in
            let name = hit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, matchesQuery(name) else { return nil }
            let lowered = name.lowercased()
            guard !knownNames.contains(lowered), !rejected.contains(lowered) else { return nil }
            let distance = origin.distance(
                from: CLLocation(latitude: hit.latitude, longitude: hit.longitude)
            )
            guard distance <= searchRadius * 1.25 else { return nil }
            return NearbyPlaceCandidate(
                id: "search-\(String(format: "%.5f", hit.latitude))-\(String(format: "%.5f", hit.longitude))-\(lowered)",
                name: name,
                subtitle: hit.subtitle,
                distanceMeters: distance,
                latitude: hit.latitude,
                longitude: hit.longitude,
                source: .search,
                confirmedVisitCount: 0
            )
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }

        var combined = Array(knownCandidates.prefix(limit))
        if combined.count < limit {
            combined.append(contentsOf: searchCandidates.prefix(limit - combined.count))
        }
        return combined
    }
}

/// Shared rules for the Review inbox and for flagging items at ingest.
enum TimelineReviewHeuristics {
    static let shortStopDuration: TimeInterval = 4 * 60
    static let headingAlignmentDegrees: Double = 30
    static let uncertainModeConfidence = 0.6
    static let longVisitDeleteConfirmation: TimeInterval = 60 * 60

    static func stayDuration(of visit: VisitPlace) -> TimeInterval? {
        guard let departure = visit.departureDate, departure > visit.arrivalDate else {
            return nil
        }
        return departure.timeIntervalSince(visit.arrivalDate)
    }

    /// Brief stay with both an inbound and outbound move — candidate for "not a stop".
    static func isShortTransitStop(_ visit: VisitPlace) -> Bool {
        guard let duration = stayDuration(of: visit), duration < shortStopDuration else {
            return false
        }
        return !visit.incomingMoves.isEmpty && !visit.outgoingMoves.isEmpty
    }

    /// Short transit whose in/out path headings agree within 30°.
    static func isPossibleFalseStop(_ visit: VisitPlace) -> Bool {
        guard isShortTransitStop(visit) else { return false }
        let incoming = visit.incomingMoves.sorted { $0.endDate < $1.endDate }.last
        let outgoing = visit.outgoingMoves.sorted { $0.startDate < $1.startDate }.first
        guard let incoming, let outgoing else { return false }
        return headingsAreAligned(incoming: incoming, outgoing: outgoing)
    }

    static func headingsAreAligned(incoming: MoveSegment, outgoing: MoveSegment) -> Bool {
        let incomingHeading = heading(along: TimelineLocator.displayedCoordinates(for: incoming), fromEnd: true)
        let outgoingHeading = heading(along: TimelineLocator.displayedCoordinates(for: outgoing), fromEnd: false)
        guard let incomingHeading, let outgoingHeading else { return false }
        return angularDifference(incomingHeading, outgoingHeading) <= headingAlignmentDegrees
    }

    static func heading(
        along coordinates: [CLLocationCoordinate2D],
        fromEnd: Bool
    ) -> Double? {
        guard coordinates.count >= 2 else { return nil }
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        if fromEnd {
            end = coordinates[coordinates.count - 1]
            start = coordinates[coordinates.count - 2]
        } else {
            start = coordinates[0]
            end = coordinates[1]
        }
        return heading(from: start, to: end)
    }

    static func heading(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double? {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        guard abs(x) > .ulpOfOne || abs(y) > .ulpOfOne else { return nil }
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }
}

/// Neighbors used by swipe/context menus and merge actions.
enum TimelineNeighbors {
    static func previousVisit(for visit: VisitPlace) -> VisitPlace? {
        visit.incomingMoves.sorted { $0.endDate < $1.endDate }.last?.startPlace
    }

    static func nextVisit(for visit: VisitPlace) -> VisitPlace? {
        visit.outgoingMoves.sorted { $0.startDate < $1.startDate }.first?.endPlace
    }

    static func previousMove(for move: MoveSegment) -> MoveSegment? {
        move.startPlace?.incomingMoves.sorted { $0.endDate < $1.endDate }.last
    }

    static func nextMove(for move: MoveSegment) -> MoveSegment? {
        move.endPlace?.outgoingMoves.sorted { $0.startDate < $1.startDate }.first
    }
}
