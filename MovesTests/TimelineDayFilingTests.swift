import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// Which day a row is filed under: the calendar day where it happened, worked out offline
/// from the coordinate, with flights, the date line, and daylight saving changes; and the
/// launch repairs that put existing rows there and clear days left empty.
@MainActor
final class TimelineDayFilingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var savedDefaultZone: TimeZone!

    override func setUp() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        // The phone is in Vietnam, as when the history these tests stand for was imported.
        savedDefaultZone = NSTimeZone.default
        NSTimeZone.default = vietnam
    }

    override func tearDown() async throws {
        NSTimeZone.default = savedDefaultZone
        context = nil
        container = nil
    }

    // MARK: - Zone lookup

    func testCitiesResolveToTheirOwnZones() {
        let expected: [(CLLocationCoordinate2D, String)] = [
            (sanFrancisco, "America/Los_Angeles"),
            (sfo, "America/Los_Angeles"),
            (CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321), "America/Los_Angeles"),
            (CLLocationCoordinate2D(latitude: 39.7392, longitude: -104.9903), "America/Denver"),
            (CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740), "America/Phoenix"),
            (CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298), "America/Chicago"),
            (CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060), "America/New_York"),
            (CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583), "Pacific/Honolulu"),
            (bangkok, "Asia/Bangkok"),
            (suvarnabhumi, "Asia/Bangkok"),
            (hoChiMinhCity, "Asia/Ho_Chi_Minh"),
            (CLLocationCoordinate2D(latitude: 11.9404, longitude: 108.4583), "Asia/Ho_Chi_Minh"),
            (CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093), "Australia/Sydney"),
            (CLLocationCoordinate2D(latitude: -34.9285, longitude: 138.6007), "Australia/Adelaide"),
            (CLLocationCoordinate2D(latitude: -8.6500, longitude: 115.2167), "Asia/Makassar"),
            (CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278), "Europe/London"),
            (CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654), "Asia/Taipei"),
        ]
        for (coordinate, zone) in expected {
            XCTAssertEqual(PlaceTimeZone.timeZone(at: coordinate)?.identifier, zone, "\(coordinate)")
        }
    }

    func testOpenSeaKeepsNauticalTimeAndMissingFixesHaveNoZone() {
        let midPacific = CLLocationCoordinate2D(latitude: 30, longitude: -160)
        XCTAssertEqual(PlaceTimeZone.timeZone(at: midPacific)?.secondsFromGMT(), -11 * 3600)
        XCTAssertNil(PlaceTimeZone.timeZone(at: CLLocationCoordinate2D(latitude: 0, longitude: 0)))
        XCTAssertNil(PlaceTimeZone.timeZone(at: CLLocationCoordinate2D(latitude: .nan, longitude: 10)))
    }

    // MARK: - New rows

    func testAFixIsFiledOnTheLocalDayWhereItWasTaken() throws {
        let repository = SwiftDataTimelineRepository(modelContext: context)
        // 18:00 on 22 April in San Francisco is already 23 April in Vietnam.
        let evening = date("2026-04-22 18:00", in: pacific)
        let samples = try repository.appendSamples(from: [location(sanFrancisco, at: evening)], source: .fileRouteImport)

        XCTAssertEqual(samples.first?.dayTimeline?.dayKey, "2026-04-22")
        XCTAssertEqual(samples.first?.dayTimeline?.dayStart, date("2026-04-22 00:00", in: pacific))
    }

    func testARowWithoutACoordinateTakesTheZoneOfTheNearestFix() throws {
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let evening = date("2026-04-22 18:00", in: pacific)
        XCTAssertEqual(try repository.dayTimeline(for: evening).dayKey, "2026-04-23", "With no fixes, the phone's zone")

        let fresh = SwiftDataTimelineRepository(modelContext: context)
        _ = try fresh.appendSamples(from: [location(sanFrancisco, at: evening.addingTimeInterval(-3600))], source: .significantChange)
        XCTAssertEqual(try fresh.dayTimeline(for: evening).dayKey, "2026-04-22")
        XCTAssertEqual(try fresh.dayTimeline(for: evening, at: bangkok).dayKey, "2026-04-23")
    }

    // MARK: - Repair of existing rows

    func testEastboundAcrossTheDateLineEachRowLandsOnceOnItsLocalDay() throws {
        // Dinner in San Francisco, the airport, a night flight, and Bangkok two dates later.
        let dinner = stay(sanFrancisco, from: "2026-04-22 18:00", to: "2026-04-22 21:00", zone: pacific)
        let airport = stay(sfo, from: "2026-04-22 22:00", to: "2026-04-22 23:30", zone: pacific)
        let hotel = stay(bangkok, from: "2026-04-24 07:00", to: "2026-04-24 12:00", zone: thailand)
        let arrival = stay(suvarnabhumi, from: "2026-04-24 05:00", to: "2026-04-24 06:00", zone: thailand)
        let flight = move(from: airport, to: arrival, start: date("2026-04-22 23:30", in: pacific), end: date("2026-04-24 05:00", in: thailand), mode: .plane)
        fix(sanFrancisco, at: date("2026-04-22 20:00", in: pacific))
        fix(bangkok, at: date("2026-04-24 08:00", in: thailand))
        photo("dinner", at: date("2026-04-22 19:00", in: pacific), on: dinner)
        photo("street", at: date("2026-04-24 09:00", in: thailand), coordinate: bangkok)
        try context.save()
        let before = try counts()

        let report = try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)
        try TimelineDayRepair.removeEmptyDays(in: context, now: date("2026-11-25 12:00", in: vietnam))

        XCTAssertEqual(dinner.dayTimeline?.dayKey, "2026-04-22")
        XCTAssertEqual(airport.dayTimeline?.dayKey, "2026-04-22")
        XCTAssertEqual(flight.dayTimeline?.dayKey, "2026-04-22", "A flight is on the day it left")
        XCTAssertEqual(arrival.dayTimeline?.dayKey, "2026-04-24")
        XCTAssertEqual(hotel.dayTimeline?.dayKey, "2026-04-24")
        XCTAssertEqual(try photos()["dinner"], "2026-04-22", "A photo goes with its stay")
        XCTAssertEqual(try photos()["street"], "2026-04-24")
        XCTAssertEqual(try dayKeys(), ["2026-04-22", "2026-04-24"], "The date skipped over the Pacific has no day")
        XCTAssertEqual(try counts(), before, "Rows move between days; none are lost")
        XCTAssertGreaterThan(report.rowsMoved, 0)
        XCTAssertEqual(try day("2026-04-22").dayStart, date("2026-04-22 00:00", in: pacific))
    }

    func testWestboundTheFlightDayRunsLongerThanADayWithEveryRowOnIt() throws {
        let breakfast = stay(bangkok, from: "2026-05-10 07:00", to: "2026-05-10 08:30", zone: thailand)
        let gate = stay(suvarnabhumi, from: "2026-05-10 09:00", to: "2026-05-10 10:00", zone: thailand)
        let landing = stay(sfo, from: "2026-05-10 08:00", to: "2026-05-10 09:00", zone: pacific)
        let night = stay(sanFrancisco, from: "2026-05-10 22:00", to: "2026-05-11 07:00", zone: pacific)
        let flight = move(from: gate, to: landing, start: date("2026-05-10 10:00", in: thailand), end: date("2026-05-10 08:00", in: pacific), mode: .plane)
        try context.save()
        XCTAssertEqual(night.dayTimeline?.dayKey, "2026-05-11", "Filed the old way, by the phone's clock in Vietnam")

        try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)
        try TimelineDayRepair.removeEmptyDays(in: context, now: date("2026-11-25 12:00", in: vietnam))

        for row in [breakfast, gate, landing, night] {
            XCTAssertEqual(row.dayTimeline?.dayKey, "2026-05-10")
        }
        XCTAssertEqual(flight.dayTimeline?.dayKey, "2026-05-10")
        let day = try day("2026-05-10")
        XCTAssertEqual(day.dayStart, date("2026-05-10 00:00", in: thailand), "Midnight where the day began")
        XCTAssertGreaterThan(night.arrivalDate.timeIntervalSince(day.dayStart), 24 * 3600)
        XCTAssertEqual(try dayKeys(), ["2026-05-10"])
    }

    func testDaylightSavingChangesKeepLateEveningsOnTheirOwnDay() throws {
        // Clocks go forward in California on 8 March 2026 and back on 1 November.
        let early = stay(sanFrancisco, from: "2026-03-08 00:30", to: "2026-03-08 01:30", zone: pacific)
        let late = stay(sanFrancisco, from: "2026-03-08 23:30", to: "2026-03-09 07:00", zone: pacific)
        let beforeFallBack = stay(sanFrancisco, from: "2026-11-01 00:30", to: "2026-11-01 01:00", zone: pacific)
        let lateFallBack = stay(sanFrancisco, from: "2026-11-01 23:30", to: "2026-11-02 07:00", zone: pacific)
        try context.save()

        try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)

        XCTAssertEqual(early.dayTimeline?.dayKey, "2026-03-08")
        XCTAssertEqual(late.dayTimeline?.dayKey, "2026-03-08")
        XCTAssertEqual(beforeFallBack.dayTimeline?.dayKey, "2026-11-01")
        XCTAssertEqual(lateFallBack.dayTimeline?.dayKey, "2026-11-01")
        XCTAssertEqual(try day("2026-03-08").dayStart, ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z"))
        XCTAssertEqual(try day("2026-11-01").dayStart, ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z"))
    }

    func testRetiredStaysAndTripsAreLeftWithoutADay() throws {
        let dinner = stay(sanFrancisco, from: "2026-04-22 18:00", to: "2026-04-22 21:00", zone: pacific)
        let retiredStop = stay(sanFrancisco, from: "2026-04-22 19:00", to: "2026-04-22 20:00", zone: pacific)
        let retiredTrip = move(from: dinner, to: retiredStop, start: date("2026-04-22 21:00", in: pacific), end: date("2026-04-22 21:30", in: pacific), mode: .walking)
        // What the rebuild's retire leaves: no day, and for a trip a retired key.
        retiredStop.dayTimeline = nil
        retiredTrip.dayTimeline = nil
        retiredTrip.dedupeKey = TimelineRetirement.dedupeKey(for: retiredTrip.id)
        try context.save()

        try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)

        XCTAssertNil(retiredStop.dayTimeline)
        XCTAssertNil(retiredTrip.dayTimeline)
        XCTAssertEqual(dinner.dayTimeline?.dayKey, "2026-04-22")
    }

    func testRunningTheRepairAgainChangesNothing() throws {
        let dinner = stay(sanFrancisco, from: "2026-04-22 18:00", to: "2026-04-22 21:00", zone: pacific)
        let hotel = stay(bangkok, from: "2026-04-24 07:00", to: "2026-04-24 12:00", zone: thailand)
        _ = move(from: dinner, to: hotel, start: date("2026-04-22 21:00", in: pacific), end: date("2026-04-24 07:00", in: thailand), mode: .plane)
        fix(sanFrancisco, at: date("2026-04-22 20:00", in: pacific))
        try context.save()

        let first = try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)
        let second = try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)

        XCTAssertGreaterThan(first.rowsMoved, 0)
        XCTAssertEqual(second, TimelineDayRepair.Report())
    }

    // MARK: - Screens read a day by its own date

    func testADayEastOfThePhoneShowsItsOwnDate() throws {
        // Sydney's 24 April starts at 21:00 on the 23rd in Vietnam.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let day = DayTimeline(containing: date("2026-04-24 10:00", in: sydney), in: sydney)
        context.insert(day)
        let walk = MoveSegment(dedupeKey: "walk", startDate: date("2026-04-24 10:00", in: sydney),
                               endDate: date("2026-04-24 11:00", in: sydney), transportMode: .walking,
                               distanceMeters: 3_000, stepCount: nil)
        context.insert(walk)
        walk.dayTimeline = day
        try context.save()

        let phoneDate = date("2026-04-24 00:00", in: vietnam)
        XCTAssertNotEqual(Calendar.current.startOfDay(for: day.dayStart), phoneDate, "The old reading: a day early")
        XCTAssertEqual(day.calendarDate(), phoneDate)
        XCTAssertEqual(try InsightsSourceLoader.load(from: container).days.map(\.dayStart), [phoneDate])
        XCTAssertEqual(
            TimelineWidgetSnapshot.make(from: day).dayTitle,
            phoneDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        )
    }

    func testADayReadsOnTheClockWhereItHappenedAndSaysSoWhenThatIsNotThePhones() throws {
        let dinner = stay(sanFrancisco, from: "2026-09-14 18:00", to: "2026-09-14 21:00", zone: pacific)
        let lunch = stay(hoChiMinhCity, from: "2026-09-20 12:00", to: "2026-09-20 13:00", zone: vietnam)
        try TimelineDayRepair.fileDaysByLocalTime(in: context, fallbackTimeZone: vietnam)
        let usDay = try XCTUnwrap(dinner.dayTimeline)

        XCTAssertEqual(usDay.placeTimeZone.identifier, "America/Los_Angeles")
        XCTAssertEqual(usDay.foreignTimeZoneAbbreviation, "PDT")
        XCTAssertEqual(StorylineClock.hourMinuteText(from: dinner.arrivalDate, locale: Locale(identifier: "en_GB"), timeZone: usDay.placeTimeZone), "18:00")
        XCTAssertEqual(dinner.placeTimeZone.identifier, "America/Los_Angeles")
        XCTAssertNil(lunch.dayTimeline?.foreignTimeZoneAbbreviation, "Same clock as the phone: no label")

        let today = DayTimeline(containing: .now, in: vietnam)
        context.insert(today)
        XCTAssertEqual(today.placeTimeZone, Calendar.current.timeZone)
        XCTAssertNil(today.foreignTimeZoneAbbreviation)
    }

    func testEditingTimesKeepsAStayOnItsLocalDayAndMovesItPastLocalMidnight() throws {
        let repository = SwiftDataTimelineRepository(modelContext: context)
        // 08:00 in California is 22:00 the same date in Vietnam.
        let dinner = stay(sanFrancisco, from: "2026-04-22 08:00", to: "2026-04-22 09:00", zone: pacific)
        try context.save()
        XCTAssertEqual(dinner.dayTimeline?.dayKey, "2026-04-22")

        // Later the same evening there: already the 23rd in Vietnam, still the 22nd in California.
        try repository.updateTimes(of: dinner, arrival: date("2026-04-22 18:00", in: pacific), departure: date("2026-04-22 21:00", in: pacific))
        XCTAssertEqual(dinner.dayTimeline?.dayKey, "2026-04-22")

        try repository.updateTimes(of: dinner, arrival: date("2026-04-23 00:30", in: pacific), departure: date("2026-04-23 02:00", in: pacific))
        XCTAssertEqual(dinner.dayTimeline?.dayKey, "2026-04-23")
    }

    // MARK: - Empty days

    func testOnlyDaysWithNothingOnThemAreRemoved() throws {
        let now = date("2026-11-25 12:00", in: vietnam)
        let empty = DayTimeline(containing: date("2026-06-01 12:00", in: vietnam), in: vietnam)
        let photoOnly = DayTimeline(containing: date("2026-06-02 12:00", in: vietnam), in: vietnam)
        let today = DayTimeline(containing: now, in: vietnam)
        for day in [empty, photoOnly, today] { context.insert(day) }
        let picture = PhotoAttachment(assetLocalIdentifier: "lone", capturedAt: date("2026-06-02 12:00", in: vietnam))
        picture.dayTimeline = photoOnly
        context.insert(picture)
        let kept = stay(hoChiMinhCity, from: "2026-06-03 09:00", to: "2026-06-03 10:00", zone: vietnam)
        try context.save()

        XCTAssertEqual(try TimelineDayRepair.removeEmptyDays(in: context, now: now), 1)
        XCTAssertEqual(try dayKeys(), ["2026-06-02", "2026-06-03", "2026-11-25"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoAttachment>()), 1)
        XCTAssertNotNil(kept.dayTimeline)
        XCTAssertEqual(try TimelineDayRepair.removeEmptyDays(in: context, now: now), 0)
    }

    func testTheLongStepShowsHowFarAndTheTimeLeft() {
        let progress = TimelineUpgradeProgress()
        progress.begin(stepCount: 2)
        progress.show("Putting each day on local time", completed: 0)
        progress.showProgressWithinStep(done: 50, of: 100, now: .now.addingTimeInterval(10))

        XCTAssertEqual(progress.fractionCompleted, 0.25, accuracy: 0.001)
        let detail = try? XCTUnwrap(progress.stepDetail)
        XCTAssertTrue(detail?.contains("50 of 100") == true, detail ?? "")
        XCTAssertTrue(detail?.contains("left") == true, detail ?? "")
    }

    func testUpgradeNineRunsTheDayRepairsBeforeTheTripRebuild() {
        let plan = TimelineSchemaUpgrader.steps(from: 8)
        XCTAssertEqual(plan.map(\.version), [9, 9])
        XCTAssertEqual(TimelineSchemaUpgrader.currentVersion, 9)
        let fromZero = TimelineSchemaUpgrader.steps(from: 0)
        guard case .longTrips = fromZero.last?.work else { return XCTFail("The trip rebuild must stay last") }
    }

    // MARK: - Step 1 on a store that already has places

    func testNamedStaysJoinANearbyPlaceOfTheSameNameAndNeverMakeATwin() throws {
        let cafe = KnownPlace(name: "Corner Cafe", latitude: 10.7700, longitude: 106.7000, footprintRadius: 80)
        context.insert(cafe)
        let near = labeledStay("Corner cafe", north: 200)
        let far = labeledStay("Corner Cafe", north: 400)
        let other = labeledStay("Bookshop", north: 50)
        try context.save()

        try TimelineSchemaUpgrader.clusterUserLabeledPlaces(in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 1, "No place is made beside the one there")
        XCTAssertEqual(near.knownPlace?.id, cafe.id)
        XCTAssertEqual(near.assignmentSource, .user)
        XCTAssertNil(far.knownPlace)
        XCTAssertEqual(far.assignmentSource, .none)
        XCTAssertNil(other.knownPlace)
    }

    func testHistoryFromBeforeLearnedPlacesStillGetsItsPlaces() throws {
        let first = labeledStay("Corner Cafe", north: 0)
        let second = labeledStay("corner cafe", north: 60)
        try context.save()

        try TimelineSchemaUpgrader.clusterUserLabeledPlaces(in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 1)
        XCTAssertNotNil(first.knownPlace)
        XCTAssertEqual(first.knownPlace?.id, second.knownPlace?.id)
    }

    // MARK: - Undo of a deleted stay

    func testUndoingAStayDeleteRelinksOnlyItsOwnPhotos() throws {
        let visit = stay(hoChiMinhCity, from: "2026-06-03 09:00", to: "2026-06-03 10:00", zone: vietnam)
        photo("mine", at: date("2026-06-03 09:30", in: vietnam), on: visit)
        for index in 0..<300 {
            photo("other-\(index)", at: date("2026-06-03 09:30", in: vietnam), coordinate: hoChiMinhCity)
        }
        try context.save()
        let payload = TimelineDeletedPlacePayload(place: visit)
        visit.photoAttachments.forEach { $0.visitPlace = nil }
        context.delete(visit)
        try context.save()

        payload.restore(in: context)

        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<VisitPlace>()).first { $0.id == payload.id })
        XCTAssertEqual(restored.photoAttachments.map(\.assetLocalIdentifier), ["mine"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAttachment>()).filter { $0.visitPlace != nil }.count, 1)
    }

    // MARK: - Health and matched paths

    func testHealthDisagreementMarksAMatchedWalkEstimatedAndAgreementLeavesIt() throws {
        XCTAssertEqual(RouteMatchPlausibility.confidence(.high, healthSignal: .wandered), .estimated)
        XCTAssertEqual(RouteMatchPlausibility.confidence(.medium, healthSignal: .shortfall), .estimated)
        XCTAssertEqual(RouteMatchPlausibility.confidence(.high, healthSignal: .agree), .high)
        XCTAssertEqual(RouteMatchPlausibility.confidence(.high, healthSignal: .inconclusive), .high)
        XCTAssertEqual(RouteMatchPlausibility.confidence(.high, healthSignal: nil), .high)
        XCTAssertEqual(RouteMatchPlausibility.confidence(.recorded, healthSignal: .wandered), .recorded)

        let start = stay(hoChiMinhCity, from: "2026-06-03 09:00", to: "2026-06-03 10:00", zone: vietnam)
        let end = stay(hoChiMinhCity, from: "2026-06-03 10:30", to: "2026-06-03 11:00", zone: vietnam)
        let walk = move(from: start, to: end, start: date("2026-06-03 10:00", in: vietnam), end: date("2026-06-03 10:30", in: vietnam), mode: .walking)
        let unread = move(from: start, to: end, start: date("2026-06-03 10:00", in: vietnam), end: date("2026-06-03 10:30", in: vietnam), mode: .walking)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let cache = HealthTimelineCacheStore(url: url)
        var data = HealthTimelineCacheData()
        data.trips[walk.id] = HealthTimelineCacheData.TripEntry(
            dayKey: "2026-06-03",
            evidence: HealthStepEvidence(steps: .value(3_000), duration: 1_800, vote: nil),
            healthMeters: 2_000
        )
        try cache.replace(data)
        let identity = HealthStrideCalibration.identity

        func signal(_ move: MoveSegment, _ meters: Double) -> HealthRouteSignal? {
            RouteMatchPlausibility.healthSignal(for: move, routeMeters: meters, cache: cache, calibration: identity, isActive: true)
        }
        XCTAssertEqual(signal(walk, 1_000), .wandered)
        XCTAssertEqual(signal(walk, 5_000), .shortfall)
        XCTAssertEqual(signal(walk, 2_100), .agree)
        XCTAssertNil(signal(unread, 1_000), "A trip Health never read keeps the matcher's answer")
        XCTAssertNil(RouteMatchPlausibility.healthSignal(for: walk, routeMeters: 1_000, cache: cache, calibration: identity, isActive: false))
        walk.transportMode = .automotive
        XCTAssertNil(signal(walk, 1_000))
    }

    // MARK: - Helpers

    private let vietnam = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private let thailand = TimeZone(identifier: "Asia/Bangkok")!
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    private let sfo = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)
    private let bangkok = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
    private let suvarnabhumi = CLLocationCoordinate2D(latitude: 13.6900, longitude: 100.7501)
    private let hoChiMinhCity = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)

    private func date(_ text: String, in zone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func location(_ coordinate: CLLocationCoordinate2D, at date: Date) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: date)
    }

    /// Filed the old way: by the date on the phone's clock in Vietnam.
    private func oldDay(for date: Date) -> DayTimeline {
        let key = DayTimeline.makeDayKey(for: date, in: vietnam)
        if let existing = try? context.fetch(FetchDescriptor<DayTimeline>()).first(where: { $0.dayKey == key }) {
            return existing
        }
        let day = DayTimeline(containing: date, in: vietnam)
        context.insert(day)
        return day
    }

    @discardableResult
    private func stay(_ coordinate: CLLocationCoordinate2D, from arrival: String, to departure: String, zone: TimeZone) -> VisitPlace {
        let visit = VisitPlace(
            arrivalDate: date(arrival, in: zone),
            departureDate: date(departure, in: zone),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: 20
        )
        context.insert(visit)
        visit.dayTimeline = oldDay(for: visit.arrivalDate)
        return visit
    }

    private func move(from start: VisitPlace, to end: VisitPlace, start startDate: Date, end endDate: Date, mode: TransportMode) -> MoveSegment {
        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: startDate,
            endDate: endDate,
            transportMode: mode,
            distanceMeters: 1_000,
            stepCount: nil
        )
        context.insert(move)
        move.startPlace = start
        move.endPlace = end
        move.dayTimeline = oldDay(for: startDate)
        return move
    }

    private func fix(_ coordinate: CLLocationCoordinate2D, at date: Date) {
        let sample = LocationSample(location: location(coordinate, at: date), source: .significantChange, dedupeKey: UUID().uuidString)
        context.insert(sample)
        sample.dayTimeline = oldDay(for: date)
    }

    private func photo(_ identifier: String, at date: Date, on visit: VisitPlace? = nil, coordinate: CLLocationCoordinate2D? = nil) {
        let photo = PhotoAttachment(
            assetLocalIdentifier: identifier,
            capturedAt: date,
            latitude: coordinate?.latitude ?? visit?.latitude,
            longitude: coordinate?.longitude ?? visit?.longitude
        )
        context.insert(photo)
        photo.visitPlace = visit
        photo.dayTimeline = visit?.dayTimeline ?? oldDay(for: date)
    }

    private func labeledStay(_ label: String, north meters: Double) -> VisitPlace {
        let visit = VisitPlace(
            arrivalDate: date("2026-06-03 09:00", in: vietnam),
            departureDate: date("2026-06-03 10:00", in: vietnam),
            latitude: 10.7700 + meters / 111_320,
            longitude: 106.7000,
            horizontalAccuracy: 20,
            userLabel: label
        )
        context.insert(visit)
        return visit
    }

    private func counts() throws -> [Int] {
        [
            try context.fetchCount(FetchDescriptor<VisitPlace>()),
            try context.fetchCount(FetchDescriptor<MoveSegment>()),
            try context.fetchCount(FetchDescriptor<LocationSample>()),
            try context.fetchCount(FetchDescriptor<PhotoAttachment>()),
        ]
    }

    private func dayKeys() throws -> [String] {
        try context.fetch(FetchDescriptor<DayTimeline>()).map(\.dayKey).sorted()
    }

    private func day(_ key: String) throws -> DayTimeline {
        try XCTUnwrap(try context.fetch(FetchDescriptor<DayTimeline>()).first { $0.dayKey == key })
    }

    private func photos() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PhotoAttachment>()).map {
            ($0.assetLocalIdentifier, $0.dayTimeline?.dayKey ?? "")
        })
    }
}

