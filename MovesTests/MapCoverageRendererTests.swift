import CoreLocation
import FogOfWorldKit
import MapKit
import SwiftData
import XCTest
@testable import Moves

final class MapCoverageRendererTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
    private let viewSize = CGSize(width: 400, height: 800)

    // MARK: Heat

    func testHeatDrawsAContinuousLineOfWarmthAlongARouteAndNothingFarAway() throws {
        let request = request(.heat, metersPerPoint: 20)
        let track = horizontalTrack(across: request.viewport, at: 0.5)
        let subset = MapActivitySubset(tracks: [track], stays: [], undatedCoverage: [])
        let geometry = try XCTUnwrap(MapCoverageRenderer.geometry(for: request, blurSigmaPoints: MapCoverageRenderer.heatSigmaPoints))

        let density = try MapCoverageRenderer.heatDensity(subset, geometry: geometry)
        let y = Int(geometry.pixel(track.chunks[0].points[0]).y)
        let from = Int(geometry.pixel(MercatorPoint(x: request.viewport.minX, y: 0)).x)
        let to = Int(geometry.pixel(MercatorPoint(x: request.viewport.maxX, y: 0)).x)
        let along = (from..<to).map { density[y * geometry.width + $0] }
        // A drive is warmth all the way along, not dots at its fixes: about one pass everywhere.
        XCTAssertGreaterThan(along.min() ?? 0, 0.8)
        XCTAssertLessThan(along.max() ?? 0, 1.2)
        XCTAssertEqual(density[(y + 80) * geometry.width + (from + to) / 2], 0, accuracy: 0.001)

        let raster = try XCTUnwrap(MapCoverageRenderer.render(subset, request: request))
        let image = PixelReader(raster.image)
        let column = (from + to) / 2
        // The line's centre can fall between two rows; start the profile at the brighter one.
        let peakRow = (y - 2...y + 2).max { image.alpha(.init(x: column, y: $0)) < image.alpha(.init(x: column, y: $1)) } ?? y
        let screen = PixelReader.Point(x: column, y: peakRow)
        XCTAssertGreaterThan(image.alpha(screen), 60)
        XCTAssertEqual(image.alpha(.init(x: screen.x, y: peakRow + 80)), 0)
        // Soft falloff, no hard edge.
        let profile = (0..<30).map { image.alpha(.init(x: screen.x, y: peakRow + $0)) }
        XCTAssertTrue(zip(profile, profile.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertTrue(profile.contains { $0 > 5 && $0 < 40 })
    }

    func testHeatKernelKeepsItsSizeOnScreenAtEveryZoom() throws {
        func halfWidthPoints(metersPerPoint: Double) throws -> Double {
            let request = request(.heat, metersPerPoint: metersPerPoint)
            let track = horizontalTrack(across: request.viewport, at: 0.5)
            let geometry = try XCTUnwrap(MapCoverageRenderer.geometry(for: request, blurSigmaPoints: MapCoverageRenderer.heatSigmaPoints))
            let density = try MapCoverageRenderer.heatDensity(MapActivitySubset(tracks: [track], stays: [], undatedCoverage: []), geometry: geometry)
            let y = Int(geometry.pixel(track.chunks[0].points[0]).y)
            let x = geometry.width / 2
            let peak = density[y * geometry.width + x]
            var offset = 0
            while density[(y + offset) * geometry.width + x] > peak / 2 { offset += 1 }
            return Double(offset) / geometry.pixelsPerPoint
        }
        let street = try halfWidthPoints(metersPerPoint: 1)
        let region = try halfWidthPoints(metersPerPoint: 500)
        XCTAssertEqual(street, region, accuracy: 3)
        XCTAssertEqual(street, MapCoverageRenderer.heatSigmaPoints * 1.18, accuracy: 3)
    }

    func testAFlightAcrossTheAntimeridianDoesNotCrossTheWholeMap() throws {
        let tokyo = MercatorPoint(CLLocationCoordinate2D(latitude: 35.5, longitude: 139.8))
        let pacific = MercatorPoint(CLLocationCoordinate2D(latitude: 45, longitude: 179.5))
        let alaska = MercatorPoint(CLLocationCoordinate2D(latitude: 50, longitude: -179.5))
        let points = MapActivityIndex.unwrapped([tokyo, pacific, alaska])
        XCTAssertEqual(points[2].x - points[1].x, MKMapSize.world.width / 360, accuracy: MKMapSize.world.width / 3_600)

        // Looking at Alaska, the leg arrives from the west edge: drawn one world over.
        let world = MKMapSize.world.width
        let viewport = MercatorRect(minX: alaska.x - world / 100, minY: alaska.y - world / 100,
                                    maxX: alaska.x + world / 100, maxY: alaska.y + world / 100)
        let track = MapActivityTrack(start: .distantPast, end: .distantFuture, mode: .plane, chunks: MapActivityIndex.chunks(for: points))
        XCTAssertEqual(MapRasterGeometry.worldOffsets(for: track.chunks[0].bounds, in: viewport), [-world])
        let request = MapCoverageRenderRequest(layer: .heat, viewport: viewport, viewSize: viewSize, isDark: false)
        let geometry = try XCTUnwrap(MapCoverageRenderer.geometry(for: request, blurSigmaPoints: MapCoverageRenderer.heatSigmaPoints))
        let density = try MapCoverageRenderer.heatDensity(MapActivitySubset(tracks: [track], stays: [], undatedCoverage: []), geometry: geometry)
        let center = geometry.pixel(alaska)
        XCTAssertGreaterThan(density[Int(center.y) * geometry.width + Int(center.x)], 0.3)
        // Nothing smeared across the bitmap far from the leg.
        XCTAssertEqual(density[3 * geometry.width + 3], 0, accuracy: 0.001)
    }

    func testHeatNormalisationKeepsASingleTripVisibleNextToHome() throws {
        let request = request(.heat, metersPerPoint: 20)
        let track = horizontalTrack(across: request.viewport, at: 0.3)
        let home = MercatorPoint(x: request.viewport.midX, y: request.viewport.minY + request.viewport.height * 0.7)
        let nights = (0..<300).map { day in
            MapActivityStay(point: home, arrival: Date(timeIntervalSince1970: Double(day) * 86_400),
                            departure: Date(timeIntervalSince1970: Double(day) * 86_400 + 10 * 3_600))
        }
        let subset = MapActivitySubset(tracks: [track], stays: nights, undatedCoverage: [])
        let raster = try XCTUnwrap(MapCoverageRenderer.render(subset, request: request))
        let image = PixelReader(raster.image)
        let scale = Double(raster.image.width) / raster.bounds.width
        let trackPixel = PixelReader.Point(x: raster.image.width / 2, y: Int((track.chunks[0].points[0].y - raster.bounds.minY) * scale))
        XCTAssertGreaterThan(image.alpha(trackPixel), 60, "One trip still reads beside 300 nights at home")
    }

    // MARK: Fog

    func testFogRevealsAFeatheredDiscAtAStayAndKeepsTheVeilElsewhere() throws {
        let request = request(.fog, metersPerPoint: 10)
        let stayPoint = MercatorPoint(x: request.viewport.midX, y: request.viewport.midY)
        let stay = MapActivityStay(point: stayPoint, arrival: .distantPast, departure: .distantFuture)
        let raster = try XCTUnwrap(MapCoverageRenderer.render(
            MapActivitySubset(tracks: [], stays: [stay], undatedCoverage: []), request: request))
        let image = PixelReader(raster.image)
        let scale = Double(raster.image.width) / raster.bounds.width
        let centerPixel = PixelReader.Point(
            x: Int((stayPoint.x - raster.bounds.minX) * scale),
            y: Int((stayPoint.y - raster.bounds.minY) * scale)
        )
        let veilAlpha = UInt8((MapCoverageRenderer.veilColor(isDark: false).alpha * 255).rounded())
        XCTAssertLessThan(image.alpha(centerPixel), 8)
        XCTAssertEqual(image.alpha(.init(x: 4, y: 4)), veilAlpha)

        // The edge fades over the reveal radius rather than stepping.
        let pixelsPerPoint = scale * request.viewport.width / Double(request.viewSize.width)
        let radiusPixels = Int(MapCoverageRenderer.fogRadiusPoints(metersPerPoint: 10) * 1.2 * pixelsPerPoint)
        XCTAssertGreaterThan(radiusPixels, 5)
        let profile = (0..<(radiusPixels * 2)).map { image.alpha(.init(x: centerPixel.x + $0, y: centerPixel.y)) }
        XCTAssertTrue(zip(profile, profile.dropFirst()).allSatisfy { $0 <= $1 }, "\(profile)")
        XCTAssertGreaterThanOrEqual(profile.filter { $0 > 10 && $0 < veilAlpha - 10 }.count, 3, "\(profile)")
        XCTAssertGreaterThan(profile.last ?? 0, veilAlpha - 12, "Fogged again within two radii: \(profile)")
    }

    func testDetailLevelsStepOncePerDoublingOfScale() {
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 1), 0)
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 16), 4)
        // A level spans a factor of two, centred on its power of two.
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 16 * 1.4), 4)
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 16 / 1.4), 4)
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 16 * 1.45), 5)
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: 0.5), -1)
        XCTAssertEqual(MapCoverageRenderer.detailLevel(metersPerPoint: .nan), 0)
        XCTAssertEqual(MapCoverageRenderer.levelMetersPerPoint(4), 16)
    }

    func testFogFootprintIsFixedOnTheGroundWithinALevelAndDoublesPerLevel() {
        let r = MapCoverageRenderer.self
        // Pinching within a level keeps the same ground footprint, so the picture only scales.
        XCTAssertEqual(r.fogRadiusMeters(metersPerPoint: 50), r.fogRadiusMeters(metersPerPoint: 80))
        XCTAssertEqual(r.fogRadiusMeters(metersPerPoint: 64), r.fogRevealPoints * 64)
        // Zooming out a level merges detail: twice the ground.
        XCTAssertEqual(r.fogRadiusMeters(metersPerPoint: 128), 2 * r.fogRadiusMeters(metersPerPoint: 64))
        // Street zoom: tens of metres around the path, not a swath.
        XCTAssertEqual(r.fogRadiusMeters(metersPerPoint: 0.75), r.fogMinimumRadiusMeters)
        XCTAssertEqual(r.undatedRadiusMeters(metersPerPoint: 0.25), r.undatedMinimumRadiusMeters)
        // On screen it stays near the target size at every zoom above the floor.
        for scale in stride(from: 3.0, through: 200_000, by: 997) {
            let points = r.fogRadiusPoints(metersPerPoint: scale)
            XCTAssertGreaterThanOrEqual(points, r.fogRevealPoints / 2.squareRoot() - 0.01, "\(scale) m/pt")
            XCTAssertLessThanOrEqual(points, r.fogRevealPoints * 2.squareRoot() + 0.01, "\(scale) m/pt")
        }
        // Neighbourhood, city, region, and world zooms are increasingly coarse on the ground.
        let footprints = [5.0, 50, 750, 20_000].map { r.fogRadiusMeters(metersPerPoint: $0) }
        XCTAssertEqual(footprints, footprints.sorted())
        XCTAssertGreaterThan(footprints[2], 5_000, "A visited city is a clear blob at region zoom")
    }

    func testHeatKernelFollowsTheZoomLevelWithAStreetFloor() {
        let r = MapCoverageRenderer.self
        XCTAssertEqual(r.heatSigmaMeters(metersPerPoint: 0.3), r.heatMinimumSigmaMeters)
        XCTAssertEqual(r.heatSigmaMeters(metersPerPoint: 600), r.heatSigmaPoints * 512)
        XCTAssertEqual(r.heatSigmaMeters(metersPerPoint: 1_200), 2 * r.heatSigmaMeters(metersPerPoint: 600))
        XCTAssertEqual(r.heatSigmaMeters(metersPerPoint: 450), r.heatSigmaMeters(metersPerPoint: 700))
    }

    func testImportedCellsKeepFineDetailZoomedInAndMergeZoomedOut() throws {
        // Two imported cells 40 m apart: separate at street zoom, one area at city zoom.
        let middle = MercatorPoint(center)
        let gap = 40 / MKMetersPerMapPointAtLatitude(center.latitude)
        let a = MercatorPoint(x: middle.x - gap / 2, y: middle.y), b = MercatorPoint(x: middle.x + gap / 2, y: middle.y)
        let coverage = MapActivitySubset(tracks: [], stays: [], undatedCoverage: [MapActivityChunk(points: [a, b])])
        func alphaBetween(metersPerPoint: Double) throws -> (between: UInt8, onCell: UInt8) {
            let request = request(.fog, metersPerPoint: metersPerPoint)
            let raster = try XCTUnwrap(MapCoverageRenderer.render(coverage, request: request))
            let image = PixelReader(raster.image)
            let scale = Double(raster.image.width) / raster.bounds.width
            func pixel(_ p: MercatorPoint) -> PixelReader.Point {
                .init(x: Int((p.x - raster.bounds.minX) * scale), y: Int((p.y - raster.bounds.minY) * scale))
            }
            return (image.alpha(pixel(middle)), image.alpha(pixel(a)))
        }
        let street = try alphaBetween(metersPerPoint: 0.25)
        XCTAssertLessThan(street.onCell, 20)
        XCTAssertGreaterThan(street.between, 100, "Cells stay distinct zoomed in")
        let city = try alphaBetween(metersPerPoint: 30)
        XCTAssertLessThan(city.between, 10, "Cells merge zoomed out")
    }

    func testFogRevealHasAMinimumSizeOnScreenAndIgnoresFlights() throws {
        let request = request(.fog, metersPerPoint: 2_000)
        XCTAssertGreaterThan(MapCoverageRenderer.fogRadiusPoints(metersPerPoint: 2_000), 12)
        let walk = horizontalTrack(across: request.viewport, at: 0.3)
        let flight = horizontalTrack(across: request.viewport, at: 0.7, mode: .plane)
        let raster = try XCTUnwrap(MapCoverageRenderer.render(
            MapActivitySubset(tracks: [walk, flight], stays: [], undatedCoverage: []), request: request))
        let image = PixelReader(raster.image)
        let scale = Double(raster.image.width) / raster.bounds.width
        func row(_ track: MapActivityTrack) -> Int { Int((track.chunks[0].points[0].y - raster.bounds.minY) * scale) }
        let x = raster.image.width / 2
        XCTAssertLessThan(image.alpha(.init(x: x, y: row(walk))), 10)
        XCTAssertGreaterThan(image.alpha(.init(x: x, y: row(flight))), 140)
    }

    func testAHundredThousandPointHistoryRendersInWellUnderASecond() throws {
        // 2,000 trips of 60 fixes wandering around one city, viewed at city and region zoom.
        var generator = SystemRandomNumberGenerator()
        let middle = MercatorPoint(center)
        let spread = 0.15 / 360 * MKMapSize.world.width
        let tracks = (0..<2_000).map { _ -> MapActivityTrack in
            var x = middle.x + Double.random(in: -spread...spread, using: &generator)
            var y = middle.y + Double.random(in: -spread...spread, using: &generator)
            let points = (0..<60).map { _ -> MercatorPoint in
                x += Double.random(in: -spread / 40...spread / 40, using: &generator)
                y += Double.random(in: -spread / 40...spread / 40, using: &generator)
                return MercatorPoint(x: x, y: y)
            }
            return MapActivityTrack(start: .distantPast, end: .distantFuture, mode: .automotive, chunks: MapActivityIndex.chunks(for: points))
        }
        let subset = MapActivitySubset(tracks: tracks, stays: [], undatedCoverage: [])
        for metersPerPoint in [15.0, 600] {
            for layer in [MapCoverageLayer.heat, .fog] {
                let started = Date()
                let raster = try MapCoverageRenderer.render(subset, request: request(layer, metersPerPoint: metersPerPoint))
                let elapsed = Date().timeIntervalSince(started)
                XCTAssertNotNil(raster)
                XCTAssertLessThan(elapsed, 1.5, "\(layer) at \(metersPerPoint) m/pt took \(elapsed) s")
                print("render \(layer) \(metersPerPoint) m/pt: \(Int(elapsed * 1_000)) ms")
            }
        }
    }

    func testUndatedCoverageBecomesPointsInsideItsCell() throws {
        var bytes = Data(repeating: 0, count: 512)
        bytes[0] = 0x80
        let block = FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: try FogOfWorldKit.FogBitmapBlock(bytes: bytes))
        let chunks = try MapActivityIndexBuilder.undatedCoverageChunks(from: [block])
        let point = try XCTUnwrap(chunks.first?.points.first)
        let bounds = try FogRasterV1.geographicBounds(for: FogCell(coordinate: FogRasterCoordinate(x: 0, y: 0)))
        XCTAssertEqual(chunks.first?.points.count, 1)
        XCTAssertGreaterThan(point.coordinate.longitude, bounds.west)
        XCTAssertLessThan(point.coordinate.longitude, bounds.east)
        XCTAssertGreaterThan(point.coordinate.latitude, bounds.south)
        XCTAssertLessThan(point.coordinate.latitude, bounds.north)
    }

    // MARK: Index

    func testSubsetFollowsTheRangeAndEnabledModes() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func track(_ offset: TimeInterval, _ mode: TransportMode) -> MapActivityTrack {
            MapActivityTrack(start: day.addingTimeInterval(offset), end: day.addingTimeInterval(offset + 600), mode: mode,
                             chunks: MapActivityIndex.chunks(for: [MercatorPoint(x: 0, y: 0), MercatorPoint(x: 1, y: 1)]))
        }
        var index = MapActivityIndex()
        index.tracks = [track(0, .walking), track(3_600, .automotive), track(200_000, .walking)]
        index.stays = [MapActivityStay(point: MercatorPoint(x: 0, y: 0), arrival: day.addingTimeInterval(-60), departure: day.addingTimeInterval(60))]
        index.undatedCoverage = [MapActivityChunk(points: [MercatorPoint(x: 5, y: 5)])]
        let range = DateInterval(start: day, duration: 86_400)

        XCTAssertEqual(index.subset(interval: range, modes: nil, includeUndated: false).tracks.count, 2)
        XCTAssertEqual(index.subset(interval: range, modes: [.walking], includeUndated: false).tracks.count, 1)
        XCTAssertEqual(index.subset(interval: range, modes: nil, includeUndated: false).stays.count, 1)
        XCTAssertTrue(index.subset(interval: range, modes: nil, includeUndated: false).undatedCoverage.isEmpty)
        XCTAssertEqual(index.subset(interval: range, modes: nil, includeUndated: true).undatedCoverage.count, 1)
    }

    func testLongPathsSplitIntoJoinedBoundedChunks() {
        let points = (0..<600).map { MercatorPoint(x: Double($0), y: 0) }
        let chunks = MapActivityIndex.chunks(for: points)
        XCTAssertTrue(chunks.allSatisfy { $0.points.count <= MapActivityIndex.chunkSize })
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.points.last, b.points.first)
        }
        XCTAssertEqual(chunks.last?.points.last, points.last)
        XCTAssertEqual(chunks.first?.bounds.maxX, Double(MapActivityIndex.chunkSize - 1))
    }

    func testIndexSkipsInaccurateFixesInRoutesAndVisitedCells() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let move = MoveSegment(dedupeKey: "m", startDate: start, endDate: start.addingTimeInterval(900),
                               transportMode: .walking, distanceMeters: 800, stepCount: nil)
        context.insert(move)
        let good = [(11.940, 108.440, 8.0), (11.942, 108.442, 0.0), (11.944, 108.444, 65.0)]
        let bad = [(12.050, 108.600, 1_200.0), (11.900, 108.300, -1.0), (11.950, 108.500, 101.0)]
        var samples: [LocationSample] = []
        for (offset, fix) in (good + bad).enumerated() {
            let sample = LocationSample(
                location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: fix.0, longitude: fix.1), altitude: 0,
                                     horizontalAccuracy: fix.2, verticalAccuracy: -1, course: -1, speed: 1,
                                     timestamp: start.addingTimeInterval(Double(offset) * 60)),
                source: .significantChange,
                dedupeKey: "s\(offset)"
            )
            sample.moveSegment = move
            context.insert(sample)
            samples.append(sample)
        }
        let stay = VisitPlace(arrivalDate: start.addingTimeInterval(-3_600), departureDate: start,
                              latitude: 11.939, longitude: 108.439, horizontalAccuracy: 20)
        context.insert(stay)
        try context.save()

        let index = try MapActivityIndexBuilder.build(container: container, undatedCoverageURL: missingURL())
        let points = try XCTUnwrap(index.tracks.first).chunks.flatMap(\.points).map(\.coordinate)
        XCTAssertEqual(points.count, good.count)
        for coordinate in points {
            XCTAssertTrue(good.contains { abs($0.0 - coordinate.latitude) < 1e-6 && abs($0.1 - coordinate.longitude) < 1e-6 },
                          "\(coordinate) is not an accurate fix")
        }
        XCTAssertEqual(index.stays.count, 1)
        XCTAssertEqual(index.stays.first?.dwell ?? 0, 3_600, accuracy: 1)

        try VisitedCellStore.rebuild(in: context)
        let cells = Set(try context.fetch(FetchDescriptor<VisitedCell>()).map(\.cellKey))
        XCTAssertEqual(cells, Set(good.map { VisitedCellStore.cellKey(latitude: $0.0, longitude: $0.1) }))
    }

    func testIndexUsesAHandDrawnRouteWhenThereIsOne() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let move = MoveSegment(dedupeKey: "m", startDate: start, endDate: start.addingTimeInterval(900),
                               transportMode: .cycling, distanceMeters: 800, stepCount: nil)
        let drawn = (0..<5).map { CLLocationCoordinate2D(latitude: 11.94 + Double($0) * 0.001, longitude: 108.44) }
        move.storeManualRouteCoordinates(drawn)
        context.insert(move)
        try context.save()
        let index = try MapActivityIndexBuilder.build(container: container, undatedCoverageURL: missingURL())
        XCTAssertEqual(index.tracks.first?.mode, .cycling)
        XCTAssertEqual(index.tracks.first?.chunks.flatMap(\.points).count, drawn.count)
        XCTAssertEqual(index.latestActivity?.latitude ?? 0, drawn.last!.latitude, accuracy: 1e-6)
    }

    // MARK: Defaults

    func testMapOpensOnAllTimeAtCityScaleNearYou() {
        let selection = MapRangeSelection.allTime()
        XCTAssertEqual(selection.granularity, .allTime)
        XCTAssertEqual(selection.title(), String(localized: "All time"))

        let you = CLLocationCoordinate2D(latitude: 11.94, longitude: 108.44)
        let lastTrip = CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21)
        let region = MapCameraDefaults.cityRegion(userLocation: you, latestActivity: lastTrip)
        XCTAssertEqual(region?.center.latitude ?? 0, you.latitude, accuracy: 1e-9)
        XCTAssertLessThan(region?.span.latitudeDelta ?? 99, 0.5)
        XCTAssertEqual(MapCameraDefaults.cityRegion(userLocation: nil, latestActivity: lastTrip)?.center.latitude ?? 0,
                       lastTrip.latitude, accuracy: 1e-9)
        XCTAssertNil(MapCameraDefaults.cityRegion(userLocation: nil, latestActivity: nil))
    }

    // MARK: Helpers

    private func request(_ layer: MapCoverageLayer, metersPerPoint: Double) -> MapCoverageRenderRequest {
        let mapPointsPerPoint = metersPerPoint / MKMetersPerMapPointAtLatitude(center.latitude)
        let middle = MercatorPoint(center)
        let width = Double(viewSize.width) * mapPointsPerPoint
        let height = Double(viewSize.height) * mapPointsPerPoint
        return MapCoverageRenderRequest(
            layer: layer,
            viewport: MercatorRect(minX: middle.x - width / 2, minY: middle.y - height / 2,
                                   maxX: middle.x + width / 2, maxY: middle.y + height / 2),
            viewSize: viewSize,
            isDark: false
        )
    }

    /// A route with fixes a third of the screen apart, crossing the whole viewport.
    private func horizontalTrack(across viewport: MercatorRect, at fraction: Double, mode: TransportMode = .automotive) -> MapActivityTrack {
        let y = viewport.minY + viewport.height * fraction
        let points = stride(from: -1.0, through: 2.0, by: 1.0 / 3).map { MercatorPoint(x: viewport.minX + viewport.width * $0, y: y) }
        return MapActivityTrack(start: .distantPast, end: .distantFuture, mode: mode, chunks: MapActivityIndex.chunks(for: points))
    }

    // MARK: Routes at scale

    func testSimplificationDropsWhatIsWithinHalfAPixelAndKeepsCorners() {
        // A straight line with sub-pixel wobble, then a right-angle turn.
        var points = (0...100).map { CGPoint(x: Double($0), y: $0 % 2 == 0 ? 0 : 0.3) }
        points += (1...50).map { CGPoint(x: 100, y: Double($0)) }
        let kept = MapCoverageRenderer.simplified(points, tolerance: 0.5)
        XCTAssertLessThanOrEqual(kept.count, 4, "\(kept)")
        XCTAssertEqual(kept.first, points.first)
        XCTAssertEqual(kept.last, points.last)
        XCTAssertTrue(kept.contains { abs($0.x - 100) < 0.01 && abs($0.y) < 0.5 }, "The corner survives")
        // Every dropped point lies within tolerance of the simplified line.
        let wobbly = (0...40).map { CGPoint(x: Double($0) * 3, y: sin(Double($0)) * 4) }
        let reduced = MapCoverageRenderer.simplified(wobbly, tolerance: 0.5)
        for point in wobbly {
            let nearest = zip(reduced, reduced.dropFirst()).map { a, b in
                MapActivitySubset.distance(from: MercatorPoint(x: point.x, y: point.y),
                                           toSegment: MercatorPoint(x: a.x, y: a.y), MercatorPoint(x: b.x, y: b.y))
            }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 0.5 + 1e-9)
        }
    }

    func testRoutesBitmapDrawsTripsAndCullsOnesOffScreen() throws {
        let request = MapCoverageRenderRequest(layer: .routes, viewport: request(.heat, metersPerPoint: 20).viewport, viewSize: viewSize, isDark: false)
        let visible = horizontalTrack(across: request.viewport, at: 0.5, mode: .walking)
        let farAway = MapActivityTrack(
            start: .distantPast, end: .distantFuture, mode: .cycling,
            chunks: MapActivityIndex.chunks(for: [MercatorPoint(x: request.viewport.minX - request.viewport.width * 5, y: request.viewport.midY),
                                                  MercatorPoint(x: request.viewport.minX - request.viewport.width * 4, y: request.viewport.midY)])
        )
        let one = try XCTUnwrap(MapCoverageRenderer.render(MapActivitySubset(tracks: [visible], stays: [], undatedCoverage: []), request: request))
        let both = try XCTUnwrap(MapCoverageRenderer.render(MapActivitySubset(tracks: [visible, farAway], stays: [], undatedCoverage: []), request: request))
        XCTAssertEqual(one.image.dataProvider?.data as Data?, both.image.dataProvider?.data as Data?, "A trip outside the padded viewport changes nothing")
        let image = PixelReader(one.image)
        let scale = Double(one.image.width) / one.bounds.width
        let row = Int((visible.chunks[0].points[0].y - one.bounds.minY) * scale)
        XCTAssertGreaterThan(image.alpha(.init(x: one.image.width / 2, y: row)), 200)
        XCTAssertEqual(image.alpha(.init(x: one.image.width / 2, y: row + 60)), 0)
    }

    func testTappingFindsTheNearestTripThroughTheIndex() {
        func track(_ y: Double, _ mode: TransportMode) -> MapActivityTrack {
            MapActivityTrack(start: .distantPast, end: .distantFuture, mode: mode,
                             chunks: MapActivityIndex.chunks(for: (0...600).map { MercatorPoint(x: Double($0) * 10, y: y) }))
        }
        let near = track(100, .walking), far = track(400, .cycling)
        let subset = MapActivitySubset(tracks: [far, near], stays: [], undatedCoverage: [])
        XCTAssertEqual(subset.nearestTrack(to: MercatorPoint(x: 2_555, y: 130), within: 50)?.id, near.id)
        XCTAssertEqual(subset.nearestTrack(to: MercatorPoint(x: 5_000, y: 380), within: 50)?.id, far.id)
        XCTAssertNil(subset.nearestTrack(to: MercatorPoint(x: 2_555, y: 250), within: 50))
        XCTAssertNil(subset.nearestTrack(to: MercatorPoint(x: 9_000, y: 100), within: 50), "Past the end of every trip")
    }

    func testTripsWithNoFixesAndAnImplausibleDurationAreNotDrawn() {
        let rule = MapActivityIndexBuilder.isPlausibleTrip
        // Photos two days apart joined by an invented trip.
        XCTAssertFalse(rule(2 * 86_400, 300, 0, false))
        XCTAssertFalse(rule(7 * 3_600, 50_000, 0, false))
        // A crawl: 5 km in 8 hours with nothing recorded.
        XCTAssertFalse(rule(5 * 3_600, 5_000, 0, false))
        // Ordinary trips, with or without fixes.
        XCTAssertTrue(rule(40 * 60, 12_000, 0, false))
        XCTAssertTrue(rule(30 * 60, 1_500, 0, false))
        XCTAssertTrue(rule(9 * 3_600, 600_000, 12, false), "A long trip with fixes is real")
        XCTAssertTrue(rule(2 * 86_400, 300, 0, true), "Someone drew it by hand")
    }

    func testPhotoHistoryPointsDoNotShapeRoutes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let move = MoveSegment(dedupeKey: "m", startDate: start, endDate: start.addingTimeInterval(1_800),
                               transportMode: .walking, distanceMeters: 1_000, stepCount: nil)
        context.insert(move)
        let fixes: [(Double, Double, LocationSampleSource)] = [
            (11.940, 108.440, .significantChange), (11.950, 108.470, .photoLibrary), (11.944, 108.444, .routeTracking)
        ]
        for (offset, fix) in fixes.enumerated() {
            let sample = LocationSample(
                location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: fix.0, longitude: fix.1), altitude: 0,
                                     horizontalAccuracy: 10, verticalAccuracy: -1, course: -1, speed: 1,
                                     timestamp: start.addingTimeInterval(Double(offset) * 300)),
                source: fix.2,
                dedupeKey: "p\(offset)"
            )
            sample.moveSegment = move
            context.insert(sample)
        }
        try context.save()
        let index = try MapActivityIndexBuilder.build(container: container, undatedCoverageURL: missingURL())
        let points = index.tracks.flatMap { $0.chunks.flatMap(\.points) }.map(\.coordinate)
        XCTAssertFalse(points.contains { abs($0.latitude - 11.950) < 1e-6 }, "The photo point is not on the route")
    }

    func testSavedIndexRoundTripsAndKnowsWhichStoreStateItIsFor() throws {
        var index = MapActivityIndex()
        index.tracks = [MapActivityTrack(id: UUID(), start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200),
                                         mode: .cycling, distanceMeters: 1_234,
                                         chunks: MapActivityIndex.chunks(for: (0..<600).map { MercatorPoint(x: Double($0), y: Double($0) * 2) }))]
        index.stays = [MapActivityStay(point: MercatorPoint(x: 5, y: 6), arrival: Date(timeIntervalSince1970: 10), departure: Date(timeIntervalSince1970: 20))]
        index.excludedTripCount = 7
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try MapActivityIndexCache.save(index, signature: "store-a", to: url)
        let loaded = try XCTUnwrap(MapActivityIndexCache.load(from: url))
        XCTAssertEqual(loaded.signature, "store-a")
        XCTAssertNotEqual(loaded.signature, "store-b", "A changed store reads as stale")
        XCTAssertEqual(loaded.index.tracks.first?.id, index.tracks.first?.id)
        XCTAssertEqual(loaded.index.tracks.first?.mode, .cycling)
        XCTAssertEqual(loaded.index.tracks.first?.chunks.flatMap(\.points), index.tracks.first?.chunks.flatMap(\.points))
        XCTAssertEqual(loaded.index.stays.first?.point, index.stays.first?.point)
        XCTAssertEqual(loaded.index.excludedTripCount, 7)
        // A truncated or foreign file is ignored rather than trusted.
        try Data([1, 2, 3]).write(to: url)
        XCTAssertNil(MapActivityIndexCache.load(from: url))
        // An in-memory store has no file state to key on, so nothing is cached for it.
        XCTAssertNil(MapActivityIndexCache.signature(for: try makeContainer()))
    }

    @MainActor
    func testCachedBitmapsAreReusedOnlyForTheSameLevelAndIndex() throws {
        let controller = MapCoverageController()
        controller.adopt(MapActivityIndex())
        let container = try makeContainer()
        let base = request(.fog, metersPerPoint: 20)
        func update(_ request: MapCoverageRenderRequest) -> MapCoverageController.Update {
            .init(container: container, revision: 0, request: request, interval: DateInterval(start: .distantPast, end: .distantFuture), modes: nil, includeUndated: true)
        }
        let raster = try XCTUnwrap(MapCoverageRenderer.render(MapActivitySubset(tracks: [], stays: [], undatedCoverage: []), request: base))
        controller.remember(raster, for: controller.rasterKey(for: update(base)))
        XCTAssertNotNil(controller.cachedRaster(for: update(base)))
        // Panning a little stays inside the padded bitmap.
        var nudged = base
        nudged.viewport = base.viewport.insetBy(dx: -0, dy: 0)
        nudged.viewport.minX += base.viewport.width * 0.2
        nudged.viewport.maxX += base.viewport.width * 0.2
        XCTAssertNotNil(controller.cachedRaster(for: update(nudged)))
        // Panning a screen and a half away does not.
        var away = base
        away.viewport.minX += base.viewport.width * 1.5
        away.viewport.maxX += base.viewport.width * 1.5
        XCTAssertNil(controller.cachedRaster(for: update(away)))
        // Another zoom level, appearance, or layer does not.
        XCTAssertNil(controller.cachedRaster(for: update(request(.fog, metersPerPoint: 80))))
        var dark = base
        dark.isDark = true
        XCTAssertNil(controller.cachedRaster(for: update(dark)))
        XCTAssertNil(controller.cachedRaster(for: update(request(.heat, metersPerPoint: 20))))
        // A rebuilt index invalidates every bitmap.
        controller.adopt(MapActivityIndex())
        XCTAssertNil(controller.cachedRaster(for: update(base)))
        // So does a memory warning.
        controller.remember(raster, for: controller.rasterKey(for: update(base)))
        XCTAssertNotNil(controller.cachedRaster(for: update(base)))
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(controller.cachedRaster(for: update(base)))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func missingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("no-coverage-\(UUID().uuidString).json")
    }
}

private struct PixelReader {
    struct Point { let x: Int; let y: Int }
    let data: Data
    let bytesPerRow: Int
    let width: Int
    let height: Int

    init(_ image: CGImage) {
        data = image.dataProvider?.data as Data? ?? Data()
        bytesPerRow = image.bytesPerRow
        width = image.width
        height = image.height
    }

    func alpha(_ point: Point) -> UInt8 {
        let x = min(max(point.x, 0), width - 1), y = min(max(point.y, 0), height - 1)
        return data[y * bytesPerRow + x * 4 + 3]
    }
}
