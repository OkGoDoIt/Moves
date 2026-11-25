import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// The Health sync end to end: store snapshot, fake Health, targeted writes, cache.
/// Coordinates are synthetic.
@MainActor
final class HealthTimelineSyncTests: XCTestCase {
    private static let metersPerDegree = 111_195.0
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(MovesTimelineSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    private struct Fixture {
        var dayKey: String
        var sparseWalk: UUID
        var denseWalk: UUID
        var stepFreeWalk: UUID
        var importedWalk: UUID
        var longStay: UUID
        var segments: [FakeHealthActivityReader.Segment]
    }

    /// Two days ago: a sparse 600 m walk, a dense 1 km walk, a 1.8 km "walk" with
    /// almost no steps, an imported walk, and a long stay with some walking in it.
    private func seed(_ context: ModelContext) throws -> Fixture {
        let calendar = Calendar.current
        let dayStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: .now))!
        let day = DayTimeline(dayStart: dayStart)
        context.insert(day)
        var cursor = dayStart.addingTimeInterval(8 * 3_600)
        var longitude = 1.0
        var segments: [FakeHealthActivityReader.Segment] = []

        func place(hours: Double) -> VisitPlace {
            let visit = VisitPlace(arrivalDate: cursor, departureDate: cursor.addingTimeInterval(hours * 3_600),
                                   latitude: 0, longitude: longitude, horizontalAccuracy: 10)
            visit.dayTimeline = day
            context.insert(visit)
            cursor = cursor.addingTimeInterval(hours * 3_600)
            return visit
        }

        func move(meters: Double, minutes: Double, spacing: Double, mode: TransportMode,
                  origin: TimelineItemOrigin = .sensor, stepsPerMinute: Double, metersPerStep: Double,
                  from startPlace: VisitPlace) -> (MoveSegment, VisitPlace) {
            let start = cursor
            let end = start.addingTimeInterval(minutes * 60)
            let segment = MoveSegment(dedupeKey: UUID().uuidString, startDate: start, endDate: end,
                                      transportMode: mode, distanceMeters: meters, stepCount: nil)
            segment.origin = origin
            if origin == .imported { segment.transportModeSource = .imported }
            segment.dayTimeline = day
            segment.startPlace = startPlace
            context.insert(segment)
            let count = max(Int(meters / spacing), 1)
            for index in 0...count {
                let fraction = Double(index) / Double(count)
                let location = CLLocation(
                    coordinate: .init(latitude: 0, longitude: longitude + fraction * meters / Self.metersPerDegree),
                    altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, course: -1, speed: -1,
                    timestamp: start.addingTimeInterval(fraction * minutes * 60)
                )
                let sample = LocationSample(location: location, source: .significantChange, dedupeKey: UUID().uuidString)
                sample.dayTimeline = day
                sample.moveSegment = segment
                context.insert(sample)
            }
            segments.append(.init(interval: DateInterval(start: start, end: end),
                                  stepsPerMinute: stepsPerMinute, metersPerStep: metersPerStep))
            cursor = end
            longitude += meters / Self.metersPerDegree
            let next = place(hours: 1)
            segment.endPlace = next
            return (segment, next)
        }

