import CloudKit
import CoreGraphics
import CoreLocation
import SwiftData
import QuickLookThumbnailing
import XCTest
@testable import Moves

final class PrivacyZoneTests: XCTestCase {
    func testHomeAndWorkBecomeZonesAndGymDoesNot() throws {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        let work = KnownPlace(name: "Office", latitude: 52.53, longitude: 13.42)
        work.category = KnownPlaceCategory.work.rawValue
        let gym = KnownPlace(name: "Gym", latitude: 52.525, longitude: 13.41)
        gym.category = KnownPlaceCategory.gym.rawValue

        let zones = PrivacyZoneResolver.zones(from: [home, work, gym])
        XCTAssertEqual(zones.map(\.name).sorted(), ["Home", "Office"])
        XCTAssertEqual(Set(zones.map(\.category)), [.home, .work])
    }

    func testShareZonesAreEmptyWhenPrivacyIsOff() {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        XCTAssertTrue(PrivacyZoneResolver.shareZones(from: [home], enabled: false).isEmpty)
        XCTAssertEqual(PrivacyZoneResolver.shareZones(from: [home], enabled: true).count, 1)
    }

    func testExportZonesHonorTheRawFixToggle() {
        let home = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        home.category = KnownPlaceCategory.home.rawValue
        XCTAssertTrue(
            PrivacyZoneResolver.exportZones(from: [home], enabled: true, hidesRawFixes: false).isEmpty
        )
        XCTAssertEqual(
            PrivacyZoneResolver.exportZones(from: [home], enabled: true, hidesRawFixes: true).count,
            1
        )
    }

