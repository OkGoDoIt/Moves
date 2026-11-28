import CoreLocation
import Foundation
import SwiftData
import XCTest
@testable import Moves

/// Parser, streaming Records scanner, occupancy dedupe, and persistence for
/// Google Timeline import. Live Takeout tests stay skipped unless
/// `MOVES_RUN_GOOGLE_TAKEOUT_TESTS=1`.
final class GoogleTimelineImporterTests: XCTestCase {
    private static let defaultTakeout = URL(
        fileURLWithPath: "/Volumes/Extreme SSD/onedrive/backups/Google Location History as of Dec 1 2024/Location History (Timeline)"
    )

    // MARK: Detection

    func testDetectsRecordsSemanticOnDeviceAndRejectsUnknown() throws {
        XCTAssertEqual(try detect("records-mini.json"), .records)
        XCTAssertEqual(try detect("semantic-month.json"), .semanticMonth)
        XCTAssertEqual(try detect("timeline-ondevice.json"), .onDevice)
        XCTAssertNil(try detect("not-google.json"))
    }

    func testTransportMappingIncludesBusAsTrain() {
        XCTAssertEqual(GoogleTimelineTransport.map("WALKING"), .walking)
        XCTAssertEqual(GoogleTimelineTransport.map("CYCLING"), .cycling)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_PASSENGER_VEHICLE"), .automotive)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_VEHICLE"), .automotive)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_TRAIN"), .train)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_BUS"), .train)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_SUBWAY"), .train)
        XCTAssertEqual(GoogleTimelineTransport.map("FLYING"), .plane)
        XCTAssertEqual(GoogleTimelineTransport.map("IN_FERRY"), .boat)
        XCTAssertEqual(GoogleTimelineTransport.map("RUNNING"), .running)
        XCTAssertEqual(GoogleTimelineTransport.map("UNKNOWN_ACTIVITY_TYPE"), .unknown)
        XCTAssertEqual(GoogleTimelineTransport.map("SKIING"), .unknown)
    }

    func testWaypointLatE7AndRecordsLatitudeE7ShareTheSameDegrees() {
        let waypoint = GoogleTimelineCoordinates.coordinate(
            from: ["latE7": 525200000, "lngE7": 134000000]
        )
        let record = GoogleTimelineCoordinates.coordinate(
            from: ["latitudeE7": 525200000, "longitudeE7": 134000000]
        )
        XCTAssertEqual(waypoint?.latitude ?? 0, 52.52, accuracy: 0.0000001)
        XCTAssertEqual(record?.latitude ?? 0, 52.52, accuracy: 0.0000001)
        XCTAssertEqual(waypoint?.longitude ?? 0, record?.longitude ?? 0, accuracy: 0.0000001)
    }

    func testParsesDegreeAndGeoLatLngStrings() {
        let degree = GoogleTimelineCoordinates.parseLatLng("52.52°, 13.40°")
        let geo = GoogleTimelineCoordinates.parseLatLng("geo:52.52,13.40")
        XCTAssertEqual(degree?.latitude ?? 0, 52.52, accuracy: 0.0001)
        XCTAssertEqual(geo?.latitude ?? 0, 52.52, accuracy: 0.0001)
        XCTAssertEqual(degree?.longitude ?? 0, geo?.longitude ?? 0, accuracy: 0.0001)
    }

    // MARK: Records stream

    func testRecordsScannerReadsAllFourMiniPoints() throws {
        let data = try fixtureData("records-mini.json")
        var points: [LocationLogPoint] = []
        let count = try GoogleTimelineRecordsScanner.forEachRecord(in: data) { point in
            points.append(point)
            return true
        }
        XCTAssertEqual(count, 4)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.first?.latitude ?? 0, 52.52, accuracy: 0.0001)
        XCTAssertEqual(points.last?.latitude ?? 0, 52.53, accuracy: 0.0001)
        XCTAssertNotNil(points.last?.timestamp)
    }

    func testRecordsScannerStopsEarly() throws {
        let data = try fixtureData("records-mini.json")
        var count = 0
        _ = try GoogleTimelineRecordsScanner.forEachRecord(in: data) { _ in
            count += 1
            return count < 2
        }
        XCTAssertEqual(count, 2)
    }

    func testRecordsScannerReadsFilesLargerThanItsReadBuffer() throws {
        let data = recordsJSON(count: 3_000)
        XCTAssertGreaterThan(data.count, 3 * 64 * 1024)
        let url = try temporaryFile(named: "Records.json", contents: data)

        var incomplete = false
        var points = 0
        let count = try GoogleTimelineRecordsScanner.forEachRecord(at: url, onIncomplete: {
            incomplete = true
        }) { _ in
            points += 1
            return true
        }

        XCTAssertEqual(count, 3_000)
        XCTAssertEqual(points, 3_000)
        XCTAssertFalse(incomplete)
    }

    func testRecordsScannerReportsAFileThatEndsEarly() throws {
        let whole = recordsJSON(count: 3_000)

        var cutMidRecord = false
        let midRecord = try GoogleTimelineRecordsScanner.forEachRecord(
            in: whole.prefix(whole.count - 30),
            onIncomplete: { cutMidRecord = true }
        ) { _ in true }
        XCTAssertTrue(cutMidRecord)
        XCTAssertEqual(midRecord, 2_999)

        var cutBeforeClose = false
        let beforeClose = try GoogleTimelineRecordsScanner.forEachRecord(
            in: whole.prefix(whole.count - 4),
            onIncomplete: { cutBeforeClose = true }
        ) { _ in true }
        XCTAssertTrue(cutBeforeClose)
        XCTAssertEqual(beforeClose, 3_000)
    }

    func testTruncatedRecordsImportWhatWasReadAndSaySo() async throws {
        let whole = recordsJSON(count: 200)
        let url = try temporaryFile(named: "Records.json", contents: whole.prefix(whole.count - 30))
        let collected = GoogleTimelineCollectedSources(recordsURLs: [url])

        let report = try await GoogleTimelineImportPipeline.run(
            collected: collected,
            container: try makeInMemoryContainer(),
            skipNaming: true,
            progress: { _, _ in }
        )

        XCTAssertEqual(report.recordsRead, 199)
        XCTAssertTrue(report.recordsWereIncomplete)
        XCTAssertTrue(report.summary.contains("Records.json was incomplete"))
    }

    func testTwoZipsWithTheSameMemberNameKeepBothFiles() throws {
        let first = recordsJSON(count: 1)
        let second = recordsJSON(count: 2)
        let firstZip = try temporaryFile(
            named: "takeout-1.zip",
            contents: MovesZipArchive.pack([MovesZipFile(path: "Records.json", data: first)])
        )
        let secondZip = try temporaryFile(
            named: "takeout-2.zip",
            contents: MovesZipArchive.pack([MovesZipFile(path: "Records.json", data: second)])
        )

        let collected = try GoogleTimelineSourceCollector.collect(from: [firstZip, secondZip])
        defer {
            if let temporary = collected.temporaryDirectory {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        XCTAssertEqual(collected.recordsURLs.count, 2)
        XCTAssertEqual(Set(collected.recordsURLs).count, 2)
        let contents = Set(try collected.recordsURLs.map { try Data(contentsOf: $0) })
        XCTAssertEqual(contents, [first, second])
    }

    func testAbsurdTimestampsAreIgnoredInsteadOfTrapping() {
        let huge = Data(#"{"latitudeE7":525200000,"longitudeE7":134000000,"timestamp":1e300}"#.utf8)
        XCTAssertNil(GoogleTimelineParser.parseRecordObject(data: huge))
        XCTAssertNil(GoogleTimelineTime.parse(1e300))
        XCTAssertNil(GoogleTimelineTime.parse("inf"))
        XCTAssertNotNil(GoogleTimelineTime.parse(1_600_000_000))
        XCTAssertNotNil(GoogleTimelineTime.parse("1600000000000"))
    }

    func testOnDeviceVisitReadsAGeoStringPlaceLocation() throws {
        let json = #"""
        [{"startTime":"2024-06-01T08:00:00Z","endTime":"2024-06-01T09:00:00Z",
          "visit":{"topCandidate":{"placeLocation":"geo:52.52,13.40"}}}]
        """#
        let draft = try GoogleTimelineParser.parseOnDevice(data: Data(json.utf8))
        XCTAssertEqual(draft.stays.count, 1)
        XCTAssertEqual(draft.stays.first?.latitude ?? 0, 52.52, accuracy: 0.0001)
    }

    // MARK: Semantic month

    func testSemanticMonthCoversEdgeCases() throws {
        let draft = try GoogleTimelineParser.parseSemanticMonth(data: try fixtureData("semantic-month.json"))
        XCTAssertEqual(draft.stays.count, 4, "Home, Cafe, Mall, Office; the Bookstore child is inside the Mall stay")
        XCTAssertEqual(draft.moves.count, 5, "walk, car, bus, flight, empty-start vehicle")
        XCTAssertEqual(draft.skippedSegmentCount, 1, "empty start/end with no path is skipped")

        let names = Set(draft.stays.compactMap(\.name))
        XCTAssertTrue(names.contains("Home"))
        XCTAssertTrue(names.contains("Cafe"))
        XCTAssertTrue(names.contains("Mall"))
        XCTAssertFalse(names.contains("Bookstore"), "a child visit would overlap its parent")
        XCTAssertTrue(names.contains("Office"))

        XCTAssertTrue(draft.stays.contains { $0.name == "Cafe" && $0.isUserConfirmed })

        let modes = Set(draft.moves.map(\.transportMode))
        XCTAssertTrue(modes.contains(.walking))
        XCTAssertTrue(modes.contains(.automotive))
        XCTAssertTrue(modes.contains(.train), "IN_BUS maps to train")
        XCTAssertTrue(modes.contains(.plane))

        let walk = try XCTUnwrap(draft.moves.first { $0.transportMode == .walking })
        XCTAssertGreaterThanOrEqual(walk.points.count, 3, "waypointPath.waypoints become interpolated points")

        let office = try XCTUnwrap(draft.stays.first { $0.name == "Office" })
        XCTAssertEqual(office.points.count, 2, "placeVisit simplifiedRawPath is kept on the stay")

        let emptyStart = try XCTUnwrap(draft.moves.first { $0.startDate == date("2020-01-03T08:00:00Z") })
        XCTAssertEqual(emptyStart.transportMode, .automotive, "missing activityType uses activities[0]")
        XCTAssertGreaterThanOrEqual(emptyStart.points.count, 2)
    }

    func testOccupancyDedupesRecordsAgainstSemanticVisits() throws {
        let draft = try GoogleTimelineParser.parseSemanticMonth(data: try fixtureData("semantic-month.json"))
        let index = GoogleOccupancyIndex(windows: draft.occupancy)

        let homeDuplicate = LocationLogPoint(
            latitude: 52.52,
            longitude: 13.40,
            timestamp: date("2020-01-02T03:00:00Z")
        )
        XCTAssertTrue(index.covers(homeDuplicate))

        let laterGap = LocationLogPoint(
            latitude: 52.52,
            longitude: 13.40,
            timestamp: date("2020-01-04T03:00:00Z")
        )
        XCTAssertFalse(index.covers(laterGap))

        let walkTime = LocationLogPoint(
            latitude: 48.0,
            longitude: 2.0,
            timestamp: date("2020-01-02T08:05:00Z")
        )
        XCTAssertTrue(index.covers(walkTime), "Records during a semantic trip are skipped by time")

        let farDuringHome = LocationLogPoint(latitude: 48.0, longitude: 2.0, timestamp: date("2020-01-02T03:00:00Z"))
        XCTAssertTrue(index.covers(farDuringHome), "a far fix during a semantic visit is noise or another device")

        let beforeHome = index.gapNumber(for: date("2019-12-30T03:00:00Z"))
        let afterAll = index.gapNumber(for: date("2020-01-04T03:00:00Z"))
        XCTAssertNotEqual(beforeHome, afterAll, "fixes either side of semantic history are separate gaps")
    }

    func testDeviceFilterKeepsTheCarriedPhoneEachHour() {
        let start = date("2015-06-01T08:00:00Z")
        var records: [GoogleTimelineRecord] = []
        // The phone walks east and reports every minute; the tablet at home every ten.
        for minute in 0..<120 {
            let time = start.addingTimeInterval(TimeInterval(minute * 60))
            records.append(GoogleTimelineRecord(point: LocationLogPoint(latitude: 37.77, longitude: -122.42 + Double(minute) * 0.0005, timestamp: time), deviceTag: 1))
            if minute.isMultiple(of: 10) {
                records.append(GoogleTimelineRecord(point: LocationLogPoint(latitude: 37.70, longitude: -122.47, timestamp: time), deviceTag: 2))
            }
        }
        // Next day the person has a new phone.
        let nextDay = start.addingTimeInterval(24 * 60 * 60)
        for minute in 0..<30 {
            records.append(GoogleTimelineRecord(point: LocationLogPoint(latitude: 37.80, longitude: -122.40, timestamp: nextDay.addingTimeInterval(TimeInterval(minute * 60))), deviceTag: 3))
        }

        let (points, dropped) = GoogleTimelineDeviceFilter.mainDevicePoints(records)
        XCTAssertEqual(dropped, 12)
        XCTAssertEqual(points.count, 150)
        XCTAssertFalse(points.contains { $0.latitude == 37.70 })
        XCTAssertEqual(points.map(\.timestamp), points.map(\.timestamp).sorted())
    }

    func testGoogleHistoryReplacesOverlappingPhotoStopsAndKeepsTheirPhotos() async throws {
        let container = try makeInMemoryContainer()
        let seed = ModelContext(container)
        let day = DayTimeline(dayStart: date("2020-03-01T00:00:00Z"))
        seed.insert(day)
        func photoVisit(_ from: String, _ to: String, latitude: Double, longitude: Double) -> VisitPlace {
            let visit = VisitPlace(arrivalDate: date(from), departureDate: date(to), latitude: latitude, longitude: longitude, horizontalAccuracy: 50)
            visit.origin = .photoInferred
            visit.dayTimeline = day
            seed.insert(visit)
            return visit
        }
        // Google says the person spent 10:00–12:00 at a museum.
        let duringMuseum = photoVisit("2020-03-01T10:30:00Z", "2020-03-01T11:30:00Z", latitude: 48.875, longitude: 2.35)
        let named = photoVisit("2020-03-01T11:00:00Z", "2020-03-01T11:20:00Z", latitude: 48.84, longitude: 2.30)
        named.userLabel = "Picnic"
        let later = photoVisit("2020-03-01T18:00:00Z", "2020-03-01T19:00:00Z", latitude: 48.80, longitude: 2.20)
        let photo = PhotoAttachment(assetLocalIdentifier: "museum-photo", capturedAt: date("2020-03-01T11:00:00Z"), latitude: 48.875, longitude: 2.35)
        photo.visitPlace = duringMuseum
        photo.dayTimeline = day
        seed.insert(photo)
        let walk = MoveSegment(dedupeKey: "photo-walk", startDate: date("2020-03-01T11:30:00Z"), endDate: date("2020-03-01T18:00:00Z"), transportMode: .walking, distanceMeters: 9_000, stepCount: nil)
        walk.origin = .photoInferred
        walk.startPlace = duringMuseum
        walk.endPlace = later
        walk.dayTimeline = day
        seed.insert(walk)
        try seed.save()
        let museumPhotoVisitID = duringMuseum.id
        let namedID = named.id
        let laterID = later.id

        let semantic = #"{"timelineObjects":[{"placeVisit":{"location":{"latitudeE7":488606111,"longitudeE7":23376362,"name":"Louvre Museum"},"duration":{"startTimestamp":"2020-03-01T10:00:00Z","endTimestamp":"2020-03-01T12:00:00Z"}}}]}"#
        let url = FileManager.default.temporaryDirectory.appending(path: "photo-yield-\(UUID().uuidString).json")
        try Data(semantic.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await GoogleTimelineImportPipeline.run(
            collected: GoogleTimelineCollectedSources(semanticURLs: [url]),
            container: container,
            skipNaming: true,
            progress: { _, _ in }
        )
        XCTAssertEqual(report.photoItemsReplaced, 2, "the stop inside the museum visit and the walk that left it")

        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let museumPhotoVisit = try XCTUnwrap(visits.first { $0.id == museumPhotoVisitID })
        XCTAssertNil(museumPhotoVisit.dayTimeline, "retired, not deleted")
        XCTAssertNotNil(visits.first { $0.id == namedID }?.dayTimeline, "a stop the person named stays")
        XCTAssertNotNil(visits.first { $0.id == laterID }?.dayTimeline, "a stop outside the Google history stays")
        let moved = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoAttachment>()).first)
        XCTAssertEqual(moved.visitPlace?.autoLabel, "Louvre Museum", "the photo moves to the stay that covers it")
        let liveMoves = try context.fetch(FetchDescriptor<MoveSegment>.live())
        XCTAssertFalse(liveMoves.contains { $0.dedupeKey == "photo-walk" })
    }

    // MARK: On-device

    func testOnDeviceParsesBothLatLngEncodingsAndRawSignals() throws {
        let draft = try GoogleTimelineParser.parseOnDevice(data: try fixtureData("timeline-ondevice.json"))
        XCTAssertEqual(draft.stays.count, 1)
        XCTAssertEqual(draft.moves.count, 1)
        XCTAssertEqual(draft.stays.first?.name, "Home")
        XCTAssertEqual(draft.moves.first?.transportMode, .walking)
        XCTAssertEqual(draft.moves.first?.points.count, 3, "timelinePath geo: and degree strings")

        let stayPoints = try XCTUnwrap(draft.stays.first?.points)
        XCTAssertGreaterThanOrEqual(stayPoints.count, 2, "rawSignals overlay the visit window")
        XCTAssertTrue(stayPoints.contains { abs($0.latitude - 52.521) < 0.0005 })
    }

    // MARK: Persistence

    func testSemanticImportWritesImportedOriginAndTrainMode() async throws {
        let container = try makeInMemoryContainer()
        let collected = GoogleTimelineCollectedSources(
            semanticURLs: [try fixtureURL("semantic-month.json")]
        )
        let report = try await GoogleTimelineImportPipeline.run(
            collected: collected,
            container: container,
            skipNaming: true,
            progress: { _, _ in }
        )

        XCTAssertEqual(report.semanticFileCount, 1)
        XCTAssertGreaterThanOrEqual(report.log.placeCount, 4)
        XCTAssertGreaterThanOrEqual(report.log.moveCount, 5)

        let context = ModelContext(container)
        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertTrue(places.contains { $0.autoLabel == "Home" && $0.origin == .imported })
        XCTAssertTrue(places.contains { $0.autoLabel == "Cafe" })
        XCTAssertFalse(places.contains { $0.autoLabel == "Bookstore" }, "a child visit is inside its parent's stay")
        XCTAssertTrue(moves.contains { $0.transportMode == .train && $0.origin == .imported })
        XCTAssertTrue(moves.contains { $0.transportMode == .plane })
        XCTAssertTrue(moves.allSatisfy { $0.transportModeSource == .imported })
    }

    func testRecordsAfterSemanticAreDedupedOnPersist() async throws {
        let container = try makeInMemoryContainer()
        let collected = GoogleTimelineCollectedSources(
            semanticURLs: [try fixtureURL("semantic-month.json")],
            recordsURLs: [try fixtureURL("records-mini.json")]
        )
        let report = try await GoogleTimelineImportPipeline.run(
            collected: collected,
            container: container,
            skipNaming: true,
            progress: { _, _ in }
        )

        XCTAssertEqual(report.recordsRead, 4)
        XCTAssertGreaterThan(report.recordsSkippedAsDuplicate, 0)
        XCTAssertLessThan(report.recordsSkippedAsDuplicate, 4, "the 21:30 deviceTag point is after the flight")
    }

    func testStoredZipRoundTripExtractsRecordsMini() throws {
        let payload = try fixtureData("records-mini.json")
        let zip = try storedZip(named: "Records.json", payload: payload)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moves-google-test-\(UUID().uuidString).zip")
        try zip.write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let entries = try GoogleTimelineZipReader.timelineEntries(in: zipURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.fileName, "Records.json")
        let extracted = try GoogleTimelineZipReader.extractData(entries[0], from: zipURL)
        var count = 0
        _ = try GoogleTimelineRecordsScanner.forEachRecord(in: extracted) { _ in
            count += 1
            return true
        }
        XCTAssertEqual(count, 4)
    }

    // MARK: Live Takeout (opt-in)

    /// Real `2021_APRIL.json` from Roger's Takeout. Copied to gitignored
    /// `import-staging/` so the Simulator does not read `/Volumes` (that path
    /// can hang). Enable with `Fixtures/GoogleTimeline/.run-live` or env
    /// `MOVES_RUN_GOOGLE_TAKEOUT_TESTS=1`.
    func testLiveTakeoutApril2021SemanticParses() throws {
        try XCTSkipUnless(liveTestsEnabled, "Set MOVES_RUN_GOOGLE_TAKEOUT_TESTS=1 or touch Fixtures/GoogleTimeline/.run-live")
        let url = try liveAprilURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        XCTAssertLessThan(data.count, 2_000_000, "a semantic month is small enough to decode whole")
        let draft = try GoogleTimelineParser.parseSemanticMonth(data: data)
        XCTAssertGreaterThan(draft.stays.count, 10)
        XCTAssertGreaterThan(draft.moves.count, 10)
        print("WS10 live 2021_APRIL: stays=\(draft.stays.count) moves=\(draft.moves.count) skipped=\(draft.skippedSegmentCount) bytes=\(data.count)")
    }

    /// Streams a 2 MiB head of the real Records.json (same pretty-printed
    /// `locations[]` shape as the 308 MiB file) without loading it whole.
    func testLiveTakeoutRecordsStreamFirstTwoThousand() throws {
        try XCTSkipUnless(liveTestsEnabled, "Set MOVES_RUN_GOOGLE_TAKEOUT_TESTS=1 or touch Fixtures/GoogleTimeline/.run-live")
        let url = try liveRecordsHeadURL()
        var first: Date?
        var last: Date?
        var count = 0
        _ = try GoogleTimelineRecordsScanner.forEachRecord(at: url) { point in
            if first == nil { first = point.timestamp }
            last = point.timestamp
            count += 1
            return count < 2_000
        }
        XCTAssertGreaterThanOrEqual(count, 100, "the 2 MiB head should contain well over 100 complete records")
        XCTAssertNotNil(first)
        print("WS10 live Records head: count=\(count) first=\(String(describing: first)) last=\(String(describing: last))")
    }

    func testLiveTakeoutStagingFilesArePresent() throws {
        try XCTSkipUnless(liveTestsEnabled, "Set MOVES_RUN_GOOGLE_TAKEOUT_TESTS=1 or touch Fixtures/GoogleTimeline/.run-live")
        let april = try liveAprilURL()
        let records = try liveRecordsHeadURL()
        XCTAssertTrue(april.lastPathComponent.contains("APRIL") || april.lastPathComponent.contains("April") || april.path.contains("2021_APRIL"))
        XCTAssertGreaterThan((try? records.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 100_000)
        print("WS10 live files: april=\(april.path) records=\(records.path)")
    }

    // MARK: Helpers

    private var liveTestsEnabled: Bool {
        if ProcessInfo.processInfo.environment["MOVES_RUN_GOOGLE_TAKEOUT_TESTS"] == "1" {
            return true
        }
        // Flag file next to the fixtures so a local `touch` enables live tests
        // without scheme environment variables (xcodebuild does not forward
        // host env into the iOS Simulator test process).
        let flag = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/GoogleTimeline/.run-live")
        return FileManager.default.fileExists(atPath: flag.path)
    }

    private func liveAprilURL() throws -> URL {
        let staging = stagingDirectory().appending(path: "2021_APRIL.json")
        guard FileManager.default.fileExists(atPath: staging.path) else {
            throw XCTSkip("Copy 2021_APRIL.json into import-staging/GoogleTimeline/")
        }
        return staging
    }

    private func liveRecordsHeadURL() throws -> URL {
        let staging = stagingDirectory().appending(path: "records-head.json")
        if FileManager.default.fileExists(atPath: staging.path) {
            return staging
        }
        throw XCTSkip("Copy a head of Records.json into import-staging/GoogleTimeline/records-head.json")
    }

    private func stagingDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "import-staging/GoogleTimeline", directoryHint: .isDirectory)
    }

    /// A pretty-printed `locations` array, one small record per line.
    private func recordsJSON(count: Int) -> Data {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let formatter = ISO8601DateFormatter()
        let records = (0..<count).map { index -> String in
            let timestamp = formatter.string(from: start.addingTimeInterval(TimeInterval(index * 60)))
            return #"    {"latitudeE7": \#(525_200_000 + index), "longitudeE7": 134000000, "accuracy": 20, "timestamp": "\#(timestamp)"}"#
        }
        return Data("{\n  \"locations\": [\n\(records.joined(separator: ",\n"))\n  ]\n}\n".utf8)
    }

    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("moves-google-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func detect(_ fileName: String) throws -> GoogleTimelineFormat? {
        let peek = try GoogleTimelineParser.peekString(at: fixtureURL(fileName))
        return GoogleTimelineParser.detect(peek: peek)
    }

    private func fixtureURL(_ fileName: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/GoogleTimeline", directoryHint: .isDirectory)
            .appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing \(fileName)")
        }
        return url
    }

    private func fixtureData(_ fileName: String) throws -> Data {
        try Data(contentsOf: try fixtureURL(fileName))
    }

    private func date(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)!
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Minimal ZIP with one stored (uncompressed) entry, for the zip reader.
    private func storedZip(named fileName: String, payload: Data) throws -> Data {
        let name = Data(fileName.utf8)
        var local = Data()
        local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        local.append(contentsOf: [0x14, 0x00]) // version
        local.append(contentsOf: [0x00, 0x00]) // flags
        local.append(contentsOf: [0x00, 0x00]) // stored
        local.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // time/date
        local.append(u32: 0) // crc skipped for stored test; reader does not check
        local.append(u32: UInt32(payload.count))
        local.append(u32: UInt32(payload.count))
        local.append(u16: UInt16(name.count))
        local.append(u16: 0)
        local.append(name)
        local.append(payload)

        var central = Data()
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        central.append(contentsOf: [0x14, 0x00, 0x14, 0x00])
        central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        central.append(u32: 0)
        central.append(u32: UInt32(payload.count))
        central.append(u32: UInt32(payload.count))
        central.append(u16: UInt16(name.count))
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u32: 0)
        central.append(u32: 0)
        central.append(name)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        eocd.append(u16: 1)
        eocd.append(u16: 1)
        eocd.append(u32: UInt32(central.count))
        eocd.append(u32: UInt32(local.count))
        eocd.append(u16: 0)

        var zip = Data()
        zip.append(local)
        zip.append(central)
        zip.append(eocd)
        return zip
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(u32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - Full Takeout on the real store

/// Runs the whole Google Takeout export from `import-staging/GoogleTimeline/full-2024-12/`
/// against a copy of the latest phone backup, the way the phone would, and audits the result.
///
/// Opt-in, because it takes minutes: pass `TEST_RUNNER_MOVES_GOOGLE_FULL=1` to `xcodebuild test`.
/// The imported store is kept in `import-staging/google-full-result/` for a look in the Simulator
/// (`SIMCTL_CHILD_MOVES_SIMULATOR_STORE=<that folder>/default.store`).
final class GoogleTimelineFullImportTests: XCTestCase {
    @MainActor
    func testFullTakeoutImportsOntoTheRealStore() async throws {
        guard ProcessInfo.processInfo.environment["MOVES_GOOGLE_FULL"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MOVES_GOOGLE_FULL=1 to run the full Google Timeline import")
        }
        let staging = Self.stagingRoot()
        let export = staging.appending(path: "GoogleTimeline/full-2024-12", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: export.path) else {
            throw XCTSkip("Copy the Takeout Location History folder into import-staging/GoogleTimeline/full-2024-12/")
        }

        let result = staging.appending(path: "google-full-result", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: result)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let backup = try Self.latestDeviceBackupStore(in: staging)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: backup.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: result.appending(path: "default.store" + suffix))
        }
        let storeURL = result.appending(path: "default.store")
        print("FULL backup: \(backup.path)")

        let container = try Self.makeContainer(storeURL: storeURL)
        let before = try Self.audit(container)
        print("FULL before: \(before)")

        let collected = try GoogleTimelineSourceCollector.collect(from: [export])
        print("FULL sources: semantic=\(collected.semanticURLs.count) records=\(collected.recordsURLs.count) onDevice=\(collected.onDeviceURLs.count)")

        let meter = MemoryMeter()
        meter.start()
        let clock = ContinuousClock()
        let stages = StageLog(clock: clock, meter: meter)
        let began = clock.now
        let report = try await GoogleTimelineImportPipeline.run(
            collected: collected,
            container: container,
            skipNaming: true,
            progress: { fraction, text in stages.note(fraction, text) }
        )
        let elapsed = clock.now - began
        meter.stop()
        print("FULL elapsed: \(elapsed), peak footprint \(meter.peakMB) MB")
        print("FULL report: \(report.summary)")
        print("FULL report detail: places=\(report.log.placeCount) merged=\(report.log.mergedPlaceCount) moves=\(report.log.moveCount) mergedMoves=\(report.log.mergedMoveCount) samples=\(report.log.sampleCount) recordsRead=\(report.recordsRead) recordsCovered=\(report.recordsSkippedAsDuplicate) skippedSegments=\(report.skippedSegmentCount)")

        let after = try Self.audit(container)
        print("FULL after: \(after)")

        XCTAssertGreaterThan(after.visits, before.visits)
        XCTAssertEqual(after.movesWithoutEnds, before.movesWithoutEnds, "every imported trip has both ends")

        // A second import of the same export must add nothing.
        let again = try await GoogleTimelineImportPipeline.run(
            collected: try GoogleTimelineSourceCollector.collect(from: [export]),
            container: container,
            skipNaming: true,
            progress: { _, _ in }
        )
        let afterAgain = try Self.audit(container)
        print("FULL second run: \(again.summary)")
        print("FULL after second run: \(afterAgain)")
        XCTAssertEqual(afterAgain.visits, after.visits, "re-importing adds no visits")
        XCTAssertEqual(afterAgain.moves, after.moves, "re-importing adds no trips")
        XCTAssertEqual(afterAgain.samples, after.samples, "re-importing adds no fixes")
    }

    // MARK: Audit

    struct Audit: CustomStringConvertible {
        var days = 0
        var visits = 0
        var importedVisits = 0
        var moves = 0
        var importedMoves = 0
        var samples = 0
        var googleSamples = 0
        var movesWithoutEnds = 0
        /// Live visits that overlap the previous one by more than five minutes.
        var overlappingVisits = 0
        /// Live trips that overlap a visit (other than their own ends) by more than five minutes.
        var tripsOverlappingVisits = 0
        var importedVisitsByYear: [Int: Int] = [:]

        var description: String {
            let years = importedVisitsByYear.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            return "days=\(days) visits=\(visits) (imported \(importedVisits)) moves=\(moves) (imported \(importedMoves)) samples=\(samples) (google \(googleSamples)) movesWithoutEnds=\(movesWithoutEnds) overlappingVisits=\(overlappingVisits) tripsOverlappingVisits=\(tripsOverlappingVisits) importedByYear=[\(years)]"
        }
    }

    @MainActor
    static func audit(_ container: ModelContainer) throws -> Audit {
        let context = ModelContext(container)
        var audit = Audit()
        audit.days = try context.fetchCount(FetchDescriptor<DayTimeline>())
        audit.samples = try context.fetchCount(FetchDescriptor<LocationSample>())
        let google = LocationSampleSource.googleTimelineImport.rawValue
        audit.googleSamples = try context.fetchCount(FetchDescriptor<LocationSample>(predicate: #Predicate { $0.sourceRawValue == google }))

        let visits = try context.fetch(FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\.arrivalDate)]))
        audit.visits = visits.count
        let calendar = Calendar(identifier: .gregorian)
        var latestEnd: Date?
        for visit in visits {
            if visit.origin == .imported {
                audit.importedVisits += 1
                audit.importedVisitsByYear[calendar.component(.year, from: visit.arrivalDate), default: 0] += 1
            }
            let end = visit.departureDate ?? visit.arrivalDate
            if let latestEnd, latestEnd.timeIntervalSince(visit.arrivalDate) > 5 * 60 {
                audit.overlappingVisits += 1
            }
            latestEnd = max(latestEnd ?? end, end)
        }

        let moves = try context.fetch(FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)]))
        audit.moves = moves.count
        var visitIndex = 0
        for move in moves {
            if move.origin == .imported { audit.importedMoves += 1 }
            if move.startPlace == nil || move.endPlace == nil { audit.movesWithoutEnds += 1 }
            while visitIndex < visits.count, (visits[visitIndex].departureDate ?? visits[visitIndex].arrivalDate) < move.startDate {
                visitIndex += 1
            }
            var index = visitIndex
            while index < visits.count, visits[index].arrivalDate < move.endDate {
                let visit = visits[index]
                if visit !== move.startPlace, visit !== move.endPlace {
                    let overlap = min(move.endDate, visit.departureDate ?? visit.arrivalDate)
                        .timeIntervalSince(max(move.startDate, visit.arrivalDate))
                    if overlap > 5 * 60 {
                        audit.tripsOverlappingVisits += 1
                        break
                    }
                }
                index += 1
            }
        }
        return audit
    }

    // MARK: Helpers

    static func stagingRoot() -> URL {
        // A worktree sits inside the main checkout, which holds the private files.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var staging = directory.appending(path: "import-staging")
        while !FileManager.default.fileExists(atPath: staging.path), directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
            staging = directory.appending(path: "import-staging")
        }
        return staging
    }

    static func latestDeviceBackupStore(in staging: URL) throws -> URL {
        let backups = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0.hasPrefix("device-backup-") }
            .sorted()
        for name in backups.reversed() {
            let store = staging.appending(path: name)
                .appending(path: "group-container/Library/Application Support/default.store")
            if FileManager.default.fileExists(atPath: store.path) { return store }
        }
        throw XCTSkip("No device backup with a timeline store under import-staging")
    }

    static func makeContainer(storeURL: URL) throws -> ModelContainer {
        let timelineSchema = Schema(MovesTimelineSchema.models)
        let cacheSchema = Schema([ShareMapAggregate.self])
        return try ModelContainer(
            for: Schema(MovesTimelineSchema.models + [ShareMapAggregate.self]),
            configurations: [
                ModelConfiguration(schema: timelineSchema, url: storeURL, cloudKitDatabase: .none),
                ModelConfiguration(
                    "ShareMapCache",
                    schema: cacheSchema,
                    url: storeURL.deletingLastPathComponent().appending(path: "ShareMapCache.store"),
                    cloudKitDatabase: .none
                ),
            ]
        )
    }
}

/// Prints each new import stage with how long the last one took and the memory in use.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ContinuousClock
    private let meter: MemoryMeter
    private var lastStage = ""
    private var stageStart: ContinuousClock.Instant

    init(clock: ContinuousClock, meter: MemoryMeter) {
        self.clock = clock
        self.meter = meter
        stageStart = clock.now
    }

    func note(_ fraction: Double, _ text: String) {
        let stage = text.components(separatedBy: CharacterSet.decimalDigits).first ?? text
        lock.lock()
        defer { lock.unlock() }
        guard stage != lastStage else { return }
        print("FULL stage \(String(format: "%.3f", fraction)) after \(clock.now - stageStart) [\(meter.currentMB) MB]: \(text)")
        lastStage = stage
        stageStart = clock.now
    }
}

/// Samples this process's memory footprint (what jetsam counts on the phone).
private final class MemoryMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = false

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    var peakMB: Int { lock.lock(); defer { lock.unlock() }; return Int(peak / 1_048_576) }
    var currentMB: Int { Int(Self.footprint() / 1_048_576) }

    func start() {
        lock.lock(); running = true; peak = Self.footprint(); lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                let value = Self.footprint()
                lock.lock()
                peak = max(peak, value)
                let keepGoing = running
                lock.unlock()
                if !keepGoing { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
}
