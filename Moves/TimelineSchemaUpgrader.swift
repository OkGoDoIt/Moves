import CoreLocation
import Foundation
import SwiftData

/// One-shot backfill that fills derived fields added in the WS0 schema.
///
/// Runs off the main actor with its own `ModelContext`. Safe to call on every
/// launch: a UserDefaults version key skips work that already completed, and
/// the individual steps are idempotent if the key is missing.
enum TimelineSchemaUpgrader {
    static let currentVersion = 4
    static let userDefaultsKey = "moves.timelineSchemaVersion"

    @MainActor private static var running: Task<Void, Never>?

    /// Whether an upgrade is underway. The timeline UI stays away until it finishes.
    @MainActor static var isRunning: Bool {
        running != nil
    }

    /// Returns once any upgrade in progress is done.
    ///
    /// The upgrade deletes duplicate rows on its own context, and touching a row another
    /// context has deleted aborts the process. Work that walks the store waits for this.
    static func waitUntilFinished() async {
        let task = await MainActor.run { running }
        await task?.value
    }

    /// Schedules an upgrade when the stored version is behind `currentVersion`.
    @MainActor
    static func runIfNeeded(
        container: ModelContainer,
        defaults: UserDefaults = .standard
    ) {
        let storedVersion = defaults.integer(forKey: userDefaultsKey)
        guard storedVersion < currentVersion else { return }

        running = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                try upgrade(in: context, from: storedVersion)
                if storedVersion < 3 {
                    await repairLongTrips(in: container)
                }
                defaults.set(currentVersion, forKey: userDefaultsKey)
            } catch {
                print("Timeline schema upgrade failed: \(error.localizedDescription)")
            }
        }
    }

    /// Applies every backfill step. Exposed for tests; calling twice is a no-op
    /// besides rewriting the same derived values.
    static func upgrade(in context: ModelContext, from storedVersion: Int = 0) throws {
        if storedVersion < 1 {
            try clusterUserLabeledPlaces(in: context)
            try backfillShortStops(in: context)
            try backfillRouteMatchPolicies(in: context)
        }
        if storedVersion < 3 {
            let repository = SwiftDataTimelineRepository(modelContext: context)
            try repository.repairDuplicateStays()
            try repository.repairTripLabels()
        }
        if storedVersion < 4 {
            try tagImportedHistory(in: context)
            try settleReviewQuestions(in: context)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    // MARK: - Review questions

    /// Trips and stays imported before the importer tagged their origin still read as
    /// recorded here. A trip whose every fix came from a history file is imported, and so
    /// is a stay whose every trip in and out is. Their open questions go with them.
    @discardableResult
    static func tagImportedHistory(in context: ModelContext) throws -> Int {
        let sensor = TimelineItemOrigin.sensor.rawValue
        var moveDescriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.originRaw == sensor })
        moveDescriptor.relationshipKeyPathsForPrefetching = [\.samplesStorage]
        var tagged = 0
        for move in try context.fetch(moveDescriptor) where TimelineReviewHeuristics.isImportedHistory(move) {
            move.origin = .imported
            if move.reviewState == .pending { move.reviewState = .none }
            tagged += 1
        }
        guard tagged > 0 else { return 0 }
        let visits = try context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.originRaw == sensor }))
        for visit in visits where TimelineReviewHeuristics.isImportedHistory(visit) {
            visit.origin = .imported
            if visit.reviewState == .pending { visit.reviewState = .none }
            tagged += 1
        }
        return tagged
    }

    /// Clears open questions whose reason no longer holds, and asks about recent stays
    /// too brief to have been flagged when they were written. Reads only open questions
    /// and recent brief stays, so it is cheap enough to run on every launch.
    @discardableResult
    static func settleReviewQuestions(in context: ModelContext, now: Date = .now) throws -> Int {
        let pending = ReviewState.pending.rawValue
        let none = ReviewState.none.rawValue
        let sensor = TimelineItemOrigin.sensor.rawValue
        var changed = 0

        let pendingVisits = try context.fetch(FetchDescriptor<VisitPlace>(
            predicate: #Predicate { $0.reviewStateRaw == pending }
        ))
        for visit in pendingVisits where TimelineReviewHeuristics.question(for: visit, now: now) == nil {
            visit.reviewState = .none
            changed += 1
        }

        let pendingMoves = try context.fetch(FetchDescriptor<MoveSegment>(
            predicate: #Predicate { $0.reviewStateRaw == pending }
        ))
        for move in pendingMoves where TimelineReviewHeuristics.question(for: move, now: now) == nil {
            move.reviewState = .none
            changed += 1
        }

        let windowStart = now.addingTimeInterval(-TimelineReviewHeuristics.newQuestionWindow)
        let recentStays = try context.fetch(FetchDescriptor<VisitPlace>(
            predicate: #Predicate { visit in
                visit.reviewStateRaw == none
                    && visit.originRaw == sensor
                    && visit.arrivalDate >= windowStart
                    && visit.departureDate != nil
            }
        ))
        for visit in recentStays where TimelineReviewHeuristics.shouldAskAboutStay(visit, now: now) {
            visit.reviewState = .pending
            changed += 1
        }
        return changed
    }

    /// The launch-time pass for review questions once the schema is current. Runs on the
    /// view context with undo detached, so it never lands on the person's Undo stack.
    @MainActor
    static func settleReviewQuestions(onViewContext context: ModelContext) {
        let manager = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = manager }
        do {
            if try settleReviewQuestions(in: context) > 0 {
                try context.save()
            }
        } catch {
            print("Settling review questions failed: \(error.localizedDescription)")
        }
    }

    /// Older trips that swallowed a stop, rebuilt from stored fixes. Names for any stops
    /// this finds come from the geocode backfill, so the upgrade never waits on the network.
    @MainActor
    static func repairLongTrips(in container: ModelContainer) async {
        await DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContainer: container),
            motionClassifier: CoreMotionTransportClassifier(),
            placeNameResolver: UnnamedPlaceResolver()
        )
        .repairLongHistoricalTrips()
    }

    private struct UnnamedPlaceResolver: PlaceNameResolver {
        func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
            nil
        }
    }

    /// Same name within 120 m becomes one `KnownPlace`; assigned visits use `.user`.
    private static func clusterUserLabeledPlaces(in context: ModelContext) throws {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let unlabeled = visits.filter { visit in
            visit.knownPlace == nil
                && !(visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var buckets: [String: [VisitPlace]] = [:]
        for visit in unlabeled {
            let key = (visit.userLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            buckets[key, default: []].append(visit)
        }

        var knownPlaces = try context.fetch(FetchDescriptor<KnownPlace>())

        for (_, labeledVisits) in buckets {
            var remaining = labeledVisits
            while !remaining.isEmpty {
                var cluster = [remaining.removeFirst()]
                var grew = true
                while grew {
                    grew = false
                    remaining.removeAll { candidate in
                        let belongs = cluster.contains { seed in
                            distance(from: seed.coordinate, to: candidate.coordinate) <= 120
                        }
                        if belongs {
                            cluster.append(candidate)
                            grew = true
                        }
                        return belongs
                    }
                }

                let name = cluster
                    .compactMap { $0.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                    ?? ""
                let knownPlace = existingKnownPlace(
                    named: name,
                    near: meanCoordinate(of: cluster),
                    in: knownPlaces
                ) ?? makeKnownPlace(from: cluster, name: name, context: context)
                if !knownPlaces.contains(where: { $0.id == knownPlace.id }) {
                    knownPlaces.append(knownPlace)
                }

                for visit in cluster {
                    visit.knownPlace = knownPlace
                    visit.assignmentSource = .user
                    visit.assignmentConfidence = 1
                }

                knownPlace.confirmedVisitCount = max(knownPlace.confirmedVisitCount, knownPlace.visits.count)
                if let latest = cluster.map(\.arrivalDate).max() {
                    if knownPlace.lastVisitAt == nil || latest > (knownPlace.lastVisitAt ?? .distantPast) {
                        knownPlace.lastVisitAt = latest
                    }
                }
            }
        }
    }

    private static func backfillShortStops(in context: ModelContext) throws {
        let days = try context.fetch(FetchDescriptor<DayTimeline>())
        for day in days {
            for place in day.places {
                place.isHiddenAsShortStop = place.matchesShortStopHeuristic(in: day)
            }
        }
    }

    private static func backfillRouteMatchPolicies(in context: ModelContext) throws {
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        for move in moves {
            if move.manualRouteCoordinatesData != nil {
                move.routeMatchPolicy = .manual
            } else if move.usesHighAccuracyRouteTracking {
                move.routeMatchPolicy = .recorded
                if move.routeMatchConfidence == .unknown {
                    move.routeMatchConfidence = .recorded
                }
            }
        }
    }

    private static func existingKnownPlace(
        named name: String,
        near coordinate: CLLocationCoordinate2D,
        in places: [KnownPlace]
    ) -> KnownPlace? {
        let needle = name.lowercased()
        return places.first { place in
            place.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
                && distance(from: place.coordinate, to: coordinate) <= 120
        }
    }

    private static func makeKnownPlace(
        from cluster: [VisitPlace],
        name: String,
        context: ModelContext
    ) -> KnownPlace {
        let center = meanCoordinate(of: cluster)
        let distances = cluster.map { distance(from: center, to: $0.coordinate) }
        let radius = min(150, max(25, percentile(distances, 0.9)))
        let place = KnownPlace(
            name: name,
            latitude: center.latitude,
            longitude: center.longitude,
            footprintRadius: radius
        )
        context.insert(place)
        return place
    }

    private static func meanCoordinate(of visits: [VisitPlace]) -> CLLocationCoordinate2D {
        guard !visits.isEmpty else {
            return CLLocationCoordinate2D()
        }
        let latitude = visits.map(\.latitude).reduce(0, +) / Double(visits.count)
        let longitude = visits.map(\.longitude).reduce(0, +) / Double(visits.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func percentile(_ values: [CLLocationDistance], _ p: Double) -> CLLocationDistance {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((p * Double(sorted.count - 1)).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }

    private static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}
