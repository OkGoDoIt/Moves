import CoreLocation
import XCTest
@testable import Moves

final class TimelineTabTests: XCTestCase {
    func testBubbleDiameterUsesMinimumWhenMaxIsZero() {
        XCTAssertEqual(
            ActivityBubbleSizing.diameter(duration: 120, maximumDuration: 0),
            ActivityBubbleSizing.minimumDiameter
        )
    }

    func testBubbleDiameterUsesMinimumForZeroDuration() {
        XCTAssertEqual(
            ActivityBubbleSizing.diameter(duration: 0, maximumDuration: 3600),
            ActivityBubbleSizing.minimumDiameter
        )
    }

    func testBubbleDiameterUsesMaximumWhenDurationsMatch() {
        XCTAssertEqual(
            ActivityBubbleSizing.diameter(duration: 3600, maximumDuration: 3600),
            ActivityBubbleSizing.maximumDiameter
        )
    }

    func testBubbleDiameterInterpolatesLinearly() {
        let diameter = ActivityBubbleSizing.diameter(duration: 1800, maximumDuration: 3600)
        let expected = ActivityBubbleSizing.minimumDiameter
            + (ActivityBubbleSizing.maximumDiameter - ActivityBubbleSizing.minimumDiameter) * 0.5
        XCTAssertEqual(diameter, expected, accuracy: 0.01)
    }

    func testBubbleDiameterClampsAboveTheMaximum() {
        XCTAssertEqual(
            ActivityBubbleSizing.diameter(duration: 10_000, maximumDuration: 3600),
            ActivityBubbleSizing.maximumDiameter
        )
    }