    func testContainsUsesTheDefaultTwoHundredMetreRadius() {
        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.5200,
            longitude: 13.4050,
            radiusMeters: PrivacyZoneSettings.defaultRadiusMeters
        )
        let inside = CLLocationCoordinate2D(latitude: 52.5208, longitude: 13.4050)
        let outside = CLLocationCoordinate2D(latitude: 52.5300, longitude: 13.4050)
        XCTAssertTrue(zone.contains(inside))
        XCTAssertFalse(zone.contains(outside))
        XCTAssertTrue(
            PrivacyZoneResolver.containsRawFix(
                latitude: inside.latitude,
                longitude: inside.longitude,
                zones: [zone]
            )
        )
        XCTAssertFalse(
            PrivacyZoneResolver.containsRawFix(
                latitude: outside.latitude,
                longitude: outside.longitude,
                zones: [zone]
            )
        )
    }

    func testExportOmitsRawFixesInsideAPrivacyZone() throws {
        let home = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: Date(timeIntervalSince1970: 1_700_003_600),
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 8,
            userLabel: "Home"
        )
        let cafe = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_003_600),
            departureDate: Date(timeIntervalSince1970: 1_700_007_200),
            latitude: 52.53,
            longitude: 13.42,
            horizontalAccuracy: 8,
            userLabel: "Café"
        )
        let move = MoveSegment(
            dedupeKey: "walk",
            startDate: home.arrivalDate.addingTimeInterval(60),
            endDate: cafe.arrivalDate,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: nil
        )
        move.startPlace = home
        move.endPlace = cafe
        let inside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.5203, longitude: 13.4051),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: home.arrivalDate.addingTimeInterval(120)
            ),
            source: .significantChange,
            dedupeKey: "inside"
        )
        let outside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.5280, longitude: 13.4180),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: home.arrivalDate.addingTimeInterval(600)
            ),
            source: .significantChange,
            dedupeKey: "outside"
        )
        move.samples = [inside, outside]
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: home.arrivalDate))
        day.places = [home, cafe]
        day.moves = [move]

        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.52,
            longitude: 13.405,
            radiusMeters: 200
        )
        let payload = try XCTUnwrap(
            TimelineExporter.makePayload(
                days: [day],
                format: .gpx,
                fileStem: "privacy",
                privacyZones: [zone]
            )
        )
        let xml = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
        XCTAssertFalse(xml.contains("52.5203"))
        XCTAssertTrue(xml.contains("52.528"))
        XCTAssertFalse(xml.contains("52.520000"), "Home's own coordinates must not survive")
        XCTAssertFalse(xml.contains("<name>Home</name>"))
        XCTAssertTrue(xml.contains("52.530000"), "Places outside a zone stay")
    }

    func testEveryExportFormatLeavesOutPlacesInsideAPrivacyZone() throws {
        let fixture = makePrivateDay()

        for format in [TimelineExportFormat.gpx, .kml, .csv] {
            let payload = try XCTUnwrap(
                TimelineExporter.makePayload(
                    days: [fixture.day],
                    format: format,
                    fileStem: "privacy",
                    privacyZones: [fixture.zone]
                )
            )
            let text = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
            XCTAssertFalse(text.contains("52.5200"), "\(format) reveals Home")
            XCTAssertFalse(text.contains("13.4050"), "\(format) reveals Home")
            XCTAssertFalse(text.contains("Private notes"), "\(format) reveals the visit")
            XCTAssertTrue(text.contains("52.530000"), "\(format) lost the café")
            if format != .gpx {
                XCTAssertTrue(text.contains("\(KnownPlaceCategory.home.title) to Café"), "\(format) move title")
            }
        }

        let geoJSON = try XCTUnwrap(
            TimelineExporter.makePayload(
                days: [fixture.day],
                format: .geoJSON,
                fileStem: "privacy",
                privacyZones: [fixture.zone]
            )
        )
        let collection = try XCTUnwrap(JSONSerialization.jsonObject(with: geoJSON.data) as? [String: Any])
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let move = try XCTUnwrap(features.first { ($0["properties"] as? [String: Any])?["record_type"] as? String == "move" })
        XCTAssertEqual((move["properties"] as? [String: Any])?["start_place"] as? String, KnownPlaceCategory.home.title)
        for feature in features {
            let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
            let points = try (geometry["coordinates"] as? [[Double]])
                ?? [XCTUnwrap(geometry["coordinates"] as? [Double])]
            for point in points {
                let coordinate = CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                XCTAssertFalse(fixture.zone.contains(coordinate), "GeoJSON reveals \(point)")
            }
        }
    }

    func testZipPlacesAndSingleMoveExportLeaveOutPlacesInsideAPrivacyZone() throws {
        let fixture = makePrivateDay()
        let homePlace = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.405)
        homePlace.category = KnownPlaceCategory.home.rawValue
        let cafePlace = KnownPlace(name: "Café", latitude: 52.53, longitude: 13.42)

        let zip = try XCTUnwrap(
            TimelineExporter.makeZipPayload(
                days: [fixture.day],
                knownPlaces: [homePlace, cafePlace],
                photos: [],
                fileStem: "privacy",
                privacyZones: [fixture.zone]
            )
        )
        let members = try MovesZipArchive.unpack(zip.data)
        let placesFile = try XCTUnwrap(members.first { $0.path == "places.json" })
        let places = try XCTUnwrap(JSONSerialization.jsonObject(with: placesFile.data) as? [[String: Any]])
        XCTAssertEqual(places.compactMap { $0["name"] as? String }, ["Café"])
        for member in members where member.path != "places.json" && !member.path.hasSuffix(".geojson") {
            let text = try XCTUnwrap(String(data: member.data, encoding: .utf8))
            XCTAssertFalse(text.contains("52.5200"), "\(member.path) reveals Home")
        }

        let single = try XCTUnwrap(
            TimelineExporter.makeMoveGPXPayload(
                move: fixture.move,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                    CLLocationCoordinate2D(latitude: 52.528, longitude: 13.418),
                    CLLocationCoordinate2D(latitude: 52.53, longitude: 13.42),
                ],
                fileStem: "walk",
                privacyZones: [fixture.zone]
            )
        )
        let xml = try XCTUnwrap(String(data: single.data, encoding: .utf8))
        XCTAssertFalse(xml.contains("52.5200"))
        XCTAssertTrue(xml.contains("<name>\(KnownPlaceCategory.home.title) to Café</name>"))
        XCTAssertTrue(xml.contains("52.530000"))
    }

    func testExportsKeepEveryPlaceWhenNoZonesApply() throws {
        let fixture = makePrivateDay()
        let payload = try XCTUnwrap(
            TimelineExporter.makePayload(days: [fixture.day], format: .csv, fileStem: "open")
        )
        let text = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
        XCTAssertTrue(text.contains("52.520000"))
        XCTAssertTrue(text.contains("Private notes"))
    }

    /// An unlabeled Home, so its title is its coordinates, with a walk to a labeled café.
    private func makePrivateDay() -> (day: DayTimeline, move: MoveSegment, zone: PrivacyZone) {
        let home = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: Date(timeIntervalSince1970: 1_700_003_600),
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 8,
            comment: "Private notes"
        )
        let cafe = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_004_200),
            departureDate: Date(timeIntervalSince1970: 1_700_007_200),
            latitude: 52.53,
            longitude: 13.42,
            horizontalAccuracy: 8,
            userLabel: "Café"
        )
        let move = MoveSegment(
            dedupeKey: "walk",
            startDate: home.departureDate ?? home.arrivalDate,
            endDate: cafe.arrivalDate,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: nil
        )
        move.startPlace = home
        move.endPlace = cafe
        let outside = LocationSample(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.528, longitude: 13.418),
                altitude: 0,
                horizontalAccuracy: 8,
                verticalAccuracy: 4,
                timestamp: Date(timeIntervalSince1970: 1_700_003_900)
            ),
            source: .significantChange,
            dedupeKey: "outside"
        )
        move.samples = [outside]
        let day = DayTimeline(dayStart: Calendar.current.startOfDay(for: home.arrivalDate))
        day.places = [home, cafe]
        day.moves = [move]
        let zone = PrivacyZone(
            id: UUID(),
            name: "Home",
            category: .home,
            latitude: 52.52,
            longitude: 13.405,
            radiusMeters: 200
        )
        return (day, move, zone)
    }

    func testWidgetRouteLayoutFitsPointsInsideThePaddedRect() {
        let points = WidgetRouteLayout.project(
            latitudes: [-33.86, -33.87],
            longitudes: [151.21, 151.24],
            in: CGSize(width: 200, height: 100),
            padding: 10
        )
        XCTAssertEqual(points.count, 2)
        for point in points {
            XCTAssertGreaterThanOrEqual(point.x, 10)
            XCTAssertLessThanOrEqual(point.x, 190)
            XCTAssertGreaterThanOrEqual(point.y, 10)
            XCTAssertLessThanOrEqual(point.y, 90)
        }
        XCTAssertEqual(points[0].x, 10, accuracy: 0.5)
        XCTAssertEqual(points[1].x, 190, accuracy: 0.5)
    }

    func testICloudStatusUsesPlainLanguage() {
        let local = MovesICloudStatus.resolve(
            allowsPrivateMirror: false,
            isSimulator: false,
            sync: MovesICloudSyncState()
        )
        XCTAssertEqual(local, .localOnly)
        XCTAssertFalse(local.detail().localizedCaseInsensitiveContains("CloudKit"))
        XCTAssertTrue(local.detail().localizedCaseInsensitiveContains("iPhone"))

        let privateICloud = MovesICloudStatus.resolve(
            allowsPrivateMirror: true,
            isSimulator: false,
            sync: MovesICloudSyncState(lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        guard case .privateICloud = privateICloud else {
            return XCTFail("Expected private iCloud")
        }
        XCTAssertFalse(privateICloud.detail().localizedCaseInsensitiveContains("CloudKit"))
    }

    func testICloudSyncTimeComesFromFinishedTransfers() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        var sync = MovesICloudSyncState()
        let id = UUID()

        sync.apply(eventID: id, kind: .transfer, endDate: nil, succeeded: false, error: nil)
        XCTAssertTrue(sync.isSyncing)
        XCTAssertEqual(MovesICloudStatus.privateICloud(sync).detail(), "Syncing now.")

        sync.apply(eventID: id, kind: .transfer, endDate: end, succeeded: true, error: nil)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertEqual(sync.lastSyncedAt, end)
        XCTAssertEqual(
            MovesICloudStatus.privateICloud(sync).detail(now: end.addingTimeInterval(30)),
            "Synced just now."
        )
        XCTAssertTrue(
            MovesICloudStatus.privateICloud(sync)
                .detail(now: end.addingTimeInterval(2 * 60 * 60))
                .hasPrefix("Last synced 2 hours ago")
        )

        // Setting up the mirror moves no data, so it says nothing about the last sync.
        let setup = UUID()
        sync.apply(eventID: setup, kind: .setup, endDate: end.addingTimeInterval(60), succeeded: true, error: nil)
        XCTAssertEqual(sync.lastSyncedAt, end)
    }

    func testICloudSyncFailureKeepsTheLastSyncAndClearsOnSuccess() {
        let lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        var sync = MovesICloudSyncState(lastSyncedAt: lastSync)

        sync.apply(
            eventID: UUID(),
            kind: .transfer,
            endDate: lastSync.addingTimeInterval(60),
            succeeded: false,
            error: CKError(.networkUnavailable)
        )
        XCTAssertEqual(sync.problem, .offline)
        XCTAssertEqual(sync.lastSyncedAt, lastSync)
        XCTAssertTrue(MovesICloudStatus.privateICloud(sync).needsAttention)
        XCTAssertTrue(
            MovesICloudStatus.privateICloud(sync)
                .detail(now: lastSync.addingTimeInterval(2 * 60 * 60))
                .hasPrefix("Waiting for a connection. Last synced 2 hours ago")
        )

        let recovered = lastSync.addingTimeInterval(120)
        sync.apply(eventID: UUID(), kind: .transfer, endDate: recovered, succeeded: true, error: nil)
        XCTAssertNil(sync.problem)
        XCTAssertEqual(sync.lastSyncedAt, recovered)
    }

    func testICloudProblemsReadWrappedErrors() {
        typealias Problem = MovesICloudSyncState.Problem
        XCTAssertEqual(Problem(error: CKError(.quotaExceeded)), .storageFull)
        XCTAssertEqual(Problem(error: CKError(.notAuthenticated)), .signedOut)
        XCTAssertEqual(Problem(error: NSError(domain: NSCocoaErrorDomain, code: 134400)), .signedOut)
        XCTAssertEqual(Problem(error: NSError(domain: "Other", code: 1)), .other)
        XCTAssertEqual(Problem(error: nil), .other)

        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: 134407,
            userInfo: [NSUnderlyingErrorKey: CKError(.networkFailure) as NSError]
        )
        XCTAssertEqual(Problem(error: wrapped), .offline)

        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: ["record": CKError(.quotaExceeded)]]
        )
        XCTAssertEqual(Problem(error: partial), .storageFull)
    }

    func testICloudMultipleErrorsPreferActionableCauseOverNetworkFailure() {
        typealias Problem = MovesICloudSyncState.Problem
        let network = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            "network": network, "storage": CKError(.quotaExceeded),
        ]])
        let multiple = NSError(domain: NSCocoaErrorDomain, code: 134407, userInfo: [
            "NSMultipleUnderlyingErrors": [partial as NSError],
        ])
        XCTAssertEqual(Problem(error: multiple), .storageFull)
        XCTAssertEqual(Problem(error: network), .offline)
        let signedOut = NSError(domain: NSCocoaErrorDomain, code: 134407, userInfo: [
            "NSMultipleUnderlyingErrors": [multiple, CKError(.notAuthenticated) as NSError],
        ])
        XCTAssertEqual(Problem(error: signedOut), .signedOut)
        // Deferral is not proof of sign-out or a reason to reset the store.
        XCTAssertEqual(Problem(error: NSError(domain: NSCocoaErrorDomain, code: 134419)), .other)
        var nested = network
        for _ in 0..<8 { nested = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: nested]) }
        XCTAssertEqual(Problem(error: nested), .offline)
    }

    func testICloudAccountChangesShowAndClearSignedOut() {
        var sync = MovesICloudSyncState()
        sync.apply(accountStatus: .noAccount)
        XCTAssertEqual(sync.problem, .signedOut)
        XCTAssertEqual(MovesICloudStatus.privateICloud(sync).systemImage, "icloud.slash")

        sync.apply(accountStatus: .couldNotDetermine)
        XCTAssertEqual(sync.problem, .signedOut)

        sync.apply(accountStatus: .available)
        XCTAssertNil(sync.problem)
        XCTAssertEqual(MovesICloudStatus.privateICloud(sync).detail(), "Waiting for the first sync.")
    }
}

