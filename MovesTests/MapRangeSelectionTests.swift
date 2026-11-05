import Foundation
import SwiftData
import XCTest
@testable import Moves

final class MapRangeSelectionTests: XCTestCase {
    func testTodayPresetUsesStartOfDayAndEndsAtNextMidnight() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 3, 7, 15, 30, calendar: calendar)
        let selection = MapRangeSelection.preset(.today, now: now, calendar: calendar)

        XCTAssertEqual(selection.granularity, .day)
        XCTAssertEqual(calendar.component(.hour, from: selection.interval.start), 0)
        XCTAssertEqual(calendar.component(.day, from: selection.interval.start), 7)
        XCTAssertEqual(calendar.component(.day, from: selection.interval.end), 8)
        XCTAssertEqual(selection.focus, selection.interval)
        XCTAssertEqual(selection.title(now: now, calendar: calendar), "Today")
    }

    func testSteppingDayAcrossSpringForwardKeepsCalendarBoundaries() {
        let calendar = Self.newYorkCalendar()
        let march7 = Self.date(2026, 3, 7, 9, 0, calendar: calendar)
        let selection = MapRangeSelection.preset(.today, now: march7, calendar: calendar)
        let next = selection.stepped(by: 1, now: Self.date(2026, 3, 10, 12, 0, calendar: calendar), calendar: calendar)

        XCTAssertEqual(calendar.component(.day, from: next.interval.start), 8)
        XCTAssertEqual(calendar.component(.month, from: next.interval.start), 3)
        XCTAssertEqual(calendar.component(.day, from: next.interval.end), 9)
        XCTAssertEqual(next.interval.duration, 23 * 3_600, accuracy: 1)
    }

    func testSteppingDayAcrossFallBackIsTwentyFiveHours() {
        let calendar = Self.newYorkCalendar()
        let october31 = Self.date(2026, 10, 31, 12, 0, calendar: calendar)
        let selection = MapRangeSelection.period(
            containing: october31,
            granularity: .day,
            calendar: calendar
        )
        let next = MapRangeSelection(
            interval: selection,
            granularity: .day,
            focus: selection,
            isCustom: false
        ).stepped(by: 1, now: Self.date(2026, 11, 5, 12, 0, calendar: calendar), calendar: calendar)

        XCTAssertEqual(calendar.component(.day, from: next.interval.start), 1)
        XCTAssertEqual(calendar.component(.month, from: next.interval.start), 11)
        XCTAssertEqual(next.interval.duration, 25 * 3_600, accuracy: 1)
    }

    func testSteppingMonthFromJanuaryLandsOnFebruaryFirst() {
        let calendar = Self.newYorkCalendar()
        let january = MapRangeSelection.preset(
            .thisMonth,
            now: Self.date(2026, 1, 31, 18, 0, calendar: calendar),
            calendar: calendar
        )
        let february = january.stepped(
            by: 1,
            now: Self.date(2026, 6, 1, 12, 0, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.month, from: february.interval.start), 2)
        XCTAssertEqual(calendar.component(.day, from: february.interval.start), 1)
        XCTAssertEqual(calendar.component(.month, from: february.interval.end), 3)
        XCTAssertEqual(calendar.component(.day, from: february.interval.end), 1)
    }

    func testSteppingMonthFromMarchThirtyFirstDoesNotSkipApril() {
        let calendar = Self.newYorkCalendar()
        let march = MapRangeSelection(
            interval: MapRangeSelection.period(
                containing: Self.date(2026, 3, 31, 8, 0, calendar: calendar),
                granularity: .month,
                calendar: calendar
            ),
            granularity: .month,
            focus: MapRangeSelection.period(
                containing: Self.date(2026, 3, 31, 8, 0, calendar: calendar),
                granularity: .month,
                calendar: calendar
            ),
            isCustom: false
        )
        let april = march.stepped(
            by: 1,
            now: Self.date(2026, 12, 1, 12, 0, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.month, from: april.interval.start), 4)
        XCTAssertEqual(calendar.component(.day, from: april.interval.start), 1)
        XCTAssertEqual(calendar.component(.month, from: april.interval.end), 5)
    }

    func testCannotStepTodayForward() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 15, 0, calendar: calendar)
        let today = MapRangeSelection.preset(.today, now: now, calendar: calendar)
        XCTAssertFalse(today.canStep(by: 1, now: now, calendar: calendar))
        XCTAssertTrue(today.canStep(by: -1, now: now, calendar: calendar))
        XCTAssertEqual(today.stepped(by: 1, now: now, calendar: calendar).interval.start, today.interval.start)
    }

    func testCustomAfternoonKeepsTimesAndDayGrain() {
        let calendar = Self.newYorkCalendar()
        let start = Self.date(2026, 9, 19, 13, 0, calendar: calendar)
        let end = Self.date(2026, 9, 19, 18, 0, calendar: calendar)
        let selection = MapRangeSelection.custom(start: start, end: end, calendar: calendar)

        XCTAssertEqual(selection.granularity, .day)
        XCTAssertTrue(selection.isCustom)
        XCTAssertEqual(selection.interval.start, start)
        XCTAssertEqual(selection.interval.end, end)
        let title = selection.title(now: end, calendar: calendar)
        XCTAssertFalse(title.localizedCaseInsensitiveContains("today"))
        XCTAssertTrue(title.contains("Sat") || title.contains("19"))
        XCTAssertEqual(selection.focus.duration, 5 * 3_600, accuracy: 1)
    }

    func testLastWeekPresetIsThePreviousCalendarWeek() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 10, 0, calendar: calendar)
        let lastWeek = MapRangeSelection.preset(.lastWeek, now: now, calendar: calendar)
        let thisWeek = MapRangeSelection.preset(.thisWeek, now: now, calendar: calendar)

        XCTAssertEqual(lastWeek.granularity, .week)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: lastWeek.interval.start, to: thisWeek.interval.start).day,
            7
        )
        XCTAssertEqual(lastWeek.title(now: now, calendar: calendar), "Last week")
    }

    func testScrubberFocusClampsToInterval() {
        let calendar = Self.newYorkCalendar()
        let today = MapRangeSelection.preset(
            .today,
            now: Self.date(2026, 9, 20, 12, 0, calendar: calendar),
            calendar: calendar
        )
        let expanded = today.withFocus(
            DateInterval(
                start: today.interval.start.addingTimeInterval(-3_600),
                end: today.interval.end.addingTimeInterval(3_600)
            )
        )
        XCTAssertEqual(expanded.focus.start, today.interval.start)
        XCTAssertEqual(expanded.focus.end, today.interval.end)
    }

    func testMapDeepLinkParsesFromAndTo() throws {
        let url = try XCTUnwrap(
            URL(string: "moves://map?from=2026-09-20T13:00:00Z&to=2026-09-20T18:00:00Z")
        )
        let interval = try XCTUnwrap(MapDeepLink.interval(from: url))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(interval.start, formatter.date(from: "2026-09-20T13:00:00Z"))
        XCTAssertEqual(interval.end, formatter.date(from: "2026-09-20T18:00:00Z"))
    }

    func testCustomPickersStayValidWhenTheFocusStartsInTheFuture() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 15, 0, calendar: calendar)
        let today = MapRangeSelection.preset(.today, now: now, calendar: calendar)
        let cropped = today.withFocus(
            DateInterval(start: now.addingTimeInterval(3_600), end: today.interval.end)
        )
        let linked = MapRangeSelection.custom(
            start: Self.date(2030, 1, 1, 0, 0, calendar: calendar),
            end: Self.date(2030, 1, 2, 0, 0, calendar: calendar),
            calendar: calendar
        )

        for selection in [cropped, linked] {
            let dates = selection.customPickerDates(now: now)
            XCTAssertLessThanOrEqual(dates.start, now)
            XCTAssertLessThanOrEqual(dates.start, dates.end)
            XCTAssertLessThanOrEqual(dates.end, now.addingTimeInterval(60))

            // Building a closed range traps when its bounds invert.
            let range = MapRangeSelection.customEndRange(start: selection.focus.start, now: now)
            XCTAssertEqual(range.upperBound, now.addingTimeInterval(60))
        }
    }

    func testAllTimeRunsFromTheFirstRecordedDayThroughToday() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 15, 0, calendar: calendar)
        let firstRecorded = Self.date(2025, 3, 14, 9, 30, calendar: calendar)
        let allTime = MapRangeSelection.preset(.allTime, now: now, calendar: calendar, firstRecorded: firstRecorded)

        XCTAssertEqual(allTime.interval.start, calendar.startOfDay(for: firstRecorded))
        XCTAssertEqual(calendar.component(.day, from: allTime.interval.end), 21)
        XCTAssertEqual(allTime.matchingPreset(now: now, calendar: calendar), .allTime)
        XCTAssertEqual(allTime.title(now: now, calendar: calendar), "All time")

        let buckets = allTime.scrubberBuckets(calendar: calendar)
        XCTAssertGreaterThan(buckets.count, 1)
        XCTAssertEqual(buckets.first?.start, allTime.interval.start)
        XCTAssertEqual(buckets.last?.end, allTime.interval.end)
    }

    func testAllTimeWithNothingRecordedIsJustToday() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 15, 0, calendar: calendar)
        let allTime = MapRangeSelection.preset(.allTime, now: now, calendar: calendar)

        XCTAssertEqual(allTime.interval.start, calendar.startOfDay(for: now))
        XCTAssertEqual(allTime.granularity, .allTime)
    }

    func testPinchingIntoAllTimeStaysInsideTheRecordedHistory() {
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 15, 0, calendar: calendar)
        let firstRecorded = Self.date(2025, 3, 14, 9, 30, calendar: calendar)
        let allTime = MapRangeSelection.preset(.allTime, now: now, calendar: calendar, firstRecorded: firstRecorded)
        let midpoint = allTime.focus.start.addingTimeInterval(allTime.focus.duration / 2)

        let year = allTime.switchingGranularity(to: .year, around: midpoint, now: now, calendar: calendar)

        XCTAssertEqual(calendar.component(.year, from: year.interval.start), 2025)
    }

    @MainActor
    func testHistogramKeepsBarsOutsideTheCroppedFocus() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let calendar = Self.newYorkCalendar()
        let now = Self.date(2026, 9, 20, 20, 0, calendar: calendar)
        context.insert(
            MoveSegment(
                dedupeKey: "morning",
                startDate: Self.date(2026, 9, 20, 8, 0, calendar: calendar),
                endDate: Self.date(2026, 9, 20, 9, 0, calendar: calendar),
                transportMode: .walking,
                distanceMeters: 1_000,
                stepCount: nil
            )
        )
        context.insert(
            MoveSegment(
                dedupeKey: "evening",
                startDate: Self.date(2026, 9, 20, 18, 0, calendar: calendar),
                endDate: Self.date(2026, 9, 20, 19, 0, calendar: calendar),
                transportMode: .cycling,
                distanceMeters: 5_000,
                stepCount: nil
            )
        )
        try context.save()

        let today = MapRangeSelection.preset(.today, now: now, calendar: calendar)
        let evening = today.withFocus(
            DateInterval(start: Self.date(2026, 9, 20, 17, 0, calendar: calendar), end: today.interval.end)
        )
        let loader = MapWindowLoader()
        loader.refreshHistogram(selection: evening, modelContext: context, calendar: calendar)

        func minutes(atHour hour: Int, in buckets: [MapHistogramBucket]) -> Double {
            buckets.first { calendar.component(.hour, from: $0.interval.start) == hour }?.movingMinutes ?? 0
        }
        XCTAssertEqual(minutes(atHour: 8, in: loader.histogram), 60, accuracy: 1)
        XCTAssertEqual(minutes(atHour: 18, in: loader.histogram), 60, accuracy: 1)

        let noWalking = loader.filteredBuckets(hiding: [.walking], selection: evening, calendar: calendar)
        XCTAssertEqual(minutes(atHour: 8, in: noWalking), 0, accuracy: 0.01)
        XCTAssertEqual(minutes(atHour: 18, in: noWalking), 60, accuracy: 1)
    }

    private static func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        return calendar
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
