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

        var pending: [String: (first: Date, last: Date, count: Int)] = [:]
        pending.reserveCapacity(samples.count)
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

    /// Drops every cell and rebuilds from `LocationSample`. Used when the cache is empty
    /// (demo seeder and imports insert samples without going through `appendSamples`).
    static func rebuild(in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<VisitedCell>())
        existing.forEach(context.delete)

        let samples = try context.fetch(FetchDescriptor<LocationSample>())
        try record(samples, in: context)
        if context.hasChanges {
            try context.save()
        }
    }

    /// Rebuilds only when the cache has never been populated.
    static func ensureBuilt(in context: ModelContext) throws {
        let count = try context.fetchCount(FetchDescriptor<VisitedCell>())
        if count == 0 {
            try rebuild(in: context)
        }
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
