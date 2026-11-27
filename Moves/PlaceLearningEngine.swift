import CoreLocation
import Foundation
import SwiftData

/// Scores visits against learned places and updates footprints from
/// user-confirmed assignments only.
///
/// Auto assignments never mutate a `KnownPlace`. Guesses (geocoder names,
/// copied labels) never teach the footprint. When two places compete, a
/// visit is auto-assigned only if the top score beats the runner-up by
/// `autoAssignMargin`; otherwise the top place is attached as
/// `.autoAmbiguous` so Review / the storyline chooser can ask.
enum PlaceLearningEngine {
    /// Minimum `top − second` score before a multi-candidate visit is
    /// auto-assigned. Decided product rule (PLAN §10).
    static let autoAssignMargin: Double = 0.25

    /// Floor used when a visit reports a tiny or unknown accuracy.
    static let accuracyFloor: CLLocationDistance = 20

    /// Extra metres added to the candidate gate beyond radius + accuracy.
    static let candidatePadding: CLLocationDistance = 15

    /// Radius used to collect `rejectedAutoLabels` that suppress geocoder names.
    static let rejectedLabelSearchRadius: CLLocationDistance = 250

    static let minimumFootprintRadius: CLLocationDistance = 25
    static let maximumFootprintRadius: CLLocationDistance = 150
    static let radiusGrowthFactor: Double = 1.15
    static let radiusShrinkFactor: Double = 0.80
    static let negativeEventsBeforeShrink = 3
    static let maxVisitsForFootprint = 200
    static let maxStayDurationSamples = 50
    /// How far a stored center or radius can sit from a rebuild and still count as learned.
    static let handSetCenterTolerance: CLLocationDistance = 1
    static let handSetRadiusTolerance: CLLocationDistance = 0.5

    static let proximityWeight = 0.45
    static let hourWeight = 0.20
    static let weekdayWeight = 0.10
    static let durationWeight = 0.15
    static let priorWeight = 0.10

    /// Serializes snapshot scoring so capture and imports can hop off the
    /// main actor without duplicating the formula.
    actor Service {
        func resolve(
            visit: VisitSnapshot,
            places: [PlaceSnapshot],
            calendar: Calendar
        ) -> Resolution {
            PlaceLearningEngine.resolve(visit: visit, places: places, calendar: calendar)
        }
    }

    /// Sendable view of a visit used by the pure scorer.
    struct VisitSnapshot: Equatable, Sendable {
        var id: UUID
        var latitude: Double
        var longitude: Double
        var horizontalAccuracy: Double
        var arrivalDate: Date
        var departureDate: Date?
        var assignmentSource: PlaceAssignmentSource

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var stayDuration: TimeInterval? {
            guard let departureDate, departureDate > arrivalDate else { return nil }
            return departureDate.timeIntervalSince(arrivalDate)
        }

        init(
            id: UUID = UUID(),
            latitude: Double,
            longitude: Double,
            horizontalAccuracy: Double,
            arrivalDate: Date,
            departureDate: Date?,
            assignmentSource: PlaceAssignmentSource = .none
        ) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.horizontalAccuracy = horizontalAccuracy
            self.arrivalDate = arrivalDate
            self.departureDate = departureDate
            self.assignmentSource = assignmentSource
        }

