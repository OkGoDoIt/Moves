import CoreLocation
import Foundation

/// A stop reconstructed from sparse GPS fixes.
///
/// Visit monitoring often closes a stay while the phone is still there, and it
/// often never opens one for a stop that significant-location fixes did see.
/// `departureDate` is nil when the latest fix is still inside the stop and
/// nothing has shown the phone leaving.
struct SampleStay: Equatable {
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    /// Best (smallest) horizontal accuracy of the fixes that belong to the stop, in metres.
    var horizontalAccuracy: Double
    /// Timestamp of the last fix that was still inside the stop.
    var lastInsideDate: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// When the stop is known to have ended. Open stops report the last inside fix.
    var presenceEnd: Date {
        departureDate ?? lastInsideDate
    }
}

/// Turns the live, low-power fix stream into stops.
///
/// Significant-location delivery is the opposite of a route log: fixes arrive
/// while the phone is moving, then go quiet for the whole time it stays put.
/// A stop is therefore either
///
/// - several fixes that remain inside `stayRadius` for at least
///   `minimumStayDuration`, or
/// - a fix followed by a long gap whose next fix is still close enough that
///   the gap cannot have been travel (a few hundred metres over a couple of
///   hours is someone staying, not someone walking).
///
/// Fixes worse than `maximumHorizontalAccuracy`, and single fixes that jump
/// away and straight back, are dropped before clustering so one bad visit
/// callback cannot punch a hole in a real stop.
enum SampleStayInference {
    struct Configuration: Sendable, Equatable {
        /// Fixes inside this distance of the running centre belong to the stop.
        var stayRadius: CLLocationDistance = 160
        /// Shortest presence that counts as a stop.
        var minimumStayDuration: TimeInterval = 10 * 60
        /// A gap slower than this, and shorter than `maximumStillGap`, is presence.
        /// Kept well under a slow walk so a couple of blocks is a trip, while a
        /// phone sitting overnight (a few hundred metres over many hours) is not.
        var maximumStillSpeed: CLLocationSpeed = 0.2
        /// Silence longer than this is not assumed to be the same stop.
        var maximumStillGap: TimeInterval = 14 * 60 * 60
        /// A later fix farther than this is travel, however slow the average looks.
        var maximumStillGapDistance: CLLocationDistance = 1_200
        /// Fixes worse than this are ignored. Cell-tower fallbacks are often 1 km.
        var maximumHorizontalAccuracy: CLLocationDistance = 250
        /// A fix this far from both neighbours is a spike when those neighbours agree.
        var spikeDistance: CLLocationDistance = 1_500
        /// Neighbours closer than this count as "the same place" for spike rejection.
        var spikeNeighborDistance: CLLocationDistance = 350

        init() {}
    }

    /// Fixes worth trusting for stops and for move distance.
    static func reliablePoints(
        from points: [LocationLogPoint],
        configuration: Configuration = Configuration()
    ) -> [LocationLogPoint] {
        var filtered = points.filter { point in
            CLLocationCoordinate2DIsValid(point.coordinate)
                && !(point.latitude == 0 && point.longitude == 0)
                && (point.horizontalAccuracy ?? 0) >= 0
                && (point.horizontalAccuracy ?? 0) <= configuration.maximumHorizontalAccuracy
        }
        filtered.sort { $0.timestamp < $1.timestamp }

        var deduped: [LocationLogPoint] = []
        deduped.reserveCapacity(filtered.count)
        for point in filtered {
            if let last = deduped.last, point.timestamp.timeIntervalSince(last.timestamp) < 1 {
                let lastAccuracy = last.horizontalAccuracy ?? .greatestFiniteMagnitude
                let accuracy = point.horizontalAccuracy ?? .greatestFiniteMagnitude
                if accuracy < lastAccuracy {
                    deduped[deduped.count - 1] = point
                }
                continue
            }
            deduped.append(point)
        }

        guard deduped.count >= 3 else { return deduped }

        var kept: [LocationLogPoint] = []
        kept.reserveCapacity(deduped.count)
        for index in deduped.indices {
            let point = deduped[index]
            if index > 0, index < deduped.count - 1 {
                let previous = deduped[index - 1]
                let next = deduped[index + 1]
                let fromPrevious = point.distance(to: previous)
                let toNext = point.distance(to: next)
                let span = previous.distance(to: next)
                if fromPrevious >= configuration.spikeDistance,
                   toNext >= configuration.spikeDistance,
                   span <= configuration.spikeNeighborDistance {
                    continue
                }
            }
            kept.append(point)
        }
        return kept
    }

