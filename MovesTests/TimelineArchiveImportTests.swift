import CoreLocation
import Foundation
import SwiftData
import XCTest
@testable import Moves

final class TimelineArchiveImportTests: XCTestCase {
    func testGeoJSONParserRestoresLabelsModesAndMoveTimes() throws {
        let data = try Data(contentsOf: try fixtureURL(named: "moves-all-days.geojson"))
        let archive = try XCTUnwrap(parseSuccess(fileName: "moves-all-days.geojson", data: data))

        XCTAssertGreaterThanOrEqual(archive.places.count, 117)
        XCTAssertGreaterThanOrEqual(archive.moves.count, 69)
        XCTAssertGreaterThanOrEqual(archive.places.filter { $0.userLabel == "Home" }.count, 9)
        XCTAssertGreaterThanOrEqual(archive.places.filter { $0.autoLabel == "Golden Gate Park" }.count, 10)
        XCTAssertTrue(
            archive.places.contains { $0.autoLabel == "Koret Children’s Quarter" }
        )
        XCTAssertFalse(
            archive.places.contains {
                ($0.userLabel ?? "").contains("10.81393") || ($0.autoLabel ?? "").contains("10.81393")
            }
        )
        XCTAssertFalse(
            archive.moves.contains {
                $0.transportMode == .running && ($0.distanceMeters ?? 0) > 1_000_000
            }
        )
        XCTAssertFalse(
            archive.moves.contains {
                $0.transportMode == .unknown && ($0.distanceMeters ?? 0) > 5_000_000
            }
        )

        let modes = Set(archive.moves.map(\.transportMode))
        XCTAssertTrue(modes.contains(.walking))
        XCTAssertTrue(modes.contains(.automotive))
        XCTAssertTrue(modes.contains(.plane))

        let returnFlight = try XCTUnwrap(
            archive.moves.first {
                $0.transportMode == .plane
                    && $0.endPlaceTitle == "Tan Son Nhat International Airport"
            }
        )
        XCTAssertEqual(returnFlight.startPlaceTitle, "Dianne Feinstein International Terminal")
        XCTAssertEqual(returnFlight.points.count, 21)
        XCTAssertTrue(returnFlight.points.allSatisfy { $0.timestamp == nil })

        let outbound = try XCTUnwrap(
            archive.moves.first {
                $0.transportMode == .plane
                    && abs($0.startDate.timeIntervalSince(date("2026-08-23T10:47:50.000Z"))) < 2
            }
        )
        XCTAssertGreaterThan((outbound.distanceMeters ?? 0), 10_000_000)
    }

    func testGPXParserKeepsOriginalTrackTimestamps() throws {
        let data = try Data(contentsOf: try fixtureURL(named: "moves-all-days.gpx"))
        let archive = try XCTUnwrap(parseSuccess(fileName: "moves-all-days.gpx", data: data))

        XCTAssertGreaterThanOrEqual(archive.places.count, 117)
        XCTAssertGreaterThanOrEqual(archive.moves.count, 69)

        let aprilRun = try XCTUnwrap(
            archive.moves.first {
                abs($0.startDate.timeIntervalSince(date("2026-04-21T11:49:30.000Z"))) < 1
            }
        )
        XCTAssertGreaterThan(aprilRun.points.count, 100)
        XCTAssertTrue(aprilRun.points.allSatisfy { $0.timestamp != nil })
        XCTAssertEqual(aprilRun.transportMode, .unknown)

        let firstTime = try XCTUnwrap(aprilRun.points.first?.timestamp)
        XCTAssertEqual(firstTime.timeIntervalSince(date("2026-04-21T11:49:30.000Z")), 0, accuracy: 1)
        XCTAssertGreaterThan(abs(firstTime.timeIntervalSinceNow), 60 * 60 * 24)
    }

