import CoreLocation
import Foundation
import SwiftData
import XCTest
@testable import Moves

/// Covers the location-log pipeline: GPX streaming, stay/move segmentation,
/// speed-based transport inference, and the bulk SwiftData writer.
///
/// The real-file tests read the Location Log exports from `import-staging/`
/// (gitignored personal data) and skip when they are absent.
final class LocationLogImportTests: XCTestCase {
    private static let subsetFile = "LocationLog 01-Aug-2026 to 01-Jan-2026.gpx"
    private static let fullYearFile = "LocationLog 13-Sep-2026 to 10-Sep-2025.gpx"

    // MARK: Synthetic

    func testSegmenterBuildsStaysAndMovesFromSyntheticLog() {
        let points = SyntheticLog.dayWithWalkDriveAndFlight()
        let timeline = LocationLogSegmenter().segment(points)

        let stays = timeline.stays
        let moves = timeline.moves
        XCTAssertEqual(stays.count, 4, "home, cafe, home again, hotel abroad")
        XCTAssertEqual(moves.count, 3, "walk, drive, flight")
        XCTAssertEqual(moves.map(\.transportMode), [.walking, .automotive, .plane])

        // Stays and moves alternate and share boundary fixes.
        for (index, segment) in timeline.segments.enumerated() {
            switch segment {
            case .stay: XCTAssertTrue(index.isMultiple(of: 2))
            case .move: XCTAssertFalse(index.isMultiple(of: 2))
            }
        }
        XCTAssertEqual(stays[0].departureDate, moves[0].startDate)
        XCTAssertEqual(moves[0].endDate, stays[1].arrivalDate)

        // A recording gap at the same spot still counts as one stay.
        XCTAssertGreaterThan(stays[2].duration, 7 * 60 * 60)
        XCTAssertEqual(stays[2].points.count, 3)

        // Flight distance survives even though the logger was off in the air.
        XCTAssertGreaterThan(moves[2].distanceMeters, 10_000_000)
        XCTAssertGreaterThan(moves[2].longestGap, 10 * 60 * 60)
    }

    func testSegmenterMergesWobbleAtTheSamePlace() {
        var points: [LocationLogPoint] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // An hour at home, then the fix drifts 125 m north (a different room
        // or a bad fix) and sits there for half an hour. That is one stay.
        points += SyntheticLog.stay(at: SyntheticLog.home, from: start, minutes: 60)
        let drifted = SyntheticLog.home.offset(north: 125)
        points.append(SyntheticLog.point(drifted, at: start.addingTimeInterval(61 * 60)))
        points.append(SyntheticLog.point(drifted, at: start.addingTimeInterval(91 * 60)))

        let timeline = LocationLogSegmenter().segment(points)
        XCTAssertEqual(timeline.stays.count, 1)
        XCTAssertEqual(timeline.moves.count, 0)
        XCTAssertEqual(timeline.stays.first?.duration ?? 0, 91 * 60, accuracy: 1)
        XCTAssertEqual(timeline.stays.first?.points.count, 5)
    }

    func testClassifierUsesDistanceWeightedSpeed() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 5 minutes walking to the car, then 10 km in 12 minutes.
        var points = SyntheticLog.leg(from: SyntheticLog.home, bearingNorthMeters: 300, from: start, minutes: 5, stepMinutes: 1)
        let carStart = points.last!
        points += SyntheticLog.leg(from: carStart.coordinate, bearingNorthMeters: 10_000, from: carStart.timestamp, minutes: 12, stepMinutes: 2).dropFirst()
        XCTAssertEqual(LocationLogTransportClassifier.classify(points), .automotive)

        let walk = SyntheticLog.leg(from: SyntheticLog.home, bearingNorthMeters: 1_500, from: start, minutes: 20, stepMinutes: 2)
        XCTAssertEqual(LocationLogTransportClassifier.classify(walk), .walking)

        let ride = SyntheticLog.leg(from: SyntheticLog.home, bearingNorthMeters: 6_000, from: start, minutes: 22, stepMinutes: 2)
        XCTAssertEqual(LocationLogTransportClassifier.classify(ride), .cycling)

