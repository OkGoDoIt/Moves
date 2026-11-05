//
//  WebhookSync.swift
//  Moves
//
//  Optional generic webhook for new timeline points. Posts OwnTracks-compatible
//  `_type: location` (and visit arrive/leave `_type: transition`) plus a
//  Moves-native `{ visits, moves }` envelope. Both envelopes are on by default
//  and can be toggled independently. HTTPS is required except on the local
//  network. Automatic upload sends new records only; backfill needs confirm.
//

import CoreLocation
import Foundation
import Security
import SwiftData
import SwiftUI

/// Which JSON envelopes the webhook should POST.
struct WebhookPayloadOptions: Equatable {
    /// OwnTracks `_type: location` for each new location sample.
    var sendOwnTracksLocations = true
    /// OwnTracks `_type: transition` when a visit starts or ends.
    var sendOwnTracksTransitions = true
    /// Moves-native `{ visits, moves }` JSON with a simplified route.
    var sendNativeTimeline = true

    var sendsAnything: Bool {
        sendOwnTracksLocations || sendOwnTracksTransitions || sendNativeTimeline
    }
}

enum WebhookSyncError: LocalizedError {
    case invalidURL
    case insecureRemoteServer
    case notConfigured
    case missingPayload
    case keychain(OSStatus)
    case invalidResponse
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a complete webhook URL, including https://."
        case .insecureRemoteServer:
            return "Remote webhooks must use HTTPS. HTTP is only allowed for local-network hosts."
        case .notConfigured:
            return "Save a webhook URL first."
        case .missingPayload:
            return "Turn on at least one payload (OwnTracks or Moves visits and moves)."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not access the saved webhook token (\(detail))."
        case .invalidResponse:
            return "The webhook returned an invalid response."
        case .server(let statusCode, let message):
            if statusCode == 401 || statusCode == 403 {
                return "The webhook rejected the saved token."
            }
            if let message, !message.isEmpty {
                return "The webhook returned HTTP \(statusCode): \(message)"
            }
            return "The webhook returned HTTP \(statusCode)."
        }
    }
}

/// A fully-qualified POST URL. Unlike Dawarich-style base URLs, the path is kept.
struct WebhookEndpoint: Equatable {
    let url: URL

    /// Parses a webhook URL and rejects remote HTTP.
    static func make(from raw: String) throws -> WebhookEndpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            throw WebhookSyncError.invalidURL
        }

        if scheme == "http", !isLocalHost(host) {
            throw WebhookSyncError.insecureRemoteServer
        }

        components.scheme = scheme
        components.fragment = nil
        guard let url = components.url else {
            throw WebhookSyncError.invalidURL
        }
        return WebhookEndpoint(url: url)
    }

    /// Hosts that may use HTTP: loopback, `.local`, single-label, RFC 1918, link-local, ULA.
    static func isLocalHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "localhost" || lowercased.hasSuffix(".local") || !lowercased.contains(".") {
            return true
        }
        if lowercased == "::1"
            || lowercased.hasPrefix("fc")
            || lowercased.hasPrefix("fd")
            || lowercased.hasPrefix("fe80:") {
            return true
        }

        let octets = lowercased.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

/// OwnTracks `_type: transition` for visit arrive/leave. HTTP mode requires `tid`.
struct OwnTracksTransitionPayload: Encodable {
    let type = "transition"
    let latitude: Double
    let longitude: Double
    let timestamp: Int64
    let waypointTimestamp: Int64
    let accuracy: Double
    let event: String
    let description: String
    let regionID: String
    let deviceID: String
    let trigger = "c"

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case latitude = "lat"
        case longitude = "lon"
        case timestamp = "tst"
        case waypointTimestamp = "wtst"
        case accuracy = "acc"
        case event
        case description = "desc"
        case regionID = "rid"
        case deviceID = "tid"
        case trigger = "t"
    }

    /// Builds an enter or leave event from a stored visit.
    init(visit: VisitPlace, event: String, deviceID: String) {
        latitude = visit.latitude
        longitude = visit.longitude
        let eventDate = event == "leave" ? (visit.departureDate ?? visit.arrivalDate) : visit.arrivalDate
        timestamp = Int64(eventDate.timeIntervalSince1970)
        waypointTimestamp = Int64(visit.createdAt.timeIntervalSince1970)
        accuracy = max(visit.horizontalAccuracy, 0)
        self.event = event
        description = WebhookPlaceName.name(for: visit)
        regionID = visit.id.uuidString
        self.deviceID = deviceID
    }
}

