import CoreLocation
import ImageIO
import MapKit
import SwiftData
import XCTest
@testable import Moves

final class MapTileTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
    private let viewSize = CGSize(width: 400, height: 800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Addressing

    func testLevelsAndTilesAddressTheWholeWorld() {
        XCTAssertEqual(MapTileLevels.tileSize(MapTileLevels.coarsestLevel), MKMapSize.world.width)
        XCTAssertEqual(MapTileLevels.tilesPerSide(MapTileLevels.coarsestLevel), 1)
        XCTAssertEqual(MapTileLevels.tilesPerSide(10), 64)
        XCTAssertEqual(MapTileLevels.all, [2, 4, 6, 8, 10, 12, 14, 16])
        XCTAssertEqual(MapTileLevels.level(forCellAtMost: 16), 4)
        XCTAssertEqual(MapTileLevels.level(forCellAtMost: 31.9), 4, "Only every other level is stored; take the finer one")
        XCTAssertEqual(MapTileLevels.level(forCellAtMost: 0.01), MapTileLevels.finestLevel)
        XCTAssertEqual(MapTileLevels.level(forCellAtMost: 1e12), MapTileLevels.coarsestLevel)
        XCTAssertEqual(MapTileLevels.coarser(than: 4), 6)
        XCTAssertNil(MapTileLevels.coarser(than: 16))
        XCTAssertEqual(MapTileLevels.floorDiv(-1, 1_024), -1)
        XCTAssertEqual(MapTileLevels.floorDiv(-1_024, 1_024), -1)
        XCTAssertEqual(MapTileLevels.floorDiv(-1_025, 1_024), -2)
        XCTAssertEqual(MapTileLevels.floorDiv(1_023, 1_024), 0)

        let point = MercatorPoint(center)
        for level in MapTileLevels.all {
            let (key, cell) = try! XCTUnwrap(MapTileTiler.cell(for: point, level: level))
            let size = MapTileLevels.tileSize(level), cellSize = MapTileLevels.cellSize(level)
            let x = Double(key.x) * size + (Double(cell.x) + 0.5) * cellSize
            let y = Double(key.y) * size + (Double(cell.y) + 0.5) * cellSize
            XCTAssertEqual(x, point.x, accuracy: cellSize / 2 + 1e-6)
            XCTAssertEqual(y, point.y, accuracy: cellSize / 2 + 1e-6)
        }
        // Past the antimeridian, a point wraps to the tile on the far side.
        let east = MercatorPoint(x: MKMapSize.world.width + 10, y: point.y)
        XCTAssertEqual(MapTileTiler.cell(for: east, level: 10)?.0.x, 0)
        XCTAssertEqual(MapTileTiler.cell(for: MercatorPoint(x: -10, y: point.y), level: 10)?.0.x, 63)
    }

    func testARouteCrossingTilesIsCutAtTheEdgesWithoutGapsOrLostLength() {
        let level = 4
        let size = Double(MapTileLevels.cellsPerTile)
        // Cell units: from the middle of one tile, diagonally across into a third.
        let a = CGPoint(x: size * 10.5, y: size * 20.25), b = CGPoint(x: size * 12.75, y: size * 21.5)
        var tiles: [MapTileKey: MapTileContent] = [:]
        MapTileTiler.addPiece(from: a, to: b, mode: 1, level: level, trip: UUID(), start: 0, into: &tiles)
        XCTAssertGreaterThan(tiles.count, 2)
        var length = 0.0
        var ends: [CGPoint] = []
        for (key, content) in tiles {
            XCTAssertFalse(key.isLong)
            for segment in content.segments.keys {
                XCTAssertTrue((0...Int32(size)).contains(segment.x0) && (0...Int32(size)).contains(segment.x1))
                let p = CGPoint(x: Double(key.x) * size + Double(segment.x0), y: Double(key.y) * size + Double(segment.y0))
                let q = CGPoint(x: Double(key.x) * size + Double(segment.x1), y: Double(key.y) * size + Double(segment.y1))
                length += hypot(q.x - p.x, q.y - p.y)
                ends += [p, q]
            }
        }
        XCTAssertEqual(length, hypot(b.x - a.x, b.y - a.y), accuracy: Double(tiles.count) * 1.5)
        // Every piece's end lands on another piece's end or on the route's own ends.
        for end in ends {
            let matches = ends.filter { hypot($0.x - end.x, $0.y - end.y) < 1.5 }.count
            let isRouteEnd = hypot(end.x - a.x, end.y - a.y) < 1 || hypot(end.x - b.x, end.y - b.y) < 1
            XCTAssertTrue(matches >= 2 || isRouteEnd, "\(end) is a loose end")
        }
    }

    func testAFlightIsKeptWholeInsteadOfCutIntoThousandsOfTiles() {
        let tokyo = MercatorPoint(CLLocationCoordinate2D(latitude: 35.5, longitude: 139.8))
        let sydney = MercatorPoint(CLLocationCoordinate2D(latitude: -33.9, longitude: 151.2))
        let track = MapTileTrack(id: UUID(), start: .now, end: .now, mode: .plane, distanceMeters: 7_800_000, points: [tokyo, sydney])
        var tiles: [MapTileKey: MapTileContent] = [:]
        MapTileTiler.add(track, levels: [2], keepTrips: true, into: &tiles)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertTrue(tiles.keys.first?.isLong ?? false)
        tiles.removeAll()
        MapTileTiler.add(track, levels: [16], keepTrips: true, into: &tiles)
        XCTAssertFalse(tiles.keys.contains { $0.isLong }, "At a coarse level it fits in a few tiles")
    }

    func testRepeatedTripsCollapseIntoCountedSegments() {
        var tiles: [MapTileKey: MapTileContent] = [:]
        let points = (0..<50).map { MercatorPoint(x: MercatorPoint(center).x + Double($0) * 40, y: MercatorPoint(center).y) }
        for day in 0..<300 {
            let track = MapTileTrack(id: UUID(), start: Date(timeIntervalSince1970: Double(day) * 86_400), end: .now,
                                     mode: .cycling, distanceMeters: 300, points: points)
            MapTileTiler.add(track, levels: [6], keepTrips: true, into: &tiles)
        }
        let segments = tiles.values.flatMap(\.segments)
        XCTAssertLessThan(segments.count, 10, "The same road 300 times is one road")
        XCTAssertTrue(segments.allSatisfy { $0.value.count == 300 })
    }

    func testRecordsRoundTripThroughTheCodec() throws {
        var content = MapTileContent()
        let trip = UUID()
        content.addSegment(MapTileSegment(mode: 3, x0: 1_024, y0: 5, x1: 0, y1: 7), count: 9, trip: trip, tripStart: 42)
        content.addStay(MapTileCell(x: 3, y: 1_023), count: 2, hours: 4.5)
        content.undated.insert(MapTileCell(x: 9, y: 9))
        let record = try XCTUnwrap(MapTileCodec.decode(MapTileCodec.encode(content, absolute: false, keepTrips: true)))
        XCTAssertEqual(record.segmentCount, 1)
        XCTAssertEqual(record.segmentCoordinates, [0, 7, 1_024, 5], "Endpoints are ordered")
        XCTAssertEqual(record.segmentCounts, [9])
        XCTAssertEqual(record.trips.first?.id, trip)
        XCTAssertEqual(record.stayHours, [4.5])
        XCTAssertEqual(record.undatedCoordinates, [9, 9])
        let back = MapTileCodec.content(of: record)
        XCTAssertEqual(back.segments.first?.value.trip, trip)
        XCTAssertEqual(back.stays.first?.value.count, 2)
        // Absolute records carry coordinates far past 16 bits.
        var long = MapTileContent()
        long.addSegment(MapTileSegment(mode: 7, x0: -5_000_000, y0: 3, x1: 90_000_000, y1: 4), trip: nil, tripStart: 0)
        let decoded = try XCTUnwrap(MapTileCodec.decode(MapTileCodec.encode(long, absolute: true, keepTrips: false)))
        XCTAssertEqual(decoded.segmentCoordinates, [-5_000_000, 3, 90_000_000, 4])
        XCTAssertNil(MapTileCodec.decode(Data([2, 9, 9])), "A truncated record is refused")
    }

    // MARK: Ranges

    func testRangesBecomeWholeYearsMonthsAndLooseDays() {
        let calendar = self.calendar
        let now = date(2026, 11, 25, calendar: calendar)
        XCTAssertEqual(MapTileRangePlan.make(interval: DateInterval(start: .distantPast, end: now), isAllTime: true,
                                             includeUndated: true, now: now, calendar: calendar).buckets, [0])
        // This year: the year so far reads as one year bucket.
        let thisYear = DateInterval(start: date(2026, 1, 1, calendar: calendar), end: date(2027, 1, 1, calendar: calendar))
        let year = MapTileRangePlan.make(interval: thisYear, isAllTime: false, includeUndated: false, now: now, calendar: calendar)
        XCTAssertEqual(year.buckets, (1...12).map { 202_600 + $0 }, "The year is its months, none of them loose")
        XCTAssertTrue(year.partial.isEmpty)
        // 15 March 2024 to 10 June 2025: loose days at each end, whole months, and no whole year.
        let odd = DateInterval(start: date(2024, 3, 15, calendar: calendar), end: date(2025, 6, 10, calendar: calendar))
        let plan = MapTileRangePlan.make(interval: odd, isAllTime: false, includeUndated: false, now: now, calendar: calendar)
        XCTAssertEqual(plan.partial.count, 2)
        XCTAssertEqual(plan.partial.first?.start, odd.start)
        XCTAssertEqual(plan.partial.last?.end, odd.end)
        XCTAssertEqual(plan.buckets, (4...12).map { 202_400 + $0 } + (1...5).map { 202_500 + $0 })
        // Whole months exactly, no loose days.
        let span = DateInterval(start: date(2023, 1, 1, calendar: calendar), end: date(2025, 2, 1, calendar: calendar))
        let spanPlan = MapTileRangePlan.make(interval: span, isAllTime: false, includeUndated: false, now: now, calendar: calendar)
        XCTAssertEqual(spanPlan.buckets.count, 25)
        XCTAssertTrue(spanPlan.partial.isEmpty)
        // A week is just loose days.
        let week = DateInterval(start: date(2026, 11, 16, calendar: calendar), duration: 7 * 86_400)
        let weekPlan = MapTileRangePlan.make(interval: week, isAllTime: false, includeUndated: false, now: now, calendar: calendar)
        XCTAssertTrue(weekPlan.buckets.isEmpty)
        XCTAssertEqual(weekPlan.partial, [week])
    }

    func testARangeOfMonthsDrawsTheSameAsTheSameDataStoredTogether() throws {
        let calendar = self.calendar
        let months = [202_401, 202_402, 202_403]
        var byMonth: [Int: MapTileSourceValues] = [:]
        var everything = MapTileSourceValues()
        var generator = SeededGenerator(seed: 7)
        for (offset, month) in months.enumerated() {
            let start = MapTileBucket.interval(ofMonth: month, calendar: calendar).start
            let values = syntheticValues(trips: 60, stays: 40, start: start, seed: &generator, modes: offset == 1 ? [.cycling] : [.walking, .automotive])
            byMonth[month] = values
            everything.tracks += values.tracks
            everything.stays += values.stays
        }
        let split = try makeDatabase()
        try split.commit(months.map { month in
            let built = MapTileBuilder.build(month: month, values: byMonth[month]!, calendar: calendar)
            return MapTileDatabase.MonthBuild(bucket: month, signature: "s", summary: built.summary, tiles: built.tiles)
        })
        let together = try makeDatabase()
        let built = MapTileBuilder.build(month: 202_401, values: everything, calendar: calendar)
        try together.commit([MapTileDatabase.MonthBuild(bucket: 202_401, signature: "s", summary: built.summary, tiles: built.tiles)])

        for layer in MapCoverageLayer.allCases {
            for metersPerPoint in [12.0, 300] {
                let request = request(layer, metersPerPoint: metersPerPoint)
                let sum = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                    database: split, plan: MapTileRangePlan(buckets: months, partial: [], includeUndated: false), loose: nil, modes: nil)))
                let allTime = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                    database: split, plan: MapTileRangePlan(buckets: [0], partial: [], includeUndated: false), loose: nil, modes: nil)))
                let direct = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                    database: together, plan: MapTileRangePlan(buckets: [202_401], partial: [], includeUndated: false), loose: nil, modes: nil)))
                let a = meanAbsoluteDifference(sum.image, direct.image), b = meanAbsoluteDifference(allTime.image, direct.image)
                XCTAssertLessThan(a, 0.5, "\(layer) at \(metersPerPoint) m/pt: months vs one bucket differ by \(a)")
                XCTAssertLessThan(b, 0.5, "\(layer) at \(metersPerPoint) m/pt: all-time vs one bucket differ by \(b)")
            }
        }
        // Loose days drawn straight from values match the same days stored as a month.
        let loose = MapTileLooseData(values: everything)
        for layer in MapCoverageLayer.allCases {
            let request = request(layer, metersPerPoint: 30)
            let fromLoose = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                database: nil, plan: MapTileRangePlan(buckets: [], partial: [DateInterval(start: .distantPast, end: .distantFuture)], includeUndated: false),
                loose: loose, modes: nil)))
            let stored = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                database: together, plan: MapTileRangePlan(buckets: [202_401], partial: [], includeUndated: false), loose: nil, modes: nil)))
            XCTAssertLessThan(meanAbsoluteDifference(fromLoose.image, stored.image), 0.5, "\(layer)")
        }
        // Swapping a month out of the sums leaves exactly the other months.
        let rebuilt = MapTileBuilder.build(month: 202_402, values: MapTileSourceValues(), calendar: calendar)
        try split.commit([MapTileDatabase.MonthBuild(bucket: 202_402, signature: "t", summary: rebuilt.summary, tiles: rebuilt.tiles)])
        let request = request(.heat, metersPerPoint: 30)
        let withoutFebruary = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
            database: split, plan: MapTileRangePlan(buckets: [0], partial: [], includeUndated: false), loose: nil, modes: nil)))
        let januaryAndMarch = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
            database: split, plan: MapTileRangePlan(buckets: [202_401, 202_403], partial: [], includeUndated: false), loose: nil, modes: nil)))
        XCTAssertLessThan(meanAbsoluteDifference(withoutFebruary.image, januaryAndMarch.image), 0.5)
        // Mode filters combine per-mode pieces: cycling alone is February alone.
        let cycling = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
            database: split, plan: MapTileRangePlan(buckets: [202_401, 202_403], partial: [], includeUndated: false), loose: nil, modes: [.cycling])))
        let staysOnly = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
            database: split, plan: MapTileRangePlan(buckets: [202_401, 202_403], partial: [], includeUndated: false), loose: nil, modes: [])))
        XCTAssertEqual(meanAbsoluteDifference(cycling.image, staysOnly.image), 0, accuracy: 0.001,
                       "February was the only cycling month and it is gone: only stays remain")
        let walking = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
            database: split, plan: MapTileRangePlan(buckets: [202_401, 202_403], partial: [], includeUndated: false), loose: nil, modes: [.walking])))
        XCTAssertGreaterThan(alphaSum(walking.image), alphaSum(staysOnly.image))
    }

    func testTilesLookLikeTheIndexRenderer() throws {
        var generator = SeededGenerator(seed: 11)
        let values = syntheticValues(trips: 400, stays: 200, start: Date(timeIntervalSince1970: 1_700_000_000), seed: &generator,
                                     modes: [.walking, .automotive, .cycling])
        let database = try makeDatabase()
        let built = MapTileBuilder.build(month: 202_311, values: values, calendar: calendar)
        try database.commit([MapTileDatabase.MonthBuild(bucket: 202_311, signature: "s", summary: built.summary, tiles: built.tiles)])
        let subset = MapActivitySubset(
            tracks: values.tracks.map { MapActivityTrack(id: $0.id, start: $0.start, end: $0.end, mode: $0.mode,
                                                         chunks: MapActivityIndex.chunks(for: $0.points)) },
            stays: values.stays.map { MapActivityStay(point: $0.point, arrival: $0.arrival, departure: $0.departure) },
            undatedCoverage: []
        )
        for layer in MapCoverageLayer.allCases {
            for metersPerPoint in [3.0, 25, 400, 5_000] {
                let request = request(layer, metersPerPoint: metersPerPoint)
                let old = try XCTUnwrap(MapCoverageRenderer.render(subset, request: request))
                let new = try XCTUnwrap(MapTileCompositor.render(request, input: .init(
                    database: database, plan: MapTileRangePlan(buckets: [0], partial: [], includeUndated: false), loose: nil, modes: nil)))
                XCTAssertEqual(old.image.width, new.image.width)
                let difference = meanAbsoluteDifference(old.image, new.image)
                print("tile vs index \(layer) \(metersPerPoint) m/pt: mean channel difference \(String(format: "%.2f", difference)) of 255")
                XCTAssertLessThan(difference, layer == .routes ? 3 : 2, "\(layer) at \(metersPerPoint) m/pt")
            }
        }
    }

    // MARK: Building from the store

    func testSyncBuildsEveryMonthThenRebuildsOnlyTheOneThatChanged() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = self.calendar
        let now = date(2026, 3, 20, calendar: calendar)
        var moves: [MoveSegment] = []
        for month in 1...3 {
            let start = date(2026, month, 10, calendar: calendar)
            moves.append(insertTrip(context, start: start, latitude: 11.9 + Double(month) * 0.01))
            let stay = VisitPlace(arrivalDate: start.addingTimeInterval(-3_600), departureDate: start,
                                  latitude: 11.9, longitude: 108.4, horizontalAccuracy: 10)
            context.insert(stay)
            stay.dayTimeline = day(containing: stay.arrivalDate, in: context)
        }
        try context.save()
        let database = try makeDatabase()
        let first = try await MapTileBuilder.sync(container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        XCTAssertEqual(Set(first.rebuilt), [202_601, 202_602, 202_603])
        XCTAssertEqual(database.summaries().map(\.trips), [1, 1, 1])
        let again = try await MapTileBuilder.sync(container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        XCTAssertTrue(again.rebuilt.isEmpty, "Nothing changed, nothing rebuilt")

        // Edit February's trip: only February is rebuilt, and the all-time sum follows.
        moves[1].transportModeRawValue = TransportMode.cycling.rawValue
        try context.save()
        let edited = try await MapTileBuilder.sync(container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        XCTAssertEqual(edited.rebuilt, [202_602])
        let cyclingIndex = Int(MapTileTiler.modeIndex(.cycling))
        XCTAssertEqual(database.summaries().first { $0.bucket == 202_602 }?.tripsByMode[cyclingIndex], 1)
        let allTime = database.records(level: MapTileLevels.coarsestLevel, buckets: [0], x: 0...0, y: 0...0).compactMap { MapTileCodec.decode($0.data) }
        let modes = Set(allTime.flatMap(\.segmentModes))
        XCTAssertTrue(modes.contains(UInt8(cyclingIndex)))
        XCTAssertFalse(modes.contains(MapTileTiler.modeIndex(.walking)) && allTime.flatMap(\.segmentCounts).reduce(0, +) > 3)

        // New capture this month touches only this month.
        _ = insertTrip(context, start: date(2026, 3, 18, calendar: calendar), latitude: 11.99)
        try context.save()
        let captured = try await MapTileBuilder.sync(container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        XCTAssertEqual(captured.rebuilt, [202_603])
    }

    func testACancelledBuildResumesWhereItStopped() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = self.calendar
        let now = date(2026, 6, 20, calendar: calendar)
        for month in 1...6 {
            _ = insertTrip(context, start: date(2026, month, 5, calendar: calendar), latitude: 11.9 + Double(month) * 0.01)
        }
        try context.save()
        let database = try makeDatabase()
        // Cancel once two months have been committed.
        let task = Task {
            try await MapTileBuilder.sync(
                container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL(),
                policy: { _ in
                    if database.summaries().count >= 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return .run
                },
                batchSeconds: 0
            )
        }
        do {
            _ = try await task.value
            XCTFail("The build should have been cancelled")
        } catch is CancellationError {}
        let partial = database.summaries().map(\.bucket)
        XCTAssertGreaterThanOrEqual(partial.count, 2)
        XCTAssertLessThan(partial.count, 6)
        XCTAssertEqual(Set(partial), Set([202_606, 202_605, 202_604, 202_603].prefix(partial.count)), "Newest months first")

        let resumed = try await MapTileBuilder.sync(container: container, database: database, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        XCTAssertEqual(Set(resumed.rebuilt), Set((1...6).map { 202_600 + $0 }).subtracting(partial))
        // Resumed equals a build that never stopped.
        let fresh = try makeDatabase()
        _ = try await MapTileBuilder.sync(container: container, database: fresh, calendar: calendar, now: now, undatedCoverageURL: missingURL())
        let request = request(.routes, metersPerPoint: 20)
        let plan = MapTileRangePlan(buckets: [0], partial: [], includeUndated: false)
        let a = try XCTUnwrap(MapTileCompositor.render(request, input: .init(database: database, plan: plan, loose: nil, modes: nil)))
        let b = try XCTUnwrap(MapTileCompositor.render(request, input: .init(database: fresh, plan: plan, loose: nil, modes: nil)))
        XCTAssertEqual(meanAbsoluteDifference(a.image, b.image), 0, accuracy: 0.01)
        XCTAssertGreaterThan(alphaSum(a.image), 0)
    }

    func testTheBuilderKeepsTheMapRules() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = self.calendar
        let start = date(2026, 2, 3, calendar: calendar)
        // A trip whose fixes include a 1.2 km-off fix and a photo point.
        let move = MoveSegment(dedupeKey: "m", startDate: start, endDate: start.addingTimeInterval(900),
                               transportMode: .walking, distanceMeters: 800, stepCount: nil)
        context.insert(move)
        move.dayTimeline = day(containing: start, in: context)
        let fixes: [(Double, Double, Double, LocationSampleSource)] = [
            (11.940, 108.440, 8, .significantChange), (12.050, 108.600, 1_200, .significantChange),
            (11.990, 108.300, 10, .photoLibrary), (11.944, 108.444, 10, .significantChange)
        ]
        for (offset, fix) in fixes.enumerated() {
            let sample = LocationSample(
                location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: fix.0, longitude: fix.1), altitude: 0,
                                     horizontalAccuracy: fix.2, verticalAccuracy: -1, course: -1, speed: 1,
                                     timestamp: start.addingTimeInterval(Double(offset) * 60)),
                source: fix.3, dedupeKey: "s\(offset)")
            sample.moveSegment = move
            context.insert(sample)
        }
        // Two days with nothing recorded between photos: not a trip.
        let gap = MoveSegment(dedupeKey: "gap", startDate: start.addingTimeInterval(3_600), endDate: start.addingTimeInterval(2 * 86_400),
                              transportMode: .automotive, distanceMeters: 300, stepCount: nil)
        context.insert(gap)
        gap.dayTimeline = day(containing: gap.startDate, in: context)
        try context.save()
        let values = try MapTileSource.values(in: MapTileBucket.interval(ofMonth: 202_602, calendar: calendar), container: container)
        XCTAssertEqual(values.tracks.count, 1)
        XCTAssertEqual(values.excludedTrips, 1)
        let coordinates = try XCTUnwrap(values.tracks.first).points.map(\.coordinate)
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertFalse(coordinates.contains { abs($0.latitude - 12.05) < 1e-6 || abs($0.latitude - 11.99) < 1e-6 })
        XCTAssertEqual(values.spans.count, 2, "The scrubber still counts every move")
    }

    // MARK: Cache versioning

    func testAPyramidForAnotherStoreOrFormatIsWiped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        var database: MapTileDatabase? = try MapTileDatabase(url: url, storeIdentity: "store-a")
        try database?.commit([MapTileDatabase.MonthBuild(bucket: 202_401, signature: "x", summary: MapMonthSummary(bucket: 202_401), tiles: [:])])
        database = nil
        XCTAssertEqual(try MapTileDatabase(url: url, storeIdentity: "store-a").monthSignatures(), [202_401: "x"])
        XCTAssertTrue(try MapTileDatabase(url: url, storeIdentity: "store-b").monthSignatures().isEmpty, "Another store starts over")
        let reopened = try MapTileDatabase(url: url, storeIdentity: "store-b")
        try reopened.commit([MapTileDatabase.MonthBuild(bucket: 202_401, signature: "y", summary: MapMonthSummary(bucket: 202_401), tiles: [:])])
        try reopened.setMeta("format", "0")
        XCTAssertTrue(try MapTileDatabase(url: url, storeIdentity: "store-b").monthSignatures().isEmpty, "An old format starts over")
    }

    // MARK: Tapping

    func testTappingFindsTheNearestTripAndTheNewestOnASharedRoad() throws {
        let base = MercatorPoint(center)
        func line(_ dy: Double, _ start: Double, _ mode: TransportMode = .walking) -> MapTileTrack {
            MapTileTrack(id: UUID(), start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 600), mode: mode,
                         distanceMeters: 500, points: (0...20).map { MercatorPoint(x: base.x + Double($0) * 200, y: base.y + dy) })
        }
        let old = line(0, 1_000), new = line(0, 9_000), other = line(3_000, 5_000, .cycling)
        let database = try makeDatabase()
        let values = MapTileSourceValues(tracks: [old, new, other])
        let built = MapTileBuilder.build(month: 202_405, values: values, calendar: calendar)
        try database.commit([MapTileDatabase.MonthBuild(bucket: 202_405, signature: "s", summary: built.summary, tiles: built.tiles)])
        let input = MapTileCompositor.Input(database: database, plan: MapTileRangePlan(buckets: [0], partial: [], includeUndated: false), loose: nil, modes: nil)
        let tap = MercatorPoint(x: base.x + 1_000, y: base.y + 300)
        XCTAssertEqual(MapTileCompositor.trip(near: tap, tolerance: 600, mapPointsPerPoint: 30, input: input), new.id)
        XCTAssertEqual(MapTileCompositor.trip(near: MercatorPoint(x: base.x + 1_000, y: base.y + 2_800), tolerance: 600, mapPointsPerPoint: 30, input: input), other.id)
        XCTAssertNil(MapTileCompositor.trip(near: MercatorPoint(x: base.x + 1_000, y: base.y + 1_500), tolerance: 600, mapPointsPerPoint: 30, input: input))
        var walkingOnly = input
        walkingOnly.modes = [.walking]
        XCTAssertNil(MapTileCompositor.trip(near: MercatorPoint(x: base.x + 1_000, y: base.y + 2_800), tolerance: 600, mapPointsPerPoint: 30, input: walkingOnly))
        // A range without May finds nothing.
        var june = input
        june.plan = MapTileRangePlan(buckets: [202_406], partial: [], includeUndated: false)
        XCTAssertNil(MapTileCompositor.trip(near: tap, tolerance: 600, mapPointsPerPoint: 30, input: june))
    }

    // MARK: Throttling

    func testTheBuilderWaitsWhenThePhoneIsHotOrSavingPower() {
        let rule = MapTileBuildPolicy.decision
        XCTAssertEqual(rule(.nominal, false, false), .run)
        XCTAssertEqual(rule(.fair, false, false), .run)
        XCTAssertEqual(rule(.serious, false, false), .pause)
        XCTAssertEqual(rule(.serious, false, true), .run, "This month still updates")
        XCTAssertEqual(rule(.critical, false, true), .pause)
        XCTAssertEqual(rule(.nominal, true, false), .pause)
        XCTAssertEqual(rule(.nominal, true, true), .run)
    }

    // MARK: Scale

    func testTenYearsOfHistoryDrawsFromTilesInMilliseconds() throws {
        // The renderer's stress case: 20,000 trips of 25 points and 30,000 stays over ten years,
        // across three cities.
        var generator = SeededGenerator(seed: 3)
        let cities = [center, CLLocationCoordinate2D(latitude: 10.78, longitude: 106.70), CLLocationCoordinate2D(latitude: 13.75, longitude: 100.50)]
        let decade = 10 * 365 * 86_400.0
        let spread = 0.2 / 360 * MKMapSize.world.width
        let base = 1_500_000_000.0
        var byMonth: [Int: MapTileSourceValues] = [:]
        for number in 0..<20_000 {
            let city = MercatorPoint(cities[number % cities.count])
            var x = city.x + Double.random(in: -spread...spread, using: &generator)
            var y = city.y + Double.random(in: -spread...spread, using: &generator)
            let points = (0..<25).map { _ -> MercatorPoint in
                x += Double.random(in: -spread / 30...spread / 30, using: &generator)
                y += Double.random(in: -spread / 30...spread / 30, using: &generator)
                return MercatorPoint(x: x, y: y)
            }
            let start = Date(timeIntervalSince1970: base + Double(number) / 20_000 * decade)
            byMonth[MapTileBucket.month(containing: start, calendar: calendar), default: MapTileSourceValues()].tracks.append(
                MapTileTrack(id: UUID(), start: start, end: start.addingTimeInterval(1_800), mode: number % 2 == 0 ? .walking : .automotive,
                             distanceMeters: 3_000, points: points))
        }
        for number in 0..<30_000 {
            let city = MercatorPoint(cities[number % cities.count])
            let arrival = Date(timeIntervalSince1970: base + Double(number) / 30_000 * decade)
            byMonth[MapTileBucket.month(containing: arrival, calendar: calendar), default: MapTileSourceValues()].stays.append(
                MapTileStay(point: MercatorPoint(x: city.x + Double.random(in: -spread...spread, using: &generator),
                                                 y: city.y + Double.random(in: -spread...spread, using: &generator)),
                            arrival: arrival, departure: arrival.addingTimeInterval(3_600)))
        }
        let database = try makeDatabase()
        var started = Date()
        var firstMonth: TimeInterval?
        var batch: [MapTileDatabase.MonthBuild] = []
        for month in byMonth.keys.sorted(by: >) {
            let built = MapTileBuilder.build(month: month, values: byMonth[month]!, calendar: calendar)
            batch.append(MapTileDatabase.MonthBuild(bucket: month, signature: "s", summary: built.summary, tiles: built.tiles))
            if firstMonth == nil || batch.count >= 6 {
                try database.commit(batch)
                batch.removeAll()
                if firstMonth == nil { firstMonth = Date().timeIntervalSince(started) }
            }
        }
        try database.commit(batch)
        database.checkpoint()
        let buildTime = Date().timeIntervalSince(started)
        print("stress tiles: build \(Int(buildTime * 1_000)) ms (newest month on disk after \(Int((firstMonth ?? 0) * 1_000)) ms), \(database.recordCount()) records, \(database.sizeOnDisk() / 1_024) KB on disk")

        let reader = try MapTileDatabase(url: database.url, storeIdentity: "test")
        let allTime = MapTileRangePlan(buckets: [0], partial: [], includeUndated: false)
        let year = MapTileRangePlan.make(interval: DateInterval(start: date(2021, 1, 1, calendar: calendar), end: date(2022, 1, 1, calendar: calendar)),
                                         isAllTime: false, includeUndated: false, now: .now, calendar: calendar)
        let months = MapTileRangePlan.make(interval: DateInterval(start: date(2020, 2, 1, calendar: calendar), end: date(2021, 9, 1, calendar: calendar)),
                                           isAllTime: false, includeUndated: false, now: .now, calendar: calendar)
        for (name, plan) in [("all time", allTime), ("a year", year), ("19 months", months)] {
            for metersPerPoint in [2.0, 30, 800, 20_000] {
                for layer in MapCoverageLayer.allCases {
                    // Twice: the first read warms SQLite's page cache, as a pan does.
                    var elapsed = 0.0
                    for _ in 0..<2 {
                        started = Date()
                        let raster = try MapTileCompositor.render(request(layer, metersPerPoint: metersPerPoint),
                                                                  input: .init(database: reader, plan: plan, loose: nil, modes: nil))
                        elapsed = Date().timeIntervalSince(started)
                        XCTAssertNotNil(raster)
                    }
                    print("stress tile render \(name) \(layer) \(metersPerPoint) m/pt: \(String(format: "%.1f", elapsed * 1_000)) ms")
                    // Heat is bounded by pixels. Routes and Fog stroke distinct pieces, and this
                    // case is 20,000 non-repeating random walks, so at city zoom they stay above
                    // the 30 ms target (about 0.1–0.3 s optimised); they must still beat the
                    // index path's 1–2 s by a wide margin.
                    XCTAssertLessThan(elapsed, layer == .heat ? 0.25 : 1.5, "\(name) \(layer) at \(metersPerPoint) m/pt took \(elapsed) s")
                }
            }
        }
        // The scrubber reads summaries, not tiles.
        XCTAssertEqual(reader.summaries().reduce(0) { $0 + $1.trips }, 20_000)
    }

    // MARK: Real history

    /// Runs only with `TEST_RUNNER_MOVES_TILE_STORE=<copy of default.store>` (and optionally
    /// `TEST_RUNNER_MOVES_TILE_OUTPUT=<folder>` for side-by-side PNGs). Times the index path against
    /// the tiles on real history and compares their pixels. Prints timings only, never places.
    func testRealHistoryDrawsTheSameFromTilesAndFaster() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MOVES_TILE_STORE"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set TEST_RUNNER_MOVES_TILE_STORE to a copy of a real store")
        }
        let output = environment["MOVES_TILE_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let storeURL = URL(fileURLWithPath: path)
        let container = try ModelContainer(
            for: Schema(MovesTimelineSchema.models),
            configurations: [ModelConfiguration(schema: Schema(MovesTimelineSchema.models), url: storeURL, cloudKitDatabase: .none)]
        )
        var started = Date()
        let index = try MapActivityIndexBuilder.build(container: container, undatedCoverageURL: missingURL())
        print("real index build: \(Int(Date().timeIntervalSince(started) * 1_000)) ms, \(index.tracks.count) trips, \(index.stays.count) stays, \(index.pointCount) points")
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("real-index-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try MapActivityIndexCache.save(index, signature: "real", to: cacheURL)
        started = Date()
        _ = MapActivityIndexCache.load(from: cacheURL)
        print("real index read from cache: \(Int(Date().timeIntervalSince(started) * 1_000)) ms")

        let database = try makeDatabase()
        started = Date()
        let firstCommit = FirstCommit()
        let result = try await MapTileBuilder.sync(container: container, database: database, undatedCoverageURL: missingURL(),
                                                   onCommit: { _ in await firstCommit.mark() })
        let firstMs = await firstCommit.milliseconds(since: started)
        print("real tile build: \(Int(Date().timeIntervalSince(started) * 1_000)) ms for \(result.rebuilt.count) months (newest month on disk after \(firstMs) ms), \(database.recordCount()) records, \(database.sizeOnDisk() / 1_024) KB on disk")
        started = Date()
        let again = try await MapTileBuilder.sync(container: container, database: database, undatedCoverageURL: missingURL())
        print("real tile sync with nothing changed: \(Int(Date().timeIntervalSince(started) * 1_000)) ms, \(again.rebuilt.count) rebuilt")

        let subset = index.subset(interval: DateInterval(start: .distantPast, end: .distantFuture), modes: nil, includeUndated: false)
        let focus = try XCTUnwrap(index.latestActivity)
        let plan = MapTileRangePlan(buckets: [0], partial: [], includeUndated: false)
        for metersPerPoint in [2.0, 10, 40, 200, 1_000, 8_000] {
            for layer in MapCoverageLayer.allCases {
                for isDark in [false, true] where isDark == false || metersPerPoint == 40 {
                    var request = request(layer, metersPerPoint: metersPerPoint, around: focus)
                    request.isDark = isDark
                    started = Date()
                    let old = try XCTUnwrap(MapCoverageRenderer.render(subset, request: request))
                    let oldMs = Date().timeIntervalSince(started) * 1_000
                    var newMs = 0.0
                    var new: MapCoverageRaster?
                    for _ in 0..<2 {
                        started = Date()
                        new = try MapTileCompositor.render(request, input: .init(database: database, plan: plan, loose: nil, modes: nil))
                        newMs = Date().timeIntervalSince(started) * 1_000
                    }
                    let tiles = try XCTUnwrap(new)
                    let difference = meanAbsoluteDifference(old.image, tiles.image)
                    let changed = changedPixelShare(old.image, tiles.image)
                    print("real \(layer) \(Int(metersPerPoint)) m/pt\(isDark ? " dark" : ""): index \(String(format: "%.1f", oldMs)) ms, tiles \(String(format: "%.1f", newMs)) ms, mean difference \(String(format: "%.2f", difference))/255, pixels off by >24: \(String(format: "%.2f", changed * 100))%")
                    if let output {
                        let name = "\(layer)-\(Int(metersPerPoint))\(isDark ? "-dark" : "")"
                        try png(old.image).write(to: output.appendingPathComponent("\(name)-index.png"))
                        try png(tiles.image).write(to: output.appendingPathComponent("\(name)-tiles.png"))
                    }
                }
            }
        }
    }

    private actor FirstCommit {
        var at: Date?
        func mark() { if at == nil { at = Date() } }
        func milliseconds(since start: Date) -> Int { Int(((at ?? Date()).timeIntervalSince(start)) * 1_000) }
    }

    private func request(_ layer: MapCoverageLayer, metersPerPoint: Double, around coordinate: CLLocationCoordinate2D) -> MapCoverageRenderRequest {
        let mapPointsPerPoint = metersPerPoint / MKMetersPerMapPointAtLatitude(coordinate.latitude)
        let middle = MercatorPoint(coordinate)
        let width = Double(viewSize.width) * mapPointsPerPoint, height = Double(viewSize.height) * mapPointsPerPoint
        return MapCoverageRenderRequest(
            layer: layer,
            viewport: MercatorRect(minX: middle.x - width / 2, minY: middle.y - height / 2, maxX: middle.x + width / 2, maxY: middle.y + height / 2),
            viewSize: viewSize,
            isDark: false
        )
    }

    private func changedPixelShare(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let x = rgba(a), y = rgba(b)
        var changed = 0
        for pixel in stride(from: 0, to: min(x.count, y.count), by: 4) {
            if (0..<4).contains(where: { abs(Int(x[pixel + $0]) - Int(y[pixel + $0])) > 24 }) { changed += 1 }
        }
        return Double(changed) / Double(max(x.count / 4, 1))
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Helpers

    private func makeDatabase() throws -> MapTileDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString).sqlite")
        addTeardownBlock { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        return try MapTileDatabase(url: url, storeIdentity: "test")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func missingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("no-coverage-\(UUID().uuidString).json")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @discardableResult
    private func insertTrip(_ context: ModelContext, start: Date, latitude: Double) -> MoveSegment {
        let move = MoveSegment(dedupeKey: UUID().uuidString, startDate: start, endDate: start.addingTimeInterval(1_200),
                               transportMode: .walking, distanceMeters: 1_500, stepCount: nil)
        context.insert(move)
        move.dayTimeline = day(containing: start, in: context)
        for step in 0..<6 {
            let sample = LocationSample(
                location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude + Double(step) * 0.002, longitude: 108.44),
                                     altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, course: -1, speed: 1,
                                     timestamp: start.addingTimeInterval(Double(step) * 200)),
                source: .significantChange, dedupeKey: UUID().uuidString)
            sample.moveSegment = move
            context.insert(sample)
        }
        return move
    }

    /// A live stay or trip is always on a day; reuse the one already inserted for this date.
    private func day(containing date: Date, in context: ModelContext) -> DayTimeline {
        let key = DayTimeline.makeDayKey(for: date)
        if let existing = try? context.fetch(FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })).first {
            return existing
        }
        let day = DayTimeline(dayStart: date)
        context.insert(day)
        return day
    }

    private func syntheticValues(trips: Int, stays: Int, start: Date, seed generator: inout SeededGenerator, modes: [TransportMode]) -> MapTileSourceValues {
        let middle = MercatorPoint(center)
        let spread = 0.05 / 360 * MKMapSize.world.width
        var values = MapTileSourceValues()
        for number in 0..<trips {
            var x = middle.x + Double.random(in: -spread...spread, using: &generator)
            var y = middle.y + Double.random(in: -spread...spread, using: &generator)
            let points = (0..<40).map { _ -> MercatorPoint in
                x += Double.random(in: -spread / 50...spread / 50, using: &generator)
                y += Double.random(in: -spread / 50...spread / 50, using: &generator)
                return MercatorPoint(x: x, y: y)
            }
            let tripStart = start.addingTimeInterval(Double(number) * 3_000)
            values.tracks.append(MapTileTrack(id: UUID(), start: tripStart, end: tripStart.addingTimeInterval(1_200),
                                              mode: modes[number % modes.count], distanceMeters: 2_000, points: points))
        }
        for number in 0..<stays {
            let arrival = start.addingTimeInterval(Double(number) * 5_000)
            values.stays.append(MapTileStay(point: MercatorPoint(x: middle.x + Double.random(in: -spread...spread, using: &generator),
                                                                 y: middle.y + Double.random(in: -spread...spread, using: &generator)),
                                            arrival: arrival, departure: arrival.addingTimeInterval(Double(number % 9) * 3_600)))
        }
        return values
    }

    private func request(_ layer: MapCoverageLayer, metersPerPoint: Double) -> MapCoverageRenderRequest {
        let mapPointsPerPoint = metersPerPoint / MKMetersPerMapPointAtLatitude(center.latitude)
        let middle = MercatorPoint(center)
        let width = Double(viewSize.width) * mapPointsPerPoint, height = Double(viewSize.height) * mapPointsPerPoint
        return MapCoverageRenderRequest(
            layer: layer,
            viewport: MercatorRect(minX: middle.x - width / 2, minY: middle.y - height / 2, maxX: middle.x + width / 2, maxY: middle.y + height / 2),
            viewSize: viewSize,
            isDark: false
        )
    }

    /// Mean absolute difference per channel, 0–255.
    private func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let x = rgba(a), y = rgba(b)
        var total = 0.0
        for index in 0..<min(x.count, y.count) { total += abs(Double(x[index]) - Double(y[index])) }
        return total / Double(max(x.count, 1))
    }

    private func alphaSum(_ image: CGImage) -> Int {
        let bytes = rgba(image)
        return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}

/// Reproducible randomness, so a failing comparison fails the same way twice.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
