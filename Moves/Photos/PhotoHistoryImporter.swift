import CoreLocation
import Foundation
import SwiftData

/// Result of attaching photos and, optionally, creating photo-inferred days.
struct PhotoHistoryImportReport: Sendable, Equatable, Codable {
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
        return ListFormatter.localizedString(byJoining: parts) + "."
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            geotaggedPhotoCount: lhs.geotaggedPhotoCount + rhs.geotaggedPhotoCount,
            attachedPhotoCount: lhs.attachedPhotoCount + rhs.attachedPhotoCount,
            createdVisitCount: lhs.createdVisitCount + rhs.createdVisitCount,
            reusedVisitCount: lhs.reusedVisitCount + rhs.reusedVisitCount,
            createdMoveCount: lhs.createdMoveCount + rhs.createdMoveCount,
            sensorDaySkipCount: lhs.sensorDaySkipCount + rhs.sensorDaySkipCount,
            dayOnlyAttachmentCount: lhs.dayOnlyAttachmentCount + rhs.dayOnlyAttachmentCount
        )
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

    /// At most `count` of the photos, evenly spread, the first and last among them.
    func spread(_ count: Int) -> [PhotoAssetDescriptor] {
        guard assets.count > count, count > 1 else { return assets }
        return (0..<count).map { assets[$0 * (assets.count - 1) / (count - 1)] }
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
        /// Two stays further apart in time than this are separate outings, not one trip.
        /// After that nothing is known of the time between, and a line across it would be a
        /// trip nobody recorded.
        var maximumMoveGap: TimeInterval = 3 * 60 * 60
        /// A flight is the exception: two photos far apart can only have one between them.
        var maximumFlightGap: TimeInterval = 24 * 60 * 60
        var minimumFlightDistance: CLLocationDistance = 150_000
        /// Faster than any airliner door to door: one of the two photos is wrong.
        var maximumFlightKilometersPerHour: Double = 1_000
        /// Every row costs about 3.5 KB of iCloud bookkeeping on the phone, so a burst of two
        /// hundred photos at one stop is kept as a few spread across it, always with the
        /// first and the last.
        var maximumPhotosPerStay = 8
        var maximumFixesPerStay = 4
        /// A stop the person removed is not rebuilt from photos taken this close to it.
        var removedStopMatchDistance: CLLocationDistance = 200

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

    // MARK: - Segment (pure)

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
                // Points keep the capture time they were made from, so a set finds a stay's
                // photos without comparing every photo with every point.
                let stayTimes = Set(stay.points.map(\.timestamp))
                let stayAssets = window.filter { stayTimes.contains($0.capturedAt) }
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
        progress?(0.05, "Rebuilding timeline…")
        let report = try importStep(Self.geotagged(assets, in: interval))
        Self.announceChanges()
        RouteMatchBackgroundTask.scheduleAfterImport()
        progress?(1, "Done")
        return report
    }

    /// Writes one batch of photos and saves once.
    ///
    /// A long import calls this for one batch after another. Everything a batch needs is
    /// read up front for its own dates, so a batch costs the same in the first year as the
    /// twentieth, and a batch that is interrupted leaves nothing half-written: repeating it
    /// finds the visits and attachments it already made.
    @discardableResult
    func importStep(_ assets: [PhotoAssetDescriptor]) throws -> PhotoHistoryImportReport {
        let geotagged = assets
            .filter { $0.coordinate != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        var report = PhotoHistoryImportReport(geotaggedPhotoCount: geotagged.count)
        guard let first = geotagged.first, let last = geotagged.last else { return report }

        let range = DateInterval(start: first.capturedAt, end: last.capturedAt)
        let stays = Self.clusterStays(geotagged, configuration: configuration)

        try repository.performBulkImportStep(covering: range) {
            var step = try Step(range: range, configuration: configuration, context: modelContext)
            var usedAssetIDs = Set<String>()
            var previous = step.latestPhotoInferredVisit(before: stays.first?.arrivalDate ?? range.start)

            for stay in stays {
                if Task.isCancelled {
                    modelContext.rollback()
                    throw CancellationError()
                }
                let (visit, created, skippedSensorDay) = try persistStay(stay, step: &step)
                if skippedSensorDay {
                    report.sensorDaySkipCount += 1
                }
                if created {
                    report.createdVisitCount += 1
                } else if visit != nil {
                    report.reusedVisitCount += 1
                }
                usedAssetIDs.formUnion(stay.assets.map(\.localIdentifier))
                for asset in stay.spread(configuration.maximumPhotosPerStay) {
                    if try attach(asset, to: visit, step: &step) {
                        report.attachedPhotoCount += 1
                        if visit == nil {
                            report.dayOnlyAttachmentCount += 1
                        }
                    }
                }
                if let visit {
                    if let previous, try insertMoveIfNeeded(from: previous, to: visit, step: &step) {
                        report.createdMoveCount += 1
                    }
                    previous = visit
                }
            }
            // An import that works backward has already made the visits that follow this batch.
            if let last = previous, last.origin == .photoInferred,
               let following = step.earliestPhotoInferredVisit(after: last),
               try insertMoveIfNeeded(from: last, to: following, step: &step) {
                report.createdMoveCount += 1
            }

            for asset in geotagged where !usedAssetIDs.contains(asset.localIdentifier) {
                let visit = step.matchingVisit(for: asset)
                if try attach(asset, to: visit, step: &step) {
                    report.attachedPhotoCount += 1
                    if visit == nil {
                        report.dayOnlyAttachmentCount += 1
                    }
                }
            }

            try repository.saveIfNeeded()
        }
        return report
    }

    /// Attaches newly seen geotagged photos to matching visits or to the day.
    @discardableResult
    func attachPhotos(_ assets: [PhotoAssetDescriptor]) throws -> Int {
        let geotagged = assets
            .filter { $0.coordinate != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let first = geotagged.first, let last = geotagged.last else { return 0 }

        var step = try Step(
            range: DateInterval(start: first.capturedAt, end: last.capturedAt),
            configuration: configuration,
            context: modelContext
        )
        var attached = 0
        for asset in geotagged {
            if try attach(asset, to: step.matchingVisit(for: asset), step: &step) {
                attached += 1
            }
        }
        if attached > 0 {
            try repository.saveIfNeeded()
            Self.announceChanges()
        }
        return attached
    }

    /// Tells open screens that photo-built visits or attachments changed.
    static func announceChanges() {
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        NotificationCenter.default.post(name: .movesPhotoLibraryDidChange, object: nil)
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
        transportMode(
            distance: LocationLogGeometry.distance(from: start.coordinate, to: end.coordinate),
            duration: end.arrivalDate.timeIntervalSince(start.departureDate),
            configuration: configuration
        )
    }

    static func transportMode(
        distance: CLLocationDistance,
        duration: TimeInterval,
        configuration: Configuration
    ) -> TransportMode {
        guard duration > 0 else { return .unknown }
        let kilometersPerHour = (distance / 1_000) / (duration / 3_600)
        return AutomaticTransportModes.load().allowedMode(
            kilometersPerHour > configuration.planeSpeedKilometersPerHour ? .plane : .unknown
        )
    }

    /// How the owner got from one photo stop to the next, or `nil` when the photos don't
    /// say there was one trip: too long a silence, or a speed nothing on the ground has over
    /// a distance nobody flies.
    static func tripMode(
        distance: CLLocationDistance,
        gap: TimeInterval,
        configuration: Configuration = Configuration()
    ) -> TransportMode? {
        guard gap >= 0, distance >= configuration.minimumMoveDistance else { return nil }
        guard gap > 0 else { return nil }
        let kilometersPerHour = distance / gap * 3.6
        guard kilometersPerHour <= configuration.maximumFlightKilometersPerHour else { return nil }
        if kilometersPerHour > configuration.planeSpeedKilometersPerHour,
           distance < configuration.minimumFlightDistance {
            return nil
        }
        let mode = transportMode(distance: distance, duration: gap, configuration: configuration)
        if gap <= configuration.maximumMoveGap { return mode }
        return mode == .plane && gap <= configuration.maximumFlightGap ? mode : nil
    }

    // MARK: - Repairs at launch

    /// Takes out photo-built trips an earlier version made across silences that `tripMode`
    /// calls gaps. A trip the person has touched is theirs and stays.
    ///
    /// Only for before the timeline is on screen: it deletes rows.
    @discardableResult
    static func removeImplausibleTrips(in context: ModelContext) throws -> Int {
        let photoInferred = TimelineItemOrigin.photoInferred.rawValue
        let trips = try context.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.originRaw == photoInferred }))
        var removed = 0
        for trip in trips where !trip.isTouchedByPerson {
            let distance: CLLocationDistance
            if let start = trip.startPlace, let end = trip.endPlace {
                distance = LocationLogGeometry.distance(from: start.coordinate, to: end.coordinate)
            } else {
                distance = trip.distanceMeters
            }
            guard tripMode(distance: distance, gap: trip.endDate.timeIntervalSince(trip.startDate)) == nil else { continue }
            context.delete(trip)
            removed += 1
        }
        return removed
    }

    /// Takes out stays an earlier version built only from photos now known not to be the
    /// owner's, with the trips to and from them. A stay the person has touched stays.
    ///
    /// Only for before the timeline is on screen: it deletes rows.
    @discardableResult
    static func removeStays(builtOnlyFrom identifiers: Set<String>, in context: ModelContext) throws -> Int {
        let photoInferred = TimelineItemOrigin.photoInferred.rawValue
        var stays: [UUID: VisitPlace] = [:]
        let all = Array(identifiers)
        for from in stride(from: 0, to: all.count, by: 200) {
            let some = Array(all[from..<min(from + 200, all.count)])
            let rows = try context.fetch(
                FetchDescriptor<PhotoAttachment>(predicate: #Predicate { some.contains($0.assetLocalIdentifier) })
            )
            for row in rows {
                guard let stay = row.visitPlace, stay.originRaw == photoInferred, !stay.isTouchedByPerson else { continue }
                stays[stay.id] = stay
            }
        }

        var removed = 0
        for stay in stays.values {
            let photos = stay.photoAttachments
            guard photos.allSatisfy({ identifiers.contains($0.assetLocalIdentifier) }) else {
                for photo in photos where identifiers.contains(photo.assetLocalIdentifier) {
                    context.delete(photo)
                }
                continue
            }
            let trips = stay.outgoingMoves + stay.incomingMoves
            guard trips.allSatisfy({ $0.origin == .photoInferred && !$0.isTouchedByPerson }) else { continue }
            let from = stay.arrivalDate.addingTimeInterval(-1)
            let through = (stay.departureDate ?? stay.arrivalDate).addingTimeInterval(1)
            let library = LocationSampleSource.photoLibrary.rawValue
            let fixes = try context.fetch(
                FetchDescriptor<LocationSample>(
                    predicate: #Predicate {
                        $0.timestamp >= from && $0.timestamp <= through && $0.sourceRawValue == library
                    }
                )
            )
            for fix in fixes where LocationLogGeometry.distance(from: fix.coordinate, to: stay.coordinate) < 2_000 {
                context.delete(fix)
            }
            for trip in trips {
                context.delete(trip)
            }
            context.delete(stay)
            removed += 1
        }
        return removed
    }

    // MARK: - Write path

    /// What one batch reads once instead of asking the store about every photo.
    private struct Step {
        let configuration: Configuration
        /// Visits that could overlap the batch, ordered by arrival.
        private(set) var visits: [VisitPlace]
        var attachedIDs: Set<String>
        var protectedDays: [String: Bool] = [:]
        /// The first and last fix stored for a visit made in this batch.
        var endpointSamples: [UUID: (first: LocationSample, last: LocationSample)] = [:]
        private let removedStops: [(interval: DateInterval, coordinate: CLLocationCoordinate2D)]

        /// A visit from a week earlier can still be open over the batch's first photo.
        private static let visitLookback: TimeInterval = 8 * 24 * 60 * 60

        init(range: DateInterval, configuration: Configuration, context: ModelContext) throws {
            self.configuration = configuration
            let slack = configuration.visitMatchSlack

            let visitsFrom = range.start.addingTimeInterval(-Self.visitLookback)
            let visitsThrough = range.end.addingTimeInterval(slack + configuration.maximumFlightGap)
            visits = try context.fetch(
                FetchDescriptor<VisitPlace>(
                    predicate: #Predicate { $0.arrivalDate >= visitsFrom && $0.arrivalDate <= visitsThrough && $0.dayTimeline != nil },
                    sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
                )
            )

            let photosFrom = range.start.addingTimeInterval(-1)
            let photosThrough = range.end.addingTimeInterval(1)
            var attachments = FetchDescriptor<PhotoAttachment>(
                predicate: #Predicate { $0.capturedAt >= photosFrom && $0.capturedAt <= photosThrough }
            )
            attachments.propertiesToFetch = [\.assetLocalIdentifier]
            attachedIDs = Set(try context.fetch(attachments).map(\.assetLocalIdentifier))

            let removedFrom = range.start
            let removedThrough = range.end
            removedStops = try context.fetch(
                FetchDescriptor<RemovedTimelineSpan>(
                    predicate: #Predicate { $0.endDate >= removedFrom && $0.startDate <= removedThrough }
                )
            )
            .filter { $0.kind == .stop }
            .map { span in
                (
                    DateInterval(start: span.startDate, end: max(span.endDate, span.startDate)),
                    CLLocationCoordinate2D(latitude: span.latitude, longitude: span.longitude)
                )
            }
        }

        /// Visits whose time range touches the stay, whichever day they are filed under: a
        /// hotel visit from Monday covers Tuesday's photos though Tuesday has no rows.
        func visitsOverlapping(_ stay: PhotoHistoryStay) -> [VisitPlace] {
            let slack = configuration.visitMatchSlack
            let windowEnd = stay.departureDate.addingTimeInterval(slack)
            return visits(arrivingFrom: stay.arrivalDate.addingTimeInterval(-Self.visitLookback), through: windowEnd)
                .filter { place in
                    PhotoHistoryImporter.timeRangesOverlap(
                        startA: stay.arrivalDate.addingTimeInterval(-slack),
                        endA: windowEnd,
                        startB: place.arrivalDate,
                        endB: place.departureDate ?? place.outgoingMoves.map(\.startDate).min() ?? .distantFuture
                    )
                }
        }

        func matchingVisit(for asset: PhotoAssetDescriptor) -> VisitPlace? {
            guard let coordinate = asset.coordinate else { return nil }
            let slack = configuration.visitMatchSlack
            let radius = configuration.visitMatchRadius
            return visits(
                arrivingFrom: asset.capturedAt.addingTimeInterval(-Self.visitLookback),
                through: asset.capturedAt.addingTimeInterval(slack)
            )
            .filter { place in
                let start = place.arrivalDate.addingTimeInterval(-slack)
                let end = (place.departureDate ?? .distantFuture).addingTimeInterval(slack)
                return asset.capturedAt >= start
                    && asset.capturedAt <= end
                    && LocationLogGeometry.distance(from: place.coordinate, to: coordinate) <= radius
            }
            .min { lhs, rhs in
                LocationLogGeometry.distance(from: coordinate, to: lhs.coordinate)
                    < LocationLogGeometry.distance(from: coordinate, to: rhs.coordinate)
            }
        }

        /// The photo-built visit a batch continues from, so a trip that spans two batches
        /// is still joined.
        func latestPhotoInferredVisit(before date: Date) -> VisitPlace? {
            visits[..<firstIndex(arrivingAtOrAfter: date)].last { $0.origin == .photoInferred }
        }

        func earliestPhotoInferredVisit(after visit: VisitPlace) -> VisitPlace? {
            let departure = visit.departureDate ?? visit.arrivalDate
            return visits[firstIndex(arrivingAtOrAfter: departure)...].first {
                $0.origin == .photoInferred && $0.id != visit.id
            }
        }

        func wasRemoved(_ stay: PhotoHistoryStay) -> Bool {
            removedStops.contains { removed in
                removed.interval.start < stay.departureDate.addingTimeInterval(1)
                    && removed.interval.end > stay.arrivalDate.addingTimeInterval(-1)
                    && LocationLogGeometry.distance(from: stay.coordinate, to: removed.coordinate)
                        <= configuration.removedStopMatchDistance
            }
        }

        mutating func insert(_ visit: VisitPlace) {
            visits.insert(visit, at: firstIndex(arrivingAtOrAfter: visit.arrivalDate))
        }

        /// Call after moving a visit's arrival so later lookups still find it in order.
        mutating func restoreOrder() {
            visits.sort { $0.arrivalDate < $1.arrivalDate }
        }

        private func visits(arrivingFrom start: Date, through end: Date) -> ArraySlice<VisitPlace> {
            let lower = firstIndex(arrivingAtOrAfter: start)
            var upper = lower
            while upper < visits.count, visits[upper].arrivalDate <= end {
                upper += 1
            }
            return visits[lower..<upper]
        }

        private func firstIndex(arrivingAtOrAfter date: Date) -> Int {
            var low = 0
            var high = visits.count
            while low < high {
                let middle = (low + high) / 2
                if visits[middle].arrivalDate < date {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }

    private func persistStay(
        _ stay: PhotoHistoryStay,
        step: inout Step
    ) throws -> (visit: VisitPlace?, created: Bool, skippedSensorDay: Bool) {
        let day = try repository.dayTimeline(for: stay.arrivalDate, at: stay.coordinate)
        let overlapping = step.visitsOverlapping(stay)
        let match = matchingVisit(for: stay, among: overlapping)
        if isProtected(day, step: &step) || overlapping.contains(where: { $0.origin != .photoInferred }) {
            return (match, false, true)
        }

        if let existing = match {
            if existing.origin == .photoInferred {
                let arrival = existing.arrivalDate
                extendPhotoInferredVisit(existing, with: stay)
                if existing.arrivalDate != arrival {
                    step.restoreOrder()
                }
                // Photos the visit did not have before bring their fixes with them.
                _ = try repository.appendSamples(
                    from: stay.spread(configuration.maximumFixesPerStay).compactMap(\.locationLogPoint).map(\.location),
                    source: .photoLibrary
                )
            }
            return (existing, false, false)
        }

        // Removing a stop is a correction, and a correction outlasts every later import.
        if step.wasRemoved(stay) {
            return (nil, false, false)
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
        step.insert(visit)

        let locations = stay.spread(configuration.maximumFixesPerStay).compactMap(\.locationLogPoint).map(\.location)
        let samples = try repository.appendSamples(from: locations, source: .photoLibrary)
        if let first = samples.first, let last = samples.last {
            step.endpointSamples[visit.id] = (first, last)
        }
        try repository.applyPlaceLearning(to: visit)
        return (visit, true, false)
    }

    private func isProtected(_ day: DayTimeline, step: inout Step) -> Bool {
        if let known = step.protectedDays[day.dayKey] {
            return known
        }
        let protected = day.isProtectedFromPhotoBackfill
        step.protectedDays[day.dayKey] = protected
        return protected
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

    /// Joins two photo-built visits with an estimated trip when they belong to one outing.
    private func insertMoveIfNeeded(
        from start: VisitPlace,
        to end: VisitPlace,
        step: inout Step
    ) throws -> Bool {
        guard start.id != end.id, start.origin == .photoInferred, end.origin == .photoInferred else {
            return false
        }
        let startDate = start.departureDate ?? start.arrivalDate
        let endDate = end.arrivalDate
        let gap = endDate.timeIntervalSince(startDate)
        let distance = LocationLogGeometry.distance(from: start.coordinate, to: end.coordinate)
        guard let mode = Self.tripMode(distance: distance, gap: gap, configuration: configuration) else { return false }

        if let startDay = start.dayTimeline, isProtected(startDay, step: &step) { return false }
        if let endDay = end.dayTimeline, isProtected(endDay, step: &step) { return false }
        if start.outgoingMoves.contains(where: { move in
            move.endPlace?.id == end.id && move.origin == .photoInferred
        }) {
            return false
        }

        let move = MoveSegment(
            dedupeKey: "photo-\(start.id.uuidString)-\(end.id.uuidString)-\(Int(startDate.timeIntervalSince1970))",
            startDate: startDate,
            endDate: endDate,
            transportMode: mode,
            distanceMeters: distance,
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
        // The last photo at one stop and the first at the next are the trip's two fixes.
        step.endpointSamples[start.id]?.last.moveSegment = move
        step.endpointSamples[end.id]?.first.moveSegment = move
        modelContext.insert(move)
        return true
    }

    @discardableResult
    private func attach(
        _ asset: PhotoAssetDescriptor,
        to visit: VisitPlace?,
        step: inout Step
    ) throws -> Bool {
        guard step.attachedIDs.insert(asset.localIdentifier).inserted else { return false }

        let attachment = PhotoAttachment(
            assetLocalIdentifier: asset.localIdentifier,
            capturedAt: asset.capturedAt,
            latitude: asset.latitude,
            longitude: asset.longitude
        )
        attachment.visitPlace = visit
        attachment.dayTimeline = try visit?.dayTimeline ?? repository.dayTimeline(
            for: asset.capturedAt,
            at: asset.latitude.flatMap { latitude in asset.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) } }
        )
        modelContext.insert(attachment)
        return true
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

    fileprivate static func timeRangesOverlap(
        startA: Date,
        endA: Date,
        startB: Date,
        endB: Date
    ) -> Bool {
        min(endA, endB) >= max(startA, startB)
    }
}

extension DayTimeline {
    /// GPS, import, or manual items already occupy this day — photo backfill
    /// may attach thumbnails but must not add inferred visits or moves.
    var isProtectedFromPhotoBackfill: Bool {
        places.contains { $0.origin != .photoInferred }
            || moves.contains { $0.origin != .photoInferred }
            || samples.contains { $0.source != .photoLibrary && $0.source != .cameraPhoto }
    }
}

private extension MoveSegment {
    var isTouchedByPerson: Bool {
        transportModeSource == .user
            || reviewState == .confirmed
            || manualRouteCoordinatesData != nil
            || !(comment ?? "").isEmpty
    }
}

private extension VisitPlace {
    var isTouchedByPerson: Bool {
        assignmentSource == .user
            || reviewState == .confirmed
            || !(userLabel ?? "").isEmpty
            || !(comment ?? "").isEmpty
    }
}

/// Photos found in the timeline that a later look at the library says are not the owner's.
/// They are taken out at the next launch, before the timeline is on screen.
struct RejectedPhotoStore: Sendable {
    static let key = "photos.rejectedPhotos"
    nonisolated(unsafe) var defaults: UserDefaults = .standard

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func add(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        defaults.set(Array(load().union(identifiers)), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
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