/// One visit in the Moves-native webhook envelope.
struct MovesNativeVisitJSON: Encodable, Equatable {
    let id: String
    let name: String
    let arrival: String
    let departure: String?
    let latitude: Double
    let longitude: Double
    let knownPlaceID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, arrival, departure, latitude, longitude
        case knownPlaceID = "known_place_id"
    }

    init(visit: VisitPlace) {
        id = visit.id.uuidString
        name = WebhookPlaceName.name(for: visit)
        arrival = LocationServiceAPIClient.iso8601String(from: visit.arrivalDate)
        departure = visit.departureDate.map(LocationServiceAPIClient.iso8601String(from:))
        latitude = visit.latitude
        longitude = visit.longitude
        knownPlaceID = visit.knownPlace?.id.uuidString
    }
}

/// One move in the Moves-native webhook envelope. `route` is `[longitude, latitude]` pairs.
struct MovesNativeMoveJSON: Encodable, Equatable {
    let id: String
    let mode: String
    let start: String
    let end: String
    let startPlace: String
    let endPlace: String
    let distanceMeters: Double
    let route: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, mode, start, end
        case startPlace = "start_place"
        case endPlace = "end_place"
        case distanceMeters = "distance_meters"
        case route
    }

    init(move: MoveSegment, route: [[Double]]) {
        id = move.id.uuidString
        mode = move.transportMode.rawValue
        start = LocationServiceAPIClient.iso8601String(from: move.timelineStartDate)
        end = LocationServiceAPIClient.iso8601String(from: move.endDate)
        startPlace = WebhookPlaceName.name(for: move.startPlace)
        endPlace = WebhookPlaceName.name(for: move.endPlace)
        distanceMeters = move.distanceMeters
        self.route = route
    }
}

/// Moves-native POST body. Full GPS samples are never included.
struct MovesNativeTimelineJSON: Encodable, Equatable {
    let visits: [MovesNativeVisitJSON]
    let moves: [MovesNativeMoveJSON]
}

enum WebhookPlaceName {
    /// Human place name, never a raw coordinate pair.
    static func name(for visit: VisitPlace?) -> String {
        guard let visit else { return "Unknown place" }
        if let known = visit.knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !known.isEmpty {
            return known
        }
        if let userLabel = visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userLabel.isEmpty {
            return userLabel
        }
        if let autoLabel = visit.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !autoLabel.isEmpty {
            return autoLabel
        }
        return "Visit"
    }
}

/// Downsamples a polyline so native POSTs stay small.
enum WebhookRouteSimplifier {
    static let maxVertexCount = 32

    /// GeoJSON-order coordinates for a move, capped at `maxVertexCount` vertices.
    static func geoJSONLine(for move: MoveSegment) -> [[Double]] {
        downsample(coordinates(for: move)).map { [$0.longitude, $0.latitude] }
    }