    func testMergerPrefersGeoJSONMetadataAndGPXTimestamps() throws {
        let archive = try mergedRealExport()

        XCTAssertEqual(archive.formats, [.gpx, .geoJSON, .csv])
        XCTAssertGreaterThanOrEqual(archive.places.filter { $0.userLabel == "Home" }.count, 9)
        XCTAssertGreaterThanOrEqual(archive.places.filter { $0.autoLabel == "Golden Gate Park" }.count, 10)
        XCTAssertFalse(
            archive.moves.contains {
                $0.transportMode == .running && ($0.distanceMeters ?? 0) > 1_000_000
            },
            "Saigon-to-Home teleport should not survive cleanup"
        )
        XCTAssertFalse(
            archive.moves.contains {
                $0.transportMode == .unknown && ($0.distanceMeters ?? 0) > 5_000_000
            },
            "The 43-day unknown trans-Pacific scribble should be split"
        )

        let gardenWalks = archive.moves.filter {
            $0.startPlaceTitle == "San Francisco Botanical Garden"
                && abs($0.startDate.timeIntervalSince(date("2026-09-15T21:07:49.021Z"))) < 1
        }
        XCTAssertEqual(gardenWalks.count, 2, "Moves that share a start time should stay distinct")
        XCTAssertEqual(
            Set(gardenWalks.map(\.endPlaceTitle)),
            ["1201 9th Ave", "1480 8th Ave"]
        )

        let plane = try XCTUnwrap(archive.moves.first { $0.transportMode == .plane })
        XCTAssertGreaterThanOrEqual(plane.points.filter { $0.timestamp != nil }.count, 2)

        let aprilRun = try XCTUnwrap(
            archive.moves.first { $0.transportMode == .running && $0.dayKey == "2026-04-21" }
        )
        XCTAssertGreaterThan(aprilRun.points.count, 100)
        XCTAssertTrue(aprilRun.points.contains { $0.timestamp != nil && $0.elevation != nil })

        let stitched = archive.moves.first {
            $0.startPlaceTitle == "1567 8th Ave" && $0.endPlaceTitle == "270 Laguna Honda Blvd"
        }
        XCTAssertNotNil(stitched, "CSV-only unknown-destination walks should be stitched back together")
        XCTAssertEqual(stitched?.transportMode, .walking)
    }

    func testGeoJSONOnlyInterpolatesAlongExportedTimesNotNow() throws {
        let data = try Data(contentsOf: try fixtureURL(named: "moves-all-days.geojson"))
        let parsed = try XCTUnwrap(parseSuccess(fileName: "moves-all-days.geojson", data: data))
        let archive = TimelineArchiveMerger.merge([parsed])
        let plane = try XCTUnwrap(
            archive.moves.first {
                $0.transportMode == .plane
                    && $0.endPlaceTitle == "Tan Son Nhat International Airport"
            }
        )
        let points = TimelineArchiveMerger.interpolatedPoints(for: plane)
        let first = try XCTUnwrap(points.first?.timestamp)
        let last = try XCTUnwrap(points.last?.timestamp)

        XCTAssertEqual(first.timeIntervalSince(plane.startDate), 0, accuracy: 1)
        XCTAssertEqual(last.timeIntervalSince(plane.endDate), 0, accuracy: 1)
        XCTAssertGreaterThan(abs(first.timeIntervalSinceNow), 60 * 60 * 24)
    }

    func testRealExportRoundTripRestoresTimelineIntoSwiftData() throws {
        executionTimeAllowance = 120
        let archive = try mergedRealExport()
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let report = try repository.importTimelineArchive(archive)
        XCTAssertGreaterThanOrEqual(report.placeCount, 110)
        XCTAssertGreaterThanOrEqual(report.moveCount, 69)
        XCTAssertGreaterThan(report.sampleCount, 1_000)

        let context = ModelContext(container)
        let places = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        let samples = try context.fetch(FetchDescriptor<LocationSample>())

        XCTAssertGreaterThanOrEqual(places.filter { $0.userLabel == "Home" }.count, 8)
        XCTAssertGreaterThanOrEqual(places.filter { $0.autoLabel == "Golden Gate Park" }.count, 8)
        XCTAssertTrue(places.contains { $0.autoLabel == "Tan Son Nhat International Airport" })
        XCTAssertTrue(places.contains { $0.autoLabel == "Dianne Feinstein International Terminal" })

        let modes = Set(moves.map(\.transportMode))
        XCTAssertTrue(modes.contains(.walking))
        XCTAssertTrue(modes.contains(.automotive))
        XCTAssertTrue(modes.contains(.plane))
        XCTAssertTrue(modes.contains(.running))

        let returnFlight = try XCTUnwrap(
            moves.first {
                $0.transportMode == .plane
                    && $0.endPlace?.autoLabel == "Tan Son Nhat International Airport"
            }
        )
        XCTAssertEqual(returnFlight.startPlace?.autoLabel, "Dianne Feinstein International Terminal")
        XCTAssertGreaterThan(abs(returnFlight.startDate.timeIntervalSinceNow), 60 * 60 * 24)

        XCTAssertTrue(
            moves.contains {
                $0.transportMode == .plane && $0.distanceMeters > 10_000_000
                    && $0.startDate < date("2026-09-01T00:00:00Z")
            }
        )
        XCTAssertFalse(moves.contains { $0.transportMode == .running && $0.distanceMeters > 1_000_000 })

        XCTAssertTrue(samples.contains { $0.source == .fileRouteImport })
        XCTAssertGreaterThan(samples.filter { abs($0.timestamp.timeIntervalSinceNow) > 60 * 60 * 24 }.count, 1_000)

        let secondReport = try repository.importTimelineArchive(archive)
        let placesAfterRepeat = try context.fetch(FetchDescriptor<VisitPlace>())
        let movesAfterRepeat = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(placesAfterRepeat.count, places.count)
        XCTAssertEqual(movesAfterRepeat.count, moves.count)
        XCTAssertGreaterThanOrEqual(secondReport.placeCount, 110)
    }

