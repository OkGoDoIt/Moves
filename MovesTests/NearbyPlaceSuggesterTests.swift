import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class NearbyPlaceSuggesterTests: XCTestCase {
    func testKnownPlacesRankAheadOfSearchHitsAndFillRemainingSlots() throws {
        let (context, _) = try makeContext()
        let cafe = insertKnownPlace(in: context, name: "Cafe", latitude: 52.5200, longitude: 13.4050, visits: 8)
        let gym = insertKnownPlace(in: context, name: "Gym", latitude: 52.5201, longitude: 13.4051, visits: 3)
        try context.save()

        let searcher = FakeLocalPlaceSearcher(hits: [
            NearbySearchHit(name: "Bookstore", subtitle: "Unter den Linden", latitude: 52.5202, longitude: 13.4052),
            NearbySearchHit(name: "Pharmacy", subtitle: nil, latitude: 52.5203, longitude: 13.4053),
        ])

        let visit = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_710_000_000),
            departureDate: nil,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 12
        )

        let candidates = NearbyPlaceSuggester.merge(
            visitCoordinate: visit.coordinate,
            knownPlaces: [cafe, gym],
            searchHits: searcher.hits,
            query: nil
        )

        XCTAssertEqual(candidates.map(\.name), ["Cafe", "Gym", "Bookstore", "Pharmacy"])
        XCTAssertEqual(candidates.first?.source, .knownPlace(id: cafe.id))
        XCTAssertLessThanOrEqual(candidates.count, NearbyPlaceSuggester.maximumCandidates)
    }

    func testRejectedAutoLabelsAreOmittedFromSearchHits() throws {
        let (context, _) = try makeContext()
        let home = insertKnownPlace(in: context, name: "Home", latitude: 52.52, longitude: 13.405, visits: 20)
        home.rejectedAutoLabels = ["Wrong Café", "Parking"]
        try context.save()

        let candidates = NearbyPlaceSuggester.merge(
            visitCoordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            knownPlaces: [home],
            searchHits: [
                NearbySearchHit(name: "Wrong Café", subtitle: nil, latitude: 52.5201, longitude: 13.4051),
                NearbySearchHit(name: "Bakery", subtitle: nil, latitude: 52.5202, longitude: 13.4052),
            ],
            query: nil
        )

        XCTAssertEqual(candidates.map(\.name), ["Home", "Bakery"])
        XCTAssertFalse(candidates.contains { $0.name == "Wrong Café" })
    }

    func testQueryFiltersKnownPlacesAndFakeSearch() async throws {
        let (context, _) = try makeContext()
        let cafe = insertKnownPlace(in: context, name: "Cafe Nero", latitude: 52.52, longitude: 13.405, visits: 4)
        let gym = insertKnownPlace(in: context, name: "Gym", latitude: 52.5202, longitude: 13.4052, visits: 2)
        try context.save()

        let visit = VisitPlace(
            arrivalDate: Date(),
            departureDate: nil,
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 10
        )
        let searcher = FakeLocalPlaceSearcher(hits: [
            NearbySearchHit(name: "Cafe Central", subtitle: nil, latitude: 52.5201, longitude: 13.4051),
            NearbySearchHit(name: "Museum", subtitle: nil, latitude: 52.5203, longitude: 13.4053),
        ])
        let suggester = NearbyPlaceSuggester(searcher: searcher)

        let results = await suggester.suggestions(for: visit, knownPlaces: [cafe, gym], query: "cafe")

        XCTAssertEqual(results.map(\.name), ["Cafe Nero", "Cafe Central"])
        XCTAssertEqual(searcher.lastQuery, "cafe")
    }

    func testPlacesBeyond250mAreExcluded() throws {
        let (context, _) = try makeContext()
        let near = insertKnownPlace(in: context, name: "Near", latitude: 52.5200, longitude: 13.4050, visits: 1)
        let far = insertKnownPlace(in: context, name: "Far", latitude: 52.5300, longitude: 13.4200, visits: 99)
        try context.save()

        let candidates = NearbyPlaceSuggester.merge(
            visitCoordinate: CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050),
            knownPlaces: [near, far],
            searchHits: [],
            query: nil
        )

        XCTAssertEqual(candidates.map(\.name), ["Near"])
    }
}

