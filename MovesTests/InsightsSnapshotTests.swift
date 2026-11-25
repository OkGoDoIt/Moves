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
        let snapshot = InsightsSnapshotBuilder.build(
            days: days,
            period: .year(2026),
            now: date(2026, 1, 2, 8, 0),
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
        XCTAssertEqual(snapshot.countries.map(\.countryCode), ["NL", "FR"])
        XCTAssertEqual(snapshot.countries.first?.visitCount, 2)
        XCTAssertEqual(snapshot.cities.map(\.name), ["Amsterdam", "Paris"])
        XCTAssertEqual(snapshot.countries.first?.flagEmoji, "🇳🇱")
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

    // MARK: - Fixtures

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
