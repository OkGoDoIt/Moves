import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Archive model

/// A format produced by Moves' Settings export / nightly iCloud Drive backup.
enum TimelineArchiveFormat: String, Hashable {
    case gpx
    case geoJSON
    case csv
}

/// One GPS vertex from a Moves export. GPX includes real timestamps and elevation;
/// GeoJSON LineStrings only have coordinates, so `timestamp` and `elevation` stay nil
/// until the merger copies times from GPX or interpolates from the move's start/end.
struct TimelineArchivePoint: Equatable {
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var timestamp: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A visit reconstructed from one or more export files.
struct TimelineArchivePlace: Equatable {
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    var userLabel: String?
    var autoLabel: String?
    var title: String?
    var comment: String?
    var dayKey: String?
    var source: TimelineArchiveFormat

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A movement segment reconstructed from one or more export files.
struct TimelineArchiveMove: Equatable {
    var startDate: Date
    var endDate: Date
    var transportMode: TransportMode
    var distanceMeters: Double?
    var stepCount: Int?
    var startPlaceTitle: String?
    var endPlaceTitle: String?
    var comment: String?
    var dayKey: String?
    var points: [TimelineArchivePoint]
    var source: TimelineArchiveFormat
}

/// Combined timeline extracted from one file or merged from several.
struct TimelineArchive: Equatable {
    var places: [TimelineArchivePlace]
    var moves: [TimelineArchiveMove]
    var formats: Set<TimelineArchiveFormat>

    static let empty = TimelineArchive(places: [], moves: [], formats: [])

    var isEmpty: Bool { places.isEmpty && moves.isEmpty }
}

struct TimelineArchiveImportReport {
    var fileCount: Int
    var parsedFileCount: Int
    var placeCount: Int
    var moveCount: Int
    var sampleCount: Int
    var formats: Set<TimelineArchiveFormat>
    var skippedFileNames: [String]
    var warnings: [String]

    var summary: String {
        var parts: [String] = []
        if placeCount > 0 {
            parts.append("\(placeCount) place\(placeCount == 1 ? "" : "s")")
        }
        if moveCount > 0 {
            parts.append("\(moveCount) move\(moveCount == 1 ? "" : "s")")
        }
        if sampleCount > 0 {
            parts.append("\(sampleCount) GPS point\(sampleCount == 1 ? "" : "s")")
        }

        let restored = parts.isEmpty ? "No timeline records" : parts.joined(separator: ", ")
        var message = "Restored \(restored) from \(parsedFileCount) file\(parsedFileCount == 1 ? "" : "s")."

        if formats.contains(.gpx) && (formats.contains(.geoJSON) || formats.contains(.csv)) {
            message += " GPS times came from GPX; names, notes, and transport modes came from GeoJSON/CSV."
        } else if formats == [.geoJSON] {
            message += " Place names, notes, and transport modes were restored. GPS points use interpolated times along each route."
        } else if formats == [.gpx] {
            message += " Tracks kept their original GPS times. Place names from waypoints were restored; transport modes are unknown unless a single-move GPX included them."
        } else if formats == [.csv] {
            message += " Places, times, notes, and transport modes were restored. Route shapes are limited to start and end points."
        }

        if !skippedFileNames.isEmpty {
            message += " Skipped \(skippedFileNames.joined(separator: ", "))."
        }
        return message
    }
}

enum TimelineArchiveImportError: LocalizedError {
    case noFiles
    case noTimelineData

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "No files selected."
        case .noTimelineData:
            return "No Moves timeline data was found in the selected files. Export All Days as GPX, GeoJSON, and CSV from the other Moves app, then select those files together."
        }
    }
}

// MARK: - File parsing

struct TimelineArchiveParseError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum TimelineArchiveFileParser {
    static func parse(fileName: String, data: Data) -> Result<TimelineArchive, TimelineArchiveParseError> {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmedName.lowercased()

        if lowercased.hasSuffix(".gpx") {
            return parseGPX(data, fileName: trimmedName)
        }
        if lowercased.hasSuffix(".geojson") || lowercased.hasSuffix(".json") {
            return parseGeoJSON(data)
        }
        if lowercased.hasSuffix(".csv") {
            return parseCSV(data)
        }

        if let xml = String(data: data.prefix(180), encoding: .utf8),
           xml.contains("<gpx") {
            return parseGPX(data, fileName: trimmedName)
        }
        if data.first == UInt8(ascii: "{") || data.first == UInt8(ascii: "[") {
            return parseGeoJSON(data)
        }

        return .failure(TimelineArchiveParseError(message: "\(trimmedName) is not a Moves GPX, GeoJSON, or CSV export"))
    }

    static func parseAll(files: [(name: String, data: Data)]) -> (archive: TimelineArchive, skipped: [String], warnings: [String]) {
        var archives: [TimelineArchive] = []
        var skipped: [String] = []
        var warnings: [String] = []

        for file in files {
            switch parse(fileName: file.name, data: file.data) {
            case .success(let archive):
                if archive.isEmpty {
                    skipped.append(file.name)
                } else {
                    archives.append(archive)
                }
            case .failure(let error):
                skipped.append(file.name)
                warnings.append(error.message)
            }
        }

        return (TimelineArchiveMerger.merge(archives), skipped, warnings)
    }

