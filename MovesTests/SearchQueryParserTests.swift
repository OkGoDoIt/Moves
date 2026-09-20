import XCTest
@testable import Moves

final class SearchQueryParserTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Wednesday 16 September 2026, 16:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 16, minute: 0))!
    }

    func testLastTuesdayResolvesToThePreviousTuesday() {
        let parsed = SearchQueryParser.parse("last Tuesday", now: now, calendar: calendar)
        XCTAssertEqual(parsed.day, date(2026, 9, 15))
        XCTAssertNil(parsed.moment)
        XCTAssertEqual(parsed.freeText, "")
    }

    func testLastTuesdayWhenTodayIsTuesdayGoesBackAWeek() {
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 10))!
        let parsed = SearchQueryParser.parse("last Tuesday", now: tuesday, calendar: calendar)
        XCTAssertEqual(parsed.day, date(2026, 9, 8))
    }

    func testTue3pmBecomesAMomentOnTheMostRecentTuesday() {
        let parsed = SearchQueryParser.parse("Tue 3pm", now: now, calendar: calendar)
        XCTAssertEqual(parsed.day, date(2026, 9, 15))
        XCTAssertEqual(parsed.moment, date(2026, 9, 15, hour: 15))
        XCTAssertEqual(parsed.freeText, "")
    }

    func testChristmas2024IsChristmasDay() {
        let parsed = SearchQueryParser.parse("Christmas 2024", now: now, calendar: calendar)
        XCTAssertEqual(parsed.day, date(2024, 12, 25))
        XCTAssertNil(parsed.moment)
    }

    func testYesterdayAndToday() {
        XCTAssertEqual(
            SearchQueryParser.parse("yesterday", now: now, calendar: calendar).day,
            date(2026, 9, 15)
        )
        XCTAssertEqual(
            SearchQueryParser.parse("today", now: now, calendar: calendar).day,
            date(2026, 9, 16)
        )
    }

    func testISODate() {
        let parsed = SearchQueryParser.parse("2026-09-20", now: now, calendar: calendar)
        XCTAssertEqual(parsed.day, date(2026, 9, 20))
    }

    func testPlaceNameIsLeftAsFreeText() {
        let parsed = SearchQueryParser.parse("Berlin last Tuesday", now: now, calendar: calendar)
        XCTAssertEqual(parsed.freeText, "Berlin")
        XCTAssertEqual(parsed.day, date(2026, 9, 15))
    }

    func testNoteQueryHasNoDay() {
        let parsed = SearchQueryParser.parse("coffee with Sam", now: now, calendar: calendar)
        XCTAssertEqual(parsed.freeText, "coffee with Sam")
        XCTAssertNil(parsed.day)
        XCTAssertNil(parsed.moment)
    }

    func testMomentURLUsesMovesAtHost() throws {
        let moment = date(2026, 9, 15, hour: 15)
        let url = try XCTUnwrap(SearchQueryParser.momentURL(moment, timeZone: calendar.timeZone))
        XCTAssertEqual(url.scheme, "moves")
        XCTAssertEqual(url.host, "at")
        XCTAssertEqual(TimelineDeepLink.moment(from: url), moment)
    }

    func testDayURLUsesYearMonthDayPath() throws {
        let url = try XCTUnwrap(SearchQueryParser.dayURL(date(2026, 9, 15), calendar: calendar))
        XCTAssertEqual(url.absoluteString, "moves://day/2026-09-15")
    }

    func testEmptyQuery() {
        XCTAssertTrue(SearchQueryParser.parse("   ", now: now, calendar: calendar).isEmpty)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
