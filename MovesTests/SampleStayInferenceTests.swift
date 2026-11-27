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

    /// Capture goes quiet at a stop and wakes as the person sets off, so the first fix back
    /// is followed by a ride. Judged as travel, it left the silence without its nearby fix,
    /// and a 55-minute stop vanished as soon as the ride away was written (Da Lat, Nov 27).
    func testStopKeepsTheFixThatEndsItsSilence() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cafe = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        // Three minutes of walking up to the door, 1.5 m/s, a fix every 4 seconds.
        var points = (0...45).map { step in
            fix(offset(cafe, north: -Double(45 - step) * 6, east: 0), at: start.addingTimeInterval(Double(step) * 4), accuracy: 5)
        }
        let settled = start.addingTimeInterval(180)
        let setOff = settled.addingTimeInterval(55 * 60)
        points.append(fix(offset(cafe, north: 15, east: 0), at: setOff, accuracy: 5))
        // The ride away, 6 m/s.
        points += (1...45).map { step in
            fix(offset(cafe, north: 15 + Double(step) * 24, east: 0), at: setOff.addingTimeInterval(Double(step) * 4), accuracy: 5)
        }

        let stays = SampleStayInference.stays(from: points, now: setOff.addingTimeInterval(200))

        XCTAssertEqual(stays.count, 1)
        let stay = try XCTUnwrap(stays.first)
        XCTAssertEqual(stay.departureDate, setOff)
        XCTAssertLessThanOrEqual(abs(stay.arrivalDate.timeIntervalSince(settled)), 90)
    }

    /// Changed deliberately: 7.1 km in 24 minutes (4.9 m/s) with 25 steps a minute used to
    /// stay unknown. That is the owner's scooter in city traffic, and a motor vehicle is
    /// the answer; only Core Motion's own cycling reading keeps it from being one.
    func testFewStepsAtRidingPaceAreARideUnlessMotionSawCycling() {
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 7_100, duration: 24 * 60, stepCount: 600, locations: []),
            .automotive
        )
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .unknown, straightLine: 2_400, duration: 8 * 60, stepCount: 30, locations: []),
            .automotive,
            "A scooter ride motion left unresolved"
        )
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .unknown, straightLine: 2_400, duration: 8 * 60, stepCount: 30,
                                        dominantActivity: .cycling, locations: []),
            .unknown,
            "Cycling turned off must not become driving"
        )
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 20_000, duration: 25 * 60, stepCount: 200, locations: []),
            .automotive
        )
        // A middling step rate still does not identify a vehicle.
        XCTAssertEqual(
            ImplausibleWalk.mode(proposed: .walking, straightLine: 7_100, duration: 24 * 60, stepCount: 960),
            .unknown
        )
    }

    func testWalkWithAlmostNoStepsIsNotAWalk() {
        // 37 minutes, 1.8 km, 261 steps (7 a minute): not on foot, too slow to call a ride.
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 1_800, duration: 37 * 60, stepCount: 261, locations: []),
            .unknown
        )
        // A "run" of 6 km in 20 minutes with no steps at all is a ride.
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .running, straightLine: 6_000, duration: 20 * 60, stepCount: 0, locations: []),
            .automotive
        )
        // No step data is not zero steps: the walk stands.
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .running, straightLine: 6_000, duration: 40 * 60, stepCount: nil, locations: []),
            .running
        )
        // A short walk is not judged on steps.
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 250, duration: 4 * 60, stepCount: 0, locations: []),
            .walking
        )
    }

    /// Shapes from the owner's 2026 "runs", most imported with no step data.
    func testPaceNobodyKeepsOnFootIsNotARun() {
        func paced(_ mode: TransportMode, km: Double, minutes: Double, steps: Int? = nil,
                   dominant: TransportMode? = nil) -> TransportMode? {
            ImplausibleFootPace.mode(proposed: mode, distance: km * 1_000, duration: minutes * 60,
                                     stepCount: steps, dominantActivity: dominant)
        }
        XCTAssertEqual(paced(.running, km: 37.3, minutes: 108), .unknown, "20.7 km/h: a bike's pace, not a vehicle's")
        XCTAssertEqual(paced(.running, km: 37.3, minutes: 108, dominant: .cycling), .cycling)
        XCTAssertEqual(paced(.running, km: 30.6, minutes: 101), .unknown)
        XCTAssertEqual(paced(.running, km: 29.6, minutes: 81), .unknown)
        XCTAssertEqual(paced(.running, km: 13.6, minutes: 43), .unknown, "19 km/h for 43 minutes")
        XCTAssertEqual(paced(.running, km: 40, minutes: 50), .automotive, "48 km/h is a vehicle")
        XCTAssertEqual(paced(.running, km: 26, minutes: 200), .unknown, "Longer than 25 km")
        XCTAssertNil(paced(.running, km: 10, minutes: 50), "12 km/h is a run")
        XCTAssertNil(paced(.running, km: 5, minutes: 15), "A fast 5 km is too short to judge")
        XCTAssertNil(paced(.running, km: 13.6, minutes: 43, steps: 6_500), "A running step rate keeps it")
        XCTAssertEqual(paced(.walking, km: 4, minutes: 20), .unknown, "12 km/h for 20 minutes is not a walk")
        XCTAssertNil(paced(.walking, km: 1.5, minutes: 9), "Too short to judge")
        XCTAssertNil(paced(.walking, km: 4, minutes: 50), "4.8 km/h is a walk")
        XCTAssertNil(paced(.cycling, km: 37.3, minutes: 108))
        // Reached through the shared rule chain, distance from the trip's own path.
        XCTAssertEqual(
            StepModeRules.refinedMode(proposed: .running, straightLine: 9_000, distance: 37_300, duration: 108 * 60,
                                      stepCount: nil, locations: []),
            .unknown
        )
    }

    /// Running the rules on their own answer changes nothing, so a stored trip is never
    /// relabeled back and forth.
    func testStepRulesAreAFixedPoint() {
        let cases: [(TransportMode, Double, Double, Int?)] = [
            (.walking, 7_100, 24 * 60, 600), (.walking, 1_800, 37 * 60, 261), (.automotive, 190, 11 * 60, 240),
            (.unknown, 400, 8 * 60, 10), (.walking, 1_284, 5.7 * 60, 555), (.unknown, 2_400, 8 * 60, 30),
            (.running, 6_000, 20 * 60, 0), (.automotive, 180, 8 * 60, 0), (.walking, 900, 6 * 60, nil),
        ]
        for (mode, distance, duration, steps) in cases {
            let once = StepModeRules.refinedMode(proposed: mode, straightLine: distance, duration: duration, stepCount: steps, locations: [])
            let twice = StepModeRules.refinedMode(proposed: once, straightLine: distance, duration: duration, stepCount: steps, locations: [])
            XCTAssertEqual(twice, once, "\(mode) \(distance) m \(duration) s \(String(describing: steps))")
        }
    }

    func testOnFootDistanceFollowsStepsWithinTheStraightLineBounds() {
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: 1_000), 750)
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: 100), 500, "Never under the straight line")
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: 10_000), 1_800, "At most 3 × line + 300 m")
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: nil), 600)
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: 0), 600)
        XCTAssertEqual(OnFootDistanceEstimate.distance(straightLine: 500, stepCount: 1_000, stride: 0.8), 800)
        XCTAssertTrue(OnFootDistanceEstimate.applies(mode: .walking, interiorFixCount: 2))
        XCTAssertFalse(OnFootDistanceEstimate.applies(mode: .walking, interiorFixCount: 3))
        XCTAssertFalse(OnFootDistanceEstimate.applies(mode: .automotive, interiorFixCount: 0))
    }

    func testDepartureFollowsTheLastFixAtTheStop() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hotel = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let street = offset(hotel, north: 300, east: 0)
        let fixes = [
            boundaryFix(hotel, at: start.addingTimeInterval(10 * 60)),
            boundaryFix(hotel, at: start.addingTimeInterval(60 * 60)),
            boundaryFix(street, at: start.addingTimeInterval(65 * 60)),
            boundaryFix(offset(street, north: 200, east: 0), at: start.addingTimeInterval(68 * 60)),
        ]
        let departure = start.addingTimeInterval(4 * 60 * 60)
        let noSteps: StopBoundaryEvidence.StepLookup = { _, _ in nil }

        let trimmed = StopBoundaryEvidence.trimmedDeparture(
            centre: hotel, arrival: start, departure: departure, fixes: fixes, steps: noSteps
        )
        XCTAssertEqual(trimmed, start.addingTimeInterval(60 * 60))
        // Applied to its own answer, nothing more to trim.
        XCTAssertNil(StopBoundaryEvidence.trimmedDeparture(
            centre: hotel, arrival: start, departure: try! XCTUnwrap(trimmed), fixes: fixes, steps: noSteps
        ))

        // Indoor wander: one good fix outside, then nothing. Not a departure without steps.
        let wander = Array(fixes.prefix(3))
        XCTAssertNil(StopBoundaryEvidence.trimmedDeparture(
            centre: hotel, arrival: start, departure: departure, fixes: wander, steps: noSteps
        ))
        XCTAssertNil(StopBoundaryEvidence.trimmedDeparture(
            centre: hotel, arrival: start, departure: departure, fixes: wander, steps: { _, _ in 0 }
        ))
        // One fix outside plus walking steps since the last one inside is a departure.
        XCTAssertEqual(
            StopBoundaryEvidence.trimmedDeparture(
                centre: hotel, arrival: start, departure: departure, fixes: wander, steps: { _, _ in 450 }
            ),
            start.addingTimeInterval(60 * 60)
        )
        // A poor fix far away is not evidence.
        let poor = Array(fixes.prefix(2)) + [boundaryFix(street, at: start.addingTimeInterval(65 * 60), accuracy: 120),
                                             boundaryFix(street, at: start.addingTimeInterval(66 * 60), accuracy: 120)]
        XCTAssertNil(StopBoundaryEvidence.trimmedDeparture(
            centre: hotel, arrival: start, departure: departure, fixes: poor, steps: noSteps
        ))
    }

    func testArrivalFollowsTheFirstFixAtTheStop() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cafe = CLLocationCoordinate2D(latitude: 10, longitude: 106)
        let approach = offset(cafe, north: 0, east: 400)
        let fixes = [
            boundaryFix(approach, at: start.addingTimeInterval(60)),
            boundaryFix(offset(approach, north: 0, east: -150), at: start.addingTimeInterval(3 * 60)),
            boundaryFix(cafe, at: start.addingTimeInterval(6 * 60)),
            boundaryFix(cafe, at: start.addingTimeInterval(40 * 60)),
        ]
        XCTAssertEqual(
            StopBoundaryEvidence.trimmedArrival(centre: cafe, arrival: start, departure: start.addingTimeInterval(3_600),
                                                fixes: fixes, steps: { _, _ in nil }),
            start.addingTimeInterval(6 * 60)
        )
    }

    func testJumpTripTakesAWalksTimeWithinBounds() {
        let next = Date(timeIntervalSince1970: 1_700_000_000)
        let arrival = next.addingTimeInterval(-5 * 60 * 60)
        // 565 m at 1.3 m/s is a bit over seven minutes; the last fix there was hours earlier.
        XCTAssertEqual(
            StopBoundaryEvidence.jumpTripStart(firstArrival: arrival, nextArrival: next, distance: 565,
                                               lastOnSite: next.addingTimeInterval(-4 * 60 * 60)).timeIntervalSince1970,
            next.addingTimeInterval(-565 / 1.3).timeIntervalSince1970,
            accuracy: 1,
            "Whole seconds"
        )
        // A later last fix wins, but the trip still lasts two minutes.
        XCTAssertEqual(
            StopBoundaryEvidence.jumpTripStart(firstArrival: arrival, nextArrival: next, distance: 565,
                                               lastOnSite: next.addingTimeInterval(-30)),
            next.addingTimeInterval(-120)
        )
        // Never more than 30 minutes, never before the stop began.
        XCTAssertEqual(
            StopBoundaryEvidence.jumpTripStart(firstArrival: arrival, nextArrival: next, distance: 9_000, lastOnSite: nil),
            next.addingTimeInterval(-30 * 60)
        )
        XCTAssertEqual(
            StopBoundaryEvidence.jumpTripStart(firstArrival: next.addingTimeInterval(-60), nextArrival: next,
                                               distance: 565, lastOnSite: nil),
            next.addingTimeInterval(-60)
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
        // An imported log has no steps, and this pace is a plausible walk. Changed
        // deliberately from `stepCount: 0`: imports now pass nil, and a measured zero over
        // 1.8 km is evidence that nobody walked (see `testWalkWithAlmostNoStepsIsNotAWalk`).
        XCTAssertEqual(
            ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 1_777, duration: 19 * 60, stepCount: nil, locations: []),
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
        let places = try context.liveVisits()
        let moves = try context.liveMoves()

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
        let placesAfter = try context.liveVisits()
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

    func testPhotosTakenWithThePhoneBecomeStops() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .automotive, steps: 0),
            placeNameResolver: EmptyPlaceNameResolver()
        )
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let paris = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)

        await assembler.ingestLocations(
            (0...6).map { location(paris, at: start.addingTimeInterval(Double($0) * 10 * 60)) },
            source: .cameraPhoto
        )

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 1)
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
        // Every live row has a day; a row without one reads as retired.
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: arrival))
        context.insert(day)
        open.dayTimeline = day
        closed.dayTimeline = day
        context.insert(open)
        context.insert(closed)
        try context.save()

        try repository.repairDuplicateStays()

        let verification = ModelContext(container)
        let places = try verification.liveVisits()
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

        let moves = try ModelContext(container).liveMoves()
        XCTAssertFalse(
            moves.contains { $0.endDate.timeIntervalSince($0.startDate) > 6 * 60 * 60 },
            "The night should be a stop, not one long trip"
        )
        let places = try ModelContext(container).liveVisits()
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
        XCTAssertEqual(try verification.liveVisits().count, 1)
        XCTAssertEqual(try verification.liveMoves().count, 0)
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

    /// Field log: "Rebuilt 0 stops and 2 trips" on every run with nothing new. One trip left
    /// a stop whose arrival had been clamped past its departure; the trip from it overlapped
    /// the stop before, so each pass deleted it and the next built it again.
    @MainActor
    func testUnchangedWeekIsANoOpAfterTheFirstPass() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .walking, steps: 400),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() }
        )
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-2 * 24 * 60 * 60 + 9 * 60 * 60)
        let cafe = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let corner = offset(cafe, north: 142, east: 0)
        let office = offset(corner, north: 900, east: 0)
        let longStop = VisitPlace(arrivalDate: base, departureDate: base.addingTimeInterval(74 * 60),
                                  latitude: cafe.latitude, longitude: cafe.longitude, horizontalAccuracy: 20)
        // Arrived when the long stop ended, but "left" four minutes earlier.
        let inverted = VisitPlace(arrivalDate: base.addingTimeInterval(74 * 60), departureDate: base.addingTimeInterval(70 * 60),
                                  latitude: corner.latitude, longitude: corner.longitude, horizontalAccuracy: 20)
        let destination = VisitPlace(arrivalDate: base.addingTimeInterval(74 * 60 + 10), departureDate: base.addingTimeInterval(4 * 60 * 60),
                                     latitude: office.latitude, longitude: office.longitude, horizontalAccuracy: 20)
        // A trip the person never recognised: unknown, days old, between two other stops.
        let oldUnknownFrom = VisitPlace(arrivalDate: base.addingTimeInterval(5 * 60 * 60), departureDate: base.addingTimeInterval(6 * 60 * 60),
                                        latitude: office.latitude, longitude: office.longitude + 0.02, horizontalAccuracy: 20)
        let oldUnknownTo = VisitPlace(arrivalDate: base.addingTimeInterval(6 * 60 * 60 + 9 * 60), departureDate: base.addingTimeInterval(8 * 60 * 60),
                                      latitude: office.latitude, longitude: office.longitude + 0.04, horizontalAccuracy: 20)
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: base))
        context.insert(day)
        for place in [longStop, inverted, destination, oldUnknownFrom, oldUnknownTo] {
            place.dayTimeline = day
            context.insert(place)
        }
        let unknown = MoveSegment(dedupeKey: "old-unknown", startDate: oldUnknownFrom.departureDate!, endDate: oldUnknownTo.arrivalDate,
                                  transportMode: .unknown, distanceMeters: 2_200, stepCount: 0)
        unknown.startPlace = oldUnknownFrom
        unknown.endPlace = oldUnknownTo
        unknown.dayTimeline = day
        context.insert(unknown)
        try context.save()

        await assembler.reconcileSampleStays()
        let settled = try identities(in: ModelContext(container))

        var saves = 0
        // Only the reconciler's own context: the test host app saves its demo store too.
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for pass in 2...4 {
            let result = try repository.reconcileSampleStays(now: .now)
            XCTAssertTrue(result.moveLegs.isEmpty, "Pass \(pass) rebuilt \(result.moveLegs.count) trips with nothing new")
            XCTAssertTrue(result.newPlaces.isEmpty)
            await assembler.reconcileSampleStays()
        }
        XCTAssertEqual(saves, 0, "An unchanged week must not save")
        let after = try identities(in: ModelContext(container))
        XCTAssertEqual(after.moves, settled.moves)
        XCTAssertEqual(after.visits, settled.visits)
        XCTAssertTrue(after.moves.contains(unknown.id), "The old unknown trip stays as it was")
    }

    /// Photo fixes arrive with their capture time, days in the past. Nothing in the
    /// reconcile skips on "newest fix": every pass reads the whole window, so a stop that
    /// only a back-dated fix reveals is still built.
    @MainActor
    func testBackdatedFixInsideTheWindowIsRebuilt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: FixedMotionClassifier(mode: .walking, steps: 400),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() }
        )
        let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3 * 24 * 60 * 60 + 8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let cafe = offset(home, north: 2_000, east: 0)
        let work = offset(home, north: 4_000, east: 0)
        let atWork = morning.addingTimeInterval(7 * 60 * 60)
        _ = try repository.addOrUpdateVisit(from: MockVisit(coordinate: home, horizontalAccuracy: 20, arrivalDate: morning, departureDate: morning.addingTimeInterval(60 * 60)))
        _ = try repository.addOrUpdateVisit(from: MockVisit(coordinate: work, horizontalAccuracy: 20, arrivalDate: atWork, departureDate: atWork.addingTimeInterval(2 * 60 * 60)))
        _ = try repository.appendSamples(
            from: (0...3).map { location(home, at: morning.addingTimeInterval(Double($0) * 20 * 60)) }
                + (0...3).map { location(work, at: atWork.addingTimeInterval(Double($0) * 30 * 60)) },
            source: .significantChange
        )
        await assembler.reconcileSampleStays()
        await assembler.reconcileSampleStays()
        let before = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertFalse(before.contains { distance($0.coordinate, cafe) < 150 })

        // Fixes captured three days ago, stored now: two hours still at a café in between.
        let cafeStart = morning.addingTimeInterval(3 * 60 * 60)
        _ = try repository.appendSamples(
            from: (0...6).map { location(cafe, at: cafeStart.addingTimeInterval(Double($0) * 20 * 60)) },
            source: .significantChange
        )
        let result = try repository.reconcileSampleStays(now: .now)
        XCTAssertTrue(
            result.newPlaces.contains { distance($0.coordinate, cafe) < 150 },
            "A stop that only back-dated fixes show must be built"
        )
    }

    /// The retry that left an unknown trip open to reclassification still runs while it is fresh.
    @MainActor
    func testRecentUnknownTripIsStillRetried() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let left = Date().addingTimeInterval(-2 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let work = offset(home, north: 2_000, east: 0)
        let from = VisitPlace(arrivalDate: left.addingTimeInterval(-60 * 60), departureDate: left,
                              latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 20)
        let to = VisitPlace(arrivalDate: left.addingTimeInterval(12 * 60), departureDate: left.addingTimeInterval(60 * 60),
                            latitude: work.latitude, longitude: work.longitude, horizontalAccuracy: 20)
        // Every live row has a day; a row without one reads as retired.
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: left))
        context.insert(day)
        from.dayTimeline = day
        to.dayTimeline = day
        context.insert(from)
        context.insert(to)
        let move = MoveSegment(dedupeKey: "fresh-unknown", startDate: left, endDate: to.arrivalDate,
                               transportMode: .unknown, distanceMeters: 2_000, stepCount: nil)
        move.startPlace = from
        move.endPlace = to
        move.dayTimeline = day
        context.insert(move)
        try context.save()

        let result = try repository.reconcileSampleStays(now: .now)
        XCTAssertEqual(result.moveLegs.count, 1)
    }

    // MARK: - Stops, trips, and modes follow the evidence

    private struct Rebuild {
        let container: ModelContainer
        let context: ModelContext
        let repository: SwiftDataTimelineRepository
        let assembler: DefaultTimelineAssembler

        func places() throws -> [VisitPlace] {
            try context.fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
                .filter { !TimelineRetirement.isRetired($0) }
        }

        func moves() throws -> [MoveSegment] {
            try context.fetch(FetchDescriptor<MoveSegment>(sortBy: [SortDescriptor(\.startDate)]))
                .filter { !TimelineRetirement.isRetired($0) }
        }

        func visit(_ coordinate: CLLocationCoordinate2D, from arrival: Date, to departure: Date) throws -> VisitPlace {
            try repository.addOrUpdateVisit(
                from: MockVisit(coordinate: coordinate, horizontalAccuracy: 20, arrivalDate: arrival, departureDate: departure)
            )
        }

        func fixes(_ coordinate: CLLocationCoordinate2D, at dates: [Date]) throws {
            _ = try repository.appendSamples(from: dates.map { location(coordinate, at: $0) }, source: .significantChange)
        }

        /// Passes after the first must change nothing and save nothing.
        func assertSettled(file: StaticString = #filePath, line: UInt = #line) async throws {
            let before = (Set(try places().map(\.id)), Set(try moves().map(\.id)))
            var saves = 0
            let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
                saves += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            for _ in 0..<2 { await assembler.reconcileSampleStays() }
            XCTAssertEqual(saves, 0, "A rebuild of its own output saved", file: file, line: line)
            XCTAssertEqual(Set(try places().map(\.id)), before.0, file: file, line: line)
            XCTAssertEqual(Set(try moves().map(\.id)), before.1, file: file, line: line)
        }

        func assertInvariants(file: StaticString = #filePath, line: UInt = #line) throws {
            let stops = try places()
            for stop in stops {
                if let departure = stop.departureDate {
                    XCTAssertGreaterThanOrEqual(departure, stop.arrivalDate, "A stop ends before it begins", file: file, line: line)
                }
            }
            for (a, b) in zip(stops, stops.dropFirst()) {
                XCTAssertLessThanOrEqual(a.departureDate ?? a.arrivalDate, b.arrivalDate, "Two stops overlap", file: file, line: line)
            }
            let trips = try moves()
            for trip in trips {
                XCTAssertNotNil(trip.startPlace, file: file, line: line)
                XCTAssertNotNil(trip.endPlace, file: file, line: line)
            }
            for (a, b) in zip(trips, trips.dropFirst()) {
                XCTAssertLessThanOrEqual(a.endDate, b.startDate.addingTimeInterval(1), "Two trips overlap", file: file, line: line)
            }
        }
    }

    private func makeRebuild(
        mode: TransportMode = .walking,
        steps: Int? = 400,
        stepsPerMinute: Double? = nil
    ) throws -> Rebuild {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: RateMotionClassifier(mode: mode, steps: steps, stepsPerMinute: stepsPerMinute),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() }
        )
        return Rebuild(container: container, context: context, repository: repository, assembler: assembler)
    }

    /// A: visit monitoring said four hours; the fixes say the person left after one.
    func testStopDepartureFollowsTheFixesNotTheVisit() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let hotel = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let street = offset(hotel, north: 300, east: 0)
        let cafe = offset(hotel, north: 2_000, east: 0)
        _ = try rebuild.visit(hotel, from: start, to: start.addingTimeInterval(85 * 60))
        _ = try rebuild.visit(cafe, from: start.addingTimeInterval(90 * 60), to: start.addingTimeInterval(3 * 60 * 60))
        try rebuild.fixes(hotel, at: [start.addingTimeInterval(10 * 60), start.addingTimeInterval(60 * 60)])
        try rebuild.fixes(street, at: [start.addingTimeInterval(65 * 60)])
        try rebuild.fixes(offset(street, north: 300, east: 0), at: [start.addingTimeInterval(68 * 60)])

        await rebuild.assembler.reconcileSampleStays()

        let stay = try XCTUnwrap(try rebuild.places().first { distance($0.coordinate, hotel) < 100 })
        XCTAssertEqual(stay.departureDate, start.addingTimeInterval(60 * 60))
        let trip = try XCTUnwrap(try rebuild.moves().first)
        XCTAssertEqual(trip.startDate, start.addingTimeInterval(60 * 60))
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    /// A guard: one fix outside a building, with no steps, is indoor wander.
    func testIndoorWanderDoesNotEndAStop() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let hotel = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let cafe = offset(hotel, north: 2_000, east: 0)
        _ = try rebuild.visit(hotel, from: start, to: start.addingTimeInterval(85 * 60))
        _ = try rebuild.visit(cafe, from: start.addingTimeInterval(90 * 60), to: start.addingTimeInterval(3 * 60 * 60))
        try rebuild.fixes(hotel, at: [start.addingTimeInterval(10 * 60), start.addingTimeInterval(60 * 60)])
        try rebuild.fixes(offset(hotel, north: 0, east: 140), at: [start.addingTimeInterval(65 * 60)])

        await rebuild.assembler.reconcileSampleStays()

        let stay = try XCTUnwrap(try rebuild.places().first { distance($0.coordinate, hotel) < 100 })
        XCTAssertEqual(stay.departureDate, start.addingTimeInterval(85 * 60))
        try await rebuild.assertSettled()
    }

    /// B: a stop that "ends" exactly when one 565 m away begins swallowed the walk.
    func testStopsThatTouchFarApartGetATrip() async throws {
        let rebuild = try makeRebuild(steps: 400)
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let hotel = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let cafe = offset(hotel, north: 565, east: 0)
        let handoff = start.addingTimeInterval(4 * 60 * 60)
        _ = try rebuild.visit(hotel, from: start, to: handoff)
        _ = try rebuild.visit(cafe, from: handoff, to: handoff.addingTimeInterval(60 * 60))
        try rebuild.fixes(hotel, at: [start.addingTimeInterval(5 * 60), start.addingTimeInterval(30 * 60)])

        await rebuild.assembler.reconcileSampleStays()

        let trip = try XCTUnwrap(try rebuild.moves().first, "Every jump gets a trip")
        XCTAssertEqual(trip.endDate, handoff)
        let apart = distance(hotel, cafe)
        XCTAssertEqual(trip.startDate.timeIntervalSince1970, handoff.addingTimeInterval(-apart / 1.3).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(trip.routeMatchConfidence, .estimated, "No fix drew it")
        XCTAssertEqual(trip.transportMode, .walking)
        XCTAssertGreaterThanOrEqual(trip.distanceMeters, apart - 1)
        let stay = try XCTUnwrap(try rebuild.places().first)
        XCTAssertEqual(stay.departureDate, trip.startDate)
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    /// A late visit report dated the stop to when the person parked, before a 15-minute walk
    /// around the block and back. Joined with the stop the fixes showed, its centre came
    /// from the walk's dense fixes, the stop was trimmed to two minutes on the street and
    /// dissolved, and one trip ran from the first stop to the next (Da Lat, Nov 27).
    func testLateVisitThatClaimsTheWalkThereKeepsTheStop() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let parked = offset(home, north: 1_500, east: 0)
        let next = offset(parked, north: 0, east: 1_500)
        let left = start.addingTimeInterval(60 * 60)
        let atParking = left.addingTimeInterval(6 * 60)
        let settled = atParking.addingTimeInterval(15 * 60)
        let setOff = settled.addingTimeInterval(55 * 60)
        let atNext = setOff.addingTimeInterval(6 * 60)

        _ = try rebuild.visit(home, from: start, to: left)
        try rebuild.fixes(home, at: [5, 30, 59].map { start.addingTimeInterval($0 * 60) })
        var fixes = track(from: home, north: 1_500, east: 0, start: left, seconds: 6 * 60)
        // Out 450 m and back at 1 m/s, a fix every 4 seconds.
        fixes += track(from: parked, north: 0, east: 450, start: atParking, seconds: 7.5 * 60)
        fixes += track(from: offset(parked, north: 0, east: 450), north: 0, east: -450,
                       start: atParking.addingTimeInterval(7.5 * 60), seconds: 7.5 * 60)
        fixes.append(location(offset(parked, north: 15, east: 0), at: setOff))
        fixes += track(from: parked, north: 0, east: 1_500, start: setOff, seconds: 6 * 60)
        _ = try rebuild.repository.appendSamples(from: fixes, source: .continuous)
        _ = try rebuild.visit(next, from: atNext, to: atNext.addingTimeInterval(60 * 60))
        try rebuild.fixes(next, at: [10, 40, 59].map { atNext.addingTimeInterval($0 * 60) })
        await rebuild.assembler.reconcileSampleStays()

        // iOS reports the visit an hour late, from when the person parked.
        _ = try rebuild.visit(offset(parked, north: 40, east: 40), from: atParking, to: setOff.addingTimeInterval(15))
        await rebuild.assembler.reconcileSampleStays()

        let stop = try XCTUnwrap(try rebuild.places().first { distance($0.coordinate, parked) < 100 }, "The stop is kept")
        XCTAssertGreaterThanOrEqual(stop.arrivalDate, settled.addingTimeInterval(-90), "The walk is not part of the stop")
        XCTAssertEqual(try XCTUnwrap(stop.departureDate).timeIntervalSince(setOff), 0, accuracy: 60)
        XCTAssertEqual(try rebuild.places().count, 3)
        XCTAssertEqual(try rebuild.moves().count, 2)
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    private func makeBlipScene(
        blipMinutes: Double,
        steps: Int?,
        configure: (VisitPlace, ModelContext) -> Void = { _, _ in }
    ) async throws -> (Rebuild, CLLocationCoordinate2D) {
        let rebuild = try makeRebuild(mode: .automotive, steps: steps)
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let blip = offset(home, north: 1_000, east: 0)
        let work = offset(home, north: 2_000, east: 0)
        let left = start.addingTimeInterval(2 * 60 * 60)
        let blipArrival = left.addingTimeInterval(10 * 60)
        let blipDeparture = blipArrival.addingTimeInterval(blipMinutes * 60)
        let atWork = blipDeparture.addingTimeInterval(10 * 60)
        _ = try rebuild.visit(home, from: start, to: left)
        let stop = try rebuild.visit(blip, from: blipArrival, to: blipDeparture)
        _ = try rebuild.visit(work, from: atWork, to: atWork.addingTimeInterval(2 * 60 * 60))
        try rebuild.fixes(home, at: (0...3).map { start.addingTimeInterval(Double($0) * 40 * 60) })
        try rebuild.fixes(work, at: (0...3).map { atWork.addingTimeInterval(Double($0) * 40 * 60) })
        configure(stop, rebuild.context)
        try rebuild.context.save()
        await rebuild.assembler.reconcileSampleStays()
        return (rebuild, blip)
    }

    /// C: a two-minute stop only visit monitoring saw is not a stop; the trips join.
    func testVisitOnlyBlipIsDissolvedAndItsTripsJoin() async throws {
        let (rebuild, blip) = try await makeBlipScene(blipMinutes: 2, steps: 0)
        XCTAssertFalse(try rebuild.places().contains { distance($0.coordinate, blip) < 100 })
        XCTAssertEqual(try rebuild.places().count, 2)
        XCTAssertEqual(try rebuild.moves().count, 1, "One trip from home to work")
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    func testZeroLengthVisitOnlyStopIsDissolved() async throws {
        let (rebuild, blip) = try await makeBlipScene(blipMinutes: 0, steps: 0)
        XCTAssertFalse(try rebuild.places().contains { distance($0.coordinate, blip) < 100 })
        try await rebuild.assertSettled()
    }

    /// C: walked straight through it, by the pedometer.
    func testShortStopWalkedThroughIsDissolved() async throws {
        let (walked, blip) = try await makeBlipScene(blipMinutes: 6, steps: 600)
        XCTAssertFalse(try walked.places().contains { distance($0.coordinate, blip) < 100 })
        try await walked.assertSettled()

        let (stood, standing) = try await makeBlipScene(blipMinutes: 6, steps: 0)
        XCTAssertTrue(try stood.places().contains { distance($0.coordinate, standing) < 100 }, "Six minutes standing still is a stop")
        try await stood.assertSettled()
    }

    /// C guards: what the person named, placed, photographed, or reviewed stays.
    func testAnchoredShortStopsAreNeverDissolved() async throws {
        let named = try await makeBlipScene(blipMinutes: 2, steps: 0) { stop, _ in stop.userLabel = "Kiosk" }
        XCTAssertTrue(try named.0.places().contains { distance($0.coordinate, named.1) < 100 })
        try await named.0.assertSettled()

        let known = try await makeBlipScene(blipMinutes: 2, steps: 0) { stop, context in
            let place = KnownPlace(name: "Bakery", latitude: stop.latitude, longitude: stop.longitude)
            context.insert(place)
            stop.knownPlace = place
            stop.assignmentSource = .user
        }
        XCTAssertTrue(try known.0.places().contains { distance($0.coordinate, known.1) < 100 })

        let confirmed = try await makeBlipScene(blipMinutes: 2, steps: 0) { stop, _ in stop.reviewState = .confirmed }
        XCTAssertTrue(try confirmed.0.places().contains { distance($0.coordinate, confirmed.1) < 100 })
    }

    /// D: a stop that ends before it begins, and one that ends with another it overlaps.
    func testStopTimesAreRepairedToTheInvariants() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let base = Date().addingTimeInterval(-10 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let office = offset(home, north: 3_000, east: 0)
        let market = offset(home, north: 6_000, east: 0)
        let long = VisitPlace(arrivalDate: base, departureDate: base.addingTimeInterval(3 * 60 * 60),
                              latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 20)
        // Ends with the long stop: one of them is wrong, and it is not the later one.
        let sameEnd = VisitPlace(arrivalDate: base.addingTimeInterval(60 * 60), departureDate: base.addingTimeInterval(3 * 60 * 60),
                                 latitude: office.latitude, longitude: office.longitude, horizontalAccuracy: 20)
        sameEnd.userLabel = "Office"
        let inverted = VisitPlace(arrivalDate: base.addingTimeInterval(5 * 60 * 60), departureDate: base.addingTimeInterval(4 * 60 * 60),
                                  latitude: market.latitude, longitude: market.longitude, horizontalAccuracy: 20)
        inverted.userLabel = "Market"
        for place in [long, sameEnd, inverted] {
            let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: place.arrivalDate))
            rebuild.context.insert(day)
            place.dayTimeline = day
            rebuild.context.insert(place)
        }
        try rebuild.context.save()

        await rebuild.assembler.reconcileSampleStays()

        // Ends where the office begins, less the drive there that no fix recorded.
        let longEnd = try XCTUnwrap(long.departureDate)
        XCTAssertLessThanOrEqual(longEnd, sameEnd.arrivalDate.addingTimeInterval(-StopBoundaryEvidence.jumpMinimumTrip))
        XCTAssertGreaterThanOrEqual(longEnd, sameEnd.arrivalDate.addingTimeInterval(-StopBoundaryEvidence.jumpMaximumTrip))
        XCTAssertEqual(inverted.departureDate, inverted.arrivalDate)
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    /// E: a stored "run" whose measured steps were zero is a ride, unless the person said so.
    func testStoredRunWithoutStepsIsRelabeledUnlessThePersonChoseIt() async throws {
        for confirmed in [false, true] {
            let rebuild = try makeRebuild(mode: .running, steps: 0)
            let start = Date().addingTimeInterval(-8 * 60 * 60)
            let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
            let work = offset(home, north: 6_000, east: 0)
            let left = start.addingTimeInterval(2 * 60 * 60)
            let arrived = left.addingTimeInterval(20 * 60)
            let from = try rebuild.visit(home, from: start, to: left)
            let to = try rebuild.visit(work, from: arrived, to: arrived.addingTimeInterval(2 * 60 * 60))
            let run = try rebuild.repository.upsertMove(startPlace: from, endPlace: to, startDate: left, endDate: arrived,
                                                        transportMode: .running, distanceMeters: 6_000, stepCount: 0, samples: [])
            if confirmed {
                try rebuild.repository.setTransportMode(.running, for: run, source: .user)
            }
            try rebuild.context.save()

            await rebuild.assembler.reconcileSampleStays()

            let trip = try XCTUnwrap(try rebuild.moves().first)
            XCTAssertEqual(trip.id, run.id, "The row is updated in place")
            XCTAssertEqual(trip.transportMode, confirmed ? .running : .automotive)
            try await rebuild.assertSettled()
        }
    }

    /// F1: a trip whose ends moved apart gets a distance at least the line between them.
    func testTripDistanceFollowsItsEnds() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let work = offset(home, north: 3_000, east: 0)
        let left = start.addingTimeInterval(2 * 60 * 60)
        let arrived = left.addingTimeInterval(10 * 60)
        let from = try rebuild.visit(home, from: start, to: left)
        let to = try rebuild.visit(work, from: arrived, to: arrived.addingTimeInterval(2 * 60 * 60))
        let trip = try rebuild.repository.upsertMove(startPlace: from, endPlace: to, startDate: left, endDate: arrived,
                                                     transportMode: .automotive, distanceMeters: 900, stepCount: 0, samples: [])
        try rebuild.context.save()

        await rebuild.assembler.reconcileSampleStays()

        XCTAssertEqual(try rebuild.moves().first?.id, trip.id)
        XCTAssertGreaterThanOrEqual(trip.distanceMeters, distance(home, work) - 1)
        XCTAssertEqual(trip.transportMode, .automotive, "Only the distance was stale")
        try await rebuild.assertSettled()
    }

    /// The pace sweep reaches history of any age, imported too, and never the person's choice.
    func testPaceSweepRelabelsOldRunsButNotChosenOnesAndAsksOnlyAboutRecentOnes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date()
        func run(daysAgo: Double, origin: TimelineItemOrigin = .sensor, source: TransportModeSource = .auto) -> MoveSegment {
            let end = now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
            let move = MoveSegment(dedupeKey: UUID().uuidString, startDate: end.addingTimeInterval(-108 * 60), endDate: end,
                                   transportMode: .running, distanceMeters: 37_300, stepCount: 0)
            move.origin = origin
            move.transportModeSource = source
            let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: end))
            context.insert(day)
            move.dayTimeline = day
            context.insert(move)
            return move
        }
        let imported = run(daysAgo: 90, origin: .imported, source: .imported)
        let old = run(daysAgo: 60)
        let recent = run(daysAgo: 1)
        let chosen = run(daysAgo: 60, source: .user)
        let reviewed = run(daysAgo: 60)
        reviewed.reviewState = .confirmed
        try context.save()

        let report = try AutomaticModeHistory.applyPaceRules(in: context, now: now, preferences: .init())

        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(imported.transportMode, .unknown)
        XCTAssertEqual(imported.reviewState, ReviewState.none, "Imported history never goes to Review")
        XCTAssertEqual(old.transportMode, .unknown)
        XCTAssertEqual(old.reviewState, ReviewState.none, "Old history changes quietly")
        XCTAssertEqual(recent.transportMode, .unknown)
        XCTAssertEqual(recent.reviewState, .pending)
        XCTAssertEqual(chosen.transportMode, .running)
        XCTAssertEqual(reviewed.transportMode, .running)
        XCTAssertEqual(try AutomaticModeHistory.applyPaceRules(in: context, now: now, preferences: .init()).total, 0)
    }

    // MARK: - H: retiring rows instead of deleting them

    func testDissolvedStopIsRetiredAndStaysReadableElsewhere() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Retire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: directory.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: RateMotionClassifier(mode: .automotive, steps: 0, stepsPerMinute: nil),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() }
        )
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let blip = offset(home, north: 1_000, east: 0)
        let work = offset(home, north: 2_000, east: 0)
        let left = start.addingTimeInterval(2 * 60 * 60)
        let blipArrival = left.addingTimeInterval(10 * 60)
        let atWork = blipArrival.addingTimeInterval(12 * 60)
        let homeStop = try repository.addOrUpdateVisit(from: MockVisit(coordinate: home, horizontalAccuracy: 20, arrivalDate: start, departureDate: left))
        let blipStop = try repository.addOrUpdateVisit(from: MockVisit(coordinate: blip, horizontalAccuracy: 20, arrivalDate: blipArrival, departureDate: blipArrival.addingTimeInterval(120)))
        let workStop = try repository.addOrUpdateVisit(from: MockVisit(coordinate: work, horizontalAccuracy: 20, arrivalDate: atWork, departureDate: atWork.addingTimeInterval(2 * 60 * 60)))
        let into = try repository.upsertMove(startPlace: homeStop, endPlace: blipStop, startDate: left, endDate: blipArrival,
                                             transportMode: .walking, distanceMeters: 1_000, stepCount: 0, samples: [])
        let outOf = try repository.upsertMove(startPlace: blipStop, endPlace: workStop, startDate: blipArrival.addingTimeInterval(120),
                                              endDate: atWork, transportMode: .walking, distanceMeters: 1_000, stepCount: 0, samples: [])
        try context.save()
        let blipID = blipStop.id
        let outOfID = outOf.id

        // The view's side: another context holds the rows before the rebuild.
        let reader = ModelContext(container)
        let heldStop = try XCTUnwrap(try reader.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == blipID })).first)
        let heldTrip = try XCTUnwrap(try reader.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == outOfID })).first)
        _ = heldStop.arrivalDate
        _ = heldTrip.distanceMeters

        await assembler.reconcileSampleStays()

        // Every stored property is still readable on the other context.
        _ = (heldStop.id, heldStop.arrivalDate, heldStop.departureDate, heldStop.latitude, heldStop.longitude,
             heldStop.horizontalAccuracy, heldStop.userLabel, heldStop.autoLabel, heldStop.comment, heldStop.reviewState,
             heldStop.origin, heldStop.countryCode, heldStop.locality, heldStop.isHiddenAsShortStop)
        _ = (heldTrip.id, heldTrip.startDate, heldTrip.endDate, heldTrip.transportMode, heldTrip.distanceMeters,
             heldTrip.stepCount, heldTrip.comment, heldTrip.routeMatchSummary, heldTrip.reviewState, heldTrip.dedupeKey)
        _ = heldTrip.startPlace?.arrivalDate
        _ = heldTrip.dayTimeline?.dayKey

        let check = ModelContext(container)
        let allStops = try check.fetch(FetchDescriptor<VisitPlace>())
        let retiredStop = try XCTUnwrap(allStops.first { $0.id == blipID }, "Retired, not deleted")
        XCTAssertNil(retiredStop.dayTimeline)
        XCTAssertNil(retiredStop.knownPlace)
        XCTAssertEqual(retiredStop.reviewState, ReviewState.none)
        let allTrips = try check.fetch(FetchDescriptor<MoveSegment>())
        let retiredTrip = try XCTUnwrap(allTrips.first { $0.id == outOfID })
        XCTAssertNil(retiredTrip.dayTimeline)
        XCTAssertNil(retiredTrip.startPlace)
        XCTAssertTrue(retiredTrip.dedupeKey.hasPrefix(TimelineRetirement.dedupeKeyPrefix))
        let live = allTrips.filter { $0.dayTimeline != nil }
        XCTAssertEqual(live.map(\.id), [into.id], "The trip into the blip became the whole trip")
        XCTAssertEqual(live.first?.endPlace?.id, workStop.id)

        // A rebuild of its own output: nothing retired is read, retired again, or revived.
        var saves = 0
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 { await assembler.reconcileSampleStays() }
        XCTAssertEqual(saves, 0)
        XCTAssertNil(try ModelContext(container).fetch(FetchDescriptor<VisitPlace>()).first { $0.id == blipID }?.dayTimeline)

        let retiredCount = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>()).filter { $0.dayTimeline == nil }.count
            + (try ModelContext(container).fetch(FetchDescriptor<MoveSegment>()).filter { $0.dayTimeline == nil }.count)
        let liveCount = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>()).filter { $0.dayTimeline != nil }.count
            + (try ModelContext(container).fetch(FetchDescriptor<MoveSegment>()).filter { $0.dayTimeline != nil }.count)
        let purge = ModelContext(container)
        XCTAssertEqual(try SwiftDataTimelineRepository.purgeRetiredRows(in: purge), retiredCount)
        let after = ModelContext(container)
        XCTAssertEqual(try after.fetchCount(FetchDescriptor<VisitPlace>()) + after.fetchCount(FetchDescriptor<MoveSegment>()), liveCount)
        XCTAssertEqual(retiredCount, 2)
    }

    /// A late report of a visit whose stop the rebuild retired makes a new stop; the
    /// retired row stays retired.
    func testLateVisitReportDoesNotReviveARetiredStop() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let arrival = Date().addingTimeInterval(-3 * 60 * 60)
        let kiosk = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let visit = MockVisit(coordinate: kiosk, horizontalAccuracy: 20, arrivalDate: arrival, departureDate: arrival.addingTimeInterval(120))
        let first = try repository.addOrUpdateVisit(from: visit)
        repository.retire(first)
        try context.save()

        let again = try repository.addOrUpdateVisit(from: visit)

        XCTAssertNotEqual(again.id, first.id)
        XCTAssertNil(first.dayTimeline, "The retired row is not given a day again")
        XCTAssertEqual(try context.liveVisits().map(\.id), [again.id])
    }

    /// The person deletes a stop on the view's context while the rebuild waits on Core
    /// Motion for the trip into it. The rebuild holds no stop across that wait: it looks
    /// both ends up again, leaves that trip out, and finishes without touching the row.
    func testAStopDeletedWhileItsTripIsClassifiedIsSkippedQuietly() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let classifier = InterruptingMotionClassifier()
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: classifier,
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() }
        )
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let work = offset(home, north: 4_000, east: 0)
        let left = start.addingTimeInterval(2 * 60 * 60)
        let arrived = left.addingTimeInterval(20 * 60)
        _ = try repository.addOrUpdateVisit(from: MockVisit(coordinate: home, horizontalAccuracy: 20, arrivalDate: start, departureDate: left))
        let workStop = try repository.addOrUpdateVisit(from: MockVisit(coordinate: work, horizontalAccuracy: 20,
                                                                       arrivalDate: arrived, departureDate: arrived.addingTimeInterval(2 * 60 * 60)))
        let along = (1...9).map { step in
            location(offset(home, north: Double(step) * 400, east: 0), at: left.addingTimeInterval(Double(step) * 2 * 60))
        }
        _ = try repository.appendSamples(from: along, source: .significantChange)
        try context.save()

        let workID = workStop.id
        classifier.whileClassifying = {
            let view = ModelContext(container)
            guard let stop = try? view.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == workID })).first else { return }
            view.delete(stop)
            try? view.save()
        }
        await assembler.reconcileSampleStays()

        XCTAssertGreaterThan(classifier.classified, 0, "The trip into the stop was classified")
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == workID })), 0)
        XCTAssertFalse(try check.liveMoves().contains { $0.endPlace == nil || $0.startPlace == nil },
                       "No trip was written to a stop that is gone")
    }

    /// Photo-inferred history is the photo import's: never dissolved, trimmed, or relabeled,
    /// and its times are not evidence for the stops beside it.
    func testPhotoInferredRowsAreLeftToThePhotoImport() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let photoSpot = offset(home, north: 1_000, east: 0)
        let work = offset(home, north: 2_000, east: 0)
        let left = start.addingTimeInterval(2 * 60 * 60)
        _ = try rebuild.visit(home, from: start, to: left)
        // Touches the home stop, far away, two minutes long, made from a photo.
        let photo = VisitPlace(arrivalDate: left, departureDate: left.addingTimeInterval(120),
                               latitude: photoSpot.latitude, longitude: photoSpot.longitude, horizontalAccuracy: 50)
        photo.origin = .photoInferred
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: left))
        rebuild.context.insert(day)
        photo.dayTimeline = day
        rebuild.context.insert(photo)
        _ = try rebuild.visit(work, from: left.addingTimeInterval(30 * 60), to: left.addingTimeInterval(3 * 60 * 60))
        let run = MoveSegment(dedupeKey: "photo-run", startDate: start.addingTimeInterval(-20 * 24 * 60 * 60),
                              endDate: start.addingTimeInterval(-20 * 24 * 60 * 60 + 108 * 60),
                              transportMode: .running, distanceMeters: 37_300, stepCount: nil)
        run.origin = .photoInferred
        run.dayTimeline = day
        rebuild.context.insert(run)
        try rebuild.context.save()

        await rebuild.assembler.reconcileSampleStays()
        try AutomaticModeHistory.applyPaceRules(in: rebuild.context, preferences: .init())

        XCTAssertTrue(try rebuild.places().contains { $0.id == photo.id }, "Not dissolved")
        XCTAssertEqual(photo.departureDate, left.addingTimeInterval(120), "Not trimmed")
        XCTAssertEqual(try rebuild.places().first?.departureDate, left, "A photo's time does not shorten the stop before it")
        XCTAssertEqual(run.transportMode, .running, "The pace sweep leaves photo-inferred trips alone")
        try await rebuild.assertSettled()
    }

    /// The live trip's rebuild and the full week's agree: alternating them writes nothing
    /// after the first.
    func testTripOnlyAndFullPassesAgree() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 400)
        let start = Date().addingTimeInterval(-3 * 60 * 60)
        let hotel = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let street = offset(hotel, north: 300, east: 0)
        let cafe = offset(hotel, north: 565, east: 0)
        let far = offset(hotel, north: 3_000, east: 0)
        let handoff = start.addingTimeInterval(90 * 60)
        _ = try rebuild.visit(hotel, from: start, to: handoff)
        _ = try rebuild.visit(cafe, from: handoff, to: handoff.addingTimeInterval(20 * 60))
        // A two-minute blip, then the trip still under way.
        let blip = handoff.addingTimeInterval(30 * 60)
        _ = try rebuild.visit(offset(cafe, north: 1_000, east: 0), from: blip, to: blip.addingTimeInterval(120))
        _ = try rebuild.visit(far, from: blip.addingTimeInterval(15 * 60), to: blip.addingTimeInterval(40 * 60))
        try rebuild.fixes(hotel, at: [start.addingTimeInterval(5 * 60), start.addingTimeInterval(40 * 60)])
        try rebuild.fixes(street, at: [start.addingTimeInterval(45 * 60), start.addingTimeInterval(47 * 60)])
        try rebuild.fixes(far, at: (0...3).map { blip.addingTimeInterval(Double(15 + $0 * 8) * 60) })
        // The trip window opens after the hotel stop began, so it sees only part of it.
        let tripStart = blip.addingTimeInterval(-10 * 60)

        await rebuild.assembler.reconcile(.week)
        try rebuild.assertInvariants()
        let settled = (Set(try rebuild.places().map(\.id)), Set(try rebuild.moves().map(\.id)))
        var saves = 0
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: rebuild.context, queue: nil) { _ in
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for scope in [CaptureRebuildScope.recentTrip(since: tripStart), .week, .recentTrip(since: tripStart)] {
            await rebuild.assembler.reconcile(scope)
        }
        XCTAssertEqual(saves, 0, "A trip-only pass and a full pass disagreed")
        XCTAssertEqual(Set(try rebuild.places().map(\.id)), settled.0)
        XCTAssertEqual(Set(try rebuild.moves().map(\.id)), settled.1)
    }

    /// Field case: the first walk recorded densely. A stay at a resort, then 23 minutes on
    /// foot (a fix every 4 s, including laps around a garden within 160 m of its own centre),
    /// with a launch one-shot fix five minutes in. Trip-only rebuilds every 150 s, as capture
    /// runs them, must never open a stay on the walk, never leave a trip of no length, and
    /// a full-week rebuild at the end must change nothing.
    func testDenseWalkStaysATripWhileItIsUnderWay() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let walkStart = Date().addingTimeInterval(-30 * 60)
        var clock = walkStart
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: RateMotionClassifier(mode: .walking, steps: nil, stepsPerMinute: 110),
            placeNameResolver: EmptyPlaceNameResolver(),
            automaticModes: { .init() },
            now: { clock },
            paceRulesDefaults: nil
        )
        let resort = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
        let arrival = walkStart.addingTimeInterval(-2 * 60 * 60)
        let resortStop = try repository.addOrUpdateVisit(
            from: MockVisit(coordinate: resort, horizontalAccuracy: 20, arrivalDate: arrival, departureDate: .distantFuture)
        )
        _ = try repository.appendSamples(
            from: (0...5).map { location(resort, at: arrival.addingTimeInterval(Double($0) * 20 * 60)) },
            source: .significantChange
        )
        try context.save()

        // 0–4 min north to a garden, 4–19 min laps of a 120 m circle, 19–23 min north again.
        func position(at seconds: Double) -> CLLocationCoordinate2D {
            let speed = 1.3
            if seconds < 230 { return offset(resort, north: speed * seconds, east: 0) }
            if seconds < 1_140 {
                let angle = speed * (seconds - 230) / 120
                return offset(resort, north: 420 - 120 * cos(angle), east: 120 * sin(angle))
            }
            let start = offset(resort, north: 420 - 120 * cos(speed * 910 / 120), east: 120 * sin(speed * 910 / 120))
            return offset(start, north: speed * (seconds - 1_140), east: 0)
        }
        var lastRebuild = walkStart
        var longest: Double = 0
        for step in stride(from: 0.0, through: 23 * 60, by: 4) {
            clock = walkStart.addingTimeInterval(step)
            let fix = CLLocation(coordinate: position(at: step), altitude: 0, horizontalAccuracy: 5,
                                 verticalAccuracy: -1, course: -1, speed: 1.3, timestamp: clock)
            await assembler.ingestLocations([fix], source: step == 300 ? .launchBackfill : .continuous, reconcile: false)
            guard clock.timeIntervalSince(lastRebuild) >= 150 else { continue }
            lastRebuild = clock
            await assembler.reconcile(.recentTrip(since: walkStart))

            let stops = try context.liveVisits()
            XCTAssertEqual(stops.map(\.id), [resortStop.id], "A stay opened on the walk at \(Int(step)) s: " + stops.map { stop in
                "[\(Int(stop.arrivalDate.timeIntervalSince(walkStart)))…\(stop.departureDate.map { "\(Int($0.timeIntervalSince(walkStart)))" } ?? "open") s, \(Int(distance(stop.coordinate, resort))) m]"
            }.joined(separator: " "))
            for trip in try context.liveMoves() {
                XCTAssertGreaterThan(trip.endDate.timeIntervalSince(trip.startDate), 60, "A trip with no length")
                XCTAssertGreaterThanOrEqual(trip.distanceMeters, longest - 1, "Distance went backwards")
                longest = max(longest, trip.distanceMeters)
            }
        }
        let departure = try XCTUnwrap(resortStop.departureDate, "The resort stay ends when the walk leaves it")
        XCTAssertLessThan(departure.timeIntervalSince(walkStart), 90)

        var saves = 0
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await assembler.reconcile(.week)
        XCTAssertEqual(saves, 0, "The full week disagreed with the trip-only rebuilds")
    }

    /// A launch fix or a second visit report split one stay in two at the same spot: one stay.
    func testTouchingStopsAtTheSameSpotAreOneStay() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let resort = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
        let first = try rebuild.visit(resort, from: start, to: start.addingTimeInterval(2 * 60 * 60))
        _ = try rebuild.visit(offset(resort, north: 30, east: 0), from: start.addingTimeInterval(2 * 60 * 60 + 20),
                              to: start.addingTimeInterval(2 * 60 * 60 + 6 * 60))
        _ = try rebuild.visit(offset(resort, north: 3_000, east: 0), from: start.addingTimeInterval(3 * 60 * 60),
                              to: start.addingTimeInterval(4 * 60 * 60))

        await rebuild.assembler.reconcileSampleStays()

        XCTAssertEqual(try rebuild.places().count, 2)
        XCTAssertEqual(first.departureDate, start.addingTimeInterval(2 * 60 * 60 + 6 * 60))
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    /// Field case: after a stay the person confirmed, a few-minute stay the system matched to
    /// the same place, touching it, is that stay reported twice; the confirmed one keeps its times.
    func testDuplicateAfterAConfirmedStayGoes() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let resort = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
        let known = KnownPlace(name: "Resort", latitude: resort.latitude, longitude: resort.longitude)
        rebuild.context.insert(known)
        let stay = try rebuild.visit(resort, from: start, to: start.addingTimeInterval(2 * 60 * 60))
        stay.knownPlace = known
        stay.assignmentSource = .user
        stay.reviewState = .confirmed
        let twice = try rebuild.visit(offset(resort, north: 200, east: 0), from: start.addingTimeInterval(2 * 60 * 60),
                                      to: start.addingTimeInterval(2 * 60 * 60 + 4 * 60))
        twice.knownPlace = known
        twice.assignmentSource = .auto
        _ = try rebuild.visit(offset(resort, north: 3_000, east: 0), from: start.addingTimeInterval(3 * 60 * 60),
                              to: start.addingTimeInterval(4 * 60 * 60))
        try rebuild.context.save()

        await rebuild.assembler.reconcileSampleStays()

        XCTAssertFalse(try rebuild.places().contains { $0.id == twice.id })
        XCTAssertEqual(stay.departureDate, start.addingTimeInterval(2 * 60 * 60), "A confirmed stay keeps its times")
        XCTAssertEqual(try rebuild.moves().first?.startPlace?.id, stay.id)
        try rebuild.assertInvariants()
        try await rebuild.assertSettled()
    }

    /// A trip's times are its stops' times: a start left behind when its stop was trimmed is
    /// brought up to date, so the trip never shows no length.
    func testTripTimesFollowTheirStops() async throws {
        let rebuild = try makeRebuild(mode: .automotive, steps: 0)
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let work = offset(home, north: 3_000, east: 0)
        let left = start.addingTimeInterval(60 * 60)
        let arrived = left.addingTimeInterval(10 * 60)
        let from = try rebuild.visit(home, from: start, to: left)
        let to = try rebuild.visit(work, from: arrived, to: arrived.addingTimeInterval(60 * 60))
        // Stored as if the stop had ended four minutes later: within the old tolerance.
        let trip = try rebuild.repository.upsertMove(startPlace: from, endPlace: to, startDate: left.addingTimeInterval(4 * 60),
                                                     endDate: arrived, transportMode: .automotive, distanceMeters: 3_000,
                                                     stepCount: 0, samples: [])
        try rebuild.context.save()

        await rebuild.assembler.reconcileSampleStays()

        XCTAssertEqual(trip.startDate, left)
        XCTAssertEqual(trip.transportMode, .automotive)
        try await rebuild.assertSettled()
    }

    private func identities(in context: ModelContext) throws -> (visits: Set<UUID>, moves: Set<UUID>) {
        (Set(try context.liveVisits().map(\.id)), Set(try context.liveMoves().map(\.id)))
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

/// Steps for any interval: a fixed count, or a rate times its length.
private struct RateMotionClassifier: MotionClassifier {
    var mode: TransportMode
    var steps: Int?
    var stepsPerMinute: Double?
    var confidence: Double = 0.9

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (mode, confidence)
    }

    func stepCount(start: Date, end: Date) async -> Int? {
        if let stepsPerMinute { return Int(stepsPerMinute * end.timeIntervalSince(start) / 60) }
        return steps
    }
}

