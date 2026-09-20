import CoreLocation
import Foundation

// MARK: - Format

/// The three Google Timeline JSON shapes Moves can import.
enum GoogleTimelineFormat: String, Sendable {
    /// Takeout `Records.json` (`locations[]` with E7 coordinates).
    case records
    /// Takeout Semantic Location History month (`timelineObjects[]`).
    case semanticMonth
    /// On-device Maps export (`semanticSegments[]` or a bare segment array).
    case onDevice
}

/// Errors while detecting or parsing a Google Timeline file.
enum GoogleTimelineImportError: LocalizedError {
    case notGoogleTimeline
    case noTimelineData
    case unreadableFile(String)
    case corruptZip
    case recordsTooLargeToBuffer

    var errorDescription: String? {
        switch self {
        case .notGoogleTimeline:
            return "This file isn’t a Google Timeline export."
        case .noTimelineData:
            return "The selected Google Timeline files did not contain any visits, trips, or GPS points."
        case .unreadableFile(let name):
            return "Could not read \(name)."
        case .corruptZip:
            return "The zip archive is damaged or uses an unsupported compression method."
        case .recordsTooLargeToBuffer:
            return "Records.json is too large to load at once. Moves streams it from disk instead."
        }
    }
}

// MARK: - Draft

/// Intermediate visits and trips parsed from one or more Google Timeline files.
///
/// Persistence goes through `LocationLogStay` / `LocationLogMove` so SwiftData
/// writes, dedupe, and progress reporting stay shared with Files import.
struct GoogleTimelineDraft: Sendable {
    var stays: [LocationLogStay] = []
    var moves: [LocationLogMove] = []
    /// Time windows already covered by semantic history, used to skip Records points.
    var occupancy: [GoogleOccupiedWindow] = []
    var skippedSegmentCount = 0
    var recordPointCount = 0
    var format: GoogleTimelineFormat?

    var isEmpty: Bool { stays.isEmpty && moves.isEmpty && recordPointCount == 0 }

    mutating func append(_ other: GoogleTimelineDraft) {
        stays.append(contentsOf: other.stays)
        moves.append(contentsOf: other.moves)
        occupancy.append(contentsOf: other.occupancy)
        skippedSegmentCount += other.skippedSegmentCount
        recordPointCount += other.recordPointCount
        if format == nil {
            format = other.format
        }
    }

    /// Stays and moves ordered by start time for `importLocationLog`.
    func makeTimeline() -> LocationLogTimeline {
        var events: [(Date, LocationLogSegment)] = []
        events.reserveCapacity(stays.count + moves.count)
        for stay in stays {
            events.append((stay.arrivalDate, .stay(stay)))
        }
        for move in moves {
            events.append((move.startDate, .move(move)))
        }
        events.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            switch (lhs.1, rhs.1) {
            case (.stay, .move): return true
            default: return false
            }
        }
        let pointCount = stays.reduce(0) { $0 + $1.points.count }
            + moves.reduce(0) { $0 + $1.points.count }
        return LocationLogTimeline(segments: events.map(\.1), pointCount: pointCount)
    }
}

/// A visit or trip already imported from semantic history.
struct GoogleOccupiedWindow: Sendable {
    var start: Date
    var end: Date
    var latitude: Double
    var longitude: Double
    var isVisit: Bool
}

/// Day-bucketed lookup so Records streaming can skip points already covered
/// by semantic visits (time + ~150 m) and trips (time only).
struct GoogleOccupancyIndex: Sendable {
    private var visitBuckets: [Int: [GoogleOccupiedWindow]] = [:]
    private var moveBuckets: [Int: [GoogleOccupiedWindow]] = [:]

    /// Metres: a Records fix inside this of a visit at the same time is a duplicate.
    static let visitMatchDistance: CLLocationDistance = 150
    /// Seconds of slack around a visit when matching Records points.
    static let visitMatchSlack: TimeInterval = 2 * 60
    /// Cheap degree gate equivalent to a bit more than `visitMatchDistance`.
    fileprivate static let degreeGate = 0.002

