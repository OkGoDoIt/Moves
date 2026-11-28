import BackgroundTasks
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Local recovery state adapted from upstream ImportQueue. Never mirrored to CloudKit.
struct SavedImport: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case routes, google, archive }
    enum State: String, Codable { case queued, running, paused, completed, failed }
    var id = UUID()
    var kind: Kind
    var names: [String]
    var state: State = .queued
    var createdAt = Date()
    var message: String?
    /// Times a run was cut off by the app closing, a crash, or a restart.
    var interruptions: Int? = nil
    /// False when the system paused the job, so it carries on by itself. Older saved
    /// queues have no value and are treated as the person's own pause.
    var pausedByPerson: Bool? = nil
}

/// Atomic queue persistence; unreadable or newer files must never be replaced with an empty queue.
struct SavedImportStore {
    struct Envelope: Codable { var version = 1; var jobs: [SavedImport] }
    let directory: URL
    var manifest: URL { directory.appendingPathComponent("queue.json") }
    /// A job that was cut off this many times in a row stops, so one that brings the
    /// app down cannot do it on every launch.
    static let interruptionLimit = 3

    /// Interrupted and system-paused jobs come back queued, so they finish by themselves.
    func load() throws -> [SavedImport] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: manifest))
        guard value.version == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        return value.jobs.map { job in
            var restored = job
            switch job.state {
            case .running:
                let interruptions = (job.interruptions ?? 0) + 1
                restored.interruptions = interruptions
                if interruptions >= Self.interruptionLimit {
                    restored.state = .failed
                    restored.message = String(localized: "Stopped three times before finishing.")
                } else {
                    restored.state = .queued
                }
            case .paused where job.pausedByPerson == false:
                restored.state = .queued
            case .queued, .paused, .completed, .failed:
                break
            }
            return restored
        }
    }
    func save(_ jobs: [SavedImport]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try JSONEncoder().encode(Envelope(jobs: jobs)).write(to: manifest, options: .atomic)
    }
    func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func sources(for job: SavedImport) -> [URL] {
        job.names.enumerated().map { folder(for: job.id).appendingPathComponent(String($0.offset)).appendingPathComponent($0.element) }
    }
}

/// Propagates cancellation into a detached worker instead of abandoning a writer in the background.
func importWorkerValue<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// One app-owned importer: navigation never starts another writer or loses interrupted work.
@MainActor
final class DurableImportQueue: ObservableObject {
    @Published private(set) var jobs: [SavedImport] = []
    @Published private(set) var storageError: String?
    @Published private(set) var isStaging = false
    @Published private(set) var workingJobID: UUID?
    @Published private(set) var runStartedAt: Date?
    let routes: RouteFileImporter
    let google: GoogleTimelineImporter
    let archive: TimelineArchiveImporter
    private let store: SavedImportStore
    private var runner: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var isActive = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(container: ModelContainer, directory: URL? = nil) {
        let context = ModelContext(container)
        routes = RouteFileImporter(modelContext: context)
        google = GoogleTimelineImporter(modelContext: context)
        archive = TimelineArchiveImporter(modelContext: context)
        store = SavedImportStore(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Moves/ImportQueue", isDirectory: true))
        do {
            jobs = try store.load()
            // Saves what `load` restored, so an interruption is counted only once.
            if !jobs.isEmpty { try store.save(jobs) }
        } catch { storageError = error.localizedDescription }
        if !ProcessInfo.processInfo.isRunningUnitTests { Self.shared = self }
        for publisher in [routes.objectWillChange, google.objectWillChange, archive.objectWillChange] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        }
    }

    var current: SavedImport? { jobs.first { $0.state == .running } }
    var progress: Double? {
        switch current?.kind { case .routes: routes.importProgress; case .google: google.importProgress; case .archive: archive.importProgress; case nil: nil }
    }
    var progressText: String {
        switch current?.kind { case .routes: routes.importProgressText; case .google: google.importProgressText; case .archive: archive.importProgressText; case nil: "" }
    }

