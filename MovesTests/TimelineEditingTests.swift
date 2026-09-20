import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class TimelineEditingTests: XCTestCase {
    func testDissolveVisitMergesIncomingAndOutgoingMoves() throws {
        let (repository, context, _) = try makeRepository()
        let home = insertPlace(
            in: context,
            arrival: date(10, 0),
            departure: date(10, 30),
            latitude: 52.52,
            longitude: 13.40
        )
        let light = insertPlace(
            in: context,
            arrival: date(10, 35),
            departure: date(10, 37),
            latitude: 52.521,
            longitude: 13.405
        )
        let cafe = insertPlace(
            in: context,
            arrival: date(10, 50),
            departure: date(11, 20),
            latitude: 52.53,
            longitude: 13.41
        )
        let incoming = insertMove(
            in: context,
            from: home,
            to: light,
            start: date(10, 30),
            end: date(10, 35),
            mode: .walking,
            distance: 400
        )
        let outgoing = insertMove(
            in: context,
            from: light,
            to: cafe,
            start: date(10, 37),
            end: date(10, 50),
            mode: .walking,
            distance: 800
        )
        try context.save()

        let merged = try repository.dissolveVisit(light)

        XCTAssertEqual(merged.id, incoming.id)
        XCTAssertEqual(merged.startPlace?.id, home.id)
        XCTAssertEqual(merged.endPlace?.id, cafe.id)
        XCTAssertEqual(merged.startDate, date(10, 30))
        XCTAssertEqual(merged.endDate, date(10, 50))
        XCTAssertGreaterThan(merged.distanceMeters, 1_000)
        XCTAssertNil(try context.fetch(FetchDescriptor<VisitPlace>()).first { $0.id == light.id })
        XCTAssertNil(try context.fetch(FetchDescriptor<MoveSegment>()).first { $0.id == outgoing.id })
    }

    func testDissolveVisitWithoutNeighborsThrows() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertPlace(
            in: context,
            arrival: date(9, 0),
            departure: date(10, 0),
            latitude: 52.52,
            longitude: 13.40
        )
        try context.save()

        XCTAssertThrowsError(try repository.dissolveVisit(visit)) { error in
            XCTAssertEqual(error as? TimelineEditingError, .missingNeighbors)
        }
    }

    func testMergeVisitsDeletesTheConnectingMove() throws {
        let (repository, context, _) = try makeRepository()
        let first = insertPlace(
            in: context,
            arrival: date(12, 0),
            departure: date(12, 20),
            latitude: 52.5200,
            longitude: 13.4050,
            userLabel: "Home"
        )
        let second = insertPlace(
            in: context,
            arrival: date(12, 25),
            departure: date(13, 0),
            latitude: 52.5204,
            longitude: 13.4053,
            userLabel: "Home"
        )
        _ = insertMove(
            in: context,
            from: first,
            to: second,
            start: date(12, 20),
            end: date(12, 25),
            mode: .walking,
            distance: 40
        )
        try context.save()

        let merged = try repository.mergeVisits(first, second)

        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.departureDate, date(13, 0))
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).count, 0)
    }

    func testSplitMoveInsertsAVisitAndTwoMoves() throws {
        let (repository, context, _) = try makeRepository()
        let start = insertPlace(
            in: context,
            arrival: date(8, 0),
            departure: date(8, 10),
            latitude: 52.50,
            longitude: 13.40
        )
        let end = insertPlace(
            in: context,
            arrival: date(8, 40),
            departure: date(9, 0),
            latitude: 52.54,
            longitude: 13.44
        )
        let move = insertMove(
            in: context,
            from: start,
            to: end,
            start: date(8, 10),
            end: date(8, 40),
            mode: .cycling,
            distance: 4_000
        )
        move.storeCachedRouteCoordinates(
            [
                start.coordinate,
                CLLocationCoordinate2D(latitude: 52.52, longitude: 13.42),
                end.coordinate,
            ],
            signature: "test-route"
        )
        try context.save()

        let splitAt = date(8, 25)
        let (first, visit, second) = try repository.splitMove(move, at: splitAt)

        XCTAssertEqual(first.endPlace?.id, visit.id)
        XCTAssertEqual(second.startPlace?.id, visit.id)
        XCTAssertEqual(second.endPlace?.id, end.id)
        XCTAssertEqual(first.endDate, splitAt)
        XCTAssertEqual(second.startDate, splitAt)
        XCTAssertEqual(visit.arrivalDate, splitAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).count, 2)
        XCTAssertEqual(first.transportMode, .cycling)
        XCTAssertEqual(second.transportMode, .cycling)
    }

    func testSplitMoveAtEndpointThrows() throws {
        let (repository, context, _) = try makeRepository()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)
        let move = insertMove(
            in: context,
            from: start,
            to: end,
            start: date(8, 10),
            end: date(8, 40),
            mode: .walking,
            distance: 1_000
        )
        try context.save()

        XCTAssertThrowsError(try repository.splitMove(move, at: date(8, 10))) { error in
            XCTAssertEqual(error as? TimelineEditingError, .invalidSplitTime)
        }
    }

    func testSplitVisitKeepsOutgoingMovesOnTheSecondStay() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertPlace(
            in: context,
            arrival: date(18, 0),
            departure: date(22, 0),
            latitude: 52.52,
            longitude: 13.40,
            userLabel: "Home"
        )
        let next = insertPlace(
            in: context,
            arrival: date(22, 20),
            departure: nil,
            latitude: 52.53,
            longitude: 13.41
        )
        let outgoing = insertMove(
            in: context,
            from: visit,
            to: next,
            start: date(22, 0),
            end: date(22, 20),
            mode: .walking,
            distance: 600
        )
        try context.save()

        let (first, second) = try repository.splitVisit(visit, at: date(20, 0))

        XCTAssertEqual(first.departureDate, date(20, 0))
        XCTAssertEqual(second.arrivalDate, date(20, 0))
        XCTAssertEqual(second.departureDate, date(22, 0))
        XCTAssertEqual(outgoing.startPlace?.id, second.id)
        XCTAssertEqual(second.userLabel, "Home")
    }

    func testUpdateTimesAdjustsNeighboringMoves() throws {
        let (repository, context, _) = try makeRepository()
        let previous = insertPlace(in: context, arrival: date(9, 0), departure: date(10, 0), latitude: 52.51, longitude: 13.39)
        let visit = insertPlace(in: context, arrival: date(10, 20), departure: date(11, 0), latitude: 52.52, longitude: 13.40)
        let next = insertPlace(in: context, arrival: date(11, 20), departure: date(12, 0), latitude: 52.53, longitude: 13.41)
        let incoming = insertMove(in: context, from: previous, to: visit, start: date(10, 0), end: date(10, 20), mode: .walking, distance: 500)
        let outgoing = insertMove(in: context, from: visit, to: next, start: date(11, 0), end: date(11, 20), mode: .walking, distance: 500)
        try context.save()

        try repository.updateTimes(of: visit, arrival: date(10, 15), departure: date(11, 10))

        XCTAssertEqual(visit.arrivalDate, date(10, 15))
        XCTAssertEqual(visit.departureDate, date(11, 10))
        XCTAssertEqual(incoming.endDate, date(10, 15))
        XCTAssertEqual(outgoing.startDate, date(11, 10))
    }

    func testUpdateTimesRejectsInvertedRange() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertPlace(in: context, arrival: date(10, 0), departure: date(11, 0), latitude: 52.52, longitude: 13.40)
        try context.save()

        XCTAssertThrowsError(try repository.updateTimes(of: visit, arrival: date(11, 0), departure: date(10, 0))) { error in
            XCTAssertEqual(error as? TimelineEditingError, .invalidTimeRange)
        }
    }

    func testSetTransportModeRecordsUserSourceAndClearsCache() throws {
        let (repository, context, _) = try makeRepository()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)
        let move = insertMove(in: context, from: start, to: end, start: date(8, 10), end: date(8, 40), mode: .automotive, distance: 4_000)
        move.storeCachedRouteCoordinates([start.coordinate, end.coordinate], signature: "cached")
        try context.save()

        try repository.setTransportMode(.cycling, for: move, source: .user)

        XCTAssertEqual(move.transportMode, .cycling)
        XCTAssertEqual(move.transportModeSource, .user)
        XCTAssertNil(move.routeCacheCoordinatesData)
    }

    func testAssignAndCreateKnownPlace() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertPlace(
            in: context,
            arrival: date(19, 0),
            departure: date(22, 0),
            latitude: 52.52,
            longitude: 13.40
        )
        try context.save()

        let place = try repository.createKnownPlace(from: visit, name: "Home")
        XCTAssertEqual(visit.knownPlace?.id, place.id)
        XCTAssertEqual(visit.assignmentSource, .user)
        XCTAssertEqual(visit.userLabel, "Home")

        let nearby = try repository.knownPlaces(near: visit.coordinate, within: 50)
        XCTAssertEqual(nearby.map(\.id), [place.id])
    }

    func testRangeQueriesFilterByTimeAndMode() throws {
        let (repository, context, _) = try makeRepository()
        let home = insertPlace(in: context, arrival: date(8, 0), departure: date(9, 0), latitude: 52.52, longitude: 13.40)
        let work = insertPlace(in: context, arrival: date(9, 30), departure: date(17, 0), latitude: 52.53, longitude: 13.41)
        _ = insertMove(in: context, from: home, to: work, start: date(9, 0), end: date(9, 30), mode: .cycling, distance: 3_000)
        try context.save()

        let morning = DateInterval(start: date(8, 0), end: date(10, 0))
        XCTAssertEqual(try repository.visits(in: morning).count, 2)
        XCTAssertEqual(try repository.moves(in: morning, modes: [.cycling]).count, 1)
        XCTAssertEqual(try repository.moves(in: morning, modes: [.walking]).count, 0)
    }

    func testTransportModeChangeIsUndoable() throws {
        let (repository, context, _) = try makeRepository()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.5, longitude: 13.4)
        let end = insertPlace(in: context, arrival: date(8, 40), departure: date(9, 0), latitude: 52.54, longitude: 13.44)
        let move = insertMove(in: context, from: start, to: end, start: date(8, 10), end: date(8, 40), mode: .automotive, distance: 4_000)
        try context.save()

        try repository.setTransportMode(.cycling, for: move, source: .user)
        XCTAssertEqual(move.transportMode, .cycling)
        XCTAssertEqual(move.transportModeSource, .user)
        XCTAssertTrue(context.undoManager?.canUndo == true)

        context.undoManager?.undo()
        if context.hasChanges {
            try context.save()
        }

        XCTAssertEqual(move.transportMode, .automotive)
    }

    func testSchemaUpgraderClustersLabeledVisitsIdempotently() throws {
        let (_, context, _) = try makeRepository()
        let first = insertPlace(
            in: context,
            arrival: date(9, 0),
            departure: date(10, 0),
            latitude: 52.5200,
            longitude: 13.4050,
            userLabel: "Home"
        )
        let second = insertPlace(
            in: context,
            arrival: date(18, 0),
            departure: date(22, 0),
            latitude: 52.5204,
            longitude: 13.4052,
            userLabel: "Home"
        )
        let far = insertPlace(
            in: context,
            arrival: date(12, 0),
            departure: date(13, 0),
            latitude: 53.55,
            longitude: 9.99,
            userLabel: "Home"
        )
        try context.save()

        try TimelineSchemaUpgrader.upgrade(in: context)
        try TimelineSchemaUpgrader.upgrade(in: context)

        let known = try context.fetch(FetchDescriptor<KnownPlace>())
        XCTAssertEqual(known.count, 2)
        XCTAssertEqual(first.knownPlace?.id, second.knownPlace?.id)
        XCTAssertNotEqual(first.knownPlace?.id, far.knownPlace?.id)
        XCTAssertEqual(first.assignmentSource, .user)
        XCTAssertEqual(second.assignmentSource, .user)
    }

    func testSchemaUpgraderCopiesShortStopHeuristicAndRoutePolicies() throws {
        let (_, context, _) = try makeRepository()
        let start = insertPlace(in: context, arrival: date(8, 0), departure: date(8, 10), latitude: 52.50, longitude: 13.40)
        let brief = insertPlace(in: context, arrival: date(8, 12), departure: date(8, 14), latitude: 52.501, longitude: 13.401)
        let end = insertPlace(in: context, arrival: date(8, 20), departure: date(9, 0), latitude: 52.51, longitude: 13.41)
        _ = insertMove(in: context, from: start, to: brief, start: date(8, 10), end: date(8, 12), mode: .walking, distance: 80)
        let tracked = insertMove(in: context, from: brief, to: end, start: date(8, 14), end: date(8, 20), mode: .walking, distance: 400)
        let sample = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.505, longitude: 13.405),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: -1,
                course: -1,
                speed: 1.4,
                timestamp: date(8, 16)
            ),
            source: .routeTracking,
            dedupeKey: "tracked-1"
        )
        sample.moveSegment = tracked
        context.insert(sample)

        let manual = insertMove(
            in: context,
            from: end,
            to: start,
            start: date(9, 0),
            end: date(9, 30),
            mode: .automotive,
            distance: 2_000
        )
        manual.storeManualRouteCoordinates([end.coordinate, start.coordinate])
        try context.save()

        try TimelineSchemaUpgrader.upgrade(in: context)

        XCTAssertTrue(brief.isHiddenAsShortStop)
        XCTAssertFalse(start.isHiddenAsShortStop)
        XCTAssertEqual(tracked.routeMatchPolicy, .recorded)
        XCTAssertEqual(manual.routeMatchPolicy, .manual)
    }

    func testPhotoLibrarySamplesAreNotRouteTracks() {
        XCTAssertEqual(LocationSampleSource.photoLibrary.priority, 1)
        XCTAssertFalse(LocationSampleSource.photoLibrary.isRouteTrack)
        XCTAssertEqual(LocationSampleSource.googleTimelineImport.priority, 7)
        XCTAssertTrue(LocationSampleSource.googleTimelineImport.isRouteTrack)
        XCTAssertEqual(LocationSampleSource.fileRouteImport.priority, 7)
        XCTAssertTrue(LocationSampleSource.routeTracking.isRouteTrack)
    }

    private func makeRepository() throws -> (SwiftDataTimelineRepository, ModelContext, ModelContainer) {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        context.autosaveEnabled = false
        return (SwiftDataTimelineRepository(modelContext: context), context, container)
    }

    private func insertPlace(
        in context: ModelContext,
        arrival: Date,
        departure: Date?,
        latitude: Double,
        longitude: Double,
        userLabel: String? = nil
    ) -> VisitPlace {
        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: 12,
            userLabel: userLabel
        )
        place.dayTimeline = timeline(in: context, for: arrival)
        context.insert(place)
        return place
    }

    private func insertMove(
        in context: ModelContext,
        from startPlace: VisitPlace,
        to endPlace: VisitPlace,
        start: Date,
        end: Date,
        mode: TransportMode,
        distance: CLLocationDistance
    ) -> MoveSegment {
        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: start,
            endDate: end,
            transportMode: mode,
            distanceMeters: distance,
            stepCount: nil
        )
        move.startPlace = startPlace
        move.endPlace = endPlace
        move.dayTimeline = timeline(in: context, for: start)
        context.insert(move)
        return move
    }

    private func timeline(in context: ModelContext, for date: Date) -> DayTimeline {
        let dayKey = DayTimeline.makeDayKey(for: date)
        if let existing = try? context.fetch(FetchDescriptor<DayTimeline>()).first(where: { $0.dayKey == dayKey }) {
            return existing
        }
        let timeline = DayTimeline(dayStart: date)
        context.insert(timeline)
        return timeline
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