    private static func parseGeoJSON(_ data: Data) -> Result<TimelineArchive, TimelineArchiveParseError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(TimelineArchiveParseError(message: "GeoJSON file is not valid JSON"))
        }

        var places: [TimelineArchivePlace] = []
        var moves: [TimelineArchiveMove] = []

        let features: [[String: Any]]
        if let type = object["type"] as? String, type == "FeatureCollection" {
            features = object["features"] as? [[String: Any]] ?? []
        } else {
            features = [object]
        }

        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let geometry = feature["geometry"] as? [String: Any] ?? feature
            let geometryType = geometry["type"] as? String ?? ""
            let recordType = stringValue(properties["record_type"])?.lowercased()

            if recordType == "place" || (recordType == nil && geometryType == "Point") {
                if let place = place(fromGeoJSON: properties, geometry: geometry) {
                    places.append(place)
                }
            } else if recordType == "move" || (recordType == nil && (geometryType == "LineString" || geometryType == "MultiLineString")) {
                moves.append(contentsOf: movesFromGeoJSON(properties: properties, geometry: geometry))
            }
        }

        guard !places.isEmpty || !moves.isEmpty else {
            return .failure(TimelineArchiveParseError(message: "GeoJSON file has no place or move features"))
        }

        return .success(
            TimelineArchive(places: places, moves: moves, formats: [.geoJSON])
        )
    }

    private static func place(fromGeoJSON properties: [String: Any], geometry: [String: Any]) -> TimelineArchivePlace? {
        guard let coordinate = firstCoordinate(in: geometry),
              let arrival = parseDate(stringValue(properties["arrival_time"])) else {
            return nil
        }

        let title = nonempty(stringValue(properties["title"]))
        return TimelineArchivePlace(
            arrivalDate: arrival,
            departureDate: parseDate(stringValue(properties["departure_time"])),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            userLabel: nonempty(stringValue(properties["user_label"])),
            autoLabel: nonempty(stringValue(properties["auto_label"])),
            title: title,
            comment: nonempty(stringValue(properties["comment"])),
            dayKey: nonempty(stringValue(properties["day_key"])),
            source: .geoJSON
        )
    }

    private static func movesFromGeoJSON(properties: [String: Any], geometry: [String: Any]) -> [TimelineArchiveMove] {
        let lines = lineStrings(in: geometry)
        guard let start = parseDate(stringValue(properties["start_time"])),
              let end = parseDate(stringValue(properties["end_time"])) else {
            return []
        }

        let mode = parseTransportMode(stringValue(properties["transport_mode"])) ?? .unknown
        let distance = doubleValue(properties["distance_meters"])
        let steps = intValue(properties["step_count"])
        let comment = nonempty(stringValue(properties["comment"]))
        let dayKey = nonempty(stringValue(properties["day_key"]))
        let startTitle = nonempty(stringValue(properties["start_place"]))
        let endTitle = nonempty(stringValue(properties["end_place"]))

        return lines.compactMap { points in
            guard points.count >= 2 else { return nil }
            return TimelineArchiveMove(
                startDate: start,
                endDate: max(end, start),
                transportMode: mode,
                distanceMeters: distance,
                stepCount: steps,
                startPlaceTitle: unknownTitle(startTitle) ? nil : startTitle,
                endPlaceTitle: unknownTitle(endTitle) ? nil : endTitle,
                comment: comment,
                dayKey: dayKey,
                points: points,
                source: .geoJSON
            )
        }
    }

    private static func parseCSV(_ data: Data) -> Result<TimelineArchive, TimelineArchiveParseError> {
        let payload = stripUTF8BOM(data)
        guard let text = String(data: payload, encoding: .utf8) else {
            return .failure(TimelineArchiveParseError(message: "CSV file is not valid UTF-8"))
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard let headerLine = lines.first else {
            return .failure(TimelineArchiveParseError(message: "CSV file is empty"))
        }

        let header = parseCSVLine(headerLine).map { $0.lowercased() }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        let rows = lines.dropFirst()

        var places: [TimelineArchivePlace] = []
        var moves: [TimelineArchiveMove] = []

        for line in rows {
            let fields = parseCSVLine(line)
            func field(_ name: String) -> String? {
                guard let index = columns[name], index < fields.count else { return nil }
                return nonempty(fields[index])
            }

            let recordType = field("record_type")?.lowercased()
            let start = parseDate(field("start_time"))
            let end = parseDate(field("end_time"))
            let title = field("title")
            let dayKey = field("day_key")
            let comment = field("comment")

            if recordType == "place" {
                guard let arrival = start,
                      let latitude = doubleValue(field("latitude")),
                      let longitude = doubleValue(field("longitude")) else {
                    continue
                }
                places.append(
                    TimelineArchivePlace(
                        arrivalDate: arrival,
                        departureDate: end,
                        latitude: latitude,
                        longitude: longitude,
                        userLabel: nil,
                        autoLabel: nil,
                        title: title,
                        comment: comment,
                        dayKey: dayKey,
                        source: .csv
                    )
                )
            } else if recordType == "move" {
                guard let startDate = start, let endDate = end else { continue }
                let titles = splitMoveTitle(title)
                moves.append(
                    TimelineArchiveMove(
                        startDate: startDate,
                        endDate: max(endDate, startDate),
                        transportMode: parseTransportMode(field("transport_mode")) ?? .unknown,
                        distanceMeters: doubleValue(field("distance_meters")),
                        stepCount: intValue(field("step_count")),
                        startPlaceTitle: titles?.start,
                        endPlaceTitle: titles?.end,
                        comment: comment,
                        dayKey: dayKey,
                        points: [],
                        source: .csv
                    )
                )
            }
        }

        guard !places.isEmpty || !moves.isEmpty else {
            return .failure(TimelineArchiveParseError(message: "CSV file has no place or move rows"))
        }

        return .success(
            TimelineArchive(places: places, moves: moves, formats: [.csv])
        )
    }

    private static func parseGPX(_ data: Data, fileName: String) -> Result<TimelineArchive, TimelineArchiveParseError> {
        let parser = XMLParser(data: data)
        let delegate = MovesGPXArchiveParser()
        parser.delegate = delegate
        guard parser.parse() else {
            return .failure(
                TimelineArchiveParseError(
                    message: parser.parserError?.localizedDescription ?? "GPX file could not be parsed"
                )
            )
        }
        delegate.finish()

        var moves = delegate.moves
        if shouldInferTransportMode(from: fileName),
           let inferred = inferredTransportMode(from: fileName) {
            for index in moves.indices where moves[index].transportMode == .unknown {
                moves[index].transportMode = inferred
            }
        }

        guard !delegate.places.isEmpty || !moves.isEmpty else {
            return .failure(TimelineArchiveParseError(message: "GPX file has no waypoints or tracks"))
        }

        return .success(
            TimelineArchive(places: delegate.places, moves: moves, formats: [.gpx])
        )
    }
}

