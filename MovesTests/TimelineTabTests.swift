import CoreLocation
import SwiftData
import XCTest
@testable import Moves

final class TimelineTabTests: XCTestCase {
    func testActivityChipTitlesAreSentenceCase() {
        XCTAssertEqual(TransportMode.walking.chipTitle, "Walk")
        XCTAssertEqual(TransportMode.automotive.chipTitle, "Drive")
        XCTAssertEqual(TransportMode.running.chipTitle, "Run")
        XCTAssertEqual(TransportMode.cycling.chipTitle, "Bike")
    }

    func testOpenDepartureIsOnlyOfferedWhenNothingStartsAfterTheVisit() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let earlier = VisitPlace(
            arrivalDate: date(9, 0),
            departureDate: date(10, 0),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let latest = VisitPlace(
            arrivalDate: date(12, 0),
            departureDate: nil,
            latitude: 52.53,
            longitude: 13.41,
            horizontalAccuracy: 10
        )
        context.insert(earlier)
        context.insert(latest)
        try context.save()

        XCTAssertEqual(EditTimesRules.nextItemStart(after: earlier, in: context), date(12, 0))
        XCTAssertNil(EditTimesRules.nextItemStart(after: latest, in: context))

        context.insert(
            MoveSegment(
                dedupeKey: "later-move",
                startDate: date(13, 0),
                endDate: date(13, 30),
                transportMode: .walking,
                distanceMeters: 800,
                stepCount: nil
            )
        )
        try context.save()

        XCTAssertEqual(EditTimesRules.nextItemStart(after: latest, in: context), date(13, 0))
    }

    func testWidgetSnapshotFromAnotherDayReadsAsAnEmptyToday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        func snapshot(for day: Date) -> TimelineWidgetSnapshot {
            TimelineWidgetSnapshot(
                generatedAt: day,
                dayKey: DayTimeline.makeDayKey(for: day),
                dayTitle: "Published",
                totalDistanceMeters: 4_200,
                visitedLocationCount: 3,
                moveCount: 2,
                transportMetrics: [],
                routePoints: [TimelineWidgetRoutePoint(latitude: 52.52, longitude: 13.40)]
            )
        }

        XCTAssertEqual(TimelineWidgetSnapshot.dayKey(for: now), DayTimeline.makeDayKey(for: now))

        let current = snapshot(for: now).forDisplay(now: now)
        XCTAssertEqual(current.dayTitle, "Published")
        XCTAssertEqual(current.moveCount, 2)

        let stale = snapshot(for: yesterday).forDisplay(now: now)
        XCTAssertEqual(stale.dayKey, DayTimeline.makeDayKey(for: now))
        XCTAssertEqual(stale.totalDistanceMeters, 0)
        XCTAssertEqual(stale.visitedLocationCount, 0)
        XCTAssertEqual(stale.moveCount, 0)
        XCTAssertTrue(stale.routePoints.isEmpty)
    }

    func testActivityChipRowStaysCompact() {
        XCTAssertEqual(ActivityChipSizing.rowHeight, 40)
        XCTAssertLessThanOrEqual(StorylineCompactMetrics.hiddenStopRowHeight, 28)
        XCTAssertLessThanOrEqual(StorylineCompactMetrics.shortStopRowHeight, 28)
    }

    func testCompactDurationUsesLessThanOneMinuteBelowSixtySeconds() {
        XCTAssertEqual(DurationFormatter.compactText(for: 0), "<1m")
        XCTAssertEqual(DurationFormatter.compactText(for: 45), "<1m")
        XCTAssertNotEqual(DurationFormatter.compactText(for: 120), "<1m")
    }

    func testHiddenStopCaptionIsASingleQuietLine() {
        let stop = VisitPlace(
            arrivalDate: date(8, 59),
            departureDate: date(9, 1),
            latitude: 10.76,
            longitude: 106.70,
            horizontalAccuracy: 10
        )
        let cluster = HiddenStopsCluster(places: [stop])
        XCTAssertEqual(cluster.collapsedCaption, "· \(DurationFormatter.compactText(for: 120))")
        XCTAssertFalse(cluster.collapsedCaption.localizedCaseInsensitiveContains("tap to show"))
        XCTAssertFalse(cluster.collapsedCaption.localizedCaseInsensitiveContains("hidden"))
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
