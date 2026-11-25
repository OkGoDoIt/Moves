import CoreLocation
import MapKit
import SwiftData
import UIKit
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

/// Choose a Place, the narrowed chips, and the better default guesses.
@MainActor
final class PlaceNamingTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)

    /// About `meters` north of the origin.
    private func north(_ meters: Double) -> Double {
        origin.latitude + meters / 111_320
    }

    func testDefaultsPreferAPlaceThatHoldsTheStayAndAKindPeopleNameStaysAfter() {
        let hits = [
            NearbySearchHit(name: "Cash Point", subtitle: nil, latitude: north(5), longitude: origin.longitude, category: MKPointOfInterestCategory.atm.rawValue),
            NearbySearchHit(name: "Garage Level 2", subtitle: nil, latitude: north(8), longitude: origin.longitude, category: MKPointOfInterestCategory.parking.rawValue),
            NearbySearchHit(name: "Pasta & Pizza", subtitle: nil, latitude: north(30), longitude: origin.longitude, category: MKPointOfInterestCategory.restaurant.rawValue),
            NearbySearchHit(name: "Bookshop", subtitle: nil, latitude: north(120), longitude: origin.longitude, category: MKPointOfInterestCategory.store.rawValue),
            NearbySearchHit(name: "PASTA & PIZZA", subtitle: nil, latitude: north(40), longitude: origin.longitude, category: MKPointOfInterestCategory.restaurant.rawValue),
        ]

        let chips = NearbyPlaceSuggester.merge(
            visitCoordinate: origin,
            known: [],
            searchHits: hits,
            query: nil,
            accuracy: 25
        )

        // Before: nearest first, so the ATM and the car park led and the restaurant showed twice.
        XCTAssertEqual(chips.map(\.name), ["Pasta & Pizza", "Bookshop", "Cash Point", "Garage Level 2"])
    }

    func testListingFiltersAnywhereIgnoringCaseAndAccentsWithOwnPlacesFirst() throws {
        let (context, _) = try makeContext()
        let office = insertKnownPlace(in: context, name: "Café Office", latitude: north(60), longitude: origin.longitude, visits: 3)
        office.rejectedAutoLabels = ["Wrong Cafe"]
        let home = insertKnownPlace(in: context, name: "Home", latitude: north(10), longitude: origin.longitude, visits: 30)
        try context.save()

        let nearby = [
            NearbySearchHit(name: "Blue Cafe", subtitle: "Main St", latitude: north(90), longitude: origin.longitude),
            NearbySearchHit(name: "CAFÉ OFFICE", subtitle: nil, latitude: north(61), longitude: origin.longitude),
            NearbySearchHit(name: "Wrong Café", subtitle: nil, latitude: north(20), longitude: origin.longitude),
            NearbySearchHit(name: "Bakery", subtitle: nil, latitude: north(15), longitude: origin.longitude),
        ]
        // Apple's answer for "cafe" may include places whose names lack the word.
        let typed = [
            NearbySearchHit(name: "Blue Bottle", subtitle: nil, latitude: north(1_500), longitude: origin.longitude, category: MKPointOfInterestCategory.cafe.rawValue),
        ]
        let known = [office, home].map(NearbyKnownPlace.init)

        let everything = PlaceChoiceListing.build(origin: origin, query: "", known: known, nearbyHits: nearby, typedHits: [])
        XCTAssertEqual(everything.known.map(\.name), ["Home", "Café Office"])
        XCTAssertEqual(everything.places.map(\.name), ["Bakery", "Blue Cafe"])

        let filtered = PlaceChoiceListing.build(origin: origin, query: "cafe", known: known, nearbyHits: nearby, typedHits: typed)
        XCTAssertEqual(filtered.known.map(\.name), ["Café Office"])
        XCTAssertEqual(filtered.places.map(\.name), ["Blue Cafe", "Blue Bottle"])
        XCTAssertEqual(filtered.narrowedChips(query: "cafe", limit: 5).map(\.name), ["Café Office", "Blue Cafe", "Blue Bottle"])

        let none = PlaceChoiceListing.build(origin: origin, query: "zzz", known: known, nearbyHits: nearby, typedHits: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testNarrowedChipsPutWordPrefixesBeforeOtherMatchesAndSameNamesAcrossTownStay() {
        let nearby = [
            NearbySearchHit(name: "Costa", subtitle: nil, latitude: north(10), longitude: origin.longitude),
            NearbySearchHit(name: "Starbucks", subtitle: nil, latitude: north(200), longitude: origin.longitude),
        ]
        let typed = [
            NearbySearchHit(name: "Starbucks", subtitle: nil, latitude: north(2_400), longitude: origin.longitude),
            NearbySearchHit(name: "Starbucks", subtitle: nil, latitude: north(230), longitude: origin.longitude),
        ]
        let listing = PlaceChoiceListing.build(origin: origin, query: "sta", known: [], nearbyHits: nearby, typedHits: typed)

        // The duplicate 30 m away folds away; the one across town stays, with its distance.
        XCTAssertEqual(listing.places.map(\.name), ["Costa", "Starbucks", "Starbucks"])
        XCTAssertEqual(listing.places.map { Int(($0.distanceMeters / 100).rounded()) }, [0, 2, 24])
        XCTAssertEqual(listing.narrowedChips(query: "sta", limit: 2).map(\.name), ["Starbucks", "Starbucks"])
    }

    func testDistancesReadInThePersonsUnits() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(PlaceNamingRanking.distanceText(37, locale: us), "120 ft")
        XCTAssertEqual(PlaceNamingRanking.distanceText(1_200, locale: us), "0.7 mi")
        let metric = Locale(identifier: "en_AU")
        XCTAssertEqual(PlaceNamingRanking.distanceText(37, locale: metric), "40 m")
        XCTAssertEqual(PlaceNamingRanking.distanceText(1_520, locale: metric), "1.5 km")
    }

    func testEveryCategoryGlyphExists() {
        let categories: [MKPointOfInterestCategory] = [
            .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket, .hotel, .campground, .store, .pharmacy,
            .hospital, .spa, .laundry, .publicTransport, .airport, .park, .beach, .marina, .fitnessCenter, .swimming,
            .tennis, .school, .library, .museum, .theater, .movieTheater, .musicVenue, .bank, .gasStation, .evCharger,
            .parking, .carRental, .postOffice, .police, .zoo, .aquarium, .amusementPark, .hiking,
        ]
        for category in categories {
            let name = PlaceNamingRanking.symbolName(forCategory: category.rawValue)
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
        XCTAssertNotNil(UIImage(systemName: "character.cursor.ibeam"))
    }

    func testTypedSearchWaitsForAPauseSkipsOneLetterAndReusesEarlierAnswers() async throws {
        let searcher = ScriptedPlaceSearcher()
        searcher.answers["starbucks"] = [NearbySearchHit(name: "Starbucks", subtitle: nil, latitude: north(150), longitude: origin.longitude)]
        let model = makeModel(searcher)
        await model.prepare(near: origin, accuracy: 20, knownPlaces: [])

        model.fieldQuery = "S"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(searcher.typedQueries, [], "one letter never asks Apple")

        model.fieldQuery = "St"
        model.fieldQuery = "Starbucks"
        try await waitUntil { model.chips.map(\.name) == ["Starbucks"] }
        XCTAssertEqual(searcher.typedQueries, ["Starbucks"], "only the text after the pause is searched")

        model.fieldQuery = ""
        XCTAssertEqual(model.chips, model.defaultChips, "clearing the field restores the guesses")

        model.fieldQuery = "starbucks "
        XCTAssertEqual(model.chips.map(\.name), ["Starbucks"], "an answer already in hand shows at once")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(searcher.typedQueries, ["Starbucks"])
    }

    func testASlowEarlierAnswerNeverReplacesANewerOne() async throws {
        let searcher = ScriptedPlaceSearcher()
        searcher.answers["st"] = [NearbySearchHit(name: "Stale Corner", subtitle: nil, latitude: north(50), longitude: origin.longitude)]
        searcher.delays["st"] = .milliseconds(400)
        searcher.answers["sta"] = [NearbySearchHit(name: "Starbucks", subtitle: nil, latitude: north(60), longitude: origin.longitude)]
        let model = makeModel(searcher)
        await model.prepare(near: origin, accuracy: 20, knownPlaces: [])

        model.sheetQuery = "St"
        try await waitUntil { searcher.queries.contains("St") }
        model.sheetQuery = "Sta"
        try await waitUntil { model.listing(for: "Sta").places.map(\.name) == ["Starbucks"] }

        // Let the slow "St" answer land; it must not change what "Sta" shows.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.listing(for: model.sheetQuery).places.map(\.name), ["Starbucks"])
        XCTAssertFalse(model.isSearching("Sta"))
        XCTAssertFalse(model.isSearching("St"))
    }

    func testDefaultChipsHoldStillOnceShownAndOwnPlacesLead() async throws {
        let (context, _) = try makeContext()
        let gym = insertKnownPlace(in: context, name: "My Gym", latitude: north(20), longitude: origin.longitude, visits: 12)
        try context.save()

        let searcher = ScriptedPlaceSearcher()
        searcher.nearby = [NearbySearchHit(name: "Noodle Bar", subtitle: nil, latitude: north(25), longitude: origin.longitude, category: MKPointOfInterestCategory.restaurant.rawValue)]
        searcher.widened = [NearbySearchHit(name: "Pizza Place", subtitle: nil, latitude: north(10), longitude: origin.longitude, category: MKPointOfInterestCategory.restaurant.rawValue)]
        let model = makeModel(searcher)

        await model.prepare(near: origin, accuracy: 20, knownPlaces: [gym])
        let shown = model.defaultChips.map(\.name)
        XCTAssertEqual(shown, ["My Gym", "Noodle Bar"])

        // Too few nearby, so the list widens; the chips the person is reading do not move.
        try await waitUntil { model.listing(for: "").places.count == 2 }
        XCTAssertEqual(model.defaultChips.map(\.name), shown)
        XCTAssertEqual(searcher.radii, [NearbyPlaceSuggester.listRadius, NearbyPlaceSuggester.widenedListRadius])
    }

    func testOfflineStillFiltersWhatIsAlreadyKnown() async throws {
        let (context, _) = try makeContext()
        let home = insertKnownPlace(in: context, name: "Studio", latitude: north(20), longitude: origin.longitude, visits: 2)
        try context.save()
        let searcher = ScriptedPlaceSearcher()
        searcher.fails = true
        let model = makeModel(searcher)
        await model.prepare(near: origin, accuracy: 20, knownPlaces: [home])

        model.sheetQuery = "stu"
        try await waitUntil { !model.isSearching("stu") && searcher.queries.contains("stu") }
        XCTAssertEqual(model.listing(for: "stu").known.map(\.name), ["Studio"])
        XCTAssertEqual(model.chips.map(\.name), ["Studio"])
    }

    private func makeModel(_ searcher: ScriptedPlaceSearcher) -> PlaceNamingModel {
        PlaceNamingModel(
            searcher: searcher,
            debounce: .milliseconds(60),
            pacer: PlaceSearchPacer(interval: .zero),
            cache: PlaceSearchCache()
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Answers by folded query, after an optional delay it does not cut short when cancelled,
/// like a network reply already on its way.
private final class ScriptedPlaceSearcher: LocalPlaceSearching, @unchecked Sendable {
    private let lock = NSLock()
    var nearby: [NearbySearchHit] = []
    var widened: [NearbySearchHit] = []
    var answers: [String: [NearbySearchHit]] = [:]
    var delays: [String: Duration] = [:]
    var fails = false
    private var recordedQueries: [String?] = []
    private var recordedRadii: [CLLocationDistance] = []

    var queries: [String?] { lock.withLock { recordedQueries } }
    var typedQueries: [String] { queries.compactMap { $0 } }
    var radii: [CLLocationDistance] { lock.withLock { recordedRadii } }

    func search(near coordinate: CLLocationCoordinate2D, query: String?) async throws -> [NearbySearchHit] {
        try await search(near: coordinate, query: query, radius: NearbyPlaceSuggester.searchRadius)
    }

    func search(near coordinate: CLLocationCoordinate2D, query: String?, radius: CLLocationDistance) async throws -> [NearbySearchHit] {
        let key = PlaceNamingRanking.folded(query ?? "")
        let (delay, answer, shouldFail): (Duration?, [NearbySearchHit], Bool) = lock.withLock {
            recordedQueries.append(query)
            if query == nil { recordedRadii.append(radius) }
            let answer = query == nil
                ? (radius > NearbyPlaceSuggester.listRadius ? widened : nearby)
                : answers[key] ?? []
            return (delays[key], answer, fails && query != nil)
        }
        if let delay {
            let nanoseconds = UInt64(delay.components.attoseconds / 1_000_000_000) + UInt64(delay.components.seconds) * 1_000_000_000
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                    continuation.resume()
                }
            }
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return answer
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

        let items = ReviewInboxBuilder.items(visits: [start, light, end], moves: [incoming, outgoing], now: date(12, 0))
        XCTAssertEqual(items.map(\.section), [.stops])
        XCTAssertEqual(items.first?.itemID, light.id)
    }

    /// A stay that ended the moment it began never reached Review before.
    func testAZeroLengthStopIsAskedAbout() throws {
        let (context, _) = try makeContext()
        let start = insertPlace(in: context, arrival: date(10, 0), departure: date(10, 30), latitude: 52.50, longitude: 13.40)
        let blip = insertPlace(in: context, arrival: date(10, 32), departure: date(10, 32), latitude: 52.501, longitude: 13.401)
        let end = insertPlace(in: context, arrival: date(10, 50), departure: date(11, 0), latitude: 52.51, longitude: 13.41)
        _ = insertMove(in: context, from: start, to: blip, start: date(10, 30), end: date(10, 32))
        _ = insertMove(in: context, from: blip, to: end, start: date(10, 32), end: date(10, 50))
        try context.save()

        XCTAssertEqual(TimelineReviewHeuristics.stayDuration(of: blip), 0)
        XCTAssertTrue(TimelineReviewHeuristics.shouldAskAboutStay(blip, now: date(12, 0)))
        blip.reviewState = .pending
        XCTAssertEqual(TimelineReviewHeuristics.question(for: blip, now: date(12, 0)), .notAStop)
    }

    func testUncertainAutoModesLandInTheModeSection() throws {
        let (context, _) = try makeContext()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)
        let move = insertMove(in: context, from: start, to: end, start: date(8, 10), end: date(8, 40))
        move.reviewState = .pending
        move.transportModeSource = .auto
        try context.save()

        let items = ReviewInboxBuilder.items(visits: [start, end], moves: [move], now: date(12, 0))
        XCTAssertEqual(items.filter { $0.section == .trips }.count, 1)
    }

    func testImportedHistoryIsNeverListed() throws {
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
        restored.reviewState = .pending
        try context.save()

        let items = ReviewInboxBuilder.items(visits: [], moves: [google, restored], now: date(12, 0))
        XCTAssertTrue(items.isEmpty)
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
    place.dayTimeline = fixtureDay(containing: arrival, in: context)
    return place
}

/// A live stay or trip is always on a day; reuse the one already inserted for this date.
@MainActor
private func fixtureDay(containing date: Date, in context: ModelContext) -> DayTimeline {
    let zone = TimeZone(secondsFromGMT: 0)!
    let key = DayTimeline.makeDayKey(for: date, in: zone)
    if let existing = try? context.fetch(FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })).first {
        return existing
    }
    let day = DayTimeline(containing: date, in: zone)
    context.insert(day)
    return day
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
    move.dayTimeline = fixtureDay(containing: start, in: context)
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
