import CoreLocation
import FogOfWorldKit
import Foundation
import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Coverage values have no SwiftData identity. Undated imported coverage never creates visits.
struct ExplorationDisplayCell: Hashable, Sendable {
    let x: UInt32
    let y: UInt32
    let factor: UInt32
    var bounds: FogCellGeographicBounds {
        let start = FogRaster.coordinate(x: x, y: y)
        let end = FogRaster.coordinate(x: min(x + factor, FogRasterV1.globalCellDimension - 1), y: min(y + factor, FogRasterV1.globalCellDimension - 1))
        return .init(west: start.longitude, south: end.latitude, east: end.longitude, north: start.latitude)
    }
}

private extension FogRaster {
    static func coordinate(x: UInt32, y: UInt32) -> FogGeographicCoordinate {
        geographicCoordinate(for: FogWorldCoordinate(x: x, y: y))
    }
}

/// Fine raster adapted from upstream Exploration, built only for the visible map.
/// Paging bounds memory; cancellation stops work on navigation. No new background schedule or GPS work.
enum DetailedExploration {
    static func displayCells(container: ModelContainer, interval: DateInterval, region: MKCoordinateRegion,
                             includeUndated: Bool) async throws -> [ExplorationDisplayCell] {
        try await importWorkerValue(Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let start = interval.start, end = interval.end
            let south = max(-90, region.center.latitude - region.span.latitudeDelta * 0.65)
            let north = min(90, region.center.latitude + region.span.latitudeDelta * 0.65)
            let centerLon = region.center.longitude
            let halfWidth = region.span.longitudeDelta * 0.65
            var query = FetchDescriptor<LocationSample>(predicate: #Predicate {
                $0.timestamp >= start && $0.timestamp < end && $0.latitude >= south && $0.latitude <= north
            }, sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.dedupeKey)])
            query.fetchLimit = 1000
            query.relationshipKeyPathsForPrefetching = [\.moveSegment]
            let width = max(1, Double(FogRasterV1.globalCellDimension) * region.span.longitudeDelta / 360)
            var factor: UInt32 = 1
            while Double(factor) * 160 < width { factor *= 2 }
            var cells = Set<ExplorationDisplayCell>()
            var offset = 0
            func add(_ latitude: Double, _ longitude: Double) {
                guard latitude.isFinite, longitude.isFinite, latitude >= south, latitude <= north else { return }
                let delta = abs(FogRasterV1.normalizedLongitude(longitude - centerLon))
                guard halfWidth >= 180 || delta <= halfWidth,
                      let address = try? FogRasterV1.address(for: .init(latitude: latitude, longitude: longitude)) else { return }
                let point = address.cell.coordinate
                cells.insert(.init(x: point.x / factor * factor, y: point.y / factor * factor, factor: factor))
            }
            while true {
                try Task.checkCancellation()
                query.fetchOffset = offset
                let count = try autoreleasepool {
                    let page = try context.fetch(query)
                    for sample in page {
                        // A flight trace or photo is evidence of travel, not ground exploration.
                        guard sample.moveSegment?.transportMode != .plane, sample.source != .photoLibrary,
                              CLLocationCoordinate2DIsValid(sample.coordinate) else { continue }
                        add(sample.latitude, sample.longitude)
                    }
                    return page.count
                }
                if count < 1000 { break }
                offset += count
            }
            if includeUndated {
                for block in try FogCoverageArchive.load() {
                    try Task.checkCancellation()
                    let tileX = block.tileID % 512, tileY = block.tileID / 512
                    let x0 = UInt32((tileX * 128 + block.localX) * 64)
                    let y0 = UInt32((tileY * 128 + block.localY) * 64)
                    let corner = FogRaster.coordinate(x: x0, y: y0)
                    let opposite = FogRaster.coordinate(x: x0 + 63, y: y0 + 63)
                    guard corner.latitude >= south, opposite.latitude <= north else { continue }
                    for y in 0..<64 { for x in 0..<64 where block.bitmap.contains(x: x, y: y) {
                        let coordinate = FogRaster.coordinate(x: x0 + UInt32(x), y: y0 + UInt32(y))
                        add(coordinate.latitude, coordinate.longitude)
                    } }
                }
            }
            return cells.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        })
    }
}