// MARK: - Merge

enum TimelineArchiveMerger {
    private static let placeArrivalWindow: TimeInterval = 3 * 60
    private static let placeDistanceThreshold: CLLocationDistance = 90
    private static let moveTimeWindow: TimeInterval = 3 * 60
    private static let moveEndTimeWindow: TimeInterval = 4 * 60
    private static let moveEndpointDistance: CLLocationDistance = 140

    /// Combines several exports so GeoJSON/CSV supply names, notes, and modes,
    /// while GPX supplies timed GPS vertices whenever the tracks overlap.
    static func merge(_ archives: [TimelineArchive]) -> TimelineArchive {
        let places = mergePlaces(archives.flatMap(\.places))
        var moves = mergeMoves(archives.flatMap(\.moves))
        attachCSVGeometry(to: &moves, places: places)
        for index in moves.indices {
            moves[index].points = interpolatedPoints(for: moves[index])
        }

        return TimelineArchive(
            places: places.sorted(by: { $0.arrivalDate < $1.arrivalDate }),
            moves: moves.sorted(by: { $0.startDate < $1.startDate }),
            formats: Set(archives.flatMap(\.formats))
        )
    }

    private static func mergePlaces(_ places: [TimelineArchivePlace]) -> [TimelineArchivePlace] {
        var merged: [TimelineArchivePlace] = []
        for place in places.sorted(by: sourcePriority) {
            if let index = merged.firstIndex(where: { matches($0, place) }) {
                merged[index] = fill(merged[index], with: place)
            } else {
                merged.append(normalized(place))
            }
        }
        return merged
    }

    private static func mergeMoves(_ moves: [TimelineArchiveMove]) -> [TimelineArchiveMove] {
        var merged: [TimelineArchiveMove] = []
        for move in moves.sorted(by: sourcePriority) {
            if let index = bestMoveMatch(for: move, in: merged) {
                merged[index] = fill(merged[index], with: move)
            } else {
                merged.append(move)
            }
        }
        return stitchUnknownMoves(merged)
    }

    /// The real export can contain two walks that start at the same second
    /// (same garden, different destinations). Prefer the candidate whose
    /// end time and endpoints are closest instead of the first match.
    private static func bestMoveMatch(for move: TimelineArchiveMove, in merged: [TimelineArchiveMove]) -> Int? {
        let candidates = merged.enumerated().filter { matches($0.element, move) }
        return candidates.min { lhs, rhs in
            matchScore(lhs.element, move) < matchScore(rhs.element, move)
        }?.offset
    }

    private static func matchScore(_ lhs: TimelineArchiveMove, _ rhs: TimelineArchiveMove) -> Double {
        var score = abs(lhs.startDate.timeIntervalSince(rhs.startDate))
            + abs(lhs.endDate.timeIntervalSince(rhs.endDate))
        if let lhsStart = lhs.points.first?.coordinate, let rhsStart = rhs.points.first?.coordinate {
            score += distanceMeters(lhsStart, rhsStart)
        }
        if let lhsEnd = lhs.points.last?.coordinate, let rhsEnd = rhs.points.last?.coordinate {
            score += distanceMeters(lhsEnd, rhsEnd)
        }
        return score
    }

