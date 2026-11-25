import CoreLocation
import Foundation
import SwiftData

/// One-shot backfill that fills derived fields added in the WS0 schema.
///
/// Runs off the main actor with its own `ModelContext`. Safe to call on every
/// launch: a UserDefaults version key skips work that already completed, and
/// the individual steps are idempotent if the key is missing.
enum TimelineSchemaUpgrader {
    /// Step 4 settles Review questions; steps 5–7 are the place-identity repairs; step 8
    /// takes out trips drawn between photos hours apart.
    static let currentVersion = 8
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
        guard storedVersion < currentVersion else {
            mergeDuplicatePlacesIfAny(container: container)
            return
        }

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

    /// Takes out stays a photo import built from photos it has since found are not the
    /// owner's. Runs after any upgrade, and like it holds the timeline back until it is done.
    @MainActor
    static func removeRejectedPhotoStaysIfAny(container: ModelContainer, store: RejectedPhotoStore = RejectedPhotoStore()) {
        let identifiers = store.load()
        guard !identifiers.isEmpty else { return }
        let earlier = running
        running = Task.detached(priority: .userInitiated) {
            await earlier?.value
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                try PhotoHistoryImporter.removeStays(builtOnlyFrom: identifiers, in: context)
                if context.hasChanges {
                    try context.save()
                }
                store.clear()
            } catch {
                print("Removing rejected photo stays failed: \(error.localizedDescription)")
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
        if storedVersion < 5 {
            _ = try clearCellCopiedAddresses(in: context)
            _ = try clearCountryNamedCities(in: context)
        }
        if storedVersion < 6 {
            _ = try mergeDuplicateKnownPlaces(in: context)
        }
        if storedVersion < 7 {
            _ = try unifyAutomaticLabels(in: context)
        }
        if storedVersion < 8 {
            _ = try PhotoHistoryImporter.removeImplausibleTrips(in: context)
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

    // MARK: - Place identity repairs (steps 5–7)

    /// Twins of a confirmed place can arrive from iCloud after launch, when another device
    /// or an earlier install made them. This check is a fetch of a handful of rows; the
    /// merge runs behind the upgrade screen only when there is something to merge.
    @MainActor
    private static func mergeDuplicatePlacesIfAny(container: ModelContainer) {
        let probe = ModelContext(container)
        guard let places = try? probe.fetch(FetchDescriptor<KnownPlace>()),
              !PlaceLearningEngine.duplicateMerges(places.map(PlaceLearningEngine.DuplicateCandidate.init)).isEmpty
        else { return }
        running = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                _ = try mergeDuplicateKnownPlaces(in: context)
            } catch {
                print("Duplicate place merge failed: \(error.localizedDescription)")
            }
        }
    }

    /// Step 5. Street and address fields an older backfill copied from one geocode onto
    /// every stay in a kilometre-wide cell. The tell is one address on stays more than
    /// 100 m apart. Those fields are cleared so the ~100 m name backfill fills them again,
    /// one cell per second. Returns how many fields were cleared.
    @discardableResult
    static func clearCellCopiedAddresses(in context: ModelContext) throws -> Int {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        var groups: [String: [VisitPlace]] = [:]
        for visit in visits {
            guard let address = PlaceDisplayNamer.meaningful(visit.formattedAddress) else { continue }
            groups[address, default: []].append(visit)
        }
        var copied = Set<String>()
        for (address, members) in groups where members.count > 1 {
            if spansMoreThan(cellCopyDistance, members.map(\.coordinate)) {
                copied.insert(address)
            }
        }
        guard !copied.isEmpty else { return 0 }

        var cleared = 0
        for visit in visits {
            guard let address = PlaceDisplayNamer.meaningful(visit.formattedAddress), copied.contains(address) else {
                continue
            }
            visit.formattedAddress = nil
            cleared += 1
            if visit.thoroughfare != nil {
                visit.thoroughfare = nil
                cleared += 1
            }
        }
        for place in try context.fetch(FetchDescriptor<KnownPlace>()) {
            guard let address = PlaceDisplayNamer.meaningful(place.formattedAddress), copied.contains(address) else {
                continue
            }
            place.formattedAddress = nil
            cleared += 1
            if place.thoroughfare != nil {
                place.thoroughfare = nil
                cleared += 1
            }
        }
        try context.save()
        return cleared
    }

    /// Step 5, with the address repair. A city written as the country's own name
    /// ("Türkiye") is cleared; the backfill then leaves it empty or finds the real city,
    /// and the Places list falls back to the area. Returns how many cities were cleared.
    @discardableResult
    static func clearCountryNamedCities(in context: ModelContext) throws -> Int {
        var cleared = 0
        for visit in try context.fetch(FetchDescriptor<VisitPlace>())
        where PlaceGeocodeRegion.isCountryName(visit.locality, countryCode: visit.countryCode) {
            visit.locality = nil
            cleared += 1
        }
        for place in try context.fetch(FetchDescriptor<KnownPlace>())
        where PlaceGeocodeRegion.isCountryName(place.locality, countryCode: place.countryCode) {
            place.locality = nil
            cleared += 1
        }
        if cleared > 0 {
            try context.save()
        }
        return cleared
    }

    /// Farther apart than one ~100 m name cell can explain.
    static let cellCopyDistance: CLLocationDistance = 100

    private static func spansMoreThan(_ limit: CLLocationDistance, _ coordinates: [CLLocationCoordinate2D]) -> Bool {
        for (index, lhs) in coordinates.enumerated() {
            for rhs in coordinates[(index + 1)...] where distance(from: lhs, to: rhs) > limit {
                return true
            }
        }
        return false
    }

    /// Step 6, and again at any launch that finds twins. Confirmed places with the same
    /// name, folded, whose centres sit inside the larger footprint become one, kept as the
    /// earliest created. Corrections that named the removed twin now name the survivor.
    /// Returns how many places were merged away.
    @discardableResult
    static func mergeDuplicateKnownPlaces(in context: ModelContext) throws -> Int {
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        let merges = PlaceLearningEngine.duplicateMerges(places.map(PlaceLearningEngine.DuplicateCandidate.init))
        guard !merges.isEmpty else { return 0 }
        let byID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let events = try context.fetch(FetchDescriptor<PlaceCorrectionEvent>())
        var merged = 0
        for merge in merges {
            guard let source = byID[merge.source], let destination = byID[merge.destination] else { continue }
            PlaceLearningEngine.merge(source, into: destination)
            for event in events {
                if event.fromKnownPlaceID == source.id { event.fromKnownPlaceID = destination.id }
                if event.toKnownPlaceID == source.id { event.toKnownPlaceID = destination.id }
            }
            context.delete(source)
            merged += 1
        }
        try context.save()
        return merged
    }

    /// Step 7. One automatic label per real place across history: unassigned stays the
    /// person never named are clustered with the same-spot rule, and each cluster takes the
    /// label most time was spent under. Labels only; no rows are added or removed. Running
    /// it again changes nothing, so an interrupted pass simply runs again next launch.
    /// Returns how many labels changed.
    @discardableResult
    static func unifyAutomaticLabels(in context: ModelContext) throws -> Int {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>()).filter { visit in
            visit.knownPlace == nil
                && visit.assignmentSource == .none
                && PlaceDisplayNamer.meaningful(visit.userLabel) == nil
                && PlaceDisplayNamer.meaningful(visit.autoLabel) != nil
        }
        guard !visits.isEmpty else { return 0 }
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        let changes = PlaceLearningEngine.unifiedLabels(
            for: visits.map { PlaceLearningEngine.StaySnapshot($0, label: $0.autoLabel) },
            isSuppressed: { label, coordinate in
                let nearby = places.filter {
                    distance(from: $0.coordinate, to: coordinate) <= PlaceLearningEngine.rejectedLabelSearchRadius
                }
                return PlaceLearningEngine.shouldSuppress(label, nearbyPlaces: nearby)
            }
        )
        guard !changes.isEmpty else { return 0 }
        var written = 0
        for visit in visits {
            guard let label = changes[visit.id] else { continue }
            visit.autoLabel = label
            written += 1
            if written.isMultiple(of: 200) {
                try context.save()
            }
        }
        try context.save()
        return written
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
    ///
    /// Only for history from before learned places existed. A visit that already carries an
    /// assignment had a place on the device that wrote it; on a fresh install its place is
    /// still on the way from iCloud, and making one here is how twin places were born.
    private static func clusterUserLabeledPlaces(in context: ModelContext) throws {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let unlabeled = visits.filter { visit in
            visit.knownPlace == nil
                && visit.assignmentSource == .none
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
