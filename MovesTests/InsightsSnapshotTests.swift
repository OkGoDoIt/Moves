import Observation
import SwiftData
import XCTest
@testable import Moves

final class InsightsSnapshotTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    func testActiveDayRequires500Meters() {
        XCTAssertFalse(InsightsSnapshotBuilder.isActiveDay(distanceMeters: 499))
        XCTAssertTrue(InsightsSnapshotBuilder.isActiveDay(distanceMeters: 500))
        XCTAssertTrue(InsightsSnapshotBuilder.isActiveDay(distanceMeters: 1_200))
    }

    func testStreaksCountConsecutiveActiveDaysAndResetOnAGap() {
        let days = [
            day(2026, 9, 14, distance: 600),
            day(2026, 9, 15, distance: 800),
            day(2026, 9, 16, distance: 100),
            day(2026, 9, 17, distance: 900)
        ]
        let now = date(2026, 9, 17, 18, 0)
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.longestStreakDays, 2)
        XCTAssertEqual(snapshot.currentStreakDays, 1)
        XCTAssertTrue(snapshot.showsCurrentStreak)
        XCTAssertEqual(snapshot.activeDayCount, 3)
    }

    func testCurrentStreakIsZeroWhenTodayIsInactive() {
        let days = [
            day(2026, 9, 15, distance: 800),
            day(2026, 9, 16, distance: 800),
            day(2026, 9, 17, distance: 100)
        ]
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: date(2026, 9, 17, 18, 0),
            calendar: calendar
        )
        XCTAssertEqual(snapshot.currentStreakDays, 0)
        XCTAssertEqual(snapshot.longestStreakDays, 2)
    }

    func testYearOverYearDistanceDeltaUsesThePreviousCalendarYear() {
        let days = [
            day(2025, 6, 1, distance: 1_000, mode: .walking, duration: 1_200),
            day(2026, 6, 1, distance: 2_500, mode: .walking, duration: 2_400)
        ]
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: date(2026, 9, 20, 12, 0),
            calendar: calendar
        )
        let walking = try! XCTUnwrap(snapshot.modes.first { $0.mode == .walking })
        XCTAssertEqual(walking.distanceMeters, 2_500, accuracy: 0.1)
        XCTAssertEqual(walking.previousDistanceMeters, 1_000, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(walking.distanceDeltaFraction), 1.5, accuracy: 0.01)
        XCTAssertEqual(walking.duration, 2_400, accuracy: 0.1)
        XCTAssertEqual(walking.previousDuration, 1_200, accuracy: 0.1)
    }

    func testYearBoundaryDoesNotLeakDecemberIntoJanuary() {
        let days = [
            day(2025, 12, 31, distance: 4_000, mode: .cycling),
            day(2026, 1, 1, distance: 500, mode: .cycling)
        ]
        // A finished year compares with the whole year before it.
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: date(2027, 1, 2, 8, 0),
            calendar: calendar
        )
        let cycling = try! XCTUnwrap(snapshot.modes.first { $0.mode == .cycling })
        XCTAssertEqual(cycling.distanceMeters, 500, accuracy: 0.1)
        XCTAssertEqual(cycling.previousDistanceMeters, 4_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.totalDistanceMeters, 500, accuracy: 0.1)
    }

    func testCountriesAndCitiesCountUniqueNamedPlaces() {
        let days = [
            InsightsDayRecord(
                dayStart: date(2026, 4, 1, 0, 0),
                moves: [
                    InsightsMoveRecord(
                        startDate: date(2026, 4, 1, 8, 0),
                        endDate: date(2026, 4, 1, 9, 0),
                        duration: 3_600,
                        distanceMeters: 2_000,
                        mode: .walking
                    )
                ],
                visits: [
                    InsightsVisitRecord(countryCode: "NL", locality: "Amsterdam"),
                    InsightsVisitRecord(countryCode: "NL", locality: "Amsterdam"),
                    InsightsVisitRecord(countryCode: "FR", locality: "Paris")
                ]
            )
        ]
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: date(2026, 9, 20, 12, 0),
            calendar: calendar
        )
        XCTAssertEqual(snapshot.geography.countries.map(\.code), ["NL", "FR"])
        XCTAssertEqual(snapshot.geography.countries.first?.visitCount, 2)
        XCTAssertEqual(snapshot.geography.countries.flatMap(\.cities).map(\.name), ["Amsterdam", "Paris"])
        XCTAssertEqual(snapshot.geography.countries.first?.flagEmoji, "🇳🇱")
    }

    func testHourHistogramSplitsAMoveAcrossHours() {
        var hours = Array(repeating: 0.0, count: 24)
        let move = InsightsMoveRecord(
            startDate: date(2026, 9, 16, 14, 30),
            endDate: date(2026, 9, 16, 16, 0),
            duration: 90 * 60,
            distanceMeters: 4_000,
            mode: .cycling
        )
        InsightsSnapshotBuilder.add(move, toHours: &hours, calendar: calendar)
        XCTAssertEqual(hours[14], 30 * 60, accuracy: 1)
        XCTAssertEqual(hours[15], 60 * 60, accuracy: 1)
        XCTAssertEqual(hours[16], 0, accuracy: 1)
    }

    func testFiveYearRecomputeStaysUnder300msAndCacheHits() {
        let days = makeYears(5)
        let now = date(2026, 9, 20, 12, 0)
        let start = CFAbsoluteTimeGetCurrent()
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2024),
            now: now,
            calendar: calendar,
            builtAt: now
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(
            elapsed,
            InsightsComputeCache.recomputeBudget,
            "5-year recompute took \(elapsed)s; persist an InsightsYearCache if this exceeds 300 ms."
        )
        XCTAssertFalse(snapshot.modes.isEmpty)
        XCTAssertGreaterThan(snapshot.calendarDays.count, 300)

        var storage: [String: InsightsSnapshot] = [:]
        let first = InsightsComputeCache.snapshot(key: "2024", storage: &storage) {
            InsightsSnapshotBuilder.build(
                days: days,
                period: .year(2024),
                now: now,
                calendar: calendar,
                builtAt: now
            )
        }
        let cacheStart = CFAbsoluteTimeGetCurrent()
        let second = InsightsComputeCache.snapshot(key: "2024", storage: &storage) {
            XCTFail("Cache missed; compute should not run again.")
            return first
        }
        let cacheElapsed = CFAbsoluteTimeGetCurrent() - cacheStart
        XCTAssertEqual(first.builtAt, second.builtAt)
        XCTAssertLessThan(cacheElapsed, 0.01)
        XCTAssertLessThan(cacheElapsed, elapsed)
    }

    func testCurrentStreakRunsThroughJanuaryFirst() {
        let days = [
            day(2026, 12, 30, distance: 800),
            day(2026, 12, 31, distance: 800),
            day(2027, 1, 1, distance: 800)
        ]
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2027),
            now: date(2027, 1, 1, 18, 0),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreakDays, 3)
        XCTAssertEqual(snapshot.longestStreakDays, 3)
        XCTAssertEqual(snapshot.activeDayCount, 1)
    }

    @MainActor
    func testEditingAMoveReplacesTheCachedSnapshot() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let now = date(2026, 9, 17, 18, 0)
        let timeline = DayTimeline(dayStart: now)
        context.insert(timeline)
        let move = MoveSegment(
            dedupeKey: "edit-me",
            startDate: now.addingTimeInterval(-3_600),
            endDate: now,
            transportMode: .walking,
            distanceMeters: 1_000,
            stepCount: nil
        )
        move.dayTimeline = timeline
        context.insert(move)
        try context.save()

        let store = InsightsStore(now: now, calendar: calendar)
        store.reload(container: container, now: now, calendar: calendar)
        try await waitUntilSettled(store)
        XCTAssertEqual(store.snapshot.modes.map(\.modeRaw), [TransportMode.walking.rawValue])

        // Same counts as before: only the rows can tell these apart.
        move.transportMode = .cycling
        try context.save()
        store.reload(container: container, now: now, calendar: calendar)
        try await waitUntilSettled(store)
        XCTAssertEqual(store.snapshot.modes.map(\.modeRaw), [TransportMode.cycling.rawValue])

        // A save that changes nothing Insights reads (the place-name backfill saves every
        // couple of seconds) must not hand the pages a new snapshot: each one re-renders
        // the Countries and Cities lists and redraws the world map.
        var snapshotWritten = false
        withObservationTracking {
            _ = store.snapshot
            _ = store.hasRecordedActivity
            _ = store.hasLoaded
        } onChange: {
            snapshotWritten = true
        }
        store.reload(container: container, now: now, calendar: calendar)
        try await Task.sleep(for: .milliseconds(20))
        try await waitUntilSettled(store)
        XCTAssertFalse(snapshotWritten)
        XCTAssertEqual(store.snapshot.modes.map(\.modeRaw), [TransportMode.cycling.rawValue])
    }

    /// Field crash (build 46): `MoveSegment.startPlace` aborted inside `InsightsDayRecord.init`
    /// because the reconciler deleted moves on its own context while the main context still
    /// listed them. The reload must read committed rows on its own context instead.
    @MainActor
    func testReloadSurvivesMovesDeletedOnAnotherContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                url: directory.appendingPathComponent("default.store"),
                cloudKitDatabase: .none
            )
        )
        let now = date(2026, 9, 17, 18, 0)
        let seed = ModelContext(container)
        for dayIndex in 0..<30 {
            let dayStart = calendar.date(byAdding: .day, value: -dayIndex, to: calendar.startOfDay(for: now))!
            let timeline = DayTimeline(dayStart: dayStart)
            seed.insert(timeline)
            var previous: VisitPlace?
            for index in 0..<4 {
                let arrival = dayStart.addingTimeInterval(Double(8 + index * 3) * 3_600)
                let place = VisitPlace(arrivalDate: arrival, departureDate: arrival.addingTimeInterval(3_600),
                                       latitude: 52.37, longitude: 4.89 + Double(index) * 0.01, horizontalAccuracy: 20)
                place.countryCode = "NL"
                place.locality = "Amsterdam"
                place.dayTimeline = timeline
                seed.insert(place)
                if let previous {
                    let move = MoveSegment(dedupeKey: UUID().uuidString, startDate: previous.departureDate!,
                                           endDate: arrival, transportMode: .walking, distanceMeters: 1_000, stepCount: nil)
                    move.startPlace = previous
                    move.endPlace = place
                    move.dayTimeline = timeline
                    seed.insert(move)
                }
                previous = place
            }
        }
        try seed.save()

        // The view's side: the main context holds every day and move, as `@Query` did.
        let main = container.mainContext
        let heldDays = try main.fetch(FetchDescriptor<DayTimeline>())
        let heldMoveCount = heldDays.reduce(0) { $0 + $1.moves.count }
        XCTAssertEqual(heldMoveCount, 30 * 3)

        // The reconciler's side: delete half the moves on another context and save.
        let writer = ModelContext(container)
        let doomed = try writer.fetch(FetchDescriptor<MoveSegment>()).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        for move in doomed { writer.delete(move) }
        try writer.save()
        let surviving = 30 * 3 - doomed.count

        let store = InsightsStore(now: now, calendar: calendar)
        store.reload(container: container, now: now, calendar: calendar)
        try await waitUntilSettled(store)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertTrue(store.hasRecordedActivity)
        let walking = try XCTUnwrap(store.snapshot.modes.first { $0.mode == .walking })
        XCTAssertEqual(walking.distanceMeters, Double(surviving) * 1_000, accuracy: 0.5)

        // And while a writer keeps deleting, reloads keep finishing.
        let stress = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            for _ in 0..<20 where !Task.isCancelled {
                let moves = (try? context.fetch(FetchDescriptor<MoveSegment>())) ?? []
                for move in moves.shuffled().prefix(3) { context.delete(move) }
                try? context.save()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        for _ in 0..<10 {
            store.reload(container: container, now: now, calendar: calendar)
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await stress.value
        store.reload(container: container, now: now, calendar: calendar)
        try await waitUntilSettled(store)
        let remaining = try ModelContext(container).fetchCount(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(
            store.snapshot.modes.first { $0.mode == .walking }?.distanceMeters ?? 0,
            Double(remaining) * 1_000,
            accuracy: 0.5
        )
    }

    /// What the Insights reload relies on, measured rather than assumed: `ModelContext.didSave`
    /// is posted after the save has committed, so a fresh context opened in its handler reads
    /// the new rows, while the main context still lists the deleted ones until it merges.
    @MainActor
    func testDidSaveFiresAfterCommitWhileMainContextIsStillStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: directory.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        )
        let seed = ModelContext(container)
        let timeline = DayTimeline(dayStart: date(2026, 9, 17, 12, 0))
        seed.insert(timeline)
        for index in 0..<4 {
            let move = MoveSegment(dedupeKey: "m\(index)", startDate: date(2026, 9, 17, 8 + index, 0),
                                   endDate: date(2026, 9, 17, 8 + index, 30), transportMode: .walking,
                                   distanceMeters: 100, stepCount: nil)
            move.dayTimeline = timeline
            seed.insert(move)
        }
        try seed.save()

        let mainDay = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<DayTimeline>()).first)
        XCTAssertEqual(mainDay.moves.count, 4)

        var countSeenInHandler: Int?
        let writer = ModelContext(container)
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: writer, queue: nil) { _ in
            countSeenInHandler = try? ModelContext(container).fetchCount(FetchDescriptor<MoveSegment>())
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for move in try writer.fetch(FetchDescriptor<MoveSegment>()).prefix(2) { writer.delete(move) }
        try writer.save()

        XCTAssertEqual(countSeenInHandler, 2, "A context opened from didSave reads the committed delete")
        // Same turn of the main run loop: the main context has not merged, and its
        // relationship still lists rows that are gone. Reading one of those would abort.
        XCTAssertEqual(mainDay.moves.count, 4, "The main context is stale until it merges")
    }

    @MainActor
    private func waitUntilSettled(_ store: InsightsStore) async throws {
        var attempts = 0
        while store.isComputing, attempts < 500 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testPastYearHidesCurrentStreak() {
        let days = [day(2024, 12, 31, distance: 800)]
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2024),
            now: date(2026, 9, 20, 12, 0),
            calendar: calendar
        )
        XCTAssertFalse(snapshot.showsCurrentStreak)
        XCTAssertEqual(snapshot.longestStreakDays, 1)
    }

    // MARK: - Ground, air, and the rows adding up

    func testFlightsAreStatedApartAndEveryTripLandsInARow() throws {
        let start = date(2026, 5, 10, 0, 0)
        let days = [
            InsightsDayRecord(dayStart: start, moves: [
                move(2026, 5, 10, 8, distance: 2_000, mode: .walking, duration: 1_800),
                move(2026, 5, 10, 10, distance: 1_000_000, mode: .plane, duration: 7_200),
                move(2026, 5, 10, 14, distance: 500, mode: .unknown, duration: 600),
                move(2026, 5, 10, 15, distance: 100, mode: .stationary, duration: 300)
            ]),
            day(2026, 6, 2, distance: 8_000, mode: .automotive, duration: 900)
        ]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)

        XCTAssertEqual(snapshot.airDistanceMeters, 1_000_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.airMovingDuration, 7_200, accuracy: 0.1)
        XCTAssertEqual(snapshot.groundDistanceMeters, 2_000 + 500 + 100 + 8_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.groundMovingDuration, 1_800 + 600 + 300 + 900, accuracy: 0.1)
        XCTAssertEqual(snapshot.groundDistanceMeters + snapshot.airDistanceMeters, snapshot.totalDistanceMeters, accuracy: 0.1)

        // Rows add up to the totals; trips with no mode (and stationary ones) become Other.
        XCTAssertEqual(snapshot.modes.map(\.mode), [.walking, .automotive, .unknown, .plane])
        XCTAssertEqual(snapshot.modes.reduce(0) { $0 + $1.distanceMeters }, snapshot.totalDistanceMeters, accuracy: 0.1)
        XCTAssertEqual(snapshot.modes.first { $0.mode == .unknown }?.distanceMeters ?? 0, 600, accuracy: 0.1)

        // The monthly chart, the hour chart, and the calendar shading leave the flight out.
        let may = try XCTUnwrap(snapshot.monthlyDistance.first { $0.id == "2026-05" })
        XCTAssertEqual(may.distanceMeters, 2_600, accuracy: 0.1)
        XCTAssertEqual(snapshot.hourDurations.reduce(0, +), snapshot.groundMovingDuration, accuracy: 1)
        XCTAssertEqual(snapshot.hourDurations[10], 0, accuracy: 1)
        let calendarDay = try XCTUnwrap(snapshot.calendarDays.first { $0.dayKey == "2026-05-10" })
        XCTAssertEqual(calendarDay.distanceMeters, 2_600, accuracy: 0.1)
    }

    func testADayWithOnlyAFlightStillCountsAsActive() {
        let days = [
            InsightsDayRecord(dayStart: date(2026, 3, 1, 0, 0), moves: [
                move(2026, 3, 1, 9, distance: 900_000, mode: .plane, duration: 6_000)
            ])
        ]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)
        XCTAssertEqual(snapshot.activeDayCount, 1)
        XCTAssertEqual(snapshot.groundDistanceMeters, 0, accuracy: 0.1)
        XCTAssertTrue(snapshot.calendarDays.first { $0.dayKey == "2026-03-01" }?.isActive ?? false)
    }

    // MARK: - Comparisons

    func testNoEarlierYearMeansNoComparison() {
        let days = [day(2026, 4, 1, distance: 3_000, mode: .walking)]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)
        XCTAssertNil(snapshot.comparison)
        XCTAssertNil(snapshot.modes.first?.distanceDeltaFraction)
    }

    func testAModeNewThisYearHasNoDeltaWhileOthersCompare() throws {
        let days = [
            day(2025, 4, 1, distance: 2_000, mode: .walking),
            day(2026, 4, 1, distance: 3_000, mode: .walking),
            day(2026, 4, 2, distance: 9_000, mode: .cycling)
        ]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)
        let comparison = try XCTUnwrap(snapshot.comparison)
        XCTAssertEqual(comparison.year, 2025)
        XCTAssertTrue(comparison.isSameDates)
        XCTAssertEqual(try XCTUnwrap(comparison.deltaFraction(current: snapshot.groundDistanceMeters)), 5.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.modes.first { $0.mode == .walking }?.distanceDeltaFraction), 0.5, accuracy: 0.001)
        XCTAssertNil(snapshot.modes.first { $0.mode == .cycling }?.distanceDeltaFraction)
    }

    func testYearInProgressComparesWithTheSameDatesLastYear() throws {
        let days = [
            day(2025, 2, 10, distance: 1_000, mode: .walking),
            day(2025, 6, 10, distance: 50_000, mode: .walking),
            day(2026, 2, 12, distance: 1_500, mode: .walking)
        ]
        let inProgress = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 3, 1, 12, 0), calendar: calendar)
        XCTAssertEqual(inProgress.modes.first?.previousDistanceMeters ?? 0, 1_000, accuracy: 0.1)
        XCTAssertEqual(inProgress.comparison?.groundDistanceMeters ?? 0, 1_000, accuracy: 0.1)

        // Once the year is over it is measured against all of the year before.
        let finished = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2027, 3, 1, 12, 0), calendar: calendar)
        XCTAssertEqual(finished.modes.first?.previousDistanceMeters ?? 0, 51_000, accuracy: 0.1)
        XCTAssertEqual(finished.comparison?.isSameDates, false)

        // All has nothing earlier to compare with.
        let all = InsightsSnapshotBuilder.build(days: days, period: .all, now: date(2026, 3, 1, 12, 0), calendar: calendar)
        XCTAssertNil(all.comparison)
    }

    func testComparisonLeavesFlightsOutOfTheGroundBaseline() throws {
        let days = [
            InsightsDayRecord(dayStart: date(2025, 3, 1, 0, 0), moves: [
                move(2025, 3, 1, 8, distance: 4_000, mode: .walking, duration: 3_000),
                move(2025, 3, 1, 12, distance: 800_000, mode: .plane, duration: 5_000)
            ]),
            day(2026, 3, 1, distance: 6_000, mode: .walking)
        ]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)
        XCTAssertEqual(snapshot.comparison?.groundDistanceMeters ?? 0, 4_000, accuracy: 0.1)
    }

    // MARK: - Places, days, and Health keys

    /// Demo history showed 14 countries and 2 cities while geocoding caught up. Stays
    /// without names now get both from the bundled borders and cities.
    func testStaysWithoutNamesGetCountryAndCityOffline() {
        var unnamedParis = InsightsVisitRecord()
        unnamedParis.latitude = 48.8584
        unnamedParis.longitude = 2.2945
        let days = [
            InsightsDayRecord(
                dayStart: date(2026, 4, 1, 0, 0),
                moves: [move(2026, 4, 1, 9, distance: 1_000, mode: .walking, duration: 900)],
                visits: [
                    InsightsVisitRecord(countryCode: "NL", locality: "Amsterdam"),
                    InsightsVisitRecord(countryCode: "NL", locality: " amsterdam "),
                    InsightsVisitRecord(countryCode: "NL", locality: "Utrecht"),
                    unnamedParis
                ]
            )
        ]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 9, 1, 12, 0), calendar: calendar)
        let cities = snapshot.geography.countries.flatMap(\.cities)
        XCTAssertEqual(cities.map(\.name).sorted(), ["Amsterdam", "Paris", "Utrecht"])
        XCTAssertEqual(cities.first { $0.name == "Amsterdam" }?.visitCount, 2)
        XCTAssertEqual(snapshot.geography.countries.map(\.code), ["NL", "FR"])
    }

    func testPeriodDayKeysRunFromJanuaryFirstThroughToday() {
        let days = [day(2026, 1, 5, distance: 900)]
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2026), now: date(2026, 1, 10, 18, 0), calendar: calendar)
        XCTAssertEqual(snapshot.periodDayKeys.first, "2026-01-01")
        XCTAssertEqual(snapshot.periodDayKeys.last, "2026-01-10")
        XCTAssertEqual(snapshot.periodDayKeys.count, 10)

        let past = InsightsSnapshotBuilder.build(days: days, period: .year(2025), now: date(2026, 1, 10, 18, 0), calendar: calendar)
        XCTAssertEqual(past.periodDayKeys.count, 365)
        XCTAssertTrue(past.isEmptyPeriod)
    }

    func testPerModeTotalsMatchTheSourceRecords() {
        let days = makeYears(2)
        let snapshot = InsightsSnapshotBuilder.build(days: days, period: .year(2025), now: date(2026, 9, 20, 12, 0), calendar: calendar)
        for mode in snapshot.modes {
            let expected = days
                .filter { calendar.component(.year, from: $0.dayStart) == 2025 }
                .flatMap(\.moves)
                .filter { $0.mode == mode.mode }
            XCTAssertEqual(mode.distanceMeters, expected.reduce(0) { $0 + $1.distanceMeters }, accuracy: 0.5, "\(mode.modeRaw)")
            XCTAssertEqual(mode.duration, expected.reduce(0) { $0 + $1.duration }, accuracy: 0.5, "\(mode.modeRaw)")
        }
        let activeExpected = days
            .filter { calendar.component(.year, from: $0.dayStart) == 2025 }
            .filter { $0.moves.reduce(0) { $0 + $1.distanceMeters } >= 500 }
            .count
        XCTAssertEqual(snapshot.activeDayCount, activeExpected)
        // No flights means exactly nothing by air, not a rounding remainder.
        XCTAssertEqual(snapshot.airDistanceMeters, 0)
        XCTAssertEqual(snapshot.airMovingDuration, 0)
    }

    // MARK: - Fixtures

    private func move(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int,
        distance: Double, mode: TransportMode, duration: TimeInterval
    ) -> InsightsMoveRecord {
        let start = date(year, month, day, hour, 0)
        return InsightsMoveRecord(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            duration: duration,
            distanceMeters: distance,
            mode: mode
        )
    }

    private func day(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        distance: Double,
        mode: TransportMode = .walking,
        duration: TimeInterval = 1_800
    ) -> InsightsDayRecord {
        let start = date(year, month, day, 0, 0)
        let moveStart = date(year, month, day, 8, 0)
        return InsightsDayRecord(
            dayStart: start,
            moves: [
                InsightsMoveRecord(
                    startDate: moveStart,
                    endDate: moveStart.addingTimeInterval(duration),
                    duration: duration,
                    distanceMeters: distance,
                    mode: mode
                )
            ]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeYears(_ count: Int) -> [InsightsDayRecord] {
        let endYear = 2026
        let startYear = endYear - count + 1
        var days: [InsightsDayRecord] = []
        days.reserveCapacity(count * 365)
        for year in startYear...endYear {
            for month in 1...12 {
                for dayIndex in 1...28 {
                    let distance: Double = (dayIndex % 2 == 0) ? 800 : 200
                    days.append(day(year, month, dayIndex, distance: distance, mode: .walking))
                    if dayIndex % 5 == 0 {
                        var extra = day(year, month, dayIndex, distance: 3_000, mode: .cycling, duration: 2_400)
                        extra.moves.append(
                            InsightsMoveRecord(
                                startDate: date(year, month, dayIndex, 18, 0),
                                endDate: date(year, month, dayIndex, 18, 40),
                                duration: 2_400,
                                distanceMeters: 12_000,
                                mode: .automotive
                            )
                        )
                        days[days.count - 1] = extra
                    }
                }
            }
        }
        return days
    }
}
