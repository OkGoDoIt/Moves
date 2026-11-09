import CoreLocation
import Foundation
import SwiftData

/// Counts shown before a photo-history import starts writing.
struct PhotoHistoryPreview: Sendable, Equatable {
    var geotaggedPhotoCount = 0
    var estimatedVisitCount = 0
    var dayCount = 0

    var summary: String {
        let photos = geotaggedPhotoCount.formatted(.number)
        let visits = estimatedVisitCount.formatted(.number)
        let days = dayCount.formatted(.number)
        return "\(photos) geotagged photos → about \(visits) visits across \(days) days"
    }
}

/// Result of attaching photos and, optionally, creating photo-inferred days.
struct PhotoHistoryImportReport: Sendable, Equatable {
    var geotaggedPhotoCount = 0
    var attachedPhotoCount = 0
    var createdVisitCount = 0
    var reusedVisitCount = 0
    var createdMoveCount = 0
    var sensorDaySkipCount = 0
    var dayOnlyAttachmentCount = 0

    var summary: String {
        var parts: [String] = []
        parts.append("Attached \(attachedPhotoCount.formatted(.number)) photo\(attachedPhotoCount == 1 ? "" : "s")")
        if createdVisitCount > 0 {
            parts.append("added \(createdVisitCount.formatted(.number)) inferred visit\(createdVisitCount == 1 ? "" : "s")")
        }
        if reusedVisitCount > 0 {
            parts.append("matched \(reusedVisitCount.formatted(.number)) existing visit\(reusedVisitCount == 1 ? "" : "s")")
        }
        if sensorDaySkipCount > 0 {
            parts.append("left \(sensorDaySkipCount.formatted(.number)) recorded day\(sensorDaySkipCount == 1 ? "" : "s") unchanged")
        }
        var text = parts.joined(separator: ", ") + "."
        text += " Photos stay on this device."
        return text
    }
}

/// A stay inferred from geotagged photos, carrying the source assets so they
/// can be attached after the visit is created or matched.
struct PhotoHistoryStay: Sendable {
    var assets: [PhotoAssetDescriptor]
    var latitude: Double
    var longitude: Double
    var radius: CLLocationDistance

    var arrivalDate: Date { assets.first?.capturedAt ?? .distantPast }
    var departureDate: Date { assets.last?.capturedAt ?? arrivalDate }
    var duration: TimeInterval { departureDate.timeIntervalSince(arrivalDate) }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var locationLogStay: LocationLogStay {
        LocationLogStay(
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            points: assets.compactMap(\.locationLogPoint)
        )
    }
}

/// Turns geotagged photos into stays, dotted photo-inferred visits, and
/// `PhotoAttachment` rows.
///
/// Clustering reuses `LocationLogSegmenter` (500 m radius) after splitting the
/// stream at 90-minute gaps — the GPS segmenter otherwise treats a long gap at
/// the same spot as one stay. A stay is kept when it has at least two photos
/// or spans 20 minutes. Moves between stays are `.estimated` and `.unknown`
/// unless the implied speed is above 200 km/h (plane).
///
/// Days that already have sensor, imported, or manual timeline items are never
/// rewritten, and neither is a stay inside a recorded visit that began on an earlier
/// day: overlapping photos are attached only.
struct PhotoHistoryImporter {
    struct Configuration: Sendable {
        /// New stay when the gap between consecutive photos exceeds this.
        var stayGap: TimeInterval = 90 * 60
        /// New stay when a photo is farther than this from the cluster centre.
        var stayRadius: CLLocationDistance = 500
        /// Minimum span for a one-photo-or-more cluster to count as a stay.
        var minimumStayDuration: TimeInterval = 20 * 60
        /// Alternative to `minimumStayDuration`: two photos at the same spot.
        var minimumStayPhotoCount = 2
        /// Match an existing visit when the photo is this close.
        var visitMatchRadius: CLLocationDistance = 300
        /// Match an existing visit when the capture time is this close to the stay.
        var visitMatchSlack: TimeInterval = 10 * 60
        /// Implied speed between clusters that is labelled plane.
        var planeSpeedKilometersPerHour: Double = 200
        /// Skip a connecting move when the stays are closer than this.
        var minimumMoveDistance: CLLocationDistance = 80