private struct DayRepairWalkingClassifier: MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (.walking, 0.9)
    }

    func stepCount(start: Date, end: Date) async -> Int? { nil }
}

private struct DayRepairNoNames: PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? { nil }
}

// MARK: - Measurement on a copy of a real store

/// Runs the day repairs and the from-zero upgrade on copies of a real store. Set
/// `MOVES_DAY_REPAIR_REAL_STORE` to a directory holding `default.store` (and its -wal/-shm);
/// it is copied before each use. Results are printed only, so no real names or
/// coordinates live in the repository.
@MainActor
final class TimelineDayRepairRealStoreTests: XCTestCase {
    func testMeasureDayRepairsOnRealStoreCopy() throws {
        let context = try openCopy()
        let before = try Self.counts(context)
        print("DAYREPAIR rows before: \(before)")

        let start = Date.now
        let report = try TimelineDayRepair.fileDaysByLocalTime(in: context)
        print("DAYREPAIR re-filed in \(Int(Date.now.timeIntervalSince(start))) s: stays \(report.staysMoved), trips \(report.tripsMoved), fixes \(report.fixesMoved), photos \(report.photosMoved); days created \(report.daysCreated), day starts moved \(report.dayStartsMoved)")
        let removed = try TimelineDayRepair.removeEmptyDays(in: context)
        print("DAYREPAIR empty days removed: \(removed)")
        let after = try Self.counts(context)
        print("DAYREPAIR rows after: \(after)")
        XCTAssertEqual(Array(before.prefix(4)), Array(after.prefix(4)), "Stays, trips, fixes, and photos are all still there")

        let again = try TimelineDayRepair.fileDaysByLocalTime(in: context)
        print("DAYREPAIR second run: \(again.rowsMoved) rows moved, \(again.daysCreated) days created, \(again.dayStartsMoved) starts moved; empty days \(try TimelineDayRepair.removeEmptyDays(in: context))")
        XCTAssertEqual(again, TimelineDayRepair.Report())

        // Re-centring, measured only: automatic, unassigned, unedited sensor stays.
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        func footprint(_ coordinate: CLLocationCoordinate2D) -> UUID? {
            places.filter { PlaceLearningEngine.distance(from: $0.coordinate, to: coordinate) <= $0.footprintRadius }
                .min { PlaceLearningEngine.distance(from: $0.coordinate, to: coordinate) < PlaceLearningEngine.distance(from: $1.coordinate, to: coordinate) }?
                .id
        }
        var shifts: [Double] = []
        var changesPlace = 0
        for visit in try context.fetch(FetchDescriptor<VisitPlace>()) where visit.origin == .sensor
            && visit.knownPlace == nil && visit.assignmentSource == .none
            && PlaceDisplayNamer.meaningful(visit.userLabel) == nil && visit.reviewState == .none {
            guard let departure = visit.departureDate else { continue }
            let fixes = try repository.samples(from: visit.arrivalDate, to: departure)
                .filter { $0.source != .photoLibrary && $0.moveSegment == nil }
                .map { (latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.horizontalAccuracy) }
            guard let centre = PlaceLearningEngine.robustCenter(of: fixes) else { continue }
            shifts.append(PlaceLearningEngine.distance(from: visit.coordinate, to: centre))
            if footprint(visit.coordinate) != footprint(centre) { changesPlace += 1 }
        }
        shifts.sort()
        if !shifts.isEmpty {
            func quantile(_ q: Double) -> Int { Int(shifts[min(shifts.count - 1, Int(q * Double(shifts.count)))]) }
            print("DAYREPAIR re-centre: \(shifts.count) stays; shift median \(quantile(0.5)) m, p90 \(quantile(0.9)) m, max \(Int(shifts.last ?? 0)) m; over 50 m \(shifts.filter { $0 > 50 }.count); \(changesPlace) would change which place's footprint they sit in")
        }
    }