    /// Stops implied by `points`. `now` decides whether the trailing stop is still open.
    static func stays(
        from points: [LocationLogPoint],
        now: Date,
        configuration: Configuration = Configuration()
    ) -> [SampleStay] {
        // A fix taken while moving says where someone passed, not where they stayed: left
        // in, a dense walk drags a stop's centre and times along with it.
        let fixes = TravelEvidence.stationary(reliablePoints(from: points, configuration: configuration))
        guard !fixes.isEmpty else { return [] }

        var stays: [SampleStay] = []
        var index = 0

        while index < fixes.count {
            var memberIndexes = [index]
            var latitudeSum = fixes[index].latitude
            var longitudeSum = fixes[index].longitude
            var cursor = index + 1
            var leftAt: Date?

            while cursor < fixes.count {
                let count = Double(memberIndexes.count)
                let centre = CLLocationCoordinate2D(
                    latitude: latitudeSum / count,
                    longitude: longitudeSum / count
                )
                let candidate = fixes[cursor]
                let distance = LocationLogGeometry.distance(from: centre, to: candidate.coordinate)

                if distance <= configuration.stayRadius {
                    memberIndexes.append(cursor)
                    latitudeSum += candidate.latitude
                    longitudeSum += candidate.longitude
                    cursor += 1
                    continue
                }

                let anchor = fixes[memberIndexes[memberIndexes.count - 1]]
                let gap = candidate.timestamp.timeIntervalSince(anchor.timestamp)
                let speed = distance / max(gap, 1)
                // A couple of blocks in a few minutes is the walk after a bus,
                // not the stop continuing. Significant-change delivery often
                // has no fix in between, so the average speed looks very low.
                let isLastBlockWalk = LastBlockWalk.isShape(distance: distance, duration: gap)
                if !isLastBlockWalk,
                   gap >= configuration.minimumStayDuration,
                   gap <= configuration.maximumStillGap,
                   distance <= configuration.maximumStillGapDistance,
                   speed <= configuration.maximumStillSpeed {
                    leftAt = candidate.timestamp
                }
                break
            }

            let members = memberIndexes.map { fixes[$0] }
            let arrival = members[0].timestamp
            let lastInside = members[members.count - 1].timestamp
            let insideDuration = lastInside.timeIntervalSince(arrival)
            // Dense fixes that keep moving are a walk winding within the radius, not a
            // dwell: a meandering walk's fixes stay near their own running mean for minutes.
            let stayedByCluster = members.count >= 2 && insideDuration >= configuration.minimumStayDuration
                && !TravelEvidence.isTravel(members.map { ($0.timestamp, $0.coordinate) }, from: arrival, to: lastInside)
            let stayedByStillGap = leftAt.map { $0.timeIntervalSince(arrival) >= configuration.minimumStayDuration } ?? false

            if stayedByCluster || stayedByStillGap {
                let count = Double(members.count)
                let accuracy = members.compactMap(\.horizontalAccuracy).min() ?? configuration.stayRadius
                let departure: Date?
                if let leftAt {
                    departure = leftAt
                } else if cursor >= fixes.count {
                    let silence = now.timeIntervalSince(lastInside)
                    departure = silence > configuration.maximumStillGap ? lastInside : nil
                } else {
                    departure = lastInside
                }

                stays.append(
                    SampleStay(
                        arrivalDate: arrival,
                        departureDate: departure,
                        latitude: latitudeSum / count,
                        longitude: longitudeSum / count,
                        horizontalAccuracy: accuracy,
                        lastInsideDate: lastInside
                    )
                )
                index = leftAt == nil ? memberIndexes[memberIndexes.count - 1] + 1 : cursor
            } else {
                index += 1
            }
        }

        return stays
    }
}