extension PrivacyZoneTests {
    func testUploadFailureIsNotHiddenBySuccessfulDownload() {
        var state = MovesICloudSyncState()
        let failureTime = Date(timeIntervalSince1970: 100)
        state.apply(eventID: UUID(), kind: .upload, endDate: failureTime, succeeded: false,
                    error: CKError(.quotaExceeded))
        state.apply(eventID: UUID(), kind: .download, endDate: failureTime.addingTimeInterval(1), succeeded: true, error: nil)
        XCTAssertEqual(state.problem, .storageFull)
        XCTAssertNil(state.lastUploadedAt)
        XCTAssertNotNil(state.lastDownloadedAt)
        state.apply(eventID: UUID(), kind: .upload, endDate: failureTime.addingTimeInterval(2), succeeded: true, error: nil)
        XCTAssertNil(state.problem)
        XCTAssertEqual(state.lastUploadedAt, failureTime.addingTimeInterval(2))
    }

    func testSpotlightSkipsLocationOnlySavesButRetainsPlaceChanges() throws {
        let sampleID = try PersistentIdentifier.identifier(for: "test", entityName: "LocationSample", primaryKey: "fix")
        let visitID = try PersistentIdentifier.identifier(for: "test", entityName: "VisitPlace", primaryKey: "visit")
        XCTAssertFalse(PlaceSaveFilter.touchesPlaces(Notification(name: ModelContext.didSave,
            userInfo: [ModelContext.NotificationKey.insertedIdentifiers: [sampleID]])))
        XCTAssertTrue(PlaceSaveFilter.touchesPlaces(Notification(name: ModelContext.didSave,
            userInfo: [ModelContext.NotificationKey.deletedIdentifiers.rawValue: Set([visitID])])))
        XCTAssertTrue(PlaceSaveFilter.touchesPlaces(Notification(name: ModelContext.didSave)))
    }

