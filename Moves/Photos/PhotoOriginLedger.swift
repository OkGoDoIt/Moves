import CoreLocation
import Foundation

/// How a library photo came to be there, as far as can be told.
enum PhotoOrigin: String, Codable, Sendable {
    /// Taken with the owner's phone and in the library since that moment.
    case camera
    /// Taken with the owner's phone and added later, by a backup or a move between libraries.
    case archive
    /// Part of a large backup, from a time with nothing else to check it against.
    case presumed
    /// Another copy of a photo the owner's phone took.
    case duplicate
    /// Taken by a phone that is not the owner's.
    case otherDevice
    /// Saved, sent by someone, or of unknown origin.
    case received

    /// Says where the owner was.
    var isOwn: Bool {
        switch self {
        case .camera, .archive, .presumed: true
        case .duplicate, .otherDevice, .received: false
        }
    }

    /// How far a photo of this origin is believed when two disagree.
    var trust: Int {
        switch self {
        case .camera: 3
        case .archive: 2
        case .presumed: 1
        case .duplicate, .otherDevice, .received: 0
        }
    }
}

/// One library item, with what PhotoKit keeps about it without opening the file.
struct LibraryRollEntry: Sendable, Equatable {
    var capturedAt: Date
    var addedAt: Date
    /// The counter in a camera file name, with or without a backup's suffix.
    var number: Int?
    var isScreenshot: Bool
    var place: PhotoPlace?

    var wasAddedWhenTaken: Bool {
        PhotoCaptureClassifier.isCameraCapture(capturedAt: capturedAt, addedAt: addedAt)
    }
}

/// Decides for every photo in the library whether it says where the owner was.
///
/// A photo added the moment it was taken is judged by the owner's camera counter
/// (`OwnDeviceLedger`). A photo added later came from a backup, a computer, or another
/// person. Those keep the number the camera gave them, so they are put on one counter with
/// everything else, ordered by when they were taken: the owner's older phones count
/// straight on from each other and carry the owner's screenshots, and a partner's or a
/// friend's photos run alongside on other counters.
///
/// Photos from before the owner's counter begins have nothing to be compared with. They
/// count when they came in a large backup covering months, which is somebody moving their
/// own library, and not when they arrived a few at a time.
struct PhotoOriginLedger: Sendable, Codable {
    /// Items added in a day, over a span of capture dates, that make it a backup.
    static let backupMinimumItems = 200
    static let backupMinimumSpan: TimeInterval = 180 * 24 * 60 * 60
    /// Within this many days of the owner's own photos, an unrecognized one is someone else's.
    static let activityReach = 7
    /// A copy can be shifted by a time zone, never by more than this.
    static let duplicateReach: TimeInterval = 14 * 60 * 60 + 60

    /// Judges photos added when they were taken.
    let camera: OwnDeviceLedger
    /// Judges photos added later, by capture time.
    let archive: OwnDeviceLedger
    /// When each counter value was used by a photo added as it was taken, in order.
    private let liveTimes: [Int: [TimeInterval]]
    /// Days on which the owner's own phone took something.
    private let activeDays: Set<Int>
    /// Days on which a backup was added.
    private let backupDays: Set<Int>

    /// File names could be read and the owner's phone was recognized by them.
    var recognizesDevices: Bool { camera.ownItemCount > 0 }

