import CoreLocation
import XCTest
@testable import Moves

final class SpeedProfileBuilderTests: XCTestCase {
    func testNormalizesWalkingSpeedsAgainstTypicalRange() {
        XCTAssertEqual(SpeedProfileBuilder.normalizedFraction(speed: 0, mode: .walking), 0, accuracy: 0.001)
        XCTAssertEqual(
            SpeedProfileBuilder.normalizedFraction(speed: 3.5 / 3.6, mode: .walking),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpeedProfileBuilder.normalizedFraction(speed: 7 / 3.6, mode: .walking),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpeedProfileBuilder.normalizedFraction(speed: 20 / 3.6, mode: .walking),
            1,
            accuracy: 0.001
        )
    }

    func testFractionsKeepSlowStartAndFastFinishAcrossSmoothing() {
        let start = date(8, 0)
        let coordinates = evenlySpacedCoordinates(count: 9, metersNorth: 25)
        let samples: [SpeedProfileSample] = coordinates.enumerated().map { index, coordinate in
            let recordedSpeed: Double
            if index <= 2 {
                recordedSpeed = 0
            } else if index >= 6 {
                recordedSpeed = 7 / 3.6
            } else {
                recordedSpeed = 3.5 / 3.6
            }
            return SpeedProfileSample(
                timestamp: start.addingTimeInterval(TimeInterval(index) * 10),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                recordedSpeed: recordedSpeed
            )
        }

        let fractions = SpeedProfileBuilder.fractions(
            coordinates: coordinates,
            samples: samples,
            startDate: start,
            endDate: start.addingTimeInterval(80),
            mode: .walking
        )

        XCTAssertEqual(fractions.count, 9)
        XCTAssertEqual(Double(fractions[0]), 0, accuracy: 0.08)
        XCTAssertEqual(Double(fractions[8]), 1, accuracy: 0.08)
        XCTAssertGreaterThan(Double(fractions[8]), Double(fractions[4]))
        XCTAssertGreaterThan(Double(fractions[4]), Double(fractions[0]))
    }

    func testSmoothingDampensASingleVertexSpike() {
        let start = date(9, 0)
        let coordinates = evenlySpacedCoordinates(count: 9, metersNorth: 20)
        let samples: [SpeedProfileSample] = coordinates.enumerated().map { index, coordinate in
            SpeedProfileSample(
                timestamp: start.addingTimeInterval(TimeInterval(index) * 10),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                recordedSpeed: index == 4 ? 1.5 : 0.4
            )
        }

        let fractions = SpeedProfileBuilder.fractions(
            coordinates: coordinates,
            samples: samples,
            startDate: start,
            endDate: start.addingTimeInterval(80),
            mode: .walking
        )

        let rawMiddle = SpeedProfileBuilder.normalizedFraction(speed: 1.5, mode: .walking)
        XCTAssertEqual(fractions.count, 9)
        XCTAssertLessThan(Double(fractions[4]), rawMiddle - 0.08)
        XCTAssertGreaterThan(Double(fractions[4]), Double(fractions[0]))
    }

    func testMissingSpeedsFallBackToDistanceOverTime() {
        let start = date(10, 0)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.50, longitude: 13.40),
            CLLocationCoordinate2D(latitude: 52.501, longitude: 13.40)
        ]
        let samples = [
            SpeedProfileSample(
                timestamp: start,
                latitude: coordinates[0].latitude,
                longitude: coordinates[0].longitude,
                recordedSpeed: -1
            ),
            SpeedProfileSample(
                timestamp: start.addingTimeInterval(10),
                latitude: coordinates[1].latitude,
                longitude: coordinates[1].longitude,
                recordedSpeed: -1
            )
        ]

        let expectedSpeed = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
            .distance(from: CLLocation(latitude: coordinates[1].latitude, longitude: coordinates[1].longitude))
            / 10
        let expectedFraction = SpeedProfileBuilder.normalizedFraction(
            speed: expectedSpeed,
            mode: .automotive
        )

        let fractions = SpeedProfileBuilder.fractions(
            coordinates: coordinates,
            samples: samples,
            startDate: start,
            endDate: start.addingTimeInterval(10),
            mode: .automotive
        )

        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(Double(fractions[0]), expectedFraction, accuracy: 0.08)
        XCTAssertEqual(Double(fractions[1]), expectedFraction, accuracy: 0.08)
        XCTAssertGreaterThan(expectedSpeed, 0)
    }

    func testGradientStopsStayOpaqueAndCapped() {
        let coordinates = evenlySpacedCoordinates(count: 80, metersNorth: 8)
        let fractions: [Float] = coordinates.indices.map { index in
            Float(index % 2)
        }
        let stops = RouteGradientStops.make(
            coordinates: coordinates,
            speedFractions: fractions,
            base: .green,
            opacity: 0.75
        )

        XCTAssertLessThanOrEqual(stops.count, RouteGradientRendering.maximumStopCount)
        XCTAssertGreaterThanOrEqual(stops.count, 2)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
    }

    @MainActor
    func testSpeedProfileCacheRoundTripsWithRouteSignature() {
        let move = MoveSegment(
            dedupeKey: "cache",
            startDate: date(11, 0),
            endDate: date(11, 10),
            transportMode: .cycling,
            distanceMeters: 2_000,
            stepCount: nil
        )
        let coordinates = evenlySpacedCoordinates(count: 4, metersNorth: 40)
        move.storeCachedRouteCoordinates(coordinates, signature: "sig-1")

        let built = SpeedProfileBuilder.fractions(for: move, coordinates: coordinates)
        SpeedProfileBuilder.store(built, on: move, signature: "sig-1")

        let cached = SpeedProfileBuilder.cachedFractions(
            for: move,
            coordinateCount: coordinates.count,
            signature: "sig-1"
        )
        XCTAssertEqual(cached, built)
        XCTAssertNil(
            SpeedProfileBuilder.cachedFractions(
                for: move,
                coordinateCount: coordinates.count,
                signature: "other"
            )
        )
    }

    private func evenlySpacedCoordinates(count: Int, metersNorth: Double) -> [CLLocationCoordinate2D] {
        let start = CLLocationCoordinate2D(latitude: 52.50, longitude: 13.40)
        let latitudeStep = (metersNorth / 111_320)
        return (0..<count).map { index in
            CLLocationCoordinate2D(
                latitude: start.latitude + latitudeStep * Double(index),
                longitude: start.longitude
            )
        }
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }
}
