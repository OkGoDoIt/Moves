import CoreLocation
import Foundation
import MapKit
import SwiftData

/// Incremental cache of ~100 m visited cells (`0.001°`) for the Map tab’s
/// heat and adaptive fog layers.
enum VisitedCellStore {
    /// Street-level cell size in degrees (~100 m at mid latitudes).
    static let cellSizeDegrees = 0.001
    /// City-zoom aggregation: 3×3 native cells ≈ 250 m.
    static let cityAggregationFactor = 3
    /// Latitude span at which we switch from 100 m cells to 3×3 neighbourhoods.
    static let cityZoomLatitudeDelta = 0.025
    /// Cap on overlay primitives so a country-scale fog stays cheap.
    static let maximumDisplayCells = 2_400
    /// Raise to rebuild once more from existing history on the next Heat or Fog view.
    static let builtVersion = 1
    static let builtVersionKey = "moves.visitedCells.builtVersion"
    private static let rebuildPageSize = 5_000

    @MainActor private static var buildTask: Task<Void, Error>?

    private typealias CellTally = (first: Date, last: Date, count: Int)

    /// A raster cell after optional 3×3 (or coarser) aggregation.
    struct DisplayCell: Identifiable, Hashable, Sendable {
        let latIndex: Int
        let lonIndex: Int
        let factor: Int
        let sampleCount: Int
        let firstVisitedAt: Date
        let lastVisitedAt: Date

        var id: String { "\(latIndex)|\(lonIndex)|\(factor)" }

        var sizeDegrees: Double {
            cellSizeDegrees * Double(factor)
        }