    /// CSV sometimes keeps a walk that GeoJSON dropped because the route had
    /// too few points, splitting it into "Place to Unknown" + "Unknown to Place".
    /// If those two rows abut, join them back into one move.
    private static func stitchUnknownMoves(_ moves: [TimelineArchiveMove]) -> [TimelineArchiveMove] {
        let ordered = moves.sorted(by: { $0.startDate < $1.startDate })
        var result: [TimelineArchiveMove] = []
        var index = 0
        while index < ordered.count {
            let current = ordered[index]
            let nextIndex = index + 1
            if nextIndex < ordered.count {
                let next = ordered[nextIndex]
                if shouldStitch(current, onto: next) {
                    result.append(stitched(current, onto: next))
                    index += 2
                    continue
                }
            }
            result.append(current)
            index += 1
        }
        return result
    }

    private static func shouldStitch(_ lhs: TimelineArchiveMove, onto rhs: TimelineArchiveMove) -> Bool {
        guard lhs.endPlaceTitle == nil, rhs.startPlaceTitle == nil,
              lhs.points.count < 2, rhs.points.count < 2,
              lhs.startPlaceTitle != nil || rhs.endPlaceTitle != nil else {
            return false
        }
        guard abs(rhs.startDate.timeIntervalSince(lhs.endDate)) <= 60 else {
            return false
        }
        if lhs.transportMode != .unknown, rhs.transportMode != .unknown {
            return lhs.transportMode == rhs.transportMode
        }
        return true
    }

    private static func stitched(_ lhs: TimelineArchiveMove, onto rhs: TimelineArchiveMove) -> TimelineArchiveMove {
        var combined = lhs
        combined.endDate = max(lhs.endDate, rhs.endDate)
        combined.startPlaceTitle = lhs.startPlaceTitle ?? rhs.startPlaceTitle
        combined.endPlaceTitle = rhs.endPlaceTitle ?? lhs.endPlaceTitle
        if combined.transportMode == .unknown {
            combined.transportMode = rhs.transportMode
        }
        let leftDistance = lhs.distanceMeters ?? 0
        let rightDistance = rhs.distanceMeters ?? 0
        if leftDistance + rightDistance > 0 {
            combined.distanceMeters = leftDistance + rightDistance
        }
        let leftSteps = lhs.stepCount ?? 0
        let rightSteps = rhs.stepCount ?? 0
        if lhs.stepCount != nil || rhs.stepCount != nil {
            combined.stepCount = leftSteps + rightSteps
        }
        if combined.comment == nil {
            combined.comment = rhs.comment
        }
        combined.points = preferredPoints(lhs.points, rhs.points)
        return combined
    }

    private static func matches(_ lhs: TimelineArchivePlace, _ rhs: TimelineArchivePlace) -> Bool {
        let arrivalDelta = abs(lhs.arrivalDate.timeIntervalSince(rhs.arrivalDate))
        guard arrivalDelta <= placeArrivalWindow else { return false }
        return distanceMeters(lhs.coordinate, rhs.coordinate) <= placeDistanceThreshold
    }

    private static func matches(_ lhs: TimelineArchiveMove, _ rhs: TimelineArchiveMove) -> Bool {
        let startDelta = abs(lhs.startDate.timeIntervalSince(rhs.startDate))
        guard startDelta <= moveTimeWindow else { return false }

        let endDelta = abs(lhs.endDate.timeIntervalSince(rhs.endDate))
        if endDelta <= moveEndTimeWindow {
            return true
        }

        guard let lhsStart = lhs.points.first?.coordinate ?? nil,
              let lhsEnd = lhs.points.last?.coordinate ?? nil,
              let rhsStart = rhs.points.first?.coordinate ?? nil,
              let rhsEnd = rhs.points.last?.coordinate ?? nil else {
            return false
        }

        return distanceMeters(lhsStart, rhsStart) <= moveEndpointDistance
            && distanceMeters(lhsEnd, rhsEnd) <= moveEndpointDistance
    }

    private static func fill(_ base: TimelineArchivePlace, with incoming: TimelineArchivePlace) -> TimelineArchivePlace {
        var result = base
        if result.userLabel == nil { result.userLabel = incoming.userLabel }
        if result.autoLabel == nil { result.autoLabel = incoming.autoLabel }
        if result.comment == nil { result.comment = incoming.comment }
        if let incomingDeparture = incoming.departureDate {
            if let currentDeparture = result.departureDate {
                result.departureDate = max(currentDeparture, incomingDeparture)
            } else {
                result.departureDate = incomingDeparture
            }
        }
        if incoming.arrivalDate < result.arrivalDate {
            result.arrivalDate = incoming.arrivalDate
        }
        if result.dayKey == nil { result.dayKey = incoming.dayKey }
        if result.title == nil { result.title = incoming.title }
        applyFallbackTitle(to: &result)
        return result
    }

