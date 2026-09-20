import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class PlaceLearningEngineTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)

    func testSingleCandidateAutoAssignsWithDistanceConfidence() {
        let place = PlaceLearningEngine.PlaceSnapshot(
            name: "Home",
            centerLatitude: home.latitude,
            centerLongitude: home.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 4
        )
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 12,
            arrivalDate: date(hour: 9),
            departureDate: date(hour: 17)
        )

        let resolution = PlaceLearningEngine.resolve(visit: visit, places: [place], calendar: gmtCalendar)

        XCTAssertEqual(resolution.source, .auto)
        XCTAssertEqual(resolution.placeID, place.id)
        XCTAssertNil(resolution.runnerUpPlaceID)
        XCTAssertEqual(resolution.reviewState, .none)
        XCTAssertEqual(resolution.confidence, 1, accuracy: 0.001)
        XCTAssertEqual(resolution.scores.count, 1)
    }

    func testVisitOutsideCandidateGateStaysUnassigned() {
        let place = PlaceLearningEngine.PlaceSnapshot(
            name: "Home",
            centerLatitude: home.latitude,
            centerLongitude: home.longitude,
            footprintRadius: 40
        )
        let far = offset(home, northMeters: 120)
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: far.latitude,
            longitude: far.longitude,
            horizontalAccuracy: 12,
            arrivalDate: date(hour: 9),
            departureDate: date(hour: 10)
        )

        let resolution = PlaceLearningEngine.resolve(visit: visit, places: [place], calendar: gmtCalendar)
        XCTAssertEqual(resolution, .unassigned)
    }

    func testMultiCandidateAutoAssignsWhenMarginIsAtLeastQuarter() {
        let homePlace = peakedPlace(name: "Home", at: home, confirmed: 10)
        let gymCoordinate = offset(home, northMeters: 60)
        let gym = PlaceLearningEngine.PlaceSnapshot(
            name: "Gym",
            centerLatitude: gymCoordinate.latitude,
            centerLongitude: gymCoordinate.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 1
        )
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 20,
            arrivalDate: date(hour: 9),
            departureDate: date(hour: 17)
        )

        let resolution = PlaceLearningEngine.resolve(
            visit: visit,
            places: [homePlace, gym],
            calendar: gmtCalendar
        )
        let scores = Dictionary(uniqueKeysWithValues: resolution.scores.map { ($0.placeID, $0) })
        let margin = (scores[homePlace.id]?.score ?? 0) - (scores[gym.id]?.score ?? 0)

        XCTAssertGreaterThanOrEqual(margin, PlaceLearningEngine.autoAssignMargin)
        XCTAssertEqual(resolution.source, .auto)
        XCTAssertEqual(resolution.placeID, homePlace.id)
        XCTAssertEqual(resolution.runnerUpPlaceID, gym.id)
        XCTAssertEqual(resolution.reviewState, .none)
        XCTAssertGreaterThanOrEqual(resolution.confidence, 0.5)
    }

    func testMultiCandidateBelowMarginUsesChooserAndPendingReview() {
        let gymCoordinate = offset(home, northMeters: 60)
        let homePlace = PlaceLearningEngine.PlaceSnapshot(
            name: "Home",
            centerLatitude: home.latitude,
            centerLongitude: home.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 5
        )
        let gym = PlaceLearningEngine.PlaceSnapshot(
            name: "Gym",
            centerLatitude: gymCoordinate.latitude,
            centerLongitude: gymCoordinate.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 5
        )
        let mid = offset(home, northMeters: 30)
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: mid.latitude,
            longitude: mid.longitude,
            horizontalAccuracy: 20,
            arrivalDate: date(hour: 12),
            departureDate: date(hour: 13)
        )

        let resolution = PlaceLearningEngine.resolve(
            visit: visit,
            places: [homePlace, gym],
            calendar: gmtCalendar
        )
        let scores = resolution.scores.map(\.score)
        XCTAssertEqual(resolution.scores.count, 2)
        XCTAssertLessThan(abs(scores[0] - scores[1]), PlaceLearningEngine.autoAssignMargin)
        XCTAssertEqual(resolution.source, .autoAmbiguous)
        XCTAssertEqual(resolution.reviewState, .pending)
        XCTAssertTrue([homePlace.id, gym.id].contains(resolution.placeID))
        XCTAssertTrue([homePlace.id, gym.id].contains(resolution.runnerUpPlaceID))
        XCTAssertNotEqual(resolution.placeID, resolution.runnerUpPlaceID)
    }

    func testExactlyQuarterMarginStillAutoAssigns() {
        // Equal priors and empty histograms, so margin = 0.45 × Δproximity.
        // 36 m / 60 m denom ≈ 0.27, just above the 0.25 auto-assign line
        // (33.3 m sits on the rounding edge of WGS-84 distance).
        let close = PlaceLearningEngine.PlaceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Close",
            centerLatitude: home.latitude,
            centerLongitude: home.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 1
        )
        let farCoordinate = offset(home, northMeters: 36)
        let far = PlaceLearningEngine.PlaceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Far",
            centerLatitude: farCoordinate.latitude,
            centerLongitude: farCoordinate.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 1
        )
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 20,
            arrivalDate: date(hour: 12),
            departureDate: nil
        )
        let scored = PlaceLearningEngine.scoredCandidates(
            visit: visit,
            places: [close, far],
            calendar: gmtCalendar
        )
        XCTAssertEqual(scored.count, 2)
        let margin = scored[0].score - scored[1].score
        XCTAssertGreaterThanOrEqual(margin, PlaceLearningEngine.autoAssignMargin)

        let resolution = PlaceLearningEngine.resolve(visit: visit, places: [close, far], calendar: gmtCalendar)
        XCTAssertEqual(resolution.source, .auto)
        XCTAssertEqual(resolution.placeID, close.id)
    }

    func testLearnUpdatesFootprintOnlyForUserAssignments() throws {
        let (context, _) = try makeContext()
        let place = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        context.insert(place)

        let autoVisit = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 17),
            source: .auto,
            knownPlace: place
        )
        PlaceLearningEngine.learn(from: autoVisit, onto: place, calendar: gmtCalendar)
        XCTAssertEqual(place.footprintRadius, 40, accuracy: 0.01)
        XCTAssertEqual(place.confirmedVisitCount, 0)
        XCTAssertEqual(place.arrivalHourHistogram.reduce(0, +), 0)
        XCTAssertTrue(place.stayDurationSamples.isEmpty)

        let userVisit = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 17),
            source: .user,
            knownPlace: place
        )
        PlaceLearningEngine.learn(from: userVisit, onto: place, calendar: gmtCalendar)

        XCTAssertEqual(place.confirmedVisitCount, 1)
        XCTAssertEqual(place.arrivalHourHistogram[9], 1)
        XCTAssertEqual(place.weekdayHistogram[2], 1) // Tuesday
        XCTAssertEqual(place.stayDurationSamples, [8 * 3600])
        XCTAssertEqual(place.footprintRadius, PlaceLearningEngine.minimumFootprintRadius, accuracy: 0.01)
        XCTAssertEqual(place.lastVisitAt, userVisit.arrivalDate)
    }

    func testAutoApplyNeverMutatesKnownPlace() throws {
        let (context, _) = try makeContext()
        let place = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        place.confirmedVisitCount = 3
        context.insert(place)
        let visit = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 10),
            source: .none,
            knownPlace: nil
        )

        let resolution = PlaceLearningEngine.resolve(visit: visit, knownPlaces: [place], calendar: gmtCalendar)
        PlaceLearningEngine.apply(resolution, to: visit, knownPlaces: [place])

        XCTAssertEqual(visit.assignmentSource, .auto)
        XCTAssertEqual(visit.knownPlace?.id, place.id)
        XCTAssertEqual(place.footprintRadius, 40, accuracy: 0.01)
        XCTAssertEqual(place.confirmedVisitCount, 3)
        XCTAssertEqual(place.arrivalHourHistogram.reduce(0, +), 0)
        XCTAssertTrue(place.stayDurationSamples.isEmpty)
    }

    func testAmbiguousApplySetsPendingChooserFlags() throws {
        let (context, _) = try makeContext()
        let gymCoordinate = offset(home, northMeters: 60)
        let homePlace = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        homePlace.confirmedVisitCount = 5
        let gym = KnownPlace(name: "Gym", latitude: gymCoordinate.latitude, longitude: gymCoordinate.longitude, footprintRadius: 40)
        gym.confirmedVisitCount = 5
        context.insert(homePlace)
        context.insert(gym)

        let mid = offset(home, northMeters: 30)
        let visit = insertVisit(
            in: context,
            at: mid,
            arrival: date(hour: 12),
            departure: date(hour: 13),
            source: .none,
            knownPlace: nil
        )
        visit.horizontalAccuracy = 20

        let resolution = PlaceLearningEngine.resolve(visit: visit, knownPlaces: [homePlace, gym], calendar: gmtCalendar)
        PlaceLearningEngine.apply(resolution, to: visit, knownPlaces: [homePlace, gym])

        XCTAssertEqual(visit.assignmentSource, .autoAmbiguous)
        XCTAssertEqual(visit.reviewState, .pending)
        XCTAssertNotNil(visit.knownPlace)
        XCTAssertTrue([homePlace.id, gym.id].contains(visit.knownPlace?.id))
    }

    func testUserAssignLearnsAndAutoAssignDoesNot() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 17),
            source: .none,
            knownPlace: nil
        )
        try context.save()

        let place = try repository.createKnownPlace(from: visit, name: "Home")
        XCTAssertEqual(visit.assignmentSource, .user)
        XCTAssertEqual(place.confirmedVisitCount, 1)
        let learnedHour = Calendar.autoupdatingCurrent.component(.hour, from: visit.arrivalDate)
        XCTAssertEqual(place.arrivalHourHistogram[learnedHour], 1)
        XCTAssertEqual(place.footprintRadius, PlaceLearningEngine.minimumFootprintRadius, accuracy: 0.01)

        let later = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 18),
            departure: date(hour: 19),
            source: .none,
            knownPlace: nil
        )
        try repository.assign(later, to: place, source: .auto, confidence: 0.8)
        XCTAssertEqual(later.assignmentSource, .auto)
        XCTAssertEqual(place.confirmedVisitCount, 1)
        XCTAssertEqual(place.arrivalHourHistogram.reduce(0, +), 1)
        XCTAssertEqual(place.stayDurationSamples.count, 1)
    }

    func testNegativesShrinkRadiusAfterThreeContainedEvents() throws {
        let (context, _) = try makeContext()
        let source = KnownPlace(name: "Cafe", latitude: home.latitude, longitude: home.longitude, footprintRadius: 50)
        let destination = KnownPlace(
            name: "Home",
            latitude: home.latitude,
            longitude: home.longitude,
            footprintRadius: 40
        )
        context.insert(source)
        context.insert(destination)

        var prior: [PlaceCorrectionEvent] = []
        for index in 1...3 {
            let event = PlaceCorrectionEvent(
                visitPlaceID: UUID(),
                fromKnownPlaceID: source.id,
                fromAutoLabel: index == 1 ? "Wrong Café" : nil,
                toKnownPlaceID: destination.id,
                latitude: home.latitude,
                longitude: home.longitude,
                arrivalHour: 9,
                weekday: 2,
                stayDuration: 600
            )
            PlaceLearningEngine.applyNegatives(
                event: event,
                fromPlace: source,
                toPlace: destination,
                priorEventsFromPlace: prior
            )
            prior.append(event)
        }

        XCTAssertEqual(source.footprintRadius, 40, accuracy: 0.01)
        XCTAssertEqual(destination.rejectedAutoLabels, ["Wrong Café"])
        XCTAssertGreaterThanOrEqual(source.footprintRadius, PlaceLearningEngine.minimumFootprintRadius)
    }

    func testRecordCorrectionAppliesNegatives() throws {
        let (repository, context, _) = try makeRepository()
        let source = KnownPlace(name: "Cafe", latitude: home.latitude, longitude: home.longitude, footprintRadius: 50)
        let destination = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude)
        context.insert(source)
        context.insert(destination)
        try context.save()

        for _ in 1...3 {
            try repository.recordCorrection(
                PlaceCorrectionEvent(
                    visitPlaceID: UUID(),
                    fromKnownPlaceID: source.id,
                    fromAutoLabel: "Starbucks",
                    toKnownPlaceID: destination.id,
                    latitude: home.latitude,
                    longitude: home.longitude,
                    arrivalHour: 8,
                    weekday: 1,
                    stayDuration: 300
                )
            )
        }

        XCTAssertEqual(source.footprintRadius, 40, accuracy: 0.01)
        XCTAssertEqual(destination.rejectedAutoLabels, ["Starbucks"])
    }

    func testRejectedAutoLabelsAreSuppressed() throws {
        let (context, _) = try makeContext()
        let place = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude)
        place.rejectedAutoLabels = ["Wrong Café", "Parking"]
        context.insert(place)

        XCTAssertTrue(PlaceLearningEngine.shouldSuppress("wrong café", nearbyPlaces: [place]))
        XCTAssertTrue(PlaceLearningEngine.shouldSuppress("Parking", nearbyPlaces: [place]))
        XCTAssertFalse(PlaceLearningEngine.shouldSuppress("Bakery", nearbyPlaces: [place]))
    }

    func testSetAutomaticLabelSkipsRejectedNames() throws {
        let (repository, context, _) = try makeRepository()
        let known = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude)
        known.rejectedAutoLabels = ["Wrong Café"]
        context.insert(known)
        let visit = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 10),
            source: .none,
            knownPlace: nil
        )
        try context.save()

        try repository.setAutomaticLabel("Wrong Café", for: visit.id)
        XCTAssertNil(visit.autoLabel)

        try repository.setAutomaticLabel("Bakery", for: visit.id)
        XCTAssertEqual(visit.autoLabel, "Bakery")
    }

    func testAssemblerAutoAssignsSingleNearbyPlaceAndSuppressesRejectedGeocoderName() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let known = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        known.confirmedVisitCount = 4
        known.rejectedAutoLabels = ["Wrong Café"]
        seed.insert(known)
        try seed.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: LearningStubMotionClassifier(),
            placeNameResolver: LearningStubPlaceNameResolver(name: "Wrong Café")
        )

        await assembler.ingestVisit(
            MockVisit(
                coordinate: home,
                horizontalAccuracy: 12,
                arrivalDate: date(hour: 9),
                departureDate: date(hour: 17)
            )
        )

        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let visit = try XCTUnwrap(visits.first)
        XCTAssertEqual(visit.assignmentSource, .auto)
        XCTAssertEqual(visit.knownPlace?.name, "Home")
        XCTAssertNil(visit.autoLabel)
        XCTAssertEqual(visit.reviewState, .none)
    }

    func testAssemblerMarksAmbiguousVisitsPendingForChooser() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let gymCoordinate = offset(home, northMeters: 60)
        let homePlace = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        homePlace.confirmedVisitCount = 5
        let gym = KnownPlace(name: "Gym", latitude: gymCoordinate.latitude, longitude: gymCoordinate.longitude, footprintRadius: 40)
        gym.confirmedVisitCount = 5
        seed.insert(homePlace)
        seed.insert(gym)
        try seed.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: LearningStubMotionClassifier(),
            placeNameResolver: LearningStubPlaceNameResolver(name: nil)
        )
        let mid = offset(home, northMeters: 30)

        await assembler.ingestVisit(
            MockVisit(
                coordinate: mid,
                horizontalAccuracy: 20,
                arrivalDate: date(hour: 12),
                departureDate: date(hour: 13)
            )
        )

        let context = ModelContext(container)
        let visit = try XCTUnwrap(try context.fetch(FetchDescriptor<VisitPlace>()).first)
        XCTAssertEqual(visit.assignmentSource, .autoAmbiguous)
        XCTAssertEqual(visit.reviewState, .pending)
        XCTAssertNotNil(visit.knownPlace)
    }

    func testHourSmoothingUsesNeighbouringBins() {
        var histogram = Array(repeating: 0, count: 24)
        histogram[9] = 10
        let atNine = PlaceLearningEngine.normalizedSmoothedHistogram(histogram, index: 9, binCount: 24)
        let atTen = PlaceLearningEngine.normalizedSmoothedHistogram(histogram, index: 10, binCount: 24)
        let atNoon = PlaceLearningEngine.normalizedSmoothedHistogram(histogram, index: 12, binCount: 24)
        XCTAssertEqual(atNine, 1, accuracy: 0.001)
        XCTAssertGreaterThan(atTen, atNoon)
        XCTAssertEqual(atNoon, 0, accuracy: 0.001)
        XCTAssertEqual(PlaceLearningEngine.normalizedSmoothedHistogram(Array(repeating: 0, count: 24), index: 9, binCount: 24), 0.5)
    }

    func testMergeReassignsVisitsAndRebuildsOccupancy() throws {
        let (context, _) = try makeContext()
        let destination = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude)
        let source = KnownPlace(
            name: "Home 2",
            latitude: offset(home, northMeters: 20).latitude,
            longitude: home.longitude
        )
        source.rejectedAutoLabels = ["Old Address"]
        context.insert(destination)
        context.insert(source)
        let keep = insertVisit(
            in: context,
            at: home,
            arrival: date(hour: 9),
            departure: date(hour: 17),
            source: .user,
            knownPlace: destination
        )
        let extra = insertVisit(
            in: context,
            at: offset(home, northMeters: 20),
            arrival: date(hour: 18),
            departure: date(hour: 22),
            source: .user,
            knownPlace: source
        )

        PlaceLearningEngine.merge(source, into: destination, calendar: gmtCalendar)

        XCTAssertEqual(keep.knownPlace?.id, destination.id)
        XCTAssertEqual(extra.knownPlace?.id, destination.id)
        XCTAssertEqual(destination.confirmedVisitCount, 2)
        XCTAssertEqual(destination.rejectedAutoLabels, ["Old Address"])
        XCTAssertEqual(destination.arrivalHourHistogram[9], 1)
        XCTAssertEqual(destination.arrivalHourHistogram[18], 1)
    }

    func testMailboxActorForwardsResolve() async {
        let place = PlaceLearningEngine.PlaceSnapshot(
            name: "Home",
            centerLatitude: home.latitude,
            centerLongitude: home.longitude,
            footprintRadius: 40,
            confirmedVisitCount: 1
        )
        let visit = PlaceLearningEngine.VisitSnapshot(
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 10,
            arrivalDate: date(hour: 9),
            departureDate: date(hour: 10)
        )
        let resolution = await PlaceLearningEngine.Service().resolve(
            visit: visit,
            places: [place],
            calendar: gmtCalendar
        )
        XCTAssertEqual(resolution.source, .auto)
        XCTAssertEqual(resolution.placeID, place.id)
    }
}

