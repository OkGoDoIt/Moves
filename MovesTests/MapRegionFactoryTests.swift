import CoreLocation
import MapKit
import XCTest
@testable import Moves

/// Regression for G17 SIGABRT in `DayMapStrip.makeCollapsedSnapshot` via
/// `MKMapSnapshotOptions.setRegion:` when paging onto a day with empty, single-point,
/// identical, or garbage coordinates.
final class MapRegionFactoryTests: XCTestCase {
    private let bangkok = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
    private let chiangMai = CLLocationCoordinate2D(latitude: 18.7883, longitude: 98.9853)

    func testEmptyCoordinatesUsesFallback() {
        let region = MapRegionFactory.region(for: [])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertEqual(region.center.latitude, MapRegionFactory.fallbackRegion.center.latitude, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, MapRegionFactory.fallbackRegion.center.longitude, accuracy: 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    func testSinglePointUsesMinimumSpan() {
        let region = MapRegionFactory.region(for: [bangkok])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertEqual(region.center.latitude, bangkok.latitude, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, bangkok.longitude, accuracy: 0.0001)
        XCTAssertGreaterThan(region.span.latitudeDelta, 0)
        XCTAssertGreaterThan(region.span.longitudeDelta, 0)
        XCTAssertEqual(region.span.latitudeDelta, 0.01, accuracy: 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    func testIdenticalStartAndEndCoordinatesUsesMinimumSpan() {
        let region = MapRegionFactory.region(for: [bangkok, bangkok])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertEqual(region.span.latitudeDelta, 0.01, accuracy: 0.0001)
        XCTAssertEqual(region.span.longitudeDelta, 0.01, accuracy: 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    func testPointsAcrossThePacificFrameThePacific() {
        let sanFrancisco = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.42)
        let atlanta = CLLocationCoordinate2D(latitude: 33.75, longitude: -84.39)
        let saigon = CLLocationCoordinate2D(latitude: 10.77, longitude: 106.70)
        let region = MapRegionFactory.region(for: [sanFrancisco, atlanta, saigon])

        XCTAssertTrue(abs(region.center.longitude) > 140, "Centered at \(region.center.longitude), not the Pacific")
        assertAssignableToSnapshotOptions(region)
    }

    func testPointsOnOneSideKeepTheirOrdinaryFit() {
        let region = MapRegionFactory.region(for: [bangkok, chiangMai])
        XCTAssertEqual(region.center.longitude, (bangkok.longitude + chiangMai.longitude) / 2, accuracy: 0.0001)
    }

    func testDayWithNoMovesOneStayIsSnapshotSafe() {
        let stayOnly = [bangkok]
        let region = MapRegionFactory.region(for: stayOnly)
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        assertAssignableToSnapshotOptions(region)
    }

    func testNaNCoordinatesFallBackInsteadOfCrashing() {
        let region = MapRegionFactory.region(for: [
            CLLocationCoordinate2D(latitude: .nan, longitude: .nan),
            CLLocationCoordinate2D(latitude: .infinity, longitude: -.infinity)
        ])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertEqual(region.center.latitude, MapRegionFactory.fallbackRegion.center.latitude, accuracy: 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    func testLatitudeOutsideValidRangeIsIgnored() {
        let region = MapRegionFactory.region(for: [
            CLLocationCoordinate2D(latitude: 120, longitude: 100),
            bangkok
        ])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertEqual(region.center.latitude, bangkok.latitude, accuracy: 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    func testWorldSpanningCoordinatesClampSpan() {
        let region = MapRegionFactory.region(for: [
            CLLocationCoordinate2D(latitude: -85, longitude: -179),
            CLLocationCoordinate2D(latitude: 85, longitude: 179)
        ])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 180)
        XCTAssertLessThanOrEqual(region.span.longitudeDelta, 360)
        XCTAssertGreaterThan(region.span.latitudeDelta, 0)
        assertAssignableToSnapshotOptions(region)
    }

    func testSnapshotSafeRepairsZeroAndNaNSpan() {
        let zero = MKCoordinateRegion(
            center: bangkok,
            span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0)
        )
        let nan = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: .nan, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: .nan, longitudeDelta: .infinity)
        )

        XCTAssertFalse(MapRegionFactory.isSnapshotSafe(zero))
        XCTAssertFalse(MapRegionFactory.isSnapshotSafe(nan))

        let repairedZero = MapRegionFactory.snapshotSafe(zero)
        let repairedNaN = MapRegionFactory.snapshotSafe(nan)
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(repairedZero))
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(repairedNaN))
        assertAssignableToSnapshotOptions(repairedZero)
        assertAssignableToSnapshotOptions(repairedNaN)
    }

    func testTwoDistinctPlacesKeepAPaddedSpan() {
        let region = MapRegionFactory.region(for: [bangkok, chiangMai])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertGreaterThan(region.span.latitudeDelta, 0.01)
        XCTAssertEqual(
            region.center.latitude,
            (bangkok.latitude + chiangMai.latitude) / 2,
            accuracy: 0.0001
        )
        assertAssignableToSnapshotOptions(region)
    }

    func testPoleCoordinateDoesNotCrossNinety() {
        let region = MapRegionFactory.region(for: [
            CLLocationCoordinate2D(latitude: 90, longitude: 0)
        ])
        XCTAssertTrue(MapRegionFactory.isSnapshotSafe(region))
        XCTAssertLessThanOrEqual(abs(region.center.latitude) + region.span.latitudeDelta / 2, 90 + 0.0001)
        assertAssignableToSnapshotOptions(region)
    }

    /// Direct stand-in for the G17 crash: assigning the factory region to snapshot options.
    private func assertAssignableToSnapshotOptions(
        _ region: MKCoordinateRegion,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let options = MKMapSnapshotter.Options()
        options.region = MapRegionFactory.snapshotSafe(region)
        XCTAssertTrue(
            MapRegionFactory.isSnapshotSafe(options.region),
            "snapshot options received an invalid region",
            file: file,
            line: line
        )
    }
}
