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
        if name == "settings.json" || name == "archive_browser.html" {
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
            progress(
                0.02 + 0.28 * Double(index) / Double(semanticTotal),
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
            progress(0.32, "Reading \(url.lastPathComponent)…")
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            draft.append(try GoogleTimelineParser.parseOnDevice(data: data))
            report.formats.insert(.onDevice)
        }

        report.skippedSegmentCount += draft.skippedSegmentCount
        let occupancy = GoogleOccupancyIndex(windows: draft.occupancy)
        let semanticTimeline = draft.makeTimeline()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        if !semanticTimeline.isEmpty {
            progress(0.35, "Saving places and trips…")
            let partial = try repository.importLocationLog(
                semanticTimeline,
                source: .googleTimelineImport
            ) { fraction, text in
                progress(0.35 + 0.30 * fraction, text)
            }
            report.merge(partial)
        }

        for url in collected.recordsURLs {
            try Task.checkCancellation()
            progress(0.66, "Streaming \(url.lastPathComponent)…")
            var gapPoints: [LocationLogPoint] = []
            var read = 0
            var skipped = 0
            var incomplete = false
            _ = try GoogleTimelineRecordsScanner.forEachRecord(at: url, progress: { count, bytes in
                let fraction = min(Double(bytes) / 350_000_000, 1)
                progress(0.66 + 0.16 * fraction, "Streaming Records.json… \(count) points")
            }, onIncomplete: {
                incomplete = true
            }) { point in
                if Task.isCancelled { return false }
                read += 1
                if occupancy.covers(point) {
                    skipped += 1
                } else {
                    gapPoints.append(point)
                }
                return true
            }
            try Task.checkCancellation()
            report.recordsRead += read
            report.recordsSkippedAsDuplicate += skipped
            report.formats.insert(.records)
            if incomplete {
                report.recordsWereIncomplete = true
            }

            if !gapPoints.isEmpty {
                progress(0.83, "Finding stays in Records.json…")
                let timeline = LocationLogSegmenter().segment(gapPoints)
                if !timeline.isEmpty {
                    let partial = try repository.importLocationLog(
                        timeline,
                        source: .googleTimelineImport
                    ) { fraction, text in
                        progress(0.84 + 0.12 * fraction, text)
                    }
                    report.merge(partial)
                }
            }
        }

        if report.log.placeCount == 0 && report.log.moveCount == 0 && report.recordsRead == 0
            && draft.stays.isEmpty && draft.moves.isEmpty {
            throw GoogleTimelineImportError.noTimelineData
        }

        try repository.saveIfNeeded()

        if !skipNaming, !report.log.newPlaces.isEmpty {
            let namer = LocationLogPlaceNamer()
            let resolver = CLGeocoderPlaceNameResolver()
            report.log.namedPlaceCount = await namer.nameClusters(
                report.log.newPlaces,
                resolver: resolver,
                progress: { done, total in
                    progress(
                        total > 0 ? 0.96 + 0.03 * Double(done) / Double(total) : 0.99,
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


                    Text("Select the Location History (Timeline) folder from a Google Takeout. Moves reads Semantic Location History first, then streams Records.json. A zip or a single JSON file (one month, Records, or an on-device Timeline.json) also works. Settings.json is ignored.")
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
