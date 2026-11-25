import CoreLocation
import SwiftData
import XCTest
@testable import Moves

final class TimelineDayMapTests: XCTestCase {
    /// Today's page opened before the day had a record kept showing "Nothing recorded yet"
    /// after the first stay was saved elsewhere. The page reloads a stand-in on any save.
    @MainActor
    func testEmptyDayPagePicksUpItsFirstStaySavedOnAnotherContext() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pageContext = container.mainContext
        let today = Calendar.current.startOfDay(for: .now)
        let dayKey = DayTimeline.makeDayKey(for: today)

        let empty = try XCTUnwrap(try DayTimelinePageLoader.load(dayKey: dayKey, in: pageContext))
        XCTAssertTrue(empty.isPlaceholder)
        XCTAssertTrue(empty.day.places.isEmpty)

        let saved = expectation(forNotification: ModelContext.didSave, object: nil)
        let capture = ModelContext(container)
        let day = DayTimeline(dayStart: today)
        capture.insert(day)
        let stay = VisitPlace(arrivalDate: today.addingTimeInterval(9 * 3_600), departureDate: nil, latitude: 11.94, longitude: 108.43, horizontalAccuracy: 10, userLabel: "Cafe")
        stay.dayTimeline = day
        capture.insert(stay)
        try capture.save()
        wait(for: [saved], timeout: 2)

        // What the page does when that save arrives while it shows a stand-in.
        let reloaded = try XCTUnwrap(try DayTimelinePageLoader.load(dayKey: dayKey, in: pageContext))
        XCTAssertFalse(reloaded.isPlaceholder)
        XCTAssertEqual(reloaded.day.places.map(\.userLabel), ["Cafe"])
    }

    /// A launch-time fix that became a second stay at the same place, right after the first
    /// with no trip between, shows as one row that says it covers two stays.
    @MainActor
    func testBackToBackStaysAtOnePlaceShareARow() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let first = VisitPlace(arrivalDate: base, departureDate: base.addingTimeInterval(3_600), latitude: 11.94, longitude: 108.43, horizontalAccuracy: 10, userLabel: "Resort")
        let second = VisitPlace(arrivalDate: base.addingTimeInterval(7_200), departureDate: nil, latitude: 11.9401, longitude: 108.4301, horizontalAccuracy: 10, userLabel: "Resort")
        let elsewhere = VisitPlace(arrivalDate: base.addingTimeInterval(9_000), departureDate: nil, latitude: 11.95, longitude: 108.45, horizontalAccuracy: 10, userLabel: "Market")
        [first, second, elsewhere].forEach(context.insert)

        var entries: [TimelineEntry] = [.place(first), .place(second), .place(elsewhere)]
        let repeats = TimelineRepeatedStays.fold(&entries)

        XCTAssertEqual(entries.map(\.id), [TimelineEntry.place(first).id, TimelineEntry.place(elsewhere).id])
        let repeated = try XCTUnwrap(repeats[first.id])
        XCTAssertEqual(repeated.count, 2)
        XCTAssertNil(repeated.departure)
        // While a trip is followed, the combined row reads as ended when it set off.
        let text = TimelineStayPresentation.subtitle(
            arrival: first.arrivalDate,
            departure: first.departureDate,
            followedTripStart: base.addingTimeInterval(8_000),
            repeated: repeated
        )
        XCTAssertTrue(text.contains("2 stays"), text)
        XCTAssertTrue(text.hasPrefix("Stayed"), text)
    }

    func testTripInProgressKeepsItsRowIdentityAsFixesArrive() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let early = LiveRouteTrackingSnapshot(startDate: start, latestDate: start.addingTimeInterval(60), sampleCount: 2, distanceMeters: 80, coordinates: [], isFollowedTrip: true)
        let later = LiveRouteTrackingSnapshot(startDate: start, latestDate: start.addingTimeInterval(600), sampleCount: 20, distanceMeters: 840, coordinates: [], isFollowedTrip: true)
        XCTAssertEqual(TimelineEntry.liveRoute(early).id, TimelineEntry.liveRoute(later).id)
        XCTAssertEqual(TimelineEntry.liveRoute(early).mapSelection, TimelineEntry.liveRoute(later).mapSelection)
        XCTAssertEqual(TimelineEntry.liveRoute(later).startDate, start)
        XCTAssertEqual(TimelineLiveTrip.mode(for: later), .walking)
        // Elapsed time keeps counting between fixes.
        let progress = TimelineLiveTrip.progressText(for: later, now: start.addingTimeInterval(1_200))
        XCTAssertTrue(progress.contains("20"), progress)
    }

    func testOpenStayReadsAsEndedWhileATripIsFollowed() {
        let arrival = Date(timeIntervalSince1970: 1_000_000)
        let tripStart = arrival.addingTimeInterval(2 * 3_600 + 2 * 60)
        let followed = TimelineStayPresentation.subtitle(arrival: arrival, departure: nil, followedTripStart: tripStart, repeated: nil)
        XCTAssertTrue(followed.hasPrefix("Stayed"), followed)
        XCTAssertEqual(
            TimelineStayPresentation.subtitle(arrival: arrival, departure: nil, followedTripStart: nil, repeated: nil),
            "In progress"
        )
        // A trip that set off before the stay began does not close it.
        XCTAssertEqual(
            TimelineStayPresentation.subtitle(arrival: arrival, departure: nil, followedTripStart: arrival.addingTimeInterval(-60), repeated: nil),
            "In progress"
        )
    }
}