    /// Evenly keeps the first and last vertices.
    static func downsample(
        _ coordinates: [CLLocationCoordinate2D],
        maxVertexCount: Int = maxVertexCount
    ) -> [CLLocationCoordinate2D] {
        let count = coordinates.count
        guard count > maxVertexCount, maxVertexCount >= 2 else { return coordinates }

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(maxVertexCount)
        for step in 0..<maxVertexCount {
            let index = step == maxVertexCount - 1
                ? count - 1
                : (step * (count - 1)) / (maxVertexCount - 1)
            let coordinate = coordinates[index]
            if let last = result.last,
               last.latitude == coordinate.latitude,
               last.longitude == coordinate.longitude {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        let displayed = TimelineLocator.displayedCoordinates(for: move)
        if displayed.count >= 2 {
            return displayed
        }

        let samples = move.samples
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.coordinate)
        if samples.count >= 2 {
            return samples
        }

        var ends: [CLLocationCoordinate2D] = []
        if let start = move.startPlace?.coordinate {
            ends.append(start)
        }
        if let end = move.endPlace?.coordinate,
           ends.last.map({ $0.latitude != end.latitude || $0.longitude != end.longitude }) ?? true {
            ends.append(end)
        }
        return ends
    }
}

enum WebhookJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private enum WebhookKeychain {
    static let serviceName = "\(MovesAppIdentity.bundleIdentifier).webhook"
    static let account = "bearer"

    static func loadToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw WebhookSyncError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw WebhookSyncError.keychain(updateStatus) }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw WebhookSyncError.keychain(addStatus) }
    }

    static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebhookSyncError.keychain(status)
        }
    }
}

/// Injectable HTTP client used by the webhook manager and unit tests.
struct WebhookAPIClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testConnection(endpoint: WebhookEndpoint, bearerToken: String?) async throws {
        var request = jsonRequest(url: endpoint.url, bearerToken: bearerToken)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"_type":"cmd"}"#.utf8)
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
    }

    /// Posts OwnTracks location objects one at a time, then transitions, then one native envelope.
    func upload(
        ownTracksLocations: [OwnTracksLocationPayload],
        transitions: [OwnTracksTransitionPayload],
        native: MovesNativeTimelineJSON?,
        endpoint: WebhookEndpoint,
        bearerToken: String?
    ) async throws {
        let encoder = WebhookJSON.encoder()
        for payload in ownTracksLocations {
            try await post(try encoder.encode(payload), to: endpoint, bearerToken: bearerToken)
        }
        for payload in transitions {
            try await post(try encoder.encode(payload), to: endpoint, bearerToken: bearerToken)
        }
        if let native, !native.visits.isEmpty || !native.moves.isEmpty {
            try await post(try encoder.encode(native), to: endpoint, bearerToken: bearerToken)
        }
    }

    private func post(_ body: Data, to endpoint: WebhookEndpoint, bearerToken: String?) async throws {
        var request = jsonRequest(url: endpoint.url, bearerToken: bearerToken)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
    }

    private func jsonRequest(url: URL, bearerToken: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            let trimmed = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw WebhookSyncError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            var message: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = object["message"] as? String ?? object["error"] as? String
            }
            throw WebhookSyncError.server(statusCode: response.statusCode, message: message)
        }
        return response
    }
}

struct WebhookRuntimeState: Equatable {
    var isSyncing = false
    var isTestingConnection = false
    var isConfigured = false
    var automaticSyncEnabled = false
    var lastSuccessfulSyncAt: Date?
    var lastMessage = ""
    var lastOperationFailed = false
    var payloadOptions = WebhookPayloadOptions()
}

@MainActor
final class WebhookSyncManager: ObservableObject {
    @Published private(set) var state = WebhookRuntimeState()

    private let modelContainer: ModelContainer
    private let defaults: UserDefaults
    private let client: WebhookAPIClient
    private var notificationObserver: NSObjectProtocol?
    private var resyncRequested = false
    private static let batchSize = 50