        init() {}
    }

    /// Photo-tuned `LocationLogSegmenter` settings. Gaps are split *before*
    /// calling the segmenter, so `minimumStayDuration` is zero here and the
    /// two-photo / 20-minute rule is applied as a filter afterwards.
    static var photoSegmenterConfiguration: LocationLogSegmenter.Configuration {
        var configuration = LocationLogSegmenter.Configuration()
        configuration.stayRadius = 500
        configuration.minimumStayDuration = 0
        configuration.jitterReturnInterval = 0
        configuration.minimumMoveDistance = 0
        configuration.stayMergeDistance = 40
        configuration.maximumHorizontalAccuracy = 10_000
        return configuration
    }

    var configuration: Configuration
    private let modelContext: ModelContext
    private let repository: SwiftDataTimelineRepository
    private let calendar: Calendar

    init(
        modelContext: ModelContext,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current
    ) {
        self.modelContext = modelContext
        self.repository = SwiftDataTimelineRepository(modelContext: modelContext)
        self.configuration = configuration
        self.calendar = calendar
    }

    // MARK: - Preview / segment (pure)

    /// Counts geotagged photos, inferred stays, and distinct days without writing.
    static func preview(
        assets: [PhotoAssetDescriptor],
        in interval: DateInterval,
        configuration: Configuration = Configuration()
    ) -> PhotoHistoryPreview {
        let filtered = Self.geotagged(assets, in: interval)
        let stays = clusterStays(filtered, configuration: configuration)
        let days = Set(stays.map { DayTimeline.makeDayKey(for: $0.arrivalDate) })
        return PhotoHistoryPreview(
            geotaggedPhotoCount: filtered.count,
            estimatedVisitCount: stays.count,
            dayCount: days.count
        )
    }

