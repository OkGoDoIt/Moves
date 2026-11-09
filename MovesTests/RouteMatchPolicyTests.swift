import CoreLocation
import MapKit
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class RouteMatchPolicyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        await RoadRouteMatcher.resetTestHooks()
        RoadRouteMatcher.snappingLevelOverride = .normal

        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() async throws {
        await RoadRouteMatcher.resetTestHooks()
        container = nil
        context = nil
    }

    func testDensityGates() {
        XCTAssertEqual(
            RouteMatchDensity.classify(intermediateSampleCount: 12, recordedMeters: 1_200),
            .dense
        )
        XCTAssertEqual(
            RouteMatchDensity.classify(intermediateSampleCount: 4, recordedMeters: 3_000),
            .sparse
        )
        XCTAssertEqual(
            RouteMatchDensity.classify(intermediateSampleCount: 0, recordedMeters: 1_200),
            .endpoints
        )
    }

    func testDenseWalkMatchesWindowsAndReportsHighConfidence() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true)
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertGreaterThan(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .high)
        XCTAssertEqual(coordinates.first?.latitude ?? 0, fixture.coordinates.first?.latitude ?? 1, accuracy: 0.00001)
        XCTAssertTrue(move.routeMatchSummary?.contains("Matched to footpaths") == true)
    }

    func testSparseCarAcceptsAPlausibleRouteAtMediumConfidence() async throws {
        let fixture = try loadFixture("sparse-car")
        let move = makeMove(from: fixture, includePlaces: true)
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertGreaterThan(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .medium)
        XCTAssertTrue(move.routeMatchSummary?.contains("Matched to roads") == true)
    }

    func testParkWalkKeepsRawPathAndOffPathSummary() async throws {
        let fixture = try loadFixture("park-walk")
        let move = makeMove(from: fixture, includePlaces: true)
        let start = try XCTUnwrap(fixture.coordinates.first)
        let end = try XCTUnwrap(fixture.coordinates.last)
        let provider = FakeDirectionsProvider(style: .baseline(start: start, end: end))
        RoadRouteMatcher.directionsProvider = provider

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
        let recordedMaxLatitude = fixture.coordinates.map(\.latitude).max() ?? 0
        let matchedMaxLatitude = coordinates.map(\.latitude).max() ?? 0

        let requestCount = await provider.requestCount

        XCTAssertGreaterThan(requestCount, 0)
        XCTAssertEqual(move.routeMatchSummary, RouteMatchSummaries.partlyOffPath)
        XCTAssertEqual(matchedMaxLatitude, recordedMaxLatitude, accuracy: 0.00001)
    }

    func testSnappingOffNeverCallsDirections() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true)
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider
        RoadRouteMatcher.snappingLevelOverride = .off

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .recorded)
        XCTAssertEqual(coordinates.count, MoveRouteGeometry.rawCoordinates(for: move).count)
    }

    func testConservativeSkipsEndpointsOnlyDirections() async throws {
        let move = makeEndpointCarMove()
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider
        RoadRouteMatcher.snappingLevelOverride = .conservative

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .estimated)
        XCTAssertEqual(move.routeMatchSummary, RouteMatchSummaries.estimatedNoFixes)
    }

    func testNormalRequestsDirectionsForEndpointsOnlyCar() async throws {
        let move = makeEndpointCarMove()
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider
        RoadRouteMatcher.snappingLevelOverride = .normal

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(move.routeMatchConfidence, .estimated)
        XCTAssertEqual(move.routeMatchSummary, RouteMatchSummaries.estimatedNoFixes)
    }

    func testDisplayingAMoveKeepsItsStoredDistance() async throws {
        let move = makeEndpointCarMove()
        move.distanceMeters = 12_345
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .close)

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)

        XCTAssertEqual(move.distanceMeters, 12_345, accuracy: 0.01)
    }

    func testRoundTripWithoutFixesKeepsItsStoredDistance() async throws {
        let move = makeEndpointCarMove()
        move.endPlace = move.startPlace
        move.distanceMeters = 5_000
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .close)

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)

        XCTAssertEqual(move.distanceMeters, 5_000, accuracy: 0.01)
    }

    func testMoveWithNoDistanceTakesItsDisplayedLength() async throws {
        let move = makeEndpointCarMove()
        move.distanceMeters = 0
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .close)

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)

        XCTAssertEqual(move.distanceMeters, routeDistance(for: coordinates), accuracy: 0.01)
        XCTAssertGreaterThan(move.distanceMeters, 0)
    }

    func testMatchingAMoveStaysOffTheUndoStack() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true, policy: .recorded)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        try context.save()

        XCTAssertNotNil(move.routeCacheCoordinatesData)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(context.undoManager === undoManager)
    }

    func testTrainNeverCallsDirections() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true, mode: .train)
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .recorded)
    }

    func testRecordedPolicySkipsDirections() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true, policy: .recorded)
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .recorded)
        XCTAssertEqual(move.routeMatchSummary, "Recorded")
    }

    func testRoadsPolicyKeepsAnImplausibleRoute() async throws {
        let fixture = try loadFixture("sparse-car")
        let move = makeMove(from: fixture, includePlaces: true, policy: .roads)
        let provider = FakeDirectionsProvider(style: .detour)
        RoadRouteMatcher.directionsProvider = provider

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
        let recorded = routeDistance(for: MoveRouteGeometry.rawCoordinates(for: move))
        let requestCount = await provider.requestCount

        XCTAssertGreaterThan(requestCount, 0)
        XCTAssertGreaterThan(routeDistance(for: coordinates), recorded * 1.3)
    }

    func testRejectedMatchIsMemoisedForADay() async throws {
        let fixture = try loadFixture("sparse-car")
        let move = makeMove(from: fixture, includePlaces: true)
        let provider = FakeDirectionsProvider(style: .detour)
        RoadRouteMatcher.directionsProvider = provider

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let firstCount = await provider.requestCount
        XCTAssertGreaterThan(firstCount, 0)
        XCTAssertEqual(move.routeMatchConfidence, .estimated)

        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
        let secondCount = await provider.requestCount
        XCTAssertEqual(secondCount, firstCount)
    }

    func testManualPolicyWinsOverRecordedFixes() async throws {
        let fixture = try loadFixture("dense-walk")
        let move = makeMove(from: fixture, includePlaces: true)
        let manual = [
            CLLocationCoordinate2D(latitude: 52.51, longitude: 13.40),
            CLLocationCoordinate2D(latitude: 52.52, longitude: 13.41),
        ]
        move.storeManualRouteCoordinates(manual)
        move.routeMatchPolicy = .manual
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider

        let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
        let requestCount = await provider.requestCount

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(move.routeMatchSummary, RouteMatchSummaries.manual)
    }

    func testDeferredMatchingFillsInImportedPathsOnce() async throws {
        let move = makeMove(from: try loadFixture("sparse-car"), includePlaces: true)
        move.origin = .imported
        try context.save()
        let moveID = move.id
        let provider = FakeDirectionsProvider(style: .close)
        RoadRouteMatcher.directionsProvider = provider
        let defaults = try makeDefaults()

        let result = await RouteMatchBackgroundTask.matchWaitingMoves(in: container, defaults: defaults)
        let requestCount = await provider.requestCount

        XCTAssertEqual(result, .finished)
        XCTAssertGreaterThan(requestCount, 0)
        XCTAssertNil(defaults.object(forKey: RouteMatchBackgroundTask.cursorKey))
        let stored = try XCTUnwrap(try storedMove(moveID))
        XCTAssertNotNil(stored.routeCacheCoordinatesData)
        XCTAssertEqual(stored.routeMatchConfidence, .medium)

        let second = await RouteMatchBackgroundTask.matchWaitingMoves(in: container, defaults: defaults)
        let requestCountAfterSecond = await provider.requestCount
        XCTAssertEqual(second, .finished)
        XCTAssertEqual(requestCountAfterSecond, requestCount)
    }

    func testDeferredMatchingWalksPastAMoveItCannotMatch() async throws {
        let fixture = try loadFixture("sparse-car")
        let newer = makeMove(from: fixture, includePlaces: true)
        let older = makeMove(from: fixture, includePlaces: true)
        older.startDate = newer.startDate.addingTimeInterval(-86_400)
        older.endDate = newer.endDate.addingTimeInterval(-86_400)
        try context.save()
        let newerStart = newer.startDate
        let olderStart = older.startDate
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .detour)
        let defaults = try makeDefaults()
        func run() async -> RouteMatchBackgroundTask.RunResult {
            await RouteMatchBackgroundTask.matchWaitingMoves(in: container, limit: 1, defaults: defaults)
        }
        let cursor = { defaults.object(forKey: RouteMatchBackgroundTask.cursorKey) as? Date }

        let first = await run()
        XCTAssertEqual(first, .more)
        XCTAssertEqual(cursor(), newerStart)

        let second = await run()
        XCTAssertEqual(second, .more)
        XCTAssertEqual(cursor(), olderStart)

        let third = await run()
        XCTAssertEqual(third, .finished)
        XCTAssertNil(cursor())
        let waiting = try ModelContext(container).fetch(FetchDescriptor<MoveSegment>())
        XCTAssertTrue(waiting.allSatisfy { $0.routeCacheCoordinatesData == nil })
    }

    func testDeferredMatchingSurvivesTheMoveBeingDeletedDuringARequest() async throws {
        let move = makeMove(from: try loadFixture("sparse-car"), includePlaces: true)
        try context.save()
        let moveID = move.id
        RoadRouteMatcher.directionsProvider = DeletingDirectionsProvider(container: container, moveID: moveID)

        let result = await RouteMatchBackgroundTask.matchWaitingMoves(in: container, defaults: try makeDefaults())

        XCTAssertEqual(result, .finished)
        XCTAssertNil(try storedMove(moveID))
    }

    func testDeferredMatchingResumesAmongMovesWithTheSameStartTime() async throws {
        let fixture = try loadFixture("sparse-car")
        let firstID = makeMove(from: fixture, includePlaces: true).id
        let secondID = makeMove(from: fixture, includePlaces: true).id
        try context.save()
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .close)
        let defaults = try makeDefaults()

        for _ in 0..<3 {
            _ = await RouteMatchBackgroundTask.matchWaitingMoves(in: container, limit: 1, defaults: defaults)
        }

        XCTAssertNotNil(try XCTUnwrap(try storedMove(firstID)).routeCacheCoordinatesData)
        XCTAssertNotNil(try XCTUnwrap(try storedMove(secondID)).routeCacheCoordinatesData)
        XCTAssertNil(defaults.object(forKey: RouteMatchBackgroundTask.cursorKey))
        XCTAssertNil(defaults.object(forKey: RouteMatchBackgroundTask.cursorIDsKey))
    }

    func testDeferredMatchingStopsAndKeepsItsPlaceWhenTheBudgetRunsOut() async throws {
        let move = makeMove(from: try loadFixture("sparse-car"), includePlaces: true)
        try context.save()
        let moveID = move.id
        RoadRouteMatcher.directionsProvider = FakeDirectionsProvider(style: .close)
        let defaults = try makeDefaults()
        for _ in 0..<DirectionsRequestLimiter.maxRequestsPerWindow {
            _ = await DirectionsRequestLimiter.shared.reserveSlot()
        }

        let throttled = await RouteMatchBackgroundTask.matchWaitingMoves(
            in: container,
            throttleWait: .zero,
            defaults: defaults
        )
        XCTAssertEqual(throttled, .throttled)
        XCTAssertNil(defaults.object(forKey: RouteMatchBackgroundTask.cursorKey))
        XCTAssertNil(try XCTUnwrap(try storedMove(moveID)).routeCacheCoordinatesData)

        await DirectionsRequestLimiter.shared.reset()
        let resumed = await RouteMatchBackgroundTask.matchWaitingMoves(in: container, defaults: defaults)
        XCTAssertEqual(resumed, .finished)
        XCTAssertNotNil(try XCTUnwrap(try storedMove(moveID)).routeCacheCoordinatesData)
    }

    func testDeferredMatchingPreservesACorrectionMadeDuringTheRequest() async throws {
        let move = makeMove(from: try loadFixture("sparse-car"), includePlaces: true)
        try context.save()
        let moveID = move.id
        RoadRouteMatcher.directionsProvider = CorrectingDirectionsProvider(container: container, moveID: moveID)

        _ = await RoadRouteMatcher.matchDeferred(moveID: moveID, in: container)

        let corrected = try XCTUnwrap(try storedMove(moveID))
        XCTAssertEqual(corrected.transportMode, .walking)
        XCTAssertEqual(corrected.transportModeSource, .user)
        XCTAssertEqual(corrected.routeMatchPolicy, .recorded)
        XCTAssertEqual(corrected.routeMatchConfidence, .unknown)
        XCTAssertNil(corrected.routeMatchSummary)
        XCTAssertNil(corrected.routeCacheCoordinatesData)
    }

    func testForegroundMatchingReturnsTheNewManualPathAfterAnInFlightEdit() async throws {
        let move = makeMove(from: try loadFixture("sparse-car"), includePlaces: true)
        let manual = [CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4), CLLocationCoordinate2D(latitude: 52.501, longitude: 13.401)]
        RoadRouteMatcher.directionsProvider = ManualEditingDirectionsProvider(move: move, coordinates: manual)

        let result = await RoadRouteMatcher.matchedCoordinates(for: move)

        XCTAssertEqual(result.count, manual.count)
        XCTAssertEqual(result.first?.latitude, manual.first?.latitude)
        XCTAssertEqual(move.routeMatchPolicy, .manual)
        XCTAssertEqual(move.routeMatchSummary, RouteMatchSummaries.manual)
        XCTAssertEqual(move.distanceMeters, routeDistance(for: manual), accuracy: 0.1)
    }

    private func storedMove(_ id: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "RouteMatchPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testDailyDirectionsCap() async {
        let limiter = DirectionsRequestLimiter.shared
        await limiter.reset()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<DirectionsRequestLimiter.maxRequestsPerDay {
            let now = start.addingTimeInterval(Double(index / 40) * 60)
            let reserved = await limiter.reserveSlot(now: now)
            XCTAssertTrue(reserved, "Expected slot \(index) to be reserved")
        }

        let blocked = await limiter.reserveSlot(now: start.addingTimeInterval(10 * 60))
        XCTAssertFalse(blocked)
        let nextDay = await limiter.reserveSlot(now: start.addingTimeInterval(86_400))
        XCTAssertTrue(nextDay)
    }
}