    private static func fill(_ base: TimelineArchiveMove, with incoming: TimelineArchiveMove) -> TimelineArchiveMove {
        var result = base
        if result.transportMode == .unknown, incoming.transportMode != .unknown {
            result.transportMode = incoming.transportMode
        }
        if result.comment == nil { result.comment = incoming.comment }
        if result.stepCount == nil { result.stepCount = incoming.stepCount }
        if result.distanceMeters == nil || (result.distanceMeters ?? 0) <= 0 {
            result.distanceMeters = incoming.distanceMeters
        }
        if result.startPlaceTitle == nil { result.startPlaceTitle = incoming.startPlaceTitle }
        if result.endPlaceTitle == nil { result.endPlaceTitle = incoming.endPlaceTitle }
        if result.dayKey == nil { result.dayKey = incoming.dayKey }
        result.points = preferredPoints(result.points, incoming.points)
        return result
    }

    private static func normalized(_ place: TimelineArchivePlace) -> TimelineArchivePlace {
        var result = place
        applyFallbackTitle(to: &result)
        return result
    }

    private static func applyFallbackTitle(to place: inout TimelineArchivePlace) {
        guard place.userLabel == nil, place.autoLabel == nil,
              let title = place.title, isMeaningfulPlaceTitle(title) else {
            return
        }
        place.userLabel = title
    }

    private static func preferredPoints(
        _ lhs: [TimelineArchivePoint],
        _ rhs: [TimelineArchivePoint]
    ) -> [TimelineArchivePoint] {
        let leftScore = geometryScore(lhs)
        let rightScore = geometryScore(rhs)
        if rightScore == leftScore {
            return lhs.count >= rhs.count ? lhs : rhs
        }
        return rightScore > leftScore ? rhs : lhs
    }

    /// Timed, denser tracks outrank untimed GeoJSON lines, which outrank empty CSV rows.
    private static func geometryScore(_ points: [TimelineArchivePoint]) -> Int {
        guard points.count >= 2 else { return points.isEmpty ? 0 : 1 }
        let timedCount = points.filter { $0.timestamp != nil }.count
        let timedBonus = timedCount >= max(points.count / 2, 2) ? 1_000 : 0
        return timedBonus + points.count
    }

    private static func attachCSVGeometry(to moves: inout [TimelineArchiveMove], places: [TimelineArchivePlace]) {
        for index in moves.indices where moves[index].points.count < 2 {
            let start = places.first {
                matchesPlace($0, title: moves[index].startPlaceTitle, date: moves[index].startDate, isStart: true)
            }
            let end = places.first {
                matchesPlace($0, title: moves[index].endPlaceTitle, date: moves[index].endDate, isStart: false)
            }
            guard let start, let end else { continue }
            moves[index].points = [
                TimelineArchivePoint(
                    latitude: start.latitude,
                    longitude: start.longitude,
                    elevation: nil,
                    timestamp: moves[index].startDate
                ),
                TimelineArchivePoint(
                    latitude: end.latitude,
                    longitude: end.longitude,
                    elevation: nil,
                    timestamp: moves[index].endDate
                ),
            ]
        }
    }

    private static func matchesPlace(
        _ place: TimelineArchivePlace,
        title: String?,
        date: Date,
        isStart: Bool
    ) -> Bool {
        if let title, isMeaningfulPlaceTitle(title) {
            let placeTitle = place.userLabel ?? place.autoLabel ?? place.title
            if let placeTitle, placeTitle.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                if isStart {
                    return abs((place.departureDate ?? place.arrivalDate).timeIntervalSince(date)) <= moveTimeWindow
                        || (place.arrivalDate <= date && (place.departureDate == nil || place.departureDate! >= date.addingTimeInterval(-moveTimeWindow)))
                }
                return abs(place.arrivalDate.timeIntervalSince(date)) <= moveTimeWindow
            }
        }

        if isStart {
            return abs((place.departureDate ?? place.arrivalDate).timeIntervalSince(date)) <= moveTimeWindow
        }
        return abs(place.arrivalDate.timeIntervalSince(date)) <= moveTimeWindow
    }

    static func interpolatedPoints(for move: TimelineArchiveMove) -> [TimelineArchivePoint] {
        let unique = dedupe(move.points)
        guard unique.count >= 2 else { return unique }

        if unique.allSatisfy({ $0.timestamp != nil }) {
            return unique
        }

        return timestampedPoints(
            unique,
            startDate: move.startDate,
            endDate: move.endDate
        )
    }

    private static func sourcePriority(lhs: TimelineArchivePlace, rhs: TimelineArchivePlace) -> Bool {
        sourceRank(lhs.source) > sourceRank(rhs.source)
    }

    private static func sourcePriority(lhs: TimelineArchiveMove, rhs: TimelineArchiveMove) -> Bool {
        sourceRank(lhs.source) > sourceRank(rhs.source)
    }

    /// GeoJSON first so labels/modes win; CSV next; GPX last so it only fills gaps.
    private static func sourceRank(_ format: TimelineArchiveFormat) -> Int {
        switch format {
        case .geoJSON: return 3
        case .csv: return 2
        case .gpx: return 1
        }
    }
}

