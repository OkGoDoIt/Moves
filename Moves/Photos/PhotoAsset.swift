import CoreLocation
import Foundation

/// UserDefaults keys for the Settings → Photos card.
enum PhotoLibrarySettings {
    /// When true, storyline place rows show inline thumbnails.
    static let showOnVisitsKey = "photos.showOnVisits"
    /// When true, photos taken with this phone add a fix to the timeline.
    static let usesCameraPhotosAsFixesKey = "photos.usesCameraPhotosAsFixes"
    /// Last time new library photos were attached to today's visits.
    static let lastAttachPassAtKey = "photos.lastAttachPassAt"
    /// Recent photos already offered to the timeline as fixes, by capture time.
    static let handledFixesKey = "photos.handledFixes"
    /// The ones among them that were used, by capture time.
    static let usedFixesKey = "photos.usedFixes"

    static var showsPhotosOnVisits: Bool {
        get { UserDefaults.standard.object(forKey: showOnVisitsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showOnVisitsKey) }
    }

    static var usesCameraPhotosAsFixes: Bool {
        get { UserDefaults.standard.object(forKey: usesCameraPhotosAsFixesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: usesCameraPhotosAsFixesKey) }
    }
}

/// Tells a photo taken with the library owner's camera from one that arrived another way.
///
/// PhotoKit has no "taken on this device" flag. A camera writes the photo into the library
/// the moment it is taken, so the capture time and the time it was added agree. A photo saved
/// from a message, a download, or an import was added long after it was taken, and carries
/// the place of whoever took it.
enum PhotoCaptureClassifier {
    /// A long exposure or a panorama is added a little after it began.
    static let cameraTolerance: TimeInterval = 2 * 60

    static func isCameraCapture(capturedAt: Date, addedAt: Date?) -> Bool {
        guard let addedAt else { return false }
        return abs(addedAt.timeIntervalSince(capturedAt)) <= cameraTolerance
    }
}

/// A geotagged library photo, independent of PhotoKit so tests can inject fakes.
struct PhotoAssetDescriptor: Sendable, Hashable, Identifiable {
    /// `PHAsset.localIdentifier`. Never a file path — the library stays untouched.
    var id: String { localIdentifier }
    let localIdentifier: String
    let capturedAt: Date
    let latitude: Double?
    let longitude: Double?
    /// Accuracy the camera recorded with the fix, when it recorded one.
    let horizontalAccuracy: Double?
    /// Taken with the library owner's own phone rather than saved, imported, or taken by
    /// another device that shares the library.
    var isCameraCapture: Bool
    /// Taken by a camera, but on a device other than the owner's phone: a partner's phone
    /// in an iCloud Shared Library, or a second device on the account. Never the owner's place.
    var isFromAnotherDevice = false
    /// When the photo entered the library.
    var addedAt: Date?
    /// The counter in a camera file name such as `IMG_4317.HEIC`.
    var rollNumber: Int?

    init(
        localIdentifier: String,
        capturedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        isCameraCapture: Bool = true,
        addedAt: Date? = nil,
        rollNumber: Int? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.isCameraCapture = isCameraCapture
        self.addedAt = addedAt
        self.rollNumber = rollNumber
    }

    /// The same photo with its origin settled by the camera-roll ledger.
    ///
    /// Without a ledger (no file names, or no screenshots to tell the owner's phone by) a
    /// photo added when it was taken keeps counting as the owner's. With one, only a photo
    /// on the owner's own counter does; a photo on another counter is another device's, and
    /// one with no counter at all is treated like a saved photo.
    func resolved(with ledger: OwnDeviceLedger?) -> PhotoAssetDescriptor {
        guard let ledger, ledger.ownItemCount > 0, isCameraCapture else { return self }
        var photo = self
        if let addedAt, let rollNumber {
            photo.isCameraCapture = ledger.contains(addedAt: addedAt, number: rollNumber)
            photo.isFromAnotherDevice = !photo.isCameraCapture
        } else {
            photo.isCameraCapture = false
        }
        return photo
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// Timed point used by `LocationLogSegmenter` during photo-history backfill.
    var locationLogPoint: LocationLogPoint? {
        guard let coordinate else { return nil }
        return LocationLogPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: horizontalAccuracy ?? 25,
            timestamp: capturedAt
        )
    }