    init(entries: [LibraryRollEntry]) {
        var cameraRoll: [CameraRollEntry] = []
        var liveTimes: [Int: [TimeInterval]] = [:]
        var liveDays = Set<Int>()
        var added: [Int: (count: Int, first: TimeInterval, last: TimeInterval)] = [:]
        for entry in entries {
            if entry.wasAddedWhenTaken {
                liveDays.insert(Self.day(entry.capturedAt))
                guard let number = entry.number else { continue }
                cameraRoll.append(
                    CameraRollEntry(addedAt: entry.addedAt, number: number, isScreenshot: entry.isScreenshot)
                )
                liveTimes[number, default: []].append(entry.capturedAt.timeIntervalSinceReferenceDate)
            } else {
                let time = entry.capturedAt.timeIntervalSinceReferenceDate
                var day = added[Self.day(entry.addedAt)] ?? (0, time, time)
                day.count += 1
                day.first = min(day.first, time)
                day.last = max(day.last, time)
                added[Self.day(entry.addedAt)] = day
            }
        }
        for number in liveTimes.keys {
            liveTimes[number]?.sort()
        }
        self.liveTimes = liveTimes
        backupDays = Set(
            added.filter { $0.value.count >= Self.backupMinimumItems && $0.value.last - $0.value.first >= Self.backupMinimumSpan }
                .keys
        )

        let camera = OwnDeviceLedger(entries: cameraRoll)
        self.camera = camera

        // Copies of one photo share a second and a number; one entry stands for them all.
        var seen = Set<SlotKey>()
        var everything: [CameraRollEntry] = []
        for entry in entries {
            guard let number = entry.number else { continue }
            if !entry.wasAddedWhenTaken, Self.isNear(liveTimes[number], entry.capturedAt) { continue }
            let second = Self.second(entry.capturedAt)
            guard seen.insert(SlotKey(second: second, number: number)).inserted else { continue }
            everything.append(
                CameraRollEntry(addedAt: second, number: number, isScreenshot: entry.isScreenshot, place: entry.place)
            )
        }
        let archive = OwnDeviceLedger(entries: everything, configuration: .archive)
        self.archive = archive

        if camera.ownItemCount > 0 || archive.ownItemCount > 0 {
            var days = Set<Int>()
            for entry in entries {
                guard let number = entry.number else { continue }
                let second = Self.second(entry.capturedAt)
                let isOwn = entry.wasAddedWhenTaken
                    ? camera.contains(addedAt: entry.addedAt, number: number)
                    : archive.contains(addedAt: second, number: number)
                if isOwn, !archive.isContested(addedAt: second, number: number) {
                    days.insert(Self.day(entry.capturedAt))
                }
            }
            activeDays = days
        } else {
            activeDays = liveDays
        }
    }

    func origin(capturedAt: Date, addedAt: Date?, number: Int?) -> PhotoOrigin {
        guard let addedAt else { return .received }
        if PhotoCaptureClassifier.isCameraCapture(capturedAt: capturedAt, addedAt: addedAt) {
            // Without names, or screenshots to know the owner's phone by, a photo added
            // when it was taken keeps counting as the owner's.
            guard recognizesDevices else { return .camera }
            guard let number else { return .received }
            let isOwn = camera.contains(addedAt: addedAt, number: number)
                && !archive.isContested(addedAt: Self.second(capturedAt), number: number)
            return isOwn ? .camera : .otherDevice
        }
        if let number {
            if Self.isNear(liveTimes[number], capturedAt) { return .duplicate }
            if archive.contains(addedAt: Self.second(capturedAt), number: number) { return .archive }
        }
        if isActive(around: capturedAt) {
            return number == nil ? .received : .otherDevice
        }
        return isBackup(addedAt) ? .presumed : .received
    }

    private func isActive(around date: Date) -> Bool {
        let day = Self.day(date)
        return (day - Self.activityReach...day + Self.activityReach).contains { activeDays.contains($0) }
    }

    /// A backup runs past midnight, and its tail is a small day of its own.
    private func isBackup(_ addedAt: Date) -> Bool {
        let day = Self.day(addedAt)
        return (day - 1...day + 1).contains { backupDays.contains($0) }
    }

    private static func isNear(_ times: [TimeInterval]?, _ date: Date) -> Bool {
        guard let times else { return false }
        let time = date.timeIntervalSinceReferenceDate
        let next = times.partitioningIndex { $0 > time - duplicateReach }
        return next < times.count && times[next] < time + duplicateReach
    }