    init(windows: [GoogleOccupiedWindow]) {
        for window in windows {
            let startDay = Self.dayOrdinal(window.start)
            let endDay = Self.dayOrdinal(window.end)
            for day in startDay...max(startDay, endDay) {
                if window.isVisit {
                    visitBuckets[day, default: []].append(window)
                } else {
                    moveBuckets[day, default: []].append(window)
                }
            }
        }
    }

    /// True when this Records fix already sits on a semantic visit or trip.
    func covers(_ point: LocationLogPoint) -> Bool {
        let day = Self.dayOrdinal(point.timestamp)
        for candidate in (day - 1)...(day + 1) {
            if let visits = visitBuckets[candidate] {
                for visit in visits where visit.coversVisit(point) {
                    return true
                }
            }
            if let moves = moveBuckets[candidate] {
                for move in moves where point.timestamp >= move.start && point.timestamp <= move.end {
                    return true
                }
            }
        }
        return false
    }

    private static func dayOrdinal(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }
}

private extension GoogleOccupiedWindow {
    func coversVisit(_ point: LocationLogPoint) -> Bool {
        let slack = GoogleOccupancyIndex.visitMatchSlack
        guard point.timestamp >= start.addingTimeInterval(-slack),
              point.timestamp <= end.addingTimeInterval(slack) else {
            return false
        }
        if abs(point.latitude - latitude) > GoogleOccupancyIndex.degreeGate
            || abs(point.longitude - longitude) > GoogleOccupancyIndex.degreeGate {
            return false
        }
        let distance = LocationLogGeometry.distance(
            from: point.coordinate,
            to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
        return distance <= GoogleOccupancyIndex.visitMatchDistance
    }
}

// MARK: - Parser

/// Detects the three Google Timeline shapes and turns them into a draft.
enum GoogleTimelineParser {
    /// Bytes to read when classifying a file. Never load `Records.json` wholesale.
    static let peekLength = 2048

    /// Classifies a file from its opening bytes without parsing the body.
    static func detect(peek: String) -> GoogleTimelineFormat? {
        let trimmed = peek.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("\"locations\"") { return .records }
        if trimmed.contains("\"timelineObjects\"") { return .semanticMonth }
        if trimmed.contains("\"semanticSegments\"") { return .onDevice }
        if trimmed.hasPrefix("[") {
            // iOS on-device export can be a bare array of semantic segments.
            if trimmed.contains("\"startTime\"")
                && (trimmed.contains("\"visit\"")
                    || trimmed.contains("\"activity\"")
                    || trimmed.contains("\"timelinePath\"")) {
                return .onDevice
            }
        }
        return nil
    }

    /// Peeks at `url` and classifies it. Safe for a 300+ MiB Records.json.
    static func detect(at url: URL) throws -> GoogleTimelineFormat? {
        detect(peek: try peekString(at: url))
    }

    static func peekString(at url: URL, maxLength: Int = peekLength) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxLength)
        if data.isEmpty { return "" }
        if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// Whole-file decode of a Semantic Location History month (max ~1.5 MB).
    static func parseSemanticMonth(data: Data) throws -> GoogleTimelineDraft {
        let root = try jsonObject(data)
        guard let dictionary = root as? [String: Any],
              let objects = dictionary["timelineObjects"] as? [Any] else {
            throw GoogleTimelineImportError.notGoogleTimeline
        }
        var draft = GoogleTimelineDraft(format: .semanticMonth)
        for item in objects {
            guard let object = item as? [String: Any] else { continue }
            if let visit = object["placeVisit"] as? [String: Any] {
                let stays = parsePlaceVisit(visit, includeChildren: true)
                if stays.isEmpty {
                    draft.skippedSegmentCount += 1
                } else {
                    for stay in stays {
                        draft.stays.append(stay)
                        draft.occupancy.append(window(for: stay))
                    }
                }
            } else if let segment = object["activitySegment"] as? [String: Any] {
                if let move = parseActivitySegment(segment) {
                    draft.moves.append(move)
                    draft.occupancy.append(window(for: move))
                } else {
                    draft.skippedSegmentCount += 1
                }
            }
        }
        return draft
    }

