import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Outcome of a Files import, covering both segmented location logs and
/// legacy single-route tracks (files without timestamps).
struct RouteFileImportReport {
    var fileCount: Int
    var log: LocationLogImportReport
    /// Tracks without usable timestamps that were stored as one route each.
    var untimedRouteCount: Int
    var untimedSampleCount: Int

    var summary: String {
        var text = log.summary
        if untimedRouteCount > 0 {
            text += " \(untimedRouteCount) track\(untimedRouteCount == 1 ? "" : "s") without timestamps"
            text += " \(untimedRouteCount == 1 ? "was" : "were") stored as plain route\(untimedRouteCount == 1 ? "" : "s") (\(untimedSampleCount) points)."
        }
        return text
    }
}

/// Imports GPX / TCX / KML / GeoJSON files from the Files picker.
///
/// Parsing, segmentation, and all SwiftData writes run on a background
/// `ModelContext` so a year-long log (tens of thousands of fixes) never
/// blocks the main thread. Timestamped fixes from every selected file are
/// pooled and rebuilt into visits and trips by `LocationLogSegmenter`; tracks
/// whose points carry no time are stored as single routes, as before.
@MainActor
final class RouteFileImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: RouteFileImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let modelContainer: ModelContainer

    init(modelContext: ModelContext) {
        self.modelContainer = modelContext.container
    }

    func importFiles(urls: [URL]) async {
        guard !isImporting else { return }
        let securityScopedURLs = urls.uniqueForImport
        guard !securityScopedURLs.isEmpty else {
            lastErrorMessage = "No files selected."
            return
        }

        isImporting = true
        importProgress = 0
        importProgressText = "Reading files…"
        defer {
            isImporting = false
            importProgress = nil
            importProgressText = ""
        }

        do {
            var payloads: [(name: String, data: Data)] = []
            for (index, url) in securityScopedURLs.enumerated() {
                importProgressText = "Reading \(index + 1) of \(securityScopedURLs.count): \(url.lastPathComponent)"
                payloads.append((url.lastPathComponent, try Self.readSecurityScopedData(from: url)))
            }

            importProgressText = "Finding stays and trips…"
            importProgress = nil
            let parsed = try await Task.detached(priority: .userInitiated) {
                try Self.parse(payloads)
            }.value

            guard !parsed.timedGroups.isEmpty || !parsed.untimedTracks.isEmpty else {
                throw LocationLogImportError.noTimelineData
            }

            let container = modelContainer
            let reporter = ProgressReporter { [weak self] fraction, text in
                self?.importProgress = fraction
                self?.importProgressText = text
            }
            let skipNaming = ProcessInfo.processInfo.isRunningUnitTests

            var report = try await Task.detached(priority: .userInitiated) { () throws -> RouteFileImportReport in
                let repository = SwiftDataTimelineRepository(modelContainer: container)
                var report = RouteFileImportReport(
                    fileCount: securityScopedURLs.count,
                    log: LocationLogImportReport(),
                    untimedRouteCount: 0,
                    untimedSampleCount: 0
                )

                let groupCount = Double(max(parsed.timedGroups.count, 1))
                for (groupIndex, group) in parsed.timedGroups.enumerated() {
                    let timeline = LocationLogSegmenter().segment(group.points)
                    guard !timeline.isEmpty else { continue }
                    let base = Double(groupIndex) / groupCount
                    let partial = try repository.importLocationLog(
                        timeline,
                        source: .fileRouteImport,
                        transportModeOverride: group.transportMode == .unknown ? nil : group.transportMode
                    ) { fraction, text in
                        reporter.report(base + fraction / groupCount, text)
                    }
                    report.log.merge(partial)
                }

                for track in parsed.untimedTracks where track.locations.count >= 2 {
                    _ = try repository.importRouteTrack(
                        locations: track.locations,
                        source: .fileRouteImport,
                        transportMode: track.transportMode
                    )
                    report.untimedRouteCount += 1
                    report.untimedSampleCount += track.locations.count
                }
                try repository.saveIfNeeded()

                if !skipNaming, !report.log.newPlaces.isEmpty {
                    let namer = LocationLogPlaceNamer()
                    let resolver = CLGeocoderPlaceNameResolver()
                    report.log.namedPlaceCount = await namer.nameClusters(
                        report.log.newPlaces,
                        resolver: resolver,
                        progress: { done, total in
                            reporter.report(
                                total > 0 ? Double(done) / Double(total) : 1,
                                "Naming places… \(done) of \(total)"
                            )
                        },
                        apply: { name, placeIDs in
                            for placeID in placeIDs {
                                try repository.setAutomaticLabel(name, for: placeID)
                            }
                            try repository.saveIfNeeded()
                        }
                    )
                }

                return report
            }.value

            report.fileCount = securityScopedURLs.count
            NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
            lastReport = report
            lastErrorMessage = nil
        } catch {
            lastReport = nil
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: Parsing

    /// Fixes with real timestamps, grouped by the transport mode the file
    /// name implies (usually just one `.unknown` group).
    fileprivate struct TimedGroup {
        var transportMode: TransportMode
        var points: [LocationLogPoint]
    }

    fileprivate struct ParsedFiles {
        var timedGroups: [TimedGroup]
        var untimedTracks: [ImportedRouteTrack]
    }

    nonisolated private static func parse(_ payloads: [(name: String, data: Data)]) throws -> ParsedFiles {
        var groups: [TransportMode: [LocationLogPoint]] = [:]
        var untimed: [ImportedRouteTrack] = []

        for payload in payloads {
            let fileMode = inferTransportMode(from: payload.name)
            if payload.name.lowercased().hasSuffix(".gpx") {
                let result = try LocationLogGPXParser.parse(data: payload.data)
                if !result.points.isEmpty {
                    groups[fileMode, default: []].append(contentsOf: result.points)
                    continue
                }
            }

            for track in try loadTracks(named: payload.name, data: payload.data) {
                if track.hasRecordedTimestamps {
                    groups[track.transportMode, default: []].append(contentsOf: track.locations.map(LocationLogPoint.init))
                } else {
                    untimed.append(track)
                }
            }
        }

        let timedGroups = groups
            .map { TimedGroup(transportMode: $0.key, points: $0.value) }
            .sorted { $0.transportMode.rawValue < $1.transportMode.rawValue }
        return ParsedFiles(timedGroups: timedGroups, untimedTracks: untimed)
    }

    nonisolated private static func readSecurityScopedData(from url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func loadTracks(named fileName: String, data: Data) throws -> [ImportedRouteTrack] {
        let lowercasedName = fileName.lowercased()
        if lowercasedName.hasSuffix(".gpx") || lowercasedName.hasSuffix(".tcx") || lowercasedName.hasSuffix(".kml") {
            return try XMLRouteTrackParser.parse(data: data, fileName: fileName)
        }

        if lowercasedName.hasSuffix(".geojson") || lowercasedName.hasSuffix(".json") {
            return try GeoJSONRouteTrackParser.parse(data: data, fileName: fileName)
        }

        // Last resort: try XML first, then GeoJSON.
        if let xmlTracks = try? XMLRouteTrackParser.parse(data: data, fileName: fileName),
           !xmlTracks.isEmpty {
            return xmlTracks
        }
        if let geoJSONTracks = try? GeoJSONRouteTrackParser.parse(data: data, fileName: fileName),
           !geoJSONTracks.isEmpty {
            return geoJSONTracks
        }

        throw LocationLogImportError.unsupportedFormat(fileName)
    }
}

/// Forwards background progress to the main actor, dropping updates that
/// would not visibly change the bar so thousands of segments do not queue
/// thousands of main-thread hops.
private final class ProgressReporter: @unchecked Sendable {
    private let handler: @MainActor (Double, String) -> Void
    private let lock = NSLock()
    private var lastFraction: Double = -1
    private var lastText = ""

    init(handler: @escaping @MainActor (Double, String) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double, _ text: String) {
        lock.lock()
        let shouldSend = text != lastText || abs(fraction - lastFraction) >= 0.005 || fraction >= 1
        if shouldSend {
            lastFraction = fraction
            lastText = text
        }
        lock.unlock()
        guard shouldSend else { return }
        let handler = self.handler
        Task { @MainActor in handler(fraction, text) }
    }
}

extension LocationLogImportReport {
    /// Accumulates counts from another group's import into this one.
    mutating func merge(_ other: LocationLogImportReport) {
        placeCount += other.placeCount
        mergedPlaceCount += other.mergedPlaceCount
        moveCount += other.moveCount
        mergedMoveCount += other.mergedMoveCount
        sampleCount += other.sampleCount
        newPlaces.append(contentsOf: other.newPlaces)
        namedPlaceCount += other.namedPlaceCount
    }
}

struct RouteFileImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer: RouteFileImporter
    @State private var isShowingFileImporter = false
    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    init(modelContext: ModelContext) {
        _importer = StateObject(wrappedValue: RouteFileImporter(modelContext: modelContext))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                RouteImportCard(title: "Route Files") {
                    RouteImportActionRow(
                        title: importer.isImporting ? "Importing route files..." : "Import route files",
                        systemImage: "square.and.arrow.down",
                        isDisabled: importer.isImporting
                    ) {
                        isShowingFileImporter = true
                    }

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

                    Text("Supports GPX, TCX, KML, and GeoJSON. Select one or several files at once. Timestamped logs from other tracking apps are split into places and trips, transport modes are inferred from speed, and new places are named from the map. Points you already have are skipped, so re-importing is safe.")
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
        .navigationTitle("File Route Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: RouteFileImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    await importer.importFiles(urls: urls)
                    if let report = importer.lastReport {
                        importMessage = report.summary
                    } else {
                        importMessage = importer.lastErrorMessage ?? "No route data was imported."
                    }
                    isShowingImportMessage = true
                }
            case .failure(let error):
                importMessage = "File import failed: \(error.localizedDescription)"
                isShowingImportMessage = true
            }
        }
        .alert("File Route Import", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }
}

private struct RouteImportCard<Content: View>: View {
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

private struct RouteImportActionRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : MovesPalette.routeTracking)

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private enum RouteFileImportContentTypes {
    static let allowed: [UTType] = [
        .xml,
        .json,
        UTType(filenameExtension: "gpx") ?? .xml,
        UTType(filenameExtension: "tcx") ?? .xml,
        UTType(filenameExtension: "kml") ?? .xml,
        UTType(filenameExtension: "geojson") ?? .json
    ]
}

struct ImportedRouteTrack {
    let locations: [CLLocation]
    let transportMode: TransportMode
    /// False when any point had to be given a synthetic timestamp; such
    /// tracks cannot be segmented into stays and moves.
    let hasRecordedTimestamps: Bool
}

private enum GeoJSONRouteTrackParser {
    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var tracks: [ImportedRouteTrack] = []
        let mode = inferTransportMode(from: fileName)

        if let type = object["type"] as? String, type == "FeatureCollection",
           let features = object["features"] as? [[String: Any]] {
            for feature in features {
                guard let geometry = feature["geometry"] as? [String: Any],
                      let geometryType = geometry["type"] as? String else { continue }
                tracks.append(contentsOf: parseGeometry(geometry, type: geometryType, transportMode: mode))
            }
            return tracks
        }

        if let type = object["type"] as? String {
            tracks.append(contentsOf: parseGeometry(object, type: type, transportMode: mode))
        }

        return tracks
    }

    private static func parseGeometry(_ geometry: [String: Any], type: String, transportMode: TransportMode) -> [ImportedRouteTrack] {
        switch type {
        case "LineString":
            let locations = locationsFromCoordinates(geometry["coordinates"])
            return locations.count >= 2
                ? [ImportedRouteTrack(locations: locations, transportMode: transportMode, hasRecordedTimestamps: false)]
                : []
        case "MultiLineString":
            guard let lines = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return lines.compactMap { line in
                let locations = locationsFromLine(line)
                return locations.count >= 2
                    ? ImportedRouteTrack(locations: locations, transportMode: transportMode, hasRecordedTimestamps: false)
                    : nil
            }
        default:
            return []
        }
    }

    private static func locationsFromCoordinates(_ coordinates: Any?) -> [CLLocation] {
        guard let line = coordinates as? [[Double]] else { return [] }
        return locationsFromLine(line)
    }

    private static func locationsFromLine(_ line: [[Double]]) -> [CLLocation] {
        let start = Date()
        return line.enumerated().compactMap { index, point in
            guard point.count >= 2 else { return nil }
            let timestamp = start.addingTimeInterval(TimeInterval(index))
            let altitude = point.count > 2 ? point[2] : 0
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point[1], longitude: point[0]),
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: altitude == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: timestamp
            )
        }
    }
}

