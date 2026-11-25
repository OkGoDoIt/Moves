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

    func earliestPhotoDate() async throws -> Date? {
        guard hasReadAccess else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "creationDate != nil")
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: .image, options: options).firstObject?.creationDate
    }

    func libraryRoll(in interval: DateInterval) async throws -> [LibraryRollEntry] {
        guard hasReadAccess else { return [] }
        var entries: [LibraryRollEntry] = []
        Self.fetch(in: interval, stillsOnly: false).enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            // PhotoKit objects pile up across a library of hundreds of thousands otherwise.
            autoreleasepool {
                guard let capturedAt = asset.creationDate, let addedAt = asset.addedDate else { return }
                let name = Self.originalFileName(of: asset)
                let number = Self.rollNumber(fileName: name, capturedAt: capturedAt, addedAt: addedAt)
                entries.append(
                    LibraryRollEntry(
                        capturedAt: capturedAt,
                        addedAt: addedAt,
                        number: number,
                        // A camera never makes a PNG; a screenshot from an old phone may
                        // have lost its mark on the way through a backup, but not its name.
                        isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                            || (number != nil && name?.lowercased().hasSuffix(".png") == true),
                        // Only photos on the counter are compared by place.
                        place: number == nil || asset.mediaType != .image ? nil : asset.location.map { location in
                            PhotoPlace(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                accuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
                            )
                        }
                    )
                )
            }
        }
        try Task.checkCancellation()
        return entries
    }

    func cameraModels(for identifiers: [String]) async -> [String: String] {
        guard hasReadAccess, !identifiers.isEmpty else { return [:] }
        var resources: [(String, PHAssetResource)] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            let all = PHAssetResource.assetResources(for: asset)
            if let resource = all.first(where: { $0.type == .photo }) ?? all.first {
                resources.append((asset.localIdentifier, resource))
            }
        }

        var models: [String: String] = [:]
        // A few at a time: each read is a short burst of disk, not CPU.
        for batch in stride(from: 0, to: resources.count, by: 6).map({ resources[$0..<min($0 + 6, resources.count)] }) {
            await withTaskGroup(of: (String, String?).self) { group in
                for (identifier, resource) in batch {
                    group.addTask { (identifier, await Self.cameraModel(in: resource)) }
                }
                for await (identifier, model) in group {
                    models[identifier] = model
                }
            }
            if Task.isCancelled { break }
        }
        return models
    }

    /// Reads the start of a photo's original file, where the camera wrote its make and
    /// model, and stops. Fails at once when the original is only in iCloud.
    private static func cameraModel(in resource: PHAssetResource) async -> String? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        final class Reading: @unchecked Sendable {
            var data = Data()
            var model: String?
            var request: PHAssetResourceDataRequestID?
            var isDone = false
        }
        let reading = Reading()
        let lock = NSLock()

        return await withCheckedContinuation { continuation in
            let request = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                lock.lock()
                defer { lock.unlock() }
                guard !reading.isDone else { return }
                reading.data.append(chunk)
                // The header is in the first few kilobytes of a JPEG and a little further
                // into a HEIC. Past half a megabyte it is not coming.
                guard reading.data.count >= 32 * 1024 else { return }
                reading.model = Self.cameraModel(inFilePrefix: reading.data)
                if reading.model != nil || reading.data.count >= 512 * 1024 {
                    reading.isDone = true
                    if let request = reading.request {
                        PHAssetResourceManager.default().cancelDataRequest(request)
                    }
                }
            } completionHandler: { _ in
                lock.lock()
                let model = reading.model ?? (reading.data.isEmpty ? nil : Self.cameraModel(inFilePrefix: reading.data))
                reading.isDone = true
                lock.unlock()
                continuation.resume(returning: model)
            }
            lock.lock()
            reading.request = request
            let finishedEarly = reading.isDone
            lock.unlock()
            if finishedEarly {
                PHAssetResourceManager.default().cancelDataRequest(request)
            }
        }
    }

    static func cameraModel(inFilePrefix data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return model
    }

    /// The name the camera gave the file. iOS 27 keeps it with the asset; before that it
    /// is on the asset's resources, which costs a lookup per photo.
    private static func originalFileName(of asset: PHAsset) -> String? {
        if #available(iOS 27, *) {
            return asset.extendedMetadata.originalFilename
        }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    /// The camera's counter. A file that went through a backup may carry a suffix.
    private static func rollNumber(fileName: String?, capturedAt: Date, addedAt: Date) -> Int? {
        CameraRollEntry.number(
            inFileName: fileName,
            allowingSuffix: !PhotoCaptureClassifier.isCameraCapture(capturedAt: capturedAt, addedAt: addedAt)
        )
    }

    /// Items in the person's own library: all of `interval` oldest first, or only its
    /// newest few. Shared albums and photos synced from a computer belong to other
    /// libraries and are left out.
    private static func fetch(
        in interval: DateInterval,
        newest limit: Int? = nil,
        stillsOnly: Bool = true
    ) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        if #available(iOS 27, *) {
            options.prefetchAssetExtendedMetadata = true
        }
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
        return stillsOnly ? PHAsset.fetchAssets(with: .image, options: options) : PHAsset.fetchAssets(with: options)
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
            let addedAt = asset.addedDate
            page.assets.append(
                PhotoAssetDescriptor(
                    localIdentifier: asset.localIdentifier,
                    capturedAt: capturedAt,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil,
                    isCameraCapture: PhotoCaptureClassifier.isCameraCapture(capturedAt: capturedAt, addedAt: addedAt),
                    addedAt: addedAt,
                    rollNumber: addedAt.flatMap { added in
                        Self.rollNumber(
                            fileName: Self.originalFileName(of: asset),
                            capturedAt: capturedAt,
                            addedAt: added
                        )
                    }
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
    /// True while a step of the history import is being written.
    @Published private(set) var isHistoryImportWorking = false
    /// How long the rest of the history import should take at the pace so far.
    @Published private(set) var historyTimeRemaining: TimeInterval?
    /// True while the import is working out which photos the owner's phone took.
    @Published private(set) var isReadingLibrary = false
    /// How much of the library that has been read for, from 0 to 1.
    @Published private(set) var libraryReadShare = 0.0
    /// The owner's phones over the years, as far as the photos on this device show.
    @Published private(set) var ownCameraPeriods: [OwnCameraRoster.Period] = []
    @Published private(set) var isCheckingRecentPhotos = false
    @Published private(set) var fixStatus = PhotoFixStatus()

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
    private var grants: Set<WorkGrant> = []
    /// Where the job's photos came from; `nil` inside when it could not be worked out.
    private var ledger: (job: UUID, value: PhotoOriginLedger?)?
    private let ledgerCache = PhotoOriginLedgerCache.standard
    private var sampleObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    /// The import works only while this is true.
    @Published private(set) var isCharging = true

    /// The process's one controller, for background tasks, which start without a view.
    private(set) static weak var current: PhotoLibraryController?

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
        ownCameraPeriods = OwnCameraRosterStore(defaults: defaults).load().periods()
        refreshFixStatus()

        historyJob = jobStore.load()

        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        Self.current = self
        UIDevice.current.isBatteryMonitoringEnabled = true
        isCharging = Self.deviceIsCharging
        powerObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged() }
        }
        // The phone is woken for new fixes while Moves is closed. That is the moment to
        // look for photos taken since the last look.
        sampleObserver = NotificationCenter.default.addObserver(
            forName: .movesLocationSamplesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.processRecentPhotosAfterNewFixes()
                if UIApplication.shared.applicationState == .background {
                    self?.workBriefly()
                }
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

    /// Reading a whole library is hard on the battery, so it waits for the charger.
    private var mayWork: Bool {
        hasReadAccess && isCharging && !grants.isEmpty
    }

    /// A simulator has no battery and counts as plugged in.
    private static var deviceIsCharging: Bool {
        UIDevice.current.batteryState != .unplugged
    }

    private func powerChanged() {
        let charging = Self.deviceIsCharging
        guard charging != isCharging else { return }
        isCharging = charging
        guard isImporting else { return }
        Self.log.notice("Photo history \(charging ? "continues: charging" : "waits: unplugged", privacy: .public)")
        guard charging else { return }
        if grants.contains(.scene) {
            requestContinuing()
        } else {
            workBriefly()
        }
        continueHistoryImport()
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
        if isActive {
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            grants.insert(.scene)
            if isImporting {
                requestContinuing()
            }
            continueHistoryImport()
        } else {
            grants.remove(.scene)
            if isImporting {
                PhotoHistoryBackgroundTask.scheduleResume()
                workBriefly()
            }
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

    /// Begins importing the whole library. Returns at once: the job is written down before
    /// anything is read, and from then on it finishes on its own.
    func startHistoryImport() {
        guard !isImporting else { return }
        ledgerCache.clear()
        ledger = nil
        libraryReadShare = 0
        setHistoryJob(.wholeLibrary())
        requestContinuing()
        continueHistoryImport()
    }

    /// Stops after the step that is running. Nothing already saved is undone.
    func pauseHistoryImport() {
        guard var job = historyJob, job.state == .running else { return }
        job.state = .paused
        setHistoryJob(job)
        PhotoHistoryBackgroundTask.cancelResume()
    }

    func resumeHistoryImport() {
        guard var job = historyJob, job.state == .paused else { return }
        guard job.rules == PhotoHistoryJob.currentRules else {
            // Begun by a version that read fewer photos. What it added is kept and is
            // recognized when it comes by again.
            startHistoryImport()
            return
        }
        job.state = .running
        job.message = nil
        job.unfinishedStepStarts = 0
        setHistoryJob(job)
        requestContinuing()
        continueHistoryImport()
    }

    // MARK: Time to work in

    /// What lets the import work right now. Without any, the loop ends after its step.
    enum WorkGrant: Hashable {
        /// Moves is on screen.
        case scene
        /// The system lets a started import go on after the person leaves.
        case continuedTask
        /// The phone is idle.
        case processingTask
        /// A few seconds after leaving Moves, or after a wake for a new fix.
        case brief
    }

    /// Holds `grant` until the import is done or the grant is taken back.
    func workUntilDone(with grant: WorkGrant) async {
        grants.insert(grant)
        continueHistoryImport()
        while isImporting, isCharging, grants.contains(grant) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        grants.remove(grant)
    }

    func endWork(with grant: WorkGrant) {
        grants.remove(grant)
    }

    /// The system ended the continued task. Whatever time is left is used, and the idle
    /// task carries on from there.
    func continuedTaskExpired(after progress: Int64) {
        Self.log.notice("Continued task ended by the system at \(progress) of 1000000")
        endWork(with: .continuedTask)
        guard isImporting else { return }
        PhotoHistoryBackgroundTask.scheduleResume()
        if !grants.contains(.scene) {
            workBriefly()
        }
    }

    /// Uses the seconds the system gives an app that just left the screen or was woken.
    private func workBriefly() {
        guard isImporting, isCharging, !grants.contains(.brief) else { return }
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Photo history import") { [weak self] in
            self?.endWork(with: .brief)
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        guard identifier != .invalid else { return }
        Task {
            grants.insert(.brief)
            continueHistoryImport()
            // A step takes a second or two and is protected by a request of its own, so
            // stopping with time to spare means none is cut off.
            while isImporting, isCharging, grants.contains(.brief), UIApplication.shared.backgroundTimeRemaining > 12 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            grants.remove(.brief)
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }

    private func requestContinuing() {
        guard isCharging, !grants.contains(.continuedTask), UIApplication.shared.applicationState != .background else { return }
        do {
            try PhotoHistoryBackgroundTask.requestContinuing(title: continuingTitle, subtitle: continuingSubtitle)
        } catch {
            Self.log.error("Continuing in the background was refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    var continuingTitle: String { String(localized: "Importing photo history") }

    var continuingSubtitle: String {
        guard let job = historyJob, job.cursor < job.rangeEnd else {
            return String(localized: "Finding the photos your phone took")
        }
        let reached = job.cursor.formatted(.dateTime.month(.wide).year())
        return String(localized: "Back to \(reached)")
    }

    private var historyRunner: PhotoHistoryImportRunner {
        PhotoHistoryImportRunner(
            provider: service,
            container: modelContainer,
            rosterStore: OwnCameraRosterStore(defaults: defaults),
            rejectedStore: RejectedPhotoStore(defaults: defaults)
        )
    }

    private func setHistoryJob(_ job: PhotoHistoryJob?) {
        historyJob = job
        jobStore.save(job)
    }

    /// Works through the job for as long as something allows it. Losing every grant ends
    /// the loop after the current step, and the next one starts it again from the saved
    /// cursor. An error is tried again; nothing but the person pausing it stops the import
    /// for good.
    private func continueHistoryImport() {
        guard historyTask == nil, mayWork, historyJob?.state == .running else { return }
        let runner = historyRunner
        historyTask = Task { [weak self] in
            await TimelineSchemaUpgrader.waitUntilFinished()
            var wroteAnything = false
            var pace: (since: Date, remaining: Int, steps: Int)?
            while let self, !Task.isCancelled, self.mayWork,
                  var job = self.historyJob, job.state == .running {
                if job.rules != PhotoHistoryJob.currentRules {
                    self.setHistoryJob(.wholeLibrary())
                    continue
                }
                if !job.isCounted {
                    self.isReadingLibrary = true
                    let uncounted = job
                    let counted = try? await Task.detached(priority: .utility) { try await runner.counted(uncounted) }.value
                    guard var current = self.historyJob, current.id == job.id else { continue }
                    guard let counted else {
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    }
                    current = counted
                    current.state = self.historyJob?.state ?? current.state
                    self.setHistoryJob(current)
                    continue
                }
                if self.ledger?.job != job.id {
                    await self.prepareLedger(for: job, runner: runner)
                    continue
                }
                job.unfinishedStepStarts += 1
                self.setHistoryJob(job)
                self.isHistoryImportWorking = true
                let started = job
                let began = Date.now
                let origins = self.ledger?.value
                if pace == nil {
                    pace = (.now, started.remainingPhotoCount, 0)
                }
                do {
                    let advanced = try await Self.withStoreWriteTime(named: "Photo history") {
                        try await Task.detached(priority: .utility) {
                            try await runner.runStep(started, ledger: origins)
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
                    Self.log.notice(
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
                    await self.restIfOffScreen(after: Date.now.timeIntervalSince(began))
                } catch {
                    // The step wrote nothing. It is tried again, smaller each time, and the
                    // job's own count of starts decides when to pass its photos over.
                    Self.log.error("Photo history step failed: \(error.localizedDescription, privacy: .public)")
                    guard var current = self.historyJob, current.id == started.id else { continue }
                    current.message = String(localized: "Trying again: \(error.localizedDescription)")
                    self.setHistoryJob(current)
                    self.isHistoryImportWorking = false
                    try? await Task.sleep(for: .seconds(min(2 << current.unfinishedStepStarts, 30)))
                }
            }
            guard let self else { return }
            self.historyTask = nil
            self.isHistoryImportWorking = false
            self.isReadingLibrary = false
            self.historyTimeRemaining = nil
            self.ownCameraPeriods = OwnCameraRosterStore(defaults: self.defaults).load().periods()
            if wroteAnything {
                PhotoHistoryImporter.announceChanges()
            }
            if self.historyJob?.state == .finished {
                self.ledger = nil
                self.ledgerCache.clear()
                PhotoHistoryBackgroundTask.cancelResume()
                if wroteAnything {
                    RouteMatchBackgroundTask.scheduleAfterImport()
                }
                return
            }
            // A grant can arrive between the loop's last check and here.
            self.continueHistoryImport()
        }
    }

    /// Off screen the system ends an app that keeps the processor busy for more than 80% of
    /// a minute, so the work takes breaks there. A hot phone gets longer ones anywhere: it
    /// slows down everything else on the screen.
    private func restIfOffScreen(after worked: TimeInterval) async {
        guard worked > 0.2 else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            try? await Task.sleep(for: .seconds(min(worked * 3, 20)))
            return
        }
        guard !grants.contains(.scene) else { return }
        try? await Task.sleep(for: .seconds(min(worked * 0.6, 8)))
    }

    /// Works out where every photo came from, or takes it from the cache. The library is
    /// read in parts that are kept as they are done, so being stopped costs one part.
    private func prepareLedger(for job: PhotoHistoryJob, runner: PhotoHistoryImportRunner) async {
        isReadingLibrary = true
        defer { isReadingLibrary = false }
        let cache = ledgerCache
        if let cached = await Task.detached(priority: .utility, operation: { cache.load(for: job.id) }).value {
            ledger = (job.id, cached)
            return
        }
        // If reading it has itself stopped Moves this often, the import goes on with only
        // the photos that were added when they were taken rather than never finishing.
        guard job.ledgerAttempts < 4 else {
            ledger = (job.id, nil)
            Self.log.error("The library could not be read; importing without its history")
            return
        }

        func isCurrent() -> Bool {
            mayWork && historyJob?.id == job.id && historyJob?.state == .running
        }
        func setAttempts(_ count: Int) {
            guard var current = historyJob, current.id == job.id else { return }
            current.ledgerAttempts = count
            setHistoryJob(current)
        }

        let began = Date.now
        let pieces = runner.libraryPieces(for: job)
        do {
            for index in pieces.indices {
                guard isCurrent() else { return }
                let pieceBegan = Date.now
                setAttempts((historyJob?.ledgerAttempts ?? 0) + 1)
                try await Task.detached(priority: .utility) {
                    try await runner.readPiece(index, of: pieces, for: job, cache: cache)
                }.value
                setAttempts(0)
                await restIfOffScreen(after: Date.now.timeIntervalSince(pieceBegan))
                libraryReadShare = Double(index + 1) / Double(pieces.count)
            }
            guard isCurrent() else { return }
            setAttempts((historyJob?.ledgerAttempts ?? 0) + 1)
            let built = try await Task.detached(priority: .utility) {
                try await runner.makeLedger(for: job, cache: cache)
            }.value
            setAttempts(0)
            ledger = (job.id, built)
            Self.log.notice(
                "Library read in \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1)) s: \(built.camera.ownItemCount) items from this phone, \(built.camera.otherItemCount) from other phones; with imports \(built.archive.ownItemCount) and \(built.archive.otherItemCount)"
            )
        } catch {
            Self.log.error("Reading the library failed: \(error.localizedDescription, privacy: .public)")
            try? await Task.sleep(for: .seconds(5))
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
            let found = try await service.geotaggedAssets(in: interval)
            guard !found.isEmpty else {
                defaults.set(now, forKey: PhotoLibrarySettings.lastAttachPassAtKey)
                return
            }
            // Which of them this phone took. Without file names the ledger is empty and a
            // photo added when it was taken still counts.
            let service = service
            let ledger = try? await Task.detached(priority: .utility) {
                try await service.originLedger(around: interval)
            }.value
            let assets = found.map { $0.resolved(with: ledger) }

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

                // Last check: the camera model in the file. A new model waits until it has
                // taken a few photos in a row, so a replacement phone is picked up and a
                // stray photo from someone else's is not.
                var accepted = selection.accepted
                var nowHandled = selection.handled
                if !accepted.isEmpty {
                    let models = await service.cameraModels(for: accepted.map(\.localIdentifier))
                    let rosterStore = OwnCameraRosterStore(defaults: defaults)
                    var roster = rosterStore.load()
                    let confirmed = roster.acceptNew(
                        accepted.map { ($0.localIdentifier, models[$0.localIdentifier], $0.capturedAt) }
                    )
                    rosterStore.save(roster)
                    ownCameraPeriods = roster.periods()
                    for photo in accepted where !confirmed.contains(photo.localIdentifier) {
                        nowHandled[photo.localIdentifier] = nil
                    }
                    accepted = accepted.filter { confirmed.contains($0.localIdentifier) }
                }

                if !accepted.isEmpty {
                    await ingestFixes(accepted.compactMap(\.fixLocation))
                    var used = loadFixTimes(PhotoLibrarySettings.usedFixesKey)
                    for photo in accepted {
                        used[photo.localIdentifier] = photo.capturedAt
                    }
                    saveFixTimes(used, key: PhotoLibrarySettings.usedFixesKey)
                }
                let ownCount = assets.count(where: \.isCameraCapture)
                let otherCount = assets.count(where: \.isFromAnotherDevice)
                Self.log.info(
                    "New photo check: \(assets.count) with a location, \(ownCount) from this phone, \(otherCount) from other devices, \(accepted.count) added as fixes"
                )
                if nowHandled != handled {
                    saveFixTimes(nowHandled, key: PhotoLibrarySettings.handledFixesKey)
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
