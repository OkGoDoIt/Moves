import CoreGraphics
import CoreLocation
import SwiftData
import XCTest
@testable import Moves

final class PrivacyZoneTests: XCTestCase {
    func testHomeAndWorkBecomeZonesAndGymDoesNot() throws {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        let work = KnownPlace(name: "Office", latitude: 52.53, longitude: 13.42)
        work.category = KnownPlaceCategory.work.rawValue
        let gym = KnownPlace(name: "Gym", latitude: 52.525, longitude: 13.41)
        gym.category = KnownPlaceCategory.gym.rawValue

        let zones = PrivacyZoneResolver.zones(from: [home, work, gym])
        XCTAssertEqual(zones.map(\.name).sorted(), ["Home", "Office"])
        XCTAssertEqual(Set(zones.map(\.category)), [.home, .work])
    }

    func testShareZonesAreEmptyWhenPrivacyIsOff() {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        XCTAssertTrue(PrivacyZoneResolver.shareZones(from: [home], enabled: false).isEmpty)
        XCTAssertEqual(PrivacyZoneResolver.shareZones(from: [home], enabled: true).count, 1)
    }

    func testExportZonesHonorTheRawFixToggle() {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        XCTAssertTrue(
            PrivacyZoneResolver.exportZones(from: [home], enabled: true, hidesRawFixes: false).isEmpty
        )
        XCTAssertEqual(
            PrivacyZoneResolver.exportZones(from: [home], enabled: true, hidesRawFixes: true).count,
            1
        )
    }

