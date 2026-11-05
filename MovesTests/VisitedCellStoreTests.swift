import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class VisitedCellStoreTests: XCTestCase {
    func testCellKeyUsesThousandthDegreeBuckets() {
        let key = VisitedCellStore.cellKey(latitude: 37.7749, longitude: -122.4194)
        XCTAssertEqual(key, "37774|-122420")

        let sameCell = VisitedCellStore.cellKey(latitude: 37.77491, longitude: -122.41941)
        XCTAssertEqual(key, sameCell)

        let north = VisitedCellStore.cellKey(latitude: 37.7760, longitude: -122.4194)
        XCTAssertNotEqual(key, north)
    }

    func testSydneyNegativeLatitudeUsesFloorNotTruncation() {
        let quay = VisitedCellStore.cellIndices(latitude: -33.8611, longitude: 151.2109)
        XCTAssertEqual(quay.lat, Int(floor(-33.8611 * 1_000)))
        XCTAssertEqual(quay.lon, Int(floor(151.2109 * 1_000)))

        let nearby = VisitedCellStore.cellIndices(latitude: -33.86119, longitude: 151.2109)
        XCTAssertEqual(nearby.lat, quay.lat)
        let nextCell = VisitedCellStore.cellIndices(latitude: -33.8621, longitude: 151.2109)
        XCTAssertLessThan(nextCell.lat, quay.lat)
    }

    func testFloorDivAlignsSouthernHemisphereThreeByThreeBuckets() {
        XCTAssertEqual(VisitedCellStore.floorDiv(5, by: 3), 1)
        XCTAssertEqual(VisitedCellStore.floorDiv(-1, by: 3), -1)
        XCTAssertEqual(VisitedCellStore.floorDiv(-3, by: 3), -1)
        XCTAssertEqual(VisitedCellStore.floorDiv(-33864, by: 3) * 3, -33864)
        let a = VisitedCellStore.floorDiv(-33864, by: 3) * 3
        let b = VisitedCellStore.floorDiv(-33863, by: 3) * 3
        let c = VisitedCellStore.floorDiv(-33862, by: 3) * 3
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertNotEqual(a, VisitedCellStore.floorDiv(-33861, by: 3) * 3)
    }

    func testRecordIncrementsSampleCountForTheSameCell() throws {
        let (context, _) = try makeContext()
        let first = sample(latitude: -33.8611, longitude: 151.2109, at: date(10, 0))
        let second = sample(latitude: -33.86115, longitude: 151.21092, at: date(10, 5))
        context.insert(first)
        context.insert(second)

        try VisitedCellStore.record([first, second], in: context)

        let cells = try context.fetch(FetchDescriptor<VisitedCell>())
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].sampleCount, 2)
        XCTAssertEqual(cells[0].firstVisitedAt, date(10, 0))
        XCTAssertEqual(cells[0].lastVisitedAt, date(10, 5))
    }

    func testRebuildReplacesStaleCellsFromSamples() throws {
        let (context, _) = try makeContext()
        context.insert(VisitedCell(cellKey: "0|0", visitedAt: date(8, 0), sampleCount: 99))
        let sample = sample(latitude: 40.758, longitude: -73.9855, at: date(11, 0))
        context.insert(sample)
        try context.save()

        try VisitedCellStore.rebuild(in: context)

        let cells = try context.fetch(FetchDescriptor<VisitedCell>())
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].cellKey, VisitedCellStore.cellKey(latitude: 40.758, longitude: -73.9855))
        XCTAssertEqual(cells[0].sampleCount, 1)
    }

    func testEnsureBuiltBackfillsHistoryOnceEvenWithACellAlreadyCaptured() throws {
        let (context, _) = try makeContext()
        let suiteName = "VisitedCellStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An upgraded install: months of samples, and capture got one in before the first Map open.
        let history = sample(latitude: 40.758, longitude: -73.9855, at: date(8, 0))
        let captured = sample(latitude: 52.52, longitude: 13.405, at: date(9, 0))
        context.insert(history)
        context.insert(captured)
        try context.save()
        try VisitedCellStore.record([captured], in: context)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitedCell>()), 1)

        try VisitedCellStore.ensureBuilt(in: context, defaults: defaults)

        let cells = try context.fetch(FetchDescriptor<VisitedCell>())
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells.map(\.sampleCount), [1, 1])

        // It only needs doing once. Later samples arrive through `appendSamples`.
        context.insert(sample(latitude: -33.8611, longitude: 151.2109, at: date(10, 0)))
        try context.save()
        try VisitedCellStore.ensureBuilt(in: context, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitedCell>()), 2)
    }

    func testEnsureBuiltStillFillsAnEmptyCacheAfterTheOneTimeBackfill() throws {
        let (context, _) = try makeContext()
        let suiteName = "VisitedCellStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(VisitedCellStore.builtVersion, forKey: VisitedCellStore.builtVersionKey)

        context.insert(sample(latitude: 40.758, longitude: -73.9855, at: date(8, 0)))
        try context.save()

        try VisitedCellStore.ensureBuilt(in: context, defaults: defaults)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitedCell>()), 1)
    }

    func testRebuildReadsEveryPageOfSamples() throws {
        let (context, _) = try makeContext()
        for index in 0..<5_100 {
            context.insert(sample(latitude: 40.758, longitude: -73.9855, at: date(8, 0).addingTimeInterval(Double(index))))
        }
        try context.save()

        try VisitedCellStore.rebuild(in: context)

        let cells = try context.fetch(FetchDescriptor<VisitedCell>())
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?.sampleCount, 5_100)
    }

    func testCityZoomAggregatesThreeByThreeWhileStreetZoomStaysNative() throws {
        let (context, _) = try makeContext()
        let originLat = -33_861
        let originLon = 151_209
        var samples: [LocationSample] = []
        for latOffset in 0..<3 {
            for lonOffset in 0..<3 {
                let sample = sample(
                    latitude: (Double(originLat + latOffset) + 0.5) * 0.001,
                    longitude: (Double(originLon + lonOffset) + 0.5) * 0.001,
                    at: date(12, latOffset * 3 + lonOffset)
                )
                context.insert(sample)
                samples.append(sample)
            }
        }
        try VisitedCellStore.record(samples, in: context)
        let stored = try VisitedCellStore.fetchAll(in: context)
        XCTAssertEqual(stored.count, 9)

        let street = VisitedCellStore.displayCells(
            from: stored,
            latitudeSpan: 0.01
        )
        XCTAssertEqual(street.count, 9)
        XCTAssertEqual(street.first?.factor, 1)

        let city = VisitedCellStore.displayCells(
            from: stored,
            latitudeSpan: 0.08
        )
        XCTAssertEqual(city.count, 1)
        XCTAssertEqual(city.first?.factor, 3)
        XCTAssertEqual(city.first?.sampleCount, 9)
    }

    func testAppendSamplesHookWritesVisitedCells() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            course: -1,
            speed: 1.2,
            timestamp: date(9, 0)
        )

        _ = try repository.appendSamples(from: [location], source: .significantChange)

        let cells = try context.fetch(FetchDescriptor<VisitedCell>())
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].cellKey, VisitedCellStore.cellKey(latitude: 52.52, longitude: 13.405))
    }

    private func makeContext() throws -> (ModelContext, ModelContainer) {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return (context, container)
    }

    private func sample(latitude: Double, longitude: Double, at timestamp: Date) -> LocationSample {
        LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: -1,
                course: -1,
                speed: 1,
                timestamp: timestamp
            ),
            source: .significantChange,
            dedupeKey: UUID().uuidString
        )
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: hour, minute: minute))!
    }
}