/// Imported Fog coverage is user data, stored separately from disposable map caches and dated history.
enum FogCoverageArchive {
    struct Record: Codable { let tileID: Int; let x: Int; let y: Int; let bytes: Data }
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/FogCoverage.json")
    }
    static func load(from url: URL = url) throws -> [FogBlock] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: url)).map {
            guard (0..<(512 * 512)).contains($0.tileID), (0..<128).contains($0.x), (0..<128).contains($0.y) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FogBlock(tileID: $0.tileID, localX: $0.x, localY: $0.y,
                            bitmap: try FogOfWorldKit.FogBitmapBlock(bytes: $0.bytes))
        }
    }
    static func merge(_ blocks: [FogBlock], at url: URL = url) throws {
        var merged: [String: Record] = [:]
        for block in try load(from: url) + blocks {
            try Task.checkCancellation()
            let key = "\(block.tileID)|\(block.localX)|\(block.localY)"
            var bytes = block.bitmap.bytes
            if let old = merged[key] { for i in bytes.indices { bytes[i] |= old.bytes[i] } }
            merged[key] = Record(tileID: block.tileID, x: block.localX, y: block.localY, bytes: Data(bytes))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(merged.values)).write(to: url, options: .atomic)
    }
}

/// Fog shares the existing Map layer, using fine cells at street zoom and bounded coarse cells at world zoom.
struct DetailedFogCanvas: View {
    let cells: [ExplorationDisplayCell]
    let region: MKCoordinateRegion
    var body: some View {
        Canvas { context, size in
            guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.72)))
            context.blendMode = .destinationOut
            let center = MKMapPoint(region.center)
            let top = MKMapPoint(CLLocationCoordinate2D(latitude: min(85, region.center.latitude + region.span.latitudeDelta / 2), longitude: region.center.longitude))
            let bottom = MKMapPoint(CLLocationCoordinate2D(latitude: max(-85, region.center.latitude - region.span.latitudeDelta / 2), longitude: region.center.longitude))
            let mapWidth = MKMapSize.world.width * region.span.longitudeDelta / 360
            let mapHeight = max(bottom.y - top.y, 1)
            func point(_ latitude: Double, _ longitude: Double) -> CGPoint {
                let p = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                var dx = p.x - center.x
                if dx > MKMapSize.world.width / 2 { dx -= MKMapSize.world.width }
                if dx < -MKMapSize.world.width / 2 { dx += MKMapSize.world.width }
                return CGPoint(x: (dx / mapWidth + 0.5) * size.width, y: (p.y - top.y) / mapHeight * size.height)
            }
            for cell in cells {
                let b = cell.bounds
                let a = point(b.north, b.west), z = point(b.south, b.east)
                let rect = CGRect(x: min(a.x,z.x), y: min(a.y,z.y), width: max(abs(z.x-a.x),1), height: max(abs(z.y-a.y),1))
                context.fill(Path(rect), with: .color(.white))
            }
        }.allowsHitTesting(false)
    }
}

/// Explicit compatibility import/export. Coverage retains its undated identity and never enters automatic uploads.
struct FogCoverageSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var choosingFile = false
    @State private var working = false
    @State private var message: String?
    @State private var exportURL: URL?
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: String(localized: "Fog of World")) {
                    Button("Import coverage") { choosingFile = true }.disabled(working)
                    Button("Export coverage") { exportCoverage() }.disabled(working)
                    if working { ProgressView() }
                    if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    if let exportURL { ShareLink("Share coverage", item: exportURL) }
                    Text("Imported coverage appears in the all-time Fog map. It has no visit dates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }
        .navigationTitle("Fog of World")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.zip, .data]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { message = error.localizedDescription }
                return
            }
            working = true
            Task {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() }; working = false }
                do {
                    _ = try await importWorkerValue(Task.detached(priority: .utility) {
                        let reader = try FogArchiveReader(data: Data(contentsOf: url, options: .mappedIfSafe))
                        let blocks = try await reader.decodeAllBlocks()
                        try Task.checkCancellation()
                        try FogCoverageArchive.merge(blocks)
                        return blocks.count
                    })
                    message = String(localized: "Coverage imported.")
                    NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func exportCoverage() {
        let container = modelContext.container
        working = true
        Task {
            defer { working = false }
            do {
                exportURL = try await importWorkerValue(Task.detached(priority: .utility) {
                    let data = try FogArchiveWriter.makeFWSSArchive(blocks: FogCoverageArchive.exportBlocks(container: container))
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moves-coverage-\(UUID().uuidString).fwss")
                    try data.write(to: url, options: .atomic)
                    return url
                })
            } catch { message = error.localizedDescription }
        }
    }
}