    func testContainsUsesTheDefaultTwoHundredMetreRadius() {
        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.5200,
            longitude: 13.4050,
            radiusMeters: PrivacyZoneSettings.defaultRadiusMeters
        )
        let inside = CLLocationCoordinate2D(latitude: 52.5208, longitude: 13.4050)
        let outside = CLLocationCoordinate2D(latitude: 52.5300, longitude: 13.4050)
        XCTAssertTrue(zone.contains(inside))
        XCTAssertFalse(zone.contains(outside))
        XCTAssertTrue(
            PrivacyZoneResolver.containsRawFix(
                latitude: inside.latitude,
                longitude: inside.longitude,
                zones: [zone]
            )
        )
        XCTAssertFalse(
            PrivacyZoneResolver.containsRawFix(
                latitude: outside.latitude,
                longitude: outside.longitude,
                zones: [zone]
            )
        )
    }

    func testExportOmitsRawFixesInsideAPrivacyZone() throws {
        let home = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: Date(timeIntervalSince1970: 1_700_003_600),
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 8,
            userLabel: "Home"
        )
        let cafe = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_003_600),
            departureDate: Date(timeIntervalSince1970: 1_700_007_200),
            latitude: 52.53,
            longitude: 13.42,
            horizontalAccuracy: 8,
            userLabel: "Café"
        )
        let move = MoveSegment(
            dedupeKey: "walk",
            startDate: home.arrivalDate.addingTimeInterval(60),
            endDate: cafe.arrivalDate,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: nil
        )
        move.startPlace = home
        move.endPlace = cafe
        let inside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.5203, longitude: 13.4051),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: home.arrivalDate.addingTimeInterval(120)
            ),
            source: .significantChange,
            dedupeKey: "inside"
        )
        let outside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.5280, longitude: 13.4180),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: home.arrivalDate.addingTimeInterval(600)
            ),
            source: .significantChange,
            dedupeKey: "outside"
        )
        move.samples = [inside, outside]
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: home.arrivalDate))
        day.places = [home, cafe]
        day.moves = [move]

        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.52,
            longitude: 13.405,
            radiusMeters: 200
        )
        let payload = try XCTUnwrap(
            TimelineExporter.makePayload(
                days: [day],
                format: .gpx,
                fileStem: "privacy",
                privacyZones: [zone]
            )
        )
        let xml = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
        XCTAssertFalse(xml.contains("52.5203"))
        XCTAssertTrue(xml.contains("52.528"))
        XCTAssertFalse(xml.contains("52.520000"), "Home's own coordinates must not survive")
        XCTAssertFalse(xml.contains("<name>Home</name>"))
        XCTAssertTrue(xml.contains("52.530000"), "Places outside a zone stay")
    }

    func testEveryExportFormatLeavesOutPlacesInsideAPrivacyZone() throws {
        let fixture = makePrivateDay()

        for format in [TimelineExportFormat.gpx, .kml, .csv] {
            let payload = try XCTUnwrap(
                TimelineExporter.makePayload(
                    days: [fixture.day],
                    format: format,
                    fileStem: "privacy",
                    privacyZones: [fixture.zone]
                )
            )
            let text = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
            XCTAssertFalse(text.contains("52.5200"), "\(format) reveals Home")
            XCTAssertFalse(text.contains("13.4050"), "\(format) reveals Home")
            XCTAssertFalse(text.contains("Private notes"), "\(format) reveals the visit")
            XCTAssertTrue(text.contains("52.530000"), "\(format) lost the café")
            if format != .gpx {
                XCTAssertTrue(text.contains("\(KnownPlaceCategory.home.title) to Café"), "\(format) move title")
            }
        }

        let geoJSON = try XCTUnwrap(
            TimelineExporter.makePayload(
                days: [fixture.day],
                format: .geoJSON,
                fileStem: "privacy",
                privacyZones: [fixture.zone]
            )
        )
        let collection = try XCTUnwrap(JSONSerialization.jsonObject(with: geoJSON.data) as? [String: Any])
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let move = try XCTUnwrap(features.first { ($0["properties"] as? [String: Any])?["record_type"] as? String == "move" })
        XCTAssertEqual((move["properties"] as? [String: Any])?["start_place"] as? String, KnownPlaceCategory.home.title)
        for feature in features {
            let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
            let points = try (geometry["coordinates"] as? [[Double]])
                ?? [XCTUnwrap(geometry["coordinates"] as? [Double])]
            for point in points {
                let coordinate = CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                XCTAssertFalse(fixture.zone.contains(coordinate), "GeoJSON reveals \(point)")
            }
        }
    }

    func testZipPlacesAndSingleMoveExportLeaveOutPlacesInsideAPrivacyZone() throws {
        let fixture = makePrivateDay()
        let homePlace = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        homePlace.category = KnownPlaceCategory.home.rawValue
        let cafePlace = KnownPlace(name: "Café", latitude: 52.53, longitude: 13.42)

        let zip = try XCTUnwrap(
            TimelineExporter.makeZipPayload(
                days: [fixture.day],
                knownPlaces: [homePlace, cafePlace],
                photos: [],
                fileStem: "privacy",
                privacyZones: [fixture.zone]
            )
        )
        let members = try MovesZipArchive.unpack(zip.data)
        let placesFile = try XCTUnwrap(members.first { $0.path == "places.json" })
        let places = try XCTUnwrap(JSONSerialization.jsonObject(with: placesFile.data) as? [[String: Any]])
        XCTAssertEqual(places.compactMap { $0["name"] as? String }, ["Café"])
        for member in members where member.path != "places.json" && !member.path.hasSuffix(".geojson") {
            let text = try XCTUnwrap(String(data: member.data, encoding: .utf8))
            XCTAssertFalse(text.contains("52.5200"), "\(member.path) reveals Home")
        }

        let single = try XCTUnwrap(
            TimelineExporter.makeMoveGPXPayload(
                move: fixture.move,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                    CLLocationCoordinate2D(latitude: 52.528, longitude: 13.418),
                    CLLocationCoordinate2D(latitude: 52.53, longitude: 13.42),
                ],
                fileStem: "walk",
                privacyZones: [fixture.zone]
            )
        )
        let xml = try XCTUnwrap(String(data: single.data, encoding: .utf8))
        XCTAssertFalse(xml.contains("52.5200"))
        XCTAssertTrue(xml.contains("<name>\(KnownPlaceCategory.home.title) to Café</name>"))
        XCTAssertTrue(xml.contains("52.530000"))
    }

    func testExportsKeepEveryPlaceWhenNoZonesApply() throws {
        let fixture = makePrivateDay()
        let payload = try XCTUnwrap(
            TimelineExporter.makePayload(days: [fixture.day], format: .csv, fileStem: "open")
        )
        let text = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
        XCTAssertTrue(text.contains("52.520000"))
        XCTAssertTrue(text.contains("Private notes"))
    }

    /// An unlabeled Home, so its title is its coordinates, with a walk to a labeled café.
    private func makePrivateDay() -> (day: DayTimeline, move: MoveSegment, zone: PrivacyZone) {
        let home = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: Date(timeIntervalSince1970: 1_700_003_600),
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 8,
            comment: "Private notes"
        )
        let cafe = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_004_200),
            departureDate: Date(timeIntervalSince1970: 1_700_007_200),
            latitude: 52.53,
            longitude: 13.42,
            horizontalAccuracy: 8,
            userLabel: "Café"
        )
        let move = MoveSegment(
            dedupeKey: "walk",
            startDate: home.departureDate ?? home.arrivalDate,
            endDate: cafe.arrivalDate,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: nil
        )
        move.startPlace = home
        move.endPlace = cafe
        let outside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.528, longitude: 13.418),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: Date(timeIntervalSince1970: 1_700_003_900)
            ),
            source: .significantChange,
            dedupeKey: "outside"
        )
        move.samples = [outside]
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: home.arrivalDate))
        day.places = [home, cafe]
        day.moves = [move]
        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.52,
            longitude: 13.405,
            radiusMeters: 200
        )
        return (day, move, zone)
    }

    func testWidgetRouteLayoutFitsPointsInsideThePaddedRect() {
        let points = WidgetRouteLayout.project(
            latitudes: [-33.86, -33.87],
            longitudes: [151.21, 151.24],
            in: CGSize(width: 200, height: 100),
            padding: 10
        )
        XCTAssertEqual(points.count, 2)
        for point in points {
            XCTAssertGreaterThanOrEqual(point.x, 10)
            XCTAssertLessThanOrEqual(point.x, 190)
            XCTAssertGreaterThanOrEqual(point.y, 10)
            XCTAssertLessThanOrEqual(point.y, 90)
        }
        XCTAssertEqual(points[0].x, 10, accuracy: 0.5)
        XCTAssertEqual(points[1].x, 190, accuracy: 0.5)
    }

    func testICloudStatusUsesPlainLanguage() {
        let local = MovesICloudStatus.resolve(
            allowsPrivateMirror: false,
            isSimulator: false,
            lastUpdated: nil
        )
        XCTAssertEqual(local, .localOnly)
        XCTAssertFalse(local.detail.localizedCaseInsensitiveContains("CloudKit"))
        XCTAssertTrue(local.detail.localizedCaseInsensitiveContains("iPhone"))

        let privateICloud = MovesICloudStatus.resolve(
            allowsPrivateMirror: true,
            isSimulator: false,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard case .privateICloud = privateICloud else {
            return XCTFail("Expected private iCloud")
        }
        XCTAssertFalse(privateICloud.detail.localizedCaseInsensitiveContains("CloudKit"))
    }
}