    func testImportQueueRecoversWithoutDiscardingUnreadableManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavedImportStore(directory: root)
        var interrupted = SavedImport(kind: .google, names: ["Timeline.json"])
        interrupted.state = .running
        var finished = SavedImport(kind: .routes, names: ["route.gpx"])
        finished.state = .completed
        try store.save([interrupted, finished])
        let restored = try store.load()
        XCTAssertEqual(restored.map(\.state), [.paused, .completed])
        XCTAssertEqual(restored.first?.id, interrupted.id)
        XCTAssertEqual(store.sources(for: interrupted).first?.lastPathComponent, "Timeline.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: store.manifest)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.manifest), corrupt)
    }

    func testCancellingImportWaitCancelsItsDetachedWriter() async throws {
        let task = Task {
            try await importWorkerValue(Task.detached {
                try await Task.sleep(for: .seconds(60))
                return true
            })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled worker must stop") }
        catch is CancellationError { }
    }

    func testCalendarNavigationIncludesGapsAcrossDaylightSavingWithoutModels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let dates = TimelineBrowsingDay.days(from: start, through: end, calendar: calendar)
        XCTAssertEqual(dates.count, 4)
        XCTAssertEqual(dates.map { calendar.component(.day, from: $0.dayStart) }, [7, 8, 9, 10])
        XCTAssertEqual(dates[2].dayStart.timeIntervalSince(dates[1].dayStart), 23 * 3600)
    }
}