/// Whether dense fixes show someone travelling rather than staying.
///
/// Over each minute of fixes, a phone that is still moves no more than its jitter (a few
/// tens of metres at worst); a walk covers 60–90 m. When most of a stretch is minutes like
/// that, it is travel. Sparse fixes (minutes apart) never count as moving.
enum TravelEvidence {
    static let window: TimeInterval = 60
    static let maximumWindow: TimeInterval = 120
    static let movingDisplacement: CLLocationDistance = 40
    /// No single gap counts for more than this, so one late fix cannot carry a stretch.
    static let maximumStep: TimeInterval = 30
    static let travelShare = 0.5
    /// A fix after a silence this long is where the phone sat through it, however fast it
    /// moves next. Capture goes quiet at a stop and wakes on the way out, so the first fix
    /// back is taken as the person sets off; dropped as travel, it would leave the silence
    /// without the nearby fix that makes it a stop.
    static let silenceBeforeDeparture: TimeInterval = 10 * 60

    /// `points` without the fixes taken while moving: those whose next minute of fixes
    /// moved at least `movingDisplacement`, or whose previous minute did. Sparse fixes stay,
    /// and so does the first fix after `silenceBeforeDeparture`.
    static func stationary(_ points: [LocationLogPoint]) -> [LocationLogPoint] {
        guard points.count >= 3 else { return points }
        var moving = [Bool](repeating: false, count: points.count)
        var ahead = 0
        for index in points.indices {
            let time = points[index].timestamp
            if ahead <= index { ahead = index + 1 }
            while ahead < points.count, points[ahead].timestamp.timeIntervalSince(time) < window { ahead += 1 }
            guard ahead < points.count, points[ahead].timestamp.timeIntervalSince(time) <= maximumWindow else { continue }
            if LocationLogGeometry.distance(from: points[index].coordinate, to: points[ahead].coordinate) >= movingDisplacement {
                // The minute was travel: every fix in it. The fix that ends it may be the
                // first one at the destination, so it is judged by its own minute.
                for marked in index..<ahead { moving[marked] = true }
            }
        }
        for index in points.indices.dropFirst()
        where points[index].timestamp.timeIntervalSince(points[index - 1].timestamp) >= silenceBeforeDeparture {
            moving[index] = false
        }
        return points.indices.filter { !moving[$0] }.map { points[$0] }
    }

    /// `points` sorted by time.
    static func isTravel(
        _ points: [(timestamp: Date, coordinate: CLLocationCoordinate2D)],
        from start: Date,
        to end: Date
    ) -> Bool {
        let span = end.timeIntervalSince(start)
        guard span > 0, points.count >= 3 else { return false }
        var moving: TimeInterval = 0
        var ahead = 0
        for index in points.indices.dropLast() {
            let time = points[index].timestamp
            if ahead <= index { ahead = index + 1 }
            while ahead < points.count, points[ahead].timestamp.timeIntervalSince(time) < window { ahead += 1 }
            guard ahead < points.count, points[ahead].timestamp.timeIntervalSince(time) <= maximumWindow else { continue }
            let step = min(points[index + 1].timestamp.timeIntervalSince(time), maximumStep)
            if LocationLogGeometry.distance(from: points[index].coordinate, to: points[ahead].coordinate) >= movingDisplacement {
                moving += step
            }
        }
        return moving >= travelShare * span
    }
}

/// A ride the motion sensors read as walking.
///
/// Phones in a pocket on a motorbike or in traffic can report walking for a whole trip.
/// Steps tell them apart: a real walk runs near 100 steps a minute even when its start
/// and end times are sloppy enough to make the speed look wrong.
///
/// `stepCount` is nil when there is no step data (older than the pedometer's
/// seven days, imported, or a failed query). Zero is a measurement: nobody walked.
enum ImplausibleWalk {
    /// Steps a minute under which a trip at riding pace did not move anyone's feet.
    /// Scooters in city traffic run 4–7 m/s with a few false steps a minute.
    static let ridingStepsPerMinute: Double = 30
    /// Steps a minute under which a "walk" or "run" was not on foot.
    static let footStepsPerMinute: Double = 25
    static let ridingSpeedRange: ClosedRange<CLLocationSpeed> = 2.5...9
    static let ridingMinimumDistance: CLLocationDistance = 800
    static let footMinimumDuration: TimeInterval = 5 * 60
    static let footMinimumDistance: CLLocationDistance = 300

