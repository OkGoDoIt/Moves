import CoreLocation
import Foundation
import MapKit
import SwiftData

/// A nearby name the person can pick when naming a stay.
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
    /// Apple's point-of-interest category (`MKPointOfInterestCategory.rawValue`) for a
    /// search hit, or the stored `KnownPlace.category` for a learned place.
    var category: String? = nil
}

/// A map search result that tests can inject without calling `MKLocalSearch`.
struct NearbySearchHit: Equatable, Sendable {
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double
    /// `MKPointOfInterestCategory.rawValue`, when Apple gave one.
    var category: String? = nil
}

/// What naming needs from a `KnownPlace`, copied out so a lookup never holds a model
/// across an await (see Store safety in `CLAUDE.md`).
struct NearbyKnownPlace: Equatable, Sendable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var footprintRadius: Double
    var confirmedVisitCount: Int
    var locality: String?
    var category: String?
    var rejectedAutoLabels: [String]

    init(_ place: KnownPlace) {
        id = place.id
        name = place.name
        latitude = place.centerLatitude
        longitude = place.centerLongitude
        footprintRadius = place.footprintRadius
        confirmedVisitCount = place.confirmedVisitCount
        locality = place.locality
        category = place.category
        rejectedAutoLabels = place.rejectedAutoLabels
    }
}

/// Looks up Apple Places / addresses around a coordinate.
protocol LocalPlaceSearching: Sendable {
    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit]
    /// The same lookup with an explicit reach: the points-of-interest radius when there
    /// is no query, the region a typed query is biased to when there is one.
    func search(
        near coordinate: CLLocationCoordinate2D,
        query: String?,
        radius: CLLocationDistance
    ) async throws -> [NearbySearchHit]
}

extension LocalPlaceSearching {
    func search(
        near coordinate: CLLocationCoordinate2D,
        query: String?,
        radius: CLLocationDistance
    ) async throws -> [NearbySearchHit] {
        try await search(near: coordinate, query: query)
    }
}

/// Production searcher wrapping `MKLocalSearch` / points-of-interest requests.
struct MapKitLocalPlaceSearcher: LocalPlaceSearching {
    /// A typed result farther than this is another town, never this stay.
    static let farthestTypedResult: CLLocationDistance = 25_000

