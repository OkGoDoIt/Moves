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
        XCTAssertTrue(xml.contains("52.52"))
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
