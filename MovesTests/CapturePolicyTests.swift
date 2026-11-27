import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// Guards automatic capture: how densely trips are recorded, when GPS runs, and
/// which fixes reach the store (each one is also mirrored to the private CloudKit).
final class CapturePolicyTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 10, longitude: 20)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Level

    func testBalancedIsTheDefaultAndTheChoiceIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CapturePolicyTests-\(UUID().uuidString)"))
        XCTAssertEqual(CaptureDetailLevel.load(from: defaults), .balanced)

        CaptureDetailLevel.detailed.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: "Moves.capture.detailLevel"), "detailed")
        XCTAssertEqual(CaptureDetailLevel.load(from: defaults), .detailed)

        defaults.set("somethingElse", forKey: CaptureDetailLevel.storageKey)
        XCTAssertEqual(CaptureDetailLevel.load(from: defaults), .balanced)
        XCTAssertFalse(CaptureDetailLevel.batterySaver.followsTrips)
    }

    // MARK: Configuration

    func testBalancedFollowsWalksAndDrivesAtTheirOwnDensity() {
        let walk = configuration(.balanced, motion: .walking)
        XCTAssertEqual(walk.mode, .continuous)
        XCTAssertEqual(walk.distanceFilter, 10)
        XCTAssertEqual(walk.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(walk.activityType, .fitness)
        XCTAssertFalse(walk.pausesLocationUpdatesAutomatically)

        let drive = configuration(.balanced, motion: .automotive)
        XCTAssertEqual(drive.distanceFilter, 30)
        XCTAssertEqual(drive.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(drive.activityType, .automotiveNavigation)
        XCTAssertGreaterThanOrEqual(drive.minimumInterval, 4)

        XCTAssertEqual(configuration(.balanced, motion: .cycling).distanceFilter, 15)
        XCTAssertEqual(configuration(.balanced, motion: .unknown).distanceFilter, 20)
    }

    func testSpeedDecidesWhenMotionIsUnsureOrLags() {
        XCTAssertEqual(CapturePolicy.profile(motion: .walking, recentSpeed: 14), .vehicle)
        XCTAssertEqual(CapturePolicy.profile(motion: .unknown, recentSpeed: 4), .cycling)
        XCTAssertEqual(CapturePolicy.profile(motion: .unknown, recentSpeed: 1.3), .onFoot)
        XCTAssertEqual(CapturePolicy.profile(motion: .unknown, recentSpeed: -1), .unknownMoving)
        XCTAssertEqual(CapturePolicy.profile(motion: .stationary, recentSpeed: nil), .unknownMoving)
        XCTAssertEqual(CapturePolicy.profile(motion: .automotive, recentSpeed: 0), .vehicle)
    }

    func testDetailedIsCloserAndIgnoresLowPower() {
        let lowPower = CaptureEnergyState(isLowPowerModeEnabled: true, batteryLevel: 0.1, isCharging: false)
        let walk = configuration(.detailed, motion: .walking, energy: lowPower)
        XCTAssertEqual(walk.distanceFilter, 5)
        XCTAssertEqual(walk.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(configuration(.detailed, motion: .automotive, energy: lowPower).distanceFilter, 15)
        XCTAssertEqual(configuration(.detailed, phase: .settled, energy: lowPower).mode, .departureWatch)
    }

    func testBalancedStepsDownOnLowPowerOrLowBatteryButNotWhileCharging() {
        let lowPowerMode = CaptureEnergyState(isLowPowerModeEnabled: true, batteryLevel: 0.9, isCharging: true)
        let lowBattery = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: 0.15, isCharging: false)
        let charging = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: 0.15, isCharging: true)
        XCTAssertTrue(lowPowerMode.isConstrained)
        XCTAssertTrue(lowBattery.isConstrained)
        XCTAssertFalse(charging.isConstrained)
        XCTAssertFalse(CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: nil, isCharging: false).isConstrained)

        for energy in [lowPowerMode, lowBattery] {
            let walk = configuration(.balanced, motion: .walking, energy: energy)
            XCTAssertEqual(walk.mode, .continuous, "Never below battery saver")
            XCTAssertGreaterThan(walk.distanceFilter, 10)
            XCTAssertLessThanOrEqual(walk.distanceFilter, CapturePolicy.Tuning.lastMileDistanceFilter + 10)
            XCTAssertGreaterThan(configuration(.balanced, motion: .automotive, energy: energy).distanceFilter, 30)
            // No keep-alive session while settled; the departure circle and significant changes remain.
            XCTAssertEqual(configuration(.balanced, phase: .settled, energy: energy).mode, .lowPower)
        }
        XCTAssertEqual(configuration(.balanced, motion: .walking, energy: charging).distanceFilter, 10)
    }

    /// Past incident: with a distance filter on the session, iOS suspended the app during
    /// trips and it recorded three fixes every five to eight minutes.
    func testSessionsThatMustKeepRunningAskForEveryFixAndFilterDistanceThemselves() {
        for level in [CaptureDetailLevel.balanced, .detailed] {
            let trip = configuration(level, motion: .walking)
            let waiting = configuration(level, phase: .settled)
            for session in [trip, waiting] {
                XCTAssertTrue(session.asksForEveryFix)
                XCTAssertEqual(session.systemDistanceFilter, kCLDistanceFilterNone)
                XCTAssertLessThanOrEqual(session.desiredAccuracy, kCLLocationAccuracyHundredMeters)
                XCTAssertFalse(session.pausesLocationUpdatesAutomatically)
            }
        }
        XCTAssertEqual(CapturePolicy.routeTracking.systemDistanceFilter, CapturePolicy.routeTracking.distanceFilter)
        XCTAssertEqual(CapturePolicy.lowPower.systemDistanceFilter, CapturePolicy.lowPower.distanceFilter)

        // The gate passes what the system filter would have: one fix every five meters.
        var gate = CaptureDistanceGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let everySecond = (0..<60).map { second in
            // Walking north at about 1.1 m a second.
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 37.0 + Double(second) * 0.00001, longitude: -122.0),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(Double(second))
            )
        }
        let passed = gate.pass(everySecond, minimumDistance: 5)
        XCTAssertEqual(passed.first?.timestamp, start)
        XCTAssertTrue((11...13).contains(passed.count), "\(passed.count) passed")
        // Standing still passes nothing more.
        XCTAssertTrue(gate.pass(Array(repeating: everySecond[59], count: 30), minimumDistance: 5).isEmpty)
    }

    /// Past incident (builds 67–72): following a trip held a background activity session,
    /// and iOS showed the blue location indicator in the Dynamic Island all day. Only manual
    /// route tracking may show it; everyday capture never does, at any level or phase.
    func testOnlyRouteTrackingShowsTheLocationIndicator() {
        let energies = [
            CaptureEnergyState.unconstrained,
            CaptureEnergyState(isLowPowerModeEnabled: true, batteryLevel: 0.1, isCharging: false),
        ]
        let motions: [CaptureMotionState] = [.stationary, .walking, .running, .cycling, .automotive, .unknown]
        for level in [CaptureDetailLevel.batterySaver, .balanced, .detailed] {
            for phase in [CaptureStateMachine.Phase.off, .settled, .moving] {
                for motion in motions {
                    for energy in energies {
                        let session = configuration(level, phase: phase, motion: motion, energy: energy)
                        XCTAssertFalse(session.showsLocationIndicator, "\(level) \(phase) \(motion): \(session.logDescription)")
                    }
                }
            }
        }
        XCTAssertFalse(CapturePolicy.lastMile.showsLocationIndicator)
        XCTAssertFalse(CapturePolicy.lowPower.showsLocationIndicator)
        XCTAssertFalse(CapturePolicy.departureWatch.showsLocationIndicator)
        XCTAssertTrue(CapturePolicy.routeTracking.showsLocationIndicator)
    }

    func testSettledKeepsACoarseSessionAndBatterySaverKeepsTheOriginalBehaviour() {
        let watch = configuration(.balanced, phase: .settled)
        XCTAssertEqual(watch.mode, .departureWatch)
        XCTAssertEqual(watch.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertGreaterThanOrEqual(watch.distanceFilter, 50)
        XCTAssertFalse(watch.pausesLocationUpdatesAutomatically, "Paused updates do not reliably resume")

        let saver = configuration(.batterySaver, phase: .moving, motion: .walking)
        XCTAssertEqual(saver, CapturePolicy.lowPower)
        XCTAssertEqual(saver.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(saver.distanceFilter, 150)
        XCTAssertEqual(CapturePolicy.lastMile.distanceFilter, 20)
        XCTAssertEqual(CapturePolicy.Tuning.lastMileDuration, 10 * 60)
    }

    func testManualRouteTrackingOverridesEveryLevel() {
        for level in CaptureDetailLevel.allCases {
            for phase in [CaptureStateMachine.Phase.off, .settled, .moving] {
                let routeTracking = CapturePolicy.configuration(
                    level: level, phase: phase, motion: .walking, recentSpeed: nil,
                    energy: .unconstrained, isRouteTrackingActive: true
                )
                XCTAssertEqual(routeTracking, CapturePolicy.routeTracking)
            }
        }
        XCTAssertEqual(CapturePolicy.routeTracking.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(CapturePolicy.routeTracking.distanceFilter, 10)
    }

    // MARK: Fix filter

    func testFilterDropsCachedInaccurateJitterAndTooSoonFixes() {
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)

        let cached = fix(metersEast: 0, at: start.addingTimeInterval(-60), accuracy: 10)
        let first = fix(metersEast: 0, at: start.addingTimeInterval(2), accuracy: 10, speed: 1.4)
        let tooSoon = fix(metersEast: 12, at: start.addingTimeInterval(4), accuracy: 10, speed: 1.4)
        let coarse = fix(metersEast: 30, at: start.addingTimeInterval(20), accuracy: 120, speed: 1.4)
        let second = fix(metersEast: 12, at: start.addingTimeInterval(9), accuracy: 10, speed: 1.4)
        let jitter = fix(metersEast: 14, at: start.addingTimeInterval(30), accuracy: 10, speed: 0)
        let invalid = fix(metersEast: 50, at: start.addingTimeInterval(40), accuracy: -1)

        let accepted = filter.accept([cached, first, tooSoon, second, coarse, jitter, invalid], minimumInterval: 4)

        XCTAssertEqual(accepted, [first, second])
        XCTAssertEqual(filter.dropCounts[.stale], 1)
        XCTAssertEqual(filter.dropCounts[.tooSoon], 1)
        XCTAssertEqual(filter.dropCounts[.inaccurate], 1)
        XCTAssertEqual(filter.dropCounts[.jitter], 1)
        XCTAssertEqual(filter.dropCounts[.invalid], 1)
        XCTAssertEqual(filter.acceptedCount, 2)
        XCTAssertFalse(filter.dropSummary.isEmpty)
    }

    func testFilterTakesACoarseFixAfterAMinuteWithoutABetterOne() {
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        let good = fix(metersEast: 0, at: start.addingTimeInterval(1), accuracy: 8, speed: 10)
        let inTunnel = fix(metersEast: 400, at: start.addingTimeInterval(30), accuracy: 90, speed: 10)
        let outOfTunnel = fix(metersEast: 700, at: start.addingTimeInterval(70), accuracy: 90, speed: 10)
        let tooCoarse = fix(metersEast: 1_400, at: start.addingTimeInterval(200), accuracy: 400, speed: 10)

        XCTAssertEqual(filter.accept([good, inTunnel, outOfTunnel, tooCoarse], minimumInterval: 4), [good, outOfTunnel])
    }

    func testFilterRejectsOutOfOrderFixes() {
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        let later = fix(metersEast: 100, at: start.addingTimeInterval(20), accuracy: 5, speed: 5)
        let earlier = fix(metersEast: 50, at: start.addingTimeInterval(10), accuracy: 5, speed: 5)
        XCTAssertEqual(filter.accept([later, earlier], minimumInterval: 0), [later])
        XCTAssertEqual(filter.dropCounts[.outOfOrder], 1)
    }

    /// The outcome the owner asked for: a walk drawn every 10–15 m, a drive every
    /// 30 m or more and no more than once per 4–5 s, hundreds of fixes per hour.
    func testSimulatedWalkAndDriveStoreEvenlySpacedFixes() {
        let walk = simulateTrip(level: .balanced, motion: .walking, speed: 1.4, duration: 30 * 60, accuracy: 8)
        XCTAssertGreaterThan(walk.count, 150, "A 30-minute walk was stored with 2 fixes before")
        let walkSpacing = spacings(walk)
        XCTAssertGreaterThanOrEqual(median(walkSpacing), 10)
        XCTAssertLessThanOrEqual(median(walkSpacing), 15)
        XCTAssertLessThan(Double(walk.count) * 2, 1_000, "Hundreds of fixes per hour, not thousands")

        let drive = simulateTrip(level: .balanced, motion: .automotive, speed: 14, duration: 15 * 60, accuracy: 5)
        let driveSpacing = spacings(drive)
        XCTAssertGreaterThanOrEqual(driveSpacing.min() ?? 0, 30)
        let driveIntervals = zip(drive, drive.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
        XCTAssertGreaterThanOrEqual(driveIntervals.min() ?? 0, 4)
        XCTAssertLessThan(Double(drive.count) * 4, 1_000)

        let stillAtACafe = simulateStill(duration: 10 * 60, accuracy: 15)
        XCTAssertLessThanOrEqual(stillAtACafe.count, 1, "Standing still must not grow the store")
    }

    // MARK: Settle detection

    func testSettleNeedsFourStillMinutesWithoutMotion() {
        var detector = CaptureSettleDetector()
        detector.reset(at: start)
        detector.observe(fix(metersEast: 0, at: start.addingTimeInterval(5), accuracy: 10))
        detector.observe(fix(metersEast: 200, at: start.addingTimeInterval(120), accuracy: 10))
        XCTAssertTrue(detector.hasDisplaced)
        detector.observe(fix(metersEast: 215, at: start.addingTimeInterval(150), accuracy: 10))

        let still = start.addingTimeInterval(120)
        XCTAssertNil(detector.verdict(now: still.addingTimeInterval(3 * 60), motion: .stationary, startedByMotion: false))
        XCTAssertEqual(detector.verdict(now: still.addingTimeInterval(4 * 60), motion: .stationary, startedByMotion: false), .stillWithoutMotion)
        XCTAssertNil(detector.verdict(now: still.addingTimeInterval(4 * 60), motion: .automotive, startedByMotion: false), "Stopped in traffic")
        XCTAssertEqual(detector.verdict(now: still.addingTimeInterval(10 * 60), motion: .walking, startedByMotion: false), .stillTooLong)
    }

    func testJitterInsideTheRadiusDoesNotRestartTheClock() {
        var detector = CaptureSettleDetector()
        detector.reset(at: start)
        detector.observe(fix(metersEast: 0, at: start, accuracy: 20))
        for second in stride(from: 10, through: 240, by: 10) {
            detector.observe(fix(metersEast: Double(second % 30), at: start.addingTimeInterval(TimeInterval(second)), accuracy: 20))
        }
        XCTAssertEqual(detector.stillSince, start)
        XCTAssertEqual(detector.anchor?.horizontalAccuracy, 20)
    }

    // MARK: State machine

    func testLaunchLooksFirstWithoutAKnownPointAndRestsWithOne() {
        let looking = CaptureStateMachine(level: .balanced, isListening: true, departureAnchor: nil, now: start)
        XCTAssertEqual(looking.phase, .moving)
        XCTAssertEqual(looking.movingStartedBy, .launch)

        let resting = CaptureStateMachine(level: .balanced, isListening: true, departureAnchor: anchor(), now: start)
        XCTAssertEqual(resting.phase, .settled)

        XCTAssertEqual(CaptureStateMachine(level: .batterySaver, isListening: true, departureAnchor: nil, now: start).phase, .off)
        XCTAssertEqual(CaptureStateMachine(level: .detailed, isListening: false, departureAnchor: nil, now: start).phase, .off)
    }

    func testEverySignOfMovementStartsFollowing() {
        for trigger in [CaptureStateMachine.Trigger.visitDeparture, .regionExit] {
            var machine = settledMachine()
            XCTAssertEqual(machine.handleWake(trigger, location: nil, now: start), .startedMoving(trigger))
            XCTAssertEqual(machine.phase, .moving)
        }

        var byMotion = settledMachine()
        XCTAssertEqual(byMotion.handleMotion(.stationary, now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(byMotion.handleMotion(.walking, now: start), .startedMoving(.motionActivity))

        var byFix = settledMachine()
        XCTAssertEqual(byFix.handleFix(fix(metersEast: 60, at: start, accuracy: 20), now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(byFix.handleFix(fix(metersEast: 300, at: start, accuracy: 20), now: start), .startedMoving(.displacement))

        var coarseFix = settledMachine()
        XCTAssertEqual(
            coarseFix.handleFix(fix(metersEast: 150, at: start, accuracy: 100), now: start),
            CaptureStateMachine.Transition.none,
            "Movement inside twice the accuracy is noise"
        )
    }

    /// On the phone every launch began a four-minute trip: starting significant-change
    /// monitoring handed back its last fix, hours old and from the walk home.
    func testAnOldFixFarAwayIsNotADeparture() {
        let lastNight = start.addingTimeInterval(-9 * 3_600)

        var byFix = settledMachine()
        XCTAssertEqual(byFix.handleFix(fix(metersEast: 300, at: lastNight, accuracy: 12), now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(byFix.phase, .settled)
        XCTAssertEqual(byFix.departureAnchor, anchor())
        XCTAssertEqual(
            byFix.handleFix(fix(metersEast: 300, at: start.addingTimeInterval(-5), accuracy: 12), now: start),
            .startedMoving(.displacement)
        )

        var byWake = settledMachine()
        XCTAssertEqual(
            byWake.handleWake(.significantChange, location: fix(metersEast: 2_000, at: lastNight, accuracy: 65), now: start),
            CaptureStateMachine.Transition.none
        )
        XCTAssertEqual(
            byWake.handleWake(.significantChange, location: fix(metersEast: 2_000, at: start, accuracy: 65), now: start),
            .startedMoving(.significantChange)
        )
    }

    func testASignificantChangeNearTheSettledPointIsATowerChange() {
        var machine = settledMachine()
        XCTAssertEqual(
            machine.handleWake(.significantChange, location: fix(metersEast: 100, at: start, accuracy: 65), now: start),
            CaptureStateMachine.Transition.none
        )
        XCTAssertEqual(
            machine.handleWake(.significantChange, location: fix(metersEast: 900, at: start, accuracy: 65), now: start),
            .startedMoving(.significantChange)
        )
    }

    func testAWalkSettlesAndDrawsTheDepartureCircleWhereItEnded() {
        var machine = settledMachine()
        _ = machine.handleWake(.regionExit, location: nil, now: start)
        _ = machine.handleMotion(.walking, now: start)

        var time = start
        for step in 0..<120 {
            time = start.addingTimeInterval(TimeInterval(step * 7))
            XCTAssertEqual(machine.handleFix(fix(metersEast: Double(step) * 10, at: time, accuracy: 8, speed: 1.4), now: time), CaptureStateMachine.Transition.none)
        }
        let arrived = time
        _ = machine.handleMotion(.stationary, now: arrived.addingTimeInterval(20))
        XCTAssertEqual(machine.tick(now: arrived.addingTimeInterval(3 * 60)), CaptureStateMachine.Transition.none)

        let transition = machine.tick(now: arrived.addingTimeInterval(4 * 60 + 1))
        guard case .settled(let settledAt?, .stillWithoutMotion) = transition else {
            return XCTFail("Expected to settle, got \(transition)")
        }
        XCTAssertEqual(machine.phase, .settled)
        XCTAssertEqual(settledAt.longitude, fix(metersEast: 1_190, at: arrived, accuracy: 8).coordinate.longitude, accuracy: 0.0005)
        XCTAssertTrue(settledAt.supportsDepartureRegion)
        XCTAssertEqual(machine.departureAnchor, settledAt)
    }

    func testIndoorPacingIsAFalseStartAndBriefPausesMotionTriggers() {
        var machine = settledMachine()
        XCTAssertEqual(machine.handleMotion(.walking, now: start), .startedMoving(.motionActivity))
        _ = machine.handleFix(fix(metersEast: 5, at: start.addingTimeInterval(20), accuracy: 10), now: start.addingTimeInterval(20))
        XCTAssertEqual(machine.tick(now: start.addingTimeInterval(60)), CaptureStateMachine.Transition.none)

        let settled = machine.tick(now: start.addingTimeInterval(2 * 60))
        guard case .settled(_, .falseStart) = settled else { return XCTFail("Expected a false start, got \(settled)") }

        let soon = start.addingTimeInterval(4 * 60)
        XCTAssertEqual(machine.handleMotion(.walking, now: soon), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.handleWake(.regionExit, location: nil, now: soon), .startedMoving(.regionExit), "Leaving still counts")

        var later = settledMachine()
        _ = later.handleMotion(.walking, now: start)
        _ = later.tick(now: start.addingTimeInterval(2 * 60))
        XCTAssertEqual(later.handleMotion(.walking, now: start.addingTimeInterval(8 * 60)), .startedMoving(.motionActivity))
    }

    func testSwitchingLevelsTurnsFollowingOffAndBackOn() {
        var machine = settledMachine()
        XCTAssertEqual(machine.configure(level: .batterySaver, isListening: true, now: start), .turnedOff)
        XCTAssertEqual(machine.phase, .off)
        XCTAssertEqual(machine.handleMotion(.automotive, now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.handleWake(.regionExit, location: nil, now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.configure(level: .detailed, isListening: true, now: start), .startedMoving(.launch))
        XCTAssertEqual(machine.configure(level: .detailed, isListening: false, now: start), .turnedOff)
    }

    // MARK: Store writes

    func testReconcileRunsAtMostEveryFewMinutes() {
        var throttle = ReconcileThrottle()
        XCTAssertTrue(throttle.shouldRun(at: start))
        XCTAssertFalse(throttle.shouldRun(at: start.addingTimeInterval(60)))
        XCTAssertFalse(throttle.shouldRun(at: start.addingTimeInterval(149)))
        XCTAssertTrue(throttle.shouldRun(at: start.addingTimeInterval(150)))
        throttle.recordRun(at: start.addingTimeInterval(400))
        XCTAssertFalse(throttle.shouldRun(at: start.addingTimeInterval(450)))
        XCTAssertGreaterThanOrEqual(CapturePolicy.Tuning.reconcileInterval, 120)
        XCTAssertLessThanOrEqual(CapturePolicy.Tuning.reconcileInterval, 180)
    }

    func testBufferedFixesFlushByCountOrAge() {
        XCTAssertFalse(CapturePolicy.shouldFlush(pendingCount: 0, oldestPendingAt: start, now: start.addingTimeInterval(600)))
        XCTAssertFalse(CapturePolicy.shouldFlush(pendingCount: 3, oldestPendingAt: start, now: start.addingTimeInterval(10)))
        XCTAssertTrue(CapturePolicy.shouldFlush(pendingCount: 3, oldestPendingAt: start, now: start.addingTimeInterval(30)))
        XCTAssertTrue(CapturePolicy.shouldFlush(pendingCount: 10, oldestPendingAt: start, now: start))
    }

    // MARK: Pipeline

    func testContinuousFixesAreARecordedRouteThatUploadsAsNewPoints() {
        let source = LocationSampleSource.continuous
        XCTAssertEqual(LocationSampleSource(rawValue: "continuous"), .continuous)
        XCTAssertTrue(source.isRouteTrack)
        XCTAssertTrue(source.preservesRouteResolution)
        XCTAssertFalse(source.isHistoryImport)
        XCTAssertFalse(LocationUploadFilter.importedSources.contains(source))
        XCTAssertEqual(source.priority, LocationSampleSource.routeTracking.priority)
    }

    @MainActor
    func testADenselyRecordedWalkIsRecordedNotEstimated() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let walk = (0..<120).map { step in
            fix(metersEast: Double(step) * 12, at: start.addingTimeInterval(TimeInterval(step * 8)), accuracy: 8, speed: 1.5)
        }
        let samples = try repository.appendSamples(from: walk, source: .continuous)
        XCTAssertEqual(samples.count, walk.count, "Close fixes must not be merged into each other")

        let move = MoveSegment(
            dedupeKey: "continuous-walk",
            startDate: start,
            endDate: start.addingTimeInterval(960),
            transportMode: .walking,
            distanceMeters: 1_430,
            stepCount: 2_000
        )
        context.insert(move)
        move.samples = samples

        XCTAssertTrue(move.usesHighAccuracyRouteTracking)
        XCTAssertEqual(RenderedRoute.resolvedConfidence(for: move), .recorded)
        let input = RouteMatchInput(
            move: move,
            fallback: walk.map(\.coordinate),
            snappingLevel: .normal
        )
        XCTAssertTrue(input.usesRouteTracking)
        XCTAssertEqual(input.density, .dense)
    }

    /// Measures one rebuild of the last week against a copy of a real store.
    /// Set `TEST_RUNNER_MOVES_CAPTURE_REAL_STORE` to a copied `default.store` to run it.
    @MainActor
    func testReconcileCostOnARealStoreCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOVES_CAPTURE_REAL_STORE"],
              FileManager.default.fileExists(atPath: path)
        else { throw XCTSkip("No real store copy given") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureReconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: storeURL.path + suffix)
        }

        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let samples = try context.fetchCount(FetchDescriptor<LocationSample>())

        var rebuilds: [Double] = []
        for _ in 0..<3 {
            let began = Date()
            _ = try repository.reconcileSampleStays(now: .now)
            rebuilds.append(Date().timeIntervalSince(began) * 1_000)
        }

        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: CoreMotionTransportClassifier(),
            placeNameResolver: NoNameResolver()
        )
        let fullBegan = Date()
        await assembler.reconcileSampleStays()
        let full = Date().timeIntervalSince(fullBegan) * 1_000

        let batch = (0..<10).map { step in
            fix(metersEast: Double(step) * 12, at: Date().addingTimeInterval(TimeInterval(step * 5 - 60)), accuracy: 8, speed: 1.5)
        }
        let appendBegan = Date()
        _ = try repository.appendSamples(from: batch, source: .continuous)
        try repository.saveIfNeeded()
        let append = Date().timeIntervalSince(appendBegan) * 1_000

        let report = "Reconcile on real store copy (\(samples) samples): rebuild ms \(rebuilds.map { Int($0) }), "
            + "full assembler pass \(Int(full)) ms, append+save of 10 continuous fixes \(Int(append)) ms"
        print(report)
        // Counts and timings only. Written beside the copy so the number survives parallel test clones.
        try? report.write(toFile: path + ".capture-timing.txt", atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private func configuration(
        _ level: CaptureDetailLevel,
        phase: CaptureStateMachine.Phase = .moving,
        motion: CaptureMotionState = .unknown,
        speed: CLLocationSpeed? = nil,
        energy: CaptureEnergyState = .unconstrained
    ) -> CaptureConfiguration {
        CapturePolicy.configuration(
            level: level,
            phase: phase,
            motion: motion,
            recentSpeed: speed,
            energy: energy,
            isRouteTrackingActive: false
        )
    }

    private func settledMachine() -> CaptureStateMachine {
        CaptureStateMachine(level: .balanced, isListening: true, departureAnchor: anchor(), now: start.addingTimeInterval(-3_600))
    }

    private func anchor() -> CaptureAnchor {
        CaptureAnchor(latitude: origin.latitude, longitude: origin.longitude, horizontalAccuracy: 15)
    }

    /// A synthetic fix east of a fixed test origin. Never a real place.
    private func fix(
        metersEast: Double,
        at timestamp: Date,
        accuracy: CLLocationAccuracy,
        speed: CLLocationSpeed = -1
    ) -> CLLocation {
        let metersPerDegree = 111_320 * cos(origin.latitude * .pi / 180)
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: origin.latitude,
                longitude: origin.longitude + metersEast / metersPerDegree
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: 90,
            speed: speed,
            timestamp: timestamp
        )
    }

    /// Plays CoreLocation's distance filter over a straight trip, then the quality filter.
    private func simulateTrip(
        level: CaptureDetailLevel,
        motion: CaptureMotionState,
        speed: CLLocationSpeed,
        duration: TimeInterval,
        accuracy: CLLocationAccuracy
    ) -> [CLLocation] {
        let config = configuration(level, motion: motion)
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        var delivered: [CLLocation] = []
        var lastDelivered: Double?
        for second in 0..<Int(duration) {
            let position = Double(second) * speed
            if let last = lastDelivered, position - last < config.distanceFilter { continue }
            lastDelivered = position
            delivered.append(fix(metersEast: position, at: start.addingTimeInterval(TimeInterval(second)), accuracy: accuracy, speed: speed))
        }
        return filter.accept(delivered, minimumInterval: config.minimumInterval)
    }

    /// A phone on a café table: GPS noise within the accuracy, speed zero.
    private func simulateStill(duration: TimeInterval, accuracy: CLLocationAccuracy) -> [CLLocation] {
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        let fixes = stride(from: 0, to: Int(duration), by: 5).map { second in
            fix(metersEast: Double((second * 7) % 11), at: start.addingTimeInterval(TimeInterval(second)), accuracy: accuracy, speed: 0)
        }
        return filter.accept(fixes, minimumInterval: 4)
    }

    private func spacings(_ fixes: [CLLocation]) -> [CLLocationDistance] {
        zip(fixes, fixes.dropFirst()).map { $1.distance(from: $0) }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}

private struct NoNameResolver: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? { nil }
}