    // MARK: Zip

    /// `ditto -c -k` writes zero sizes in each local header and the real ones after the data.
    func testZipReadsMembersThatKeepTheirSizesInADataDescriptor() throws {
        let payload = Data(String(repeating: "record_type,start_time\n", count: 400).utf8)
        let zip = try deflatedZip(name: "moves.csv", payload: payload, usesDataDescriptor: true)

        let members = try MovesZipArchive.unpack(zip)

        XCTAssertEqual(members.map(\.path), ["moves.csv"])
        XCTAssertEqual(members.first?.data, payload)
    }

    func testZipKeepsEveryByteOfMembersAroundTheInflateBuffer() throws {
        for size in [65_535, 65_536, 65_537, 131_072, 131_073] {
            let payload = Data(repeating: 97, count: size)
            let zip = try deflatedZip(name: "moves.gpx", payload: payload, usesDataDescriptor: false)
            let members = try MovesZipArchive.unpack(zip)
            XCTAssertEqual(members.first?.data.count, size)
            XCTAssertEqual(members.first?.data, payload, "\(size) bytes")
        }
    }

    func testZipRejectsAMemberThatDoesNotMatchItsChecksum() throws {
        let payload = Data(String(repeating: "moves\n", count: 400).utf8)
        let zip = try deflatedZip(
            name: "moves.csv",
            payload: payload,
            usesDataDescriptor: false,
            recordedCRC: MovesZipArchive.crc32Checksum(of: payload) &+ 1
        )
        XCTAssertThrowsError(try MovesZipArchive.unpack(zip))
    }

    func testZipSkipsFolderEntries() throws {
        let payload = Data("moves".utf8)
        let zip = MovesZipArchive.pack([
            MovesZipFile(path: "backup/", data: Data()),
            MovesZipFile(path: "backup/moves.csv", data: payload),
        ])
        XCTAssertEqual(try MovesZipArchive.unpack(zip).map(\.path), ["backup/moves.csv"])
    }

    func testDamagedZipIsReportedAsDamaged() {
        let parsed = TimelineArchiveFileParser.parseAll(
            files: [(name: "backup.zip", data: Data("PK\u{3}\u{4} not really a zip".utf8))]
        )
        XCTAssertTrue(parsed.archive.isEmpty)
        XCTAssertEqual(parsed.skipped, ["backup.zip"])
        XCTAssertEqual(parsed.warnings, ["backup.zip could not be opened. It may be damaged or incomplete."])
    }

    // MARK: CSV

    func testCSVSurvivesDuplicateColumnsMultilineCommentsAndAbsurdDistances() throws {
        let csv = """
        record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment,comment
        place,2026-01-02T08:00:00.000Z,2026-01-02T09:00:00.000Z,"Cafe",2026-01-02,,,,52.52,13.40,"first line
        second ""line"" here","ignored"
        move,2026-01-02T09:00:00.000Z,2026-01-02T09:30:00.000Z,"Cafe to Park",2026-01-02,walking,1e30,,,,"",""
        """

        let archive = try parseSuccess(fileName: "moves.csv", data: Data(csv.utf8))

        XCTAssertEqual(archive.places.count, 1)
        XCTAssertEqual(archive.places.first?.comment, "first line\nsecond \"line\" here")
        XCTAssertEqual(archive.moves.count, 1)
        XCTAssertNil(archive.moves.first?.distanceMeters)
    }