    /// - Parameter distance: The trip's measured distance when known (its path); the pace
    ///   rule reads it. Defaults to the straight line.
    static func refinedMode(
        proposed: TransportMode,
        straightLine: CLLocationDistance,
        distance: CLLocationDistance? = nil,
        duration: TimeInterval,
        stepCount: Int?,
        dominantActivity: TransportMode? = nil,
        locations: [CLLocation]
    ) -> TransportMode {
        let refined = stepAndSpeedMode(
            proposed: proposed, straightLine: straightLine, duration: duration,
            stepCount: stepCount, dominantActivity: dominantActivity, locations: locations
        )
        return ImplausibleFootPace.mode(
            proposed: refined,
            distance: max(distance ?? straightLine, straightLine),
            duration: duration,
            stepCount: stepCount,
            dominantActivity: dominantActivity
        ) ?? refined
    }

    private static func stepAndSpeedMode(
        proposed: TransportMode,
        straightLine: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?,
        dominantActivity: TransportMode?,
        locations: [CLLocation]
    ) -> TransportMode {
        if let fromSteps = stepEvidenceMode(
            proposed: proposed,
            straightLine: straightLine,
            duration: duration,
            stepCount: stepCount,
            dominantActivity: dominantActivity
        ) {
            return fromSteps
        }
        let changed = mode(proposed: proposed, straightLine: straightLine, duration: duration, stepCount: stepCount)
        guard changed != proposed else { return proposed }
        // Speed alone (and a middling step rate) needs the fixes to show the pace:
        // sloppy start and end times make a walk look fast.
        let threshold: Double = proposed == .running ? 6 : 3.5
        guard TransportSpeedEvidence(locations: locations).supportsSpeed(above: threshold, tripDuration: duration)
        else { return proposed }
        return changed
    }

    /// The mode measured steps decide on their own, or nil when steps do not settle it.
    ///
    /// - A foot label with almost no steps over a real distance was a ride when it was
    ///   at riding pace, and is unresolved when it was slow.
    /// - Riding pace with few steps over a kilometre is a motor vehicle, unless Core
    ///   Motion's own dominant reading was cycling (a bicycle has no steps either).
    static func stepEvidenceMode(
        proposed: TransportMode,
        straightLine: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?,
        dominantActivity: TransportMode? = nil
    ) -> TransportMode? {
        guard let stepCount, duration > 0 else { return nil }
        let rate = Double(stepCount) / (duration / 60)
        let speed = straightLine / duration
        let cycledByMotion = dominantActivity == .cycling

        if proposed == .walking || proposed == .running,
           rate < footStepsPerMinute,
           duration >= footMinimumDuration,
           straightLine >= footMinimumDistance {
            if cycledByMotion { return .unknown }
            return speed >= ridingSpeedRange.lowerBound ? .automotive : .unknown
        }

        switch proposed {
        case .walking, .running, .unknown, .stationary:
            break
        case .automotive, .train, .plane, .boat, .cycling, .swimming:
            return nil
        }
        // A few minutes is too short to trust the pace: sloppy start and end times
        // make a walk look fast.
        if rate < ridingStepsPerMinute,
           ridingSpeedRange.contains(speed),
           straightLine >= ridingMinimumDistance,
           duration >= footMinimumDuration,
           !cycledByMotion {
            return .automotive
        }
        return nil
    }

    static func mode(
        proposed: TransportMode,
        straightLine: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?
    ) -> TransportMode {
        guard straightLine >= 800, duration > 0 else { return proposed }
        let speed = straightLine / duration

        guard proposed == .walking || proposed == .running, speed >= 2.5 else { return proposed }
        // Too fast for this walk does not identify a bicycle, so moderate-speed
        // travel with a middling step rate stays unresolved.
        let ride: TransportMode = speed >= 9 ? .automotive : .unknown

        if let stepCount {
            return Double(stepCount) / (duration / 60) < 50 ? ride : proposed
        }
        // No step data, as in an imported log. Only a sustained pace rules out feet.
        let fastestOnFoot: CLLocationSpeed = proposed == .running ? 6 : 3.5
        return speed >= fastestOnFoot && duration >= 5 * 60 ? ride : proposed
    }
}