        let flight = [
            SyntheticLog.point(SyntheticLog.home, at: start),
            SyntheticLog.point(SyntheticLog.saigon, at: start.addingTimeInterval(15 * 60 * 60)),
        ]
        XCTAssertEqual(LocationLogTransportClassifier.classify(flight), .plane)
    }

    func testGPXParserReadsOffsetsAndSkipsUntimedPoints() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="37.7" lon="-122.4"><time>2026-01-01T01:49:51-08:00</time></trkpt>
            <trkpt lat="37.8" lon="-122.5"><ele>12.5</ele><time>2026-01-01T09:52:01.250Z</time></trkpt>
            <trkpt lat="37.9" lon="-122.6"></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let result = try LocationLogGPXParser.parse(data: Data(gpx.utf8))
        XCTAssertEqual(result.points.count, 2)
        XCTAssertEqual(result.untimedCount, 1)
        XCTAssertEqual(result.points[0].timestamp, Date(timeIntervalSince1970: 1_767_260_991))
        XCTAssertEqual(result.points[1].altitude, 12.5)
        XCTAssertEqual(result.points[1].timestamp.timeIntervalSince1970, 1_767_261_121.25, accuracy: 0.001)
    }

    // MARK: Real files

    func testRealSubsetSegmentsIntoDailyStaysAndTrips() throws {
        let points = try realPoints(named: Self.subsetFile)
        XCTAssertEqual(points.count, 18_558)

        let clock = ContinuousClock()
        var timeline: LocationLogTimeline?
        let elapsed = clock.measure {
            timeline = LocationLogSegmenter().segment(points)
        }
        let result = try XCTUnwrap(timeline)
        XCTAssertLessThan(elapsed, .seconds(5), "segmentation should be near-instant")

        XCTAssertGreaterThan(result.stays.count, 800)
        XCTAssertGreaterThan(result.moves.count, 800)
        XCTAssertLessThanOrEqual(abs(result.stays.count - result.moves.count), 2)

        // Every move has real geometry and no move is absurdly long unless it flew.
        for move in result.moves {
            XCTAssertGreaterThanOrEqual(move.points.count, 2)
            XCTAssertGreaterThan(move.endDate, move.startDate)
            if move.transportMode != .plane {
                XCTAssertLessThan(move.distanceMeters, 600_000, "\(move.startDate) \(move.transportMode)")
            }
        }

        let histogram = Dictionary(grouping: result.moves, by: \.transportMode)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: " ")
        print("LocationLog subset: \(result.stays.count) stays, \(result.moves.count) moves, modes: \(histogram)")

        let modes = Set(result.moves.map(\.transportMode))
        XCTAssertTrue(modes.contains(.walking))
        XCTAssertTrue(modes.contains(.automotive))
        XCTAssertTrue(modes.contains(.plane), "the log ends in Saigon, so a trans-Pacific flight must exist")
        XCTAssertLessThan(
            Double(result.moves.filter { $0.transportMode == .unknown }.count) / Double(result.moves.count),
            0.1,
            "almost every trip should get a transport mode"
        )

        // Home should be the dominant overnight stay.
        let home = CLLocationCoordinate2D(latitude: 37.749247, longitude: -122.460294)
        let nightsAtHome = result.stays.filter {
            LocationLogGeometry.distance(from: $0.coordinate, to: home) <= 150 && $0.duration >= 6 * 60 * 60
        }
        XCTAssertGreaterThan(nightsAtHome.count, 60)
    }

    func testRealSubsetImportsQuicklyAndIsIdempotent() throws {
        executionTimeAllowance = 300
        let points = try realPoints(named: Self.subsetFile)
        let timeline = LocationLogSegmenter().segment(points)
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let clock = ContinuousClock()
        var report: LocationLogImportReport?
        let elapsed = try clock.measure {
            report = try repository.importLocationLog(timeline, source: .fileRouteImport)
        }
        let first = try XCTUnwrap(report)
        XCTAssertLessThan(elapsed, .seconds(120), "seven months of fixes must import in well under the watchdog limit")

        // The log starts and ends mid-trip, so up to two point-shaped
        // endpoint places join the stays.
        XCTAssertGreaterThanOrEqual(first.placeCount, timeline.stays.count)
        XCTAssertLessThanOrEqual(first.placeCount, timeline.stays.count + 2)
        XCTAssertEqual(first.moveCount, timeline.moves.count)
        XCTAssertEqual(first.sampleCount, timeline.pointCount)
        XCTAssertEqual(first.newPlaces.count, first.placeCount)

        let context = ModelContext(container)
        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        let samples = try context.fetch(FetchDescriptor<LocationSample>())
        XCTAssertEqual(places.count, first.placeCount)
        XCTAssertEqual(moves.count, first.moveCount)
        XCTAssertEqual(samples.count, first.sampleCount)
        XCTAssertTrue(moves.allSatisfy { $0.startPlace != nil && $0.endPlace != nil && $0.dayTimeline != nil })
        XCTAssertTrue(places.allSatisfy { $0.departureDate != nil && $0.dayTimeline != nil })
        XCTAssertTrue(samples.allSatisfy { $0.dayTimeline != nil })
        XCTAssertGreaterThan(moves.filter { !$0.samples.isEmpty }.count, moves.count * 9 / 10)

        let second = try repository.importLocationLog(timeline, source: .fileRouteImport)
        XCTAssertEqual(second.placeCount, 0)
        XCTAssertEqual(second.moveCount, 0)
        XCTAssertEqual(second.sampleCount, 0)
        XCTAssertEqual(second.mergedPlaceCount, first.placeCount)
        XCTAssertEqual(second.mergedMoveCount, first.moveCount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, places.count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).count, moves.count)
    }

    func testRealSubsetReusesUserLabelsAndExistingVisits() throws {
        executionTimeAllowance = 300
        let points = try realPoints(named: Self.subsetFile)
        let timeline = LocationLogSegmenter().segment(points)
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        // Simulate a visit the app already recorded at home on the first night.
        let home = CLLocationCoordinate2D(latitude: 37.749247, longitude: -122.460294)
        let firstHomeStay = try XCTUnwrap(
            timeline.stays.first { LocationLogGeometry.distance(from: $0.coordinate, to: home) <= 150 }
        )
        let existing = VisitPlace(
            arrivalDate: firstHomeStay.arrivalDate.addingTimeInterval(20 * 60),
            departureDate: firstHomeStay.departureDate.addingTimeInterval(-60 * 60),
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 30,
            userLabel: "Home"
        )
        context.insert(existing)
        try context.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let report = try repository.importLocationLog(timeline, source: .fileRouteImport)
        XCTAssertEqual(report.mergedPlaceCount, 1)
        XCTAssertGreaterThanOrEqual(report.placeCount, timeline.stays.count - 1)
        XCTAssertLessThanOrEqual(report.placeCount, timeline.stays.count + 1)

        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let homePlaces = places.filter { LocationLogGeometry.distance(from: $0.coordinate, to: home) <= 150 }
        XCTAssertGreaterThan(homePlaces.count, 60)
        XCTAssertTrue(homePlaces.allSatisfy { $0.userLabel == "Home" }, "the user label should propagate to every stay at home")

        let merged = try XCTUnwrap(places.first { $0.id == existing.id })
        XCTAssertEqual(merged.departureDate, firstHomeStay.departureDate)
    }

    /// Drives the same code path as the Files picker, including the
    /// background context and the untimed-track fallback.
    @MainActor
    func testRouteFileImporterHandlesWholeLogWithoutBlocking() async throws {
        let url = try realFileURL(named: Self.subsetFile)
        let container = try makeInMemoryContainer()
        let importer = RouteFileImporter(modelContext: container.mainContext)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await importer.importFiles(urls: [url])
        }

        XCTAssertNil(importer.lastErrorMessage)
        let report = try XCTUnwrap(importer.lastReport)
        XCTAssertEqual(report.fileCount, 1)
        XCTAssertGreaterThan(report.log.placeCount, 1_000)
        XCTAssertGreaterThan(report.log.moveCount, 1_000)
        XCTAssertEqual(report.log.sampleCount, 18_558)
        XCTAssertEqual(report.untimedRouteCount, 0)
        XCTAssertLessThan(elapsed, .seconds(120))
        XCTAssertFalse(importer.isImporting)

        let places = try container.mainContext.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(places.count, report.log.placeCount)
    }

    func testFullYearImportsWithinBudget() throws {
        executionTimeAllowance = 600
        let points = try realPoints(named: Self.fullYearFile)
        XCTAssertGreaterThan(points.count, 30_000)

        let timeline = LocationLogSegmenter().segment(points)
        XCTAssertGreaterThan(timeline.stays.count, 1_500)

        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let clock = ContinuousClock()
        var report: LocationLogImportReport?
        let elapsed = try clock.measure {
            report = try repository.importLocationLog(timeline, source: .fileRouteImport)
        }
        let result = try XCTUnwrap(report)
        XCTAssertLessThan(elapsed, .seconds(240))
        XCTAssertEqual(result.sampleCount, timeline.pointCount)
        XCTAssertGreaterThanOrEqual(result.placeCount, timeline.stays.count)
        XCTAssertLessThanOrEqual(result.placeCount, timeline.stays.count + 2)

        let clusters = LocationLogPlaceNamer.clusters(for: result.newPlaces, radius: 100)
        XCTAssertLessThan(clusters.count, result.newPlaces.count / 2, "repeat visits should share one geocoder lookup")
        XCTAssertGreaterThan(clusters.first?.placeIDs.count ?? 0, 50, "the most-visited cluster is home")
    }

    /// The real-world order: restore the Moves export first, then layer the
    /// longer third-party log on top. Overlapping months must merge, not
    /// double up.
    func testLogImportOnTopOfMovesArchiveMergesOverlaps() throws {
        executionTimeAllowance = 600
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures", directoryHint: .isDirectory)
        let archiveFiles = try ["moves-all-days.geojson", "moves-all-days.gpx", "moves-all-days.csv"].map { name in
            let url = fixtures.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Missing \(name) in MovesTests/Fixtures/.")
            }
            return (name: name, data: try Data(contentsOf: url))
        }
        let archive = TimelineArchiveFileParser.parseAll(files: archiveFiles).archive
        let points = try realPoints(named: Self.fullYearFile)
        let log = LocationLogSegmenter().segment(points)

        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let archiveReport = try repository.importTimelineArchive(archive)
        let context = ModelContext(container)
        let placesBefore = try context.fetch(FetchDescriptor<VisitPlace>()).count
        let movesBefore = try context.fetch(FetchDescriptor<MoveSegment>()).count

        let logReport = try repository.importLocationLog(log, source: .fileRouteImport)
        // The Moves export only covers Aug 1 – Sep 17; the log ends Sep 13.
        // CLVisit splits one evening into several fragments, so one log stay
        // often absorbs several archive places.
        XCTAssertGreaterThan(logReport.mergedPlaceCount, 40, "six weeks of overlap should reuse the Moves visits")
        XCTAssertGreaterThan(logReport.mergedMoveCount, 15)
        XCTAssertGreaterThanOrEqual(logReport.placeCount + logReport.mergedPlaceCount, log.stays.count)

        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(places.count, placesBefore + logReport.placeCount)
        XCTAssertEqual(moves.count, movesBefore + logReport.moveCount)
        XCTAssertGreaterThanOrEqual(archiveReport.placeCount, 100)

        // Every stay at home picked up the user's label from the Moves export.
        let home = CLLocationCoordinate2D(latitude: 37.749247, longitude: -122.460294)
        let homePlaces = places.filter { LocationLogGeometry.distance(from: $0.coordinate, to: home) <= 120 }
        XCTAssertGreaterThan(homePlaces.count, 100)
        XCTAssertGreaterThan(
            Double(homePlaces.filter { $0.userLabel == "Home" }.count) / Double(homePlaces.count),
            0.95
        )
        XCTAssertTrue(moves.allSatisfy { $0.startPlace != nil && $0.endPlace != nil })
    }

    // MARK: Helpers

    private func realFileURL(named fileName: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "import-staging", directoryHint: .isDirectory)
            .appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing \(fileName) in import-staging/.")
        }
        return url
    }

    private func realPoints(named fileName: String) throws -> [LocationLogPoint] {
        try LocationLogGPXParser.parse(data: Data(contentsOf: realFileURL(named: fileName))).points
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

// MARK: - Synthetic log builder

private enum SyntheticLog {
    static let home = CLLocationCoordinate2D(latitude: 37.749247, longitude: -122.460294)
    static let cafe = home.offset(north: 1_400)
    static let sfo = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)
    static let saigon = CLLocationCoordinate2D(latitude: 10.8188, longitude: 106.6519)

    static func point(_ coordinate: CLLocationCoordinate2D, at date: Date) -> LocationLogPoint {
        LocationLogPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, timestamp: date)
    }

    /// Fixes every 30 minutes within ±20 m of `coordinate`.
    static func stay(at coordinate: CLLocationCoordinate2D, from start: Date, minutes: Int) -> [LocationLogPoint] {
        stride(from: 0, through: minutes, by: 30).enumerated().map { index, minute in
            let jitter = Double(index.isMultiple(of: 2) ? 20 : -20)
            return point(coordinate.offset(north: jitter), at: start.addingTimeInterval(TimeInterval(minute * 60)))
        }
    }

    /// Straight-line leg northwards with evenly spaced fixes.
    static func leg(
        from origin: CLLocationCoordinate2D,
        bearingNorthMeters: Double,
        from start: Date,
        minutes: Int,
        stepMinutes: Int
    ) -> [LocationLogPoint] {
        let steps = max(minutes / stepMinutes, 1)
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            return point(
                origin.offset(north: bearingNorthMeters * fraction),
                at: start.addingTimeInterval(TimeInterval(step * stepMinutes * 60))
            )
        }
    }

    /// Home → walk → cafe → drive → home (with a recording gap overnight) → gap
    /// flight → hotel in Saigon.
    static func dayWithWalkDriveAndFlight() -> [LocationLogPoint] {
        var points: [LocationLogPoint] = []
        var clock = Date(timeIntervalSince1970: 1_767_240_000)

        points += stay(at: home, from: clock, minutes: 120)
        clock = clock.addingTimeInterval(120 * 60)

        let walk = leg(from: home, bearingNorthMeters: 1_400, from: clock, minutes: 20, stepMinutes: 2)
        points += walk.dropFirst()
        clock = walk.last!.timestamp

        points += stay(at: cafe, from: clock, minutes: 60).dropFirst()
        clock = clock.addingTimeInterval(60 * 60)

        let drive = leg(from: cafe, bearingNorthMeters: -15_000, from: clock, minutes: 20, stepMinutes: 2)
        points += drive.dropFirst()
        clock = drive.last!.timestamp
        let farHome = drive.last!.coordinate

        // Overnight at the destination with the logger asleep for 8 hours.
        points.append(point(farHome.offset(north: 15), at: clock.addingTimeInterval(30 * 60)))
        points.append(point(farHome.offset(north: -15), at: clock.addingTimeInterval(8 * 60 * 60 + 30 * 60)))
        clock = clock.addingTimeInterval(8 * 60 * 60 + 30 * 60)

        // Flight: one fix at the gate, next fix 15 hours later in Saigon.
        points.append(point(saigon, at: clock.addingTimeInterval(15 * 60 * 60)))
        clock = clock.addingTimeInterval(15 * 60 * 60)
        points += stay(at: saigon, from: clock, minutes: 90).dropFirst()

        return points
    }
}

private extension CLLocationCoordinate2D {
    /// Shifts the coordinate north by `meters` (negative goes south).
    func offset(north meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + meters / 111_320, longitude: longitude)
    }
}