    /// On-device `Timeline.json` (object with `semanticSegments` or a bare array).
    static func parseOnDevice(data: Data) throws -> GoogleTimelineDraft {
        let root = try jsonObject(data)
        let segments: [Any]
        var rawSignals: [Any] = []
        if let dictionary = root as? [String: Any] {
            segments = dictionary["semanticSegments"] as? [Any] ?? []
            rawSignals = dictionary["rawSignals"] as? [Any] ?? []
        } else if let array = root as? [Any] {
            segments = array
        } else {
            throw GoogleTimelineImportError.notGoogleTimeline
        }

        var draft = GoogleTimelineDraft(format: .onDevice)
        for item in segments {
            guard let segment = item as? [String: Any] else { continue }
            guard let start = GoogleTimelineTime.parse(segment["startTime"]),
                  let end = GoogleTimelineTime.parse(segment["endTime"]) else {
                draft.skippedSegmentCount += 1
                continue
            }
            let path = parseTimelinePath(segment["timelinePath"], fallbackStart: start, fallbackEnd: end)

            if let visit = segment["visit"] as? [String: Any],
               let stay = parseOnDeviceVisit(visit, start: start, end: end, path: path) {
                draft.stays.append(stay)
                draft.occupancy.append(window(for: stay))
            } else if let activity = segment["activity"] as? [String: Any],
                      let move = parseOnDeviceActivity(activity, start: start, end: end, path: path) {
                draft.moves.append(move)
                draft.occupancy.append(window(for: move))
            } else if path.count >= 2 {
                let move = LocationLogMove(
                    points: path,
                    transportMode: LocationLogTransportClassifier.classify(path),
                    distanceMeters: LocationLogGeometry.pathDistance(path),
                    longestGap: LocationLogGeometry.longestGap(path)
                )
                draft.moves.append(move)
                draft.occupancy.append(window(for: move))
            } else {
                draft.skippedSegmentCount += 1
            }
        }

        let rawPoints = parseRawSignals(rawSignals)
        if !rawPoints.isEmpty {
            applyRawSignals(rawPoints, to: &draft)
        }
        return draft
    }

    /// One `locations[]` object from Records.json. Returns nil for unusable fixes.
    static func parseRecordObject(data: Data) -> LocationLogPoint? {
        guard let object = (try? jsonObject(data)) as? [String: Any] else { return nil }
        return parseRecord(object)
    }

