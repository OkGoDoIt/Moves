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
        guard visit.assignmentSource == .user else { return }
        guard visit.knownPlace?.id == place.id else { return }
        let visits = confirmedVisits(on: place, including: visit)
        var footprint = learnedFootprint(from: visits, calendar: calendar)
        let earlier = visits.filter { $0.id != visit.id }
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
                let reach = distance(from: center, to: visit.coordinate) * radiusGrowthFactor
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
        let radius = clampRadius(percentile(distances, 0.9) * radiusGrowthFactor)

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
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return suppressedAutoLabels(from: nearbyPlaces).contains(trimmed)
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

    private static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            rhs.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private static func confirmedVisits(on place: KnownPlace, including visit: VisitPlace) -> [VisitSnapshot] {
        var snapshots = place.visits
            .filter { $0.assignmentSource == .user }
            .map(VisitSnapshot.init)
        if visit.assignmentSource == .user,
           !snapshots.contains(where: { $0.id == visit.id }) {
            snapshots.append(VisitSnapshot(visit))
        }
        return snapshots
    }
}
