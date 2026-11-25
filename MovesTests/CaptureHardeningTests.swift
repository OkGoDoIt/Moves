import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// Guards the edges of automatic capture: what reaches the store and in which order,
/// how rebuilds are scoped and coalesced, and how the state machine behaves on the
/// awkward days (tunnels, flights, pacing, clock changes, permission changes).
/// Coordinates are synthetic offsets from a made-up origin, never real places.
@MainActor
final class CaptureHardeningTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 10, longitude: 20)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Pipeline order

    func testInterleavedFixesVisitsAndRebuildsArriveInTheOrderTheyHappened() async {
        let assembler = RecordingAssembler()
        let pipeline = CaptureIngestPipeline(assembler: assembler, backgroundTime: .unavailable)

        // Earlier jobs take longer, so any job that ran ahead would show up early.
        pipeline.store([fix(metersEast: 0, at: start, accuracy: 5)], source: .continuous)
        pipeline.visit(CLVisit())
        pipeline.store([fix(metersEast: 10, at: start.addingTimeInterval(5), accuracy: 5)], source: .significantChange)
        pipeline.rebuild(.recentTrip(since: start))
        pipeline.run("check") { assembler.events.append("run check") }
        pipeline.store([fix(metersEast: 20, at: start.addingTimeInterval(10), accuracy: 5)], source: .continuous)
        pipeline.visit(CLVisit())
        pipeline.rebuild(.week)

        XCTAssertTrue(assembler.events.isEmpty, "Enqueueing returns at once; the work runs later")
        XCTAssertFalse(pipeline.isIdle)
        await pipeline.drain()

        XCTAssertEqual(assembler.events, [
            "store 1 continuous",
            "visit",
            "store 1 significantChange",
            "rebuild trip",
            "run check",
            "store 1 continuous",
            "visit",
            "rebuild week",
        ])
        XCTAssertTrue(pipeline.isIdle)
    }

    func testAdjacentWritesCombineAndCoveredRebuildsAreDropped() async {
        let assembler = RecordingAssembler()
        assembler.rebuildDelay = .milliseconds(50)
        let pipeline = CaptureIngestPipeline(assembler: assembler, backgroundTime: .unavailable)

        // While the first job runs, two writes and three rebuild requests pile up.
        pipeline.rebuild(.week)
        pipeline.store([fix(metersEast: 0, at: start, accuracy: 5)], source: .continuous)
        pipeline.store([fix(metersEast: 10, at: start.addingTimeInterval(5), accuracy: 5)], source: .continuous)
        pipeline.rebuild(.recentTrip(since: start))
        pipeline.rebuild(.week)
        await pipeline.drain()
        XCTAssertEqual(assembler.events, ["rebuild week", "store 2 continuous", "rebuild week"])

        // A request while a covering rebuild runs, with nothing written since, is that rebuild.
        assembler.events.removeAll()
        pipeline.rebuild(.week)
        await Task.yield()
        XCTAssertEqual(assembler.events, [], "Still running")
        pipeline.rebuild(.recentTrip(since: start))
        pipeline.rebuild(.week)
        await pipeline.drain()
        XCTAssertEqual(assembler.events, ["rebuild week"])
        XCTAssertGreaterThanOrEqual(pipeline.coalescedRebuilds, 3)

        // A fix written behind the running rebuild means the next one is needed.
        assembler.events.removeAll()
        pipeline.rebuild(.week)
        await Task.yield()
        pipeline.store([fix(metersEast: 30, at: start.addingTimeInterval(30), accuracy: 5)], source: .continuous)
        pipeline.rebuild(.week)
        await pipeline.drain()
        XCTAssertEqual(assembler.events, ["rebuild week", "store 1 continuous", "rebuild week"])
    }

    func testThePipelineHoldsBackgroundTimeUntilItsLastWriteLands() async {
        var begun = 0
        var ended = 0
        let time = CaptureBackgroundTime(
            begin: { _, _ in begun += 1; return begun },
            end: { _ in ended += 1 }
        )
        let assembler = RecordingAssembler()
        let pipeline = CaptureIngestPipeline(assembler: assembler, backgroundTime: time)

        pipeline.store([fix(metersEast: 0, at: start, accuracy: 5)], source: .continuous)
        pipeline.rebuild(.week)
        XCTAssertEqual(begun, 1, "Held from the moment the flush is requested")
        XCTAssertEqual(ended, 0)
        await pipeline.drain()
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, 1)

        pipeline.store([fix(metersEast: 5, at: start.addingTimeInterval(5), accuracy: 5)], source: .continuous)
        await pipeline.drain()
        XCTAssertEqual(begun, 2)
        XCTAssertEqual(ended, 2)
    }

    func testQueuedFixesAreWrittenSynchronouslyBeforeTermination() async {
        let assembler = RecordingAssembler()
        assembler.rebuildDelay = .milliseconds(50)
        let pipeline = CaptureIngestPipeline(assembler: assembler, backgroundTime: .unavailable)
        pipeline.rebuild(.week)
        await Task.yield()
        pipeline.store([fix(metersEast: 0, at: start, accuracy: 5), fix(metersEast: 9, at: start.addingTimeInterval(4), accuracy: 5)], source: .continuous)
        pipeline.visit(CLVisit())

        XCTAssertEqual(pipeline.writeQueuedFixesBeforeTermination(), 2)
        XCTAssertEqual(assembler.immediateWrites, 2)
        await pipeline.drain()
        XCTAssertEqual(assembler.events, ["rebuild week", "visit"], "The written fixes are not written twice")
    }

    /// From a real evening: a visit's place lookup never came back, and every fix of the
    /// drive that followed sat in memory behind it until the app was ended.
    func testFixesAreWrittenPastAJobThatHasStoppedMoving() async {
        let assembler = RecordingAssembler()
        assembler.visitDelay = .seconds(2)
        let pipeline = CaptureIngestPipeline(assembler: assembler, backgroundTime: .unavailable, stallAllowance: 0.1)

        pipeline.visit(CLVisit())
        pipeline.store([fix(metersEast: 0, at: start, accuracy: 5)], source: .continuous)
        XCTAssertEqual(assembler.immediateWrites, 0, "A job that has only just started keeps its place in line")

        // Nothing else arrives: the waiting fix is still written once the job has had its time.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(assembler.immediateWrites, 1)

        // Fixes that arrive while it is still stuck go straight to the store.
        pipeline.store([
            fix(metersEast: 10, at: start.addingTimeInterval(5), accuracy: 5),
            fix(metersEast: 20, at: start.addingTimeInterval(10), accuracy: 5),
        ], source: .continuous)
        XCTAssertEqual(assembler.immediateWrites, 3)
        XCTAssertEqual(pipeline.fixesWrittenPastStalls, 3)

        // A rebuild asked for now has fixes the stuck job never saw, so it still runs.
        pipeline.rebuild(.week)
        await pipeline.drain()
        XCTAssertEqual(assembler.events, ["visit", "rebuild week"], "Written once, not again when the job finishes")
    }

    func testAnAnswerThatNeverComesIsGivenUpOn() async {
        let started = ContinuousClock.now
        let name: String? = await BoundedWait.run(seconds: 0.1, fallback: nil) {
            try? await Task.sleep(for: .seconds(30))
            return "Too late"
        }
        XCTAssertNil(name)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        let prompt: String? = await BoundedWait.run(seconds: 5, fallback: nil) { "In time" }
        XCTAssertEqual(prompt, "In time")
    }

    // MARK: Rebuild coalescing in the assembler

    func testARebuildRequestedDuringOneWithNoNewDataDoesNotRunAgain() async throws {
        let gate = ResolverGate()
        let (assembler, _) = try makeAssembler(resolver: GatedResolver(gate: gate))
        assembler.storeImmediately(stayFixes(at: 0, from: Date().addingTimeInterval(-40 * 60), minutes: 20), source: .continuous)

        let first = Task { await assembler.reconcile(.week) }
        await gate.waitUntilEntered()
        let second = Task { await assembler.reconcile(.week) }
        let narrower = Task { await assembler.reconcile(.recentTrip(since: Date().addingTimeInterval(-3_600))) }
        for _ in 0..<20 { await Task.yield() }
        await gate.release()
        await first.value
        await second.value
        await narrower.value

        XCTAssertEqual(assembler.rebuildCount, 1, "Two rebuilds 120 ms apart was this case")
        XCTAssertEqual(assembler.lastRebuildChanges.stops, 1)
    }

    func testARebuildRequestedAfterNewFixesArrivedDuringOneRunsOnceMore() async throws {
        let gate = ResolverGate()
        let (assembler, _) = try makeAssembler(resolver: GatedResolver(gate: gate))
        let now = Date()
        assembler.storeImmediately(stayFixes(at: 0, from: now.addingTimeInterval(-40 * 60), minutes: 20), source: .continuous)

        let first = Task { await assembler.reconcile(.week) }
        await gate.waitUntilEntered()
        assembler.storeImmediately([fix(metersEast: 400, at: now.addingTimeInterval(-60), accuracy: 8, speed: 1.4)], source: .continuous)
        let second = Task { await assembler.reconcile(.week) }
        // Fixes the store already holds are not new data.
        assembler.storeImmediately([fix(metersEast: 400, at: now.addingTimeInterval(-60), accuracy: 8, speed: 1.4)], source: .continuous)
        for _ in 0..<20 { await Task.yield() }
        await gate.release()
        await first.value
        await second.value

        XCTAssertEqual(assembler.rebuildCount, 2)
    }

    func testTheRebuildLogCountsOnlyRealChanges() async throws {
        let (assembler, container) = try makeAssembler(resolver: NoNames())
        let now = Date()
        let tripStart = now.addingTimeInterval(-50 * 60)
        var fixes = stayFixes(at: 0, from: tripStart.addingTimeInterval(-20 * 60), minutes: 20)
        fixes += (1...10).map { step in
            fix(metersEast: Double(step) * 150, at: tripStart.addingTimeInterval(TimeInterval(step * 60)), accuracy: 8, speed: 2.5)
        }
        fixes += stayFixes(at: 1_500, from: tripStart.addingTimeInterval(11 * 60), minutes: 25)
        assembler.storeImmediately(fixes, source: .continuous)

        await assembler.reconcile(.week)
        XCTAssertGreaterThanOrEqual(assembler.lastRebuildChanges.stops, 2)
        XCTAssertEqual(assembler.lastRebuildChanges.trips, 1)
        let trips = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(trips.first?.transportMode, .unknown, "Unknown is retried by every pass for a day")

        // The next pass rewrites that trip with the same answer: not a change.
        await assembler.reconcile(.week)
        XCTAssertEqual(assembler.rebuildCount, 2)
        XCTAssertEqual(assembler.lastRebuildChanges.stops, 0)
        XCTAssertEqual(assembler.lastRebuildChanges.trips, 0)

        // The narrow rebuild sees the same trip and leaves it alone too.
        await assembler.reconcile(.recentTrip(since: tripStart))
        XCTAssertEqual(assembler.lastRebuildChanges.stops, 0)
        XCTAssertEqual(assembler.lastRebuildChanges.trips, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<MoveSegment>()), 1)
    }

    // MARK: Rebuild scope

    func testTheTripRebuildReadsFromBeforeTheTripOnlyWhenEverythingOlderIsRebuilt() {
        let now = start
        // Settled and rebuilt the week ten minutes before the trip began.
        XCTAssertEqual(
            CapturePolicy.tripRebuildScope(movingSince: now.addingTimeInterval(-20 * 60), lastFullRebuildAt: now.addingTimeInterval(-30 * 60), now: now),
            .recentTrip(since: now.addingTimeInterval(-30 * 60))
        )
        // Foreground rebuilt the week mid-trip: the trip is still read from its start.
        XCTAssertEqual(
            CapturePolicy.tripRebuildScope(movingSince: now.addingTimeInterval(-20 * 60), lastFullRebuildAt: now.addingTimeInterval(-5 * 60), now: now),
            .recentTrip(since: now.addingTimeInterval(-20 * 60))
        )
        // Relaunched mid-trip: nothing rebuilt yet this process.
        XCTAssertEqual(CapturePolicy.tripRebuildScope(movingSince: now, lastFullRebuildAt: nil, now: now), .week)
        // A long day since the last full rebuild.
        XCTAssertEqual(
            CapturePolicy.tripRebuildScope(movingSince: now.addingTimeInterval(-3_600), lastFullRebuildAt: now.addingTimeInterval(-7 * 3_600), now: now),
            .week
        )
        // Clock set back below the last rebuild.
        XCTAssertEqual(CapturePolicy.tripRebuildScope(movingSince: nil, lastFullRebuildAt: now.addingTimeInterval(60), now: now), .week)
    }

    func testRebuildScopesMergeToTheWiderOne() {
        let early = CaptureRebuildScope.recentTrip(since: start)
        let late = CaptureRebuildScope.recentTrip(since: start.addingTimeInterval(600))
        XCTAssertEqual(early.merged(with: late), early)
        XCTAssertEqual(late.merged(with: .week), .week)
        XCTAssertTrue(CaptureRebuildScope.week.covers(early))
        XCTAssertTrue(early.covers(late))
        XCTAssertFalse(late.covers(early))
        XCTAssertFalse(early.covers(.week))
    }

    // MARK: Departure circle

    func testOneDepartureCircleOnlyWhenSettledWithAlwaysAndPreciseLocation() {
        let point = CaptureAnchor(latitude: origin.latitude, longitude: origin.longitude, horizontalAccuracy: 15)
        func region(
            follows: Bool = true,
            phase: CaptureStateMachine.Phase = .settled,
            anchor: CaptureAnchor? = point,
            always: Bool = true,
            precise: Bool = true,
            maximum: CLLocationDistance = 1_000
        ) -> CLLocationDistance? {
            CapturePolicy.departureRegion(
                followsTrips: follows, phase: phase, anchor: anchor,
                isAlwaysAuthorized: always, hasFullAccuracy: precise,
                maximumMonitoringDistance: maximum
            )?.radius
        }

        XCTAssertEqual(region(), 100)
        XCTAssertNil(region(phase: .moving), "Removed while following a trip")
        XCTAssertNil(region(follows: false), "Removed in battery saver or with listening off")
        XCTAssertNil(region(always: false), "When In Use cannot wake the app from a region")
        XCTAssertNil(region(precise: false), "Approximate location cannot monitor regions")
        XCTAssertNil(region(anchor: nil))
        XCTAssertNil(region(anchor: CaptureAnchor(latitude: 10, longitude: 20, horizontalAccuracy: 150)))
        XCTAssertEqual(region(maximum: 60), 60)
        XCTAssertNil(region(maximum: -1), "Monitoring unavailable")
        // A point restored from the circle iOS kept reports accuracy 0.
        XCTAssertEqual(region(anchor: CaptureAnchor(latitude: 10, longitude: 20, horizontalAccuracy: 0)), 100)
    }

    // MARK: Launch paths

    func testLaunchWithAStaleCircleFarAwayStartsFollowingOnTheFirstFix() {
        var machine = settledMachine()
        // The device restarted somewhere else; the circle is from days ago.
        let farAway = fix(metersEast: 40_000, at: start, accuracy: 30)
        XCTAssertEqual(machine.handleFix(farAway, now: start), .startedMoving(.displacement))
    }

    func testBackgroundRelaunchesStartFollowingAndATowerChangeDoesNot() {
        for trigger in [CaptureStateMachine.Trigger.regionExit, .visitDeparture] {
            var machine = settledMachine()
            XCTAssertEqual(machine.handleWake(trigger, location: nil, now: start), .startedMoving(trigger))
        }
        var tower = settledMachine()
        XCTAssertEqual(tower.handleWake(.significantChange, location: fix(metersEast: 400, at: start, accuracy: 1_000), now: start), CaptureStateMachine.Transition.none)
        var drove = settledMachine()
        XCTAssertEqual(drove.handleWake(.significantChange, location: fix(metersEast: 3_000, at: start, accuracy: 1_000), now: start), .startedMoving(.significantChange))
    }

    func testTurningBackOnLooksAgainAndForgetsTheOldPoint() {
        var machine = settledMachine()
        XCTAssertEqual(machine.configure(level: .balanced, isListening: false, now: start), .turnedOff, "Denied, or Precise Location off")
        XCTAssertEqual(machine.configure(level: .balanced, isListening: true, now: start), .startedMoving(.launch))
        XCTAssertNil(machine.departureAnchor, "The old point may be far away now")

        // Settling without a single usable fix registers no circle at all.
        let settled = machine.tick(now: start.addingTimeInterval(4 * 60 + 1))
        XCTAssertEqual(settled, .settled(anchor: nil, verdict: .stillWithoutMotion))
        XCTAssertNil(CapturePolicy.departureRegion(
            followsTrips: true, phase: machine.phase, anchor: machine.departureAnchor,
            isAlwaysAuthorized: true, hasFullAccuracy: true, maximumMonitoringDistance: 1_000
        ))
        // The first settled fix becomes the point.
        XCTAssertEqual(machine.handleFix(fix(metersEast: 0, at: start.addingTimeInterval(300), accuracy: 20), now: start.addingTimeInterval(300)), CaptureStateMachine.Transition.none)
        XCTAssertNotNil(machine.departureAnchor)
    }

    func testRouteTrackingEndingLooksAgainAndMotionDuringItStartsNothing() {
        var machine = settledMachine()
        machine.noteMotion(.automotive)
        XCTAssertEqual(machine.phase, .settled, "Route tracking is in charge")
        XCTAssertEqual(machine.motion, .automotive)
        XCTAssertEqual(machine.restartLooking(now: start), .startedMoving(.launch))
        XCTAssertNil(machine.departureAnchor)

        var off = CaptureStateMachine(level: .batterySaver, isListening: true, departureAnchor: nil, now: start)
        XCTAssertEqual(off.restartLooking(now: start), CaptureStateMachine.Transition.none)
    }

    // MARK: Movement shapes

    func testATrafficJamDoesNotEndADriveUntilTenStillMinutes() {
        var machine = movingMachine(motion: .automotive)
        _ = machine.handleFix(fix(metersEast: 0, at: start, accuracy: 5, speed: 0), now: start)
        for minute in 1...9 {
            let now = start.addingTimeInterval(TimeInterval(minute * 60))
            _ = machine.handleFix(fix(metersEast: Double(minute % 3) * 5, at: now, accuracy: 5, speed: 0.3), now: now)
            XCTAssertEqual(machine.tick(now: now), CaptureStateMachine.Transition.none, "minute \(minute)")
        }
        guard case .settled(_, .stillTooLong) = machine.tick(now: start.addingTimeInterval(10 * 60)) else {
            return XCTFail("Ten minutes without moving 35 m ends it")
        }
    }

    func testATrainWithStationaryMotionKeepsFollowingWhileFixesMove() {
        var machine = movingMachine(motion: .stationary)
        for step in 0..<60 {
            let now = start.addingTimeInterval(TimeInterval(step * 10))
            _ = machine.handleFix(fix(metersEast: Double(step) * 250, at: now, accuracy: 40, speed: 25), now: now)
            XCTAssertEqual(machine.tick(now: now), CaptureStateMachine.Transition.none)
        }
        XCTAssertEqual(CapturePolicy.profile(motion: .stationary, recentSpeed: 25), .vehicle)
    }

    func testATunnelSettlesAfterFourSilentMinutesAndTheExitStartsAgain() {
        var machine = movingMachine(motion: .unknown)
        let entered = start
        _ = machine.handleFix(fix(metersEast: 0, at: entered, accuracy: 10, speed: 15), now: entered)
        XCTAssertEqual(machine.tick(now: entered.addingTimeInterval(3 * 60)), CaptureStateMachine.Transition.none)
        guard case .settled = machine.tick(now: entered.addingTimeInterval(4 * 60)) else {
            return XCTFail("No fixes and no motion reads as standing still")
        }
        // Out of the tunnel kilometres on, the coarse settled session sees it at once.
        let out = entered.addingTimeInterval(12 * 60)
        XCTAssertEqual(machine.handleFix(fix(metersEast: 6_000, at: out, accuracy: 30, speed: 15), now: out), .startedMoving(.displacement))
        // A stop is not invented: the fixes before and after are 6 km and 12 min apart.
        let gapSpeed = 6_000.0 / (12 * 60)
        XCTAssertGreaterThan(gapSpeed, SampleStayInference.Configuration().maximumStillSpeed)
    }

    func testAFlightLandingThousandsOfKilometresAwayStartsAFreshSession() {
        var machine = settledMachine()
        let landed = start.addingTimeInterval(9 * 3_600)
        let wake = fix(metersEast: 4_000_000, at: landed, accuracy: 800)
        XCTAssertEqual(machine.handleWake(.significantChange, location: wake, now: landed), .startedMoving(.significantChange))

        var filter = CaptureFixFilter()
        filter.beginSession(at: landed)
        let cachedFromDeparture = fix(metersEast: 0, at: start, accuracy: 10)
        let first = fix(metersEast: 4_000_010, at: landed.addingTimeInterval(3), accuracy: 10, speed: 2)
        XCTAssertEqual(filter.accept([cachedFromDeparture, first], minimumInterval: 4), [first])
        XCTAssertEqual(filter.dropCounts[.stale], 1)
    }

    func testWanderingABuildingForTenMinutesSettlesEvenWhileMotionSaysWalking() {
        var machine = movingMachine(motion: .walking)
        var time = start
        for step in 0..<66 {
            time = start.addingTimeInterval(TimeInterval(step * 9))
            // Back and forth along an 80 m corridor.
            let east = Double((step * 13) % 80)
            XCTAssertEqual(machine.handleFix(fix(metersEast: east, at: time, accuracy: 15, speed: 1.2), now: time), CaptureStateMachine.Transition.none)
        }
        guard case .settled(_, .wanderedInPlace) = machine.tick(now: start.addingTimeInterval(10 * 60 + 1)) else {
            return XCTFail("An hour inside a building is a stay, not an hour of GPS")
        }
        XCTAssertEqual(machine.handleMotion(.walking, now: start.addingTimeInterval(11 * 60)), CaptureStateMachine.Transition.none, "Still walking the corridor")
        XCTAssertEqual(machine.handleWake(.regionExit, location: nil, now: start.addingTimeInterval(12 * 60)), .startedMoving(.regionExit), "Leaving the building")
    }

    func testAWalkNeverSettlesOnTheWanderRule() {
        var machine = movingMachine(motion: .walking)
        for step in 0..<200 {
            let now = start.addingTimeInterval(TimeInterval(step * 7))
            _ = machine.handleFix(fix(metersEast: Double(step) * 10, at: now, accuracy: 8, speed: 1.4), now: now)
            XCTAssertEqual(machine.tick(now: now), CaptureStateMachine.Transition.none)
        }
    }

    func testPacingAtHomeAllDayBacksOffMotionTriggers() {
        var machine = settledMachine()
        var now = start
        var cooldowns: [TimeInterval] = []
        for _ in 0..<5 {
            XCTAssertEqual(machine.handleMotion(.walking, now: now), .startedMoving(.motionActivity))
            now = now.addingTimeInterval(2 * 60)
            guard case .settled(_, .falseStart) = machine.tick(now: now) else { return XCTFail("Expected a false start") }
            let until = machine.motionTriggersSuppressedUntil ?? now
            cooldowns.append(until.timeIntervalSince(now))
            XCTAssertEqual(machine.handleMotion(.walking, now: until.addingTimeInterval(-1)), CaptureStateMachine.Transition.none)
            now = until
        }
        let minutes: [TimeInterval] = [5, 10, 20, 30, 30]
        XCTAssertEqual(cooldowns, minutes.map { $0 * 60 })

        // A departure the location system saw ends the run of false alarms.
        _ = machine.handleWake(.regionExit, location: nil, now: now)
        XCTAssertEqual(machine.motionFalseAlarms, 0)
        XCTAssertNil(machine.motionTriggersSuppressedUntil)
    }

    func testLeavingWithinTwoMinutesOfArrivingIsOneTrip() {
        var machine = movingMachine(motion: .walking)
        _ = machine.handleFix(fix(metersEast: 0, at: start, accuracy: 8, speed: 0), now: start)
        _ = machine.handleMotion(.stationary, now: start.addingTimeInterval(10))
        XCTAssertEqual(machine.tick(now: start.addingTimeInterval(110)), CaptureStateMachine.Transition.none)
        _ = machine.handleMotion(.walking, now: start.addingTimeInterval(115))
        XCTAssertEqual(machine.handleFix(fix(metersEast: 60, at: start.addingTimeInterval(150), accuracy: 8, speed: 1.4), now: start.addingTimeInterval(150)), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.phase, .moving)
    }

    func testAThreeMinuteStopBetweenTwoTripsDoesNotSettle() {
        var machine = movingMachine(motion: .automotive)
        _ = machine.handleFix(fix(metersEast: 0, at: start, accuracy: 5, speed: 0), now: start)
        _ = machine.handleMotion(.stationary, now: start.addingTimeInterval(20))
        XCTAssertEqual(machine.tick(now: start.addingTimeInterval(3 * 60)), CaptureStateMachine.Transition.none)
        let off = start.addingTimeInterval(3 * 60 + 10)
        XCTAssertEqual(machine.handleFix(fix(metersEast: 80, at: off, accuracy: 5, speed: 8), now: off), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.phase, .moving)
        // The rules record a stop from ten minutes, so three minutes is never one.
        XCTAssertGreaterThan(SampleStayInference.Configuration().minimumStayDuration, 3 * 60)
    }

    func testDriftWhileSettledNeedsDistanceBeyondTwiceTheAccuracy() {
        var coarse = settledMachine()
        XCTAssertEqual(coarse.handleFix(fix(metersEast: 150, at: start, accuracy: 80), now: start), CaptureStateMachine.Transition.none)
        var tooCoarse = settledMachine()
        XCTAssertEqual(tooCoarse.handleFix(fix(metersEast: 900, at: start, accuracy: 250), now: start), CaptureStateMachine.Transition.none)
        var sharp = settledMachine()
        XCTAssertEqual(sharp.handleFix(fix(metersEast: 130, at: start, accuracy: 30), now: start), .startedMoving(.displacement))
    }

    // MARK: Time

    func testAClockSetBackDoesNotFreezeTimersOrDropEveryFix() {
        var throttle = ReconcileThrottle()
        XCTAssertTrue(throttle.shouldRun(at: start))
        XCTAssertTrue(throttle.shouldRun(at: start.addingTimeInterval(-3_600)), "Not an hour of waiting")

        var detector = CaptureSettleDetector()
        detector.reset(at: start)
        XCTAssertNil(detector.verdict(now: start.addingTimeInterval(-3_600), motion: .stationary, startedByMotion: false))

        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        let before = fix(metersEast: 0, at: start.addingTimeInterval(5), accuracy: 5, speed: 10)
        XCTAssertEqual(filter.accept([before], minimumInterval: 4), [before])
        let backAnHour = start.addingTimeInterval(-3_600)
        let afterChange = fix(metersEast: 100, at: backAnHour.addingTimeInterval(5), accuracy: 5, speed: 10)
        XCTAssertEqual(filter.evaluate(afterChange, minimumInterval: 4), .stale)
        filter.restartClock(at: backAnHour)
        XCTAssertEqual(filter.accept([afterChange], minimumInterval: 4), [afterChange])
        XCTAssertEqual(filter.acceptedCount, 2, "Counts survive for the session log")

        var machine = movingMachine(motion: .walking)
        _ = machine.handleFix(fix(metersEast: 0, at: start, accuracy: 5), now: start)
        machine.clockDidChange(now: backAnHour)
        XCTAssertLessThanOrEqual(machine.movingSince ?? .distantFuture, backAnHour)
        XCTAssertEqual(machine.detector.stillSince, backAnHour)
    }

    func testDuplicateAndLateTimestampsAreDropped() {
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        let first = fix(metersEast: 0, at: start.addingTimeInterval(1), accuracy: 5, speed: 2)
        let duplicate = fix(metersEast: 20, at: start.addingTimeInterval(1), accuracy: 5, speed: 2)
        let late = fix(metersEast: 30, at: start.addingTimeInterval(-30), accuracy: 5, speed: 2)
        XCTAssertEqual(filter.accept([first, duplicate, late], minimumInterval: 0), [first])
        XCTAssertEqual(filter.dropCounts[.outOfOrder], 1)
        XCTAssertEqual(filter.dropCounts[.stale], 1)
    }

    // MARK: Switching

    func testChangingTheLevelMidTripKeepsFollowingOrHandsBack() {
        var machine = movingMachine(motion: .walking)
        XCTAssertEqual(machine.configure(level: .detailed, isListening: true, now: start), CaptureStateMachine.Transition.none)
        XCTAssertEqual(machine.phase, .moving)
        XCTAssertEqual(machine.configure(level: .batterySaver, isListening: true, now: start), .turnedOff)
        XCTAssertEqual(machine.configure(level: .balanced, isListening: true, now: start), .startedMoving(.launch))
        XCTAssertEqual(machine.configure(level: .balanced, isListening: false, now: start), .turnedOff)
        XCTAssertEqual(machine.configure(level: .balanced, isListening: true, now: start), .startedMoving(.launch))
    }

    func testLowPowerModeMidTripStepsBalancedDownButNotDetailed() {
        let lowPower = CaptureEnergyState(isLowPowerModeEnabled: true, batteryLevel: 0.8, isCharging: false)
        let lowBattery = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: 0.19, isCharging: false)
        let recovered = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: 0.21, isCharging: false)
        let charging = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: 0.19, isCharging: true)
        func filter(_ level: CaptureDetailLevel, _ energy: CaptureEnergyState) -> CLLocationDistance {
            CapturePolicy.configuration(level: level, phase: .moving, motion: .automotive, recentSpeed: 20, energy: energy, isRouteTrackingActive: false).distanceFilter
        }
        XCTAssertEqual(filter(.balanced, .unconstrained), 30)
        XCTAssertEqual(filter(.balanced, lowPower), 80)
        XCTAssertEqual(filter(.balanced, lowBattery), 80)
        XCTAssertEqual(filter(.balanced, recovered), 30)
        XCTAssertEqual(filter(.balanced, charging), 30)
        XCTAssertEqual(filter(.detailed, lowPower), 15, "Detailed chosen in Low Power Mode is honoured")
    }

    // MARK: Storage

    func testStraightDrivingIsThinnedAndTurnsAreKept() {
        let straight = simulateDrive(level: .balanced, speed: 25, duration: 10 * 60, turnEvery: nil)
        let straightIntervals = intervals(straight)
        XCTAssertGreaterThanOrEqual(straightIntervals.min() ?? 0, 15)
        XCTAssertLessThan(straight.count, 50, "A straight 10 km is 40 fixes, not 120")

        // A road turning 90° every 400 m keeps fixes at each turn.
        let city = simulateDrive(level: .balanced, speed: 12, duration: 10 * 60, turnEvery: 400)
        let turns = zip(city, city.dropFirst()).filter {
            CaptureFixFilter.headingChange(from: $0.course, to: $1.course) >= 45
        }
        XCTAssertGreaterThanOrEqual(turns.count, 15, "Every turn has a fix after it")

        let detailed = simulateDrive(level: .detailed, speed: 25, duration: 10 * 60, turnEvery: nil)
        XCTAssertGreaterThan(detailed.count, 150, "Detailed is never thinned")
        XCTAssertEqual(CaptureFixFilter.headingChange(from: 350, to: 10), 20)
        XCTAssertEqual(CaptureFixFilter.headingChange(from: 10, to: 350), 20)
    }

    /// The storage estimate in the capture report, from the policy numbers.
    func testDailyFixCountsStayWithinBudget() {
        func hourOf(_ level: CaptureDetailLevel, walking: Bool) -> Int {
            walking
                ? simulateWalk(level: level, duration: 3_600).count
                : simulateDrive(level: level, speed: 14, duration: 3_600, turnEvery: 600).count
        }
        var report: [String] = []
        for level in [CaptureDetailLevel.balanced, .detailed] {
            let walk = hourOf(level, walking: true)
            let drive = hourOf(level, walking: false)
            let typical = walk + drive
            let heavy = walk / 2 + 4 * drive
            report.append("\(level.rawValue): walk \(walk)/h, drive \(drive)/h, typical \(typical), heavy \(heavy)")
            if level == .balanced {
                XCTAssertLessThan(heavy, 3_000, "A heavy Balanced day stays under 3,000 fixes")
            }
        }
        print("Capture storage estimate: " + report.joined(separator: "; "))
    }

    // MARK: Rebuild cost on a real store copy

    /// Times a full-week rebuild against the trip rebuild on a copy of a real store, with
    /// synthetic dense days added. Set `TEST_RUNNER_MOVES_CAPTURE_REAL_STORE` to a copied
    /// `default.store`. Writes counts and timings only, beside the copy.
    func testRebuildCostWithDenseDaysOnARealStoreCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOVES_CAPTURE_REAL_STORE"],
              FileManager.default.fileExists(atPath: path)
        else { throw XCTSkip("No real store copy given") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureDense-\(UUID().uuidString)", isDirectory: true)
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
        let repository = SwiftDataTimelineRepository(modelContext: ModelContext(container))
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: UnknownMotion(),
            placeNameResolver: NoNames()
        )

        func time(_ scope: CaptureRebuildScope, runs: Int = 3) async -> [Int] {
            var timings: [Int] = []
            for _ in 0..<runs {
                let began = Date()
                await assembler.reconcile(scope)
                timings.append(Int(Date().timeIntervalSince(began) * 1_000))
            }
            return timings
        }

        var lines: [String] = []
        let now = Date()
        // A trip in progress: the last 40 minutes, since a week rebuild an hour ago.
        let tripScope = CaptureRebuildScope.recentTrip(since: now.addingTimeInterval(-40 * 60))
        let realSamples = try ModelContext(container).fetchCount(FetchDescriptor<LocationSample>())
        _ = await time(.week, runs: 1)
        lines.append("real store (\(realSamples) fixes): week \(await time(.week)) ms, trip \(await time(tripScope)) ms")

        var added = 0
        for day in 0..<7 {
            let dayFixes = denseDay(endingAt: now.addingTimeInterval(TimeInterval(-day) * 86_400 - 5 * 60))
            _ = try repository.appendSamples(from: dayFixes, source: .continuous)
            try repository.saveIfNeeded()
            added += dayFixes.count
            if day == 0 || day == 6 {
                _ = await time(.week, runs: 1)
                lines.append("+\(day + 1) dense day(s) (\(added) synthetic fixes, \(dayFixes.count)/day): week \(await time(.week)) ms, trip \(await time(tripScope)) ms")
            }
        }
        let report = "Rebuild cost: " + lines.joined(separator: "; ")
        print(report)
        try? report.write(toFile: path + ".capture-dense-timing.txt", atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private func settledMachine() -> CaptureStateMachine {
        CaptureStateMachine(
            level: .balanced,
            isListening: true,
            departureAnchor: CaptureAnchor(latitude: origin.latitude, longitude: origin.longitude, horizontalAccuracy: 15),
            now: start.addingTimeInterval(-3_600)
        )
    }

    /// Following a trip that a region exit started at `start`.
    private func movingMachine(motion: CaptureMotionState) -> CaptureStateMachine {
        var machine = settledMachine()
        _ = machine.handleWake(.regionExit, location: nil, now: start)
        machine.noteMotion(motion)
        return machine
    }

    private func fix(
        metersEast: Double,
        metersNorth: Double = 0,
        at timestamp: Date,
        accuracy: CLLocationAccuracy,
        speed: CLLocationSpeed = -1,
        course: CLLocationDirection = 90
    ) -> CLLocation {
        let metersPerDegreeLongitude = 111_320 * cos(origin.latitude * .pi / 180)
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: origin.latitude + metersNorth / 111_320,
                longitude: origin.longitude + metersEast / metersPerDegreeLongitude
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }

    /// One fix a minute standing still `metersEast` of the origin.
    private func stayFixes(at metersEast: Double, from begin: Date, minutes: Int) -> [CLLocation] {
        (0..<minutes).map { minute in
            fix(metersEast: metersEast + Double(minute % 3), at: begin.addingTimeInterval(TimeInterval(minute * 60)), accuracy: 10, speed: 0)
        }
    }

    /// CoreLocation's distance filter over a drive, then the quality filter. With
    /// `turnEvery`, the road turns 90° left and right alternately every that many metres.
    private func simulateDrive(level: CaptureDetailLevel, speed: CLLocationSpeed, duration: TimeInterval, turnEvery: CLLocationDistance?) -> [CLLocation] {
        let config = CapturePolicy.configuration(level: level, phase: .moving, motion: .automotive, recentSpeed: speed, energy: .unconstrained, isRouteTrackingActive: false)
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        var east = 0.0, north = 0.0, heading = 90.0, sinceTurn = 0.0, travelled = 0.0, lastDelivered = -Double.infinity
        var turnLeft = true
        var delivered: [CLLocation] = []
        for second in 0..<Int(duration) {
            east += sin(heading * .pi / 180) * speed
            north += cos(heading * .pi / 180) * speed
            travelled += speed
            sinceTurn += speed
            if let turnEvery, sinceTurn >= turnEvery {
                heading = (heading + (turnLeft ? -90 : 90) + 360).truncatingRemainder(dividingBy: 360)
                turnLeft.toggle()
                sinceTurn = 0
            }
            guard travelled - lastDelivered >= config.distanceFilter else { continue }
            lastDelivered = travelled
            delivered.append(fix(metersEast: east, metersNorth: north, at: start.addingTimeInterval(TimeInterval(second)), accuracy: 5, speed: speed, course: heading))
        }
        return filter.accept(delivered, minimumInterval: config.minimumInterval, straightSegmentInterval: config.straightSegmentInterval)
    }

    private func simulateWalk(level: CaptureDetailLevel, duration: TimeInterval) -> [CLLocation] {
        let config = CapturePolicy.configuration(level: level, phase: .moving, motion: .walking, recentSpeed: 1.4, energy: .unconstrained, isRouteTrackingActive: false)
        var filter = CaptureFixFilter()
        filter.beginSession(at: start)
        var delivered: [CLLocation] = []
        var lastDelivered = -Double.infinity
        for second in 0..<Int(duration) {
            let position = Double(second) * 1.4
            guard position - lastDelivered >= config.distanceFilter else { continue }
            lastDelivered = position
            delivered.append(fix(metersEast: position, at: start.addingTimeInterval(TimeInterval(second)), accuracy: 8, speed: 1.4))
        }
        return filter.accept(delivered, minimumInterval: config.minimumInterval, straightSegmentInterval: config.straightSegmentInterval)
    }

    private func intervals(_ fixes: [CLLocation]) -> [TimeInterval] {
        zip(fixes, fixes.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
    }

    /// A synthetic busy day ending at `end`: stays, two hours on foot, two hours driving,
    /// a fix every 4–5 s while moving. Well over 3,000 fixes.
    private func denseDay(endingAt end: Date) -> [CLLocation] {
        let dayStart = end.addingTimeInterval(-16 * 3_600)
        var fixes: [CLLocation] = []
        var time = dayStart
        var east = 0.0
        func stay(minutes: Int) {
            for minute in stride(from: 0, to: minutes, by: 10) {
                fixes.append(fix(metersEast: east, at: time.addingTimeInterval(TimeInterval(minute * 60)), accuracy: 15, speed: 0))
            }
            time = time.addingTimeInterval(TimeInterval(minutes * 60))
        }
        func move(minutes: Int, speed: Double, every seconds: Int) {
            for second in stride(from: 0, to: minutes * 60, by: seconds) {
                east += speed * Double(seconds)
                fixes.append(fix(metersEast: east, at: time.addingTimeInterval(TimeInterval(second)), accuracy: 6, speed: speed))
            }
            time = time.addingTimeInterval(TimeInterval(minutes * 60))
        }
        stay(minutes: 180)
        move(minutes: 60, speed: 1.4, every: 4)
        stay(minutes: 120)
        move(minutes: 60, speed: 14, every: 5)
        stay(minutes: 240)
        move(minutes: 60, speed: 14, every: 5)
        stay(minutes: 60)
        move(minutes: 60, speed: 1.4, every: 4)
        stay(minutes: max(0, Int(end.timeIntervalSince(time) / 60)))
        return fixes.filter { $0.timestamp <= end }
    }

    private func makeAssembler(resolver: PlaceNameResolver) throws -> (DefaultTimelineAssembler, ModelContainer) {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let assembler = DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContainer: container),
            motionClassifier: UnknownMotion(),
            placeNameResolver: resolver
        )
        return (assembler, container)
    }
}

