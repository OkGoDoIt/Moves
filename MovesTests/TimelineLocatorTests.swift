import CoreLocation
import XCTest
@testable import Moves

final class TimelineLocatorTests: XCTestCase {
    func testLocateReturnsVisitWhenDateIsInsideTheStay() {
        let visit = VisitPlace(
            arrivalDate: date(9, 0),
            departureDate: date(10, 0),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let result = TimelineLocator.locate(at: date(9, 30), visits: [visit], moves: [])
        guard case .visit(let found) = result else {
            return XCTFail("Expected a visit")
        }
        XCTAssertEqual(found.id, visit.id)
    }

    func testLocateInterpolatesAlongCachedCoordinates() {
        let start = VisitPlace(
            arrivalDate: date(8, 0),
            departureDate: date(8, 10),
            latitude: 52.50,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let end = VisitPlace(
            arrivalDate: date(8, 40),
            departureDate: date(9, 0),
            latitude: 52.54,
            longitude: 13.44,
            horizontalAccuracy: 10
        )
        let move = MoveSegment(
            dedupeKey: "move",
            startDate: date(8, 10),
            endDate: date(8, 40),
            transportMode: .cycling,
            distanceMeters: 5_000,
            stepCount: nil
        )
        move.startPlace = start
        move.endPlace = end
        move.storeCachedRouteCoordinates(
            [
                start.coordinate,
                CLLocationCoordinate2D(latitude: 52.52, longitude: 13.42),
                end.coordinate,
            ],
            signature: "locator-test"
        )

        let midpoint = date(8, 25)
        let result = TimelineLocator.locate(at: midpoint, visits: [start, end], moves: [move])
        guard case .move(let found, let coordinate, let progress) = result else {
            return XCTFail("Expected a move")
        }
        XCTAssertEqual(found.id, move.id)
        XCTAssertEqual(progress, 0.5, accuracy: 0.02)
        XCTAssertEqual(coordinate.latitude, 52.52, accuracy: 0.01)
        XCTAssertEqual(coordinate.longitude, 13.42, accuracy: 0.01)
    }

    func testLocateFallsBackToStartAndEndPlaces() {
        let start = VisitPlace(
            arrivalDate: date(12, 0),
            departureDate: date(12, 10),
            latitude: 52.50,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let end = VisitPlace(
            arrivalDate: date(12, 40),
            departureDate: date(13, 0),
            latitude: 52.60,
            longitude: 13.50,
            horizontalAccuracy: 10
        )
        let move = MoveSegment(
            dedupeKey: "straight",
            startDate: date(12, 10),
            endDate: date(12, 40),
            transportMode: .automotive,
            distanceMeters: 12_000,
            stepCount: nil
        )
        move.startPlace = start
        move.endPlace = end

        let result = TimelineLocator.locate(at: date(12, 25), visits: [start, end], moves: [move])
        guard case .move(_, let coordinate, let progress) = result else {
            return XCTFail("Expected a move")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.02)
        XCTAssertEqual(coordinate.latitude, 52.55, accuracy: 0.001)
        XCTAssertEqual(coordinate.longitude, 13.45, accuracy: 0.001)
    }

    func testLocateReturnsGapBetweenItems() {
        let visit = VisitPlace(
            arrivalDate: date(9, 0),
            departureDate: date(10, 0),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let later = VisitPlace(
            arrivalDate: date(12, 0),
            departureDate: date(13, 0),
            latitude: 52.53,
            longitude: 13.41,
            horizontalAccuracy: 10
        )

        let result = TimelineLocator.locate(at: date(11, 0), visits: [visit, later], moves: [])
        guard case .gap(let before, let after) = result else {
            return XCTFail("Expected a gap")
        }
        guard case .visit(let beforeVisit) = before else {
            return XCTFail("Expected the earlier visit before the gap")
        }
        guard case .visit(let afterVisit) = after else {
            return XCTFail("Expected the later visit after the gap")
        }
        XCTAssertEqual(beforeVisit.id, visit.id)
        XCTAssertEqual(afterVisit.id, later.id)
    }

    func testInterpolateAtEndpoints() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ]
        let start = try XCTUnwrap(TimelineLocator.interpolate(along: coordinates, progress: 0))
        let end = try XCTUnwrap(TimelineLocator.interpolate(along: coordinates, progress: 1))
        XCTAssertEqual(start.latitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(end.latitude, 1, accuracy: 0.000_001)
    }

    func testOpenEndedVisitCoversUntilTheOutgoingMove() {
        let visit = VisitPlace(
            arrivalDate: date(18, 0),
            departureDate: nil,
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10
        )
        let next = VisitPlace(
            arrivalDate: date(19, 0),
            departureDate: date(20, 0),
            latitude: 52.53,
            longitude: 13.41,
            horizontalAccuracy: 10
        )
        let move = MoveSegment(
            dedupeKey: "leave",
            startDate: date(18, 45),
            endDate: date(19, 0),
            transportMode: .walking,
            distanceMeters: 800,
            stepCount: nil
        )
        move.startPlace = visit
        move.endPlace = next

        let stillThere = TimelineLocator.locate(at: date(18, 20), visits: [visit, next], moves: [move])
        guard case .visit = stillThere else {
            return XCTFail("Expected the open-ended visit")
        }

        let onTheWay = TimelineLocator.locate(at: date(18, 50), visits: [visit, next], moves: [move])
        guard case .move(let found, _, _) = onTheWay else {
            return XCTFail("Expected the outgoing move")
        }
        XCTAssertEqual(found.id, move.id)
    }

    func testZeroDurationVisitCoversItsInstant() {
        let visit = VisitPlace(
            arrivalDate: date(8, 25),
            departureDate: date(8, 25),
            latitude: 52.52,
            longitude: 13.42,
            horizontalAccuracy: 10
        )
        let result = TimelineLocator.locate(at: date(8, 25), visits: [visit], moves: [])
        guard case .visit(let found) = result else {
            return XCTFail("Expected the zero-duration visit")
        }
        XCTAssertEqual(found.id, visit.id)
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