private struct EmptyPlaceNameResolver: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        nil
    }
}

/// Runs `whileClassifying` inside the Core Motion wait for a new trip, as a person's edit
/// on another context can land in that wait.
private final class InterruptingMotionClassifier: MotionClassifier {
    var whileClassifying: () -> Void = {}
    private(set) var classified = 0

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        classified += 1
        await Task.yield()
        whileClassifying()
        whileClassifying = {}
        await Task.yield()
        return (.automotive, 0.9)
    }

    func stepCount(start: Date, end: Date) async -> Int? { 0 }
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

/// What a reader of the timeline sees: rows the rebuild retired are not part of it.
extension ModelContext {
    func liveVisits() throws -> [VisitPlace] {
        try fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
            .filter { !TimelineRetirement.isRetired($0) }
    }

    func liveMoves() throws -> [MoveSegment] {
        try fetch(FetchDescriptor<MoveSegment>(sortBy: [SortDescriptor(\.startDate)]))
            .filter { !TimelineRetirement.isRetired($0) }
    }
}

private func boundaryFix(
    _ coordinate: CLLocationCoordinate2D,
    at date: Date,
    accuracy: CLLocationAccuracy = 15
) -> StopBoundaryEvidence.Fix {
    StopBoundaryEvidence.Fix(timestamp: date, coordinate: coordinate, horizontalAccuracy: accuracy)
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

/// Dense fixes every 4 seconds along a straight line, the first one 4 seconds after `start`.
private func track(
    from origin: CLLocationCoordinate2D,
    north: Double,
    east: Double,
    start: Date,
    seconds: TimeInterval
) -> [CLLocation] {
    let count = Int(seconds / 4)
    return (1...count).map { index in
        let share = Double(index) / Double(count)
        return location(offset(origin, north: north * share, east: east * share), at: start.addingTimeInterval(Double(index) * 4))
    }
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