private final class XMLRouteTrackParser: NSObject, XMLParserDelegate {
    private var tracks: [(locations: [CLLocation], hasRecordedTimestamps: Bool)] = []
    private var currentTrack: [CLLocation] = []
    /// Set when a point in the current track had no usable time.
    private var currentTrackUsedFallback = false
    private var currentCoordinate: CLLocationCoordinate2D?
    private var currentAltitude: Double?
    private var currentTimestamp: Date?
    private var currentElement = ""
    private var currentText = ""
    private var fallbackTimestamp = Date()
    private let transportMode: TransportMode

    init(fileName: String) {
        self.transportMode = inferTransportMode(from: fileName)
    }

    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        let parser = XMLParser(data: data)
        let delegate = XMLRouteTrackParser(fileName: fileName)
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            return []
        }

        delegate.finalizeCurrentTrack()
        return delegate.tracks
            .filter { $0.locations.count >= 2 }
            .map {
                ImportedRouteTrack(
                    locations: $0.locations,
                    transportMode: delegate.transportMode,
                    hasRecordedTimestamps: $0.hasRecordedTimestamps
                )
            }
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

        if elementName == "trkseg" || elementName == "Track" || elementName == "Placemark" {
            finalizeCurrentTrack()
        }

        if elementName == "trkpt" {
            if let latString = attributeDict["lat"],
               let lonString = attributeDict["lon"],
               let latitude = Double(latString),
               let longitude = Double(lonString) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            currentAltitude = nil
            currentTimestamp = nil
        }

        if elementName == "Trackpoint" || elementName == "Position" {
            currentCoordinate = nil
            currentAltitude = nil
            currentTimestamp = nil
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
        case "lat", "LatitudeDegrees":
            if let latitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: currentCoordinate?.longitude ?? 0)
            }
        case "lon", "LongitudeDegrees":
            if let longitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: currentCoordinate?.latitude ?? 0, longitude: longitude)
            }
        case "ele", "AltitudeMeters":
            currentAltitude = Double(text)
        case "time", "Time":
            currentTimestamp = parseDate(text)
        case "trkpt", "Trackpoint":
            appendCurrentPointIfPossible()
        case "coordinates":
            appendKMLCoordinates(text)
        case "trkseg", "Track", "Placemark":
            finalizeCurrentTrack()
        default:
            break
        }
    }

    private func appendCurrentPointIfPossible() {
        guard let coordinate = currentCoordinate else { return }
        if currentTimestamp == nil {
            currentTrackUsedFallback = true
        }
        let timestamp = currentTimestamp ?? fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        let altitude = currentAltitude ?? 0
        let location = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: altitude == 0 ? -1 : 5,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
        currentTrack.append(location)
        currentCoordinate = nil
        currentAltitude = nil
        currentTimestamp = nil
    }

    private func appendKMLCoordinates(_ text: String) {
        let coordinateChunks = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        if !coordinateChunks.isEmpty {
            currentTrackUsedFallback = true
        }

        for chunk in coordinateChunks {
            let values = chunk.split(separator: ",").compactMap { Double($0) }
            guard values.count >= 2 else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: values[1], longitude: values[0])
            let altitude = values.count > 2 ? values[2] : 0
            let location = CLLocation(
                coordinate: coordinate,
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: altitude == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: fallbackTimestamp
            )
            fallbackTimestamp = fallbackTimestamp.addingTimeInterval(1)
            currentTrack.append(location)
        }
    }

    private func finalizeCurrentTrack() {
        defer {
            currentTrack.removeAll(keepingCapacity: true)
            currentTrackUsedFallback = false
        }
        guard currentTrack.count >= 2 else { return }

        tracks.append(
            (
                locations: currentTrack.sorted(by: { $0.timestamp < $1.timestamp }),
                hasRecordedTimestamps: !currentTrackUsedFallback
            )
        )
    }
}

private extension Array where Element == URL {
    var uniqueForImport: [URL] {
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

private func parseDate(_ value: String) -> Date? {
    if let date = ISO8601DateFormatter.withFractional.date(from: value) {
        return date
    }
    if let date = ISO8601DateFormatter.withoutFractional.date(from: value) {
        return date
    }
    return nil
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private func inferTransportMode(from fileName: String) -> TransportMode {
    let name = fileName.lowercased()
    if name.contains("run") || name.contains("jog") {
        return .running
    }
    if name.contains("ride") || name.contains("bike") || name.contains("cycle") {
        return .cycling
    }
    if name.contains("swim") || name.contains("pool") || name.contains("openwater") {
        return .swimming
    }
    if name.contains("walk") || name.contains("hike") {
        return .walking
    }
    if name.contains("train") {
        return .train
    }
    if name.contains("boat") || name.contains("ferry") {
        return .boat
    }
    if name.contains("flight") || name.contains("plane") {
        return .plane
    }
    if name.contains("drive") || name.contains("car") {
        return .automotive
    }
    return .unknown
}