extension PrivacyZoneTests {
    func testFineExplorationRasterWrapsLongitudeAndUsesLatitudeAwareArea() throws {
        let west = try FogRasterV1.address(for: .init(latitude: 0, longitude: -180))
        let east = try FogRasterV1.address(for: .init(latitude: 0, longitude: 180))
        XCTAssertEqual(west.cell, east.cell)
        let equator = try FogRasterV1.address(for: .init(latitude: 0, longitude: 10))
        let north = try FogRasterV1.address(for: .init(latitude: 60, longitude: 10))
        XCTAssertGreaterThan(try FogRasterV1.areaSquareMeters(for: equator.cell), try FogRasterV1.areaSquareMeters(for: north.cell))
        let bounds = try FogRasterV1.geographicBounds(for: equator.cell)
        XCTAssertLessThan(bounds.east - bounds.west, 0.0001)
        XCTAssertThrowsError(try FogRasterV1.address(for: .init(latitude: .nan, longitude: 0)))
    }
}

extension PrivacyZoneTests {
    func testOfflineCountryLookupUsesVisitsAndDoesNotGuessOcean() {
        XCTAssertEqual(OfflineVisitGeography.country(latitude: 37.77, longitude: -122.42), "US")
        XCTAssertEqual(OfflineVisitGeography.country(latitude: -33.86, longitude: 151.21), "AU")
        XCTAssertNil(OfflineVisitGeography.country(latitude: 0, longitude: -140))
        XCTAssertNil(OfflineVisitGeography.country(latitude: nil, longitude: nil))
    }
}

