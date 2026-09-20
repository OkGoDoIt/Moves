import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class NamedTripTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testDefaultNameUsesDominatingLocality() {
        let interval = DateInterval(
            start: date(2026, 9, 13, 8, 0),
            end: date(2026, 9, 20, 18, 0)
        )
        let visits = [
            TripVisitSnapshot(locality: "Tokyo", countryCode: "JP"),
            TripVisitSnapshot(locality: "Tokyo", countryCode: "JP"),
            TripVisitSnapshot(locality: "Tokyo", countryCode: "JP"),
            TripVisitSnapshot(locality: "Kyoto", countryCode: "JP"),
            TripVisitSnapshot(locality: nil, countryCode: "JP")
        ]
        XCTAssertEqual(
            TripRangeStats.defaultName(visits: visits, interval: interval, calendar: calendar),
            "Tokyo"
        )
    }

    func testDefaultNameFallsBackToDateSpanWhenCitiesTie() {
        let interval = DateInterval(
            start: date(2026, 9, 20, 13, 0),
            end: date(2026, 9, 20, 18, 0)
        )
        let visits = [
            TripVisitSnapshot(locality: "Paris", countryCode: "FR"),
            TripVisitSnapshot(locality: "Lyon", countryCode: "FR")
        ]
        let name = TripRangeStats.defaultName(visits: visits, interval: interval, calendar: calendar)
        XCTAssertFalse(name.contains("Paris"))
        XCTAssertFalse(name.contains("Lyon"))
        XCTAssertTrue(name.contains("2026") || name.contains("Sep") || name.contains("13"))
    }

    func testCountryCodesStayUniqueAndOrdered() {
        let visits = [
            TripVisitSnapshot(locality: "Tokyo", countryCode: "jp"),
            TripVisitSnapshot(locality: "Osaka", countryCode: "JP"),
            TripVisitSnapshot(locality: "Paris", countryCode: "FR")
        ]
        XCTAssertEqual(TripRangeStats.countryCodes(from: visits), ["JP", "FR"])
    }

    func testCreatingATripDoesNotCopyVisitsOrDays() throws {
        let (context, _) = try makeStore()
        let day = insertDay(in: context, start: date(2026, 9, 20, 0, 0))
        let visit = insertVisit(
            in: context,
            day: day,
            arrival: date(2026, 9, 20, 9, 0),
            departure: date(2026, 9, 20, 10, 0),
            locality: "Amsterdam"
        )
        let move = insertMove(
            in: context,
            day: day,
            start: date(2026, 9, 20, 10, 0),
            end: date(2026, 9, 20, 11, 0)
        )
        try context.save()

        let interval = DateInterval(start: date(2026, 9, 20, 8, 0), end: date(2026, 9, 20, 18, 0))
        let trip = NamedTrip(
            name: TripRangeStats.defaultName(visits: [visit], interval: interval, calendar: calendar),
            startDate: interval.start,
            endDate: interval.end,
            notes: "Canal day"
        )
        context.insert(trip)
        try context.save()

        XCTAssertEqual(trip.name, "Amsterdam")
        XCTAssertEqual(try context.fetch(FetchDescriptor<NamedTrip>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DayTimeline>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).first?.id, visit.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).first?.id, move.id)
    }

    func testDeletingATripLeavesDaysVisitsMovesAndPhotos() throws {
        let (context, _) = try makeStore()
        let day = insertDay(in: context, start: date(2026, 9, 20, 0, 0))
        let visit = insertVisit(
            in: context,
            day: day,
            arrival: date(2026, 9, 20, 9, 0),
            departure: date(2026, 9, 20, 12, 0),
            locality: "Rome"
        )
        let move = insertMove(
            in: context,
            day: day,
            start: date(2026, 9, 20, 12, 0),
            end: date(2026, 9, 20, 13, 0)
        )
        let photo = PhotoAttachment(
            assetLocalIdentifier: "demo-asset",
            capturedAt: date(2026, 9, 20, 10, 30),
            latitude: 41.89,
            longitude: 12.49
        )
        photo.visitPlace = visit
        photo.dayTimeline = day
        context.insert(photo)
        let trip = NamedTrip(
            name: "Rome",
            startDate: date(2026, 9, 20, 8, 0),
            endDate: date(2026, 9, 20, 18, 0)
        )
        context.insert(trip)
        try context.save()

        let dayCount = try context.fetch(FetchDescriptor<DayTimeline>()).count
        let visitID = visit.id
        let moveID = move.id
        let photoTime = photo.capturedAt

        context.delete(trip)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<NamedTrip>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DayTimeline>()).count, dayCount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).first?.id, visitID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).first?.id, moveID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAttachment>()).first?.capturedAt, photoTime)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DayTimeline>()).first?.dayKey, day.dayKey)
    }

    func testPhotosQueryReturnsAttachmentsInsideTheRange() throws {
        let (context, _) = try makeStore()
        let day = insertDay(in: context, start: date(2026, 9, 20, 0, 0))
        let inside = PhotoAttachment(
            assetLocalIdentifier: "inside",
            capturedAt: date(2026, 9, 20, 14, 0),
            latitude: 52.37,
            longitude: 4.89
        )
        inside.dayTimeline = day
        let outside = PhotoAttachment(
            assetLocalIdentifier: "outside",
            capturedAt: date(2026, 9, 21, 10, 0)
        )
        outside.dayTimeline = day
        context.insert(inside)
        context.insert(outside)
        try context.save()

        let range = DateInterval(start: date(2026, 9, 20, 13, 0), end: date(2026, 9, 20, 18, 0))
        let photos = try TripRangeStats.photos(in: range, context: context)
        XCTAssertEqual(photos.map(\.assetLocalIdentifier), ["inside"])
        XCTAssertEqual(TripRangeStats.coverPhoto(from: photos)?.assetLocalIdentifier, "inside")
    }

    func testTripDeepLinkParsesUUID() throws {
        let identifier = UUID(uuidString: "A2E4C8B0-1234-4CDE-8F00-112233445566")!
        let url = try XCTUnwrap(TripDeepLink.url(for: identifier))
        XCTAssertEqual(url.absoluteString, "moves://trip/\(identifier.uuidString)")
        XCTAssertEqual(TripDeepLink.tripID(from: url), identifier)
    }

    func testTripDeepLinkIgnoresOtherHosts() throws {
        let url = try XCTUnwrap(URL(string: "moves://map?from=2026-09-20T13:00:00Z"))
        XCTAssertNil(TripDeepLink.tripID(from: url))
    }

    func testDaySectionsSurviveTripDeletion() throws {
        let (context, _) = try makeStore()
        let day = insertDay(in: context, start: date(2026, 9, 20, 0, 0))
        _ = insertVisit(
            in: context,
            day: day,
            arrival: date(2026, 9, 20, 9, 0),
            departure: date(2026, 9, 20, 10, 0),
            locality: "Oslo"
        )
        _ = insertMove(
            in: context,
            day: day,
            start: date(2026, 9, 20, 10, 0),
            end: date(2026, 9, 20, 11, 0)
        )
        let interval = DateInterval(start: date(2026, 9, 20, 0, 0), end: date(2026, 9, 21, 0, 0))
        let trip = NamedTrip(name: "Oslo", startDate: interval.start, endDate: interval.end)
        context.insert(trip)
        try context.save()

        let before = TripDetailView.makeDaySections(
            interval: interval,
            dayTimelines: try context.fetch(FetchDescriptor<DayTimeline>()),
            calendar: calendar
        )
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?.entries.count, 2)

        context.delete(trip)
        try context.save()

        let after = TripDetailView.makeDaySections(
            interval: interval,
            dayTimelines: try context.fetch(FetchDescriptor<DayTimeline>()),
            calendar: calendar
        )
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.entries.count, 2)
    }

    private func makeStore() throws -> (ModelContext, ModelContainer) {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return (context, container)
    }

    private func insertDay(in context: ModelContext, start: Date) -> DayTimeline {
        let day = DayTimeline(dayStart: start)
        context.insert(day)
        return day
    }

    private func insertVisit(
        in context: ModelContext,
        day: DayTimeline,
        arrival: Date,
        departure: Date,
        locality: String
    ) -> VisitPlace {
        let visit = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: 52.37,
            longitude: 4.89,
            horizontalAccuracy: 12,
            userLabel: locality
        )
        visit.locality = locality
        visit.dayTimeline = day
        context.insert(visit)
        return visit
    }

    private func insertMove(
        in context: ModelContext,
        day: DayTimeline,
        start: Date,
        end: Date
    ) -> MoveSegment {
        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: start,
            endDate: end,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: 1_600
        )
        move.dayTimeline = day
        context.insert(move)
        return move
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
