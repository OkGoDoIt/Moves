import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// Stops reconstructed from the sparse fixes visit monitoring misses.
final class SampleStayInferenceTests: XCTestCase {
    func testStillGapAtTheSamePlaceIsAStayAndAFastGapIsNot() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let home = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        var points: [LocationLogPoint] = []

        points.append(fix(home, at: start))
        // Two quiet hours, then a fix a short walk away: the phone was stopped.
        let leave = offset(home, north: 0, east: 400)
        points.append(fix(leave, at: start.addingTimeInterval(2 * 60 * 60)))

        // A 20-minute hop of 5 km is travel, not another stop.
        let departed = start.addingTimeInterval(2 * 60 * 60)
        let destination = offset(leave, north: 5_000, east: 0)
        points.append(fix(destination, at: departed.addingTimeInterval(20 * 60)))

        let stays = SampleStayInference.stays(from: points, now: departed.addingTimeInterval(20 * 60))

        XCTAssertEqual(stays.count, 1)
        let stay = stays[0]
        XCTAssertEqual(stay.arrivalDate, start)
        XCTAssertEqual(stay.departureDate, departed)
        XCTAssertEqual(stay.latitude, home.latitude, accuracy: 0.000_1)
    }

    func testSpikeBetweenTwoFixesAtTheSamePlaceIsIgnored() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let home = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let points = [
            fix(home, at: start),
            fix(offset(home, north: 6_000, east: 0), at: start.addingTimeInterval(30 * 60), accuracy: 40),
            fix(home, at: start.addingTimeInterval(40 * 60)),
            fix(home, at: start.addingTimeInterval(3 * 60 * 60))
        ]

        let stays = SampleStayInference.stays(from: points, now: start.addingTimeInterval(3 * 60 * 60))

        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays[0].arrivalDate, start)
        XCTAssertNil(stays[0].departureDate)
    }

    func testPoorAccuracyFixesDoNotSplitAStay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let home = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let points = [
            fix(home, at: start),
            fix(offset(home, north: 2_000, east: 2_000), at: start.addingTimeInterval(60 * 60), accuracy: 1_400),
            fix(home, at: start.addingTimeInterval(2 * 60 * 60))
        ]

        let stays = SampleStayInference.stays(from: points, now: start.addingTimeInterval(2 * 60 * 60))

        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays[0].latitude, home.latitude, accuracy: 0.000_1)
    }

    func testCoupleOfBlocksInAFewMinutesIsNotAStay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let kerb = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        // About 200 metres, the walk from the bus stop to the door.
        let door = offset(kerb, north: 160, east: 110)
        let points = [
            fix(kerb, at: start),
            fix(door, at: start.addingTimeInterval(11 * 60))
        ]

        let stays = SampleStayInference.stays(from: points, now: start.addingTimeInterval(11 * 60))

        XCTAssertTrue(stays.isEmpty)
    }

    func testHoursAtTheSameSpotIsStillAStay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let home = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let drifted = offset(home, north: 0, east: 400)
        let points = [
            fix(home, at: start),
            fix(drifted, at: start.addingTimeInterval(6 * 60 * 60))
        ]

        let stays = SampleStayInference.stays(from: points, now: start.addingTimeInterval(6 * 60 * 60))

        XCTAssertEqual(stays.count, 1)
    }

    func testFewStepsDoNotIdentifyABicycle() {
        // Too fast for this walk, but neither speed nor missing steps identifies a bike.
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .walking, straightLine: 7_100, duration: 24 * 60, stepCount: 600),
            .unknown
        )
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .walking, straightLine: 20_000, duration: 25 * 60, stepCount: 200),
            .automotive
        )
    }

    func testDistanceAloneDoesNotOverrideCyclingMotion() {
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .cycling, straightLine: 64_000, duration: 146 * 60, stepCount: nil),
            .cycling
        )
        // A real long ride at a cyclist's pace keeps its label.
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .cycling, straightLine: 30_000, duration: 150 * 60, stepCount: nil),
            .cycling
        )
    }

    func testRealWalkWithSloppyTimesStaysAWalk() {
        // 555 steps in 5.7 minutes is a walking pace, whatever the clock says about speed.
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .walking, straightLine: 1_284, duration: 5.7 * 60, stepCount: 555),
            .walking
        )
        // An imported log has no steps, and this pace is a plausible walk.
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .walking, straightLine: 1_777, duration: 19 * 60, stepCount: 0),
            .walking
        )
    }

    func testLastBlockAfterARideIsWalkingWhenThereAreSteps() {
        let mode = LastBlockWalk.mode(
            proposed: .automotive,
            distance: 190,
            duration: 11 * 60,
            stepCount: 240
        )
        XCTAssertEqual(mode, .walking)
    }

    func testCrawlingVehicleWithNoStepsStaysARide() {
        let mode = LastBlockWalk.mode(
            proposed: .automotive,
            distance: 180,
            duration: 8 * 60,
            stepCount: 0
        )
        XCTAssertEqual(mode, .automotive)
    }

    func testBusRideIsNotRelabeledAsALastBlockWalk() {
        let mode = LastBlockWalk.mode(
            proposed: .automotive,
            distance: 8_000,
            duration: 16 * 60,
            stepCount: 50
        )
        XCTAssertEqual(mode, .automotive)
    }

    func testLongSlowWalkIsNotReportedAsWalking() {
        let mode = CoreMotionTransportClassifier.rejectingImplausibleContinuousTrip(
            .walking,
            duration: 36 * 60 * 60,
            straightLineDistance: 6_700
        )
        XCTAssertEqual(mode, .unknown)

        let hike = CoreMotionTransportClassifier.rejectingImplausibleContinuousTrip(
            .walking,
            duration: 3 * 60 * 60,
            straightLineDistance: 8_000
        )
        XCTAssertEqual(hike, .walking)
    }
}

