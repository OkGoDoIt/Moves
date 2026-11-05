import CoreLocation
import CoreSpotlight
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Moves

final class WebhookSyncTests: XCTestCase {
    override func tearDown() {
        WebhookURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRemoteHTTPIsRejected() {
        XCTAssertThrowsError(try WebhookEndpoint.make(from: "http://example.com/hook")) { error in
            guard case WebhookSyncError.insecureRemoteServer = error else {
                return XCTFail("Expected insecureRemoteServer, got \(error)")
            }
        }
    }

    func testLocalHTTPAndRemoteHTTPSAreAllowed() throws {
        let local = try WebhookEndpoint.make(from: "http://192.168.1.20:8080/moves")
        XCTAssertEqual(local.url.absoluteString, "http://192.168.1.20:8080/moves")

        let remote = try WebhookEndpoint.make(from: "https://hooks.example.com/moves?token=1")
        XCTAssertEqual(remote.url.host, "hooks.example.com")
        XCTAssertEqual(remote.url.query, "token=1")
    }

    func testOwnTracksLocationEncodingIsReused() throws {
        let payload = OwnTracksLocationPayload(
            sample: makeSample(),
            deviceID: "moves-device"
        )
        let object = try jsonObject(from: payload)

        XCTAssertEqual(object["_type"] as? String, "location")
        XCTAssertEqual(object["lat"] as? Double, 52.52)
        XCTAssertEqual(object["lon"] as? Double, 13.405)
        XCTAssertEqual(object["tid"] as? String, "moves-device")
        XCTAssertEqual(object["acc"] as? Double, 7)
        XCTAssertEqual(try XCTUnwrap(object["vel"] as? Double), 16.2, accuracy: 0.001)
        XCTAssertEqual(object["tst"] as? Int, 1_735_000_000)
    }

    func testOwnTracksTransitionEncoding() throws {
        let visit = makeVisit(name: "Home")
        let payload = OwnTracksTransitionPayload(visit: visit, event: "enter", deviceID: "phone")
        let object = try jsonObject(from: payload)

        XCTAssertEqual(object["_type"] as? String, "transition")
        XCTAssertEqual(object["event"] as? String, "enter")
        XCTAssertEqual(object["desc"] as? String, "Home")
        XCTAssertEqual(object["tid"] as? String, "phone")
        XCTAssertEqual(object["t"] as? String, "c")
        XCTAssertEqual(object["rid"] as? String, visit.id.uuidString)
        XCTAssertEqual(object["lat"] as? Double, 52.52)
        XCTAssertEqual(object["lon"] as? Double, 13.405)
        XCTAssertEqual(object["tst"] as? Int, 1_735_000_000)
    }

    func testNativeVisitAndMoveEncodingOmitsFullSampleDump() throws {
        let home = makeVisit(name: "Home")
        let cafe = makeVisit(
            name: "Café",
            latitude: 52.53,
            longitude: 13.41,
            arrival: Date(timeIntervalSince1970: 1_735_003_600)
        )
        let move = MoveSegment(
            dedupeKey: "walk",
            startDate: home.arrivalDate.addingTimeInterval(60 * 60),
            endDate: cafe.arrivalDate,
            transportMode: .walking,
            distanceMeters: 1_250,
            stepCount: 1_600
        )
        move.startPlace = home
        move.endPlace = cafe

        let native = MovesNativeTimelineJSON(
            visits: [MovesNativeVisitJSON(visit: home), MovesNativeVisitJSON(visit: cafe)],
            moves: [MovesNativeMoveJSON(move: move, route: WebhookRouteSimplifier.geoJSONLine(for: move))]
        )
        let object = try jsonObject(from: native)
        let visits = try XCTUnwrap(object["visits"] as? [[String: Any]])
        let moves = try XCTUnwrap(object["moves"] as? [[String: Any]])
        let firstVisit = try XCTUnwrap(visits.first)
        let firstMove = try XCTUnwrap(moves.first)

        XCTAssertEqual(firstVisit["id"] as? String, home.id.uuidString)
        XCTAssertEqual(firstVisit["name"] as? String, "Home")
        XCTAssertEqual(firstVisit["latitude"] as? Double, 52.52)
        XCTAssertNotNil(firstVisit["arrival"] as? String)
        XCTAssertNil(firstVisit["samples"])

        XCTAssertEqual(firstMove["mode"] as? String, "walking")
        XCTAssertEqual(firstMove["start_place"] as? String, "Home")
        XCTAssertEqual(firstMove["end_place"] as? String, "Café")
        XCTAssertEqual(firstMove["distance_meters"] as? Double, 1_250)
        XCTAssertNil(firstMove["samples"])
        let route = try XCTUnwrap(firstMove["route"] as? [[Double]])
        XCTAssertEqual(route.count, 2)
        XCTAssertEqual(route[0], [13.405, 52.52])
        XCTAssertEqual(route[1], [13.41, 52.53])
    }

    func testRouteSimplifierKeepsEndpointsAndCapsVertices() {
        let coordinates = (0..<100).map {
            CLLocationCoordinate2D(latitude: 52 + Double($0) * 0.001, longitude: 13 + Double($0) * 0.001)
        }
        let simplified = WebhookRouteSimplifier.downsample(coordinates, maxVertexCount: 32)
        XCTAssertEqual(simplified.count, 32)
        XCTAssertEqual(simplified.first?.latitude ?? 0, coordinates.first?.latitude ?? 1, accuracy: 0.000_000_1)
        XCTAssertEqual(simplified.last?.latitude ?? 0, coordinates.last?.latitude ?? 1, accuracy: 0.000_000_1)
    }

    func testWebhookClientPostsOwnTracksThenNativeWithBearer() async throws {
        var bodies: [Data] = []
        var methods: [String] = []
        var auths: [String?] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            auths.append(request.value(forHTTPHeaderField: "Authorization"))
            if let body = request.httpBody {
                bodies.append(body)
            } else if let stream = request.httpBodyStream {
                bodies.append(Data(reading: stream))
            }
            XCTAssertEqual(request.url?.absoluteString, "https://hooks.example.com/moves")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (Data(), 204, [:])
        }

        let sample = makeSample()
        let visit = makeVisit(name: "Home")
        let native = MovesNativeTimelineJSON(
            visits: [MovesNativeVisitJSON(visit: visit)],
            moves: []
        )
        let endpoint = try WebhookEndpoint.make(from: "https://hooks.example.com/moves")

        try await client.upload(
            ownTracksLocations: [OwnTracksLocationPayload(sample: sample, deviceID: "tid")],
            transitions: [OwnTracksTransitionPayload(visit: visit, event: "enter", deviceID: "tid")],
            native: native,
            endpoint: endpoint,
            bearerToken: "secret"
        )

        XCTAssertEqual(methods, ["POST", "POST", "POST"])
        XCTAssertEqual(auths, ["Bearer secret", "Bearer secret", "Bearer secret"])
        XCTAssertEqual(bodies.count, 3)

        let location = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(location["_type"] as? String, "location")

        let transition = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        XCTAssertEqual(transition["_type"] as? String, "transition")
        XCTAssertEqual(transition["event"] as? String, "enter")

        let nativeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[2]) as? [String: Any])
        XCTAssertEqual((nativeObject["visits"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((nativeObject["moves"] as? [Any])?.count, 0)
    }

    func testPayloadOptionsDefaultToBothEnvelopesOn() {
        let options = WebhookPayloadOptions()
        XCTAssertTrue(options.sendOwnTracksLocations)
        XCTAssertTrue(options.sendOwnTracksTransitions)
        XCTAssertTrue(options.sendNativeTimeline)
    }

    func testZipRoundTripAndKMLExport() throws {
        let day = DayTimeline(dayStart: Date(timeIntervalSince1970: 1_735_000_000))
        let place = makeVisit(name: "Home")
        place.dayTimeline = day
        day.places = [place]

        let zip = try XCTUnwrap(
            TimelineExporter.makeZipPayload(
                days: [day],
                knownPlaces: [],
                photos: [],
                fileStem: "moves-all-days"
            )
        )
        XCTAssertEqual(zip.filename, "moves-all-days.zip")
        XCTAssertEqual(zip.contentType, .zip)

        let members = try MovesZipArchive.unpack(zip.data)
        let names = Set(members.map(\.path))
        XCTAssertTrue(names.contains("moves-all-days.gpx"))
        XCTAssertTrue(names.contains("moves-all-days.geojson"))
        XCTAssertTrue(names.contains("moves-all-days.csv"))
        XCTAssertTrue(names.contains("moves-all-days.kml"))
        XCTAssertTrue(names.contains("places.json"))
        XCTAssertTrue(names.contains("photos.csv"))

        let expanded = TimelineArchiveFileParser.expandZipMembers(in: [("moves-all-days.zip", zip.data)])
        XCTAssertTrue(expanded.contains(where: { $0.name.hasSuffix(".gpx") }))
        XCTAssertFalse(expanded.contains(where: { $0.name == "places.json" }))

        // Restoring the zip reads its three timeline files and reports nothing as skipped.
        let parsed = TimelineArchiveFileParser.parseAll(files: [("moves-all-days.zip", zip.data)])
        XCTAssertEqual(parsed.parsedFileCount, 3)
        XCTAssertEqual(parsed.skipped, [])
        XCTAssertEqual(parsed.warnings, [])
        XCTAssertFalse(parsed.archive.isEmpty)

        // A KML picked on its own still says it could not be restored.
        let picked = TimelineArchiveFileParser.parseAll(
            files: [("day.kml", Data("<kml></kml>".utf8))]
        )
        XCTAssertEqual(picked.parsedFileCount, 0)
        XCTAssertEqual(picked.skipped, ["day.kml"])

        let kml = try XCTUnwrap(TimelineExporter.makePayload(days: [day], format: .kml, fileStem: "day"))
        let xml = try XCTUnwrap(String(data: kml.data, encoding: .utf8))
        XCTAssertTrue(xml.contains("<kml"))
        XCTAssertTrue(xml.contains("Home"))
        XCTAssertTrue(xml.contains("<Point>"))
    }

    func testWhereWasIOmitsCoordinatesUnlessOptedIn() {
        let visit = makeVisit(name: "Home")
        let at = visit.arrivalDate.addingTimeInterval(60)
        let hidden = TimelineMomentSummary.text(
            result: .visit(visit),
            at: at,
            includeCoordinates: false
        )
        XCTAssertTrue(hidden.contains("Home"))
        XCTAssertFalse(hidden.contains("52.52"))
        XCTAssertFalse(hidden.contains("13.405"))

        let shown = TimelineMomentSummary.text(
            result: .visit(visit),
            at: at,
            includeCoordinates: true
        )
        XCTAssertTrue(shown.contains("52.52000"))
        XCTAssertTrue(shown.contains("13.40500"))
    }

    // MARK: History stays on the device until a confirmed upload

    func testAutomaticFilterKeepsLiveSamplesAndLeavesOutImports() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let now = Date.now
        let longAgo = now.addingTimeInterval(-400 * 24 * 60 * 60)
        for source in LocationSampleSource.allCases {
            context.insert(makeSample(source: source, latitude: 52.52, timestamp: longAgo))
        }
        context.insert(makeSample(source: .healthWorkoutRoute, latitude: 52.53, timestamp: now))
        try context.save()
        let cursor = now.addingTimeInterval(-60)

        let automatic = try context.fetch(
            FetchDescriptor<LocationSample>(
                predicate: LocationUploadFilter.samples(after: cursor, includingHistory: false)
            )
        )
        XCTAssertEqual(
            Set(automatic.map(\.source)),
            [
                .visit, .significantChange, .routeTracking, .watchRouteTracking, .watchSignificantChange,
                .launchBackfill, .authorizationGrant, .lastMile, .healthWorkoutRoute,
            ]
        )
        XCTAssertEqual(
            automatic.filter { $0.source == .healthWorkoutRoute }.map(\.latitude),
            [52.53],
            "A fresh workout uploads; a historical Health import does not"
        )

        let confirmed = try context.fetch(
            FetchDescriptor<LocationSample>(
                predicate: LocationUploadFilter.samples(after: .distantPast, includingHistory: true)
            )
        )
        XCTAssertEqual(confirmed.count, LocationSampleSource.allCases.count + 1)
    }

    func testRecentRestoresAndGPSFilesStayOutOfAutomaticUploads() throws {
        let start = Date.now.addingTimeInterval(-6 * 60 * 60)
        let walkStart = start.addingTimeInterval(2 * 60 * 60)
        let walk = SyntheticLog.leg(
            from: SyntheticLog.home,
            bearingNorthMeters: 1_400,
            from: walkStart,
            minutes: 20,
            stepMinutes: 2
        )
        var points = SyntheticLog.stay(at: SyntheticLog.home, from: start, minutes: 120)
        points += walk.dropFirst()
        points += SyntheticLog.stay(at: SyntheticLog.cafe, from: walk.last!.timestamp, minutes: 60).dropFirst()

        // GPS file with stays and moves.
        let logContainer = try makeInMemoryContainer()
        _ = try SwiftDataTimelineRepository(modelContainer: logContainer).importLocationLog(
            LocationLogSegmenter().segment(points),
            source: .fileRouteImport
        )
        try assertAllImportedAndNotUploaded(in: logContainer)

        // GPS file with a bare track.
        let trackContainer = try makeInMemoryContainer()
        _ = try SwiftDataTimelineRepository(modelContainer: trackContainer).importRouteTrack(
            locations: walk.map(\.location),
            source: .fileRouteImport,
            transportMode: .walking
        )
        try assertAllImportedAndNotUploaded(in: trackContainer)

        // Moves export.
        let archiveContainer = try makeInMemoryContainer()
        let archive = TimelineArchive(
            places: [
                TimelineArchivePlace(
                    arrivalDate: start,
                    departureDate: walkStart,
                    latitude: SyntheticLog.home.latitude,
                    longitude: SyntheticLog.home.longitude,
                    userLabel: "Home",
                    source: .geoJSON
                ),
            ],
            moves: [
                TimelineArchiveMove(
                    startDate: walkStart,
                    endDate: walk.last!.timestamp,
                    transportMode: .walking,
                    points: walk.map {
                        TimelineArchivePoint(
                            latitude: $0.coordinate.latitude,
                            longitude: $0.coordinate.longitude,
                            timestamp: $0.timestamp
                        )
                    },
                    source: .gpx
                ),
            ],
            formats: [.gpx, .geoJSON]
        )
        _ = try SwiftDataTimelineRepository(modelContainer: archiveContainer).importTimelineArchive(archive)
        try assertAllImportedAndNotUploaded(in: archiveContainer)
    }

    func testImportsLeaveARecordedVisitMarkedAsRecorded() throws {
        let start = Date.now.addingTimeInterval(-6 * 60 * 60)
        let end = start.addingTimeInterval(2 * 60 * 60)
        let coordinate = SyntheticLog.home

        func recordedVisit(in container: ModelContainer) throws -> ModelContext {
            let context = ModelContext(container)
            let visit = VisitPlace(
                arrivalDate: start,
                departureDate: end,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                horizontalAccuracy: 20
            )
            context.insert(visit)
            try context.save()
            return context
        }

        let archiveContainer = try makeInMemoryContainer()
        let archiveContext = try recordedVisit(in: archiveContainer)
        _ = try SwiftDataTimelineRepository(modelContainer: archiveContainer).importTimelineArchive(
            TimelineArchive(
                places: [
                    TimelineArchivePlace(
                        arrivalDate: start,
                        departureDate: end,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        userLabel: "Home",
                        source: .geoJSON
                    ),
                ],
                moves: [],
                formats: [.geoJSON]
            )
        )
        XCTAssertEqual(try archiveContext.fetch(FetchDescriptor<VisitPlace>()).map(\.origin), [.sensor])

        let logContainer = try makeInMemoryContainer()
        let logContext = try recordedVisit(in: logContainer)
        let timeline = LocationLogSegmenter().segment(SyntheticLog.stay(at: coordinate, from: start, minutes: 120))
        _ = try SwiftDataTimelineRepository(modelContainer: logContainer)
            .importLocationLog(timeline, source: .fileRouteImport)
        XCTAssertEqual(try logContext.fetch(FetchDescriptor<VisitPlace>()).map(\.origin), [.sensor])
    }

    private func assertAllImportedAndNotUploaded(
        in container: ModelContainer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertFalse(visits.isEmpty, file: file, line: line)
        XCTAssertFalse(moves.isEmpty, file: file, line: line)
        XCTAssertTrue(visits.allSatisfy { $0.origin == .imported }, file: file, line: line)
        XCTAssertTrue(moves.allSatisfy { $0.origin == .imported }, file: file, line: line)

        let uploadableVisits = try context.fetch(
            FetchDescriptor<VisitPlace>(
                predicate: LocationUploadFilter.visits(after: .distantPast, includingHistory: false)
            )
        )
        let uploadableMoves = try context.fetch(
            FetchDescriptor<MoveSegment>(
                predicate: LocationUploadFilter.moves(after: .distantPast, includingHistory: false)
            )
        )
        XCTAssertEqual(uploadableVisits.count, 0, file: file, line: line)
        XCTAssertEqual(uploadableMoves.count, 0, file: file, line: line)

        // Only Google Timeline's guesses go to the Review inbox.
        XCTAssertEqual(ReviewInboxBuilder.items(visits: visits, moves: moves).count, 0, file: file, line: line)
    }

    func testAutomaticFilterLeavesOutImportedVisitsAndMoves() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let now = Date.now
        let longAgo = now.addingTimeInterval(-400 * 24 * 60 * 60)

        let live = makeVisit(name: "Live", arrival: now.addingTimeInterval(-3_600))
        let googleVisit = makeVisit(name: "Google", arrival: now.addingTimeInterval(-3_600))
        googleVisit.origin = .imported
        let photoVisit = makeVisit(name: "Photo", arrival: now.addingTimeInterval(-3_600))
        photoVisit.origin = .photoInferred
        let restoredVisit = makeVisit(name: "Restored", arrival: longAgo)
        for visit in [live, googleVisit, photoVisit, restoredVisit] {
            context.insert(visit)
        }

        let liveMove = makeMove(key: "live", end: now)
        let googleMove = makeMove(key: "google", end: now)
        googleMove.origin = .imported
        let restoredMove = makeMove(key: "restored", end: longAgo)
        for move in [liveMove, googleMove, restoredMove] {
            context.insert(move)
        }
        try context.save()
        let cursor = now.addingTimeInterval(-60)

        let visits = try context.fetch(
            FetchDescriptor<VisitPlace>(predicate: LocationUploadFilter.visits(after: cursor, includingHistory: false))
        )
        XCTAssertEqual(visits.map(\.userLabel), ["Live"])
        let allVisits = try context.fetch(
            FetchDescriptor<VisitPlace>(predicate: LocationUploadFilter.visits(after: .distantPast, includingHistory: true))
        )
        XCTAssertEqual(allVisits.count, 4)

        let moves = try context.fetch(
            FetchDescriptor<MoveSegment>(predicate: LocationUploadFilter.moves(after: cursor, includingHistory: false))
        )
        XCTAssertEqual(moves.map(\.dedupeKey), ["live"])
        let allMoves = try context.fetch(
            FetchDescriptor<MoveSegment>(predicate: LocationUploadFilter.moves(after: .distantPast, includingHistory: true))
        )
        XCTAssertEqual(allMoves.count, 3)
    }

    @MainActor
    func testWebhookSendsLivePointsAndSavesImportsForAConfirmedUpload() async throws {
        let container = try makeInMemoryContainer()
        let defaults = makeDefaults()
        defaults.set("https://hooks.example.com/moves", forKey: "Moves.webhook.serverURL")
        defaults.set(false, forKey: "Moves.webhook.sendTransitions")
        defaults.set(false, forKey: "Moves.webhook.sendNative")
        defaults.set(Date.now.addingTimeInterval(-60), forKey: "Moves.webhook.sampleCursor")

        var latitudes: [Double] = []
        let client = makeClient { request in
            if let object = try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any],
               let latitude = object["lat"] as? Double {
                latitudes.append(latitude)
            }
            return (Data(), 204, [:])
        }
        let manager = WebhookSyncManager(modelContainer: container, defaults: defaults, client: client)

        let context = ModelContext(container)
        context.insert(makeSample(source: .watchRouteTracking, latitude: 1, timestamp: .now))
        context.insert(makeSample(source: .googleTimelineImport, latitude: 2, timestamp: .now))
        context.insert(makeSample(source: .fileRouteImport, latitude: 3, timestamp: .now))
        try context.save()

        await manager.syncNewItemsNow()
        XCTAssertFalse(manager.state.lastOperationFailed, manager.state.lastMessage)
        XCTAssertEqual(latitudes, [1])

        latitudes = []
        await manager.syncAllHistory()
        XCTAssertFalse(manager.state.lastOperationFailed, manager.state.lastMessage)
        XCTAssertEqual(Set(latitudes), [1, 2, 3])
    }

    @MainActor
    func testLocationServiceSendsLivePointsAndSavesImportsForAConfirmedUpload() async throws {
        let container = try makeInMemoryContainer()
        let defaults = makeDefaults()
        defaults.set("https://traccar.example.com:5144", forKey: "Moves.locationServices.traccar.serverURL")
        defaults.set("phone", forKey: "Moves.locationServices.traccar.deviceID")
        defaults.set(Date.now.addingTimeInterval(-60), forKey: "Moves.locationServices.traccar.uploadCursor")

        var latitudes: [Double] = []
        WebhookURLProtocolStub.handler = { request in
            if let object = try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any],
               let latitude = object["lat"] as? Double {
                latitudes.append(latitude)
            }
            return (Data(), 200, [:])
        }
        let manager = LocationServiceSyncManager(
            modelContainer: container,
            defaults: defaults,
            client: LocationServiceAPIClient(session: makeStubbedSession())
        )

        let context = ModelContext(container)
        context.insert(makeSample(source: .routeTracking, latitude: 1, timestamp: .now))
        context.insert(makeSample(source: .photoLibrary, latitude: 2, timestamp: .now))
        try context.save()

        await manager.syncNewSamplesNow(.traccar)
        XCTAssertFalse(manager.state(for: .traccar).lastOperationFailed, manager.state(for: .traccar).lastMessage)
        XCTAssertEqual(latitudes, [1])

        latitudes = []
        await manager.syncAllHistory(.traccar)
        XCTAssertFalse(manager.state(for: .traccar).lastOperationFailed, manager.state(for: .traccar).lastMessage)
        XCTAssertEqual(Set(latitudes), [1, 2])
    }

    @MainActor
    func testTurningAutomaticUploadsOnStartsFromNow() throws {
        let container = try makeInMemoryContainer()
        let defaults = makeDefaults()
        let stale = Date(timeIntervalSince1970: 1_600_000_000)
        for key in ["sampleCursor", "visitCursor", "moveCursor", "leaveCursor"] {
            defaults.set(stale, forKey: "Moves.webhook.\(key)")
        }
        defaults.set(stale, forKey: "Moves.locationServices.traccar.uploadCursor")

        let webhook = WebhookSyncManager(modelContainer: container, defaults: defaults)
        webhook.setAutomaticSyncEnabled(true)
        for key in ["sampleCursor", "visitCursor", "moveCursor", "leaveCursor"] {
            let cursor = try XCTUnwrap(defaults.object(forKey: "Moves.webhook.\(key)") as? Date)
            XCTAssertGreaterThan(cursor, stale, key)
        }
        webhook.setAutomaticSyncEnabled(false)

        let services = LocationServiceSyncManager(modelContainer: container, defaults: defaults)
        services.setAutomaticSyncEnabled(true, for: .traccar)
        let cursor = try XCTUnwrap(defaults.object(forKey: "Moves.locationServices.traccar.uploadCursor") as? Date)
        XCTAssertGreaterThan(cursor, stale)
        services.setAutomaticSyncEnabled(false, for: .traccar)
    }

    @MainActor
    func testTurningAPayloadBackOnDoesNotSendTheGap() throws {
        let defaults = makeDefaults()
        let manager = WebhookSyncManager(modelContainer: try makeInMemoryContainer(), defaults: defaults)
        var options = manager.payloadOptions()
        options.sendOwnTracksLocations = false
        manager.setPayloadOptions(options)

        let stale = Date(timeIntervalSince1970: 1_600_000_000)
        defaults.set(stale, forKey: "Moves.webhook.sampleCursor")
        defaults.set(stale, forKey: "Moves.webhook.moveCursor")

        options.sendOwnTracksLocations = true
        manager.setPayloadOptions(options)

        let sampleCursor = try XCTUnwrap(defaults.object(forKey: "Moves.webhook.sampleCursor") as? Date)
        XCTAssertGreaterThan(sampleCursor, stale)
        XCTAssertEqual(defaults.object(forKey: "Moves.webhook.moveCursor") as? Date, stale, "Moves were never off")
    }

    @MainActor
    func testLateCreatedVisitPostsBothEnterAndLeave() async throws {
        let container = try makeInMemoryContainer()
        let defaults = makeDefaults()
        let now = Date.now
        defaults.set("https://hooks.example.com/moves", forKey: "Moves.webhook.serverURL")
        defaults.set(false, forKey: "Moves.webhook.sendOwnTracks")
        defaults.set(false, forKey: "Moves.webhook.sendNative")
        defaults.set(now.addingTimeInterval(-60), forKey: "Moves.webhook.visitCursor")
        defaults.set(now.addingTimeInterval(-60), forKey: "Moves.webhook.leaveCursor")

        var events: [String] = []
        let client = makeClient { request in
            if let object = try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any],
               let event = object["event"] as? String {
                events.append(event)
            }
            return (Data(), 204, [:])
        }
        let manager = WebhookSyncManager(modelContainer: container, defaults: defaults, client: client)

        let context = ModelContext(container)
        // Departed two hours ago, well before the leave cursor, but only created just now.
        context.insert(makeVisit(name: "Reconciled", arrival: now.addingTimeInterval(-3 * 3_600)))
        try context.save()

        await manager.syncNewItemsNow()
        XCTAssertFalse(manager.state.lastOperationFailed, manager.state.lastMessage)
        XCTAssertEqual(events, ["enter", "leave"])
    }

    // MARK: Saved secrets

    @MainActor
    func testWebhookKeepsItsTokenOnTheSameServerAndDropsItForANewOne() async throws {
        var auth: [String: String?] = [:]
        let client = makeClient { request in
            auth[request.url?.absoluteString ?? ""] = request.value(forHTTPHeaderField: "Authorization")
            return (Data(), 204, [:])
        }
        let manager = WebhookSyncManager(
            modelContainer: try makeInMemoryContainer(),
            defaults: makeDefaults(),
            client: client
        )
        defer { try? manager.disconnect() }

        try await manager.connect(urlString: "https://a.example.com/hook", bearerToken: "secret")
        XCTAssertEqual(auth["https://a.example.com/hook"], "Bearer secret")

        try await manager.connect(urlString: "https://a.example.com/other", bearerToken: "")
        XCTAssertEqual(auth["https://a.example.com/other"], "Bearer secret", "Same server keeps the token")

        XCTAssertFalse(manager.canKeepStoredToken(for: "https://b.example.com/hook"))
        try await manager.connect(urlString: "https://b.example.com/hook", bearerToken: "")
        XCTAssertEqual(auth["https://b.example.com/hook"], .some(nil), "A new server never gets the old token")
        XCTAssertFalse(manager.hasStoredToken)
    }

    @MainActor
    func testLocationServiceAsksForItsSecretAgainOnANewServer() async throws {
        var bearerTokens: [String?] = []
        WebhookURLProtocolStub.handler = { request in
            bearerTokens.append(request.value(forHTTPHeaderField: "Authorization"))
            return (Data("[]".utf8), 200, [:])
        }
        let manager = LocationServiceSyncManager(
            modelContainer: try makeInMemoryContainer(),
            defaults: makeDefaults(),
            client: LocationServiceAPIClient(session: makeStubbedSession())
        )
        defer { try? manager.disconnect(.reitti) }

        var input = LocationServiceConnectionInput(serverURL: "https://a.example.com", token: "secret")
        _ = try await manager.connect(service: .reitti, input: input)
        XCTAssertEqual(bearerTokens, ["Bearer secret"])

        input.token = ""
        _ = try await manager.connect(service: .reitti, input: input)
        XCTAssertEqual(bearerTokens, ["Bearer secret", "Bearer secret"], "Same server keeps the token")

        input.serverURL = "https://b.example.com"
        XCTAssertFalse(manager.canKeepStoredSecret(for: .reitti, input: input))
        do {
            _ = try await manager.connect(service: .reitti, input: input)
            XCTFail("A new server must not receive the saved token")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter the API token for Reitti.")
        }
        XCTAssertEqual(bearerTokens.count, 2, "Nothing is sent to the new server")
    }

    // MARK: Shortcuts and Spotlight

    func testSpotlightNeverDonatesCoordinatesAsAName() {
        let unlabeled = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_735_000_000),
            departureDate: nil,
            latitude: 52.52,
            longitude: 13.405,
            horizontalAccuracy: 8
        )
        let entity = VisitedPlaceEntity(place: unlabeled)
        XCTAssertEqual(entity.name, "Visited place")
        XCTAssertFalse(entity.attributeSet.displayName?.contains("52.52") ?? true)

        unlabeled.autoLabel = "52.52000, 13.40500"
        XCTAssertEqual(VisitedPlaceEntity(place: unlabeled).name, "Visited place")

        unlabeled.autoLabel = "Coffee Shop"
        XCTAssertEqual(VisitedPlaceEntity(place: unlabeled).name, "Coffee Shop")
    }

    func testYesterdayDoesNotClaimTodaysMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 14)))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))

        let interval = try XCTUnwrap(MovesTimelinePeriod.yesterday.dateInterval(containing: now, calendar: calendar))
        XCTAssertTrue(interval.holds(yesterday))
        XCTAssertTrue(interval.holds(today.addingTimeInterval(-1)))
        XCTAssertFalse(interval.holds(today))
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream { return Data(reading: stream) }
        return Data()
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "moves-upload-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    private func makeSample(
        source: LocationSampleSource,
        latitude: Double,
        timestamp: Date
    ) -> LocationSample {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 13.405),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 4,
            timestamp: timestamp
        )
        return LocationSample(
            location: location,
            source: source,
            dedupeKey: "\(source.rawValue)-\(latitude)-\(timestamp.timeIntervalSince1970)"
        )
    }

    private func makeMove(key: String, end: Date) -> MoveSegment {
        MoveSegment(
            dedupeKey: key,
            startDate: end.addingTimeInterval(-600),
            endDate: end,
            transportMode: .walking,
            distanceMeters: 500,
            stepCount: nil
        )
    }

    private func makeVisit(
        name: String,
        latitude: Double = 52.52,
        longitude: Double = 13.405,
        arrival: Date = Date(timeIntervalSince1970: 1_735_000_000)
    ) -> VisitPlace {
        VisitPlace(
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(3_600),
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: 8,
            userLabel: name
        )
    }

    private func makeSample() -> LocationSample {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            altitude: 42,
            horizontalAccuracy: 7,
            verticalAccuracy: 3,
            course: 90,
            speed: 4.5,
            timestamp: Date(timeIntervalSince1970: 1_735_000_000)
        )
        return LocationSample(location: location, source: .routeTracking, dedupeKey: "sample")
    }

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try WebhookJSON.encoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (Data, Int, [String: String])
    ) -> WebhookAPIClient {
        WebhookURLProtocolStub.handler = handler
        return WebhookAPIClient(session: makeStubbedSession())
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class WebhookURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, Int, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, statusCode, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                append(buffer, count: read)
            } else {
                break
            }
        }
    }
}