/// A pace nobody keeps on foot.
///
/// Needs no steps, so it also settles imported history and trips older than the
/// pedometer's week: a "run" above 15 km/h for over 20 minutes (world-class marathon
/// pace is about 20 km/h) or longer than 25 km, and a "walk" above 9 km/h for over 15
/// minutes, were not on foot. A vehicle's pace becomes automotive; anything slower stays
/// unresolved unless Core Motion itself read cycling. A measured walking step rate keeps
/// the label: then the times, not the feet, are wrong.
enum ImplausibleFootPace {
    static let runningMaximumSpeed: CLLocationSpeed = 15 / 3.6
    static let runningSustainedDuration: TimeInterval = 20 * 60
    static let runningMaximumDistance: CLLocationDistance = 25_000
    static let walkingMaximumSpeed: CLLocationSpeed = 9 / 3.6
    static let walkingSustainedDuration: TimeInterval = 15 * 60
    /// Above this, a vehicle (the shared speed bucket for driving).
    static let vehicleSpeed: CLLocationSpeed = 9
    /// A step rate at or above this is someone on foot.
    static let onFootStepsPerMinute: Double = 50

    /// The mode a foot label's pace rules out, or nil when the label stands.
    static func mode(
        proposed: TransportMode,
        distance: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?,
        dominantActivity: TransportMode? = nil
    ) -> TransportMode? {
        guard duration > 0, distance > 0 else { return nil }
        if let stepCount, Double(stepCount) / (duration / 60) >= onFootStepsPerMinute { return nil }
        let speed = distance / duration
        switch proposed {
        case .running:
            guard (speed > runningMaximumSpeed && duration > runningSustainedDuration)
                    || distance > runningMaximumDistance
            else { return nil }
        case .walking:
            guard speed > walkingMaximumSpeed, duration > walkingSustainedDuration else { return nil }
        case .automotive, .train, .plane, .boat, .cycling, .swimming, .stationary, .unknown:
            return nil
        }
        if speed >= vehicleSpeed { return .automotive }
        return dominantActivity == .cycling ? .cycling : .unknown
    }
}

/// Every automatic step-and-distance rule a trip's mode goes through, in order.
/// Shared by new trips and the checks on stored ones, so a pass never relabels a
/// trip that the next pass would relabel back.
enum StepModeRules {
    static func refinedMode(
        proposed: TransportMode,
        straightLine: CLLocationDistance,
        distance: CLLocationDistance? = nil,
        duration: TimeInterval,
        stepCount: Int?,
        dominantActivity: TransportMode? = nil,
        locations: [CLLocation]
    ) -> TransportMode {
        ImplausibleWalk.refinedMode(
            proposed: LastBlockWalk.mode(
                proposed: proposed,
                distance: straightLine,
                duration: duration,
                stepCount: stepCount
            ),
            straightLine: straightLine,
            distance: distance,
            duration: duration,
            stepCount: stepCount,
            dominantActivity: dominantActivity,
            locations: locations
        )
    }
}

/// Distance for a walk whose fixes cannot draw it.
///
/// Two or fewer fixes between the stops make the straight path a floor, not a
/// measurement. Steps are the better ruler when the pedometer counted them.
enum OnFootDistanceEstimate {
    static let defaultStride: CLLocationDistance = 0.75
    static let noStepsDetour = 1.2
    static let maximumDetour = 3.0
    static let detourAllowance: CLLocationDistance = 300
    static let maximumInteriorFixes = 2

    static func applies(mode: TransportMode, interiorFixCount: Int) -> Bool {
        (mode == .walking || mode == .running) && interiorFixCount <= maximumInteriorFixes
    }

    static func distance(
        straightLine: CLLocationDistance,
        stepCount: Int?,
        stride: CLLocationDistance = defaultStride
    ) -> CLLocationDistance {
        guard let stepCount, stepCount > 0 else {
            return (straightLine * noStepsDetour).rounded()
        }
        let walked = Double(stepCount) * stride
        let ceiling = straightLine * maximumDetour + detourAllowance
        return min(max(walked, straightLine), ceiling).rounded()
    }
}