    func testMomentJumpTargetMapsAVisit() {
        let visit = VisitPlace(
            arrivalDate: date(9, 0),
            departureDate: date(10, 0),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let result = TimelineLocator.locate(at: date(9, 30), visits: [visit], moves: [])
        let target = TimelineMomentJump.target(from: result)

        XCTAssertEqual(target?.entryID, "place-\(visit.id.uuidString)")
        XCTAssertEqual(target?.mapSelection, .place(visit.id))
        XCTAssertEqual(target?.visitID, visit.id)
        XCTAssertNil(target?.moveID)
    }

    func testMomentJumpTargetMapsAMove() {
        let start = VisitPlace(
            arrivalDate: date(8, 0),
            departureDate: date(8, 10),
            latitude: 52.50,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let end = VisitPlace(
            arrivalDate: date(8, 40),
            departureDate: date(9, 0),
            latitude: 52.54,
            longitude: 13.44,
            horizontalAccuracy: 10
        )
        let move = MoveSegment(
            dedupeKey: "cycle",
            startDate: date(8, 10),
            endDate: date(8, 40),
            transportMode: .cycling,
            distanceMeters: 5_000,
            stepCount: nil
        )
        move.startPlace = start
        move.endPlace = end

        let result = TimelineLocator.locate(at: date(8, 25), visits: [start, end], moves: [move])
        let target = TimelineMomentJump.target(from: result)

        XCTAssertEqual(target?.entryID, "move-\(move.id.uuidString)")
        XCTAssertEqual(target?.mapSelection, .move(move.id))
        XCTAssertEqual(target?.moveID, move.id)
        XCTAssertNil(target?.visitID)
    }

    func testMomentJumpGapFallsBackToThePreviousItem() {
        let visit = VisitPlace(
            arrivalDate: date(9, 0),
            departureDate: date(10, 0),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let later = VisitPlace(
            arrivalDate: date(12, 0),
            departureDate: date(13, 0),
            latitude: 52.53,
            longitude: 13.41,
            horizontalAccuracy: 10
        )

        let result = TimelineLocator.locate(at: date(11, 0), visits: [visit, later], moves: [])
        let target = TimelineMomentJump.target(from: result)

        XCTAssertEqual(target?.entryID, "place-\(visit.id.uuidString)")
        XCTAssertEqual(target?.visitID, visit.id)
    }

    func testDeepLinkParsesAnISO8601Moment() throws {
        let url = try XCTUnwrap(URL(string: "moves://at/2026-09-20T08:32:00Z"))
        let moment = try XCTUnwrap(TimelineDeepLink.moment(from: url))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.year, from: moment), 2026)
        XCTAssertEqual(calendar.component(.month, from: moment), 9)
        XCTAssertEqual(calendar.component(.day, from: moment), 20)
        XCTAssertEqual(calendar.component(.hour, from: moment), 8)
        XCTAssertEqual(calendar.component(.minute, from: moment), 32)
    }

    func testDeepLinkParsesADateOnlyPath() throws {
        let url = try XCTUnwrap(URL(string: "moves://at/2026-09-20"))
        let moment = try XCTUnwrap(TimelineDeepLink.moment(from: url))
        let start = Calendar.autoupdatingCurrent.startOfDay(for: moment)
        XCTAssertEqual(moment, start)
    }

    func testDeepLinkIgnoresOtherHosts() throws {
        let url = try XCTUnwrap(URL(string: "moves://today"))
        XCTAssertNil(TimelineDeepLink.moment(from: url))
    }

    func testStorylineClockKeepsPeriodOffTheHourMinuteLine() {
        var components = Locale.Components(identifier: "en_US")
        components.hourCycle = .oneToTwelve
        let locale = Locale(components: components)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = date(6, 54)

        XCTAssertTrue(StorylineClock.usesTwelveHourClock(locale: locale))
        let hourMinute = StorylineClock.hourMinuteText(from: morning, locale: locale, timeZone: timeZone)
        XCTAssertFalse(hourMinute.localizedCaseInsensitiveContains("am"))
        XCTAssertFalse(hourMinute.localizedCaseInsensitiveContains("pm"))
        XCTAssertTrue(hourMinute.contains("6"))
        XCTAssertTrue(hourMinute.contains("54"))
        XCTAssertEqual(
            StorylineClock.periodText(from: morning, locale: locale, timeZone: timeZone)?.uppercased(),
            "AM"
        )
        XCTAssertEqual(
            StorylineClock.periodText(from: date(15, 20), locale: locale, timeZone: timeZone)?.uppercased(),
            "PM"
        )
    }

    func testStorylineClockOmitsPeriodOnATwentyFourHourLocale() {
        var components = Locale.Components(identifier: "en_GB")
        components.hourCycle = .zeroToTwentyThree
        let locale = Locale(components: components)
        let timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertFalse(StorylineClock.usesTwelveHourClock(locale: locale))
        XCTAssertNil(StorylineClock.periodText(from: date(6, 54), locale: locale, timeZone: timeZone))
        let hourMinute = StorylineClock.hourMinuteText(from: date(6, 54), locale: locale, timeZone: timeZone)
        XCTAssertTrue(hourMinute.contains("6") || hourMinute.contains("06"))
        XCTAssertTrue(hourMinute.contains("54"))
    }

    func testCollapsedHeroGradientStaysSolidModeColor() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.50, longitude: 13.40),
            CLLocationCoordinate2D(latitude: 52.51, longitude: 13.40),
            CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)
        ]
        let route = RenderedRoute(
            id: "walk",
            coordinates: coordinates,
            usesHighAccuracyRouteTracking: false,
            usesHealthWorkoutRoute: false,
            transportMode: .walking,
            speedFractions: [0, 0.5, 1]
        )

        let collapsed = route.strokeGradient(shadeBySpeed: false)
        XCTAssertEqual(collapsed.stops.count, 2)
        XCTAssertEqual(collapsed.stops.first?.location, 0)
        XCTAssertEqual(collapsed.stops.last?.location, 1)

        let expanded = route.strokeGradient(shadeBySpeed: true)
        XCTAssertGreaterThanOrEqual(expanded.stops.count, 2)
        XCTAssertLessThanOrEqual(expanded.stops.count, RouteGradientRendering.maximumStopCount)
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }
}
