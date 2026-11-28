import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Outcome of a Google Timeline import (semantic months plus any Records gaps).
struct GoogleTimelineImportReport: Sendable {
    var log = LocationLogImportReport()
    var semanticFileCount = 0
    var recordsRead = 0
    var recordsSkippedAsDuplicate = 0
    var skippedSegmentCount = 0
    /// Records.json fixes left out because another device on the account recorded them.
    var recordsFromOtherDevices = 0
    /// Photo-based stops and trips the imported history replaced.
    var photoItemsReplaced = 0
    var formats: Set<GoogleTimelineFormat> = []
    /// True when a Records.json ended before its `locations` array did.
    var recordsWereIncomplete = false

    var summary: String {
        var text = log.summary
        if recordsRead > 0 {
            text += " Read \(recordsRead) Records.json point\(recordsRead == 1 ? "" : "s")"
            if recordsSkippedAsDuplicate > 0 {
                text += " and skipped \(recordsSkippedAsDuplicate) already covered by semantic history"
            }
            text += "."
        }
        if recordsFromOtherDevices > 0 {
            text += " Left out \(recordsFromOtherDevices.formatted()) point\(recordsFromOtherDevices == 1 ? "" : "s") from another device on your Google account."
        }
        if photoItemsReplaced > 0 {
            text += photoItemsReplaced == 1
                ? " Replaced 1 photo-based stop or trip with your Google history."
                : " Replaced \(photoItemsReplaced.formatted()) photo-based stops and trips with your Google history."
        }
        if skippedSegmentCount > 0 {
            text += " Ignored \(skippedSegmentCount) empty activity segment\(skippedSegmentCount == 1 ? "" : "s")."
        }
        if recordsWereIncomplete {
            text += " Records.json was incomplete, so only the readable part was imported."
        }
        return text
    }

    mutating func merge(_ other: LocationLogImportReport) {
        log.merge(other)
    }
}

/// Imports Google Takeout Timeline folders, zip archives, and individual JSON files.
///
/// Product order: Semantic Location History months first, then a streamed
/// `Records.json` to fill gaps, skipping `Settings.json`. Persistence uses
/// `LocationLogSegmenter` / `importLocationLog` so dedupe and Place Learning
/// stay on the shared path.
@MainActor
final class GoogleTimelineImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: GoogleTimelineImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let modelContainer: ModelContainer

    init(modelContext: ModelContext) {
        self.modelContainer = modelContext.container
    }

    func importSelection(urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        importProgress = 0
        importProgressText = "Looking for Timeline files…"
        defer {
            isImporting = false
            importProgress = nil
            importProgressText = ""
        }

        var accessed: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
        }
        defer {
            for url in accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let collected = try await importWorkerValue(Task.detached(priority: .utility) {
                try GoogleTimelineSourceCollector.collect(from: urls)
            })
            guard collected.hasWork else {
                throw GoogleTimelineImportError.noTimelineData
            }

            let reporter = GoogleTimelineProgressReporter { [weak self] fraction, text in
                self?.importProgress = fraction
                self?.importProgressText = text
            }
            let skipNaming = ProcessInfo.processInfo.isRunningUnitTests
            let container = modelContainer

            let report = try await importWorkerValue(Task.detached(priority: .userInitiated) {
                try await GoogleTimelineImportPipeline.run(
                    collected: collected,
                    container: container,
                    skipNaming: skipNaming,
                    progress: { fraction, text in
                        reporter.report(fraction, text)
                    }
                )
            })

            NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
            RouteMatchBackgroundTask.scheduleAfterImport()
            lastReport = report
            lastErrorMessage = nil
        } catch {
            lastReport = nil
            lastErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - File collection

struct GoogleTimelineCollectedSources: Sendable {
    var semanticURLs: [URL] = []
    var recordsURLs: [URL] = []
    var onDeviceURLs: [URL] = []
    var temporaryDirectory: URL?

    var hasWork: Bool {
        !semanticURLs.isEmpty || !recordsURLs.isEmpty || !onDeviceURLs.isEmpty
    }
}

enum GoogleTimelineSourceCollector {
    static func collect(from urls: [URL]) throws -> GoogleTimelineCollectedSources {
        var collected = GoogleTimelineCollectedSources()
        let fm = FileManager.default
        for url in urls.uniqueForImport {
            if url.pathExtension.lowercased() == "zip" {
                try appendZip(url, into: &collected)
                continue
            }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try appendDirectory(url, into: &collected)
                continue
            }
            try appendFile(url, into: &collected)
        }
        collected.semanticURLs.sort { $0.path < $1.path }
        return collected
    }

    private static func appendDirectory(_ root: URL, into collected: inout GoogleTimelineCollectedSources) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            try appendFile(fileURL, into: &collected)
        }
    }

    private static func appendFile(_ url: URL, into collected: inout GoogleTimelineCollectedSources) throws {
        let name = url.lastPathComponent.lowercased()
        if name == "settings.json" || name == "archive_browser.html" || name.hasPrefix("._") {
            return
        }
        guard name.hasSuffix(".json") else { return }
        if name == "records.json" {
            collected.recordsURLs.append(url)
            return
        }
        if name == "timeline.json" {
            collected.onDeviceURLs.append(url)
            return
        }
        if GoogleTimelineZipReader.isTimelinePath(url.path) {
            collected.semanticURLs.append(url)
            return
        }
        let peek = try GoogleTimelineParser.peekString(at: url)
        switch GoogleTimelineParser.detect(peek: peek) {
        case .records:
            collected.recordsURLs.append(url)
        case .semanticMonth:
            collected.semanticURLs.append(url)
        case .onDevice:
            collected.onDeviceURLs.append(url)
        case nil:
            break
        }
    }

    private static func appendZip(_ zipURL: URL, into collected: inout GoogleTimelineCollectedSources) throws {
        let entries = try GoogleTimelineZipReader.timelineEntries(in: zipURL)
        guard !entries.isEmpty else { return }
        let fm = FileManager.default
        let tempRoot = collected.temporaryDirectory ?? fm.temporaryDirectory
            .appendingPathComponent("moves-google-timeline-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        collected.temporaryDirectory = tempRoot
        // One folder per zip, because two zips can hold members with the same index and name.
        let zipFolder = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)

        for (index, entry) in entries.enumerated() {
            let dest = zipFolder.appendingPathComponent("\(index)-\(entry.fileName)")
            try GoogleTimelineZipReader.extract(entry, from: zipURL, to: dest)
            try appendFile(dest, into: &collected)
        }
    }
}