// MARK: - Fake provider

actor FakeDirectionsProvider: DirectionsProvider {
    enum Style: Sendable {
        case close
        case detour
        case baseline(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)
    }

    private(set) var requestCount = 0
    var style: Style

    init(style: Style) {
        self.style = style
    }

    func routes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        requestsAlternateRoutes: Bool
    ) async throws -> [[CLLocationCoordinate2D]] {
        requestCount += 1

        switch style {
        case .close:
            let mid = CLLocationCoordinate2D(
                latitude: (start.latitude + end.latitude) / 2 + 0.000015,
                longitude: (start.longitude + end.longitude) / 2
            )
            return [[start, mid, end]]
        case .detour:
            let via = CLLocationCoordinate2D(
                latitude: start.latitude,
                longitude: start.longitude + 0.05
            )
            return [[start, via, end]]
        case .baseline(let baselineStart, let baselineEnd):
            return [[baselineStart, baselineEnd]]
        }
    }
}

/// Simulates a person's correction while the directions service is answering.
@MainActor
private final class ManualEditingDirectionsProvider: DirectionsProvider {
    let move: MoveSegment
    let coordinates: [CLLocationCoordinate2D]

    init(move: MoveSegment, coordinates: [CLLocationCoordinate2D]) {
        self.move = move
        self.coordinates = coordinates
    }