// MARK: - Locations

extension TimelineArchiveMove {
    /// Converts archive vertices into `CLLocation` values the repository can store.
    func locations() -> [CLLocation] {
        let points = TimelineArchiveMerger.interpolatedPoints(for: self)
        return points.map { point in
            let timestamp = point.timestamp ?? startDate
            let altitude = point.elevation ?? 0
            return CLLocation(
                coordinate: point.coordinate,
                altitude: altitude,
                horizontalAccuracy: 15,
                verticalAccuracy: point.elevation == nil ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: timestamp
            )
        }
    }
}

// MARK: - UI

@MainActor
final class TimelineArchiveImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: TimelineArchiveImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func importFiles(urls: [URL]) async {
        guard !isImporting else { return }
        let uniqueURLs = urls.uniqueForTimelineImport
        guard !uniqueURLs.isEmpty else {
            lastErrorMessage = TimelineArchiveImportError.noFiles.localizedDescription
            lastReport = nil
            return
        }

        isImporting = true
        importProgress = 0
        importProgressText = "Reading export files…"
        defer {
            isImporting = false
            importProgress = nil
            importProgressText = ""
        }

        do {
            var files: [(name: String, data: Data)] = []
            for (index, url) in uniqueURLs.enumerated() {
                importProgressText = "Reading \(index + 1) of \(uniqueURLs.count): \(url.lastPathComponent)"
                importProgress = Double(index) / Double(max(uniqueURLs.count + 1, 1))
                files.append((url.lastPathComponent, try readSecurityScopedData(from: url)))
            }

            importProgressText = "Combining GPX, GeoJSON, and CSV…"
            let parsed = await Task.detached(priority: .userInitiated) {
                TimelineArchiveFileParser.parseAll(files: files)
            }.value

            guard !parsed.archive.isEmpty else {
                throw TimelineArchiveImportError.noTimelineData
            }

            let repository = SwiftDataTimelineRepository(modelContext: modelContext)
            let persisted = try repository.importTimelineArchive(parsed.archive) { [weak self] fraction, text in
                self?.importProgress = fraction
                self?.importProgressText = text
            }

            var report = persisted
            report.fileCount = uniqueURLs.count
            report.parsedFileCount = uniqueURLs.count - parsed.skipped.count
            report.formats = parsed.archive.formats
            report.skippedFileNames = parsed.skipped
            report.warnings = parsed.warnings
            lastReport = report
            lastErrorMessage = nil
        } catch {
            lastReport = nil
            lastErrorMessage = error.localizedDescription
        }
    }

    private func readSecurityScopedData(from url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }
}

