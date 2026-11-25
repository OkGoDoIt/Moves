import CoreLocation
import Foundation
import SwiftData

/// A fix the phone recorded itself, which a photo's location is checked against.
struct RecordedFix: Sendable, Equatable {
    var date: Date
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Whether a camera photo's location may join the timeline as a fix.
///
/// A photo that reached the library the moment it was taken is almost always the
/// phone's own. "Almost" covers another device on the same iCloud account and a shared
/// library, so the photo is also checked against where the phone says it was.
enum PhotoFixPlausibility {
    enum Verdict: Equatable {
        case accept
        case reject
        /// Not reachable from the last fix, but nothing newer has been recorded yet.
        /// A landing looks like this until the phone reports from the new place.
        case wait
    }

    /// A photo this close to a recorded fix agrees with it.
    static let nearbyDistance: CLLocationDistance = 1_500
    /// How far either side of a photo a recorded fix still says something about it.
    static let neighborWindow: TimeInterval = 24 * 60 * 60
    /// Faster than a train; anything quicker has to show in the phone's own fixes.
    static let groundSpeed: Double = 60
    static let airSpeed: Double = 300
    /// Fixes at one place this close together in time mean the phone stayed there.
    static let stayedPutSpan: TimeInterval = 2 * 60 * 60
    static let stayedPutDistance: CLLocationDistance = 500

    /// - Parameter fixes: The phone's own fixes, oldest first, without photo fixes.
    static func verdict(for photo: PhotoAssetDescriptor, fixes: [RecordedFix]) -> Verdict {
        guard let coordinate = photo.coordinate else { return .reject }
        let time = photo.capturedAt
        let before = fixes.last { $0.date <= time && time.timeIntervalSince($0.date) <= neighborWindow }
        let after = fixes.first { $0.date > time && $0.date.timeIntervalSince(time) <= neighborWindow }

        func distance(to fix: RecordedFix) -> CLLocationDistance {
            LocationLogGeometry.distance(from: coordinate, to: fix.coordinate)
        }
        func isNear(_ fix: RecordedFix) -> Bool {
            distance(to: fix) <= nearbyDistance + (photo.horizontalAccuracy ?? 0)
        }
        func isReachable(from fix: RecordedFix, at speed: Double) -> Bool {
            distance(to: fix) <= nearbyDistance + speed * abs(time.timeIntervalSince(fix.date))
        }

        switch (before, after) {
        case (nil, nil):
            return .accept
        case let (before?, nil):
            if isReachable(from: before, at: groundSpeed) { return .accept }
            return .wait
        case let (nil, after?):
            return isReachable(from: after, at: airSpeed) ? .accept : .reject
        case let (before?, after?):
            let ownDistance = LocationLogGeometry.distance(from: before.coordinate, to: after.coordinate)
            let ownSpan = after.date.timeIntervalSince(before.date)
            if ownDistance <= stayedPutDistance, ownSpan <= stayedPutSpan, !isNear(before), !isNear(after) {
                return .reject
            }
            // A flight shows up as the phone's own fixes being far apart, and only then
            // is a photo allowed to be that far from them.
            let ownSpeed = ownSpan > 0 ? ownDistance / ownSpan : 0
            let speed = min(airSpeed, max(groundSpeed, ownSpeed * 1.5))
            return isReachable(from: before, at: speed) && isReachable(from: after, at: speed) ? .accept : .reject
        }
    }
}

/// What the Photos card says about photos used as fixes lately.
struct PhotoFixStatus: Equatable, Sendable {
    /// When the library was last looked at for new photos.
    var lastCheckedAt: Date?
    /// Photos used as fixes in the last week.
    var recentFixCount = 0
    /// Capture time of the newest of them.
    var latestFixAt: Date?

    /// - Parameter used: Capture time of each photo used as a fix, by identifier.
    init(lastCheckedAt: Date? = nil, used: [String: Date] = [:]) {
        self.lastCheckedAt = lastCheckedAt
        recentFixCount = used.count
        latestFixAt = used.values.max()
    }
}

/// Picks the recent camera photos that become timeline fixes, and remembers which
/// were already offered so a photo is weighed once.
struct PhotoFixSelection {
    /// A photo older than the window the timeline still rebuilds belongs to history.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// A fix vaguer than this says which neighborhood, not which place.
    static let maximumAccuracy: Double = 200

    var accepted: [PhotoAssetDescriptor] = []
    /// Capture time by photo identifier, for every photo that needs no second look.
    var handled: [String: Date]

    init(
        photos: [PhotoAssetDescriptor],
        fixes: [RecordedFix],
        handled: [String: Date],
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        self.handled = handled.filter { $0.value >= cutoff }
        for photo in photos.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            guard photo.isCameraCapture,
                  photo.coordinate != nil,
                  photo.capturedAt >= cutoff,
                  photo.capturedAt <= now.addingTimeInterval(60),
                  self.handled[photo.localIdentifier] == nil
            else { continue }

            if let accuracy = photo.horizontalAccuracy, accuracy > Self.maximumAccuracy {
                self.handled[photo.localIdentifier] = photo.capturedAt
                continue
            }
            switch PhotoFixPlausibility.verdict(for: photo, fixes: fixes) {
            case .accept:
                accepted.append(photo)
                self.handled[photo.localIdentifier] = photo.capturedAt
            case .reject:
                self.handled[photo.localIdentifier] = photo.capturedAt
            case .wait:
                break
            }
        }
    }

    /// The phone's own fixes around `interval`, copied out of the store.
    static func recordedFixes(around interval: DateInterval, in container: ModelContainer) throws -> [RecordedFix] {
        let context = ModelContext(container)
        let start = interval.start.addingTimeInterval(-PhotoFixPlausibility.neighborWindow)
        let end = interval.end.addingTimeInterval(PhotoFixPlausibility.neighborWindow)
        let library = LocationSampleSource.photoLibrary.rawValue
        let camera = LocationSampleSource.cameraPhoto.rawValue
        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.timestamp >= start && sample.timestamp <= end
                    && sample.sourceRawValue != library && sample.sourceRawValue != camera
            },
            sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.timestamp, \.latitude, \.longitude]
        return try context.fetch(descriptor).map {
            RecordedFix(date: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}
