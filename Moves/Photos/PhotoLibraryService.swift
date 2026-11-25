import Combine
import CoreLocation
import Foundation
import OSLog
import Photos
import PhotosUI
import SwiftData
import UIKit

/// Read-only PhotoKit façade.
///
/// Requests `.readWrite` because iOS has no read-only library level, then
/// never calls `performChanges`, never creates albums, and never deletes
/// assets. Thumbnails are generated with `PHCachingImageManager`.
actor PhotoLibraryService: PhotoAssetProviding {
    static let shared = PhotoLibraryService()

    private let imageManager = PHCachingImageManager()

    /// Current `.readWrite` status, including `.limited`.
    nonisolated var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    nonisolated var hasReadAccess: Bool {
        switch authorizationStatus {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    /// Prompts for library access. The handler may return `.limited`.
    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func geotaggedAssets(in interval: DateInterval) async throws -> [PhotoAssetDescriptor] {
        guard hasReadAccess else { return [] }
        return Self.descriptors(in: Self.fetch(in: interval)).assets
    }

    func newestAssets(in interval: DateInterval, limit: Int) async throws -> PhotoAssetPage {
        guard hasReadAccess else { return PhotoAssetPage(assets: [], scannedCount: 0, earliestScannedAt: nil) }
        return Self.descriptors(in: Self.fetch(in: interval, newest: limit))
    }

    func photoCount(in interval: DateInterval) async throws -> Int {
        guard hasReadAccess else { return 0 }
        return Self.fetch(in: interval).count
    }

    /// Still images in the person's own library: all of `interval` oldest first, or only
    /// its newest few. Shared albums and photos synced from a computer belong to other
    /// libraries and are left out.
    private static func fetch(in interval: DateInterval, newest limit: Int? = nil) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate,
            interval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: limit == nil)]
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.wantsIncrementalChangeDetails = false
        options.fetchLimit = limit ?? 0
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    /// Reads only what PhotoKit keeps in its database, so nothing is downloaded from iCloud.
    private static func descriptors(in fetch: PHFetchResult<PHAsset>) -> PhotoAssetPage {
        var page = PhotoAssetPage(assets: [], scannedCount: 0, earliestScannedAt: nil)
        fetch.enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            page.scannedCount += 1
            guard let capturedAt = asset.creationDate else { return }
            page.earliestScannedAt = min(page.earliestScannedAt ?? capturedAt, capturedAt)
            // A screenshot shows a place; it wasn't taken there.
            guard !asset.mediaSubtypes.contains(.photoScreenshot), let location = asset.location else { return }
            page.assets.append(
                PhotoAssetDescriptor(
                    localIdentifier: asset.localIdentifier,
                    capturedAt: capturedAt,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil,
                    isCameraCapture: PhotoCaptureClassifier.isCameraCapture(
                        capturedAt: capturedAt,
                        addedAt: asset.addedDate
                    )
                )
            )
        }
        page.assets.sort { $0.capturedAt < $1.capturedAt }
        return page
    }

    /// Loads a thumbnail or full-size still. Never writes back to the library.
    func image(
        for identifier: String,
        targetSize: CGSize,
        quality: PHImageRequestOptionsDeliveryMode = .fastFormat
    ) async -> UIImage? {
        // Fetching without access would raise the system prompt from a passing thumbnail.
        guard hasReadAccess else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = quality
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let manager = imageManager
        return await withCheckedContinuation { continuation in
            var didResume = false
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                if quality == .fastFormat {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: image)
                    }
                    return
                }
                if !degraded, !didResume {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}