struct TimelineArchiveImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer: TimelineArchiveImporter
    @State private var isShowingFileImporter = false
    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    init(modelContext: ModelContext) {
        _importer = StateObject(wrappedValue: TimelineArchiveImporter(modelContext: modelContext))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                TimelineArchiveImportCard(title: "Moves Export") {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(importer.isImporting ? .secondary : MovesPalette.routeTracking)

                            Text(importer.isImporting ? "Restoring timeline…" : "Import Moves export files")
                                .font(.body.weight(.medium))
                                .foregroundStyle(importer.isImporting ? .secondary : .primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(importer.isImporting)

                    if importer.isImporting {
                        if let progress = importer.importProgress {
                            ProgressView(value: progress)
                                .tint(MovesPalette.routeTracking)
                        } else {
                            ProgressView()
                                .tint(MovesPalette.routeTracking)
                        }

                        if !importer.importProgressText.isEmpty {
                            Text(importer.importProgressText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("In the other Moves app, export All Days as GPX, GeoJSON, and CSV, then select every file here at once. GeoJSON and CSV restore names, notes, and transport modes. GPX restores the original GPS times and elevation. Nightly iCloud Drive backups of those same formats work too.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
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
        .navigationTitle("Timeline Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: TimelineArchiveImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    await importer.importFiles(urls: urls)
                    importMessage = importer.lastReport?.summary
                        ?? importer.lastErrorMessage
                        ?? "No timeline data was imported."
                    isShowingImportMessage = true
                }
            case .failure(let error):
                importMessage = "File import failed: \(error.localizedDescription)"
                isShowingImportMessage = true
            }
        }
        .alert("Timeline Import", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }
}

private struct TimelineArchiveImportCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

private enum TimelineArchiveImportContentTypes {
    static let allowed: [UTType] = [
        .xml,
        .json,
        .commaSeparatedText,
        UTType(filenameExtension: "gpx") ?? .xml,
        UTType(filenameExtension: "geojson") ?? .json,
        UTType(filenameExtension: "csv") ?? .commaSeparatedText
    ]
}

// MARK: - GPX XML

private final class MovesGPXArchiveParser: NSObject, XMLParserDelegate {
    var places: [TimelineArchivePlace] = []
    var moves: [TimelineArchiveMove] = []

    private var currentElement = ""
    private var currentText = ""
    private var waypointCoordinate: CLLocationCoordinate2D?
    private var waypointName: String?
    private var waypointTime: Date?
    private var isCollectingWaypoint = false
    private var currentTrackPoints: [TimelineArchivePoint] = []
    private var currentPointCoordinate: CLLocationCoordinate2D?
    private var currentPointElevation: Double?
    private var currentPointTime: Date?
    private var currentTrackName: String?
    private var currentTrackType: String?
    private var currentTrackDescription: String?

    func finish() {
        finalizeCurrentSegment()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "wpt":
            isCollectingWaypoint = true
            waypointCoordinate = coordinate(from: attributeDict)
            waypointName = nil
            waypointTime = nil
        case "trk":
            currentTrackName = nil
            currentTrackType = nil
            currentTrackDescription = nil
        case "trkseg":
            finalizeCurrentSegment()
        case "trkpt":
            currentPointCoordinate = coordinate(from: attributeDict)
            currentPointElevation = nil
            currentPointTime = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentText = "" }

        switch elementName {
        case "name":
            if isCollectingWaypoint {
                waypointName = nonempty(text)
            } else {
                currentTrackName = nonempty(text)
            }
        case "time":
            let date = parseDate(text)
            if isCollectingWaypoint {
                waypointTime = date
            } else {
                currentPointTime = date
            }
        case "ele":
            currentPointElevation = Double(text)
        case "type":
            currentTrackType = nonempty(text)
        case "desc":
            currentTrackDescription = nonempty(text)
        case "wpt":
            if let coordinate = waypointCoordinate, let arrival = waypointTime {
                places.append(
                    TimelineArchivePlace(
                        arrivalDate: arrival,
                        departureDate: nil,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        userLabel: nil,
                        autoLabel: nil,
                        title: waypointName,
                        comment: nil,
                        dayKey: nil,
                        source: .gpx
                    )
                )
            }
            isCollectingWaypoint = false
            waypointCoordinate = nil
        case "trkpt":
            if let coordinate = currentPointCoordinate {
                currentTrackPoints.append(
                    TimelineArchivePoint(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        elevation: currentPointElevation,
                        timestamp: currentPointTime
                    )
                )
            }
            currentPointCoordinate = nil
        case "trkseg":
            finalizeCurrentSegment()
        default:
            break
        }
    }

    private func finalizeCurrentSegment() {
        defer { currentTrackPoints.removeAll(keepingCapacity: true) }
        let points = currentTrackPoints
        guard points.count >= 2 else { return }

        let timed = points.compactMap(\.timestamp)
        let start = timed.first ?? points.first?.timestamp
        let end = timed.last ?? points.last?.timestamp
        guard let start, let end else { return }

        moves.append(
            TimelineArchiveMove(
                startDate: start,
                endDate: max(end, start),
                transportMode: parseTransportMode(currentTrackType) ?? .unknown,
                distanceMeters: nil,
                stepCount: nil,
                startPlaceTitle: nil,
                endPlaceTitle: nil,
                comment: currentTrackDescription,
                dayKey: currentTrackName,
                points: points,
                source: .gpx
            )
        )
    }

    private func coordinate(from attributes: [String: String]) -> CLLocationCoordinate2D? {
        guard let lat = Double(attributes["lat"] ?? ""),
              let lon = Double(attributes["lon"] ?? "") else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Shared parsing helpers

private func parseTransportMode(_ value: String?) -> TransportMode? {
    guard let value, let trimmed = nonempty(value) else { return nil }
    let lowered = trimmed.lowercased()
    if let mode = TransportMode(rawValue: lowered) {
        return mode
    }
    return TransportMode.allCases.first {
        $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame
            || $0.rawValue.compare(trimmed, options: .caseInsensitive) == .orderedSame
    }
}

private func shouldInferTransportMode(from fileName: String) -> Bool {
    let name = fileName.lowercased()
    if name.hasPrefix("moves-") || name.contains("all-days") || name.contains("timeline") {
        return false
    }
    return true
}

private func inferredTransportMode(from fileName: String) -> TransportMode? {
    let name = fileName.lowercased()
    if name.contains("run") || name.contains("jog") { return .running }
    if name.contains("ride") || name.contains("bike") || name.contains("cycle") { return .cycling }
    if name.contains("swim") { return .swimming }
    if name.contains("walk") || name.contains("hike") { return .walking }
    if name.contains("train") { return .train }
    if name.contains("boat") || name.contains("ferry") { return .boat }
    if name.contains("flight") || name.contains("plane") { return .plane }
    if name.contains("drive") || name.contains("car") { return .automotive }
    return nil
}

private func isMeaningfulPlaceTitle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !unknownTitle(trimmed) else { return false }
    return !isCoordinateTitle(trimmed)
}

private func unknownTitle(_ value: String?) -> Bool {
    guard let value else { return true }
    let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.isEmpty
        || lowered == "unknown start"
        || lowered == "unknown destination"
        || lowered == "unknown start to unknown destination"
}

private func isCoordinateTitle(_ value: String) -> Bool {
    let compact = value.replacingOccurrences(of: " ", with: "")
    return compact.range(of: #"^-?\d+\.\d+,-?\d+\.\d+$"#, options: .regularExpression) != nil
}

private func splitMoveTitle(_ title: String?) -> (start: String?, end: String?)? {
    guard let title, let range = title.range(of: " to ", options: [.backwards, .caseInsensitive]) else {
        return nil
    }
    let startRaw = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    let endRaw = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    let start = isMeaningfulPlaceTitle(startRaw) ? startRaw : nil
    let end = isMeaningfulPlaceTitle(endRaw) ? endRaw : nil
    if start == nil && end == nil { return nil }
    return (start, end)
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

private func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
        return number.intValue
    case let string as String:
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

private func parseDate(_ value: String?) -> Date? {
    guard let value, let trimmed = nonempty(value) else { return nil }
    if let date = ISO8601DateFormatter.movesArchiveFractional.date(from: trimmed) {
        return date
    }
    if let date = ISO8601DateFormatter.movesArchiveInternet.date(from: trimmed) {
        return date
    }
    return nil
}

private func stripUTF8BOM(_ data: Data) -> Data {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        return data.dropFirst(3)
    }
    return data
}

private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var index = line.startIndex

    while index < line.endIndex {
        let character = line[index]
        if character == "\"" {
            let next = line.index(after: index)
            if inQuotes, next < line.endIndex, line[next] == "\"" {
                current.append("\"")
                index = next
            } else {
                inQuotes.toggle()
            }
        } else if character == ",", !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(character)
        }
        index = line.index(after: index)
    }

    fields.append(current)
    return fields
}

private func firstCoordinate(in geometry: [String: Any]) -> CLLocationCoordinate2D? {
    switch geometry["type"] as? String {
    case "Point":
        return coordinate(from: geometry["coordinates"])
    case "LineString":
        let points = lineString(from: geometry["coordinates"])
        return points.first?.coordinate
    default:
        return nil
    }
}

private func lineStrings(in geometry: [String: Any]) -> [[TimelineArchivePoint]] {
    switch geometry["type"] as? String {
    case "LineString":
        let points = lineString(from: geometry["coordinates"])
        return points.count >= 2 ? [points] : []
    case "MultiLineString":
        guard let lines = geometry["coordinates"] as? [Any] else { return [] }
        return lines.compactMap { line in
            let points = lineString(from: line)
            return points.count >= 2 ? points : nil
        }
    default:
        return []
    }
}

private func lineString(from value: Any?) -> [TimelineArchivePoint] {
    guard let line = value as? [Any] else { return [] }
    return line.compactMap { item in
        guard let coordinate = coordinate(from: item) else { return nil }
        let elevation = elevation(from: item)
        return TimelineArchivePoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            elevation: elevation,
            timestamp: nil
        )
    }
}

private func coordinate(from value: Any?) -> CLLocationCoordinate2D? {
    guard let pair = value as? [Any], pair.count >= 2,
          let longitude = doubleValue(pair[0]),
          let latitude = doubleValue(pair[1]) else {
        return nil
    }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

private func elevation(from value: Any?) -> Double? {
    guard let pair = value as? [Any], pair.count > 2 else { return nil }
    return doubleValue(pair[2])
}

private func timestampedPoints(
    _ points: [TimelineArchivePoint],
    startDate: Date,
    endDate: Date
) -> [TimelineArchivePoint] {
    let coordinates = points.map(\.coordinate)
    let segmentDistances = zip(coordinates, coordinates.dropFirst()).map {
        distanceMeters($0.0, $0.1)
    }
    let totalDistance = segmentDistances.reduce(0, +)
    let duration = max(endDate.timeIntervalSince(startDate), 0)
    var distanceTravelled: CLLocationDistance = 0

    return points.enumerated().map { index, point in
        if index > 0 {
            distanceTravelled += segmentDistances[index - 1]
        }

        let fraction: Double
        if let timestamp = point.timestamp {
            return TimelineArchivePoint(
                latitude: point.latitude,
                longitude: point.longitude,
                elevation: point.elevation,
                timestamp: timestamp
            )
        } else if totalDistance > 0 {
            fraction = distanceTravelled / totalDistance
        } else if points.count > 1 {
            fraction = Double(index) / Double(points.count - 1)
        } else {
            fraction = 0
        }

        return TimelineArchivePoint(
            latitude: point.latitude,
            longitude: point.longitude,
            elevation: point.elevation,
            timestamp: startDate.addingTimeInterval(duration * fraction)
        )
    }
}

private func dedupe(_ points: [TimelineArchivePoint]) -> [TimelineArchivePoint] {
    var result: [TimelineArchivePoint] = []
    var previousKey: String?
    for point in points {
        let second = point.timestamp.map { Int($0.timeIntervalSince1970.rounded()) } ?? -1
        let key = "\(second)|\(String(format: "%.6f", point.latitude))|\(String(format: "%.6f", point.longitude))"
        if key == previousKey { continue }
        result.append(point)
        previousKey = key
    }
    return result
}

private func distanceMeters(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
}

private extension ISO8601DateFormatter {
    static let movesArchiveFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let movesArchiveInternet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension Array where Element == URL {
    var uniqueForTimelineImport: [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for url in self {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(url)
        }
        return ordered
    }
}
