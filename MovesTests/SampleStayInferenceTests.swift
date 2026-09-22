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
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self
        ])
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

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode {
        mode
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