    func routes(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, transportType: MKDirectionsTransportType, requestsAlternateRoutes: Bool) async throws -> [[CLLocationCoordinate2D]] {
        move.storeManualRouteCoordinates(coordinates)
        move.routeMatchPolicy = .manual
        return [[start, end]]
    }
}

/// Simulates a correction on a different context during background matching.
private actor CorrectingDirectionsProvider: DirectionsProvider {
    let container: ModelContainer
    let moveID: UUID

    init(container: ModelContainer, moveID: UUID) {
        self.container = container
        self.moveID = moveID
    }

    func routes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        requestsAlternateRoutes: Bool
    ) async throws -> [[CLLocationCoordinate2D]] {
        let container = container
        let moveID = moveID
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == moveID })
            if let move = try context.fetch(descriptor).first {
                move.transportMode = .walking
                move.transportModeSource = .user
                move.routeMatchPolicy = .recorded
                move.clearCachedRouteCoordinates()
                try context.save()
            }
        }
        return [[start, end]]
    }
}

/// Deletes a move on another context while its directions request is in flight.
private actor DeletingDirectionsProvider: DirectionsProvider {
    let container: ModelContainer
    let moveID: UUID

    init(container: ModelContainer, moveID: UUID) {
        self.container = container
        self.moveID = moveID
    }

    func routes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        requestsAlternateRoutes: Bool
    ) async throws -> [[CLLocationCoordinate2D]] {
        let container = container
        let moveID = moveID
        await MainActor.run {
            let context = ModelContext(container)
            let moves = (try? context.fetch(FetchDescriptor<MoveSegment>())) ?? []
            for move in moves where move.id == moveID {
                context.delete(move)
            }
            try? context.save()
        }
        return [[start, end]]
    }
}

