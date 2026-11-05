import Combine
import Foundation
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

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate,
            interval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false

        let fetch = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PhotoAssetDescriptor] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            guard let location = asset.location, let capturedAt = asset.creationDate else { return }
            assets.append(
                PhotoAssetDescriptor(
                    localIdentifier: asset.localIdentifier,
                    capturedAt: capturedAt,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            )
        }
        return assets
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
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: PhotoHistoryImportReport?
    @Published private(set) var lastErrorMessage: String?

    let modelContainer: ModelContainer
    let service: PhotoLibraryService
    private var changeRelay: PhotoLibraryChangeRelay?
    private var importTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, service: PhotoLibraryService = .shared) {
        self.modelContainer = modelContainer
        self.service = service
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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

    /// Starts the PhotoKit change observer. Safe to call more than once.
    func start() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasReadAccess else { return }
        if changeRelay == nil {
            let relay = PhotoLibraryChangeRelay { [weak self] in
                Task { @MainActor in
                    await self?.attachRecentPhotos()
                }
            }
            changeRelay = relay
            PHPhotoLibrary.shared().register(relay)
        }
    }

    func handleSceneBecameActive() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard PhotoLibrarySettings.showsPhotosOnVisits, hasReadAccess else { return }
        start()
        await attachRecentPhotos()
    }

    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await service.requestAuthorization()
        authorizationStatus = status
        if hasReadAccess {
            start()
            await attachRecentPhotos()
        }
        return status
    }

    /// Limited Library picker so the user can add or remove selected photos.
    func presentLimitedLibraryPicker() {
        guard isLimited else { return }
        guard let presenter = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    func previewHistory(in interval: DateInterval) async throws -> PhotoHistoryPreview {
        let assets = try await service.geotaggedAssets(in: interval)
        return PhotoHistoryImporter.preview(assets: assets, in: interval)
    }

    func importHistory(in interval: DateInterval) {
        guard !isImporting else { return }
        isImporting = true
        importProgress = 0
        importProgressText = String(localized: "Reading photos…")
        lastErrorMessage = nil
        lastReport = nil

        importTask?.cancel()
        importTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let assets = try await self.service.geotaggedAssets(in: interval)
                let report = try await Self.importOnBackground(
                    assets: assets,
                    interval: interval,
                    container: self.modelContainer
                ) { [weak self] fraction, text in
                    Task { @MainActor in
                        self?.importProgress = fraction
                        self?.importProgressText = text
                    }
                }
                self.lastReport = report
                self.importProgress = 1
                self.importProgressText = report.summary
            } catch is CancellationError {
                self.importProgressText = ""
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            self.isImporting = false
        }
    }

    /// Runs the SwiftData write off the main actor. Progress hops back via `progress`.
    nonisolated private static func importOnBackground(
        assets: [PhotoAssetDescriptor],
        interval: DateInterval,
        container: ModelContainer,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PhotoHistoryImportReport {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let importer = PhotoHistoryImporter(modelContext: context)
            return try importer.importHistory(assets: assets, in: interval, progress: progress)
        }.value
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isImporting = false
        importProgressText = String(localized: "Cancelled")
    }

    func attachRecentPhotos() async {
        guard hasReadAccess else { return }
        let now = Date.now
        let lastPass = UserDefaults.standard.object(forKey: PhotoLibrarySettings.lastAttachPassAtKey) as? Date
        let start = (lastPass ?? now.addingTimeInterval(-24 * 60 * 60)).addingTimeInterval(-15 * 60)
        let interval = DateInterval(start: start, end: now.addingTimeInterval(60))
        do {
            let assets = try await service.geotaggedAssets(in: interval)
            let container = modelContainer
            _ = try await Task.detached(priority: .utility) {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let importer = PhotoHistoryImporter(modelContext: context)
                return try importer.attachPhotos(assets)
            }.value
            UserDefaults.standard.set(now, forKey: PhotoLibrarySettings.lastAttachPassAtKey)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
