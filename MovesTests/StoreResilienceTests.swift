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

        let flightsBefore = try Self.flights(in: ModelContext(container))
        let pendingBefore = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
            .filter { $0.reviewState == .pending }
            .count
        try TimelineSchemaUpgrader.upgrade(in: ModelContext(container))
        await TimelineSchemaUpgrader.repairLongTrips(in: container)
        let flightsAfter = try Self.flights(in: ModelContext(container))
        // Step 4 may call a flight that came from a file imported; nothing else may change.
        XCTAssertEqual(
            flightsAfter.filter { !$0.value.isFromPhotos }.mapValues(\.withoutImportLabel),
            flightsBefore.filter { !$0.value.isFromPhotos }.mapValues(\.withoutImportLabel),
            "A recorded or imported flight changed"
        )
        for (id, flight) in flightsBefore where flight.isFromPhotos {
            if let after = flightsAfter[id] {
                XCTAssertEqual(after, flight, "A flight between photos changed")
                XCTAssertTrue(flight.isPossible || flight.isTouched, "An impossible flight stayed: \(flight)")
            } else {
                XCTAssertFalse(flight.isPossible, "A possible flight was removed: \(flight)")
                XCTAssertFalse(flight.isTouched, "A flight the person touched was removed: \(flight)")
            }
        }
        XCTAssertTrue(Set(flightsAfter.keys).isSubset(of: flightsBefore.keys), "A flight was made up")
        print("Flights: \(flightsBefore.count) before, \(flightsBefore.count - flightsAfter.count) impossible ones removed")
        let repaired = try ModelContext(container).liveMoves()
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
        let writerContext = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: writerContext)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: RecordingMotionClassifier(),
            placeNameResolver: NoNamePlaceResolver()
        )

        var previous = try Self.identities(in: ModelContext(container))
        var saves = 0
        // Only the reconciler's own context: the test host app saves its demo store too.
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: writerContext, queue: nil) { _ in
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var currentPass = 0
        // What a later pass touched, against the stored row, for diagnosis.
        let willSave = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: writerContext, queue: nil) { _ in
            guard currentPass >= 2 else { return }
            let stored = ModelContext(container)
            for model in writerContext.changedModelsArray {
                if let place = model as? VisitPlace {
                    let id = place.id
                    let old = try? stored.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == id })).first
                    print("Pass \(currentPass) stop \(id.uuidString.prefix(4)) origin=\(place.origin.rawValue) arrival \(String(describing: old?.arrivalDate))→\(place.arrivalDate) departure \(String(describing: old?.departureDate))→\(String(describing: place.departureDate)) review \(old?.reviewStateRaw ?? "-")→\(place.reviewStateRaw) day changed=\(old?.dayTimeline?.persistentModelID != place.dayTimeline?.persistentModelID)")
                } else if let move = model as? MoveSegment {
                    let id = move.id
                    let old = try? stored.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id })).first
                    print("Pass \(currentPass) trip \(id.uuidString.prefix(4)) \(String(describing: old?.startDate))→\(move.startDate) \(String(describing: old?.endDate))→\(move.endDate) mode \(old?.transportModeRawValue ?? "-")→\(move.transportModeRawValue) distance \(old?.distanceMeters ?? -1)→\(move.distanceMeters) review \(old?.reviewStateRaw ?? "-")→\(move.reviewStateRaw) confidence \(old?.routeMatchConfidenceRaw ?? "-")→\(move.routeMatchConfidenceRaw)")
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(willSave) }
        // Full, trip-only, full, trip-only, as capture runs them.
        let tripSince = Date().addingTimeInterval(-2 * 60 * 60)
        for pass in 1...4 {
            saves = 0
            currentPass = pass
            await assembler.reconcile(pass.isMultiple(of: 2) ? .recentTrip(since: tripSince) : .week)
            let current = try Self.identities(in: ModelContext(container))
            // The first pass may repair what older builds left; after that, nothing is new.
            if pass >= 2 {
                XCTAssertEqual(current.moves, previous.moves, "Pass \(pass) deleted or rebuilt trips with nothing new to learn")
                XCTAssertEqual(current.visits, previous.visits, "Pass \(pass) deleted or rebuilt stops with nothing new to learn")
                XCTAssertEqual(saves, 0, "Pass \(pass) saved with nothing new to learn")
            }
            print("Reconcile pass \(pass): \(saves) saves")
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

    /// Insights now reads its own context instead of the view's day rows. On a real
    /// history it must add up to exactly what walking every day's rows did.
    func testInsightsLoaderMatchesTheDayWalkOnRealStore() throws {
        let backup = try Self.latestDeviceBackup()
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let container = try makeContainer(storeURL: storeURL)
        let days = try ModelContext(container).fetch(FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart)]))
        let walked = days.map { day in
            InsightsDayRecord(
                // The day's own date, as the loader reads it: since days are filed where
                // they happened, `dayStart` of a day east of the phone falls on the date
                // before and would merge two days into one.
                dayStart: day.calendarDate(),
                moves: day.moves.flatMap(InsightsMoveRecord.records),
                visits: day.places.map(InsightsVisitRecord.init)
            )
        }
        let loaded = try InsightsSourceLoader.load(from: container)
        XCTAssertEqual(loaded.days.count, walked.count)
        let now = Date.now
        let calendar = Calendar.current
        for period in [InsightsPeriod.year(calendar.component(.year, from: now)), .all] {
            let old = InsightsSnapshotBuilder.build(days: walked, period: period, now: now, calendar: calendar, builtAt: now)
            let new = InsightsSnapshotBuilder.build(days: loaded.days, period: period, now: now, calendar: calendar, builtAt: now)
            XCTAssertEqual(new.totalDistanceMeters, old.totalDistanceMeters, accuracy: 0.01)
            XCTAssertEqual(new.totalMovingDuration, old.totalMovingDuration, accuracy: 0.01)
            XCTAssertEqual(new.activeDayCount, old.activeDayCount)
            XCTAssertEqual(new.currentStreakDays, old.currentStreakDays)
            XCTAssertEqual(new.longestStreakDays, old.longestStreakDays)
            XCTAssertEqual(new.geography, old.geography)
            XCTAssertEqual(new.modes.map(\.modeRaw), old.modes.map(\.modeRaw))
            for (a, b) in zip(new.modes, old.modes) {
                XCTAssertEqual(a.distanceMeters, b.distanceMeters, accuracy: 0.01)
                XCTAssertEqual(a.duration, b.duration, accuracy: 0.01)
            }
            print("Insights \(period.id) on backup copy: \(Int(new.totalDistanceMeters)) m, \(Int(new.totalMovingDuration)) s, \(new.activeDayCount) active days — matches day walk")
        }
    }

    /// Opening Places, and the pass that hands unnamed stays a neighbor's name, on years
    /// of history. Both once held every stay against every other, which took minutes on
    /// the phone after a photo import; ten seconds is generous for neighbors only.
    func testPlacesGroupingAndNameReuseAreQuickOnRealStore() throws {
        let backup = try Self.latestDeviceBackup()
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let container = try makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>.live()).map(PlacesVisitRecord.init)
        let places = try context.fetch(FetchDescriptor<KnownPlace>()).map(PlacesKnownRecord.init)
        let clock = ContinuousClock()

        var snapshot = PlacesIndexSnapshot.empty
        let grouping = clock.measure {
            snapshot = PlacesIndexBuilder.build(
                knownPlaces: places,
                visits: visits,
                sort: .mostVisited,
                query: "",
                now: .now,
                calendar: .current
            )
        }
        // Every stay without a place of its own lands in exactly one suggestion.
        let unassigned = visits.filter { $0.knownPlaceID == nil && !$0.isHiddenAsShortStop }
        XCTAssertEqual(snapshot.suggested.reduce(0) { $0 + $1.visitCount }, unassigned.count)
        XCTAssertEqual(Set(snapshot.suggested.flatMap(\.visitIDs)).count, unassigned.count)
        XCTAssertLessThan(grouping, .seconds(10))

        var reused = 0
        let reuse = try clock.measure { reused = try PlaceGeocodeBackfill.reuseNearbyLabels(in: context) }
        XCTAssertLessThan(reuse, .seconds(10))
        // Written to the copy: names left unsaved are read again after the copy is
        // deleted, and that ends the test process during whichever test runs next.
        try context.save()
        print("Places on backup copy: \(visits.count) stays in \(snapshot.suggested.count) suggestions, grouped in \(grouping); \(reused) stays took a neighbor's name in \(reuse)")
    }

    /// Before-and-after numbers for the stop and trip rules on a copy of a real store.
    ///
    /// Skipped unless `MOVES_REBUILD_STORE` names a `default.store` (pass it to
    /// `xcodebuild` as `TEST_RUNNER_MOVES_REBUILD_STORE`). `MOVES_REBUILD_NOW` (ISO 8601)
    /// shifts "now"; the default is just after the newest fix. `MOVES_REBUILD_OUT` names
    /// a directory the rebuilt copy is written to, for the audit scripts. The copy is a
    /// private backup: nothing from it is asserted on by name or place.
    func testRebuildMeasurementsOnAStoreCopy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MOVES_REBUILD_STORE"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set MOVES_REBUILD_STORE to a copy of default.store")
        }
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: storeURL.path + suffix)
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        }
        let container = try makeContainer(storeURL: storeURL)
        // The launch purge first, as the app runs it before any view exists.
        let launchPurgeStarted = ContinuousClock.now
        let waitingAtLaunch = try SwiftDataTimelineRepository.retiredRowCount(in: ModelContext(container))
        let probed = ContinuousClock.now - launchPurgeStarted
        let purgedAtLaunch = waitingAtLaunch > 0 ? try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container)) : 0
        print("REBUILD launch purge: \(waitingAtLaunch) retired rows waiting, probe \(probed), \(purgedAtLaunch) removed in \(ContinuousClock.now - launchPurgeStarted)")
        let probe = ModelContext(container)
        var newest = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        newest.fetchLimit = 1
        let newestFix = try probe.fetch(newest).first?.timestamp ?? .now
        let now = environment["MOVES_REBUILD_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? newestFix.addingTimeInterval(5 * 60)
        let windowStart = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let before = try Self.rebuildMetrics(in: ModelContext(container), from: windowStart, to: now)
        let replay = try ReplayMotionClassifier(context: ModelContext(container))
        let writerContext = ModelContext(container)
        let assembler = DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContext: writerContext),
            motionClassifier: replay,
            placeNameResolver: NoNamePlaceResolver(),
            automaticModes: { .init() },
            now: { now },
            paceRulesDefaults: nil
        )

        // The pace sweep over all history, as the app runs it once.
        let yearStart = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let running = try writerContext.fetch(FetchDescriptor<MoveSegment>())
            .filter { $0.transportMode == .running && $0.startDate >= yearStart }
        let runningIDs = Set(running.map(\.id))
        let runningMiles = running.reduce(0) { $0 + $1.distanceMeters } / 1_609.344
        let pace = try AutomaticModeHistory.applyPaceRules(in: writerContext, now: now, preferences: .init())
        let relabeled = try writerContext.fetch(FetchDescriptor<MoveSegment>()).filter { runningIDs.contains($0.id) }
        let outcome = Dictionary(grouping: relabeled, by: { $0.transportMode.rawValue }).mapValues { trips in
            "\(trips.count) trips, \(Int(trips.reduce(0) { $0 + $1.distanceMeters } / 1_609.344)) mi"
        }
        print("REBUILD 2026 running trips: \(running.count) (\(Int(runningMiles)) mi); after the pace sweep: \(outcome.sorted { $0.key < $1.key })")
        print("REBUILD pace sweep: checked \(pace.checked), changed \(pace.changed.map { "\($0.key.rawValue)=\($0.value)" }.sorted())")

        var counts: [String: Int] = [:]
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: writerContext, queue: nil) { note in
            for (key, label) in [(ModelContext.NotificationKey.insertedIdentifiers, "inserted"),
                                 (.updatedIdentifiers, "updated"), (.deletedIdentifiers, "deleted")] {
                let ids = (note.userInfo?[key.rawValue] as? [PersistentIdentifier]) ?? []
                for id in ids where id.entityName == "VisitPlace" || id.entityName == "MoveSegment" {
                    counts["\(label) \(id.entityName)", default: 0] += 1
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var passNumber = 0
        // Which rows a later pass touched, and which day row they point at, for diagnosis.
        let willSave = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: writerContext, queue: nil) { _ in
            guard passNumber >= 2 else { return }
            let stored = ModelContext(container)
            for model in writerContext.changedModelsArray {
                if let place = model as? VisitPlace {
                    let id = place.id
                    if let old = try? stored.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == id })).first {
                        let fields: [(String, Bool)] = [
                            ("arrival", old.arrivalDate != place.arrivalDate), ("departure", old.departureDate != place.departureDate),
                            ("lat", old.latitude != place.latitude), ("lon", old.longitude != place.longitude),
                            ("acc", old.horizontalAccuracy != place.horizontalAccuracy),
                            ("day", old.dayTimeline?.persistentModelID != place.dayTimeline?.persistentModelID),
                            ("review", old.reviewStateRaw != place.reviewStateRaw), ("auto", old.autoLabel != place.autoLabel),
                            ("user", old.userLabel != place.userLabel), ("known", old.knownPlace?.id != place.knownPlace?.id),
                            ("assign", old.assignmentSourceRaw != place.assignmentSourceRaw),
                            ("out", Set(old.outgoingMoves.map(\.id)) != Set(place.outgoingMoves.map(\.id))),
                            ("in", Set(old.incomingMoves.map(\.id)) != Set(place.incomingMoves.map(\.id))),
                        ]
                        print("REBUILD pass \(passNumber) stop \(id.uuidString.prefix(4)) differs in: \(fields.filter(\.1).map(\.0)) arrival \(old.arrivalDate)→\(place.arrivalDate) departure \(String(describing: old.departureDate))→\(String(describing: place.departureDate))")
                    }
                } else if let move = model as? MoveSegment {
                    let id = move.id
                    if let old = try? stored.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id })).first {
                        let fields: [(String, Bool)] = [
                            ("start", old.startDate != move.startDate), ("end", old.endDate != move.endDate),
                            ("mode", old.transportModeRawValue != move.transportModeRawValue),
                            ("distance", old.distanceMeters != move.distanceMeters), ("steps", old.stepCount != move.stepCount),
                            ("from", old.startPlace?.id != move.startPlace?.id), ("to", old.endPlace?.id != move.endPlace?.id),
                            ("day", old.dayTimeline?.persistentModelID != move.dayTimeline?.persistentModelID),
                            ("key", old.dedupeKey != move.dedupeKey), ("review", old.reviewStateRaw != move.reviewStateRaw),
                            ("confidence", old.routeMatchConfidenceRaw != move.routeMatchConfidenceRaw),
                            ("summary", old.routeMatchSummary != move.routeMatchSummary),
                            ("samples", Set(old.samples.map(\.dedupeKey)) != Set(move.samples.map(\.dedupeKey))),
                            ("cache", old.routeCacheSignature != move.routeCacheSignature),
                        ]
                        print("REBUILD pass \(passNumber) trip \(id.uuidString.prefix(4)) differs in: \(fields.filter(\.1).map(\.0))")
                    }
                }
            }
            for model in writerContext.changedModelsArray {
                if let place = model as? VisitPlace {
                    print("REBUILD pass \(passNumber) touched stop \(place.id.uuidString.prefix(4)) day=\(String(describing: place.dayTimeline?.persistentModelID.hashValue)) arrival=\(place.arrivalDate) departure=\(String(describing: place.departureDate))")
                } else if let move = model as? MoveSegment {
                    print("REBUILD pass \(passNumber) touched trip \(move.id.uuidString.prefix(4)) day=\(String(describing: move.dayTimeline?.persistentModelID.hashValue)) \(move.startDate)…\(move.endDate) \(move.transportMode.rawValue) from=\(move.startPlace?.id.uuidString.prefix(4) ?? "-") to=\(move.endPlace?.id.uuidString.prefix(4) ?? "-")")
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(willSave) }
        var passes: [[String: Int]] = []
        func snapshot() throws -> [UUID: String] {
            let check = ModelContext(container)
            var rows: [UUID: String] = [:]
            for place in try check.fetch(FetchDescriptor<VisitPlace>()) where place.arrivalDate >= windowStart.addingTimeInterval(-36 * 3_600) {
                rows[place.id] = "stop \(place.arrivalDate)…\(place.departureDate.map { "\($0)" } ?? "open") src=\(place.origin.rawValue) rv=\(place.reviewState.rawValue) named=\(place.userLabel != nil) kp=\(place.knownPlace != nil) day=\(place.dayTimeline?.dayKey ?? "-") acc=\(place.horizontalAccuracy) at=\(String(format: "%.6f,%.6f", place.latitude, place.longitude)) auto=\(place.autoLabel != nil) assign=\(place.assignmentSource.rawValue)"
            }
            for move in try check.fetch(FetchDescriptor<MoveSegment>()) where move.endDate >= windowStart {
                rows[move.id] = "trip \(move.startDate)…\(move.endDate) \(move.transportMode.rawValue) \(Int(move.distanceMeters)) m steps=\(String(describing: move.stepCount)) from=\(move.startPlace?.id.uuidString.prefix(4) ?? "-") to=\(move.endPlace?.id.uuidString.prefix(4) ?? "-") rv=\(move.reviewState.rawValue) rm=\(move.routeMatchConfidence.rawValue) day=\(move.dayTimeline?.dayKey ?? "-") key=\(move.dedupeKey.prefix(12)) samples=\(move.samples.count)"
            }
            return rows
        }
        var previousRows = try snapshot()
        // Full, trip-only, full, trip-only: the live trip's rebuild must agree with the week's.
        let scopes: [CaptureRebuildScope] = [.week, .recentTrip(since: now.addingTimeInterval(-2 * 60 * 60)),
                                             .week, .recentTrip(since: now.addingTimeInterval(-2 * 60 * 60))]
        for pass in 1...4 {
            counts = [:]
            passNumber = pass
            await assembler.reconcile(scopes[pass - 1])
            passes.append(counts)
            let rows = try snapshot()
            if pass >= 2 {
                for (id, row) in rows where previousRows[id] != row {
                    print("REBUILD pass \(pass) \(id.uuidString.prefix(4)) was: \(previousRows[id] ?? "-") now: \(row)")
                }
                for (id, row) in previousRows where rows[id] == nil {
                    print("REBUILD pass \(pass) \(id.uuidString.prefix(4)) removed: \(row)")
                }
            }
            previousRows = rows
        }
        let after = try Self.rebuildMetrics(in: ModelContext(container), from: windowStart, to: now)
        // Stops that still run past another anywhere in the store, for diagnosis.
        let everyStop = try ModelContext(container).liveVisits().filter { $0.departureDate != nil }
        for (a, b) in zip(everyStop, everyStop.dropFirst()) {
            guard let aEnd = a.departureDate, let bEnd = b.departureDate, aEnd.timeIntervalSince(b.arrivalDate) > 60 else { continue }
            let apart = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            print("REBUILD overlap \(bEnd <= aEnd ? "contained" : "partial"): \(a.origin.rawValue) \(a.arrivalDate)…\(aEnd) rv=\(a.reviewState.rawValue) / \(b.origin.rawValue) \(b.arrivalDate)…\(bEnd) rv=\(b.reviewState.rawValue) \(Int(apart)) m")
        }

        print("REBUILD now=\(now) window=\(windowStart)…\(now)")
        print("REBUILD before: \(before.summary)")
        print("REBUILD after:  \(after.summary)")
        for (index, pass) in passes.enumerated() {
            print("REBUILD pass \(index + 1) row changes: \(pass.sorted { $0.key < $1.key })")
        }
        for pass in passes.dropFirst() {
            XCTAssertTrue(pass.isEmpty, "A pass after the first changed rows: \(pass)")
        }
        XCTAssertEqual(after.negative, 0)
        XCTAssertEqual(after.stopOverlaps, 0)
        XCTAssertEqual(after.tripOverlaps, 0)

        if let out = environment["MOVES_REBUILD_OUT"] {
            let outURL = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                let target = outURL.appendingPathComponent("default.store" + suffix)
                try? FileManager.default.removeItem(at: target)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        }

        // The next launch's purge: exactly the retired rows go, and every live row stays.
        let rowCounts = { (context: ModelContext) throws -> (visits: Int, moves: Int, all: Int) in
            (try context.fetchCount(FetchDescriptor<VisitPlace>.live()), try context.fetchCount(FetchDescriptor<MoveSegment>.live()),
             try context.fetchCount(FetchDescriptor<VisitPlace>()) + context.fetchCount(FetchDescriptor<MoveSegment>()))
        }
        let beforePurge = try rowCounts(ModelContext(container))
        let retired = try SwiftDataTimelineRepository.retiredRowCount(in: ModelContext(container))
        let purgeStarted = ContinuousClock.now
        let purged = try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container))
        let purgeTime = ContinuousClock.now - purgeStarted
        let afterPurge = try rowCounts(ModelContext(container))
        print("REBUILD live after passes: \(beforePurge.visits) stops, \(beforePurge.moves) trips; \(retired) retired")
        print("REBUILD purge at next launch: \(purged) removed in \(purgeTime); \(afterPurge.visits) stops, \(afterPurge.moves) trips left")
        XCTAssertEqual(purged, retired)
        XCTAssertEqual(beforePurge.all - afterPurge.all, retired)
        XCTAssertEqual(afterPurge.visits, beforePurge.visits)
        XCTAssertEqual(afterPurge.moves, beforePurge.moves)
        XCTAssertEqual(afterPurge.all, afterPurge.visits + afterPurge.moves, "No row without a day is left")

        // The purge's cost with a few hundred retired rows: the oldest 300 trips of this copy.
        let bulkContext = ModelContext(container)
        var oldest = FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)])
        oldest.fetchLimit = 300
        let bulkRepository = SwiftDataTimelineRepository(modelContext: bulkContext)
        for move in try bulkContext.fetch(oldest) { bulkRepository.retire(move) }
        try bulkContext.save()
        let bulkWaiting = try SwiftDataTimelineRepository.retiredRowCount(in: ModelContext(container))
        let bulkStarted = ContinuousClock.now
        let bulkPurged = try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container))
        print("REBUILD purge of \(bulkWaiting) retired trips: \(bulkPurged) removed in \(ContinuousClock.now - bulkStarted)")
        XCTAssertEqual(bulkPurged, bulkWaiting)
    }

    struct RebuildMetrics {
        var stops = 0
        var trips = 0
        var jumpsWithoutTrip = 0
        var underTenMinutes = 0
        var zeroLength = 0
        var negative = 0
        var stopOverlaps = 0
        var tripOverlaps = 0
        var sameSpanTrips = 0
        var modes: [String: Int] = [:]
        var walkingKilometresByDay: [String: Double] = [:]

        var summary: String {
            let days = walkingKilometresByDay.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " ")
            return "stops \(stops), trips \(trips), jumps without trip \(jumpsWithoutTrip), stops <10 min \(underTenMinutes), "
                + "zero-length \(zeroLength), negative \(negative), stop overlaps \(stopOverlaps), trip overlaps \(tripOverlaps), "
                + "same-span trips \(sameSpanTrips), modes \(modes.sorted { $0.key < $1.key }), walking km/day \(days)"
        }
    }

    static func rebuildMetrics(in context: ModelContext, from start: Date, to end: Date) throws -> RebuildMetrics {
        var metrics = RebuildMetrics()
        let stops = try context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.arrivalDate >= start && $0.arrivalDate <= end },
                                                                  sortBy: [SortDescriptor(\.arrivalDate)]))
            .filter { $0.dayTimeline != nil }
        let trips = try context.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.startDate >= start && $0.startDate <= end },
                                                                   sortBy: [SortDescriptor(\.startDate)]))
            .filter { $0.dayTimeline != nil }
        metrics.stops = stops.count
        metrics.trips = trips.count
        for stop in stops {
            guard let departure = stop.departureDate else { continue }
            let duration = departure.timeIntervalSince(stop.arrivalDate)
            if duration < 0 { metrics.negative += 1 }
            if duration == 0 { metrics.zeroLength += 1 }
            if duration < 600 { metrics.underTenMinutes += 1 }
        }
        for (a, b) in zip(stops, stops.dropFirst()) {
            let end = a.departureDate ?? a.arrivalDate
            if end.timeIntervalSince(b.arrivalDate) > 1 { metrics.stopOverlaps += 1 }
            let apart = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            if b.arrivalDate.timeIntervalSince(end) <= 60, apart > 120 { metrics.jumpsWithoutTrip += 1 }
        }
        for (a, b) in zip(trips, trips.dropFirst()) {
            if a.endDate.timeIntervalSince(b.startDate) > 1 { metrics.tripOverlaps += 1 }
            if a.startDate == b.startDate, a.endDate == b.endDate { metrics.sameSpanTrips += 1 }
        }
        for trip in trips {
            metrics.modes[trip.transportMode.rawValue, default: 0] += 1
            if trip.transportMode == .walking, let day = trip.dayTimeline?.dayKey {
                metrics.walkingKilometresByDay[day, default: 0] += trip.distanceMeters / 1_000
            }
        }
        return metrics
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
        // A worktree sits inside the main checkout, which holds the private backups.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var staging = directory.appendingPathComponent("import-staging")
        while !FileManager.default.fileExists(atPath: staging.path), directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
            staging = directory.appendingPathComponent("import-staging")
        }
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

    private struct Flight: Equatable {
        var start: Date
        var end: Date
        var recordedDistance: Double
        /// Between the two stops, which is what the rule for photo trips looks at.
        var distance: Double
        var origin: String
        var source: String
        var review: String
        var comment: String
        var route: Data?

        var isFromPhotos: Bool { origin == TimelineItemOrigin.photoInferred.rawValue }

        var withoutImportLabel: Flight {
            var flight = self
            if origin == TimelineItemOrigin.imported.rawValue {
                flight.origin = TimelineItemOrigin.sensor.rawValue
            }
            return flight
        }

        var isTouched: Bool {
            source == TransportModeSource.user.rawValue || review == ReviewState.confirmed.rawValue
                || !comment.isEmpty || route != nil
        }

        /// Written out here rather than asked of the importer, so a mistake there shows.
        var isPossible: Bool {
            let hours = end.timeIntervalSince(start) / 3_600
            guard hours > 0, hours <= 24, distance >= 150_000 else { return false }
            let speed = distance / 1_000 / hours
            return speed > 200 && speed <= 1_000
        }
    }

    private static func flights(in context: ModelContext) throws -> [UUID: Flight] {
        let moves = try context.liveMoves().filter { $0.transportMode == .plane }
        return Dictionary(
            moves.map { move in
                let distance: Double
                if let start = move.startPlace, let end = move.endPlace {
                    distance = LocationLogGeometry.distance(from: start.coordinate, to: end.coordinate)
                } else {
                    distance = move.distanceMeters
                }
                return (
                    move.id,
                    Flight(
                        start: move.startDate, end: move.endDate, recordedDistance: move.distanceMeters,
                        distance: distance, origin: move.originRaw, source: move.transportModeSource.rawValue,
                        review: move.reviewState.rawValue, comment: move.comment ?? "",
                        route: move.manualRouteCoordinatesData
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private struct Quality {
        var visits = 0
        var moves = 0
        var open = 0
        var partialOverlaps = 0
        var containedStops = 0
        var selfLoops = 0
        var photoOnlyOverlaps = 0
    }

    private static func quality(of context: ModelContext) throws -> Quality {
        let visits = try context.liveVisits()
        let moves = try context.liveMoves()
        var result = Quality(visits: visits.count, moves: moves.count)
        result.open = visits.filter { $0.departureDate == nil }.count
        result.selfLoops = moves.filter { $0.startPlace?.id != nil && $0.startPlace?.id == $0.endPlace?.id }.count
        let closed = visits.filter { $0.departureDate != nil }
        for (a, b) in zip(closed, closed.dropFirst()) {
            guard let aEnd = a.departureDate, let bEnd = b.departureDate,
                  aEnd.timeIntervalSince(b.arrivalDate) > 60 else { continue }
            // Two stays both inferred from photos belong to the photo import, which the
            // rebuild never rewrites (it has no fixes for them). Counted apart, not as a
            // rebuild failure.
            if a.origin == .photoInferred, b.origin == .photoInferred {
                result.photoOnlyOverlaps += 1
                print("Overlap between photo-inferred stays (photo import's): \(a.arrivalDate)…\(aEnd) / \(b.arrivalDate)…\(bEnd)")
                continue
            }
            if bEnd <= aEnd {
                result.containedStops += 1
                print("Contained stop: \(a.origin.rawValue) \(a.arrivalDate)…\(aEnd) rv=\(a.reviewState.rawValue) holds \(b.origin.rawValue) \(b.arrivalDate)…\(bEnd)")
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
        let visits = try context.liveVisits()
        let moves = try context.liveMoves()
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

/// Answers motion questions from the trips already stored, so a rebuild on a store copy
/// sees roughly what the phone's Core Motion said: the mode of the trip that overlaps
/// most, and the measured steps of overlapping trips in proportion to the overlap.
private struct ReplayMotionClassifier: MotionClassifier {
    struct Trip { let start: Date; let end: Date; let mode: TransportMode; let steps: Int? }
    let trips: [Trip]

    @MainActor
    init(context: ModelContext) throws {
        trips = try context.fetch(FetchDescriptor<MoveSegment>()).map {
            Trip(start: $0.startDate, end: $0.endDate, mode: $0.transportMode, steps: $0.knownStepCount)
        }
    }

    private func overlap(_ trip: Trip, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(trip.end, end).timeIntervalSince(max(trip.start, start)))
    }

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        let best = trips.max { overlap($0, start, end) < overlap($1, start, end) }
        guard let best, overlap(best, start, end) > 0 else { return (.unknown, 0.3) }
        return (best.mode, 0.8)
    }

    func stepCount(start: Date, end: Date) async -> Int? {
        var total = 0.0
        var known = false
        for trip in trips where trip.end > trip.start {
            let shared = overlap(trip, start, end)
            guard shared > 0, let steps = trip.steps else { continue }
            known = true
            total += Double(steps) * shared / trip.end.timeIntervalSince(trip.start)
        }
        return known ? Int(total.rounded()) : nil
    }
}

private struct NoNamePlaceResolver: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        nil
    }
}

/// The rebuild retires stops and trips instead of deleting them while views may hold
/// them. Until the next launch purges them they are still rows in the store, and no
/// surface may show, count, upload, or attach to one.
@MainActor
final class RetiredRowVisibilityTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func visit(_ coordinate: CLLocationCoordinate2D, from arrival: Date, hours: Double) -> MockVisit {
        MockVisit(coordinate: coordinate, horizontalAccuracy: 20, arrivalDate: arrival, departureDate: arrival.addingTimeInterval(hours * 3_600))
    }

    func testARetiredStopAndTripAreInvisibleToEverySurface() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let base = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400)).addingTimeInterval(8 * 3_600)
        let home = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let ghostSpot = CLLocationCoordinate2D(latitude: 10.78, longitude: 106.70)
        let workSpot = CLLocationCoordinate2D(latitude: 10.80, longitude: 106.70)
        // Home 08–10, a drive to work 10–12, work 12–15; then a walk 15–16 to a stop 16–17
        // that the rebuild retires with its trip.
        let homeStop = try repository.addOrUpdateVisit(from: visit(home, from: base, hours: 2))
        let work = try repository.addOrUpdateVisit(from: visit(workSpot, from: base.addingTimeInterval(4 * 3_600), hours: 3))
        let ghost = try repository.addOrUpdateVisit(from: visit(ghostSpot, from: base.addingTimeInterval(8 * 3_600), hours: 1))
        let trip = try repository.upsertMove(startPlace: homeStop, endPlace: work, startDate: base.addingTimeInterval(2 * 3_600),
                                             endDate: base.addingTimeInterval(4 * 3_600), transportMode: .automotive,
                                             distanceMeters: 4_500, stepCount: 0, samples: [])
        let ghostTrip = try repository.upsertMove(startPlace: work, endPlace: ghost, startDate: base.addingTimeInterval(7 * 3_600),
                                                  endDate: base.addingTimeInterval(8 * 3_600), transportMode: .walking,
                                                  distanceMeters: 2_200, stepCount: 3_000, samples: [])
        let place = KnownPlace(name: "Desk", latitude: ghostSpot.latitude, longitude: ghostSpot.longitude, footprintRadius: 60)
        context.insert(place)
        try context.save()
        repository.retire(ghostTrip)
        repository.retire(ghost)
        // An edit on a stale view after the rebuild retired the stop.
        ghost.knownPlace = place
        try context.save()
        let ghostIDs: Set<UUID> = [ghost.id, ghostTrip.id]
        let liveVisitIDs: Set<UUID> = [homeStop.id, work.id]

        // Timeline: the day's own rows.
        let reader = ModelContext(container)
        let day = try XCTUnwrap(try reader.fetch(FetchDescriptor<DayTimeline>()).first { !$0.places.isEmpty })
        XCTAssertEqual(Set(day.places.map(\.id)), liveVisitIDs)
        XCTAssertEqual(day.moves.map(\.id), [trip.id])
        XCTAssertEqual(Set(homeStop.outgoingMoves.map(\.id)), [trip.id])

        // Map, named trips, and the "where was I" lookup.
        let range = DateInterval(start: base.addingTimeInterval(-3_600), end: base.addingTimeInterval(10 * 3_600))
        let readerRepository = SwiftDataTimelineRepository(modelContext: reader)
        XCTAssertEqual(Set(try readerRepository.visits(in: range).map(\.id)), liveVisitIDs)
        XCTAssertEqual(try readerRepository.moves(in: range, modes: nil).map(\.id), [trip.id])
        for hour in [7.5, 8.5] {
            switch try readerRepository.timelineItem(at: base.addingTimeInterval(hour * 3_600)) {
            case .visit(let found): XCTAssertFalse(ghostIDs.contains(found.id))
            case .move(let found, _, _): XCTAssertFalse(ghostIDs.contains(found.id))
            case .gap: break
            }
        }
        let missingCoverage = FileManager.default.temporaryDirectory.appendingPathComponent("no-coverage-\(UUID().uuidString).json")
        let index = try MapActivityIndexBuilder.build(container: container, undatedCoverageURL: missingCoverage)
        XCTAssertEqual(index.stays.count, 2)
        XCTAssertFalse(index.tracks.contains { ghostIDs.contains($0.id) })

        // Places: a place's stays.
        XCTAssertEqual(place.visits.map(\.id), [])

        // Insights and search read their own contexts.
        let insights = try InsightsSourceLoader.load(from: container)
        XCTAssertEqual(insights.days.flatMap(\.visits).count, 2)
        XCTAssertEqual(insights.days.flatMap(\.moves).count, 1)
        let corpus = try await MovesSearchCorpus.load(from: container)
        XCTAssertEqual(Set(corpus.days.flatMap(\.visits).map(\.id)), liveVisitIDs)
        XCTAssertEqual(corpus.days.flatMap(\.moves).map(\.id), [trip.id])

        // Uploads, Spotlight, and the widget.
        let uploadVisits = try reader.fetch(FetchDescriptor(predicate: LocationUploadFilter.visits(after: .distantPast, includingHistory: true)))
        let uploadMoves = try reader.fetch(FetchDescriptor(predicate: LocationUploadFilter.moves(after: .distantPast, includingHistory: true)))
        XCTAssertEqual(Set(uploadVisits.map(\.id)), liveVisitIDs)
        XCTAssertEqual(uploadMoves.map(\.id), [trip.id])
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<VisitPlace>.live()), 2)
        let widget = try XCTUnwrap(TimelineWidgetSnapshotPublisher.snapshot(forDayKey: day.dayKey, in: ModelContext(container)))
        XCTAssertEqual(widget.moveCount, 1)
        XCTAssertEqual(widget.totalDistanceMeters, 4_500, accuracy: 1)

        // The rows themselves are still there for whoever held them, until the purge.
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<VisitPlace>()), 3)
        XCTAssertEqual(try SwiftDataTimelineRepository.retiredRowCount(in: reader), 2)
    }

    /// The launch purge deletes exactly the rows the rebuild retired. A row iCloud is still
    /// bringing in can have no day for a while; it carries no retirement mark and stays.
    func testThePurgeRemovesExactlyTheRetiredRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let base = Date().addingTimeInterval(-2 * 86_400)
        let a = CLLocationCoordinate2D(latitude: 10.76, longitude: 106.70)
        let b = CLLocationCoordinate2D(latitude: 10.80, longitude: 106.70)
        let first = try repository.addOrUpdateVisit(from: visit(a, from: base, hours: 1))
        let second = try repository.addOrUpdateVisit(from: visit(b, from: base.addingTimeInterval(2 * 3_600), hours: 1))
        let kept = try repository.upsertMove(startPlace: first, endPlace: second, startDate: base.addingTimeInterval(3_600),
                                             endDate: base.addingTimeInterval(2 * 3_600), transportMode: .automotive,
                                             distanceMeters: 4_500, stepCount: 0, samples: [])
        let doomed = try repository.addOrUpdateVisit(from: visit(b, from: base.addingTimeInterval(5 * 3_600), hours: 1))
        let doomedTrip = try repository.upsertMove(startPlace: second, endPlace: doomed, startDate: base.addingTimeInterval(3 * 3_600),
                                                   endDate: base.addingTimeInterval(5 * 3_600), transportMode: .walking,
                                                   distanceMeters: 100, stepCount: 200, samples: [])
        // Arrived from iCloud before its day did: no day, but never retired.
        let arriving = VisitPlace(arrivalDate: base.addingTimeInterval(9 * 3_600), departureDate: nil,
                                  latitude: a.latitude, longitude: a.longitude, horizontalAccuracy: 20)
        context.insert(arriving)
        try context.save()
        repository.retire(doomedTrip)
        repository.retire(doomed)
        try context.save()

        XCTAssertEqual(try SwiftDataTimelineRepository.retiredRowCount(in: ModelContext(container)), 2)
        XCTAssertEqual(try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container), batchSize: 1), 2)

        let after = ModelContext(container)
        XCTAssertEqual(Set(try after.fetch(FetchDescriptor<VisitPlace>()).map(\.id)), [first.id, second.id, arriving.id])
        XCTAssertEqual(try after.fetch(FetchDescriptor<MoveSegment>()).map(\.id), [kept.id])
        XCTAssertEqual(try after.fetch(FetchDescriptor<MoveSegment>()).first?.endPlace?.id, second.id)
        XCTAssertEqual(try SwiftDataTimelineRepository.retiredRowCount(in: after), 0)
        XCTAssertEqual(try SwiftDataTimelineRepository.purgeRetiredRows(in: after), 0, "Nothing left to do")
    }

    /// A purge stopped part way (its background time ran out) leaves only retired rows,
    /// and the next launch finishes the job.
    func testAPurgeStoppedPartWayFinishesNextTime() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let base = Date().addingTimeInterval(-3 * 86_400)
        var retired: [VisitPlace] = []
        for index in 0..<6 {
            let coordinate = CLLocationCoordinate2D(latitude: 10.70 + Double(index) * 0.02, longitude: 106.70)
            retired.append(try repository.addOrUpdateVisit(from: visit(coordinate, from: base.addingTimeInterval(Double(index) * 3 * 3_600), hours: 1)))
        }
        try context.save()
        retired.forEach(repository.retire)
        try context.save()

        XCTAssertEqual(try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container), batchSize: 2, shouldStop: { true }), 2)
        XCTAssertEqual(try SwiftDataTimelineRepository.retiredRowCount(in: ModelContext(container)), 4)
        XCTAssertEqual(try SwiftDataTimelineRepository.purgeRetiredRows(in: ModelContext(container)), 4)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>()), 0)
    }
}