        init(_ visit: VisitPlace) {
            self.init(
                id: visit.id,
                latitude: visit.latitude,
                longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate,
                assignmentSource: visit.assignmentSource
            )
        }
    }

    /// Sendable view of a learned place used by the pure scorer.
    struct PlaceSnapshot: Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        var centerLatitude: Double
        var centerLongitude: Double
        var footprintRadius: Double
        var confirmedVisitCount: Int
        var arrivalHourHistogram: [Int]
        var weekdayHistogram: [Int]
        var stayDurationSamples: [Double]
        var rejectedAutoLabels: [String]

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
        }

        init(
            id: UUID = UUID(),
            name: String,
            centerLatitude: Double,
            centerLongitude: Double,
            footprintRadius: Double,
            confirmedVisitCount: Int = 0,
            arrivalHourHistogram: [Int] = Array(repeating: 0, count: 24),
            weekdayHistogram: [Int] = Array(repeating: 0, count: 7),
            stayDurationSamples: [Double] = [],
            rejectedAutoLabels: [String] = []
        ) {
            self.id = id
            self.name = name
            self.centerLatitude = centerLatitude
            self.centerLongitude = centerLongitude
            self.footprintRadius = footprintRadius
            self.confirmedVisitCount = confirmedVisitCount
            self.arrivalHourHistogram = arrivalHourHistogram
            self.weekdayHistogram = weekdayHistogram
            self.stayDurationSamples = stayDurationSamples
            self.rejectedAutoLabels = rejectedAutoLabels
        }

        init(_ place: KnownPlace) {
            self.init(
                id: place.id,
                name: place.name,
                centerLatitude: place.centerLatitude,
                centerLongitude: place.centerLongitude,
                footprintRadius: place.footprintRadius,
                confirmedVisitCount: place.confirmedVisitCount,
                arrivalHourHistogram: place.arrivalHourHistogram,
                weekdayHistogram: place.weekdayHistogram,
                stayDurationSamples: place.stayDurationSamples,
                rejectedAutoLabels: place.rejectedAutoLabels
            )
        }
    }

    /// One candidate's breakdown. Exposed so tests and later UI can show why.
    struct ScoredCandidate: Equatable, Sendable, Identifiable {
        var placeID: UUID
        var distance: CLLocationDistance
        var proximity: Double
        var hourAffinity: Double
        var weekdayAffinity: Double
        var durationAffinity: Double
        var prior: Double
        var score: Double

        var id: UUID { placeID }
    }

    /// Outcome of matching a visit to nearby learned places.
    struct Resolution: Equatable, Sendable {
        var source: PlaceAssignmentSource
        var placeID: UUID?
        var runnerUpPlaceID: UUID?
        var confidence: Double
        var scores: [ScoredCandidate]
        var reviewState: ReviewState

        static let unassigned = Resolution(
            source: .none,
            placeID: nil,
            runnerUpPlaceID: nil,
            confidence: 0,
            scores: [],
            reviewState: .none
        )
    }

    /// Center, radius, and occupancy rebuilt from confirmed visits.
    struct Footprint: Equatable, Sendable {
        var centerLatitude: Double
        var centerLongitude: Double
        var footprintRadius: Double
        var arrivalHourHistogram: [Int]
        var weekdayHistogram: [Int]
        var stayDurationSamples: [Double]
        var confirmedVisitCount: Int
        var lastVisitAt: Date?
    }

    // MARK: - Scoring

    /// Distance gate: `footprintRadius + max(accuracy, 20) + 15`.
    static func candidateDistanceLimit(
        footprintRadius: CLLocationDistance,
        horizontalAccuracy: CLLocationDistance
    ) -> CLLocationDistance {
        footprintRadius + max(horizontalAccuracy, accuracyFloor) + candidatePadding
    }

    /// Ranks `places` whose centers fall inside the candidate gate, then
    /// applies the auto / chooser rule.
    static func resolve(
        visit: VisitSnapshot,
        places: [PlaceSnapshot],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Resolution {
        guard visit.assignmentSource != .user else {
            return .unassigned
        }

        let scored = scoredCandidates(visit: visit, places: places, calendar: calendar)
        switch scored.count {
        case 0:
            return .unassigned
        case 1:
            let winner = scored[0]
            let accuracy = max(visit.horizontalAccuracy, accuracyFloor)
            let radius = places.first(where: { $0.id == winner.placeID })?.footprintRadius ?? 40
            let raw = 1 - winner.distance / max(radius + accuracy, 1)
            let confidence = min(1, max(0.5, raw))
            return Resolution(
                source: .auto,
                placeID: winner.placeID,
                runnerUpPlaceID: nil,
                confidence: confidence,
                scores: scored,
                reviewState: .none
            )
        default:
            let top = scored[0]
            let second = scored[1]
            let margin = top.score - second.score
            if margin >= autoAssignMargin {
                return Resolution(
                    source: .auto,
                    placeID: top.placeID,
                    runnerUpPlaceID: second.placeID,
                    confidence: min(1, max(0.5, margin + 0.5)),
                    scores: scored,
                    reviewState: .none
                )
            }
            return Resolution(
                source: .autoAmbiguous,
                placeID: top.placeID,
                runnerUpPlaceID: second.placeID,
                confidence: min(1, max(0, top.score)),
                scores: scored,
                reviewState: .pending
            )
        }
    }

    /// Convenience for SwiftData models.
    static func resolve(
        visit: VisitPlace,
        knownPlaces: [KnownPlace],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Resolution {
        resolve(
            visit: VisitSnapshot(visit),
            places: knownPlaces.map(PlaceSnapshot.init),
            calendar: calendar
        )
    }

    /// Scores every place inside the candidate gate, highest first.
    static func scoredCandidates(
        visit: VisitSnapshot,
        places: [PlaceSnapshot],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ScoredCandidate] {
        let origin = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let accuracy = max(visit.horizontalAccuracy, accuracyFloor)
        let hour = calendar.component(.hour, from: visit.arrivalDate)
        let weekday = clampedWeekdayIndex(calendar.component(.weekday, from: visit.arrivalDate))
        let duration = visit.stayDuration

        let gated: [(PlaceSnapshot, CLLocationDistance)] = places.compactMap { place in
            let distance = origin.distance(
                from: CLLocation(latitude: place.centerLatitude, longitude: place.centerLongitude)
            )
            let limit = candidateDistanceLimit(
                footprintRadius: place.footprintRadius,
                horizontalAccuracy: visit.horizontalAccuracy
            )
            guard distance <= limit else { return nil }
            return (place, distance)
        }

        let priorTotal = max(gated.reduce(0) { $0 + max($1.0.confirmedVisitCount, 0) }, 1)

        let scored = gated.map { place, distance -> ScoredCandidate in
            let denom = max(place.footprintRadius + accuracy, 1)
            let proximity = min(1, max(0, 1 - distance / denom))
            let hourAffinity = normalizedSmoothedHistogram(
                place.arrivalHourHistogram,
                index: hour,
                binCount: 24
            )
            let weekdayAffinity = normalizedSmoothedHistogram(
                place.weekdayHistogram,
                index: weekday,
                binCount: 7
            )
            let durationAffinity = durationLikelihood(
                stayDuration: duration,
                samples: place.stayDurationSamples
            )
            let prior = Double(max(place.confirmedVisitCount, 0)) / Double(priorTotal)
            let score =
                proximityWeight * proximity
                + hourWeight * hourAffinity
                + weekdayWeight * weekdayAffinity
                + durationWeight * durationAffinity
                + priorWeight * prior
            return ScoredCandidate(
                placeID: place.id,
                distance: distance,
                proximity: proximity,
                hourAffinity: hourAffinity,
                weekdayAffinity: weekdayAffinity,
                durationAffinity: durationAffinity,
                prior: prior,
                score: score
            )
        }

        return scored.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-12 {
                return lhs.score > rhs.score
            }
            if abs(lhs.distance - rhs.distance) > 0.01 {
                return lhs.distance < rhs.distance
            }
            return lhs.placeID.uuidString < rhs.placeID.uuidString
        }
    }

    // MARK: - Apply / learn / negatives

    /// Writes assignment flags onto `visit`. Never mutates the `KnownPlace`.
    static func apply(
        _ resolution: Resolution,
        to visit: VisitPlace,
        knownPlaces: [KnownPlace]
    ) {
        guard visit.assignmentSource != .user else { return }
        // A retired stay joined to a place would show in that place's visits.
        guard !TimelineRetirement.isRetired(visit) else { return }
        guard resolution.source == .auto || resolution.source == .autoAmbiguous else { return }
        guard let placeID = resolution.placeID,
              let place = knownPlaces.first(where: { $0.id == placeID })
        else { return }

        visit.knownPlace = place
        visit.assignmentSource = resolution.source
        visit.assignmentConfidence = min(max(resolution.confidence, 0), 1)
        if resolution.source == .autoAmbiguous,
           visit.reviewState != .confirmed,
           visit.reviewState != .dismissed {
            visit.reviewState = .pending
        }
    }

    /// Rebuilds `place`'s footprint from user-confirmed visits. No-ops when
    /// `visit` is not a `.user` assignment to this place.
    ///
    /// A stored center or radius the earlier confirmed visits do not produce was set on
    /// purpose (a moved pin, a shrink), so it stays. A kept radius grows only as far as
    /// this visit needs.
    static func learn(
        from visit: VisitPlace,
        onto place: KnownPlace,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        learn(fromBatch: [visit], onto: place, calendar: calendar)
    }

    /// `learn(from:onto:)` for many stays the person confirmed at once: the footprint is
    /// rebuilt once, not once per stay, and "earlier" means the confirmed stays from
    /// before this batch.
    static func learn(
        fromBatch batch: [VisitPlace],
        onto place: KnownPlace,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let joined = batch.filter { $0.assignmentSource == .user && $0.knownPlace?.id == place.id }
        guard !joined.isEmpty else { return }
        let joinedIDs = Set(joined.map(\.id))
        let visits = confirmedVisits(on: place, including: joined)
        var footprint = learnedFootprint(from: visits, calendar: calendar)
        let earlier = visits.filter { !joinedIDs.contains($0.id) }
        if !earlier.isEmpty {
            let rebuilt = learnedFootprint(from: earlier, calendar: calendar)
            let rebuiltCenter = CLLocationCoordinate2D(
                latitude: rebuilt.centerLatitude,
                longitude: rebuilt.centerLongitude
            )
            if distance(from: place.coordinate, to: rebuiltCenter) > handSetCenterTolerance {
                footprint.centerLatitude = place.centerLatitude
                footprint.centerLongitude = place.centerLongitude
            }
            if abs(place.footprintRadius - rebuilt.footprintRadius) > handSetRadiusTolerance {
                let center = CLLocationCoordinate2D(
                    latitude: footprint.centerLatitude,
                    longitude: footprint.centerLongitude
                )
                let reach = (joined.map { distance(from: center, to: $0.coordinate) }.max() ?? 0)
                    * radiusGrowthFactor
                footprint.footprintRadius = max(place.footprintRadius, reach)
            }
        }
        apply(footprint, to: place)
    }

    /// Pure footprint math. `visits` must already be the confirmed set.
    static func learnedFootprint(
        from visits: [VisitSnapshot],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Footprint {
        let ordered = visits.sorted { $0.arrivalDate > $1.arrivalDate }
        let forGeometry = Array(ordered.prefix(maxVisitsForFootprint))
        let count = ordered.count
        let lastVisitAt = ordered.first?.arrivalDate

        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        for visit in ordered {
            let hour = min(max(calendar.component(.hour, from: visit.arrivalDate), 0), 23)
            hours[hour] += 1
            weekdays[clampedWeekdayIndex(calendar.component(.weekday, from: visit.arrivalDate))] += 1
        }

        let durations: [Double] = ordered.compactMap { visit in
            guard let duration = visit.stayDuration, duration > 0 else { return nil }
            return duration
        }
        let staySamples = Array(durations.prefix(maxStayDurationSamples))

        guard !forGeometry.isEmpty else {
            return Footprint(
                centerLatitude: 0,
                centerLongitude: 0,
                footprintRadius: minimumFootprintRadius,
                arrivalHourHistogram: hours,
                weekdayHistogram: weekdays,
                stayDurationSamples: staySamples,
                confirmedVisitCount: count,
                lastVisitAt: lastVisitAt
            )
        }

        let centerLatitude = forGeometry.map(\.latitude).reduce(0, +) / Double(forGeometry.count)
        let centerLongitude = forGeometry.map(\.longitude).reduce(0, +) / Double(forGeometry.count)
        let center = CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
        let distances = forGeometry.map { distance(from: center, to: $0.coordinate) }
        let radius = clampRadius(footprintReach(distances) * radiusGrowthFactor)

        return Footprint(
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            footprintRadius: radius,
            arrivalHourHistogram: hours,
            weekdayHistogram: weekdays,
            stayDurationSamples: staySamples,
            confirmedVisitCount: count,
            lastVisitAt: lastVisitAt
        )
    }

    static func apply(_ footprint: Footprint, to place: KnownPlace) {
        place.centerLatitude = footprint.centerLatitude
        place.centerLongitude = footprint.centerLongitude
        place.footprintRadius = clampRadius(footprint.footprintRadius)
        place.arrivalHourHistogram = footprint.arrivalHourHistogram
        place.weekdayHistogram = footprint.weekdayHistogram
        place.stayDurationSamples = footprint.stayDurationSamples
        place.confirmedVisitCount = footprint.confirmedVisitCount
        place.lastVisitAt = footprint.lastVisitAt
    }

    /// Records a rejected geocoder name on the destination and shrinks the
    /// source footprint after three contained corrections away from it.
    static func applyNegatives(
        event: PlaceCorrectionEvent,
        fromPlace: KnownPlace?,
        toPlace: KnownPlace?,
        priorEventsFromPlace: [PlaceCorrectionEvent]
    ) {
        if let toPlace {
            appendRejectedAutoLabel(event.fromAutoLabel, to: toPlace)
        }

        guard let fromPlace else { return }
        if let toPlace, toPlace.id == fromPlace.id { return }

        let eventCoordinate = CLLocationCoordinate2D(latitude: event.latitude, longitude: event.longitude)
        guard distance(from: fromPlace.coordinate, to: eventCoordinate) <= fromPlace.footprintRadius else {
            return
        }

        let previousContained = priorEventsFromPlace.filter { prior in
            let coordinate = CLLocationCoordinate2D(latitude: prior.latitude, longitude: prior.longitude)
            return distance(from: fromPlace.coordinate, to: coordinate) <= fromPlace.footprintRadius
        }
        let containedCount = previousContained.count + 1
        if containedCount > 0, containedCount % negativeEventsBeforeShrink == 0 {
            fromPlace.footprintRadius = clampRadius(fromPlace.footprintRadius * radiusShrinkFactor)
        }
    }

    /// Reassigns `source`'s visits onto `destination` and rebuilds occupancy
    /// from confirmed visits. Caller deletes `source`. Used by Places tab (WS7).
    static func merge(
        _ source: KnownPlace,
        into destination: KnownPlace,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let sourceVisits = source.visits
        for visit in sourceVisits {
            visit.knownPlace = destination
        }

        var rejected = destination.rejectedAutoLabels
        let existing = Set(rejected.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for label in source.rejectedAutoLabels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existing.contains(trimmed.lowercased()) else { continue }
            rejected.append(trimmed)
        }
        destination.rejectedAutoLabels = rejected

        if (destination.category?.isEmpty ?? true), let category = source.category, !category.isEmpty {
            destination.category = category
        }
        if destination.countryCode == nil { destination.countryCode = source.countryCode }
        if destination.locality == nil { destination.locality = source.locality }
        if destination.administrativeArea == nil { destination.administrativeArea = source.administrativeArea }

        let confirmed = destination.visits
            .filter { $0.assignmentSource == .user }
            .map(VisitSnapshot.init)
        // With no confirmed visits there is nothing to learn from; an empty footprint
        // would move the destination to (0, 0).
        guard !confirmed.isEmpty else { return }
        apply(learnedFootprint(from: confirmed, calendar: calendar), to: destination)
    }

    /// Geocoder / search names the user has rejected at nearby learned places.
    static func suppressedAutoLabels(from places: [KnownPlace]) -> Set<String> {
        Set(
            places
                .flatMap { place in
                    place.rejectedAutoLabels.filter { !isSameName($0, place.name) }
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    static func shouldSuppress(_ label: String, nearbyPlaces: [KnownPlace]) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if suppressedAutoLabels(from: nearbyPlaces).contains(trimmed.lowercased()) { return true }
        // Compare the way every other label comparison does, so "135-137 X" stays
        // rejected once it is written as "135–137 X".
        let key = PlaceDisplayNamer.labelComparisonKey(trimmed)
        return nearbyPlaces.contains { place in
            place.rejectedAutoLabels.contains { rejected in
                !isSameName(rejected, place.name) && PlaceDisplayNamer.labelComparisonKey(rejected) == key
            }
        }
    }

    static func clampRadius(_ radius: CLLocationDistance) -> CLLocationDistance {
        min(maximumFootprintRadius, max(minimumFootprintRadius, radius))
    }

    static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    // MARK: - Internals

    /// ±1-bin smoothing, then divide by the peak so the mode is 1. Empty
    /// histograms are a neutral 0.5 so they do not drown proximity.
    static func normalizedSmoothedHistogram(_ values: [Int], index: Int, binCount: Int) -> Double {
        var bins = Array(repeating: 0, count: binCount)
        for (offset, value) in values.enumerated() where offset < binCount {
            bins[offset] = max(value, 0)
        }
        guard bins.contains(where: { $0 > 0 }) else { return 0.5 }

        func smoothed(_ i: Int) -> Double {
            let prev = bins[(i - 1 + binCount) % binCount]
            let current = bins[i]
            let next = bins[(i + 1) % binCount]
            return Double(prev + current + next)
        }

        let smoothedBins = (0..<binCount).map(smoothed)
        let peak = smoothedBins.max() ?? 0
        guard peak > 0 else { return 0.5 }
        let clampedIndex = min(max(index, 0), binCount - 1)
        return smoothedBins[clampedIndex] / peak
    }

    /// Likelihood of `stayDuration` under the place's samples. Unknown
    /// departure or an empty history is a neutral 0.5.
    static func durationLikelihood(stayDuration: TimeInterval?, samples: [Double]) -> Double {
        guard let stayDuration, stayDuration > 0 else { return 0.5 }
        let positive = samples.filter { $0 > 0 }
        guard !positive.isEmpty else { return 0.5 }

        let mean = positive.reduce(0, +) / Double(positive.count)
        let variance = positive.reduce(0) { partial, sample in
            let delta = sample - mean
            return partial + delta * delta
        } / Double(positive.count)
        let sigma = max(sqrt(variance), 15 * 60)
        let z = (stayDuration - mean) / sigma
        return exp(-0.5 * z * z)
    }

    static func percentile(_ values: [CLLocationDistance], _ p: Double) -> CLLocationDistance {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((p * Double(sorted.count - 1)).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }

    static func clampedWeekdayIndex(_ calendarWeekday: Int) -> Int {
        min(max(calendarWeekday - 1, 0), 6)
    }

    private static func appendRejectedAutoLabel(_ label: String?, to place: KnownPlace) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        // Keeping the suggested name is accepting it, not rejecting it.
        guard !isSameName(trimmed, place.name) else { return }
        let existing = place.rejectedAutoLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if existing.contains(trimmed.lowercased()) { return }
        place.rejectedAutoLabels.append(trimmed)
    }

    static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        PlaceDisplayNamer.labelComparisonKey(lhs) == PlaceDisplayNamer.labelComparisonKey(rhs)
    }

    private static func confirmedVisits(on place: KnownPlace, including joined: [VisitPlace]) -> [VisitSnapshot] {
        var snapshots = place.visits
            .filter { $0.assignmentSource == .user }
            .map(VisitSnapshot.init)
        var seen = Set(snapshots.map(\.id))
        for visit in joined where visit.assignmentSource == .user && seen.insert(visit.id).inserted {
            snapshots.append(VisitSnapshot(visit))
        }
        return snapshots
    }
}

// MARK: - Place identity: one real place, one name

extension PlaceLearningEngine {
    /// Below this many visits a footprint reaches the farthest one; above it, the 90th
    /// percentile, so one stray centre in a long history cannot stretch it.
    static let smallFootprintSampleCount = 30

    /// Two stays are the same spot within `40 m + max(their accuracies)`, never past 100 m.
    static let sameSpotBaseDistance: CLLocationDistance = 40
    static let sameSpotMaximumDistance: CLLocationDistance = 100
    /// A cluster grown stay by stay stays within this of the stay it grew from, so a
    /// chain of stops along one street cannot swallow the neighbours.
    static let clusterRadius: CLLocationDistance = 150
    /// Fixes vaguer than this say little about where in a building someone was.
    static let robustCenterAccuracyLimit: CLLocationAccuracy = 50

    /// Plain values of one stay, for label reuse and clustering.
    struct StaySnapshot: Equatable, Sendable, Identifiable {
        var id: UUID
        var latitude: Double
        var longitude: Double
        var horizontalAccuracy: Double
        var arrivalDate: Date
        var departureDate: Date?
        /// The automatic label the stay shows, if any.
        var label: String?

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// Time spent there. Open or instant stays still count for a minute.
        var weight: TimeInterval {
            guard let departureDate else { return 60 }
            return max(departureDate.timeIntervalSince(arrivalDate), 60)
        }

        init(
            id: UUID = UUID(),
            latitude: Double,
            longitude: Double,
            horizontalAccuracy: Double,
            arrivalDate: Date,
            departureDate: Date?,
            label: String?
        ) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.horizontalAccuracy = horizontalAccuracy
            self.arrivalDate = arrivalDate
            self.departureDate = departureDate
            self.label = label
        }

        init(_ visit: VisitPlace, label: String?) {
            self.init(
                id: visit.id,
                latitude: visit.latitude,
                longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate,
                label: label
            )
        }
    }

    /// How far apart two stays can be and still be the same spot.
    static func sameSpotDistance(
        _ lhsAccuracy: CLLocationAccuracy,
        _ rhsAccuracy: CLLocationAccuracy
    ) -> CLLocationDistance {
        min(sameSpotBaseDistance + max(max(lhsAccuracy, 0), max(rhsAccuracy, 0)), sameSpotMaximumDistance)
    }

    static func isSameSpot(_ lhs: StaySnapshot, _ rhs: StaySnapshot) -> Bool {
        distance(from: lhs.coordinate, to: rhs.coordinate)
            <= sameSpotDistance(lhs.horizontalAccuracy, rhs.horizontalAccuracy)
    }

    /// The automatic label to reuse for `target`: among other stays at the same spot,
    /// the label under which the most time was spent, ties to the most recent. Nil when
    /// nothing nearby has one, and the caller geocodes.
    static func reusableLabel(
        for target: StaySnapshot,
        among others: [StaySnapshot],
        isSuppressed: (String) -> Bool = { _ in false }
    ) -> String? {
        let nearby = others.filter { other in
            other.id != target.id
                && PlaceDisplayNamer.meaningful(other.label) != nil
                && isSameSpot(target, other)
        }
        return dominantLabel(among: nearby, isSuppressed: isSuppressed)
    }

    /// Time-weighted winning label among `stays`, written in its readable form.
    static func dominantLabel(
        among stays: [StaySnapshot],
        isSuppressed: (String) -> Bool = { _ in false }
    ) -> String? {
        struct Tally {
            var weight: TimeInterval = 0
            var latest: Date = .distantPast
            var label = ""
        }
        var tallies: [String: Tally] = [:]
        for stay in stays {
            guard let raw = PlaceDisplayNamer.meaningful(stay.label) else { continue }
            let label = PlaceDisplayNamer.normalizedAutomaticLabel(raw)
            guard !isSuppressed(label) else { continue }
            let key = PlaceDisplayNamer.labelComparisonKey(label)
            var tally = tallies[key] ?? Tally()
            tally.weight += stay.weight
            if stay.arrivalDate >= tally.latest {
                tally.latest = stay.arrivalDate
                tally.label = label
            }
            tallies[key] = tally
        }
        return tallies
            .sorted { lhs, rhs in
                if abs(lhs.value.weight - rhs.value.weight) > 0.5 { return lhs.value.weight > rhs.value.weight }
                if lhs.value.latest != rhs.value.latest { return lhs.value.latest > rhs.value.latest }
                return lhs.key < rhs.key
            }
            .first?
            .value
            .label
    }

    /// Stays reachable from `seed` one same-spot step at a time, all within
    /// `clusterRadius` of it. The seed itself is not returned.
    static func cluster(
        around seed: StaySnapshot,
        among candidates: [StaySnapshot],
        radius: CLLocationDistance = clusterRadius
    ) -> [StaySnapshot] {
        cluster(around: [seed], among: candidates, radius: radius)
    }

    /// Stays reachable from any of `seeds` one same-spot step at a time, each within
    /// `radius` of some seed. Seeds are not returned. Naming a thousand stays at once
    /// grows one cluster from all of them instead of a thousand overlapping ones.
    static func cluster(
        around seeds: [StaySnapshot],
        among candidates: [StaySnapshot],
        radius: CLLocationDistance = clusterRadius
    ) -> [StaySnapshot] {
        guard !seeds.isEmpty else { return [] }
        let seedIDs = Set(seeds.map(\.id))
        // A box around the seeds first, so the per-seed distance test only sees stays near them.
        let latitudeSpan = radius / 111_320
        let minLatitude = seeds.map(\.latitude).min()! - latitudeSpan
        let maxLatitude = seeds.map(\.latitude).max()! + latitudeSpan
        let longitudeSpan = radius / max(111_320 * cos(max(abs(minLatitude), abs(maxLatitude)) * .pi / 180), 1)
        let minLongitude = seeds.map(\.longitude).min()! - longitudeSpan
        let maxLongitude = seeds.map(\.longitude).max()! + longitudeSpan
        var remaining = candidates.filter { candidate in
            guard !seedIDs.contains(candidate.id),
                  candidate.latitude >= minLatitude, candidate.latitude <= maxLatitude,
                  candidate.longitude >= minLongitude, candidate.longitude <= maxLongitude
            else { return false }
            return seeds.contains { distance(from: $0.coordinate, to: candidate.coordinate) <= radius }
        }
        var members: [StaySnapshot] = []
        var frontier = seeds
        while let current = frontier.popLast() {
            var index = 0
            while index < remaining.count {
                if isSameSpot(current, remaining[index]) {
                    let joined = remaining.remove(at: index)
                    members.append(joined)
                    frontier.append(joined)
                } else {
                    index += 1
                }
            }
        }
        return members
    }

    /// One label per real place across history: each cluster grows from its longest stay
    /// and every member takes the cluster's time-weighted label. Returns only the stays
    /// whose label changes, so running it again on its own result changes nothing.
    static func unifiedLabels(
        for stays: [StaySnapshot],
        isSuppressed: (String, CLLocationCoordinate2D) -> Bool = { _, _ in false }
    ) -> [UUID: String] {
        let labeled = stays.filter { PlaceDisplayNamer.meaningful($0.label) != nil }
        let ordered = labeled.sorted { lhs, rhs in
            if abs(lhs.weight - rhs.weight) > 0.5 { return lhs.weight > rhs.weight }
            if lhs.arrivalDate != rhs.arrivalDate { return lhs.arrivalDate < rhs.arrivalDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var claimed = Set<UUID>()
        var changes: [UUID: String] = [:]
        for anchor in ordered where !claimed.contains(anchor.id) {
            let unclaimed = ordered.filter { !claimed.contains($0.id) }
            let members = [anchor] + cluster(around: anchor, among: unclaimed)
            for member in members { claimed.insert(member.id) }
            guard let label = dominantLabel(
                among: members,
                isSuppressed: { isSuppressed($0, anchor.coordinate) }
            ) else { continue }
            for member in members where member.label != label {
                changes[member.id] = label
            }
        }
        return changes
    }

    /// Per-axis median of the stay's own fixes no vaguer than 50 m. Nil with fewer than
    /// two such fixes, and the caller keeps its earlier rule.
    static func robustCenter(
        of fixes: [(latitude: Double, longitude: Double, accuracy: Double)]
    ) -> CLLocationCoordinate2D? {
        let good = fixes.filter { $0.accuracy >= 0 && $0.accuracy <= robustCenterAccuracyLimit }
        guard good.count >= 2 else { return nil }
        return CLLocationCoordinate2D(
            latitude: median(good.map(\.latitude)),
            longitude: median(good.map(\.longitude))
        )
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// How far the footprint must reach. Small histories reach their farthest visit so
    /// every visit assigned to the place stays inside it.
    static func footprintReach(_ distances: [CLLocationDistance]) -> CLLocationDistance {
        guard !distances.isEmpty else { return 0 }
        if distances.count <= smallFootprintSampleCount {
            return distances.max() ?? 0
        }
        return percentile(distances, 0.9)
    }

    // MARK: Duplicate confirmed places

    struct DuplicateCandidate: Equatable, Sendable {
        var id: UUID
        var name: String
        var latitude: Double
        var longitude: Double
        var footprintRadius: Double
        var createdAt: Date

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        init(id: UUID, name: String, latitude: Double, longitude: Double, footprintRadius: Double, createdAt: Date) {
            self.id = id
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.footprintRadius = footprintRadius
            self.createdAt = createdAt
        }

        init(_ place: KnownPlace) {
            self.init(
                id: place.id,
                name: place.name,
                latitude: place.centerLatitude,
                longitude: place.centerLongitude,
                footprintRadius: place.footprintRadius,
                createdAt: place.createdAt
            )
        }
    }

    /// Places that are certainly one place: the same name once folded, with centres
    /// inside the larger footprint. Each maps to the earliest-created twin, so every
    /// device picks the same survivor. Anything less certain is left for the person.
    static func duplicateMerges(_ places: [DuplicateCandidate]) -> [(source: UUID, destination: UUID)] {
        let ordered = places.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var keepers: [DuplicateCandidate] = []
        var merges: [(source: UUID, destination: UUID)] = []
        for place in ordered {
            let key = PlaceDisplayNamer.labelComparisonKey(place.name)
            let keeper = keepers.first { keeper in
                !key.isEmpty
                    && PlaceDisplayNamer.labelComparisonKey(keeper.name) == key
                    && distance(from: keeper.coordinate, to: place.coordinate)
                        <= max(keeper.footprintRadius, place.footprintRadius)
            }
            if let keeper {
                merges.append((place.id, keeper.id))
            } else {
                keepers.append(place)
            }
        }
        return merges
    }
}

/// Coordinates sorted into a grid, so "everything within reach of here" reads a few cells
/// instead of all of history.
///
/// `indices(near:)` returns every coordinate within `reach` and some a little beyond it;
/// the caller still measures. Years of stays compared pair by pair is tens of millions of
/// distances, which is what this avoids.
struct CoordinateBuckets: Sendable {
    private struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    /// Shorter than any degree of latitude, so a cell is never narrower than `reach`.
    private static let metersPerDegree = 110_000.0
    /// Near the poles a cell spans most of the way round; past this many columns, read all.
    private static let widestColumnSpan = 64

    private let cellDegrees: Double
    private let columnCount: Int
    private let count: Int
    private var cells: [Cell: [Int]] = [:]

    init(_ coordinates: [CLLocationCoordinate2D], reach: CLLocationDistance) {
        cellDegrees = max(reach, 1) / Self.metersPerDegree
        columnCount = max(1, Int((360 / cellDegrees).rounded(.up)))
        count = coordinates.count
        for (index, coordinate) in coordinates.enumerated() {
            cells[cell(for: coordinate), default: []].append(index)
        }
    }

    /// Indices of the coordinates that may lie within `reach` of `coordinate`, ascending.
    func indices(near coordinate: CLLocationCoordinate2D) -> [Int] {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return Array(0..<count) }
        let center = cell(for: coordinate)
        let steepestLatitude = min(abs(coordinate.latitude) + cellDegrees, 90) * .pi / 180
        let shrink = cos(steepestLatitude)
        guard shrink > 0.001 else { return Array(0..<count) }
        // One column more than the arithmetic asks for: the last column before the
        // antimeridian is narrower than the rest.
        let columnReach = Int((1 / shrink).rounded(.up)) + 1
        guard 2 * columnReach + 1 <= Self.widestColumnSpan, 2 * columnReach + 1 < columnCount else {
            return Array(0..<count)
        }
        var found: [Int] = []
        for row in (center.row - 1)...(center.row + 1) {
            for offset in -columnReach...columnReach {
                let column = ((center.column + offset) % columnCount + columnCount) % columnCount
                if let members = cells[Cell(row: row, column: column)] {
                    found.append(contentsOf: members)
                }
            }
        }
        return found.sorted()
    }

    private func cell(for coordinate: CLLocationCoordinate2D) -> Cell {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return Cell(row: 0, column: 0) }
        let latitude = max(-90, min(90, coordinate.latitude))
        let longitude = max(-360, min(360, coordinate.longitude))
        let row = Int((latitude / cellDegrees).rounded(.down))
        let column = Int(((longitude + 180) / cellDegrees).rounded(.down))
        return Cell(row: row, column: ((column % columnCount) + columnCount) % columnCount)
    }
}