/// Main-actor coordinator for Settings, storyline refresh, and change observation.
///
/// Capture, Live Activity, and this observer live above the tab bar so
/// fold/rotation does not tear photo attachment down.
@MainActor
final class PhotoLibraryController: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    /// The history import in progress, paused, or just finished.
    @Published private(set) var historyJob: PhotoHistoryJob?
    @Published private(set) var isPreparingHistoryImport = false
    /// True while a step of the history import is being written.
    @Published private(set) var isHistoryImportWorking = false
    /// How long the rest of the history import should take at the pace so far.
    @Published private(set) var historyTimeRemaining: TimeInterval?
    @Published private(set) var isCheckingRecentPhotos = false
    @Published private(set) var fixStatus = PhotoFixStatus()
    @Published private(set) var lastErrorMessage: String?

    let modelContainer: ModelContainer
    let service: PhotoLibraryService
    /// Hands accepted photo fixes to the timeline. Set once by the app's runtime so
    /// they are written by the same worker as every other fix.
    var ingestFixes: (([CLLocation]) async -> Void)?

    private let jobStore: PhotoHistoryJobStore
    private let defaults: UserDefaults
    private var changeRelay: PhotoLibraryChangeRelay?
    private var historyTask: Task<Void, Never>?
    private var recentPassTask: Task<Void, Never>?
    private var needsAnotherRecentPass = false
    private var lastRecentPassAt: Date?
    private var isSceneActive = false
    private var sampleObserver: NSObjectProtocol?

    /// Counts only. Where a photo was taken never reaches the log.
    private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Photos")

    /// Location fixes arrive in bursts; one look at the library covers a burst.
    private static let minimumBackgroundPassInterval: TimeInterval = 3 * 60

    init(
        modelContainer: ModelContainer,
        service: PhotoLibraryService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.modelContainer = modelContainer
        self.service = service
        self.defaults = defaults
        self.jobStore = PhotoHistoryJobStore(defaults: defaults)
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        refreshFixStatus()

        var job = jobStore.load()
        if var interrupted = job, interrupted.state == .running, interrupted.unfinishedStepStarts >= 2 {
            interrupted.state = .paused
            interrupted.message = String(localized: "The import stopped twice at the same photos.")
            jobStore.save(interrupted)
            job = interrupted
        }
        historyJob = job

        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        // The phone is woken for new fixes while Moves is closed. That is the moment to
        // look for photos taken since the last look.
        sampleObserver = NotificationCenter.default.addObserver(
            forName: .movesLocationSamplesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.processRecentPhotosAfterNewFixes()
            }
        }
    }

    var hasReadAccess: Bool {
        switch authorizationStatus {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    var isLimited: Bool {
        authorizationStatus == .limited
    }

    var isImporting: Bool {
        historyJob?.state == .running
    }

    /// Starts the PhotoKit change observer. Safe to call more than once.
    func start() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasReadAccess else { return }
        if changeRelay == nil {
            let relay = PhotoLibraryChangeRelay { [weak self] in
                Task { @MainActor in
                    await self?.processRecentPhotos()
                }
            }
            changeRelay = relay
            PHPhotoLibrary.shared().register(relay)
        }
    }

    func sceneChanged(isActive: Bool) {
        isSceneActive = isActive
        if isActive {
            continueHistoryImport()
        }
    }

    func handleSceneBecameActive() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasReadAccess else { return }
        start()
        await processRecentPhotos()
    }

    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await service.requestAuthorization()
        authorizationStatus = status
        if hasReadAccess {
            start()
            await processRecentPhotos()
        }
        return status
    }

    /// Limited Library picker so the user can add or remove selected photos.
    func presentLimitedLibraryPicker() {
        guard isLimited else { return }
        guard let presenter = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    // MARK: - History import

    /// Counts what an import of `interval` would read. Runs off the main actor: the
    /// library can hold tens of thousands of photos.
    func previewHistory(in interval: DateInterval, includesSavedPhotos: Bool) async throws -> PhotoHistoryPreview {
        let service = service
        return try await importWorkerValue(Task.detached(priority: .userInitiated) {
            let assets = try await service.geotaggedAssets(in: interval)
            try Task.checkCancellation()
            return PhotoHistoryImporter.preview(
                assets: assets,
                in: interval,
                includesSavedPhotos: includesSavedPhotos
            )
        })
    }

    func startHistoryImport(in interval: DateInterval, includesSavedPhotos: Bool) {
        guard !isImporting, !isPreparingHistoryImport else { return }
        isPreparingHistoryImport = true
        lastErrorMessage = nil
        let runner = historyRunner
        Task {
            defer { isPreparingHistoryImport = false }
            do {
                setHistoryJob(try await runner.makeJob(in: interval, includesSavedPhotos: includesSavedPhotos))
                continueHistoryImport()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Stops after the step that is running. Nothing already saved is undone.
    func pauseHistoryImport() {
        guard var job = historyJob, job.state == .running else { return }
        job.state = .paused
        job.message = nil
        setHistoryJob(job)
    }

    func resumeHistoryImport() {
        guard var job = historyJob, job.state == .paused || job.state == .failed else { return }
        job.state = .running
        job.message = nil
        job.unfinishedStepStarts = 0
        setHistoryJob(job)
        continueHistoryImport()
    }

    /// Forgets a finished or abandoned import. What it already added stays.
    func clearHistoryImport() {
        guard historyJob?.state != .running else { return }
        setHistoryJob(nil)
    }

    private var historyRunner: PhotoHistoryImportRunner {
        PhotoHistoryImportRunner(provider: service, container: modelContainer)
    }

    private func setHistoryJob(_ job: PhotoHistoryJob?) {
        historyJob = job
        jobStore.save(job)
    }

    /// Works through the job while Moves is open. Leaving the app ends the loop after
    /// the current step, and coming back starts it again from the saved cursor.
    private func continueHistoryImport() {
        guard historyTask == nil, isSceneActive, hasReadAccess, historyJob?.state == .running else { return }
        let runner = historyRunner
        historyTask = Task { [weak self] in
            await TimelineSchemaUpgrader.waitUntilFinished()
            var wroteAnything = false
            var pace: (since: Date, remaining: Int, steps: Int)?
            while let self, !Task.isCancelled, self.isSceneActive,
                  var job = self.historyJob, job.state == .running {
                job.unfinishedStepStarts += 1
                self.setHistoryJob(job)
                self.isHistoryImportWorking = true
                let started = job
                if pace == nil {
                    pace = (.now, started.remainingPhotoCount, 0)
                }
                do {
                    let advanced = try await Self.withStoreWriteTime(named: "Photo history") {
                        try await Task.detached(priority: .utility) {
                            try await runner.runStep(started)
                        }.value
                    }
                    wroteAnything = true
                    // A pause or a new import that arrived while the step ran keeps its say.
                    guard let current = self.historyJob, current.id == started.id else { continue }
                    var merged = advanced
                    if current.state == .paused, merged.state == .running {
                        merged.state = .paused
                    }
                    self.setHistoryJob(merged)
                    Self.log.info(
                        "Photo history step done: \(merged.checkedPhotoCount) of \(merged.totalPhotoCount) photos checked, \(merged.state.rawValue, privacy: .public)"
                    )
                    if var measured = pace {
                        measured.steps += 1
                        pace = measured
                        self.historyTimeRemaining = Self.timeRemaining(
                            for: merged,
                            since: measured.since,
                            startingFrom: measured.remaining,
                            steps: measured.steps
                        )
                    }
                } catch {
                    guard var current = self.historyJob, current.id == started.id else { continue }
                    current.state = .failed
                    current.message = error.localizedDescription
                    self.setHistoryJob(current)
                    Self.log.error("Photo history step failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let self else { return }
            self.historyTask = nil
            self.isHistoryImportWorking = false
            self.historyTimeRemaining = nil
            if wroteAnything {
                PhotoHistoryImporter.announceChanges()
                if self.historyJob?.state == .finished {
                    RouteMatchBackgroundTask.scheduleAfterImport()
                }
            }
            // The scene can come back between the loop's last check and here.
            self.continueHistoryImport()
        }
    }

    /// The first step also warms caches, so the estimate starts with the second.
    private static func timeRemaining(
        for job: PhotoHistoryJob,
        since start: Date,
        startingFrom initialRemaining: Int,
        steps: Int
    ) -> TimeInterval? {
        let done = initialRemaining - job.remainingPhotoCount
        guard job.state == .running, steps >= 2, done > 0 else { return nil }
        return Date.now.timeIntervalSince(start) / Double(done) * Double(job.remainingPhotoCount)
    }

    // MARK: - New photos

    /// Looks at photos taken since the last look: camera photos become timeline fixes,
    /// and geotagged photos are attached to the visits they were taken at.
    func processRecentPhotos() async {
        if let recentPassTask {
            needsAnotherRecentPass = true
            await recentPassTask.value
            return
        }
        let task = Task { await performRecentPass() }
        recentPassTask = task
        isCheckingRecentPhotos = true
        await task.value
        recentPassTask = nil
        isCheckingRecentPhotos = false
        refreshFixStatus()
        if needsAnotherRecentPass {
            needsAnotherRecentPass = false
            await processRecentPhotos()
        }
    }

    private func processRecentPhotosAfterNewFixes() async {
        if let lastRecentPassAt, Date.now.timeIntervalSince(lastRecentPassAt) < Self.minimumBackgroundPassInterval {
            return
        }
        await processRecentPhotos()
    }

    private func performRecentPass() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let usesFixes = PhotoLibrarySettings.usesCameraPhotosAsFixes && ingestFixes != nil
        let showsPhotos = PhotoLibrarySettings.showsPhotosOnVisits
        guard hasReadAccess, usesFixes || showsPhotos else { return }

        let now = Date.now
        lastRecentPassAt = now
        // A photo can reach this phone days after it was taken, from another device.
        let lastPass = defaults.object(forKey: PhotoLibrarySettings.lastAttachPassAtKey) as? Date
        let earliest = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let start = max(min(lastPass ?? now, now.addingTimeInterval(-3 * 24 * 60 * 60)), earliest)
        let interval = DateInterval(start: start.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(60))
        let container = modelContainer

        do {
            let assets = try await service.geotaggedAssets(in: interval)
            guard !assets.isEmpty else {
                defaults.set(now, forKey: PhotoLibrarySettings.lastAttachPassAtKey)
                return
            }

            if usesFixes, let ingestFixes {
                let handled = loadFixTimes(PhotoLibrarySettings.handledFixesKey)
                let selection = try await Task.detached(priority: .utility) {
                    PhotoFixSelection(
                        photos: assets,
                        fixes: try PhotoFixSelection.recordedFixes(around: interval, in: container),
                        handled: handled,
                        now: now
                    )
                }.value
                if !selection.accepted.isEmpty {
                    await ingestFixes(selection.accepted.compactMap(\.fixLocation))
                    var used = loadFixTimes(PhotoLibrarySettings.usedFixesKey)
                    for photo in selection.accepted {
                        used[photo.localIdentifier] = photo.capturedAt
                    }
                    saveFixTimes(used, key: PhotoLibrarySettings.usedFixesKey)
                }
                let cameraCount = assets.count(where: \.isCameraCapture)
                Self.log.info(
                    "New photo check: \(assets.count) with a location, \(cameraCount) from the camera, \(selection.accepted.count) added as fixes"
                )
                if selection.handled != handled {
                    saveFixTimes(selection.handled, key: PhotoLibrarySettings.handledFixesKey)
                }
            }

            if showsPhotos {
                try await Self.withStoreWriteTime(named: "Photo attachments") {
                    try await Task.detached(priority: .utility) {
                        let context = ModelContext(container)
                        context.autosaveEnabled = false
                        _ = try PhotoHistoryImporter(modelContext: context).attachPhotos(assets)
                    }.value
                }
            }
            defaults.set(now, forKey: PhotoLibrarySettings.lastAttachPassAtKey)
        } catch {
            // This runs unasked, so a failure belongs in the log, not on a screen.
            Self.log.error("New photo check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshFixStatus() {
        fixStatus = PhotoFixStatus(
            lastCheckedAt: defaults.object(forKey: PhotoLibrarySettings.lastAttachPassAtKey) as? Date,
            used: loadFixTimes(PhotoLibrarySettings.usedFixesKey)
        )
    }

    /// Capture times by photo identifier, without the ones too old to matter.
    private func loadFixTimes(_ key: String) -> [String: Date] {
        let cutoff = Date.now.addingTimeInterval(-PhotoFixSelection.maximumAge)
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value >= cutoff }
    }

    private func saveFixTimes(_ times: [String: Date], key: String) {
        defaults.set(times.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    /// The store lives in the App Group container. Being suspended in the middle of a
    /// write there ends the app (0xdead10cc), so each write asks for time to finish.
    private static func withStoreWriteTime<T>(
        named name: String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        defer {
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
        return try await work()
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

/// Forwards PhotoKit change callbacks without making `PhotoLibraryService` an NSObject.
final class PhotoLibraryChangeRelay: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        _ = changeInstance
        onChange()
    }
}

/// Loads a still for a `PhotoAttachment.assetLocalIdentifier`.
enum PhotoThumbnailLoader {
    static func image(
        for identifier: String,
        targetSize: CGSize,
        quality: PHImageRequestOptionsDeliveryMode = .fastFormat
    ) async -> UIImage? {
        await PhotoLibraryService.shared.image(
            for: identifier,
            targetSize: targetSize,
            quality: quality
        )
    }
}