    /// Groups geotagged photos into stays using photo thresholds.
    static func clusterStays(
        _ assets: [PhotoAssetDescriptor],
        configuration: Configuration = Configuration()
    ) -> [PhotoHistoryStay] {
        let geotagged = assets
            .filter { $0.locationLogPoint != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        var stays: [PhotoHistoryStay] = []
        let segmenter = LocationLogSegmenter(configuration: photoSegmenterConfiguration)

        for window in splitByGap(geotagged, maximumGap: configuration.stayGap) {
            let points = window.compactMap(\.locationLogPoint)
            let timeline = segmenter.segment(points)
            for stay in timeline.stays {
                let stayAssets = window.filter { asset in
                    stay.points.contains { point in
                        abs(point.timestamp.timeIntervalSince(asset.capturedAt)) < 0.75
                    }
                }
                let qualifyingCount = stayAssets.count >= configuration.minimumStayPhotoCount
                let qualifyingDuration = stay.duration >= configuration.minimumStayDuration
                guard qualifyingCount || qualifyingDuration, !stayAssets.isEmpty else {
                    continue
                }
                stays.append(
                    PhotoHistoryStay(
                        assets: stayAssets,
                        latitude: stay.latitude,
                        longitude: stay.longitude,
                        radius: stay.radius
                    )
                )
            }
        }

        return stays
    }

    /// Ordered stays and connecting moves (plane or unknown) for a photo set.
    static func segment(
        _ assets: [PhotoAssetDescriptor],
        configuration: Configuration = Configuration()
    ) -> LocationLogTimeline {
        let stays = clusterStays(assets, configuration: configuration)
        var segments: [LocationLogSegment] = []
        var pointCount = 0

        for (index, stay) in stays.enumerated() {
            if index > 0, let move = makeMove(
                from: stays[index - 1],
                to: stay,
                configuration: configuration
            ) {
                segments.append(.move(move))
                pointCount += move.points.count
            }
            segments.append(.stay(stay.locationLogStay))
            pointCount += stay.assets.count
        }

        return LocationLogTimeline(segments: segments, pointCount: pointCount)
    }

    // MARK: - Persistence

    /// Creates photo-inferred visits on empty days and attaches photos everywhere.
    ///
    /// Re-running with the same assets is idempotent: existing `PhotoAttachment`
    /// identifiers are reused, and sensor days only receive attachments.
    @discardableResult
    func importHistory(
        assets: [PhotoAssetDescriptor],
        in interval: DateInterval,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> PhotoHistoryImportReport {
        let filtered = Self.geotagged(assets, in: interval)
        var report = PhotoHistoryImportReport(geotaggedPhotoCount: filtered.count)
        guard !filtered.isEmpty else {
            progress?(1, "Done")
            return report
        }

        progress?(0.05, "Grouping photos…")
        let stays = Self.clusterStays(filtered, configuration: configuration)
        var attachedIDs = try existingAttachmentIdentifiers()
        var usedAssetIDs = Set<String>()
        var stayVisits: [VisitPlace?] = []
        stayVisits.reserveCapacity(stays.count)
        let total = Double(max(stays.count, 1))

        for (index, stay) in stays.enumerated() {
            progress?(0.08 + 0.75 * Double(index) / total, "Rebuilding timeline…")
            let (visit, created, skippedSensorDay) = try persistStay(stay)
            stayVisits.append(visit)
            if skippedSensorDay {
                report.sensorDaySkipCount += 1
            }
            if created {
                report.createdVisitCount += 1
            } else if visit != nil {
                report.reusedVisitCount += 1
            }
            for asset in stay.assets {
                let attached = try attach(
                    asset,
                    to: visit,
                    day: try timeline(for: asset.capturedAt),
                    attachedIDs: &attachedIDs
                )
                if attached {
                    report.attachedPhotoCount += 1
                    if visit == nil {
                        report.dayOnlyAttachmentCount += 1
                    }
                }
                usedAssetIDs.insert(asset.localIdentifier)
            }
        }

        progress?(0.88, "Connecting visits…")
        for index in stayVisits.indices.dropFirst() {
            guard let start = stayVisits[index - 1], let end = stayVisits[index] else {
                continue
            }
            if try insertMoveIfNeeded(from: start, to: end, stay: stays[index - 1], next: stays[index]) {
                report.createdMoveCount += 1
            }
        }

        progress?(0.94, "Attaching remaining photos…")
        for asset in filtered where !usedAssetIDs.contains(asset.localIdentifier) {
            let visit = try matchingVisit(for: asset)
            let attached = try attach(
                asset,
                to: visit,
                day: try timeline(for: asset.capturedAt),
                attachedIDs: &attachedIDs
            )
            if attached {
                report.attachedPhotoCount += 1
                if visit == nil {
                    report.dayOnlyAttachmentCount += 1
                }
            }
        }

        progress?(0.99, "Saving…")
        try repository.saveIfNeeded()
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        NotificationCenter.default.post(name: .movesPhotoLibraryDidChange, object: nil)
        RouteMatchBackgroundTask.scheduleAfterImport()
        progress?(1, "Done")
        return report
    }

    /// Attaches newly seen geotagged photos to matching visits or to the day.
    @discardableResult
    func attachPhotos(
        _ assets: [PhotoAssetDescriptor],
        attachedIDs: Set<String>? = nil
    ) throws -> Int {
        var known = try attachedIDs ?? existingAttachmentIdentifiers()
        var attached = 0
        for asset in assets where asset.coordinate != nil {
            let visit = try matchingVisit(for: asset)
            if try attach(
                asset,
                to: visit,
                day: try timeline(for: asset.capturedAt),
                attachedIDs: &known
            ) {
                attached += 1
            }
        }
        if attached > 0 {
            try repository.saveIfNeeded()
            NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
            NotificationCenter.default.post(name: .movesPhotoLibraryDidChange, object: nil)
        }
        return attached
    }

    // MARK: - Clustering helpers

    static func geotagged(
        _ assets: [PhotoAssetDescriptor],
        in interval: DateInterval
    ) -> [PhotoAssetDescriptor] {
        assets.filter { asset in
            asset.coordinate != nil
                && asset.capturedAt >= interval.start
                && asset.capturedAt < interval.end
        }
        .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Splits a time-ordered photo list whenever the gap exceeds `maximumGap`.
    static func splitByGap(
        _ assets: [PhotoAssetDescriptor],
        maximumGap: TimeInterval
    ) -> [[PhotoAssetDescriptor]] {
        guard let first = assets.first else { return [] }
        var windows: [[PhotoAssetDescriptor]] = [[first]]
        for asset in assets.dropFirst() {
            let previous = windows[windows.count - 1].last!
            if asset.capturedAt.timeIntervalSince(previous.capturedAt) > maximumGap {
                windows.append([asset])
            } else {
                windows[windows.count - 1].append(asset)
            }
        }
        return windows
    }

    static func makeMove(
        from start: PhotoHistoryStay,
        to end: PhotoHistoryStay,
        configuration: Configuration
    ) -> LocationLogMove? {
        guard let startPoint = start.assets.last?.locationLogPoint,
              let endPoint = end.assets.first?.locationLogPoint
        else {
            return nil
        }
        let distance = startPoint.distance(to: endPoint)
        guard distance >= configuration.minimumMoveDistance else { return nil }
        let points = [startPoint, endPoint]
        return LocationLogMove(
            points: points,
            transportMode: transportMode(from: start, to: end, configuration: configuration),
            distanceMeters: distance,
            longestGap: end.arrivalDate.timeIntervalSince(start.departureDate)
        )
    }

    static func transportMode(
        from start: PhotoHistoryStay,
        to end: PhotoHistoryStay,
        configuration: Configuration
    ) -> TransportMode {
        let distance = LocationLogGeometry.distance(from: start.coordinate, to: end.coordinate)
        let duration = end.arrivalDate.timeIntervalSince(start.departureDate)
        guard duration > 0 else { return .unknown }
        let kilometersPerHour = (distance / 1_000) / (duration / 3_600)
        return AutomaticTransportModes.load().allowedMode(
            kilometersPerHour > configuration.planeSpeedKilometersPerHour ? .plane : .unknown
        )
    }

    // MARK: - Write path

    private func persistStay(
        _ stay: PhotoHistoryStay
    ) throws -> (visit: VisitPlace?, created: Bool, skippedSensorDay: Bool) {
        let day = try timeline(for: stay.arrivalDate)
        let overlapping = try visitsOverlapping(stay)
        let match = matchingVisit(for: stay, among: overlapping)
        if day.isProtectedFromPhotoBackfill || overlapping.contains(where: { $0.origin != .photoInferred }) {
            return (match, false, true)
        }

        if let existing = match {
            if existing.origin == .photoInferred {
                extendPhotoInferredVisit(existing, with: stay)
            }
            return (existing, false, false)
        }

        let visit = VisitPlace(
            arrivalDate: stay.arrivalDate,
            departureDate: stay.departureDate,
            latitude: stay.latitude,
            longitude: stay.longitude,
            horizontalAccuracy: min(max(stay.radius, 20), 150)
        )
        visit.origin = .photoInferred
        visit.dayTimeline = day
        modelContext.insert(visit)
        try insertSamples(for: stay)
        try repository.applyPlaceLearning(to: visit)
        return (visit, true, false)
    }

    private func extendPhotoInferredVisit(_ visit: VisitPlace, with stay: PhotoHistoryStay) {
        if stay.arrivalDate < visit.arrivalDate {
            visit.arrivalDate = stay.arrivalDate
        }
        let stayEnd = stay.departureDate
        if let departure = visit.departureDate {
            if stayEnd > departure {
                visit.departureDate = stayEnd
            }
        } else {
            visit.departureDate = stayEnd
        }
    }

    private func insertMoveIfNeeded(
        from start: VisitPlace,
        to end: VisitPlace,
        stay: PhotoHistoryStay,
        next: PhotoHistoryStay
    ) throws -> Bool {
        guard start.origin == .photoInferred, end.origin == .photoInferred else {
            return false
        }
        guard start.dayTimeline?.isProtectedFromPhotoBackfill != true,
              end.dayTimeline?.isProtectedFromPhotoBackfill != true
        else {
            return false
        }
        guard let logMove = Self.makeMove(from: stay, to: next, configuration: configuration) else {
            return false
        }
        if start.outgoingMoves.contains(where: { move in
            move.endPlace?.id == end.id && move.origin == .photoInferred
        }) {
            return false
        }

        let samples = try repository.appendSamples(
            from: logMove.points.map(\.location),
            source: .photoLibrary
        )
        let move = MoveSegment(
            dedupeKey: "photo-\(start.id.uuidString)-\(end.id.uuidString)-\(Int(logMove.startDate.timeIntervalSince1970))",
            startDate: logMove.startDate,
            endDate: logMove.endDate,
            transportMode: logMove.transportMode,
            distanceMeters: logMove.distanceMeters,
            stepCount: nil
        )
        move.origin = .photoInferred
        move.routeMatchConfidence = .estimated
        move.routeMatchPolicy = .auto
        move.transportModeSource = .auto
        move.routeMatchSummary = String(localized: "Inferred from photos")
        move.startPlace = start
        move.endPlace = end
        move.dayTimeline = start.dayTimeline ?? end.dayTimeline
        for sample in samples {
            sample.moveSegment = move
        }
        modelContext.insert(move)
        return true
    }

    @discardableResult
    private func attach(
        _ asset: PhotoAssetDescriptor,
        to visit: VisitPlace?,
        day: DayTimeline,
        attachedIDs: inout Set<String>
    ) throws -> Bool {
        guard !attachedIDs.contains(asset.localIdentifier) else { return false }
        if try attachment(for: asset.localIdentifier) != nil {
            attachedIDs.insert(asset.localIdentifier)
            return false
        }

        let attachment = PhotoAttachment(
            assetLocalIdentifier: asset.localIdentifier,
            capturedAt: asset.capturedAt,
            latitude: asset.latitude,
            longitude: asset.longitude
        )
        attachment.visitPlace = visit
        attachment.dayTimeline = visit?.dayTimeline ?? day
        modelContext.insert(attachment)
        attachedIDs.insert(asset.localIdentifier)
        return true
    }

    private func insertSamples(for stay: PhotoHistoryStay) throws {
        let locations = stay.assets.compactMap(\.locationLogPoint).map(\.location)
        _ = try repository.appendSamples(from: locations, source: .photoLibrary)
    }

    /// Visits whose time range touches the stay, whichever day they are filed under: a
    /// hotel visit from Monday covers Tuesday's photos though Tuesday has no rows.
    private func visitsOverlapping(_ stay: PhotoHistoryStay) throws -> [VisitPlace] {
        let slack = configuration.visitMatchSlack
        let windowStart = stay.arrivalDate.addingTimeInterval(-8 * 24 * 60 * 60)
        let windowEnd = stay.departureDate.addingTimeInterval(slack)
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            }
        )
        return try modelContext.fetch(descriptor).filter { place in
            Self.timeRangesOverlap(
                startA: stay.arrivalDate.addingTimeInterval(-slack),
                endA: windowEnd,
                startB: place.arrivalDate,
                endB: place.departureDate ?? place.outgoingMoves.map(\.startDate).min() ?? .distantFuture
            )
        }
    }

    private func matchingVisit(for stay: PhotoHistoryStay, among visits: [VisitPlace]) -> VisitPlace? {
        let radius = max(configuration.visitMatchRadius, stay.radius)
        return visits
            .filter { place in
                LocationLogGeometry.distance(from: stay.coordinate, to: place.coordinate) <= radius
            }
            .min { lhs, rhs in
                LocationLogGeometry.distance(from: stay.coordinate, to: lhs.coordinate)
                    < LocationLogGeometry.distance(from: stay.coordinate, to: rhs.coordinate)
            }
    }

    private func matchingVisit(for asset: PhotoAssetDescriptor) throws -> VisitPlace? {
        guard let coordinate = asset.coordinate else { return nil }
        let slack = configuration.visitMatchSlack
        let windowStart = asset.capturedAt.addingTimeInterval(-8 * 24 * 60 * 60)
        let windowEnd = asset.capturedAt.addingTimeInterval(slack)
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            }
        )
        let nearby = try modelContext.fetch(descriptor)
        return nearby
            .filter { place in
                Self.visit(place, matches: asset.capturedAt, coordinate: coordinate, slack: slack, radius: configuration.visitMatchRadius)
            }
            .min { lhs, rhs in
                LocationLogGeometry.distance(from: coordinate, to: lhs.coordinate)
                    < LocationLogGeometry.distance(from: coordinate, to: rhs.coordinate)
            }
    }

    private static func visit(
        _ place: VisitPlace,
        matches date: Date,
        coordinate: CLLocationCoordinate2D,
        slack: TimeInterval,
        radius: CLLocationDistance
    ) -> Bool {
        let start = place.arrivalDate.addingTimeInterval(-slack)
        let end = (place.departureDate ?? .distantFuture).addingTimeInterval(slack)
        guard date >= start, date <= end else { return false }
        return LocationLogGeometry.distance(from: place.coordinate, to: coordinate) <= radius
    }

    private static func timeRangesOverlap(
        startA: Date,
        endA: Date,
        startB: Date,
        endB: Date
    ) -> Bool {
        min(endA, endB) >= max(startA, startB)
    }

    private func existingAttachmentIdentifiers() throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<PhotoAttachment>())
        return Set(rows.map(\.assetLocalIdentifier))
    }

    private func attachment(for identifier: String) throws -> PhotoAttachment? {
        var descriptor = FetchDescriptor<PhotoAttachment>(
            predicate: #Predicate { $0.assetLocalIdentifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func timeline(for date: Date) throws -> DayTimeline {
        let dayKey = DayTimeline.makeDayKey(for: date)
        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { timeline in
                timeline.dayKey == dayKey
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        let timeline = DayTimeline(dayStart: date)
        modelContext.insert(timeline)
        return timeline
    }
}

extension DayTimeline {
    /// GPS, import, or manual items already occupy this day — photo backfill
    /// may attach thumbnails but must not add inferred visits or moves.
    var isProtectedFromPhotoBackfill: Bool {
        places.contains { $0.origin != .photoInferred }
            || moves.contains { $0.origin != .photoInferred }
            || samples.contains { $0.source != .photoLibrary }
    }
}

/// Date-range lens over `PhotoAttachment` rows.
///
/// Named trips (WS9b) do not copy photos; they call this (or the matching
/// `TripRangeStats.photos` helper after merge) with the trip interval so
/// visit attachments in range appear on trip detail.
enum PhotoAttachmentQuery {
    /// Photos whose capture time falls in `range` (end exclusive), oldest first.
    static func photos(in range: DateInterval, context: ModelContext) throws -> [PhotoAttachment] {
        let start = range.start
        let end = range.end
        let descriptor = FetchDescriptor<PhotoAttachment>(
            predicate: #Predicate { photo in
                photo.capturedAt >= start && photo.capturedAt < end
            },
            sortBy: [SortDescriptor(\PhotoAttachment.capturedAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// First geotagged attachment, otherwise the earliest in the list.
    static func coverPhoto(from photos: [PhotoAttachment]) -> PhotoAttachment? {
        photos.first { $0.latitude != nil && $0.longitude != nil } ?? photos.first
    }
}

extension Notification.Name {
    /// Posted after photo attachments or photo-inferred visits change.
    static let movesPhotoLibraryDidChange = Notification.Name("Moves.photoLibraryDidChange")
}