        let home = place(hours: 1)
        // Health: 1,500 steps and 1,100 m over a walk recorded as two fixes.
        let (sparse, office) = move(meters: 600, minutes: 15, spacing: 600, mode: .walking,
                                    stepsPerMinute: 100, metersPerStep: 1_100.0 / 1_500, from: home)
        let (dense, cafe) = move(meters: 1_000, minutes: 12, spacing: 20, mode: .walking,
                                 stepsPerMinute: 110, metersPerStep: 0.8, from: office)
        let (stepFree, market) = move(meters: 1_800, minutes: 37, spacing: 300, mode: .walking,
                                      stepsPerMinute: 261.0 / 37, metersPerStep: 0.7, from: cafe)
        let (imported, _) = move(meters: 600, minutes: 15, spacing: 600, mode: .walking, origin: .imported,
                                 stepsPerMinute: 100, metersPerStep: 0.75, from: market)
        // The cafe stay (1 hour) gets 15 minutes of walking around: about 1 km.
        segments.append(.init(interval: DateInterval(start: cafe.arrivalDate.addingTimeInterval(600), duration: 900),
                              stepsPerMinute: 95, metersPerStep: 0.7))
        try context.save()
        return Fixture(dayKey: day.dayKey, sparseWalk: sparse.id, denseWalk: dense.id, stepFreeWalk: stepFree.id,
                       importedWalk: imported.id, longStay: cafe.id, segments: segments)
    }

    private struct MoveValues {
        var transportMode: TransportMode
        var distanceMeters: Double
        var reviewState: ReviewState
        var startDate: Date
        var endDate: Date
    }

    /// Reads a trip on a fresh context, as the UI would after the sync saved.
    private func move(_ id: UUID, in container: ModelContainer) throws -> MoveValues {
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id })).first)
        return MoveValues(transportMode: row.transportMode, distanceMeters: row.distanceMeters,
                          reviewState: row.reviewState, startDate: row.startDate, endDate: row.endDate)
    }

    func testSyncEstimatesSparseWalksFlagsStepFreeWalksAndLeavesTheRestAlone() async throws {
        let container = try makeContainer()
        let fixture = try seed(ModelContext(container))
        let cache = HealthTimelineCacheStore(url: directory.appendingPathComponent("cache.json"))
        let store = HealthSummaryStore(cache: cache)
        let sync = HealthTimelineSync(container: container, summaryStore: store, cache: cache,
                                      reader: FakeHealthActivityReader(segments: fixture.segments))

        let report = await sync.perform()
        XCTAssertEqual(report.processedDays, 1)
        XCTAssertEqual(report.changedModes, 1)
        XCTAssertEqual(report.correctedDistances, 1)

        let sparse = try move(fixture.sparseWalk, in: container)
        XCTAssertEqual(sparse.distanceMeters, 1_100, accuracy: 1, "k = 1 until eight walks calibrate it")
        XCTAssertEqual(sparse.transportMode, .walking)
        XCTAssertEqual(try move(fixture.denseWalk, in: container).distanceMeters, 1_000, "GPS path kept")
        let stepFree = try move(fixture.stepFreeWalk, in: container)
        XCTAssertEqual(stepFree.transportMode, .unknown)
        XCTAssertEqual(stepFree.reviewState, .pending, "Ruled out as a walk, so the person is asked which vehicle")
        XCTAssertEqual(stepFree.distanceMeters, 1_800)
        let imported = try move(fixture.importedWalk, in: container)
        XCTAssertEqual(imported.distanceMeters, 600)
        XCTAssertEqual(imported.transportMode, .walking)

        let data = cache.data()
        XCTAssertEqual(data.trips[fixture.sparseWalk]?.originalDistance, 600)
        XCTAssertEqual(data.trips[fixture.stepFreeWalk]?.modeChange?.vote, .notOnFoot)
        XCTAssertEqual(data.trips[fixture.stepFreeWalk]?.evidence.vote, .notOnFoot)
        XCTAssertTrue(store.healthEstimatedTripIDs.contains(fixture.sparseWalk))
        XCTAssertNotNil(store.days[fixture.dayKey]?.steps)
        XCTAssertEqual(store.staysWalking[fixture.longStay]?.isWorthShowing, true)
        XCTAssertEqual(store.staysWalking[fixture.longStay]?.walkedMeters ?? 0, 998, accuracy: 2)

        // A settled day with an unchanged timeline is not read again, and nothing is applied twice.
        let again = await sync.perform()
        XCTAssertEqual(again.processedDays, 0)
        XCTAssertEqual(again.skippedDays, 1)
        XCTAssertEqual(try move(fixture.sparseWalk, in: container).distanceMeters, 1_100, accuracy: 1)

        // The person names the vehicle; Health never changes it back.
        let editing = ModelContext(container)
        let stepFreeID = fixture.stepFreeWalk
        let named = try XCTUnwrap(editing.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == stepFreeID })).first)
        named.transportMode = .cycling
        named.transportModeSource = .user
        try editing.save()
        _ = await sync.perform()
        XCTAssertEqual(try move(fixture.stepFreeWalk, in: container).transportMode, .cycling)
    }

    func testLockedOrUnauthorizedHealthChangesNothingAndIsReadAgain() async throws {
        let container = try makeContainer()
        let fixture = try seed(ModelContext(container))
        let cache = HealthTimelineCacheStore(url: directory.appendingPathComponent("cache.json"))
        let store = HealthSummaryStore(cache: cache)
        let locked = HealthTimelineSync(container: container, summaryStore: store, cache: cache,
                                        reader: FakeHealthActivityReader(segments: fixture.segments, forcedUnknown: .locked))
        let report = await locked.perform()
        XCTAssertEqual(report.changedModes + report.correctedDistances, 0)
        XCTAssertGreaterThan(report.unknownReasons[.locked] ?? 0, 0)
        XCTAssertEqual(try move(fixture.sparseWalk, in: container).distanceMeters, 600)
        XCTAssertEqual(try move(fixture.stepFreeWalk, in: container).transportMode, .walking)
        XCTAssertNil(store.days[fixture.dayKey]?.steps, "Unknown is not zero")
        XCTAssertEqual(cache.data().days[fixture.dayKey]?.isSettled, false)

        // Denied access reads as no samples at all: still unknown, still nothing written.
        let denied = HealthTimelineSync(container: container, summaryStore: store, cache: cache,
                                        reader: FakeHealthActivityReader(segments: []))
        let second = await denied.perform()
        XCTAssertEqual(second.processedDays, 1, "An unsettled day is read again")
        XCTAssertEqual(second.changedModes + second.correctedDistances, 0)
        XCTAssertEqual(try move(fixture.stepFreeWalk, in: container).transportMode, .walking)

        // Unlocked later: the same day is corrected.
        let unlocked = HealthTimelineSync(container: container, summaryStore: store, cache: cache,
                                          reader: FakeHealthActivityReader(segments: fixture.segments))
        _ = await unlocked.perform()
        XCTAssertEqual(try move(fixture.sparseWalk, in: container).distanceMeters, 1_100, accuracy: 1)
    }

    func testWriterSkipsRowsThatChangedSinceTheSnapshot() throws {
        let container = try makeContainer()
        let fixture = try seed(ModelContext(container))
        let current = try move(fixture.sparseWalk, in: container)
        let stale = HealthTripWrite(id: fixture.sparseWalk, expectedStart: current.startDate, expectedEnd: current.endDate,
                                    expectedMode: .walking, expectedDistance: 999, newMode: nil, newDistance: 1_100,
                                    asksForReview: false)
        XCTAssertEqual(try HealthTimelineWriter.apply([stale], container: container), [])
        let missing = HealthTripWrite(id: UUID(), expectedStart: .now, expectedEnd: .now, expectedMode: .walking,
                                      expectedDistance: 0, newMode: .unknown, newDistance: nil, asksForReview: true)
        XCTAssertEqual(try HealthTimelineWriter.apply([missing], container: container), [])
        XCTAssertEqual(try move(fixture.sparseWalk, in: container).distanceMeters, 600)
    }

    /// Runs the sync with synthetic Health against a private copy of the owner's store.
    /// Skips when no backup is present; prints counts only.
    func testSyncOnRealStoreCopyKeepsEveryRow() async throws {
        let backup = try Self.latestDeviceBackup()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let container = try ModelContainer(
            for: Schema(MovesTimelineSchema.models + [ShareMapAggregate.self]),
            configurations: [
                ModelConfiguration(schema: Schema(MovesTimelineSchema.models), url: storeURL, cloudKitDatabase: .none),
                ModelConfiguration("ShareMapCache", schema: Schema([ShareMapAggregate.self]),
                                   url: directory.appendingPathComponent("ShareMapCache.store"), cloudKitDatabase: .none),
            ]
        )
        let context = ModelContext(container)
        func counts() throws -> [Int] {
            [try context.fetchCount(FetchDescriptor<DayTimeline>()), try context.fetchCount(FetchDescriptor<VisitPlace>()),
             try context.fetchCount(FetchDescriptor<MoveSegment>()), try context.fetchCount(FetchDescriptor<LocationSample>())]
        }
        let before = try counts()
        var latest = FetchDescriptor<MoveSegment>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        latest.fetchLimit = 1
        let newest = try XCTUnwrap(context.fetch(latest).first?.startDate)
        let original = Dictionary(try context.fetch(FetchDescriptor<MoveSegment>()).map {
            ($0.id, ($0.transportMode, $0.distanceMeters, $0.permitsAutomaticModeChanges,
                     HealthTimelineSnapshotReader.permitsDistanceCorrection($0)))
        }, uniquingKeysWith: { first, _ in first })

        let snapshotStart = Calendar.current.date(byAdding: .day, value: -14, to: newest)!
        let snapshots = try HealthTimelineSnapshotReader.read(container: container, from: snapshotStart, to: newest.addingTimeInterval(86_400))
        let cache = HealthTimelineCacheStore(url: directory.appendingPathComponent("cache.json"))
        let sync = HealthTimelineSync(container: container, summaryStore: HealthSummaryStore(cache: cache), cache: cache,
                                      reader: HealthDemoProfile.reader(for: snapshots), now: { newest.addingTimeInterval(3_600) })
        let report = await sync.perform()
        print("Health sync on backup copy: \(report.processedDays) days, \(report.votes) votes, \(report.changedModes) modes, \(report.correctedDistances) distances, k \(report.calibration.k) from \(report.calibration.sampleCount)")

        XCTAssertEqual(try counts(), before, "No row added or removed")
        for move in try ModelContext(container).fetch(FetchDescriptor<MoveSegment>()) {
            guard let was = original[move.id] else { continue }
            if move.transportMode != was.0 { XCTAssertTrue(was.2, "Mode changed only where automatic changes are allowed") }
            if abs(move.distanceMeters - was.1) >= 1 { XCTAssertTrue(was.3, "Distance changed only on eligible sensor trips") }
        }
    }

    private static func latestDeviceBackup() throws -> URL {
        let staging = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("import-staging")
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [])
            .filter { $0.hasPrefix("device-backup-") }.sorted()
        guard let latest = backups.last else { throw XCTSkip("No device backup under import-staging") }
        let store = staging.appendingPathComponent(latest)
            .appendingPathComponent("group-container/Library/Application Support/default.store")
        guard FileManager.default.fileExists(atPath: store.path) else { throw XCTSkip("Backup has no timeline store") }
        return store
    }
}