    /// Copies selected files while security access is held. Original files are never moved or deleted.
    func enqueue(_ urls: [URL], kind: SavedImport.Kind) async throws {
        guard storageError == nil else { throw CocoaError(.fileWriteUnknown) }
        guard !isStaging, !urls.isEmpty else { return }
        isStaging = true
        defer { isStaging = false }
        let job = SavedImport(kind: kind, names: urls.map(\.lastPathComponent))
        let folder = store.folder(for: job.id)
        let destinations = store.sources(for: job)
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            try await importWorkerValue(Task.detached(priority: .utility) {
                for (source, destination) in zip(urls, destinations) {
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            })
            try Task.checkCancellation()
            try store.save(jobs + [job])
            jobs.append(job)
            startIfNeeded()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func resume(_ id: UUID) {
        guard let state = jobs.first(where: { $0.id == id })?.state, state == .paused || state == .failed else { return }
        guard update(id, { $0.state = .queued; $0.message = nil; $0.interruptions = nil; $0.pausedByPerson = nil }) else { return }
        startIfNeeded()
    }
    /// The person's own Pause: the job waits until they resume it.
    func pause(_ id: UUID) {
        guard let state = jobs.first(where: { $0.id == id })?.state, state == .queued || state == .running else { return }
        let wasRunning = current?.id == id
        guard update(id, { $0.state = .paused; $0.pausedByPerson = true }) else { return }
        if wasRunning { runner?.cancel() }
    }
    /// The system took the time back: stop now and carry on the next time Moves is open.
    private func systemInterrupted() {
        guard let id = current?.id else { return }
        guard update(id, { $0.state = .queued; $0.pausedByPerson = false }) else { return }
        runner?.cancel()
    }
    func remove(_ id: UUID) {
        guard workingJobID != id else { return }
        do {
            let updated = jobs.filter { $0.id != id }
            try store.save(updated)
            jobs = updated
            try? FileManager.default.removeItem(at: store.folder(for: id))
        } catch { storageError = error.localizedDescription }
    }
    func sceneChanged(_ phase: ScenePhase) {
        isActive = phase == .active
        if isActive { startIfNeeded() }
    }
    @discardableResult private func update(_ id: UUID, _ change: (inout SavedImport) -> Void) -> Bool {
        guard storageError == nil, let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        var updated = jobs
        change(&updated[index])
        do { try store.save(updated); jobs = updated; return true }
        catch { storageError = error.localizedDescription; runner?.cancel(); return false }
    }
    private func startIfNeeded() {
        guard runner == nil, isActive || continuedTask != nil, storageError == nil,
              jobs.contains(where: { $0.state == .queued }) else { return }
        runner = Task {
            await TimelineSchemaUpgrader.waitUntilFinished()
            while !Task.isCancelled, isActive || continuedTask != nil, let job = jobs.first(where: { $0.state == .queued }) {
                guard update(job.id, { $0.state = .running }) else { break }
                if isActive, continuedTask == nil {
                    requestContinuing(for: job)
                }
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish import") { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        // A continued task keeps the import going; without one, the time is up.
                        if self.continuedTask == nil { self.systemInterrupted() }
                        self.endBackgroundTime()
                    }
                }
                runStartedAt = .now
                workingJobID = job.id
                let urls = store.sources(for: job)
                var result: String?
                var error: String?
                switch job.kind {
                case .routes:
                    await routes.importFiles(urls: urls)
                    result = routes.lastReport?.summary; error = routes.lastErrorMessage
                case .google:
                    await google.importSelection(urls: urls)
                    result = google.lastReport?.summary; error = google.lastErrorMessage
                case .archive:
                    await archive.importFiles(urls: urls)
                    result = archive.lastReport?.summary; error = archive.lastErrorMessage
                }
                workingJobID = nil
                runStartedAt = nil
                endBackgroundTime()
                NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
                if !Task.isCancelled, jobs.first(where: { $0.id == job.id })?.state == .running {
                    if update(job.id, { $0.state = error == nil ? .completed : .failed; $0.message = error ?? result }), error == nil {
                        try? FileManager.default.removeItem(at: store.folder(for: job.id))
                    }
                }
            }
            runner = nil
            startIfNeeded()
            finishContinuedTaskIfIdle()
        }
    }
    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Continuing after the person leaves

    /// Must match `BGTaskSchedulerPermittedIdentifiers` (`importNow.*`) in `Info.plist`.
    static let continuedIdentifier = "\(MovesAppIdentity.bundleIdentifier).importNow.queue"
    /// The process's one queue, for the continued task, which starts without a view.
    private(set) static weak var shared: DurableImportQueue?
    private var continuedTask: BGContinuedProcessingTask?
    private var continuedReporting: Task<Void, Never>?