    /// Upgrade 9, then the stay rebuild as capture runs it (full, trip only, full, trip only):
    /// later passes write nothing, and filing the days again moves nothing.
    func testMeasureDayRepairAndRebuildsSettleTogether() async throws {
        let context = try openCopy()
        let container = context.container
        let report = try TimelineDayRepair.fileDaysByLocalTime(in: context)
        let removed = try TimelineDayRepair.removeEmptyDays(in: context)
        print("DAYREBUILD upgrade 9 moved \(report.rowsMoved) rows, created \(report.daysCreated) days, removed \(removed) empty days")

        let writer = ModelContext(container)
        let assembler = DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContext: writer),
            motionClassifier: DayRepairWalkingClassifier(),
            placeNameResolver: DayRepairNoNames()
        )
        var saves = 0
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: writer, queue: nil) { _ in
            saves += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let tripSince = Date().addingTimeInterval(-2 * 60 * 60)
        for pass in 1...4 {
            saves = 0
            await assembler.reconcile(pass.isMultiple(of: 2) ? .recentTrip(since: tripSince) : .week)
            print("DAYREBUILD pass \(pass) (\(pass.isMultiple(of: 2) ? "trip only" : "full")): \(saves) saves")
            if pass >= 2 { XCTAssertEqual(saves, 0, "Pass \(pass) wrote with nothing new") }
        }

        let check = ModelContext(container)
        check.autosaveEnabled = false
        let again = try TimelineDayRepair.fileDaysByLocalTime(in: check)
        let emptyAgain = try TimelineDayRepair.removeEmptyDays(in: check)
        print("DAYREBUILD upgrade 9 again: \(again.rowsMoved) rows moved, \(again.daysCreated) days created, \(again.dayStartsMoved) starts moved, \(emptyAgain) empty days")
        XCTAssertEqual(again, TimelineDayRepair.Report())
        XCTAssertEqual(emptyAgain, 0)
    }

    func testMeasureFromZeroUpgradeKeepsThePlacesOfAnIncrementalOne() throws {
        let incremental = try openCopy()
        let placesBefore = try incremental.fetchCount(FetchDescriptor<KnownPlace>())
        try TimelineSchemaUpgrader.upgrade(in: incremental, from: 8)
        // Every launch at the current version also merges same-name twins it finds.
        try TimelineSchemaUpgrader.mergeDuplicateKnownPlaces(in: incremental)
        let incrementalPlaces = try Self.placeSummary(incremental)

        let fromZero = try openCopy()
        try TimelineSchemaUpgrader.clusterUserLabeledPlaces(in: fromZero)
        let afterStepOne = try fromZero.fetchCount(FetchDescriptor<KnownPlace>())
        try TimelineSchemaUpgrader.upgrade(in: fromZero, from: 0)
        let fromZeroPlaces = try Self.placeSummary(fromZero)

        print("DAYREPAIR places: \(placesBefore) in the copy; \(afterStepOne) after step 1 from zero; \(fromZeroPlaces.count) after the whole upgrade from zero; \(incrementalPlaces.count) after the incremental one")
        XCTAssertEqual(afterStepOne, placesBefore, "Step 1 makes no place beside existing ones")
        XCTAssertEqual(fromZeroPlaces.count, incrementalPlaces.count)
    }

    private static func placeSummary(_ context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<KnownPlace>()).map { PlaceDisplayNamer.labelComparisonKey($0.name) }.sorted()
    }

    private static func counts(_ context: ModelContext) throws -> [Int] {
        [
            try context.fetchCount(FetchDescriptor<VisitPlace>()),
            try context.fetchCount(FetchDescriptor<MoveSegment>()),
            try context.fetchCount(FetchDescriptor<LocationSample>()),
            try context.fetchCount(FetchDescriptor<PhotoAttachment>()),
            try context.fetchCount(FetchDescriptor<KnownPlace>()),
            try context.fetchCount(FetchDescriptor<DayTimeline>()),
        ]
    }

    private func openCopy() throws -> ModelContext {
        guard let source = ProcessInfo.processInfo.environment["MOVES_DAY_REPAIR_REAL_STORE"], !source.isEmpty else {
            throw XCTSkip("No real store copy given")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source).appendingPathComponent("default.store" + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)]
        )
        containers.append(container)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private var containers: [ModelContainer] = []
}