extension PrivacyZoneTests {
    func testFogExportOmitsPrivacyZoneCellsAndFlightObservations() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let now = Date()
        let coordinates = [CLLocationCoordinate2D(latitude: 37.77, longitude: -122.42),
                           .init(latitude: 37.79, longitude: -122.42), .init(latitude: 37.82, longitude: -122.42)]
        let flight = MoveSegment(dedupeKey: "flight", startDate: now, endDate: now.addingTimeInterval(60), transportMode: .plane, distanceMeters: 1000, stepCount: nil)
        context.insert(flight)
        for (i, coordinate) in coordinates.enumerated() {
            let fix = LocationSample(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), source: .routeTracking, dedupeKey: "fix-\(i)")
            context.insert(fix)
            if i == 2 { fix.moveSegment = flight }
        }
        try context.save()
        let zone = PrivacyZone(id: UUID(), name: "Home", category: .home, latitude: 37.77, longitude: -122.42, radiusMeters: 200)
        let blocks = try FogCoverageArchive.exportBlocks(container: container,
            importedURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), privacyZones: [zone])
        func included(_ coordinate: CLLocationCoordinate2D) throws -> Bool {
            let a = try FogRasterV1.address(for: coordinate)
            return blocks.contains {
                $0.tileID == Int(a.baseTile.y) * 512 + Int(a.baseTile.x)
                    && $0.localX == Int(a.block.localBlockX) && $0.localY == Int(a.block.localBlockY)
                    && $0.bitmap.contains(x: Int(a.localCellX), y: Int(a.localCellY))
            }
        }
        XCTAssertFalse(try included(coordinates[0]))
        XCTAssertTrue(try included(coordinates[1]))
        XCTAssertFalse(try included(coordinates[2]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocationSample>()), 3)
    }
}


extension PrivacyZoneTests {
    @MainActor
    func testStagedImportSurvivesRelaunchAndDoesNotNeedOriginalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("walk.gpx")
        try Data("""
        <gpx version="1.1"><trk><trkseg>
        <trkpt lat="37.77" lon="-122.42"><time>2026-10-01T10:00:00Z</time></trkpt>
        <trkpt lat="37.78" lon="-122.42"><time>2026-10-01T10:10:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """.utf8).write(to: source)
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let directory = root.appendingPathComponent("queue")
        let original = DurableImportQueue(container: container, directory: directory)
        original.sceneChanged(.inactive)
        try await original.enqueue([source], kind: .routes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(original.jobs.first?.state, .queued)
        try FileManager.default.removeItem(at: source)
        let restored = DurableImportQueue(container: container, directory: directory)
        let id = try XCTUnwrap(restored.jobs.first?.id)
        XCTAssertEqual(restored.jobs.first?.state, .paused)
        restored.resume(id)
        for _ in 0..<200 {
            if restored.jobs.first?.state == .completed || restored.jobs.first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(restored.jobs.first?.state, .completed, restored.jobs.first?.message ?? "")
        let count = try ModelContext(container).fetchCount(FetchDescriptor<LocationSample>())
        XCTAssertGreaterThan(count, 0)
        restored.resume(id)
        XCTAssertEqual(restored.jobs.first?.state, .completed)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<LocationSample>()), count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SavedImportStore(directory: directory).folder(for: id).path))
    }

    func testCorruptCoverageAddressFailsWithoutTrappingOrReplacingData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try JSONEncoder().encode([FogCoverageArchive.Record(tileID: -1, x: 0, y: 0, bytes: Data(repeating: 0, count: 512))])
        try data.write(to: url)
        XCTAssertThrowsError(try FogCoverageArchive.load(from: url))
        XCTAssertThrowsError(try FogCoverageArchive.merge([], at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testAccountChangeCannotHideQuotaFailure() {
        var state = MovesICloudSyncState()
        state.apply(eventID: UUID(), kind: .upload, endDate: Date(), succeeded: false, error: CKError(.quotaExceeded))
        state.apply(accountStatus: .noAccount)
        XCTAssertEqual(state.problem, .signedOut)
        state.apply(eventID: UUID(), kind: .download, endDate: Date(), succeeded: true, error: nil)
        XCTAssertEqual(state.problem, .signedOut)
        state.apply(accountStatus: .available)
        XCTAssertEqual(state.problem, .storageFull)
    }
}


extension PrivacyZoneTests {
    @MainActor
    func testInstalledRouteThumbnailExtensionRendersGPX() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString).gpx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        <gpx version="1.1"><trk><trkseg><trkpt lat="37.77" lon="-122.42"/><trkpt lat="37.78" lon="-122.41"/><trkpt lat="37.79" lon="-122.42"/></trkseg></trk></gpx>
        """.utf8).write(to: url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 240), scale: 1, representationTypes: .thumbnail)
        let finished = expectation(description: "Quick Look route thumbnail")
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            XCTAssertNil(error)
            XCTAssertEqual(representation?.type, .thumbnail)
            if let image = representation?.uiImage {
                let attachment = XCTAttachment(image: image)
                attachment.name = "GPX route thumbnail"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 60)
        QLThumbnailGenerator.shared.cancel(request)
    }
}
