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