    init(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard,
        client: WebhookAPIClient = WebhookAPIClient()
    ) {
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.client = client
        reloadSettings()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .movesLocationSamplesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncNewItemsIfEnabled()
            }
        }
    }

    var connectionSummary: String {
        guard state.isConfigured else { return "Not connected" }
        return currentEndpoint()?.url.host ?? "Connected"
    }

    var savedURL: String {
        defaults.string(forKey: Keys.serverURL) ?? ""
    }

    var hasStoredToken: Bool {
        let token = (try? WebhookKeychain.loadToken()) ?? ""
        return !token.isEmpty
    }

    /// True when leaving the token blank would keep the saved one for the URL now entered.
    func canKeepStoredToken(for urlString: String) -> Bool {
        guard hasStoredToken, let endpoint = try? WebhookEndpoint.make(from: urlString) else {
            return false
        }
        return SavedCredentialPolicy.mayReuse(savedFor: currentEndpoint()?.url, on: endpoint.url)
    }

    func reloadSettings() {
        var next = state
        next.isConfigured = (try? currentEndpoint()) != nil
            && !(defaults.string(forKey: Keys.serverURL) ?? "").isEmpty
        next.automaticSyncEnabled = defaults.bool(forKey: Keys.automaticSync)
        next.lastSuccessfulSyncAt = defaults.object(forKey: Keys.lastSuccess) as? Date
        next.payloadOptions = payloadOptions()
        state = next
    }

    func payloadOptions() -> WebhookPayloadOptions {
        WebhookPayloadOptions(
            sendOwnTracksLocations: bool(for: Keys.sendOwnTracks, default: true),
            sendOwnTracksTransitions: bool(for: Keys.sendTransitions, default: true),
            sendNativeTimeline: bool(for: Keys.sendNative, default: true)
        )
    }

    func setPayloadOptions(_ options: WebhookPayloadOptions) {
        stampCursorsForNewlyEnabledPayloads(from: payloadOptions(), to: options)
        defaults.set(options.sendOwnTracksLocations, forKey: Keys.sendOwnTracks)
        defaults.set(options.sendOwnTracksTransitions, forKey: Keys.sendTransitions)
        defaults.set(options.sendNativeTimeline, forKey: Keys.sendNative)
        reloadSettings()
    }

    func connect(urlString: String, bearerToken: String) async throws {
        let endpoint = try WebhookEndpoint.make(from: urlString)
        let savedToken = SavedCredentialPolicy.mayReuse(savedFor: currentEndpoint()?.url, on: endpoint.url)
            ? (try? WebhookKeychain.loadToken()) ?? ""
            : ""
        let trimmedInput = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmedInput.isEmpty ? savedToken : trimmedInput

        state.isTestingConnection = true
        defer { state.isTestingConnection = false }
        try await client.testConnection(endpoint: endpoint, bearerToken: token.isEmpty ? nil : token)

        let previous = currentEndpoint()?.url
        try WebhookKeychain.saveToken(token)
        defaults.set(urlString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.serverURL)
        if previous != endpoint.url {
            stampCursors(to: Date.now)
        }
        reloadSettings()
        state.lastOperationFailed = false
        state.lastMessage = "Connected to the webhook."
    }

    func disconnect() throws {
        try WebhookKeychain.remove()
        for key in [
            Keys.serverURL,
            Keys.automaticSync,
            Keys.lastSuccess,
            Keys.sampleCursor,
            Keys.visitCursor,
            Keys.moveCursor,
            Keys.leaveCursor,
        ] {
            defaults.removeObject(forKey: key)
        }
        reloadSettings()
        state.lastOperationFailed = false
        state.lastMessage = "Disconnected the webhook."
    }

    func setAutomaticSyncEnabled(_ enabled: Bool) {
        // Turning automatic uploads on starts from now, so time spent off is never backfilled.
        if enabled, !defaults.bool(forKey: Keys.automaticSync) {
            stampCursors(to: Date.now)
        }
        defaults.set(enabled, forKey: Keys.automaticSync)
        reloadSettings()
        if enabled {
            Task { await syncNewItemsIfEnabled() }
        }
    }

    func syncNewItemsIfEnabled() async {
        reloadSettings()
        guard state.automaticSyncEnabled, state.isConfigured else { return }
        await performSync(allHistory: false)
    }

    func syncNewItemsNow() async {
        guard state.isConfigured else {
            record(error: WebhookSyncError.notConfigured)
            return
        }
        await performSync(allHistory: false)
    }

    func syncAllHistory() async {
        guard state.isConfigured else {
            record(error: WebhookSyncError.notConfigured)
            return
        }
        await performSync(allHistory: true)
    }

    private func performSync(allHistory: Bool) async {
        guard !state.isSyncing else {
            resyncRequested = true
            return
        }

        state.isSyncing = true
        resyncRequested = false
        defer {
            state.isSyncing = false
            if resyncRequested, state.automaticSyncEnabled {
                Task { await syncNewItemsIfEnabled() }
            }
        }

        do {
            guard let endpoint = currentEndpoint() else {
                throw WebhookSyncError.notConfigured
            }
            let options = payloadOptions()
            guard options.sendsAnything else {
                throw WebhookSyncError.missingPayload
            }

            let token = try WebhookKeychain.loadToken()
            let originalSample = defaults.object(forKey: Keys.sampleCursor) as? Date
            let originalVisit = defaults.object(forKey: Keys.visitCursor) as? Date
            let originalMove = defaults.object(forKey: Keys.moveCursor) as? Date
            let originalLeave = defaults.object(forKey: Keys.leaveCursor) as? Date

            var sampleCursor = allHistory ? Date.distantPast : (originalSample ?? Date.now)
            var visitCursor = allHistory ? Date.distantPast : (originalVisit ?? Date.now)
            var moveCursor = allHistory ? Date.distantPast : (originalMove ?? Date.now)
            var leaveCursor = allHistory ? Date.distantPast : (originalLeave ?? Date.now)
            var uploadedCount = 0

            while true {
                let modelContext = ModelContext(modelContainer)
                let locations: [OwnTracksLocationPayload]
                let transitions: [OwnTracksTransitionPayload]
                let native: MovesNativeTimelineJSON?
                let nextCursors: (Date, Date, Date, Date)
                let batchCount: Int
                (
                    locations,
                    transitions,
                    native,
                    nextCursors,
                    batchCount
                ) = try loadBatch(
                    in: modelContext,
                    options: options,
                    includingHistory: allHistory,
                    sampleCursor: sampleCursor,
                    visitCursor: visitCursor,
                    moveCursor: moveCursor,
                    leaveCursor: leaveCursor
                )

                guard batchCount > 0 else { break }

                try await client.upload(
                    ownTracksLocations: locations,
                    transitions: transitions,
                    native: native,
                    endpoint: endpoint,
                    bearerToken: token
                )
                uploadedCount += batchCount
                sampleCursor = nextCursors.0
                visitCursor = nextCursors.1
                moveCursor = nextCursors.2
                leaveCursor = nextCursors.3

                if !allHistory {
                    writeCursors(
                        sample: sampleCursor,
                        visit: visitCursor,
                        move: moveCursor,
                        leave: leaveCursor
                    )
                }
                if batchCount < Self.batchSize { break }
            }

            if allHistory {
                writeCursors(
                    sample: max(originalSample ?? Date.distantPast, sampleCursor),
                    visit: max(originalVisit ?? Date.distantPast, visitCursor),
                    move: max(originalMove ?? Date.distantPast, moveCursor),
                    leave: max(originalLeave ?? Date.distantPast, leaveCursor)
                )
            }

            let completedAt = Date.now
            defaults.set(completedAt, forKey: Keys.lastSuccess)
            state.lastSuccessfulSyncAt = completedAt
            state.lastOperationFailed = false
            state.lastMessage = uploadedCount == 0
                ? "The webhook is up to date."
                : "Posted \(uploadedCount) record\(uploadedCount == 1 ? "" : "s") to the webhook."
        } catch {
            record(error: error)
        }
    }

    private func loadBatch(
        in modelContext: ModelContext,
        options: WebhookPayloadOptions,
        includingHistory: Bool,
        sampleCursor: Date,
        visitCursor: Date,
        moveCursor: Date,
        leaveCursor: Date
    ) throws -> (
        [OwnTracksLocationPayload],
        [OwnTracksTransitionPayload],
        MovesNativeTimelineJSON?,
        (Date, Date, Date, Date),
        Int
    ) {
        let deviceID = deviceIdentifier()
        var locations: [OwnTracksLocationPayload] = []
        var transitions: [OwnTracksTransitionPayload] = []
        var nativeVisits: [MovesNativeVisitJSON] = []
        var nativeMoves: [MovesNativeMoveJSON] = []
        var nextSample = sampleCursor
        var nextVisit = visitCursor
        var nextMove = moveCursor
        var nextLeave = leaveCursor
        var count = 0

        if options.sendOwnTracksLocations {
            var descriptor = FetchDescriptor<LocationSample>(
                predicate: LocationUploadFilter.samples(after: sampleCursor, includingHistory: includingHistory),
                sortBy: [SortDescriptor(\LocationSample.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = Self.batchSize
            let samples = try modelContext.fetch(descriptor)
            locations = samples.map {
                OwnTracksLocationPayload(sample: $0, deviceID: deviceID)
            }
            if let latest = samples.map(\.createdAt).max() {
                nextSample = latest
            }
            count += samples.count
        }

        if options.sendOwnTracksTransitions || options.sendNativeTimeline {
            let visits = try fetchPendingVisits(
                in: modelContext,
                includingHistory: includingHistory,
                visitCursor: visitCursor,
                leaveCursor: leaveCursor
            )

            for visit in visits {
                if options.sendOwnTracksTransitions {
                    let isNewVisit = visit.createdAt > visitCursor
                    if isNewVisit {
                        transitions.append(
                            OwnTracksTransitionPayload(visit: visit, event: "enter", deviceID: deviceID)
                        )
                    }
                    // A visit created after it ended still needs its leave, whatever the cursor says.
                    if let departure = visit.departureDate, isNewVisit || departure > leaveCursor {
                        transitions.append(
                            OwnTracksTransitionPayload(visit: visit, event: "leave", deviceID: deviceID)
                        )
                    }
                }
                if options.sendNativeTimeline {
                    nativeVisits.append(MovesNativeVisitJSON(visit: visit))
                }
                nextVisit = max(nextVisit, visit.createdAt)
                if let departure = visit.departureDate {
                    nextLeave = max(nextLeave, departure)
                }
            }
            count += visits.count
        }

        if options.sendNativeTimeline {
            var moveDescriptor = FetchDescriptor<MoveSegment>(
                predicate: LocationUploadFilter.moves(after: moveCursor, includingHistory: includingHistory),
                sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
            )
            moveDescriptor.fetchLimit = Self.batchSize
            let moves = try modelContext.fetch(moveDescriptor)
            nativeMoves = moves.map {
                MovesNativeMoveJSON(move: $0, route: WebhookRouteSimplifier.geoJSONLine(for: $0))
            }
            if let latest = moves.map(\.createdAt).max() {
                nextMove = latest
            }
            count += moves.count
        }

        let native: MovesNativeTimelineJSON?
        if options.sendNativeTimeline, !nativeVisits.isEmpty || !nativeMoves.isEmpty {
            native = MovesNativeTimelineJSON(visits: nativeVisits, moves: nativeMoves)
        } else {
            native = nil
        }

        return (locations, transitions, native, (nextSample, nextVisit, nextMove, nextLeave), count)
    }

    /// New visits by `createdAt`, plus recently departed visits whose leave has not been posted yet.
    private func fetchPendingVisits(
        in modelContext: ModelContext,
        includingHistory: Bool,
        visitCursor: Date,
        leaveCursor: Date
    ) throws -> [VisitPlace] {
        var createdDescriptor = FetchDescriptor<VisitPlace>(
            predicate: LocationUploadFilter.visits(after: visitCursor, includingHistory: includingHistory),
            sortBy: [SortDescriptor(\VisitPlace.createdAt, order: .forward)]
        )
        createdDescriptor.fetchLimit = Self.batchSize
        var visits = try modelContext.fetch(createdDescriptor)

        var recentDescriptor = FetchDescriptor<VisitPlace>(
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        recentDescriptor.fetchLimit = Self.batchSize
        let recent = try modelContext.fetch(recentDescriptor)
        let known = Set(visits.map(\.id))
        let lateLeaves = recent.filter { visit in
            guard !known.contains(visit.id), let departure = visit.departureDate else {
                return false
            }
            if !includingHistory, LocationUploadFilter.importedOrigins.contains(visit.originRaw) {
                return false
            }
            return departure > leaveCursor && visit.createdAt <= visitCursor
        }
        visits.append(contentsOf: lateLeaves)
        return visits
    }

    private func currentEndpoint() -> WebhookEndpoint? {
        try? WebhookEndpoint.make(from: savedURL)
    }

    private func stampCursors(to date: Date) {
        writeCursors(sample: date, visit: date, move: date, leave: date)
    }

    /// A payload that was off has a stale cursor. Starting it from now keeps the gap local.
    private func stampCursorsForNewlyEnabledPayloads(
        from previous: WebhookPayloadOptions,
        to next: WebhookPayloadOptions
    ) {
        let now = Date.now
        if next.sendOwnTracksLocations, !previous.sendOwnTracksLocations {
            defaults.set(now, forKey: Keys.sampleCursor)
        }
        let sentVisits = previous.sendOwnTracksTransitions || previous.sendNativeTimeline
        let sendsVisits = next.sendOwnTracksTransitions || next.sendNativeTimeline
        if sendsVisits, !sentVisits {
            defaults.set(now, forKey: Keys.visitCursor)
            defaults.set(now, forKey: Keys.leaveCursor)
        }
        if next.sendNativeTimeline, !previous.sendNativeTimeline {
            defaults.set(now, forKey: Keys.moveCursor)
        }
    }

    private func writeCursors(sample: Date, visit: Date, move: Date, leave: Date) {
        defaults.set(sample, forKey: Keys.sampleCursor)
        defaults.set(visit, forKey: Keys.visitCursor)
        defaults.set(move, forKey: Keys.moveCursor)
        defaults.set(leave, forKey: Keys.leaveCursor)
    }

    private func deviceIdentifier() -> String {
        let sharedKey = "Moves.locationServices.generatedDeviceID"
        if let existing = defaults.string(forKey: sharedKey), !existing.isEmpty {
            return existing
        }
        if let existing = defaults.string(forKey: Keys.deviceID), !existing.isEmpty {
            return existing
        }
        let value = "Moves-iOS-\(UUID().uuidString)"
        defaults.set(value, forKey: Keys.deviceID)
        return value
    }

    private func bool(for key: String, default defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func record(error: Error) {
        state.lastOperationFailed = true
        state.lastMessage = error.localizedDescription
    }

    private enum Keys {
        static let serverURL = "Moves.webhook.serverURL"
        static let automaticSync = "Moves.webhook.automaticSync"
        static let lastSuccess = "Moves.webhook.lastSuccess"
        static let sendOwnTracks = "Moves.webhook.sendOwnTracks"
        static let sendTransitions = "Moves.webhook.sendTransitions"
        static let sendNative = "Moves.webhook.sendNative"
        static let sampleCursor = "Moves.webhook.sampleCursor"
        static let visitCursor = "Moves.webhook.visitCursor"
        static let moveCursor = "Moves.webhook.moveCursor"
        static let leaveCursor = "Moves.webhook.leaveCursor"
        static let deviceID = "Moves.webhook.deviceID"
    }
}

struct WebhookSettingsView: View {
    @EnvironmentObject private var syncManager: WebhookSyncManager

    @State private var urlString = ""
    @State private var bearerToken = ""
    @State private var isShowingHistoryConfirmation = false
    @State private var isShowingDisconnectConfirmation = false
    @State private var alertMessage = ""
    @State private var isShowingAlert = false

    private var state: WebhookRuntimeState { syncManager.state }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Server") {
                    TextField("https://example.com/hooks/moves", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    SecureField(
                        syncManager.canKeepStoredToken(for: urlString)
                            ? "Leave blank to keep saved token"
                            : "Bearer token (optional)",
                        text: $bearerToken
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    Button { connect() } label: {
                        Label(
                            state.isTestingConnection ? "Testing…" : "Test and Save Connection",
                            systemImage: state.isConfigured ? "checkmark.icloud" : "link"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(state.isTestingConnection || state.isSyncing)

                    Text("HTTPS is required outside your local network. The URL is posted to as-is, including any path.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Payloads") {
                    Toggle(
                        "OwnTracks location points",
                        isOn: payloadBinding(\.sendOwnTracksLocations)
                    )
                    Toggle(
                        "OwnTracks arrive and leave",
                        isOn: payloadBinding(\.sendOwnTracksTransitions)
                    )
                    Toggle(
                        "Moves visits and moves",
                        isOn: payloadBinding(\.sendNativeTimeline)
                    )

                    Text("OwnTracks posts a location object for each new GPS point so Recorder and Home Assistant can ingest without a custom parser. Moves posts visit ids, names, times, and a simplified route — not the full GPS dump.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Uploads") {
                    Toggle(
                        "Automatically upload new points",
                        isOn: Binding(
                            get: { state.automaticSyncEnabled },
                            set: { syncManager.setAutomaticSyncEnabled($0) }
                        )
                    )
                    .disabled(!state.isConfigured)

                    Button { Task { await syncManager.syncNewItemsNow() } } label: {
                        Label("Upload New Points Now", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isConfigured || state.isSyncing)
                    .padding(.vertical, 5)

                    Button { isShowingHistoryConfirmation = true } label: {
                        Label("Upload All Local History", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isConfigured || state.isSyncing)
                    .padding(.vertical, 5)

                    if state.isSyncing {
                        ProgressView("Posting to the webhook…")
                    }

                    if !state.lastMessage.isEmpty {
                        Text(state.lastMessage)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(state.lastOperationFailed ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let lastSync = state.lastSuccessfulSyncAt {
                        Text("Last successful upload \(lastSync.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text("New points only until you confirm a full-history upload. Repeating a full-history upload may create duplicates if the receiver does not deduplicate.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if state.isConfigured {
                    SettingsCard(title: "Connection") {
                        Button(role: .destructive) { isShowingDisconnectConfirmation = true } label: {
                            Label("Disconnect Webhook", systemImage: "link.badge.minus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isSyncing || state.isTestingConnection)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncManager.reloadSettings()
            urlString = syncManager.savedURL
        }
        .confirmationDialog(
            "Upload All Location History?",
            isPresented: $isShowingHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Upload All History") { Task { await syncManager.syncAllHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every matching visit, move, and location sample stored in Moves will be posted to this webhook. Repeating this action may create duplicates if the receiver does not deduplicate them.")
        }
        .confirmationDialog(
            "Disconnect Webhook?",
            isPresented: $isShowingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved URL and token will be removed. Data already posted is not deleted.")
        }
        .alert("Webhook", isPresented: $isShowingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func payloadBinding(_ keyPath: WritableKeyPath<WebhookPayloadOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { syncManager.state.payloadOptions[keyPath: keyPath] },
            set: { newValue in
                var options = syncManager.payloadOptions()
                options[keyPath: keyPath] = newValue
                syncManager.setPayloadOptions(options)
            }
        )
    }

    private func connect() {
        Task {
            do {
                try await syncManager.connect(urlString: urlString, bearerToken: bearerToken)
                bearerToken = ""
            } catch {
                alertMessage = error.localizedDescription
                isShowingAlert = true
            }
        }
    }

    private func disconnect() {
        do {
            try syncManager.disconnect()
            urlString = syncManager.savedURL
            bearerToken = ""
        } catch {
            alertMessage = error.localizedDescription
            isShowingAlert = true
        }
    }
}