// MARK: - Fakes

@MainActor
private final class RecordingAssembler: TimelineAssembler {
    var events: [String] = []
    var immediateWrites = 0
    var rebuildDelay: Duration = .milliseconds(5)
    var visitDelay: Duration = .milliseconds(20)

    func ingestVisit(_ visit: CLVisit) async {
        try? await Task.sleep(for: visitDelay)
        events.append("visit")
    }

    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource, reconcile: Bool) async {
        try? await Task.sleep(for: .milliseconds(30))
        events.append("store \(locations.count) \(source.rawValue)")
    }

    func storeImmediately(_ locations: [CLLocation], source: LocationSampleSource) {
        immediateWrites += locations.count
    }

    func reconcile(_ scope: CaptureRebuildScope) async {
        try? await Task.sleep(for: rebuildDelay)
        switch scope {
        case .week: events.append("rebuild week")
        case .recentTrip: events.append("rebuild trip")
        }
    }

    func approachWasAutomotive(before date: Date) async -> Bool { false }
    func recentlyWalking(at date: Date) async -> Bool { false }
}

private struct UnknownMotion: MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (.unknown, 0)
    }

    func stepCount(start: Date, end: Date) async -> Int? { nil }
}

private struct NoNames: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? { nil }
}

/// Holds the first name lookup until the test lets it go, so a rebuild can be caught mid-pass.
private actor ResolverGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard !entered else { return }
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct GatedResolver: PlaceNameResolver {
    let gate: ResolverGate

    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        await gate.enter()
        return nil
    }
}