// MARK: - Fixtures

private struct RouteMatchFixture: Decodable {
    let mode: String
    let accuracy: Double
    let points: [Point]

    struct Point: Decodable {
        let lat: Double
        let lon: Double
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var transportMode: TransportMode {
        TransportMode(rawValue: mode) ?? .unknown
    }
}

extension RouteMatchPolicyTests {
    private func loadFixture(_ name: String) throws -> RouteMatchFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RouteMatchFixture.self, from: data)
    }

    private func makeMove(
        from fixture: RouteMatchFixture,
        includePlaces: Bool,
        mode: TransportMode? = nil,
        policy: RouteMatchPolicy = .auto,
        source: LocationSampleSource = .significantChange
    ) -> MoveSegment {
        let coordinates = fixture.coordinates
        let transportMode = mode ?? fixture.transportMode
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let endDate = startDate.addingTimeInterval(Double(max(coordinates.count, 1)) * 80)

        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: startDate,
            endDate: endDate,
            transportMode: transportMode,
            distanceMeters: routeDistance(for: coordinates),
            stepCount: nil
        )
        move.routeMatchPolicy = policy
        move.dayTimeline = timeline(for: startDate)

        if includePlaces, let first = coordinates.first, let last = coordinates.last {
            let startPlace = VisitPlace(
                arrivalDate: startDate.addingTimeInterval(-600),
                departureDate: startDate,
                latitude: first.latitude,
                longitude: first.longitude,
                horizontalAccuracy: fixture.accuracy
            )
            startPlace.dayTimeline = move.dayTimeline
            context.insert(startPlace)
            move.startPlace = startPlace

            let endPlace = VisitPlace(
                arrivalDate: endDate,
                departureDate: endDate.addingTimeInterval(600),
                latitude: last.latitude,
                longitude: last.longitude,
                horizontalAccuracy: fixture.accuracy
            )
            endPlace.dayTimeline = move.dayTimeline
            context.insert(endPlace)
            move.endPlace = endPlace
        }

        var samples: [LocationSample] = []
        for (index, coordinate) in coordinates.enumerated() {
            let location = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: fixture.accuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: transportMode == .walking ? 1.4 : 12,
                timestamp: startDate.addingTimeInterval(Double(index) * 80)
            )
            let sample = LocationSample(
                location: location,
                source: source,
                dedupeKey: "\(move.dedupeKey)-\(index)"
            )
            sample.moveSegment = move
            sample.dayTimeline = move.dayTimeline
            context.insert(sample)
            samples.append(sample)
        }
        move.samples = samples
        context.insert(move)
        return move
    }

    private func makeEndpointCarMove() -> MoveSegment {
        let start = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
        let end = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4220)
        let startDate = Date(timeIntervalSince1970: 1_800_100_000)
        let endDate = startDate.addingTimeInterval(12 * 60)

        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: startDate,
            endDate: endDate,
            transportMode: .automotive,
            distanceMeters: RouteCoordinateOps.distanceMeters(from: start, to: end),
            stepCount: nil
        )
        move.dayTimeline = timeline(for: startDate)

        let startPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-600),
            departureDate: startDate,
            latitude: start.latitude,
            longitude: start.longitude,
            horizontalAccuracy: 15
        )
        startPlace.dayTimeline = move.dayTimeline
        context.insert(startPlace)
        move.startPlace = startPlace

        let endPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: endDate.addingTimeInterval(600),
            latitude: end.latitude,
            longitude: end.longitude,
            horizontalAccuracy: 15
        )
        endPlace.dayTimeline = move.dayTimeline
        context.insert(endPlace)
        move.endPlace = endPlace
        context.insert(move)
        return move
    }

    private func timeline(for date: Date) -> DayTimeline {
        let timeline = DayTimeline(dayStart: date)
        context.insert(timeline)
        return timeline
    }
}