    func testFileNamesImplyAModeOnlyAsWholeWords() throws {
        let gpx = """
        <gpx version="1.1"><trk><trkseg>
        <trkpt lat="52.52" lon="13.40"><time>2026-01-02T08:00:00Z</time></trkpt>
        <trkpt lat="52.53" lon="13.41"><time>2026-01-02T08:10:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let carolina = try parseSuccess(fileName: "Carolina.gpx", data: Data(gpx.utf8))
        XCTAssertEqual(carolina.moves.first?.transportMode, .unknown)
        let carTrip = try parseSuccess(fileName: "car-trip.gpx", data: Data(gpx.utf8))
        XCTAssertEqual(carTrip.moves.first?.transportMode, .automotive)
    }

    /// A zip with one DEFLATE member, built by hand because `pack` only stores.
    private func deflatedZip(
        name: String,
        payload: Data,
        usesDataDescriptor: Bool,
        recordedCRC: UInt32? = nil
    ) throws -> Data {
        let compressed = try (payload as NSData).compressed(using: .zlib) as Data
        let crc = recordedCRC ?? MovesZipArchive.crc32Checksum(of: payload)
        let nameData = Data(name.utf8)
        let flags: UInt16 = usesDataDescriptor ? 0x8 : 0

        var zip = Data()
        zip.appendZipUInt32(0x04034b50)
        zip.appendZipUInt16(20)
        zip.appendZipUInt16(flags)
        zip.appendZipUInt16(8)
        zip.appendZipUInt32(0) // time and date
        zip.appendZipUInt32(usesDataDescriptor ? 0 : crc)
        zip.appendZipUInt32(usesDataDescriptor ? 0 : UInt32(compressed.count))
        zip.appendZipUInt32(usesDataDescriptor ? 0 : UInt32(payload.count))
        zip.appendZipUInt16(UInt16(nameData.count))
        zip.appendZipUInt16(0)
        zip.append(nameData)
        zip.append(compressed)
        if usesDataDescriptor {
            zip.appendZipUInt32(0x08074b50)
            zip.appendZipUInt32(crc)
            zip.appendZipUInt32(UInt32(compressed.count))
            zip.appendZipUInt32(UInt32(payload.count))
        }

        let centralOffset = zip.count
        zip.appendZipUInt32(0x02014b50)
        zip.appendZipUInt16(20)
        zip.appendZipUInt16(20)
        zip.appendZipUInt16(flags)
        zip.appendZipUInt16(8)
        zip.appendZipUInt32(0) // time and date
        zip.appendZipUInt32(crc)
        zip.appendZipUInt32(UInt32(compressed.count))
        zip.appendZipUInt32(UInt32(payload.count))
        zip.appendZipUInt16(UInt16(nameData.count))
        zip.appendZipUInt16(0)
        zip.appendZipUInt16(0)
        zip.appendZipUInt16(0)
        zip.appendZipUInt16(0)
        zip.appendZipUInt32(0)
        zip.appendZipUInt32(0)
        zip.append(nameData)
        let centralSize = zip.count - centralOffset

        zip.appendZipUInt32(0x06054b50)
        zip.appendZipUInt16(0)
        zip.appendZipUInt16(0)
        zip.appendZipUInt16(1)
        zip.appendZipUInt16(1)
        zip.appendZipUInt32(UInt32(centralSize))
        zip.appendZipUInt32(UInt32(centralOffset))
        zip.appendZipUInt16(0)
        return zip
    }

    private func mergedRealExport() throws -> TimelineArchive {
        let files = ["moves-all-days.geojson", "moves-all-days.gpx", "moves-all-days.csv"]
        let payloads = try files.map { name in
            (name: name, data: try Data(contentsOf: try fixtureURL(named: name)))
        }
        let parsed = TimelineArchiveFileParser.parseAll(files: payloads)
        XCTAssertTrue(parsed.skipped.isEmpty, parsed.skipped.joined(separator: ", "))
        XCTAssertFalse(parsed.archive.isEmpty)
        return parsed.archive
    }

    private func parseSuccess(fileName: String, data: Data) throws -> TimelineArchive {
        switch TimelineArchiveFileParser.parse(fileName: fileName, data: data) {
        case .success(let archive):
            return archive
        case .failure(let error):
            XCTFail(error.message)
            throw error
        }
    }

    private func fixtureURL(named fileName: String) throws -> URL {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Fixtures", directoryHint: .isDirectory)
                .appending(path: fileName),
            URL(fileURLWithPath: "/Users/roger/Downloads/\(fileName)"),
        ]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }
        throw XCTSkip("Missing \(fileName). Export All Days from Moves into Downloads or MovesTests/Fixtures.")
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
}

private extension Data {
    mutating func appendZipUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendZipUInt32(_ value: UInt32) {
        appendZipUInt16(UInt16(value & 0xFFFF))
        appendZipUInt16(UInt16(value >> 16))
    }
}