    private static func day(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    private static func second(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private struct SlotKey: Hashable {
        var second: Date
        var number: Int
    }
}

/// Leaves out photos that say the owner was somewhere they could not have been.
///
/// The counter lets a few strays through, a backup can hold a photo with a wrong place or
/// time, and a phone that has just woken stamps a photo with where it last was. A photo
/// whose own fix is vague is dropped. So is one that could only be true if the owner had
/// outrun a car, or over a longer time an airliner, between it and a more trusted photo,
/// and one that disagrees in that way with both its neighbors.
enum PhotoTrailFilter {
    /// A vaguer fix names a neighborhood, and is the one most often out of date.
    static let maximumAccuracy: CLLocationDistance = 100
    static let roadSpeed: Double = 40
    /// Faster than an airliner, so a real flight is never the reason.
    static let airSpeed: Double = 280
    /// Nobody boards, flies, and lands within this time.
    static let shortestFlight: TimeInterval = 30 * 60
    /// A photo says nothing about a trusted one from further away in time than this.
    static let reach: TimeInterval = 6 * 60 * 60

    /// `photos` without the vague and the impossible ones, in the order given, oldest first.
    static func possible(_ photos: [PhotoAssetDescriptor]) -> [PhotoAssetDescriptor] {
        var dropped = Set(
            photos.filter { ($0.horizontalAccuracy ?? 0) > maximumAccuracy }.map(\.localIdentifier)
        )
        for trust in [PhotoOrigin.camera.trust, PhotoOrigin.archive.trust, PhotoOrigin.presumed.trust] {
            let trusted = photos.filter { $0.origin.trust > trust && !dropped.contains($0.localIdentifier) }
            for photo in photos where photo.origin.trust == trust {
                let next = trusted.partitioningIndex { $0.capturedAt >= photo.capturedAt }
                for index in [next - 1, next] where trusted.indices.contains(index) {
                    let other = trusted[index]
                    if abs(other.capturedAt.timeIntervalSince(photo.capturedAt)) <= reach, conflict(photo, other) {
                        dropped.insert(photo.localIdentifier)
                    }
                }
            }

            var peers = photos.filter { $0.origin.trust == trust && !dropped.contains($0.localIdentifier) }
            for _ in 0..<3 where peers.count > 2 {
                let outliers = Set(
                    peers.indices.dropFirst().dropLast()
                        .filter { conflict(peers[$0 - 1], peers[$0]) && conflict(peers[$0], peers[$0 + 1]) }
                        .map { peers[$0].localIdentifier }
                )
                if outliers.isEmpty { break }
                dropped.formUnion(outliers)
                peers.removeAll { outliers.contains($0.localIdentifier) }
            }
        }
        return photos.filter { !dropped.contains($0.localIdentifier) }
    }

    private static func conflict(_ first: PhotoAssetDescriptor, _ second: PhotoAssetDescriptor) -> Bool {
        guard let place = first.place, let other = second.place else { return false }
        let seconds = abs(second.capturedAt.timeIntervalSince(first.capturedAt))
        return place.conflicts(
            with: other,
            seconds: seconds,
            speed: seconds < shortestFlight ? roadSpeed : airSpeed,
            slack: 1_000
        )
    }
}

/// Keeps the ledger while an import is under way, so carrying on after Moves was closed
/// does not read the whole library again. A cache: losing it costs only that reading.
struct PhotoOriginLedgerCache: Sendable {
    var directory: URL

    static var standard: PhotoOriginLedgerCache {
        PhotoOriginLedgerCache(
            directory: URL.cachesDirectory.appending(path: "PhotoHistory", directoryHint: .isDirectory)
        )
    }

    private struct Contents: Codable {
        var job: UUID
        var ledger: PhotoOriginLedger
    }

    /// Names the rules the ledger was made by; a new set of rules starts over.
    private var file: URL { directory.appending(path: "origins-1.json") }

    func load(for job: UUID) -> PhotoOriginLedger? {
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.job == job
        else { return nil }
        return contents.ledger
    }

    func save(_ ledger: PhotoOriginLedger, for job: UUID) {
        guard let data = try? JSONEncoder().encode(Contents(job: job, ledger: ledger)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable while the phone is locked, which is when much of an import runs.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