@MainActor
final class ReviewInboxBuilderTests: XCTestCase {
    func testFalseStopRequiresShortStayAndAlignedHeadings() throws {
        let (context, _) = try makeContext()
        let start = insertPlace(in: context, arrival: date(10, 0), departure: date(10, 30), latitude: 52.50, longitude: 13.40)
        let light = insertPlace(in: context, arrival: date(10, 32), departure: date(10, 34), latitude: 52.501, longitude: 13.401)
        let end = insertPlace(in: context, arrival: date(10, 50), departure: date(11, 0), latitude: 52.51, longitude: 13.41)
        let incoming = insertMove(in: context, from: start, to: light, start: date(10, 30), end: date(10, 32))
        incoming.storeCachedRouteCoordinates([start.coordinate, light.coordinate], signature: "in")
        let outgoing = insertMove(in: context, from: light, to: end, start: date(10, 34), end: date(10, 50))
        outgoing.storeCachedRouteCoordinates([light.coordinate, end.coordinate], signature: "out")
        light.reviewState = .pending
        try context.save()

        XCTAssertTrue(TimelineReviewHeuristics.isShortTransitStop(light))
        XCTAssertTrue(TimelineReviewHeuristics.isPossibleFalseStop(light))

        let items = ReviewInboxBuilder.items(visits: [start, light, end], moves: [incoming, outgoing])
        XCTAssertTrue(items.contains { $0.section == .possibleFalseStops && $0.title == light.displayTitle })
    }

    func testUncertainAutoModesLandInTheModeSection() throws {
        let (context, _) = try makeContext()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)
        let move = insertMove(in: context, from: start, to: end, start: date(8, 10), end: date(8, 40))
        move.reviewState = .pending
        move.transportModeSource = .auto
        try context.save()

        let items = ReviewInboxBuilder.items(visits: [start, end], moves: [move])
        XCTAssertEqual(items.filter { $0.section == .uncertainModes }.count, 1)
    }

    func testOnlyGoogleTimelineGuessesAreListedAsImportedPaths() throws {
        let (context, _) = try makeContext()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)

        let google = insertMove(in: context, from: start, to: end, start: date(8, 10), end: date(8, 40))
        google.origin = .imported
        google.transportModeSource = .imported
        google.routeMatchConfidence = .estimated

        let restored = insertMove(in: context, from: start, to: end, start: date(9, 0), end: date(9, 30))
        restored.origin = .imported
        restored.routeMatchConfidence = .estimated
        try context.save()

        let items = ReviewInboxBuilder.items(visits: [], moves: [google, restored])
        XCTAssertEqual(items.map(\.id), ["import-move-\(google.id.uuidString)"])
    }

    func testHeadingDifferenceTreatsWrapAround() {
        XCTAssertEqual(TimelineReviewHeuristics.angularDifference(350, 10), 20, accuracy: 0.01)
        XCTAssertEqual(TimelineReviewHeuristics.angularDifference(0, 180), 180, accuracy: 0.01)
        XCTAssertLessThan(
            TimelineReviewHeuristics.angularDifference(5, 20),
            TimelineReviewHeuristics.headingAlignmentDegrees
        )
    }
}

private final class FakeLocalPlaceSearcher: LocalPlaceSearching, @unchecked Sendable {
    var hits: [NearbySearchHit]
    var lastQuery: String?

    init(hits: [NearbySearchHit]) {
        self.hits = hits
    }

    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit] {
        lastQuery = query
        guard let query, !query.isEmpty else { return hits }
        return hits.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
private func makeContext() throws -> (ModelContext, ModelContainer) {
    let schema = Schema(MovesTimelineSchema.models)
    let configuration = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return (context, container)
}

@MainActor
private func insertKnownPlace(
    in context: ModelContext,
    name: String,
    latitude: Double,
    longitude: Double,
    visits: Int
) -> KnownPlace {
    let place = KnownPlace(name: name, latitude: latitude, longitude: longitude)
    place.confirmedVisitCount = visits
    context.insert(place)
    return place
}

@MainActor
private func insertPlace(
    in context: ModelContext,
    arrival: Date,
    departure: Date?,
    latitude: Double,
    longitude: Double
) -> VisitPlace {
    let place = VisitPlace(
        arrivalDate: arrival,
        departureDate: departure,
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracy: 12
    )
    context.insert(place)
    return place
}

@MainActor
private func insertMove(
    in context: ModelContext,
    from startPlace: VisitPlace,
    to endPlace: VisitPlace,
    start: Date,
    end: Date
) -> MoveSegment {
    let move = MoveSegment(
        dedupeKey: UUID().uuidString,
        startDate: start,
        endDate: end,
        transportMode: .walking,
        distanceMeters: 400,
        stepCount: nil
    )
    move.startPlace = startPlace
    move.endPlace = endPlace
    context.insert(move)
    return move
}

private func date(_ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 20
    components.hour = hour
    components.minute = minute
    components.timeZone = TimeZone(secondsFromGMT: 0)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: components)!
}