/// Where the fixes say a stop really began and ended.
///
/// Visit monitoring's own arrival and departure are often minutes (or hours) off,
/// and a stop that ends exactly when the next begins has swallowed the trip between
/// them. These rules only ever shorten a stop, and applying them twice gives the
/// same answer, so a rebuild on its own output changes nothing.
enum StopBoundaryEvidence {
    /// A good fix farther than this from the centre is outside the stop.
    static let outsideDistance: CLLocationDistance = 100
    /// Only fixes at least this good count as outside.
    static let maximumOutsideAccuracy: CLLocationAccuracy = 50
    /// A fix within max(this, 2 × its accuracy) of the centre is still there.
    static let minimumInsideRadius: CLLocationDistance = 60
    static let maximumInsideAccuracy: CLLocationAccuracy = 250
    /// One outside fix is enough when the pedometer shows walking since the last inside one.
    static let walkingStepsPerMinute: Double = 40
    static let minimumWalkingSteps = 20
    /// Pace assumed for a trip no fix recorded.
    static let assumedWalkingSpeed: CLLocationSpeed = 1.3
    static let jumpMaximumGap: TimeInterval = 60
    static let jumpMinimumDistance: CLLocationDistance = 120
    static let jumpMinimumTrip: TimeInterval = 2 * 60
    static let jumpMaximumTrip: TimeInterval = 30 * 60

    struct Fix: Equatable {
        var timestamp: Date
        var coordinate: CLLocationCoordinate2D
        var horizontalAccuracy: CLLocationAccuracy

        static func == (lhs: Fix, rhs: Fix) -> Bool {
            lhs.timestamp == rhs.timestamp
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.horizontalAccuracy == rhs.horizontalAccuracy
        }
    }

    typealias StepLookup = (Date, Date) -> Int?

    static func isInside(_ fix: Fix, centre: CLLocationCoordinate2D) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maximumInsideAccuracy else { return false }
        return LocationLogGeometry.distance(from: centre, to: fix.coordinate)
            <= max(minimumInsideRadius, 2 * fix.horizontalAccuracy)
    }

    static func isOutside(_ fix: Fix, centre: CLLocationCoordinate2D) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maximumOutsideAccuracy else { return false }
        return LocationLogGeometry.distance(from: centre, to: fix.coordinate) > outsideDistance
    }

    /// The last fix still at the stop, when fixes after it show the person left
    /// before `departure`. Nil when the departure stands.
    ///
    /// Indoor wander puts single fixes outside a building; leaving takes two
    /// consecutive good fixes outside, or one plus steps at a walking rate.
    static func trimmedDeparture(
        centre: CLLocationCoordinate2D,
        arrival: Date,
        departure: Date,
        fixes: [Fix],
        steps: StepLookup
    ) -> Date? {
        let window = fixes.filter { $0.timestamp > arrival && $0.timestamp <= departure }
        guard let lastInside = window.lastIndex(where: { isInside($0, centre: centre) }) else { return nil }
        let anchor = window[lastInside].timestamp
        guard anchor < departure else { return nil }
        let after = Array(window[(lastInside + 1)...])
        guard showsAbsence(after, anchor: anchor, centre: centre, steps: steps, anchorIsBefore: true) else { return nil }
        return anchor
    }

    /// The first fix at the stop, when fixes before it show the person had not yet
    /// arrived at `arrival`. Nil when the arrival stands.
    static func trimmedArrival(
        centre: CLLocationCoordinate2D,
        arrival: Date,
        departure: Date?,
        fixes: [Fix],
        steps: StepLookup
    ) -> Date? {
        let end = departure ?? .distantFuture
        let window = fixes.filter { $0.timestamp >= arrival && $0.timestamp < end }
        guard let firstInside = window.firstIndex(where: { isInside($0, centre: centre) }) else { return nil }
        let anchor = window[firstInside].timestamp
        guard anchor > arrival else { return nil }
        let before = Array(window[..<firstInside].reversed())
        guard showsAbsence(before, anchor: anchor, centre: centre, steps: steps, anchorIsBefore: false) else { return nil }
        return anchor
    }

    /// `ordered` runs away from `anchor` (forward after a departure, backward before an arrival).
    private static func showsAbsence(
        _ ordered: [Fix],
        anchor: Date,
        centre: CLLocationCoordinate2D,
        steps: StepLookup,
        anchorIsBefore: Bool
    ) -> Bool {
        for (first, second) in zip(ordered, ordered.dropFirst())
        where isOutside(first, centre: centre) && isOutside(second, centre: centre) {
            return true
        }
        guard let outside = ordered.first(where: { isOutside($0, centre: centre) }) else { return false }
        let start = anchorIsBefore ? anchor : outside.timestamp
        let end = anchorIsBefore ? outside.timestamp : anchor
        guard end > start, let count = steps(start, end) else { return false }
        let minutes = max(end.timeIntervalSince(start) / 60, 1)
        return count >= minimumWalkingSteps && Double(count) / minutes >= walkingStepsPerMinute
    }

    /// When the trip between two stops that touch, far apart, most likely began.
    ///
    /// The later of the last fix at the first stop and the time a walk at
    /// `assumedWalkingSpeed` needs, clamped to a 2–30 minute trip, never before the
    /// first stop's arrival.
    static func jumpTripStart(
        firstArrival: Date,
        nextArrival: Date,
        distance: CLLocationDistance,
        lastOnSite: Date?
    ) -> Date {
        // A whole number of seconds for the walk: the same stop seen from a shorter window
        // must land on the same value, not one a fraction of a second away.
        var start = nextArrival.addingTimeInterval(-(distance / assumedWalkingSpeed).rounded())
        if let lastOnSite { start = max(start, lastOnSite) }
        start = min(start, nextArrival.addingTimeInterval(-jumpMinimumTrip))
        start = max(start, nextArrival.addingTimeInterval(-jumpMaximumTrip))
        return max(start, firstArrival)
    }
}

