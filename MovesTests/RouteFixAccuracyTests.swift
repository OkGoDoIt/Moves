import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// Drawn routes leave out fixes the accuracy rule rejects, and caches built before the rule rebuild.
@MainActor
final class RouteFixAccuracyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    func testRouteSkipsInaccurateAndInvalidFixesButKeepsUnknownAccuracy() {
        let move = makeMove(withPlaces: true, fixes: [
            (0.001, 10),
            (0.020, 1_200),  // a kilometre-scale jump the phone reported at 1.2 km
            (0.002, 0),      // an import with no accuracy in the file
            (0.030, -1),     // invalid
            (0.003, 100),    // right at the limit
            (0.004, 101),
        ])

        let latitudes = MoveRouteGeometry.rawCoordinates(for: move).map { ($0.latitude * 1_000).rounded() / 1_000 }

        XCTAssertEqual(latitudes, [0.0, 0.001, 0.002, 0.003, 0.005])
    }

    func testTripWithOnlyBadFixesAndNoPlacesFallsBackToItsEndpoints() {
        let move = makeMove(withPlaces: false, fixes: [(0.001, 500), (0.002, 800), (0.003, 900)])

        let latitudes = MoveRouteGeometry.rawCoordinates(for: move).map { ($0.latitude * 1_000).rounded() / 1_000 }

        XCTAssertEqual(latitudes, [0.001, 0.003])
    }

    func testTripWithPlacesStillRunsFromStartToEndWhenEveryFixIsBad() {
        let move = makeMove(withPlaces: true, fixes: [(0.002, 500)])

        let latitudes = MoveRouteGeometry.rawCoordinates(for: move).map { ($0.latitude * 1_000).rounded() / 1_000 }

        XCTAssertEqual(latitudes, [0.0, 0.005])
    }

    func testWorkoutRouteDropsBadFixesToo() {
        let move = makeMove(withPlaces: true, fixes: [(0.001, 5), (0.020, 400), (0.002, 5)], source: .healthWorkoutRoute)
        XCTAssertTrue(move.usesHealthWorkoutRoute)

        let latitudes = MoveRouteGeometry.rawCoordinates(for: move).map { ($0.latitude * 1_000).rounded() / 1_000 }

        XCTAssertEqual(latitudes, [0.001, 0.002])
    }

    func testCacheStoredBeforeTheRuleIsNotReused() {
        let move = makeMove(withPlaces: true, fixes: [(0.001, 10), (0.002, 10)])
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        XCTAssertTrue(signature.contains(RouteFixAccuracy.ruleVersion))

        // The same signature as before the rule existed: every component but the rule's version.
        let older = signature.replacingOccurrences(of: "|\(RouteFixAccuracy.ruleVersion)", with: "")
        XCTAssertNotEqual(older, signature)
        move.storeCachedRouteCoordinates(fallback, signature: older)
        XCTAssertNil(move.cachedRouteCoordinates(for: signature))

        move.storeCachedRouteCoordinates(fallback, signature: signature)
        XCTAssertNotNil(move.cachedRouteCoordinates(for: signature))
    }

    func testShareMapAggregatesRebuildUnderANewRule() {
        let signature = ShareMapAggregateStore.sourceSignature(moves: [], places: [])
        XCTAssertTrue(signature.contains(RouteFixAccuracy.ruleVersion))
    }

    // MARK: - Helpers

    /// A trip north along longitude 0: start place at latitude 0, end place at 0.005.
    private func makeMove(
        withPlaces: Bool,
        fixes: [(latitude: Double, accuracy: Double)],
        source: LocationSampleSource = .significantChange
    ) -> MoveSegment {
        let end = start.addingTimeInterval(Double(fixes.count + 1) * 60)
        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: start,
            endDate: end,
            transportMode: .walking,
            distanceMeters: 550,
            stepCount: nil
        )
        context.insert(move)
        if withPlaces {
            let from = VisitPlace(arrivalDate: start.addingTimeInterval(-600), departureDate: start,
                                  latitude: 0, longitude: 0, horizontalAccuracy: 20)
            let to = VisitPlace(arrivalDate: end, departureDate: end.addingTimeInterval(600),
                                latitude: 0.005, longitude: 0, horizontalAccuracy: 20)
            context.insert(from)
            context.insert(to)
            move.startPlace = from
            move.endPlace = to
        }
        move.samples = fixes.enumerated().map { index, fix in
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: fix.latitude, longitude: 0),
                altitude: 0,
                horizontalAccuracy: fix.accuracy,
                verticalAccuracy: -1,
                timestamp: start.addingTimeInterval(Double(index + 1) * 60)
            )
            let sample = LocationSample(location: location, source: source, dedupeKey: UUID().uuidString)
            context.insert(sample)
            return sample
        }
        return move
    }
}
