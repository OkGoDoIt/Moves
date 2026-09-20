import Foundation
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