    static func registerBackgroundTask() {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedIdentifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                guard let queue = shared else {
                    task.setTaskCompleted(success: false)
                    return
                }
                queue.hold(task)
            }
        }
    }

    /// Asks the system to keep this import going after the person leaves, with its
    /// progress on the Lock Screen. Only possible while Moves is open.
    private func requestContinuing(for job: SavedImport) {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedIdentifier,
            title: title(for: job),
            subtitle: String(localized: "Starting…")
        )
        request.strategy = .queue
        try? BGTaskScheduler.shared.submit(request)
    }

    private func hold(_ task: BGContinuedProcessingTask) {
        guard current != nil || jobs.contains(where: { $0.state == .queued }) else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = 1_000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.systemInterrupted()
                self.releaseContinuedTask(success: false)
            }
        }
        continuedReporting = Task { [weak self] in
            var subtitle = ""
            while !Task.isCancelled, let self, let task = self.continuedTask {
                // The system ends a task whose progress stops moving, so creep a little
                // while one long step is under way.
                let done = Int64(((self.progress ?? 0) * 1_000).rounded())
                let shown = task.progress.completedUnitCount
                task.progress.completedUnitCount = min(max(done, shown + (shown < 990 ? 1 : 0)), 999)
                let text = self.progressText
                if !text.isEmpty, text != subtitle, let job = self.current {
                    subtitle = text
                    task.updateTitle(self.title(for: job), subtitle: text)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        startIfNeeded()
    }

    private func finishContinuedTaskIfIdle() {
        guard continuedTask != nil, runner == nil else { return }
        let finished = !jobs.contains { $0.state == .queued || $0.state == .running }
        releaseContinuedTask(success: finished)
    }

    private func releaseContinuedTask(success: Bool) {
        continuedReporting?.cancel()
        continuedReporting = nil
        guard let task = continuedTask else { return }
        continuedTask = nil
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
    }

    private func title(for job: SavedImport) -> String {
        switch job.kind {
        case .google: String(localized: "Importing Google Timeline")
        case .routes: String(localized: "Importing routes")
        case .archive: String(localized: "Importing timeline archive")
        }
    }

    // MARK: Time left

    /// Measured from this run's pace, once enough of it is done to say.
    var estimatedTimeLeft: TimeInterval? {
        guard let started = runStartedAt, let fraction = progress, fraction >= 0.05, fraction < 1 else { return nil }
        let elapsed = Date.now.timeIntervalSince(started)
        guard elapsed >= 20 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }
}

/// Existing Settings card styling, with one place to resume work after leaving an import screen.
struct ImportQueueCard: View {
    @EnvironmentObject private var queue: DurableImportQueue
    var body: some View {
        if !queue.jobs.isEmpty || queue.storageError != nil || queue.isStaging {
            SettingsCard(title: String(localized: "Imports")) {
                if queue.isStaging { ProgressView(String(localized: "Saving selected files…")) }
                if queue.storageError != nil {
                    Text("Import progress is unavailable. Reopen Moves to try again.").foregroundStyle(.secondary)
                }
                ForEach(queue.jobs.reversed()) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ListFormatter.localizedString(byJoining: job.names)).font(.headline).lineLimit(2)
                        if job.state == .running {
                            if let progress = queue.progress { ProgressView(value: progress) } else { ProgressView() }
                            Text(queue.progressText).font(.caption).foregroundStyle(.secondary)
                            if let left = queue.estimatedTimeLeft {
                                Text(timeLeftText(left)).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Pause") { queue.pause(job.id) }
                        } else {
                            Text(label(for: job)).font(.subheadline).foregroundStyle(.secondary)
                            HStack {
                                if job.state == .paused || job.state == .failed {
                                    Button(job.state == .failed ? "Retry" : "Resume") { queue.resume(job.id) }
                                }
                                if job.state == .queued { Button("Pause") { queue.pause(job.id) } }
                                else { Button("Dismiss") { queue.remove(job.id) }.disabled(queue.workingJobID == job.id) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func timeLeftText(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return String(localized: "Less than a minute left") }
        let minutes = Int((seconds / 60).rounded(.up))
        let duration = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return String(localized: "About \(duration) left")
    }

    private func label(for job: SavedImport) -> String {
        switch job.state {
        case .running: String(localized: "Importing…")
        case .queued: String(localized: "Waiting")
        case .paused: String(localized: "Paused")
        case .completed: job.message ?? String(localized: "Imported")
        case .failed: job.message ?? String(localized: "Import couldn’t finish")
        }
    }
}
