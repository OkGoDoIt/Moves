import CoreLocation
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookURLProtocolStub.self]
        return WebhookAPIClient(session: URLSession(configuration: configuration))
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