/// Pedometer answers for the stay rebuild, which runs synchronously on the store.
///
/// The rebuild asks for intervals; unanswered ones read as unknown and are listed in
/// `wanted` so the caller can query them and run the rebuild again. Answers are kept
/// (an unknown answer too), so later passes ask nothing and decide the same way.
final class ReconcileStepEvidence {
    private struct Key: Hashable {
        let start: Int
        let end: Int
    }

    private var answers: [Key: Int?] = [:]
    private var wantedKeys: Set<Key> = []
    private(set) var wanted: [DateInterval] = []

    init() {}

    private static func key(_ start: Date, _ end: Date) -> Key {
        Key(start: Int(start.timeIntervalSince1970.rounded()), end: Int(end.timeIntervalSince1970.rounded()))
    }

    func steps(from start: Date, to end: Date) -> Int? {
        guard end > start else { return nil }
        let key = Self.key(start, end)
        if let answer = answers[key] { return answer }
        if wantedKeys.insert(key).inserted {
            wanted.append(DateInterval(start: start, end: end))
        }
        return nil
    }

    func record(_ steps: Int?, for interval: DateInterval) {
        let key = Self.key(interval.start, interval.end)
        answers[key] = .some(steps)
        wantedKeys.remove(key)
        wanted.removeAll { Self.key($0.start, $0.end) == key }
    }

    func takeWanted() -> [DateInterval] {
        defer {
            wanted.removeAll()
            wantedKeys.removeAll()
        }
        return wanted
    }

    /// Drops answers for intervals that ended before `date`.
    func forget(before date: Date) {
        let cutoff = Int(date.timeIntervalSince1970)
        answers = answers.filter { $0.key.end >= cutoff }
    }
}

/// The shape of "got off a ride and walked the last couple of blocks."
///
/// Low-power fixes often have nothing between the kerb and the door, so the
/// gap looks like a very slow stay. Distance and duration are enough to tell
/// it from a phone that did not move for hours.
enum LastBlockWalk {
    static let minimumDistance: CLLocationDistance = 70
    static let maximumDistance: CLLocationDistance = 450
    /// Long enough that a doorway jitter is not a trip.
    static let minimumDuration: TimeInterval = 60
    /// Longer than this, the same distance is someone staying, not walking a block.
    static let maximumDuration: TimeInterval = 20 * 60

    static func isShape(distance: CLLocationDistance, duration: TimeInterval) -> Bool {
        distance >= minimumDistance
            && distance <= maximumDistance
            && duration >= minimumDuration
            && duration <= maximumDuration
    }

    /// Mode for a last-block gap. A bus that then crawls has almost no steps;
    /// the walk off that bus does.
    static func mode(
        proposed: TransportMode,
        distance: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?
    ) -> TransportMode {
        guard isShape(distance: distance, duration: duration) else { return proposed }
        let speed = distance / max(duration, 1)
        guard speed < 1.8 else { return proposed }

        if let stepCount {
            if stepCount >= 60 { return .walking }
            if stepCount == 0, proposed == .automotive || proposed == .train {
                return proposed
            }
        }

        switch proposed {
        case .automotive, .train, .unknown, .stationary:
            return .walking
        case .walking, .running, .cycling, .swimming, .plane, .boat:
            return proposed
        }
    }
}