@MainActor
private func makeContext() throws -> (ModelContext, ModelContainer) {
    let container = try makeContainer()
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return (context, container)
}

@MainActor
private func makeRepository() throws -> (SwiftDataTimelineRepository, ModelContext, ModelContainer) {
    let (context, container) = try makeContext()
    context.undoManager = UndoManager()
    return (SwiftDataTimelineRepository(modelContext: context), context, container)
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(MovesTimelineSchema.models)
    let configuration = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}

@MainActor
private func insertVisit(
    in context: ModelContext,
    at coordinate: CLLocationCoordinate2D,
    arrival: Date,
    departure: Date?,
    source: PlaceAssignmentSource,
    knownPlace: KnownPlace?
) -> VisitPlace {
    let visit = VisitPlace(
        arrivalDate: arrival,
        departureDate: departure,
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        horizontalAccuracy: 12
    )
    visit.assignmentSource = source
    visit.knownPlace = knownPlace
    context.insert(visit)
    return visit
}

private func peakedPlace(
    name: String,
    at coordinate: CLLocationCoordinate2D,
    confirmed: Int
) -> PlaceLearningEngine.PlaceSnapshot {
    var hours = Array(repeating: 0, count: 24)
    hours[9] = 12
    var weekdays = Array(repeating: 0, count: 7)
    weekdays[2] = 8
    return PlaceLearningEngine.PlaceSnapshot(
        name: name,
        centerLatitude: coordinate.latitude,
        centerLongitude: coordinate.longitude,
        footprintRadius: 40,
        confirmedVisitCount: confirmed,
        arrivalHourHistogram: hours,
        weekdayHistogram: weekdays,
        stayDurationSamples: [8 * 3600]
    )
}

private var gmtCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// Tuesday 15 Sep 2026 in GMT.
private func date(hour: Int, minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 15
    components.hour = hour
    components.minute = minute
    components.timeZone = TimeZone(secondsFromGMT: 0)
    return gmtCalendar.date(from: components)!
}

private func offset(
    _ coordinate: CLLocationCoordinate2D,
    northMeters: Double,
    eastMeters: Double = 0
) -> CLLocationCoordinate2D {
    let metersPerDegreeLatitude = 111_320.0
    let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(coordinate.latitude * .pi / 180)
    return CLLocationCoordinate2D(
        latitude: coordinate.latitude + northMeters / metersPerDegreeLatitude,
        longitude: coordinate.longitude + eastMeters / metersPerDegreeLongitude
    )
}

private struct LearningStubMotionClassifier: MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (.walking, 0.9)
    }

    func stepCount(start: Date, end: Date) async -> Int? { nil }
}

private struct LearningStubPlaceNameResolver: PlaceNameResolver {
    let name: String?

    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? { name }
}
