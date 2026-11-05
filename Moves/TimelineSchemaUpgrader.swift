import CoreLocation
import Foundation
import SwiftData

/// One-shot backfill that fills derived fields added in the WS0 schema.
///
/// Runs off the main actor with its own `ModelContext`. Safe to call on every
/// launch: a UserDefaults version key skips work that already completed, and
/// the individual steps are idempotent if the key is missing.
enum TimelineSchemaUpgrader {
    static let currentVersion = 2
    static let userDefaultsKey = "moves.timelineSchemaVersion"

    /// Schedules an upgrade when the stored version is behind `currentVersion`.
    static func runIfNeeded(
        container: ModelContainer,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.integer(forKey: userDefaultsKey) < currentVersion else { return }

        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                try upgrade(in: context)
                defaults.set(currentVersion, forKey: userDefaultsKey)
            } catch {
                print("Timeline schema upgrade failed: \(error.localizedDescription)")
            }
        }
    }

    /// Applies every backfill step. Exposed for tests; calling twice is a no-op
    /// besides rewriting the same derived values.
    static func upgrade(in context: ModelContext) throws {
        try clusterUserLabeledPlaces(in: context)
        try backfillShortStops(in: context)
        try backfillRouteMatchPolicies(in: context)
        try SwiftDataTimelineRepository(modelContext: context).repairDuplicateStays()
        if context.hasChanges {
            try context.save()
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
