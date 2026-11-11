import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class AutomaticTransportModesTests: XCTestCase {
    func testCityNoiseAndOneSpeedSpikeDoNotTurnAWalkIntoAFlightOrRide() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        var points = (0..<9).map { index in
            CLLocation(coordinate: .init(latitude: 10, longitude: 106 + Double(index) * 28 / 109_628),
                       altitude: 0, horizontalAccuracy: 15, verticalAccuracy: 10, course: 90,
                       speed: index == 4 ? 95 : 1.4, timestamp: start.addingTimeInterval(Double(index) * 20))
        }
        points.insert(CLLocation(coordinate: .init(latitude: 10.02, longitude: 106.02), altitude: 0,
                                 horizontalAccuracy: 1_000, verticalAccuracy: -1, course: -1, speed: 100,
                                 timestamp: start.addingTimeInterval(60.2)), at: 4)
        let evidence = TransportSpeedEvidence(locations: points)
        XCTAssertEqual(evidence.inferredMode, .walking)
        XCTAssertFalse(evidence.supportsSpeed(above: 3.5, tripDuration: 160))
        XCTAssertEqual(ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 2_000,
                                                 duration: 160, stepCount: 20, locations: points), .walking)
    }

    func testShortFixClustersAndLongGapsDoNotPretendToBeSustainedTravel() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let points = [0.0, 0.2, 1.0, 1_200.0, 1_201.0].enumerated().map { index, seconds in
            CLLocation(coordinate: .init(latitude: 10, longitude: 106 + Double(index) * 0.001),
                       altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, course: -1, speed: 30,
                       timestamp: start.addingTimeInterval(seconds))
        }
        let evidence = TransportSpeedEvidence(locations: points)
        XCTAssertEqual(evidence.inferredMode, .unknown)
        XCTAssertFalse(evidence.hasSustainedCoverage)
        XCTAssertFalse(evidence.supportsSpeed(above: 3.5, tripDuration: 1_201))
    }

    func testAccuracyBoundsProtectWalkingAndClearVehicleEvidenceStillCorrectsIt() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let noisy = (0..<3).map { index in
            CLLocation(coordinate: .init(latitude: 10, longitude: 106 + Double(index) * 420 / 109_628),
                       altitude: 0, horizontalAccuracy: 200, verticalAccuracy: -1, course: -1, speed: -1,
                       timestamp: start.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(TransportSpeedEvidence(locations: noisy).inferredMode, .unknown)
        XCTAssertEqual(ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 840,
                                                 duration: 120, stepCount: 5, locations: noisy), .walking)
        XCTAssertEqual(ImplausibleWalk.refinedMode(proposed: .walking, straightLine: 1_440,
                                                 duration: 120, stepCount: 5, locations: locations(speed: 12)), .automotive)
        XCTAssertEqual(TransportSpeedEvidence(locations: locations(speed: 6)).inferredMode, .unknown,
                       "Cycling pace also fits traffic; speed does not identify the vehicle.")
    }

    func testDenseWalkingFixesUseLongEnoughBaselinesToOutweighGPSUncertainty() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let dense = (0...180).map { second in
            CLLocation(coordinate: .init(latitude: 10, longitude: 106 + Double(second) * 1.4 / 109_628),
                       altitude: 0, horizontalAccuracy: 15, verticalAccuracy: -1, course: -1, speed: -1,
                       timestamp: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(TransportSpeedEvidence(locations: dense).inferredMode, .walking)
        let sparse = stride(from: 0, through: 180, by: 60).map { dense[$0] }
        XCTAssertEqual(TransportSpeedEvidence(locations: sparse).inferredMode, .walking,
                       "Changing sampling frequency alone should not change a clean walk's mode.")
    }

    func testPreferencesPersistAndEveryTravelModeCanBeDisabledWithoutBlockingManualChoices() throws {
        let name = "AutomaticTransportModesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(AutomaticTransportModes.load(from: defaults).disabled.isEmpty)
        let disabled = AutomaticTransportModes(disabled: Set(AutomaticTransportModes.choices))
        defaults.set(disabled.rawValue, forKey: AutomaticTransportModes.storageKey)
        let restored = AutomaticTransportModes.load(from: defaults)
        XCTAssertEqual(restored, disabled)
        for mode in AutomaticTransportModes.choices {
            XCTAssertEqual(restored.allowedMode(mode), .unknown)
            XCTAssertTrue(TransportMode.correctionChoices.contains(mode))
        }
        XCTAssertTrue(restored.allows(.stationary))
        XCTAssertTrue(restored.allows(.unknown))
        XCTAssertEqual(AutomaticTransportModes(rawValue: "cycling,bogus,unknown,stationary").disabled, [.cycling])
    }

    func testRejectedMotionNeedsIndependentEvidenceAndSpeedFallbackRespectsAllDisabledModes() async throws {
        let preferences = AutomaticTransportModes(disabled: [.cycling])
        let cycling = locations(speed: 6)
        XCTAssertEqual(preferences.restrict(mode: .cycling, confidence: 0.95, locations: cycling).mode, .unknown)
        let driving = locations(speed: 12)
        let replacement = preferences.restrict(mode: .cycling, confidence: 0.95, locations: driving)
        XCTAssertEqual(replacement.mode, .automotive)
        XCTAssertLessThan(replacement.confidence, TimelineReviewHeuristics.uncertainModeConfidence)
        XCTAssertEqual(AutomaticTransportModes(disabled: [.cycling, .automotive])
            .restrict(mode: .cycling, confidence: 0.95, locations: driving).mode, .unknown)
        let name = "AutomaticTransportModesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let classifier = CoreMotionTransportClassifier(defaults: defaults)
        defaults.set(preferences.rawValue, forKey: AutomaticTransportModes.storageKey)
        let result = await classifier.classifyTransport(start: cycling[0].timestamp, end: cycling[2].timestamp, locations: cycling)
        XCTAssertEqual(result.mode, .unknown)
        defaults.set("automotive", forKey: AutomaticTransportModes.storageKey)
        let blockedDrive = await classifier.classifyTransport(start: driving[0].timestamp, end: driving[2].timestamp, locations: driving)
        XCTAssertEqual(blockedDrive.mode, .unknown)
        defaults.set("", forKey: AutomaticTransportModes.storageKey)
        let enabled = await classifier.classifyTransport(start: driving[0].timestamp, end: driving[2].timestamp, locations: driving)
        XCTAssertEqual(enabled.mode, .automotive, "The existing classifier reads changed preferences without relaunching.")
        XCTAssertEqual(AutomaticTransportModes().restrict(mode: .cycling, confidence: 0.9, locations: cycling).mode, .cycling,
                       "Enabling cycling still permits a cycling motion reading.")
    }

    func testCleanupUsesStoredEvidenceAndPreservesHistoryAndCuratedModes() throws {
        let context = try makeContext()
        let history = makeHistory()
        defer { try? FileManager.default.removeItem(at: history.undoURL.deletingLastPathComponent()) }
        let driving = insertMove(in: context, speed: 12)
        let ambiguous = insertMove(in: context, speed: 6)
        let noEvidence = insertMove(in: context)
        let protected = (0..<8).map { _ in insertMove(in: context, speed: 12) }
        protected[0].transportModeSource = .user
        protected[1].transportModeSource = .imported
        protected[2].reviewState = .confirmed
        protected[3].reviewState = .dismissed
        protected[4].origin = .imported
        protected[5].comment = "My cycling tour"
        protected[6].routeMatchPolicy = .manual
        protected[7].samples.first?.source = .healthWorkoutRoute
        let enabledMode = insertMove(in: context, speed: 12)
        enabledMode.transportMode = .walking
        driving.routeCacheSignature = "old-cycling-path"
        driving.speedProfileData = Data([1, 2, 3])
        let originalTimes = [driving.startDate, driving.endDate]
        let originalDistance = driving.distanceMeters
        try context.save()
        let rowCount = try context.fetchCount(FetchDescriptor<MoveSegment>())
        let pointCount = try context.fetchCount(FetchDescriptor<LocationSample>())
        let preferences = AutomaticTransportModes(disabled: [.cycling])
        XCTAssertEqual(try history.candidates(in: context, preferences: preferences).count, 3)
        XCTAssertEqual(ambiguous.transportMode, .cycling, "Changing a preference alone must not rewrite history.")
        let report = try history.recheck(in: context, preferences: preferences)
        XCTAssertEqual(report.changed, 3)
        XCTAssertEqual(report.unknown, 2)
        XCTAssertEqual(driving.transportMode, .automotive)
        XCTAssertEqual(ambiguous.transportMode, .unknown)
        XCTAssertEqual(noEvidence.transportMode, .unknown)
        XCTAssertTrue(protected.allSatisfy { $0.transportMode == .cycling })
        XCTAssertEqual(enabledMode.transportMode, .walking)
        XCTAssertEqual(driving.transportModeSource, .auto)
        XCTAssertEqual(driving.reviewState, .pending)
        XCTAssertNil(driving.routeCacheSignature)
        XCTAssertNil(driving.speedProfileData)
        XCTAssertEqual([driving.startDate, driving.endDate], originalTimes)
        XCTAssertEqual(driving.distanceMeters, originalDistance)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MoveSegment>()), rowCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocationSample>()), pointCount)
        XCTAssertEqual(try history.recheck(in: context, preferences: preferences).changed, 0)
        XCTAssertTrue(history.canUndo, "An empty repeat must preserve the previous undo.")
    }

    func testUndoSurvivesReopeningAndPreservesLaterCorrectionsAndDeletions() throws {
        let context = try makeContext()
        let history = makeHistory()
        defer { try? FileManager.default.removeItem(at: history.undoURL.deletingLastPathComponent()) }
        let original = insertMove(in: context, speed: 6)
        let corrected = insertMove(in: context, speed: 6)
        let deleted = insertMove(in: context, speed: 6)
        let reviewed = insertMove(in: context, speed: 6)
        _ = try history.recheck(in: context, preferences: .init(disabled: [.cycling]))
        corrected.transportMode = .walking
        corrected.transportModeSource = .user
        reviewed.reviewState = .confirmed
        context.delete(deleted)
        try context.save()
        let reopened = AutomaticModeHistory(undoURL: history.undoURL)
        XCTAssertTrue(reopened.canUndo)
        XCTAssertEqual(try reopened.undo(in: context), 1)
        XCTAssertEqual(original.transportMode, .cycling)
        XCTAssertEqual(original.reviewState, .none)
        XCTAssertEqual(corrected.transportMode, .walking)
        XCTAssertEqual(corrected.transportModeSource, .user)
        XCTAssertEqual(reviewed.transportMode, .unknown)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MoveSegment>()), 3)
        XCTAssertFalse(reopened.canUndo)
    }

    /// CloudKit mirroring cannot enforce unique IDs. A duplicated trip must not
    /// trap Undo, and each copy is restored.
    func testUndoToleratesDuplicatedTripIDs() throws {
        let context = try makeContext()
        let history = makeHistory()
        defer { try? FileManager.default.removeItem(at: history.undoURL.deletingLastPathComponent()) }
        let first = insertMove(in: context, speed: 6)
        let copy = insertMove(in: context, speed: 6)
        copy.id = first.id
        try context.save()
        _ = try history.recheck(in: context, preferences: .init(disabled: [.cycling]))
        XCTAssertEqual(first.transportMode, .unknown)
        XCTAssertEqual(copy.transportMode, .unknown)
        XCTAssertEqual(try history.undo(in: context), 2)
        XCTAssertEqual(first.transportMode, .cycling)
        XCTAssertEqual(copy.transportMode, .cycling)
        XCTAssertFalse(history.canUndo)
    }

    func testFailedUndoBackupCannotModifyHistory() throws {
        let context = try makeContext()
        let move = insertMove(in: context, speed: 12)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let history = AutomaticModeHistory(undoURL: file.appendingPathComponent("undo.json"))
        XCTAssertThrowsError(try history.recheck(in: context, preferences: .init(disabled: [.cycling])))
        XCTAssertEqual(move.transportMode, .cycling)
        XCTAssertEqual(move.reviewState, .none)
    }

    func testHistoryRecheckCannotChooseAnotherDisabledMode() throws {
        let context = try makeContext()
        let history = makeHistory()
        defer { try? FileManager.default.removeItem(at: history.undoURL.deletingLastPathComponent()) }
        let move = insertMove(in: context, speed: 12)
        _ = try history.recheck(in: context, preferences: .init(disabled: [.cycling, .automotive]))
        XCTAssertEqual(move.transportMode, .unknown)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeHistory() -> AutomaticModeHistory {
        AutomaticModeHistory(undoURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("undo.json"))
    }

    private func locations(speed: Double) -> [CLLocation] {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        return (0..<3).map { index in
            CLLocation(coordinate: .init(latitude: 0, longitude: speed * Double(index) * 60 / 111_320),
                       altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, course: 90,
                       speed: speed, timestamp: start.addingTimeInterval(Double(index) * 60))
        }
    }

    private func insertMove(in context: ModelContext, speed: Double? = nil) -> MoveSegment {
        let points = speed.map(locations(speed:)) ?? []
        let start = points.first?.timestamp ?? Date(timeIntervalSince1970: 1_710_000_000)
        let move = MoveSegment(dedupeKey: UUID().uuidString, startDate: start, endDate: start.addingTimeInterval(120),
                               transportMode: .cycling, distanceMeters: (speed ?? 6) * 120, stepCount: nil)
        context.insert(move)
        for point in points {
            let sample = LocationSample(location: point, source: .routeTracking, dedupeKey: UUID().uuidString)
            context.insert(sample)
            sample.moveSegment = move
        }
        return move
    }
}