// MARK: - Pipeline (off main actor)

enum GoogleTimelineImportPipeline {
    static func run(
        collected: GoogleTimelineCollectedSources,
        container: ModelContainer,
        skipNaming: Bool,
        progress: @escaping (Double, String) -> Void
    ) async throws -> GoogleTimelineImportReport {
        defer {
            if let temp = collected.temporaryDirectory {
                try? FileManager.default.removeItem(at: temp)
            }
        }

        var report = GoogleTimelineImportReport()
        var draft = GoogleTimelineDraft()
        let semanticTotal = max(collected.semanticURLs.count, 1)

        for (index, url) in collected.semanticURLs.enumerated() {
            try Task.checkCancellation()
            // Fractions follow where the time goes: saving is about three quarters of it.
            progress(
                0.005 + 0.02 * Double(index) / Double(semanticTotal),
                "Reading \(url.lastPathComponent)…"
            )
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let parsed = try GoogleTimelineParser.parseSemanticMonth(data: data)
            draft.append(parsed)
            report.semanticFileCount += 1
            report.formats.insert(.semanticMonth)
        }

        for url in collected.onDeviceURLs {
            try Task.checkCancellation()
            progress(0.025, "Reading \(url.lastPathComponent)…")
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            draft.append(try GoogleTimelineParser.parseOnDevice(data: data))
            report.formats.insert(.onDevice)
        }

        report.skippedSegmentCount += draft.skippedSegmentCount
        let occupancy = GoogleOccupancyIndex(windows: draft.occupancy)

        // Records fill only the hours semantic history leaves out, one gap at a time.
        var gapRecords: [Int: [GoogleTimelineRecord]] = [:]
        for url in collected.recordsURLs {
            try Task.checkCancellation()
            progress(0.03, "Reading \(url.lastPathComponent)…")
            var read = 0
            var covered = 0
            var incomplete = false
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 350_000_000
            _ = try GoogleTimelineRecordsScanner.forEachDeviceRecord(at: url, progress: { count, bytes in
                let fraction = min(Double(bytes) / max(fileSize, 1), 1)
                progress(0.03 + 0.20 * fraction, "Reading Records.json… \(count.formatted()) points")
            }, onIncomplete: {
                incomplete = true
            }) { record in
                if Task.isCancelled { return false }
                read += 1
                if occupancy.covers(record.point) {
                    covered += 1
                } else {
                    gapRecords[occupancy.gapNumber(for: record.point.timestamp), default: []].append(record)
                }
                return true
            }
            try Task.checkCancellation()
            report.recordsRead += read
            report.recordsSkippedAsDuplicate += covered
            report.formats.insert(.records)
            if incomplete {
                report.recordsWereIncomplete = true
            }
        }

        if !gapRecords.isEmpty {
            progress(0.23, "Finding stays in Records.json…")
            let segmenter = LocationLogSegmenter()
            for records in gapRecords.values {
                try Task.checkCancellation()
                let (points, dropped) = GoogleTimelineDeviceFilter.mainDevicePoints(records)
                report.recordsFromOtherDevices += dropped
                for segment in segmenter.segment(points).segments {
                    switch segment {
                    case .stay(let stay):
                        draft.stays.append(stay)
                    case .move(let move):
                        draft.moves.append(move)
                    }
                }
            }
            gapRecords = [:]
        }

        let timeline = draft.makeTimeline()
        if timeline.isEmpty {
            if report.recordsRead == 0 {
                throw GoogleTimelineImportError.noTimelineData
            }
            progress(1, "Done")
            return report
        }

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        progress(0.25, "Saving places and trips…")
        // Saving runs oldest first, so say how far through the history it has got.
        let segmentDates = timeline.segments.map { segment -> Date in
            switch segment {
            case .stay(let stay): stay.arrivalDate
            case .move(let move): move.startDate
            }
        }
        let monthFormat = Date.FormatStyle().month(.wide).year()
        let partial = try repository.importLocationLog(
            timeline,
            source: .googleTimelineImport
        ) { fraction, text in
            let index = min(Int(fraction * Double(segmentDates.count)), segmentDates.count - 1)
            let shown = fraction < 0.98 && index >= 0
                ? String(localized: "Saved your history through \(segmentDates[index].formatted(monthFormat))")
                : text
            progress(0.25 + 0.68 * fraction, shown)
        }
        report.merge(partial)

        try Task.checkCancellation()
        progress(0.94, "Replacing photo-based stops…")
        let windows = draft.stays.map { DateInterval(start: $0.arrivalDate, end: max($0.departureDate, $0.arrivalDate)) }
            + draft.moves.map { DateInterval(start: $0.startDate, end: max($0.endDate, $0.startDate)) }
        report.photoItemsReplaced = try repository.retirePhotoInferredItems(coveredBy: windows)

        try repository.saveIfNeeded()

        if !skipNaming, !report.log.newPlaces.isEmpty {
            let namer = LocationLogPlaceNamer()
            let resolver = CLGeocoderPlaceNameResolver()
            report.log.namedPlaceCount = await namer.nameClusters(
                report.log.newPlaces,
                resolver: resolver,
                progress: { done, total in
                    progress(
                        total > 0 ? 0.95 + 0.045 * Double(done) / Double(total) : 0.995,
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

        progress(1, "Done")
        return report
    }
}

/// Keeps one device's fixes where several on the account report the same hours.
///
/// A tablet left at home keeps sending its spot while the phone travels, which draws a
/// zigzag between them. In each hour, the device with the most fixes is the one being
/// carried (a moving phone reports far more often); hour by hour, so a new phone takes
/// over when the old one stops. Fixes without a device tag (older exports) count as one device.
enum GoogleTimelineDeviceFilter {
    static let window: TimeInterval = 60 * 60

    static func mainDevicePoints(_ records: [GoogleTimelineRecord]) -> (points: [LocationLogPoint], dropped: Int) {
        var hours: [Int: [GoogleTimelineRecord]] = [:]
        for record in records {
            hours[Int((record.point.timestamp.timeIntervalSince1970 / window).rounded(.down)), default: []].append(record)
        }
        var points: [LocationLogPoint] = []
        points.reserveCapacity(records.count)
        for hour in hours.values {
            var counts: [Int?: Int] = [:]
            for record in hour {
                counts[record.deviceTag, default: 0] += 1
            }
            let main = counts.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : (lhs.key ?? .min) > (rhs.key ?? .min)
            }?.key
            points.append(contentsOf: hour.lazy.filter { $0.deviceTag == main }.map(\.point))
        }
        points.sort { $0.timestamp < $1.timestamp }
        return (points, records.count - points.count)
    }
}

/// Forwards background progress onto the main actor, coalesced.
private final class GoogleTimelineProgressReporter: @unchecked Sendable {
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

// MARK: - Settings

struct GoogleTimelineImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var importQueue: DurableImportQueue
    private var importer: GoogleTimelineImporter { importQueue.google }
    @State private var isShowingFileImporter = false
    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    init(modelContext: ModelContext) {
        // The app owns the queue and writers independently of this screen.
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ImportQueueCard()
                GoogleTimelineImportCard(title: "Google Timeline") {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(importer.isImporting ? .secondary : MovesPalette.routeTracking)

                            Text(importer.isImporting ? "Importing Google Timeline…" : "Import Google Timeline")
                                .font(.body.weight(.medium))
                                .foregroundStyle(importer.isImporting ? .secondary : .primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(importer.isImporting || importQueue.isStaging)


                    Text("Choose the Location History folder from your Google Takeout download, or a zip or JSON file from it.")
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
        .navigationTitle("Google Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: GoogleTimelineImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    do { try await importQueue.enqueue(urls, kind: .google) }
                    catch { importMessage = error.localizedDescription; isShowingImportMessage = true }
                }
            case .failure(let error):
                importMessage = "File import failed: \(error.localizedDescription)"
                isShowingImportMessage = true
            }
        }
        .alert("Google Timeline", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }
}

private struct GoogleTimelineImportCard<Content: View>: View {
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

enum GoogleTimelineImportContentTypes {
    static let allowed: [UTType] = [
        .folder,
        .json,
        .zip,
        UTType(filenameExtension: "json") ?? .json,
        UTType(filenameExtension: "zip") ?? .zip,
    ]
}

private extension Array where Element == URL {
    var uniqueForImport: [URL] {
        var seen = Set<String>()
        return filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }
}