    /// The fix this photo adds to the live timeline.
    var fixLocation: CLLocation? {
        guard let coordinate else { return nil }
        return CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy ?? 30,
            verticalAccuracy: -1,
            timestamp: capturedAt
        )
    }
}

/// One step's worth of library photos: the newest ones in the range asked for.
struct PhotoAssetPage: Sendable {
    /// Geotagged photos among the ones looked at, oldest first.
    var assets: [PhotoAssetDescriptor]
    /// Every photo looked at, with or without a location.
    var scannedCount: Int
    /// Capture time of the oldest photo looked at.
    var earliestScannedAt: Date?
}

/// Supplies geotagged photos for attachment and history backfill.
///
/// Production uses PhotoKit; tests inject an in-memory fake so they never
/// depend on the simulator photo library. Screenshots and photos from shared
/// albums are never returned.
protocol PhotoAssetProviding: Sendable {
    /// Geotagged still images whose capture time falls inside `interval` (end exclusive).
    func geotaggedAssets(in interval: DateInterval) async throws -> [PhotoAssetDescriptor]
    /// The newest `limit` photos captured inside `interval` (end exclusive).
    func newestAssets(in interval: DateInterval, limit: Int) async throws -> PhotoAssetPage
    /// How many photos, geotagged or not, were captured inside `interval`.
    func photoCount(in interval: DateInterval) async throws -> Int
    /// Every camera-named photo, video, and screenshot added to the library when it was
    /// taken, inside `interval`. Empty when file names cannot be read.
    func cameraRoll(in interval: DateInterval) async throws -> [CameraRollEntry]
    /// The camera model written in each photo's file, for the photos whose original is
    /// already on this device. Nothing is downloaded.
    func cameraModels(for identifiers: [String]) async -> [String: String]
}

extension PhotoAssetProviding {
    /// The ledger for photos inside `interval`. It reads some weeks either side, because
    /// a run is recognized by what surrounds it.
    func ownDeviceLedger(around interval: DateInterval) async throws -> OwnDeviceLedger {
        let margin: TimeInterval = 45 * 24 * 60 * 60
        let padded = DateInterval(
            start: interval.start.addingTimeInterval(-margin),
            end: interval.end.addingTimeInterval(margin)
        )
        return OwnDeviceLedger(entries: try await cameraRoll(in: padded))
    }
}

/// In-memory `PhotoAssetProviding` used by `PhotoHistoryImporterTests`.
struct FakePhotoAssetProvider: PhotoAssetProviding {
    var assets: [PhotoAssetDescriptor]
    /// Screenshots and other camera-roll items that are not geotagged photos.
    var otherRollEntries: [CameraRollEntry] = []
    /// Camera model by identifier, for the photos whose file is "on the device".
    var models: [String: String] = [:]

    func cameraRoll(in interval: DateInterval) async throws -> [CameraRollEntry] {
        let photos = assets.compactMap { asset -> CameraRollEntry? in
            guard let addedAt = asset.addedAt, let number = asset.rollNumber else { return nil }
            return CameraRollEntry(addedAt: addedAt, number: number, isScreenshot: false)
        }
        return (photos + otherRollEntries).filter { interval.contains($0.addedAt) }
    }

    func cameraModels(for identifiers: [String]) async -> [String: String] {
        models.filter { identifiers.contains($0.key) }
    }

    func geotaggedAssets(in interval: DateInterval) async throws -> [PhotoAssetDescriptor] {
        assets.filter { asset in
            asset.coordinate != nil
                && asset.capturedAt >= interval.start
                && asset.capturedAt < interval.end
        }
    }

    func newestAssets(in interval: DateInterval, limit: Int) async throws -> PhotoAssetPage {
        let scanned = assets
            .filter { $0.capturedAt >= interval.start && $0.capturedAt < interval.end }
            .sorted { $0.capturedAt < $1.capturedAt }
            .suffix(limit)
        return PhotoAssetPage(
            assets: scanned.filter { $0.coordinate != nil },
            scannedCount: scanned.count,
            earliestScannedAt: scanned.first?.capturedAt
        )
    }

    func photoCount(in interval: DateInterval) async throws -> Int {
        assets.count { $0.capturedAt >= interval.start && $0.capturedAt < interval.end }
    }
}