@MainActor
final class SampleStayReconciliationTests: XCTestCase {
    func testPrematureVisitDepartureIsExtendedAndTheSpanningMoveIsReplaced() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .automotive, steps: 120),
            placeNameResolver: EmptyPlaceNameResolver()
        )

        let now = Date()
        let start = now.addingTimeInterval(-26 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let north = offset(home, north: 4_000, east: 0)

        let earlyVisit = MockVisit(
            coordinate: home,
            horizontalAccuracy: 20,
            arrivalDate: start,
            departureDate: start.addingTimeInterval(5 * 60)
        )
        let laterVisit = MockVisit(
            coordinate: north,
            horizontalAccuracy: 20,
            arrivalDate: start.addingTimeInterval(22 * 60 * 60),
            departureDate: start.addingTimeInterval(23 * 60 * 60)
        )
        let origin = try repository.addOrUpdateVisit(from: earlyVisit)
        let destination = try repository.addOrUpdateVisit(from: laterVisit)
        _ = try repository.upsertMove(
            startPlace: origin,
            endPlace: destination,
            startDate: start.addingTimeInterval(5 * 60),
            endDate: start.addingTimeInterval(22 * 60 * 60),
            transportMode: .walking,
            distanceMeters: 32_000,
            stepCount: 15_000,
            samples: []
        )

        let samples = timelineFixes(start: start, home: home, north: north)
        await assembler.ingestLocations(samples, source: .significantChange)

        let context = ModelContext(container)
        let places = try context.fetch(
            FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\VisitPlace.arrivalDate)])
        )
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())

        let homeStay = try XCTUnwrap(places.first { distance($0.coordinate, home) < 150 })
        let homeDuration = (homeStay.departureDate ?? now).timeIntervalSince(homeStay.arrivalDate)
        XCTAssertGreaterThan(homeDuration, 4 * 60 * 60, "The five-minute visit should grow to cover the fixes that never left")

        XCTAssertTrue(places.contains { distance($0.coordinate, north) < 200 && $0.id != destination.id })
        XCTAssertFalse(
            moves.contains { $0.endDate.timeIntervalSince($0.startDate) > 4 * 60 * 60 },
            "No trip should still cover the whole gap"
        )
        XCTAssertTrue(moves.contains { $0.transportMode == .automotive })

        let placeCount = places.count
        await assembler.reconcileSampleStays()
        let placesAfter = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(placesAfter.count, placeCount)
    }

    func testGluedBusStopBecomesAWalkToTheDoor() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .automotive, steps: 220),
            placeNameResolver: EmptyPlaceNameResolver()
        )

        let now = Date()
        let kerbTime = now.addingTimeInterval(-30 * 60)
        let doorTime = kerbTime.addingTimeInterval(11 * 60)
        let kerb = CLLocationCoordinate2D(latitude: 10.76130, longitude: 106.70015)
        let door = offset(kerb, north: 160, east: -90)

        let stop = MockVisit(
            coordinate: kerb,
            horizontalAccuracy: 20,
            arrivalDate: kerbTime,
            departureDate: doorTime
        )
        let home = MockVisit(
            coordinate: door,
            horizontalAccuracy: 20,
            arrivalDate: doorTime,
            departureDate: doorTime.addingTimeInterval(5 * 60)
        )
        _ = try repository.addOrUpdateVisit(from: stop)
        _ = try repository.addOrUpdateVisit(from: home)
        _ = try repository.appendSamples(
            from: [
                location(kerb, at: kerbTime.addingTimeInterval(30)),
                location(door, at: doorTime)
            ],
            source: .significantChange
        )

        await assembler.reconcileSampleStays()

        let context = ModelContext(container)
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        let walk = try XCTUnwrap(moves.first { $0.transportMode == .walking })
        XCTAssertLessThan(walk.endDate.timeIntervalSince(walk.startDate), 20 * 60)
        XCTAssertGreaterThan(walk.distanceMeters, 70)
        XCTAssertLessThan(walk.distanceMeters, 450)
    }

    // MARK: - The person's corrections outlast the reconciler

    func testSameVisitReportedTwiceIsOneStop() throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let arrival = Date().addingTimeInterval(-3 * 60 * 60)
        let first = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let refined = offset(first, north: 180, east: 60)

        _ = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: first, horizontalAccuracy: 30, arrivalDate: arrival, departureDate: .distantFuture)
        )
        let departure = arrival.addingTimeInterval(60 * 60)
        _ = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: refined, horizontalAccuracy: 14, arrivalDate: arrival, departureDate: departure)
        )

        let places = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.departureDate, departure)
        XCTAssertLessThan(distance(try XCTUnwrap(places.first).coordinate, refined), 1)
    }

    func testCorrectedTripKeepsItsModeAndIsNotRebuilt() async throws {
        let scene = try await makeTwoStopScene(separation: 300, tripMinutes: 8)
        let move = try XCTUnwrap(try scene.fetchMoves().first)
        try scene.repository.setTransportMode(.automotive, for: move, source: .user)
        let id = move.id

        await scene.assembler.reconcileSampleStays()
        await scene.assembler.reconcileSampleStays()

        let moves = try scene.fetchMoves()
        XCTAssertEqual(moves.map(\.id), [id])
        XCTAssertEqual(moves.first?.transportMode, .automotive)
        XCTAssertEqual(moves.first?.transportModeSource, .user)
    }

    func testRideThatKeepsItsLabelIsNotRebuiltOnEveryPass() async throws {
        let scene = try await makeTwoStopScene(separation: 300, tripMinutes: 8, steps: 0)
        let id = try XCTUnwrap(try scene.fetchMoves().first).id
        XCTAssertEqual(try scene.fetchMoves().first?.transportMode, .automotive)

        await scene.assembler.reconcileSampleStays()
        await scene.assembler.reconcileSampleStays()

        XCTAssertEqual(try scene.fetchMoves().map(\.id), [id])
    }

    func testRemovedTripStaysRemoved() async throws {
        let scene = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10)
        let move = try XCTUnwrap(try scene.fetchMoves().first)
        scene.repository.recordRemoval(of: move)
        scene.context.delete(move)
        try scene.context.save()

        await scene.assembler.reconcileSampleStays()

        XCTAssertEqual(try scene.fetchMoves().count, 0)
    }

    func testRemovedStopIsNotRebuiltFromItsFixes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .automotive, steps: 0),
            placeNameResolver: EmptyPlaceNameResolver()
        )
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let cafe = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        _ = try repository.appendSamples(
            from: (0...6).map { location(cafe, at: start.addingTimeInterval(Double($0) * 10 * 60)) },
            source: .significantChange
        )

        await assembler.reconcileSampleStays()
        let rebuilt = try XCTUnwrap(try context.fetch(FetchDescriptor<VisitPlace>()).first)
        repository.recordRemoval(of: rebuilt)
        context.delete(rebuilt)
        try context.save()

        await assembler.reconcileSampleStays()

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 0)
    }

    func testEditedTimesAreNotStretchedBackOverFixes() async throws {
        let scene = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10)
        let place = try XCTUnwrap(try scene.fetchPlaces().first)
        let arrival = place.arrivalDate.addingTimeInterval(60 * 60)
        let departure = place.departureDate
        try scene.repository.updateTimes(of: place, arrival: arrival, departure: departure)
        XCTAssertEqual(place.origin, .manual)

        await scene.assembler.reconcileSampleStays()

        XCTAssertEqual(try scene.fetchPlaces().first?.arrivalDate, arrival)
    }

    func testSplitStopStaysSplit() async throws {
        let scene = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10)
        let place = try XCTUnwrap(try scene.fetchPlaces().first)
        let middle = place.arrivalDate.addingTimeInterval(60 * 60)
        let before = try scene.fetchPlaces().count
        _ = try scene.repository.splitVisit(place, at: middle)

        await scene.assembler.reconcileSampleStays()

        XCTAssertEqual(try scene.fetchPlaces().count, before + 1)
        XCTAssertEqual(try scene.fetchPlaces().first?.departureDate, middle)
    }

    func testUnsureTripGoesToReviewAndConfidentOneDoesNot() async throws {
        let unsure = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10, confidence: 0.4)
        XCTAssertEqual(try unsure.fetchMoves().first?.reviewState, .pending)
        XCTAssertEqual(try unsure.fetchMoves().first?.transportModeSource, .auto)

        let sure = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10, confidence: 0.9)
        await sure.assembler.reconcileSampleStays()
        XCTAssertEqual(try sure.fetchMoves().first?.reviewState, ReviewState.none)
    }

    func testDismissedTripIsNotAskedAboutAgain() async throws {
        let scene = try await makeTwoStopScene(separation: 2_000, tripMinutes: 10, confidence: 0.4)
        let move = try XCTUnwrap(try scene.fetchMoves().first)
        move.reviewState = .dismissed
        try scene.context.save()

        await scene.assembler.reconcileSampleStays()

        XCTAssertEqual(try scene.fetchMoves().first?.reviewState, .dismissed)
    }

    func testPhotoLocationsDoNotBecomeStops() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .automotive, steps: 0),
            placeNameResolver: EmptyPlaceNameResolver()
        )
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let paris = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)
        _ = try repository.appendSamples(
            from: (0...6).map { location(paris, at: start.addingTimeInterval(Double($0) * 10 * 60)) },
            source: .photoLibrary
        )

        await assembler.reconcileSampleStays()

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 0)
    }

    func testRepairMergesReportedTwiceStopsAndKeepsWhatTheyCarried() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let arrival = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let coordinate = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let twin = offset(coordinate, north: 150, east: 0)

        let known = KnownPlace(name: "Studio", latitude: twin.latitude, longitude: twin.longitude)
        context.insert(known)
        let open = VisitPlace(
            arrivalDate: arrival,
            departureDate: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: 30,
            userLabel: "Studio"
        )
        open.knownPlace = known
        open.assignmentSource = .user
        let photo = PhotoAttachment(assetLocalIdentifier: "asset", capturedAt: arrival)
        context.insert(photo)
        photo.visitPlace = open
        let closed = VisitPlace(
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(60 * 60),
            latitude: twin.latitude,
            longitude: twin.longitude,
            horizontalAccuracy: 14
        )
        context.insert(open)
        context.insert(closed)
        try context.save()

        try repository.repairDuplicateStays()

        let verification = ModelContext(container)
        let places = try verification.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(places.count, 1)
        let kept = try XCTUnwrap(places.first)
        XCTAssertEqual(kept.departureDate, arrival.addingTimeInterval(60 * 60))
        XCTAssertEqual(kept.userLabel, "Studio")
        XCTAssertEqual(kept.knownPlace?.id, known.id)
        XCTAssertEqual(kept.photoAttachments.count, 1, "Photos must move, not cascade-delete with the duplicate")
    }

    func testTripThatSwallowedANightBecomesAStop() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .walking, steps: 0),
            placeNameResolver: EmptyPlaceNameResolver()
        )
        let evening = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let hotel = CLLocationCoordinate2D(latitude: 10.34, longitude: 107.08)
        let beach = offset(hotel, north: 400, east: 0)
        let morning = evening.addingTimeInterval(16 * 60 * 60)
        let first = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: hotel, horizontalAccuracy: 20, arrivalDate: evening.addingTimeInterval(-60 * 60), departureDate: evening)
        )
        let second = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: beach, horizontalAccuracy: 20, arrivalDate: morning, departureDate: morning.addingTimeInterval(2 * 60 * 60))
        )
        // Fixes hold at the hotel, go silent overnight, then reach the beach.
        let samples = try repository.appendSamples(
            from: (0...3).map { location(hotel, at: evening.addingTimeInterval(Double($0) * -20 * 60)) }
                + [location(hotel, at: morning.addingTimeInterval(-10 * 60))]
                + [location(beach, at: morning)],
            source: .fileRouteImport
        )
        _ = try repository.upsertMove(
            startPlace: first,
            endPlace: second,
            startDate: evening,
            endDate: morning,
            transportMode: .unknown,
            distanceMeters: 400,
            stepCount: 0,
            samples: samples
        )

        await assembler.repairLongHistoricalTrips()

        let moves = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
        XCTAssertFalse(
            moves.contains { $0.endDate.timeIntervalSince($0.startDate) > 6 * 60 * 60 },
            "The night should be a stop, not one long trip"
        )
        let places = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        XCTAssertGreaterThan(
            try XCTUnwrap(places.first?.departureDate).timeIntervalSince(evening),
            8 * 60 * 60,
            "The hotel stop should run through the night"
        )
    }

    func testLongFlightIsLeftAlone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let takeoff = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let landing = takeoff.addingTimeInterval(14 * 60 * 60)
        let saigon = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: CLLocationCoordinate2D(latitude: 10.81, longitude: 106.66), horizontalAccuracy: 20, arrivalDate: takeoff.addingTimeInterval(-60 * 60), departureDate: takeoff)
        )
        let sanFrancisco = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: CLLocationCoordinate2D(latitude: 37.62, longitude: -122.38), horizontalAccuracy: 20, arrivalDate: landing, departureDate: landing.addingTimeInterval(60 * 60))
        )
        let flight = try repository.upsertMove(
            startPlace: saigon,
            endPlace: sanFrancisco,
            startDate: takeoff,
            endDate: landing,
            transportMode: .plane,
            distanceMeters: 12_700_000,
            stepCount: 0,
            samples: []
        )

        XCTAssertEqual(try repository.implausiblyLongTrips().count, 0)
        XCTAssertEqual(flight.transportMode, .plane)
    }

    func testPhantomTripBetweenTheSameStopMerges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let start = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let wander = offset(home, north: 124, east: 0)
        let first = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: home, horizontalAccuracy: 14, arrivalDate: start, departureDate: start.addingTimeInterval(3 * 60 * 60))
        )
        let second = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: wander, horizontalAccuracy: 19, arrivalDate: start.addingTimeInterval(3 * 60 * 60 + 84), departureDate: start.addingTimeInterval(4 * 60 * 60))
        )
        _ = try repository.upsertMove(
            startPlace: first,
            endPlace: second,
            startDate: start.addingTimeInterval(3 * 60 * 60),
            endDate: start.addingTimeInterval(3 * 60 * 60 + 84),
            transportMode: .walking,
            distanceMeters: 1_017,
            stepCount: 0,
            samples: []
        )

        try repository.repairDuplicateStays()

        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<VisitPlace>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<MoveSegment>()), 0)
    }

    func testLateReportOfARemovedStopDoesNotBringItBack() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .walking, steps: 0),
            placeNameResolver: EmptyPlaceNameResolver()
        )
        let arrival = Date().addingTimeInterval(-3 * 60 * 60)
        let cafe = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let place = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: cafe, horizontalAccuracy: 20, arrivalDate: arrival, departureDate: .distantFuture)
        )
        repository.recordRemoval(of: place)
        context.delete(place)
        try context.save()

        await assembler.ingestVisit(
            MockVisit(coordinate: cafe, horizontalAccuracy: 14, arrivalDate: arrival, departureDate: arrival.addingTimeInterval(60 * 60))
        )

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 0)
    }

    func testStopThatRanPastAnOutingResumesAfterIt() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let evening = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let dinner = offset(home, north: 1_000, east: 0)
        let stop = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: home, horizontalAccuracy: 15, arrivalDate: evening, departureDate: evening.addingTimeInterval(14 * 60 * 60))
        )
        stop.userLabel = "Home"
        _ = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: dinner, horizontalAccuracy: 20, arrivalDate: evening.addingTimeInterval(60 * 60), departureDate: evening.addingTimeInterval(2 * 60 * 60))
        )

        let stretches = try repository.splitStopsAroundContainedOnes()

        XCTAssertEqual(stretches.count, 1)
        let places = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        XCTAssertEqual(places.count, 3)
        XCTAssertEqual(places[0].departureDate, evening.addingTimeInterval(60 * 60))
        XCTAssertEqual(places[2].arrivalDate, evening.addingTimeInterval(2 * 60 * 60))
        XCTAssertEqual(places[2].departureDate, evening.addingTimeInterval(14 * 60 * 60))
        XCTAssertEqual(places[2].userLabel, "Home")
    }

    func testRepairKeepsStopsTheyNamedDifferently() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let arrival = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let coordinate = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        for (label, north) in [("Bakery", 0.0), ("Barber", 150.0)] {
            let place = offset(coordinate, north: north, east: 0)
            context.insert(VisitPlace(
                arrivalDate: arrival,
                departureDate: arrival.addingTimeInterval(60 * 60),
                latitude: place.latitude,
                longitude: place.longitude,
                horizontalAccuracy: 14,
                userLabel: label
            ))
        }
        try context.save()

        try SwiftDataTimelineRepository(modelContext: context).repairDuplicateStays()

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 2)
    }

    /// Two stops with fixes that hold still at each and one trip the reconciler built between them.
    private struct TwoStopScene {
        let context: ModelContext
        let repository: SwiftDataTimelineRepository
        let assembler: DefaultTimelineAssembler

        func fetchMoves() throws -> [MoveSegment] {
            try context.fetch(FetchDescriptor<MoveSegment>())
        }

        func fetchPlaces() throws -> [VisitPlace] {
            try context.fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        }
    }

    func testDisabledModesStayDisabledAfterStepAndDistanceCorrections() async throws {
        let ride = try await makeTwoStopScene(
            separation: 3_600, tripMinutes: 12, steps: 40, mode: .walking,
            automaticModes: { .init(disabled: [.cycling]) }
        )
        let rideMoves = try ride.fetchMoves()
        XCTAssertFalse(rideMoves.isEmpty)
        XCTAssertTrue(rideMoves.allSatisfy { $0.transportMode != .cycling })
        await ride.assembler.reconcileSampleStays()
        XCTAssertTrue(try ride.fetchMoves().allSatisfy { $0.transportMode != .cycling })

        let lastBlock = try await makeTwoStopScene(
            separation: 200, tripMinutes: 8, steps: 100,
            automaticModes: { .init(disabled: [.walking]) }
        )
        XCTAssertFalse(try lastBlock.fetchMoves().isEmpty)
        XCTAssertTrue(try lastBlock.fetchMoves().allSatisfy { $0.transportMode != .walking })
    }

    private func makeTwoStopScene(
        separation: Double,
        tripMinutes: Double,
        steps: Int = 40,
        confidence: Double = 0.9,
        mode: TransportMode = .automotive,
        automaticModes: @escaping () -> AutomaticTransportModes = { .init() }
    ) async throws -> TwoStopScene {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: mode, steps: steps, confidence: confidence),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: automaticModes
        )
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let work = offset(home, north: separation, east: 0)
        let left = start.addingTimeInterval(3 * 60 * 60)
        let arrived = left.addingTimeInterval(tripMinutes * 60)
        _ = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: home, horizontalAccuracy: 20, arrivalDate: start, departureDate: left)
        )
        _ = try repository.addOrUpdateVisit(
            from: MockVisit(
                coordinate: work,
                horizontalAccuracy: 20,
                arrivalDate: arrived,
                departureDate: arrived.addingTimeInterval(2 * 60 * 60)
            )
        )
        _ = try repository.appendSamples(
            from: (0...4).map { location(home, at: start.addingTimeInterval(Double($0) * 40 * 60)) }
                + [location(home, at: left)]
                + (0...3).map { location(work, at: arrived.addingTimeInterval(Double($0) * 40 * 60)) },
            source: .significantChange
        )
        await assembler.reconcileSampleStays()
        return TwoStopScene(context: context, repository: repository, assembler: assembler)
    }

    private func timelineFixes(
        start: Date,
        home: CLLocationCoordinate2D,
        north: CLLocationCoordinate2D
    ) -> [CLLocation] {
        var fixes: [CLLocation] = []
        // Still at home for six hours after visit monitoring said the stay had ended.
        var time = start.addingTimeInterval(20 * 60)
        let homeUntil = start.addingTimeInterval(6 * 60 * 60)
        while time <= homeUntil {
            fixes.append(location(offset(home, north: 12, east: -8), at: time))
            time = time.addingTimeInterval(20 * 60)
        }

        // Outbound trip, about 4 km in 25 minutes.
        for step in 1...5 {
            let fraction = Double(step) / 6
            let point = CLLocationCoordinate2D(
                latitude: home.latitude + (north.latitude - home.latitude) * fraction,
                longitude: home.longitude
            )
            fixes.append(location(point, at: homeUntil.addingTimeInterval(Double(step) * 5 * 60)))
        }

        // Quiet stop: one fix on arrival, the next two hours later a short distance away.
        let arrived = homeUntil.addingTimeInterval(30 * 60)
        fixes.append(location(north, at: arrived))
        fixes.append(location(offset(north, north: 0, east: 350), at: arrived.addingTimeInterval(2 * 60 * 60)))

        // Back home, then out again to the visit monitoring finally recorded.
        let backHome = arrived.addingTimeInterval(3 * 60 * 60)
        fixes.append(location(home, at: backHome))
        fixes.append(location(home, at: backHome.addingTimeInterval(2 * 60 * 60)))
        let finalHop = backHome.addingTimeInterval(3 * 60 * 60)
        fixes.append(location(north, at: finalHop))
        fixes.append(location(north, at: finalHop.addingTimeInterval(60 * 60)))
        return fixes
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private struct FixedMotionClassifier: MotionClassifier {
    var mode: TransportMode
    var steps: Int
    var confidence: Double = 0.9

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (mode, confidence)
    }

    func stepCount(start: Date, end: Date) async -> Int? {
        steps
    }
}

private struct EmptyPlaceNameResolver: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        nil
    }
}

private func fix(
    _ coordinate: CLLocationCoordinate2D,
    at date: Date,
    accuracy: CLLocationAccuracy = 15
) -> LocationLogPoint {
    LocationLogPoint(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        horizontalAccuracy: accuracy,
        timestamp: date
    )
}

private func location(_ coordinate: CLLocationCoordinate2D, at date: Date) -> CLLocation {
    CLLocation(
        coordinate: coordinate,
        altitude: 0,
        horizontalAccuracy: 15,
        verticalAccuracy: -1,
        course: -1,
        speed: -1,
        timestamp: date
    )
}

private func offset(
    _ origin: CLLocationCoordinate2D,
    north: Double,
    east: Double
) -> CLLocationCoordinate2D {
    let latitude = origin.latitude + north / 111_320
    let longitude = origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180))
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

private func distance(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
}
