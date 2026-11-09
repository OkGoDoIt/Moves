import CoreLocation
import SQLite3
import SwiftData
import XCTest
@testable import Moves

/// Guards the store against the failures that reached a real phone: a map cache
/// reader racing the reconciler, and a schema change opening existing history.
@MainActor
final class StoreResilienceTests: XCTestCase {
    func testAutomaticModeCleanupAndUndoPreserveRealStore() throws {
        let backup = try Self.latestDeviceBackup()
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: storeURL.path + suffix)
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        }
        let container = try makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        let originalModes = Dictionary(uniqueKeysWithValues: moves.map { ($0.id, $0.transportMode) })
        let originalReviews = Dictionary(uniqueKeysWithValues: moves.map { ($0.id, $0.reviewState) })
        let before = try Self.rowCounts(in: storeURL)
        let history = AutomaticModeHistory(undoURL: directory.appendingPathComponent("undo.json"))
        let preferences = AutomaticTransportModes(disabled: [.cycling])
        let eligible = try history.candidates(in: context, preferences: preferences).count
        let report = try history.recheck(in: context, preferences: preferences)
        let reclassified = moves.filter { originalModes[$0.id] == .cycling && $0.transportMode != .cycling }
        let histogram = Dictionary(grouping: reclassified, by: { $0.transportMode.rawValue }).mapValues(\.count)
        print("Rechecked cycling mode counts (backup copy only): \(histogram)")
        let formatter = ISO8601DateFormatter()
        let knownStart = formatter.date(from: "2026-09-09T00:00:00Z")!
        let knownEnd = formatter.date(from: "2026-11-10T00:00:00Z")!
        let recent = reclassified.filter { $0.startDate >= knownStart && $0.startDate < knownEnd }
        print("Recent false cycling replacements (unverified guesses): \(Dictionary(grouping: recent, by: { $0.transportMode.rawValue }).mapValues(\.count))")
        XCTAssertEqual(report.changed, eligible)
        XCTAssertEqual(try history.candidates(in: context, preferences: preferences).count, 0)
        let after = try Self.rowCounts(in: storeURL)
        XCTAssertEqual(after.days, before.days)
        XCTAssertEqual(after.visits, before.visits)
        XCTAssertEqual(after.moves, before.moves)
        XCTAssertEqual(after.samples, before.samples)
        if eligible > 0 { XCTAssertEqual(try history.undo(in: context), eligible) }
        let restored = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.transportMode) }), originalModes)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.reviewState) }), originalReviews)
        print("Automatic mode cleanup on backup copy: \(eligible) eligible trips, all restored; row counts unchanged.")
    }

    /// 26 field crashes: `MoveSegment.id` aborted inside `ShareMapAggregateBuilder`
    /// because another context deleted the row while the builder walked `day.moves`.
    func testMapCacheRefreshSurvivesMovesBeingDeletedUnderIt() async throws {
        let directory = try makeTemporaryDirectory()
        let container = try makeContainer(storeURL: directory.appendingPathComponent("default.store"))
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-60 * 24 * 60 * 60)

        for dayIndex in 0..<60 {
            let dayStart = start.addingTimeInterval(Double(dayIndex) * 24 * 60 * 60)
            try seedDay(at: dayStart, repository: repository, context: context)
        }
        try context.save()

        let writer = Task.detached(priority: .userInitiated) {
            let writerContext = ModelContext(container)
            for _ in 0..<40 where !Task.isCancelled {
                let moves = (try? writerContext.fetch(FetchDescriptor<MoveSegment>())) ?? []
                for move in moves.shuffled().prefix(20) {
                    writerContext.delete(move)
                }
                try? writerContext.save()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        for _ in 0..<12 {
            await ShareMapAggregateBuilder.refreshAll(in: container)
        }
        writer.cancel()
        _ = await writer.value

        let verification = ModelContext(container)
        XCTAssertFalse(try verification.fetch(FetchDescriptor<ShareMapAggregate>()).isEmpty)
    }

    /// Opens a copy of a real phone's store under the current schema. Skipped when
    /// no backup is present; the backup is private and stays out of the repository.
    func testRealStoreOpensAndKeepsEveryRow() async throws {
        let backup = try XCTUnwrap(
            try? Self.latestDeviceBackup(),
            "No device backup under import-staging"
        )
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: storeURL.path + suffix)
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        }

        let before = try Self.rowCounts(in: storeURL)
        let labelsBefore = try Self.distinctLabels(in: storeURL)

        let container = try makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DayTimeline>()), before.days)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitPlace>()), before.visits)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MoveSegment>()), before.moves)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocationSample>()), before.samples)

        let flightsBefore = try Self.flightStarts(in: ModelContext(container))
        let pendingBefore = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
            .filter { $0.reviewState == .pending }
            .count
        try TimelineSchemaUpgrader.upgrade(in: ModelContext(container))
        await TimelineSchemaUpgrader.repairLongTrips(in: container)
        XCTAssertEqual(try Self.flightStarts(in: ModelContext(container)), flightsBefore, "A flight changed")
        let repaired = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(
            repaired.filter { $0.transportMode != .plane && $0.endDate.timeIntervalSince($0.startDate) > 6 * 60 * 60 }.count,
            0,
            "A trip still swallows a stop"
        )
        XCTAssertLessThanOrEqual(
            repaired.filter { $0.reviewState == .pending }.count,
            pendingBefore + 3,
            "An upgrade should not fill the Review inbox"
        )

        let afterUpgrade = ModelContext(container)
        XCTAssertEqual(try afterUpgrade.fetchCount(FetchDescriptor<LocationSample>()), before.samples)
        print("Real store after repair: \(try Self.quality(of: afterUpgrade))")

        // Fixes are the record of where the person actually was. Nothing may lose them.
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: RecordingMotionClassifier(),
            placeNameResolver: NoNamePlaceResolver()
        )

        var previous = try Self.identities(in: ModelContext(container))
        for pass in 1...4 {
            await assembler.reconcileSampleStays()
            let current = try Self.identities(in: ModelContext(container))
            if pass >= 3 {
                XCTAssertEqual(current.moves, previous.moves, "Pass \(pass) deleted or rebuilt trips with nothing new to learn")
                XCTAssertEqual(current.visits, previous.visits, "Pass \(pass) deleted or rebuilt stops with nothing new to learn")
            }
            previous = current
        }

        let finalContext = ModelContext(container)
        XCTAssertEqual(try finalContext.fetchCount(FetchDescriptor<LocationSample>()), before.samples)
        let labelsAfter = Set(try finalContext.fetch(FetchDescriptor<VisitPlace>()).compactMap(\.userLabel))
        XCTAssertEqual(labelsBefore.subtracting(labelsAfter), [], "A place name the person gave was lost")
        let quality = try Self.quality(of: finalContext)
        XCTAssertLessThanOrEqual(quality.open, 1, "Only the current stop may be open")
        XCTAssertEqual(quality.selfLoops, 0, "A trip may not start and end at the same stop")
        XCTAssertEqual(quality.partialOverlaps, 0, "Nobody is in two places at once")
        XCTAssertEqual(quality.containedStops, 0, "A stop still runs straight past an outing")

        await ShareMapAggregateBuilder.refreshAll(in: container)
        XCTAssertFalse(try ModelContext(container).fetch(FetchDescriptor<ShareMapAggregate>()).isEmpty)
    }

    // MARK: - Helpers

    private func seedDay(
        at dayStart: Date,
        repository: SwiftDataTimelineRepository,
        context: ModelContext
    ) throws {
        var previous: VisitPlace?
        for index in 0..<5 {
            let arrival = dayStart.addingTimeInterval(Double(index) * 2 * 60 * 60)
            let place = try repository.addOrUpdateVisit(
                from: MockVisit(
                    coordinate: CLLocationCoordinate2D(latitude: 10.77 + Double(index) * 0.01, longitude: 106.70),
                    horizontalAccuracy: 20,
                    arrivalDate: arrival,
                    departureDate: arrival.addingTimeInterval(60 * 60)
                )
            )
            if let previous {
                let samples = try repository.appendSamples(
                    from: (0..<6).map { step in
                        CLLocation(
                            coordinate: CLLocationCoordinate2D(
                                latitude: previous.latitude + Double(step) * 0.001,
                                longitude: 106.70
                            ),
                            altitude: 0,
                            horizontalAccuracy: 15,
                            verticalAccuracy: -1,
                            course: -1,
                            speed: -1,
                            timestamp: arrival.addingTimeInterval(Double(step) * -60)
                        )
                    },
                    source: .routeTracking
                )
                _ = try repository.upsertMove(
                    startPlace: previous,
                    endPlace: place,
                    startDate: previous.departureDate ?? arrival,
                    endDate: arrival,
                    transportMode: .automotive,
                    distanceMeters: 1_100,
                    stepCount: 10,
                    samples: samples
                )
            }
            previous = place
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreResilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeContainer(storeURL: URL) throws -> ModelContainer {
        let timelineSchema = Schema(MovesTimelineSchema.models)
        let cacheSchema = Schema([ShareMapAggregate.self])
        return try ModelContainer(
            for: Schema(MovesTimelineSchema.models + [ShareMapAggregate.self]),
            configurations: [
                ModelConfiguration(schema: timelineSchema, url: storeURL, cloudKitDatabase: .none),
                ModelConfiguration(
                    "ShareMapCache",
                    schema: cacheSchema,
                    url: storeURL.deletingLastPathComponent().appendingPathComponent("ShareMapCache.store"),
                    cloudKitDatabase: .none
                )
            ]
        )
    }

    private static func latestDeviceBackup() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let staging = repository.appendingPathComponent("import-staging")
        let backups = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0.hasPrefix("device-backup-") }
            .sorted()
        guard let latest = backups.last else {
            throw XCTSkip("No device backup under import-staging")
        }
        let store = staging
            .appendingPathComponent(latest)
            .appendingPathComponent("group-container/Library/Application Support/default.store")
        guard FileManager.default.fileExists(atPath: store.path) else {
            throw XCTSkip("Backup has no timeline store")
        }
        return store
    }

    private struct RowCounts {
        var days = 0
        var visits = 0
        var moves = 0
        var samples = 0
    }

    private static func rowCounts(in storeURL: URL) throws -> RowCounts {
        RowCounts(
            days: try scalar("SELECT COUNT(*) FROM ZDAYTIMELINE", in: storeURL),
            visits: try scalar("SELECT COUNT(*) FROM ZVISITPLACE", in: storeURL),
            moves: try scalar("SELECT COUNT(*) FROM ZMOVESEGMENT", in: storeURL),
            samples: try scalar("SELECT COUNT(*) FROM ZLOCATIONSAMPLE", in: storeURL)
        )
    }

    private static func distinctLabels(in storeURL: URL) throws -> Set<String> {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw XCTSkip("Could not open the store copy")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT DISTINCT ZUSERLABEL FROM ZVISITPLACE WHERE ZUSERLABEL IS NOT NULL AND ZUSERLABEL != ''"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw XCTSkip("Could not query the store copy")
        }
        var labels = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            labels.insert(String(cString: sqlite3_column_text(statement, 0)))
        }
        return labels
    }

    private static func scalar(_ query: String, in storeURL: URL) throws -> Int {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw XCTSkip("Could not open the store copy")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw XCTSkip("Could not query the store copy")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func flightStarts(in context: ModelContext) throws -> Set<Date> {
        Set(try context.fetch(FetchDescriptor<MoveSegment>()).filter { $0.transportMode == .plane }.map(\.startDate))
    }

    private struct Quality {
        var visits = 0
        var moves = 0
        var open = 0
        var partialOverlaps = 0
        var containedStops = 0
        var selfLoops = 0
    }

    private static func quality(of context: ModelContext) throws -> Quality {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        var result = Quality(visits: visits.count, moves: moves.count)
        result.open = visits.filter { $0.departureDate == nil }.count
        result.selfLoops = moves.filter { $0.startPlace?.id != nil && $0.startPlace?.id == $0.endPlace?.id }.count
        let closed = visits.filter { $0.departureDate != nil }
        for (a, b) in zip(closed, closed.dropFirst()) {
            guard let aEnd = a.departureDate, let bEnd = b.departureDate,
                  aEnd.timeIntervalSince(b.arrivalDate) > 60 else { continue }
            if bEnd <= aEnd {
                result.containedStops += 1
            } else {
                result.partialOverlaps += 1
            }
        }
        return result
    }

    private struct Identities {
        var visits: Set<UUID>
        var moves: Set<UUID>
    }

    private static func identities(in context: ModelContext) throws -> Identities {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        return Identities(visits: Set(visits.map(\.id)), moves: Set(moves.map(\.id)))
    }
}

private struct RecordingMotionClassifier: MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (.automotive, 0.9)
    }

    func stepCount(start: Date, end: Date) async -> Int? {
        0
    }
}

private struct NoNamePlaceResolver: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        nil
    }
}
