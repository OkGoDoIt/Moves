import XCTest
@testable import Moves

/// The Health fusion rules on plain values. Coordinates are synthetic.
final class HealthTimelineFusionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)
    private static let metersPerDegree = 111_195.0

    // MARK: Builders

    /// A straight eastward trip with a fix every `spacing` metres.
    private func trip(
        mode: TransportMode,
        meters: Double,
        minutes: Double,
        spacing: Double? = 20,
        distance: Double? = nil,
        permitsMode: Bool = true,
        permitsDistance: Bool = true
    ) -> HealthTripFacts {
        let end = start.addingTimeInterval(minutes * 60)
        let origin = HealthCoordinate(latitude: 0, longitude: 1)
        let destination = HealthCoordinate(latitude: 0, longitude: 1 + meters / Self.metersPerDegree)
        var fixes: [HealthFix] = []
        if let spacing {
            let count = max(Int(meters / spacing), 1)
            fixes = (0...count).map { index in
                let fraction = Double(index) / Double(count)
                return HealthFix(
                    latitude: 0,
                    longitude: 1 + fraction * meters / Self.metersPerDegree,
                    timestamp: start.addingTimeInterval(fraction * minutes * 60),
                    horizontalAccuracy: 10
                )
            }
        }
        return HealthTripFacts(
            id: UUID(), start: start, end: end, mode: mode,
            distanceMeters: distance ?? meters,
            startCoordinate: origin, endCoordinate: destination,
            fixes: fixes, permitsModeChange: permitsMode, permitsDistanceCorrection: permitsDistance,
            pedometerSteps: nil, matchedRouteMeters: nil, sampleCount: fixes.count
        )
    }

    private func buckets(for trip: HealthTripFacts, stepsPerMinute: [Double]) -> [HealthBucket] {
        stepsPerMinute.enumerated().map { index, rate in
            let bucketStart = trip.start.addingTimeInterval(Double(index) * 300)
            return HealthBucket(start: bucketStart, end: bucketStart.addingTimeInterval(300), steps: rate * 5, meters: rate * 5 * 0.7)
        }
    }

    // MARK: Recording quality and calibration

    func testRecordingQualityRequiresDenseFixesAndNoLongGap() {
        let dense = trip(mode: .walking, meters: 1_000, minutes: 12, spacing: 20)
        XCTAssertTrue(HealthRecordingQuality(fixes: dense.fixes).isWellRecordedWalk(dense))

        let sparse = trip(mode: .walking, meters: 1_000, minutes: 12, spacing: 200)
        XCTAssertFalse(HealthRecordingQuality(fixes: sparse.fixes).isWellRecordedWalk(sparse))

        var gappy = dense
        gappy.fixes.removeSubrange(10..<20) // one 220 m gap
        XCTAssertFalse(HealthRecordingQuality(fixes: gappy.fixes).isWellRecordedWalk(gappy))

        let short = trip(mode: .walking, meters: 250, minutes: 4)
        XCTAssertFalse(HealthRecordingQuality(fixes: short.fixes).isWellRecordedWalk(short), "Under 300 m")
        let quick = trip(mode: .walking, meters: 400, minutes: 2.5)
        XCTAssertFalse(HealthRecordingQuality(fixes: quick.fixes).isWellRecordedWalk(quick), "Under 3 minutes")
        let ride = trip(mode: .automotive, meters: 1_000, minutes: 3)
        XCTAssertFalse(HealthRecordingQuality(fixes: ride.fixes).isWellRecordedWalk(ride))
    }

    func testCalibrationNeedsEightWalksTakesTheMedianAndClamps() {
        XCTAssertEqual(HealthStrideCalibration.calibrate(ratios: Array(repeating: 1.2, count: 7)).k, 1)
        XCTAssertEqual(HealthStrideCalibration.calibrate(ratios: Array(repeating: 1.2, count: 7)).sampleCount, 7)

        let ratios = [1.10, 1.12, 1.08, 1.15, 0.2, 5.0, 1.11, 1.09]
        let calibrated = HealthStrideCalibration.calibrate(ratios: ratios)
        XCTAssertTrue(calibrated.isCalibrated)
        XCTAssertEqual(calibrated.k, 1.105, accuracy: 0.001, "Median ignores the two outliers")

        XCTAssertEqual(HealthStrideCalibration.calibrate(ratios: Array(repeating: 2, count: 9)).k, 1.3)
        XCTAssertEqual(HealthStrideCalibration.calibrate(ratios: Array(repeating: 0.4, count: 9)).k, 0.7)
        XCTAssertEqual(HealthStrideCalibration.calibrate(ratios: [.nan, .infinity, -1, 0]).sampleCount, 0)
    }

    func testCalibrationRatioComesOnlyFromWellRecordedWalksWithHealthDistance() {
        let walk = trip(mode: .walking, meters: 1_100, minutes: 14)
        let quality = HealthRecordingQuality(fixes: walk.fixes)
        let ratio = HealthStrideCalibration.ratio(trip: walk, quality: quality, healthDistance: .value(1_000))
        XCTAssertEqual(ratio ?? 0, 1.1, accuracy: 0.01)
        XCTAssertNil(HealthStrideCalibration.ratio(trip: walk, quality: quality, healthDistance: .value(0)))
        XCTAssertNil(HealthStrideCalibration.ratio(trip: walk, quality: quality, healthDistance: .unknown(.locked)))
        let sparse = trip(mode: .walking, meters: 1_100, minutes: 14, spacing: 300)
        XCTAssertNil(HealthStrideCalibration.ratio(trip: sparse, quality: HealthRecordingQuality(fixes: sparse.fixes), healthDistance: .value(1_000)))
    }

    // MARK: Walk distance

    private func decide(
        _ trip: HealthTripFacts,
        k: Double = 1,
        health: HealthValue,
        steps: HealthValue = .value(1_500),
        original: Double? = nil
    ) -> HealthWalkDistanceDecision {
        HealthWalkDistance.decide(
            trip: trip, quality: HealthRecordingQuality(fixes: trip.fixes),
            originalDistance: original ?? trip.distanceMeters,
            calibration: HealthStrideCalibration(k: k, sampleCount: 10),
            healthDistance: health, steps: steps
        )
    }

    func testPoorlyRecordedWalkTakesCalibratedHealthDistanceWithinBounds() {
        // Two fixes 600 m apart; the person really walked a winding 1.1 km.
        let walk = trip(mode: .walking, meters: 600, minutes: 15, spacing: 600)
        XCTAssertEqual(decide(walk, k: 1.1, health: .value(1_000)), .apply(meters: 1_100))
    }

    func testWalkDistanceIsLeftAloneWhenItCannotBeTrusted() {
        let walk = trip(mode: .walking, meters: 600, minutes: 15, spacing: 600)
        XCTAssertEqual(decide(walk, health: .value(500)), .keep(.shorterThanStraightLine), "Under 0.9 × straight line")
        XCTAssertEqual(decide(walk, health: .value(1_900)), .keep(.implausiblyLong), "Over 3 × path")
        XCTAssertEqual(decide(walk, health: .value(1_000), steps: .value(0)), .keep(.noSteps))
        XCTAssertEqual(decide(walk, health: .unknown(.locked)), .keep(.unknownHealth))
        XCTAssertEqual(decide(walk, health: .value(610)), .keep(.unchanged))

        let dense = trip(mode: .walking, meters: 1_000, minutes: 12)
        XCTAssertEqual(decide(dense, health: .value(1_400)), .keep(.wellRecorded), "GPS beats the pedometer")

        let curated = trip(mode: .walking, meters: 600, minutes: 15, spacing: 600, permitsDistance: false)
        XCTAssertEqual(decide(curated, health: .value(1_000)), .keep(.notEligible))

        let ride = trip(mode: .automotive, meters: 600, minutes: 15, spacing: 600)
        XCTAssertEqual(decide(ride, health: .value(1_000)), .keep(.notOnFoot))
    }

    func testWalkWithoutARouteAllowsThreeTimesStraightLinePlusAllowance() {
        let walk = trip(mode: .walking, meters: 400, minutes: 15, spacing: nil, distance: 0)
        XCTAssertEqual(decide(walk, health: .value(1_450)), .apply(meters: 1_450))
        XCTAssertEqual(decide(walk, health: .value(1_550)), .keep(.implausiblyLong))
    }

    func testReRunsDeriveFromTheOriginalDistance() {
        // Stored distance is an earlier estimate; the original path was 600 m.
        let walk = trip(mode: .walking, meters: 600, minutes: 15, spacing: 600, distance: 1_100)
        XCTAssertEqual(decide(walk, k: 1.2, health: .value(1_000), original: 600), .apply(meters: 1_200))
        XCTAssertEqual(decide(walk, health: .value(1_900), original: 600), .keep(.implausiblyLong))
    }

    // MARK: Mode votes

    private func vote(_ trip: HealthTripFacts, steps: Double, buckets: [HealthBucket] = []) -> HealthModeVote? {
        HealthModeEvidence.vote(trip: trip, steps: steps, buckets: buckets)
    }

    func testWalksWithAlmostNoStepsAreNotOnFoot() {
        // 1.8 km in 37 minutes with 261 steps.
        let slowWalk = trip(mode: .walking, meters: 1_800, minutes: 37, spacing: 300)
        XCTAssertEqual(vote(slowWalk, steps: 261), .notOnFoot)
        XCTAssertEqual(HealthModeEvidence.proposedMode(for: slowWalk, vote: .notOnFoot, preferences: .init()), .unknown,
                       "Ruled out as a walk, but not identified as a vehicle")

        // A 6 km "run" with no steps at all.
        let run = trip(mode: .running, meters: 6_000, minutes: 12, spacing: 300)
        XCTAssertEqual(vote(run, steps: 0), .notOnFoot)
        XCTAssertEqual(HealthModeEvidence.proposedMode(for: run, vote: .notOnFoot, preferences: .init()), .unknown)

        let fast = trip(mode: .walking, meters: 6_000, minutes: 10, spacing: 300)
        XCTAssertEqual(HealthModeEvidence.proposedMode(for: fast, vote: .notOnFoot, preferences: .init()), .automotive)
    }

    func testRealWalksShortTripsAndFootstepNoiseDoNotVote() {
        let walk = trip(mode: .walking, meters: 1_200, minutes: 15)
        XCTAssertNil(vote(walk, steps: 1_500))
        XCTAssertNil(vote(trip(mode: .walking, meters: 350, minutes: 6), steps: 0), "Under 400 m")
        XCTAssertNil(vote(trip(mode: .walking, meters: 900, minutes: 2.5), steps: 0), "Under 3 minutes")
        // Hundreds of false steps on a bumpy motorbike ride stay a ride.
        XCTAssertNil(vote(trip(mode: .automotive, meters: 8_000, minutes: 20), steps: 400))
        // Driving 1–3 km with no steps is right.
        XCTAssertNil(vote(trip(mode: .automotive, meters: 2_000, minutes: 7), steps: 0))
    }

    func testUnresolvedRideWithFewStepsGetsAVoteButNoNewMode() {
        let scooter = trip(mode: .unknown, meters: 3_000, minutes: 10)
        XCTAssertEqual(vote(scooter, steps: 150), .notOnFoot)
        XCTAssertNil(HealthModeEvidence.proposedMode(for: scooter, vote: .notOnFoot, preferences: .init()))
        XCTAssertNil(vote(scooter, steps: 400), "Over 25 steps a minute")
    }

    func testSlowUnknownTripWithSustainedWalkingIsOnFoot() {
        let shuffle = trip(mode: .unknown, meters: 1_500, minutes: 20)
        let walking = buckets(for: shuffle, stepsPerMinute: [100, 105, 95, 40])
        XCTAssertEqual(vote(shuffle, steps: 1_700, buckets: walking), .onFoot)
        XCTAssertEqual(HealthModeEvidence.proposedMode(for: shuffle, vote: .onFoot, preferences: .init()), .walking)

        let burst = buckets(for: shuffle, stepsPerMinute: [300, 10, 10, 10])
        XCTAssertNil(vote(shuffle, steps: 1_650, buckets: burst), "One burst is not most of the trip")

        let fastRide = trip(mode: .automotive, meters: 6_000, minutes: 20)
        XCTAssertNil(vote(fastRide, steps: 1_700, buckets: walking), "Too fast to be on foot")
    }

    func testVotesNeverOverrideCuratedTripsOrDisabledModes() {
        let curated = trip(mode: .walking, meters: 1_800, minutes: 37, spacing: 300, permitsMode: false)
        XCTAssertNil(HealthModeEvidence.proposedMode(for: curated, vote: .notOnFoot, preferences: .init()))
        let shuffle = trip(mode: .unknown, meters: 1_500, minutes: 20)
        XCTAssertNil(HealthModeEvidence.proposedMode(for: shuffle, vote: .onFoot, preferences: .init(disabled: [.walking])))
    }

    func testStepEvidenceKeepsUnknownAndZeroApart() {
        let zero = HealthStepEvidence(steps: .value(0), duration: 600, vote: .notOnFoot)
        XCTAssertEqual(zero.stepsPerMinute, 0)
        XCTAssertEqual(zero.classifierStepCount(stored: nil), 0)
        let unknown = HealthStepEvidence(steps: .unknown(.beforeAuthorizedWindow), duration: 600, vote: nil)
        XCTAssertNil(unknown.stepsPerMinute)
        XCTAssertEqual(unknown.classifierStepCount(stored: 0), 0, "Falls back to the stored value, whatever it means")
        XCTAssertNil(unknown.classifierStepCount(stored: nil))
        XCTAssertEqual(HealthStepEvidence(steps: .value(812.4), duration: 600, vote: nil).classifierStepCount(stored: 0), 812)
    }

    func testNoSamplesInsideADayWithDataMeansZeroOtherwiseUnknown() {
        XCTAssertEqual(HealthTimelineFusion.resolveTripValue(.unknown(.noData), dayHasData: true), .value(0))
        XCTAssertEqual(HealthTimelineFusion.resolveTripValue(.unknown(.noData), dayHasData: false), .unknown(.noData))
        XCTAssertEqual(HealthTimelineFusion.resolveTripValue(.unknown(.locked), dayHasData: true), .unknown(.locked))
        XCTAssertEqual(HealthTimelineFusion.resolveTripValue(.value(12), dayHasData: false), .value(12))
    }

    // MARK: Stays, days, routes

    func testWalkingInsideAStayIsForDisplayOnly() {
        let calibration = HealthStrideCalibration(k: 1.1, sampleCount: 9)
        let short = HealthStayFacts(id: UUID(), arrival: start, departure: start.addingTimeInterval(19 * 60))
        XCTAssertNil(HealthStayWalking.summarize(stay: short, steps: .value(2_000), distance: .value(1_400), calibration: calibration))

        let long = HealthStayFacts(id: UUID(), arrival: start, departure: start.addingTimeInterval(3 * 3_600))
        let walked = HealthStayWalking.summarize(stay: long, steps: .value(900), distance: .value(600), calibration: calibration)
        XCTAssertEqual(walked?.walkedMeters, 660)
        XCTAssertEqual(walked?.isWorthShowing, true)
        let little = HealthStayWalking.summarize(stay: long, steps: .value(300), distance: .value(200), calibration: calibration)
        XCTAssertEqual(little?.isWorthShowing, false)
        XCTAssertNil(HealthStayWalking.summarize(stay: long, steps: .unknown(.locked), distance: .value(200), calibration: calibration))
    }

    func testDaySummaryKeepsUnknownFieldsUnknown() {
        let summary = HealthDaySummary.summarize(
            dayKey: "2026-01-02", steps: .value(8_412.4), distance: .value(5_000),
            flights: .unknown(.noData), calibration: HealthStrideCalibration(k: 1.1, sampleCount: 9)
        )
        XCTAssertEqual(summary.steps, 8_412)
        XCTAssertEqual(summary.walkedMeters, 5_500)
        XCTAssertNil(summary.flights)
        XCTAssertFalse(HealthDaySummary(dayKey: "x").hasAnyValue)
    }

    func testRouteSignalBands() {
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .value(1_200), steps: .value(1)), .agree)
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .value(1_600), steps: .value(1)), .wandered)
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .value(400), steps: .value(500)), .shortfall)
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .value(400), steps: .value(0)), .inconclusive)
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .value(1_400), steps: .value(1)), .inconclusive)
        XCTAssertEqual(HealthRouteSignal.classify(routeMeters: 1_000, healthMeters: .unknown(.locked), steps: .value(1)), .inconclusive)
    }

    func testSignatureIsStableAndNoticesChanges() {
        let walk = trip(mode: .walking, meters: 1_000, minutes: 12)
        let identity = HealthStrideCalibration.identity
        let first = HealthTimelineFusion.signature(trips: [walk], stays: [], calibration: identity)
        XCTAssertEqual(first, HealthTimelineFusion.signature(trips: [walk], stays: [], calibration: identity))
        var edited = walk
        edited.mode = .running
        XCTAssertNotEqual(first, HealthTimelineFusion.signature(trips: [edited], stays: [], calibration: identity))
        XCTAssertNotEqual(first, HealthTimelineFusion.signature(trips: [walk], stays: [], calibration: .init(k: 1.1, sampleCount: 8)))
    }

    func testDayIntervalUsesTheTimelineDaysOwnStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // The day clocks went back: 25 hours long.
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertEqual(HealthTimelineFusion.dayInterval(dayStart: dayStart, calendar: calendar).duration, 25 * 3_600)
        let ordinary = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        XCTAssertEqual(HealthTimelineFusion.dayInterval(dayStart: ordinary, calendar: calendar).duration, 24 * 3_600)
    }
}