        var origin: CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: Double(latIndex) * cellSizeDegrees,
                longitude: Double(lonIndex) * cellSizeDegrees
            )
        }

        var center: CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: origin.latitude + sizeDegrees / 2,
                longitude: origin.longitude + sizeDegrees / 2
            )
        }
    }

    /// `"latIndex|lonIndex"` at `cellSizeDegrees` resolution.
    static func cellKey(latitude: Double, longitude: Double) -> String {
        let indices = cellIndices(latitude: latitude, longitude: longitude)
        return "\(indices.lat)|\(indices.lon)"
    }

    static func cellIndices(latitude: Double, longitude: Double) -> (lat: Int, lon: Int) {
        (
            lat: Int(floor(latitude * 1_000)),
            lon: Int(floor(longitude * 1_000))
        )
    }

    static func indices(from key: String) -> (lat: Int, lon: Int)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2, let lat = Int(parts[0]), let lon = Int(parts[1]) else {
            return nil
        }
        return (lat, lon)
    }

    /// Integer division toward −∞. Needed so southern-hemisphere 3×3 buckets align.
    static func floorDiv(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        let (q, r) = value.quotientAndRemainder(dividingBy: divisor)
        if r != 0 && value < 0 {
            return q - 1
        }
        return q
    }

    /// Best-effort hook from `appendSamples`. Failures never fail capture.
    static func ingest(_ samples: [LocationSample], in context: ModelContext) {
        guard !samples.isEmpty else { return }
        do {
            try record(samples, in: context)
        } catch {
            // Fog / heat is a derived cache; the timeline write already succeeded.
        }
    }

    /// Upserts cells for the given samples. `sampleCount` grows by unique inserts.
    static func record(_ samples: [LocationSample], in context: ModelContext) throws {
        guard !samples.isEmpty else { return }

        var pending: [String: CellTally] = [:]
        pending.reserveCapacity(samples.count)
        tally(samples, into: &pending)

        for (key, delta) in pending {
            if let cell = try fetchCell(key: key, in: context) {
                cell.firstVisitedAt = min(cell.firstVisitedAt, delta.first)
                cell.lastVisitedAt = max(cell.lastVisitedAt, delta.last)
                cell.sampleCount += delta.count
            } else {
                let cell = VisitedCell(cellKey: key, visitedAt: delta.first, sampleCount: delta.count)
                cell.lastVisitedAt = delta.last
                context.insert(cell)
            }
        }
    }

    private static func tally(_ samples: [LocationSample], into pending: inout [String: CellTally]) {
        for sample in samples {
            let key = cellKey(latitude: sample.latitude, longitude: sample.longitude)
            if let existing = pending[key] {
                pending[key] = (
                    min(existing.first, sample.timestamp),
                    max(existing.last, sample.timestamp),
                    existing.count + 1
                )
            } else {
                pending[key] = (sample.timestamp, sample.timestamp, 1)
            }
        }
    }

    /// Makes the cells match `LocationSample`, reading a page of samples at a time. Used when the
    /// cache is empty (the demo seeder inserts samples without going through `appendSamples`) and
    /// once for history recorded before cells existed. Imports go through `appendSamples`, so they
    /// keep the cells current without a rebuild.
    ///
    /// Updates cells in place and deletes only the ones with no samples behind them, so capture
    /// can keep writing to a cell on another context while this runs.
    static func rebuild(in context: ModelContext) throws {
        if context.hasChanges {
            try context.save()
        }

        var pending: [String: CellTally] = [:]
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<LocationSample>()
            descriptor.includePendingChanges = false
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = rebuildPageSize
            let pageCount = try autoreleasepool { () throws -> Int in
                let page = try context.fetch(descriptor)
                tally(page, into: &pending)
                return page.count
            }
            offset += pageCount
            if pageCount < rebuildPageSize { break }
        }

        var existing: [String: VisitedCell] = [:]
        for cell in try context.fetch(FetchDescriptor<VisitedCell>()) {
            if existing[cell.cellKey] == nil {
                existing[cell.cellKey] = cell
            } else {
                context.delete(cell)
            }
        }
        for (key, delta) in pending {
            if let cell = existing.removeValue(forKey: key) {
                cell.firstVisitedAt = delta.first
                cell.lastVisitedAt = delta.last
                cell.sampleCount = delta.count
            } else {
                let cell = VisitedCell(cellKey: key, visitedAt: delta.first, sampleCount: delta.count)
                cell.lastVisitedAt = delta.last
                context.insert(cell)
            }
        }
        for cell in existing.values {
            context.delete(cell)
        }

        if context.hasChanges {
            try context.save()
        }
    }

    /// Rebuilds when the cache is empty, and once per `builtVersion` regardless of how many cells
    /// it holds: capture can ingest a sample before the first Map open on an upgraded install,
    /// and a cell count of one says nothing about the months of history behind it.
    static func ensureBuilt(in context: ModelContext, defaults: UserDefaults = .standard) throws {
        let count = try context.fetchCount(FetchDescriptor<VisitedCell>())
        if count == 0 || defaults.integer(forKey: builtVersionKey) < builtVersion {
            try rebuild(in: context)
            defaults.set(builtVersion, forKey: builtVersionKey)
        }
    }

    /// `ensureBuilt` on its own context off the main thread, one build at a time.
    @MainActor
    static func ensureBuilt(container: ModelContainer, defaults: UserDefaults = .standard) async throws {
        if let buildTask {
            try await buildTask.value
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            await TimelineSchemaUpgrader.waitUntilFinished()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            try ensureBuilt(in: context, defaults: defaults)
        }
        buildTask = task
        defer { buildTask = nil }
        try await task.value
    }

    /// Adaptive display set: native 100 m at street zoom, 3×3 (~250 m) at city zoom,
    /// and coarser 3ⁿ packing if the visible set would exceed `maximumDisplayCells`.
    static func displayCells(
        from cells: [VisitedCell],
        latitudeSpan: CLLocationDegrees,
        region: MKCoordinateRegion? = nil,
        overlapping interval: DateInterval? = nil
    ) -> [DisplayCell] {
        let padded = region.map(indexBounds(for:))
        var native: [(lat: Int, lon: Int, cell: VisitedCell)] = []
        native.reserveCapacity(cells.count)
        for cell in cells {
            if let interval, !overlaps(cell, interval: interval) { continue }
            guard let indices = indices(from: cell.cellKey) else { continue }
            if let padded, !contains(padded, indices: indices) { continue }
            native.append((indices.lat, indices.lon, cell))
        }

        var factor = latitudeSpan >= cityZoomLatitudeDelta ? cityAggregationFactor : 1
        while factor < 243 {
            let estimated = estimatedCount(native, factor: factor)
            if estimated <= maximumDisplayCells { break }
            factor *= cityAggregationFactor
        }
        return aggregate(native, factor: factor)
    }

    static func fetchAll(in context: ModelContext) throws -> [VisitedCell] {
        try context.fetch(FetchDescriptor<VisitedCell>())
    }

    private static func fetchCell(key: String, in context: ModelContext) throws -> VisitedCell? {
        var descriptor = FetchDescriptor<VisitedCell>(
            predicate: #Predicate { $0.cellKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func overlaps(_ cell: VisitedCell, interval: DateInterval) -> Bool {
        cell.firstVisitedAt < interval.end && cell.lastVisitedAt >= interval.start
    }

    private static func indexBounds(
        for region: MKCoordinateRegion
    ) -> (minLat: Int, maxLat: Int, minLon: Int, maxLon: Int) {
        let padLat = region.span.latitudeDelta * 0.2
        let padLon = region.span.longitudeDelta * 0.2
        let minLat = region.center.latitude - region.span.latitudeDelta / 2 - padLat
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2 + padLat
        let minLon = region.center.longitude - region.span.longitudeDelta / 2 - padLon
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2 + padLon
        return (
            Int(floor(minLat * 1_000)),
            Int(floor(maxLat * 1_000)),
            Int(floor(minLon * 1_000)),
            Int(floor(maxLon * 1_000))
        )
    }

    private static func contains(
        _ region: (minLat: Int, maxLat: Int, minLon: Int, maxLon: Int),
        indices: (lat: Int, lon: Int)
    ) -> Bool {
        indices.lat >= region.minLat && indices.lat <= region.maxLat
            && indices.lon >= region.minLon && indices.lon <= region.maxLon
    }

    private static func estimatedCount(
        _ native: [(lat: Int, lon: Int, cell: VisitedCell)],
        factor: Int
    ) -> Int {
        guard factor > 1 else { return native.count }
        var keys = Set<Int64>()
        keys.reserveCapacity(min(native.count, maximumDisplayCells * 2))
        for item in native {
            let lat = floorDiv(item.lat, by: factor)
            let lon = floorDiv(item.lon, by: factor)
            keys.insert((Int64(lat) &<< 32) ^ Int64(bitPattern: UInt64(UInt32(truncatingIfNeeded: lon))))
            if keys.count > maximumDisplayCells { return keys.count }
        }
        return keys.count
    }

    private static func aggregate(
        _ native: [(lat: Int, lon: Int, cell: VisitedCell)],
        factor: Int
    ) -> [DisplayCell] {
        guard factor > 1 else {
            return native.map { item in
                DisplayCell(
                    latIndex: item.lat,
                    lonIndex: item.lon,
                    factor: 1,
                    sampleCount: item.cell.sampleCount,
                    firstVisitedAt: item.cell.firstVisitedAt,
                    lastVisitedAt: item.cell.lastVisitedAt
                )
            }
        }

        struct Acc {
            var count: Int
            var first: Date
            var last: Date
        }
        var grouped: [String: Acc] = [:]
        for item in native {
            let lat = floorDiv(item.lat, by: factor) * factor
            let lon = floorDiv(item.lon, by: factor) * factor
            let key = "\(lat)|\(lon)"
            if let existing = grouped[key] {
                grouped[key] = Acc(
                    count: existing.count + item.cell.sampleCount,
                    first: min(existing.first, item.cell.firstVisitedAt),
                    last: max(existing.last, item.cell.lastVisitedAt)
                )
            } else {
                grouped[key] = Acc(
                    count: item.cell.sampleCount,
                    first: item.cell.firstVisitedAt,
                    last: item.cell.lastVisitedAt
                )
            }
        }
        return grouped.compactMap { key, acc in
            guard let indices = indices(from: key) else { return nil }
            return DisplayCell(
                latIndex: indices.lat,
                lonIndex: indices.lon,
                factor: factor,
                sampleCount: acc.count,
                firstVisitedAt: acc.first,
                lastVisitedAt: acc.last
            )
        }
    }
}