    /// The background name fill's lookup: 250 m, nothing past 1.25× that.
    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit] {
        let reach = NearbyPlaceSuggester.searchRadius
        let hits = try await search(near: coordinate, query: query, radius: reach)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return hits.filter {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= reach * 1.25
        }
    }

    func search(
        near coordinate: CLLocationCoordinate2D,
        query: String?,
        radius: CLLocationDistance
    ) async throws -> [NearbySearchHit] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let search: MKLocalSearch
        if trimmed.isEmpty {
            search = MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: coordinate, radius: radius))
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = [.pointOfInterest]
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
            search = MKLocalSearch(request: request)
        }
        let handle = LocalSearchHandle(search: search)
        let response = try await withTaskCancellationHandler {
            try await handle.search.start()
        } onCancel: {
            handle.search.cancel()
        }
        try Task.checkCancellation()

        let reach = trimmed.isEmpty ? radius * 1.25 : Self.farthestTypedResult
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems.compactMap { item in
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            let coordinate = Self.coordinate(of: item)
            let distance = origin.distance(
                from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            guard distance <= reach else { return nil }
            return NearbySearchHit(
                name: name,
                subtitle: Self.subtitle(of: item),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                category: item.pointOfInterestCategory?.rawValue
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

/// Lets a cancellation handler reach the search it has to stop.
private final class LocalSearchHandle: @unchecked Sendable {
    let search: MKLocalSearch

    init(search: MKLocalSearch) {
        self.search = search
    }
}

/// Merges learned places with Apple search hits into a handful of best guesses.
///
/// Learned places within 250 m come first: ones whose footprint holds the stay, then
/// most confirmed visits, then nearest. Apple places fill the remaining slots, ranked by
/// `PlaceNamingRanking.score`: close relative to how precise the stay is, and of a kind
/// people name stays after. Near-identical names appear once, and names the person
/// rejected at a nearby learned place are left out.
struct NearbyPlaceSuggester {
    /// Reach for learned places; also used by the background name fill and same-name lookups.
    static let searchRadius: CLLocationDistance = 250
    static let maximumCandidates = 5
    /// The Choose a Place list asks Apple for everything this far out first…
    static let listRadius: CLLocationDistance = 300
    /// …and this far when the first pass found fewer than `listTarget` places.
    static let widenedListRadius: CLLocationDistance = 600
    static let listTarget = 15
    /// A typed search is biased to this radius around the stay.
    static let typedSearchRadius: CLLocationDistance = 2_000

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

    /// Pure merge used by tests and by the two-phase load (known places first).
    static func merge(
        visitCoordinate: CLLocationCoordinate2D,
        knownPlaces: [KnownPlace],
        searchHits: [NearbySearchHit],
        query: String?,
        limit: Int = maximumCandidates,
        accuracy: CLLocationDistance = 0
    ) -> [NearbyPlaceCandidate] {
        merge(
            visitCoordinate: visitCoordinate,
            known: knownPlaces.map(NearbyKnownPlace.init),
            searchHits: searchHits,
            query: query,
            limit: limit,
            accuracy: accuracy
        )
    }

    static func merge(
        visitCoordinate: CLLocationCoordinate2D,
        known: [NearbyKnownPlace],
        searchHits: [NearbySearchHit],
        query: String?,
        limit: Int = maximumCandidates,
        accuracy: CLLocationDistance = 0
    ) -> [NearbyPlaceCandidate] {
        let reach = PlaceNamingRanking.stayReach(accuracy: accuracy)
        let knownCandidates = PlaceNamingRanking.knownCandidates(
            known,
            origin: visitCoordinate,
            within: searchRadius,
            query: query
        )
        .sorted { lhs, rhs in
            let lhsHolds = lhs.distanceMeters <= (lhs.footprint ?? 0) + reach
            let rhsHolds = rhs.distanceMeters <= (rhs.footprint ?? 0) + reach
            if lhsHolds != rhsHolds { return lhsHolds }
            if lhs.candidate.confirmedVisitCount != rhs.candidate.confirmedVisitCount {
                return lhs.candidate.confirmedVisitCount > rhs.candidate.confirmedVisitCount
            }
            return lhs.distanceMeters < rhs.distanceMeters
        }
        .map(\.candidate)

        let searchCandidates = PlaceNamingRanking.searchCandidates(
            searchHits,
            origin: visitCoordinate,
            within: searchRadius * 1.25,
            query: query,
            known: known,
            excludingNames: knownCandidates.map(\.name)
        )
        .sorted { lhs, rhs in
            let lhsScore = PlaceNamingRanking.score(lhs, accuracy: accuracy)
            let rhsScore = PlaceNamingRanking.score(rhs, accuracy: accuracy)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

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
    /// Only recent items are worth asking about. Older history is left as recorded.
    static let newQuestionWindow: TimeInterval = 14 * 24 * 60 * 60
    /// A question nobody answered within this long is dropped without asking.
    static let unansweredQuestionExpiry: TimeInterval = 30 * 24 * 60 * 60

    /// What the Review inbox asks about one item.
    enum Question: Equatable {
        /// The stay was matched to one of several nearby places.
        case whichPlace
        /// A stay so brief it may be a pause on the way, not a stop.
        case notAStop
        /// The trip's mode was a guess.
        case mode
    }

    /// Length of a finished stay. Zero for a stay that ended when it began; `nil` while open.
    static func stayDuration(of visit: VisitPlace) -> TimeInterval? {
        guard let departure = visit.departureDate else {
            return nil
        }
        return max(departure.timeIntervalSince(visit.arrivalDate), 0)
    }

    /// Brief stay with both an inbound and outbound move — candidate for "not a stop".
    /// A stay with no length at all counts.
    static func isShortTransitStop(_ visit: VisitPlace) -> Bool {
        guard let duration = stayDuration(of: visit), duration < shortStopDuration else {
            return false
        }
        return !visit.incomingMoves.isEmpty && !visit.outgoingMoves.isEmpty
    }

    /// Whether a freshly written stay should be put to the person. Ingest calls this
    /// once the stay has a departure; nothing older than `newQuestionWindow` is asked.
    static func shouldAskAboutStay(_ visit: VisitPlace, now: Date = .now) -> Bool {
        guard visit.reviewState == .none,
              visit.origin == .sensor,
              visit.assignmentSource != .user,
              now.timeIntervalSince(visit.arrivalDate) <= newQuestionWindow,
              !isImportedHistory(visit)
        else { return false }
        return isShortTransitStop(visit)
    }

    /// The question still worth asking about `visit`, or `nil` once its reason is gone:
    /// the person answered or labelled it, it came from an import, it is too old, or the
    /// stay grew long.
    static func question(for visit: VisitPlace, now: Date = .now) -> Question? {
        guard visit.reviewState == .pending,
              visit.origin == .sensor,
              visit.assignmentSource != .user,
              now.timeIntervalSince(visit.arrivalDate) <= unansweredQuestionExpiry,
              !isImportedHistory(visit)
        else { return nil }
        if visit.assignmentSource == .autoAmbiguous, visit.knownPlace != nil {
            return .whichPlace
        }
        if isShortTransitStop(visit) {
            return .notAStop
        }
        return nil
    }

    /// The question still worth asking about `move`, or `nil` once its reason is gone.
    static func question(for move: MoveSegment, now: Date = .now) -> Question? {
        guard move.reviewState == .pending,
              move.origin == .sensor,
              move.transportModeSource == .auto,
              now.timeIntervalSince(move.startDate) <= unansweredQuestionExpiry,
              !isImportedHistory(move)
        else { return nil }
        return .mode
    }

    /// Fixes that all came from a history file, even if the row predates origin tagging.
    static func isImportedHistory(_ move: MoveSegment) -> Bool {
        if move.origin == .imported { return true }
        let samples = move.samples
        return !samples.isEmpty && samples.allSatisfy { $0.source.isHistoryImport }
    }

    /// A stay whose every trip in and out is imported history.
    static func isImportedHistory(_ visit: VisitPlace) -> Bool {
        if visit.origin == .imported { return true }
        let moves = visit.incomingMoves + visit.outgoingMoves
        return !moves.isEmpty && moves.allSatisfy { isImportedHistory($0) }
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
