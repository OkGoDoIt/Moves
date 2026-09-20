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

    // MARK: Semantic month

    func testSemanticMonthCoversEdgeCases() throws {
        let draft = try GoogleTimelineParser.parseSemanticMonth(data: try fixtureData("semantic-month.json"))
        XCTAssertEqual(draft.stays.count, 5, "Home, Cafe, Mall, Bookstore child, Office")
        XCTAssertEqual(draft.moves.count, 5, "walk, car, bus, flight, empty-start vehicle")
        XCTAssertEqual(draft.skippedSegmentCount, 1, "empty start/end with no path is skipped")

        let names = Set(draft.stays.compactMap(\.name))
        XCTAssertTrue(names.contains("Home"))
        XCTAssertTrue(names.contains("Cafe"))
        XCTAssertTrue(names.contains("Mall"))
        XCTAssertTrue(names.contains("Bookstore"))
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
        XCTAssertGreaterThanOrEqual(report.log.placeCount, 5)
        XCTAssertGreaterThanOrEqual(report.log.moveCount, 5)

        let context = ModelContext(container)
        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertTrue(places.contains { $0.autoLabel == "Home" && $0.origin == .imported })
        XCTAssertTrue(places.contains { $0.autoLabel == "Cafe" })
        XCTAssertTrue(places.contains { $0.autoLabel == "Bookstore" }, "childVisits become extra stays")
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