    static func parseRecord(_ object: [String: Any]) -> LocationLogPoint? {
        guard let coordinate = GoogleTimelineCoordinates.coordinate(from: object),
              let timestamp = GoogleTimelineTime.parse(object["timestamp"])
                ?? GoogleTimelineTime.parse(object["timestampMs"]) else {
            return nil
        }
        let accuracy = GoogleTimelineJSON.double(object["accuracy"])
        return LocationLogPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: GoogleTimelineJSON.double(object["altitude"]),
            horizontalAccuracy: accuracy,
            timestamp: timestamp
        )
    }

    /// Maps a Google activity type onto Moves `TransportMode`. `IN_BUS` is train.
    static func transportMode(from raw: String?) -> TransportMode {
        GoogleTimelineTransport.map(raw)
    }

    // MARK: Semantic pieces

    private static func parsePlaceVisit(
        _ visit: [String: Any],
        includeChildren: Bool
    ) -> [LocationLogStay] {
        var stays: [LocationLogStay] = []
        if let stay = parseOnePlaceVisit(visit) {
            stays.append(stay)
        }
        if includeChildren, let children = visit["childVisits"] as? [[String: Any]] {
            for child in children {
                stays.append(contentsOf: parsePlaceVisit(child, includeChildren: true))
            }
        }
        return stays
    }

    private static func parseOnePlaceVisit(_ visit: [String: Any]) -> LocationLogStay? {
        let location = visit["location"] as? [String: Any] ?? [:]
        let duration = visit["duration"] as? [String: Any] ?? [:]
        guard let start = GoogleTimelineTime.parse(duration["startTimestamp"]),
              let end = GoogleTimelineTime.parse(duration["endTimestamp"]) else {
            return nil
        }
        let coordinate = GoogleTimelineCoordinates.coordinate(from: location)
            ?? GoogleTimelineCoordinates.coordinate(
                latitudeE7: GoogleTimelineJSON.int(visit["centerLatE7"]),
                longitudeE7: GoogleTimelineJSON.int(visit["centerLngE7"])
            )
        guard let coordinate else { return nil }

        let path = simplifiedRawPoints(visit["simplifiedRawPath"])
        var points = path
        if points.isEmpty {
            points = [
                LocationLogPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    horizontalAccuracy: 40,
                    timestamp: start
                ),
                LocationLogPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    horizontalAccuracy: 40,
                    timestamp: end
                ),
            ]
        }
        let radius = max(
            path.map { $0.distance(to: LocationLogPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, timestamp: start)) }.max() ?? 40,
            20
        )
        let confirmed = isUserConfirmed(visit)
        return LocationLogStay(
            arrivalDate: start,
            departureDate: max(end, start.addingTimeInterval(1)),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius,
            points: points,
            name: visitName(from: location),
            isUserConfirmed: confirmed
        )
    }

    private static func parseActivitySegment(_ segment: [String: Any]) -> LocationLogMove? {
        let duration = segment["duration"] as? [String: Any] ?? [:]
        guard let start = GoogleTimelineTime.parse(duration["startTimestamp"]),
              let end = GoogleTimelineTime.parse(duration["endTimestamp"]) else {
            return nil
        }

        var points = pathPoints(from: segment, start: start, end: end)
        if points.count < 2 {
            let startCoord = GoogleTimelineCoordinates.coordinate(from: segment["startLocation"] as? [String: Any] ?? [:])
            let endCoord = GoogleTimelineCoordinates.coordinate(from: segment["endLocation"] as? [String: Any] ?? [:])
            if let startCoord, let endCoord {
                points = GoogleTimelineCoordinates.interpolatedPoints(
                    coordinates: [startCoord, endCoord],
                    from: start,
                    to: end
                )
            }
        }
        guard points.count >= 2 else { return nil }

        let reportedDistance = GoogleTimelineJSON.double(segment["distance"])
        let distance = (reportedDistance ?? 0) > 0
            ? reportedDistance!
            : LocationLogGeometry.pathDistance(points)
        let rawType = segment["activityType"] as? String
            ?? firstActivityType(segment["activities"])
        return LocationLogMove(
            points: points,
            transportMode: GoogleTimelineTransport.map(rawType),
            distanceMeters: distance,
            longestGap: LocationLogGeometry.longestGap(points)
        )
    }

    /// Prefer `waypointPath.waypoints` (`latE7`/`lngE7`); else simplified raw; else transit stops.
    private static func pathPoints(
        from segment: [String: Any],
        start: Date,
        end: Date
    ) -> [LocationLogPoint] {
        if let waypointPath = segment["waypointPath"] as? [String: Any],
           let waypoints = waypointPath["waypoints"] as? [[String: Any]] {
            let coordinates = waypoints.compactMap { GoogleTimelineCoordinates.coordinate(from: $0) }
            if coordinates.count >= 2 {
                return GoogleTimelineCoordinates.interpolatedPoints(
                    coordinates: coordinates,
                    from: start,
                    to: end
                )
            }
        }
        let simplified = simplifiedRawPoints(segment["simplifiedRawPath"])
        if simplified.count >= 2 {
            return simplified
        }
        if let transitPath = segment["transitPath"] as? [String: Any],
           let stops = transitPath["transitStops"] as? [[String: Any]] {
            let coordinates = stops.compactMap { GoogleTimelineCoordinates.coordinate(from: $0) }
            if coordinates.count >= 2 {
                return GoogleTimelineCoordinates.interpolatedPoints(
                    coordinates: coordinates,
                    from: start,
                    to: end
                )
            }
        }
        return simplified
    }

    private static func simplifiedRawPoints(_ value: Any?) -> [LocationLogPoint] {
        guard let path = value as? [String: Any],
              let points = path["points"] as? [[String: Any]] else {
            return []
        }
        return points.compactMap { point in
            guard let coordinate = GoogleTimelineCoordinates.coordinate(from: point) else { return nil }
            let timestamp = GoogleTimelineTime.parse(point["timestamp"]) ?? .distantPast
            guard timestamp != .distantPast else { return nil }
            return LocationLogPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                horizontalAccuracy: GoogleTimelineJSON.double(point["accuracyMeters"]),
                timestamp: timestamp
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private static func firstActivityType(_ value: Any?) -> String? {
        guard let activities = value as? [[String: Any]], let first = activities.first else {
            return nil
        }
        return first["activityType"] as? String ?? first["type"] as? String
    }

    private static func visitName(from location: [String: Any]) -> String? {
        if let name = (location["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        switch location["semanticType"] as? String {
        case "TYPE_HOME": return "Home"
        case "TYPE_WORK": return "Work"
        default: return nil
        }
    }

    private static func isUserConfirmed(_ visit: [String: Any]) -> Bool {
        if visit["placeConfidence"] as? String == "USER_CONFIRMED" { return true }
        if visit["editConfirmationStatus"] as? String == "CONFIRMED" { return true }
        return false
    }

    // MARK: On-device pieces

    private static func parseOnDeviceVisit(
        _ visit: [String: Any],
        start: Date,
        end: Date,
        path: [LocationLogPoint]
    ) -> LocationLogStay? {
        let candidate = visit["topCandidate"] as? [String: Any] ?? visit
        let placeLocation = candidate["placeLocation"] as? [String: Any] ?? candidate
        guard let coordinate = GoogleTimelineCoordinates.coordinate(from: placeLocation) else {
            return nil
        }
        var points = path
        if points.isEmpty {
            points = GoogleTimelineCoordinates.interpolatedPoints(
                coordinates: [coordinate, coordinate],
                from: start,
                to: end
            )
        }
        let semantic = candidate["semanticType"] as? String
        let name = visitName(from: [
            "name": candidate["placeName"] as? String ?? candidate["name"] as? String ?? "",
            "semanticType": semantic as Any,
        ])
        return LocationLogStay(
            arrivalDate: start,
            departureDate: max(end, start.addingTimeInterval(1)),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: 40,
            points: points,
            name: name,
            isUserConfirmed: false
        )
    }

    private static func parseOnDeviceActivity(
        _ activity: [String: Any],
        start: Date,
        end: Date,
        path: [LocationLogPoint]
    ) -> LocationLogMove? {
        var points = path
        if points.count < 2 {
            let startCoord = GoogleTimelineCoordinates.coordinate(from: activity["start"] as? [String: Any] ?? [:])
                ?? GoogleTimelineCoordinates.parseLatLng(activity["start"] as? String)
            let endCoord = GoogleTimelineCoordinates.coordinate(from: activity["end"] as? [String: Any] ?? [:])
                ?? GoogleTimelineCoordinates.parseLatLng(activity["end"] as? String)
            if let startCoord, let endCoord {
                points = GoogleTimelineCoordinates.interpolatedPoints(
                    coordinates: [startCoord, endCoord],
                    from: start,
                    to: end
                )
            }
        }
        guard points.count >= 2 else { return nil }
        let candidate = activity["topCandidate"] as? [String: Any] ?? [:]
        let rawType = candidate["type"] as? String ?? activity["type"] as? String
        let distance = GoogleTimelineJSON.double(activity["distanceMeters"])
            ?? LocationLogGeometry.pathDistance(points)
        return LocationLogMove(
            points: points,
            transportMode: GoogleTimelineTransport.map(rawType),
            distanceMeters: distance,
            longestGap: LocationLogGeometry.longestGap(points)
        )
    }

    private static func parseTimelinePath(_ value: Any?, fallbackStart: Date, fallbackEnd: Date) -> [LocationLogPoint] {
        guard let items = value as? [[String: Any]] else { return [] }
        let span = max(fallbackEnd.timeIntervalSince(fallbackStart), 1)
        var points: [LocationLogPoint] = []
        for (index, item) in items.enumerated() {
            let rawPoint = item["point"] as? String ?? item["latLng"] as? String
            guard let coordinate = GoogleTimelineCoordinates.coordinate(from: item)
                    ?? GoogleTimelineCoordinates.parseLatLng(rawPoint) else {
                continue
            }
            let timestamp = GoogleTimelineTime.parse(item["time"] ?? item["timestamp"])
                ?? fallbackStart.addingTimeInterval(span * Double(index) / Double(max(items.count - 1, 1)))
            points.append(
                LocationLogPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    horizontalAccuracy: GoogleTimelineJSON.double(item["accuracyMeters"]),
                    timestamp: timestamp
                )
            )
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private static func parseRawSignals(_ signals: [Any]) -> [LocationLogPoint] {
        signals.compactMap { item in
            let dictionary = item as? [String: Any] ?? [:]
            let position = dictionary["position"] as? [String: Any] ?? dictionary
            guard let coordinate = GoogleTimelineCoordinates.coordinate(from: position),
                  let timestamp = GoogleTimelineTime.parse(position["timestamp"] ?? dictionary["timestamp"]) else {
                return nil
            }
            return LocationLogPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                horizontalAccuracy: GoogleTimelineJSON.double(position["accuracyMeters"]),
                timestamp: timestamp
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    /// Prefer `rawSignals` as the sample stream when the on-device export included them.
    private static func applyRawSignals(_ rawPoints: [LocationLogPoint], to draft: inout GoogleTimelineDraft) {
        func points(in start: Date, _ end: Date) -> [LocationLogPoint] {
            rawPoints.filter { $0.timestamp >= start && $0.timestamp <= end }
        }
        draft.stays = draft.stays.map { stay in
            let overlay = points(in: stay.arrivalDate, stay.departureDate)
            guard overlay.count >= 2 else { return stay }
            return LocationLogStay(
                arrivalDate: stay.arrivalDate,
                departureDate: stay.departureDate,
                latitude: stay.latitude,
                longitude: stay.longitude,
                radius: stay.radius,
                points: overlay,
                name: stay.name,
                isUserConfirmed: stay.isUserConfirmed
            )
        }
        draft.moves = draft.moves.map { move in
            let overlay = points(in: move.startDate, move.endDate)
            guard overlay.count >= 2 else { return move }
            return LocationLogMove(
                points: overlay,
                transportMode: move.transportMode,
                distanceMeters: max(move.distanceMeters, LocationLogGeometry.pathDistance(overlay)),
                longestGap: LocationLogGeometry.longestGap(overlay)
            )
        }
    }

    private static func window(for stay: LocationLogStay) -> GoogleOccupiedWindow {
        GoogleOccupiedWindow(
            start: stay.arrivalDate,
            end: stay.departureDate,
            latitude: stay.latitude,
            longitude: stay.longitude,
            isVisit: true
        )
    }

    private static func window(for move: LocationLogMove) -> GoogleOccupiedWindow {
        GoogleOccupiedWindow(
            start: move.startDate,
            end: move.endDate,
            latitude: move.points.first?.latitude ?? 0,
            longitude: move.points.first?.longitude ?? 0,
            isVisit: false
        )
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Transport

enum GoogleTimelineTransport {
    /// Google activity types → Moves modes. There is no `bus` mode; `IN_BUS` is train.
    static func map(_ raw: String?) -> TransportMode {
        guard let raw else { return .unknown }
        switch raw.uppercased() {
        case "WALKING", "ON_FOOT":
            return .walking
        case "RUNNING":
            return .running
        case "CYCLING", "ON_BICYCLE":
            return .cycling
        case "IN_PASSENGER_VEHICLE", "IN_VEHICLE", "MOTORCYCLING":
            return .automotive
        case "IN_TRAIN", "IN_SUBWAY", "IN_TRAM", "IN_BUS":
            return .train
        case "FLYING":
            return .plane
        case "IN_FERRY", "SAILING", "BOATING":
            return .boat
        case "SWIMMING":
            return .swimming
        default:
            return .unknown
        }
    }
}

// MARK: - Coordinates

enum GoogleTimelineCoordinates {
    static let e7: Double = 10_000_000

    static func fromE7(_ value: Int) -> Double {
        Double(value) / e7
    }

    static func coordinate(latitudeE7: Int?, longitudeE7: Int?) -> CLLocationCoordinate2D? {
        guard let latitudeE7, let longitudeE7 else { return nil }
        let latitude = fromE7(latitudeE7)
        let longitude = fromE7(longitudeE7)
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            return nil
        }
        if latitudeE7 == 0 && longitudeE7 == 0 { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Reads `latitudeE7`/`longitudeE7`, waypoint `latE7`/`lngE7`, or `latLng` strings.
    static func coordinate(from object: [String: Any]) -> CLLocationCoordinate2D? {
        if let latitude = GoogleTimelineJSON.int(object["latitudeE7"]),
           let longitude = GoogleTimelineJSON.int(object["longitudeE7"]) {
            return coordinate(latitudeE7: latitude, longitudeE7: longitude)
        }
        if let latitude = GoogleTimelineJSON.int(object["latE7"]),
           let longitude = GoogleTimelineJSON.int(object["lngE7"]) {
            return coordinate(latitudeE7: latitude, longitudeE7: longitude)
        }
        if let latitude = GoogleTimelineJSON.double(object["latitude"]),
           let longitude = GoogleTimelineJSON.double(object["longitude"]) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let latLng = object["latLng"] ?? object["LatLng"] ?? object["point"]
        if let string = latLng as? String {
            return parseLatLng(string)
        }
        if let nested = latLng as? [String: Any] {
            return coordinate(from: nested)
        }
        return nil
    }

    /// `"50.05°, 14.34°"`, `"geo:50.05,14.34"`, or `"50.05, 14.34"`.
    static func parseLatLng(_ raw: String?) -> CLLocationCoordinate2D? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.lowercased().hasPrefix("geo:") {
            text = String(text.dropFirst(4))
        }
        text = text.replacingOccurrences(of: "°", with: "")
        text = text.replacingOccurrences(of: " ", with: "")
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "/" })
        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func interpolatedPoints(
        coordinates: [CLLocationCoordinate2D],
        from start: Date,
        to end: Date,
        accuracy: Double = 25
    ) -> [LocationLogPoint] {
        guard !coordinates.isEmpty else { return [] }
        if coordinates.count == 1 {
            let coordinate = coordinates[0]
            return [
                LocationLogPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, horizontalAccuracy: accuracy, timestamp: start),
                LocationLogPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, horizontalAccuracy: accuracy, timestamp: max(end, start.addingTimeInterval(1))),
            ]
        }
        let span = max(end.timeIntervalSince(start), 1)
        let last = Double(coordinates.count - 1)
        return coordinates.enumerated().map { index, coordinate in
            let timestamp = start.addingTimeInterval(span * Double(index) / last)
            return LocationLogPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                horizontalAccuracy: accuracy,
                timestamp: timestamp
            )
        }
    }
}

// MARK: - JSON / time helpers

enum GoogleTimelineJSON {
    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value.rounded()) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

enum GoogleTimelineTime {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = doubleNumber(value) {
            return fromEpochNumber(number)
        }
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let number = Double(raw) {
            return fromEpochNumber(number)
        }
        lock.lock()
        let fractionalDate = fractional.date(from: raw)
        let plainDate = fractionalDate ?? plain.date(from: raw)
        lock.unlock()
        return plainDate
    }

    private static func doubleNumber(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func fromEpochNumber(_ value: Double) -> Date? {
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}