extension FogCoverageArchive {
    /// Explicit export of original ground observations plus imported undated coverage.
    /// Honor the same Home/Work redaction policy as every other export format.
    static func exportBlocks(container: ModelContainer, importedURL: URL? = nil, privacyZones: [PrivacyZone]? = nil) throws -> [FogBlock] {
        let context = ModelContext(container)
        let zones: [PrivacyZone]
        if let privacyZones { zones = privacyZones }
        else { zones = PrivacyZoneResolver.exportZones(from: try context.fetch(FetchDescriptor<KnownPlace>())) }
        var bitmaps: [FogBlockID: Data] = [:]
        for block in try load(from: importedURL ?? url) {
            let id = FogBlockID(x: UInt32((block.tileID % 512) * 128 + block.localX),
                                y: UInt32((block.tileID / 512) * 128 + block.localY))
            bitmaps[id] = block.bitmap.bytes
        }
        var query = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.dedupeKey)])
        query.fetchLimit = 1000
        query.relationshipKeyPathsForPrefetching = [\.moveSegment]
        var offset = 0
        while true {
            try Task.checkCancellation()
            query.fetchOffset = offset
            let count = try autoreleasepool {
                let page = try context.fetch(query)
                for sample in page where sample.moveSegment?.transportMode != .plane && sample.source != .photoLibrary {
                    guard CLLocationCoordinate2DIsValid(sample.coordinate), let address = try? FogRasterV1.address(for: sample.coordinate) else { continue }
                    var bytes = bitmaps[address.block] ?? Data(repeating: 0, count: 512)
                    let x = Int(address.localCellX), y = Int(address.localCellY)
                    bytes[y * 8 + x / 8] |= UInt8(0x80 >> (x % 8))
                    bitmaps[address.block] = bytes
                }
                return page.count
            }
            if count < 1000 { break }
            offset += count
        }
        var blocks: [FogBlock] = []
        for (id, original) in bitmaps {
            try Task.checkCancellation()
            var bytes = original
            if !zones.isEmpty {
                for y in 0..<64 { for x in 0..<64 where bytes[y * 8 + x / 8] & UInt8(0x80 >> (x % 8)) != 0 {
                    let cell = FogCell(coordinate: .init(x: id.x * 64 + UInt32(x), y: id.y * 64 + UInt32(y)))
                    let b = try FogRasterV1.geographicBounds(for: cell)
                    let center = CLLocation(latitude: (b.north + b.south) / 2, longitude: (b.east + b.west) / 2)
                    let diagonal = center.distance(from: CLLocation(latitude: b.north, longitude: b.east))
                    if zones.contains(where: { center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radiusMeters + diagonal }) {
                        bytes[y * 8 + x / 8] &= ~UInt8(0x80 >> (x % 8))
                    }
                } }
            }
            guard bytes.contains(where: { $0 != 0 }) else { continue }
            blocks.append(FogBlock(tileID: Int(id.baseTile.y) * 512 + Int(id.baseTile.x),
                                   localX: Int(id.localBlockX), localY: Int(id.localBlockY),
                                   bitmap: try FogOfWorldKit.FogBitmapBlock(bytes: bytes)))
        }
        return blocks
    }
}
