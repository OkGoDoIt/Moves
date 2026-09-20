import CoreLocation
import Foundation

/// UserDefaults keys for the Settings → Photos card.
enum PhotoLibrarySettings {
    /// When true, storyline place rows show inline thumbnails.
    static let showOnVisitsKey = "photos.showOnVisits"
    /// Last time new library photos were attached to today's visits.
    static let lastAttachPassAtKey = "photos.lastAttachPassAt"

    static var showsPhotosOnVisits: Bool {
        get { UserDefaults.standard.object(forKey: showOnVisitsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showOnVisitsKey) }
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

    init(
        localIdentifier: String,
        capturedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
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
            horizontalAccuracy: 25,
            timestamp: capturedAt
        )
    }
}

/// Supplies geotagged photos for attachment and history backfill.
///
/// Production uses PhotoKit; tests inject an in-memory fake so they never
/// depend on the simulator photo library.
protocol PhotoAssetProviding: Sendable {
    /// Geotagged still images whose capture time falls inside `interval` (end exclusive).
    func geotaggedAssets(in interval: DateInterval) async throws -> [PhotoAssetDescriptor]
}

/// In-memory `PhotoAssetProviding` used by `PhotoHistoryImporterTests`.
struct FakePhotoAssetProvider: PhotoAssetProviding {
    var assets: [PhotoAssetDescriptor]

    func geotaggedAssets(in interval: DateInterval) async throws -> [PhotoAssetDescriptor] {
        assets.filter { asset in
            asset.coordinate != nil
                && asset.capturedAt >= interval.start
                && asset.capturedAt < interval.end
        }
    }
}
