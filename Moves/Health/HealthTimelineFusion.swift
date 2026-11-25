import Foundation

// Pure rules that combine Apple Health activity with the timeline.
//
// Nothing here touches SwiftData or HealthKit: every input is a plain value read
// beforehand, so each rule can be tested on its own. Health totals are evidence,
// never verdicts. iPhone pedometer distance can be 10–40% off, so a well-recorded
// GPS path always wins, and steps inside a stay never become a trip.

// MARK: - Values

/// Why a Health reading could not be used. None of these mean zero.
enum HealthUnknownReason: String, Codable, Sendable, CaseIterable {
    /// Protected data is unreadable while the device is locked.
    case locked
    /// Limited-history access: the interval starts before the authorized window.
    case beforeAuthorizedWindow
    /// No samples matched. Read access is opaque, so this also covers "denied".
    case noData
    /// Health is not available on this device.
    case unavailable
    /// Any other query failure.
    case queryFailed
}

/// A Health total that distinguishes a measured value from an unknown one.
enum HealthValue: Equatable, Codable, Sendable {
    case value(Double)
    case unknown(HealthUnknownReason)

    var known: Double? {
        if case .value(let value) = self { return value }
        return nil
    }

    var unknownReason: HealthUnknownReason? {
        if case .unknown(let reason) = self { return reason }
        return nil
    }
}

/// Five-minute (or other) slice of merged Health activity. A shape, not a precise
/// timeline: iPhone samples span minutes and are spread evenly across buckets.
struct HealthBucket: Equatable, Codable, Sendable {
    var start: Date
    var end: Date
    var steps: Double
    var meters: Double

    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

enum HealthBucketsResult: Equatable, Sendable {
    case buckets([HealthBucket])
    case unknown(HealthUnknownReason)

    var buckets: [HealthBucket]? {
        if case .buckets(let buckets) = self { return buckets }
        return nil
    }
}

struct HealthCoordinate: Equatable, Codable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// One stored location fix, copied out of the store.
struct HealthFix: Equatable, Codable, Sendable {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double

    var coordinate: HealthCoordinate { HealthCoordinate(latitude: latitude, longitude: longitude) }
}

enum HealthGeo {
    /// Great-circle distance in metres.
    static func meters(_ a: HealthCoordinate, _ b: HealthCoordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    static func pathLength(_ coordinates: [HealthCoordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }
}

/// A trip as the fusion rules see it.
struct HealthTripFacts: Equatable, Sendable {
    var id: UUID
    var start: Date
    var end: Date
    var mode: TransportMode
    /// The stored trip distance (GPS path or matched route), in metres.
    var distanceMeters: Double
    var startCoordinate: HealthCoordinate?
    var endCoordinate: HealthCoordinate?
    /// Stored fixes, oldest first.
    var fixes: [HealthFix]
    /// Same guard as automatic stay repair: auto mode, sensor origin, not reviewed,
    /// no manual route, no comment, no workout route.
    var permitsModeChange: Bool
    /// Sensor trip with no manual path, no imported fixes, and no workout route.
    var permitsDistanceCorrection: Bool
    /// Pedometer steps stamped when the trip was recorded, when there are any.
    var pedometerSteps: Int?
    /// Length of the cached matched route, when one is cached.
    var matchedRouteMeters: Double?
    var sampleCount: Int

    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }

    var isOnFootMode: Bool { mode == .walking || mode == .running }

    /// Straight line between the stops, falling back to the first and last fix.
    var straightLineMeters: Double? {
        if let startCoordinate, let endCoordinate {
            return HealthGeo.meters(startCoordinate, endCoordinate)
        }
        guard let first = fixes.first, let last = fixes.last, fixes.count > 1 else { return nil }
        return HealthGeo.meters(first.coordinate, last.coordinate)
    }
}

struct HealthStayFacts: Equatable, Sendable {
    var id: UUID
    var arrival: Date
    var departure: Date

    var duration: TimeInterval { max(departure.timeIntervalSince(arrival), 0) }
}

// MARK: - Recording quality

/// How densely a trip's own fixes describe its path.
struct HealthRecordingQuality: Equatable, Sendable {
    static let maximumAccuracy: Double = 100
    static let minimumPath: Double = 300
    static let minimumDuration: TimeInterval = 3 * 60
    static let maximumAverageSpacing: Double = 30
    static let maximumGap: Double = 150

    var pathLength: Double
    var averageSpacing: Double
    var largestGap: Double
    var fixCount: Int

    init(fixes: [HealthFix]) {
        let usable = fixes
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Self.maximumAccuracy }
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.coordinate)
        let steps = zip(usable, usable.dropFirst()).map { HealthGeo.meters($0.0, $0.1) }
        pathLength = steps.reduce(0, +)
        largestGap = steps.max() ?? 0
        averageSpacing = steps.isEmpty ? .infinity : pathLength / Double(steps.count)
        fixCount = usable.count
    }

    /// Dense enough to trust the GPS path over pedometer distance.
    var isDense: Bool {
        fixCount >= 3 && averageSpacing <= Self.maximumAverageSpacing && largestGap <= Self.maximumGap
    }

    /// A walk the stride calibration and the distance rules may treat as ground truth.
    func isWellRecordedWalk(_ trip: HealthTripFacts) -> Bool {
        trip.isOnFootMode
            && pathLength >= Self.minimumPath
            && trip.duration >= Self.minimumDuration
            && isDense
    }
}

// MARK: - Stride calibration

/// k = GPS path ÷ Health distance, learned from well-recorded walks.
struct HealthStrideCalibration: Equatable, Codable, Sendable {
    static let minimumWalks = 8
    static let range: ClosedRange<Double> = 0.7...1.3
    static let identity = HealthStrideCalibration(k: 1, sampleCount: 0)

    var k: Double
    /// Walks the median was taken over (or collected so far, while uncalibrated).
    var sampleCount: Int

    var isCalibrated: Bool { sampleCount >= Self.minimumWalks }

    /// GPS ÷ Health for one walk, or nil when it cannot be a calibration sample.
    static func ratio(
        trip: HealthTripFacts,
        quality: HealthRecordingQuality,
        healthDistance: HealthValue
    ) -> Double? {
        guard quality.isWellRecordedWalk(trip),
              let health = healthDistance.known, health > 0 else { return nil }
        let ratio = quality.pathLength / health
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    static func calibrate(ratios: [Double]) -> HealthStrideCalibration {
        let valid = ratios.filter { $0.isFinite && $0 > 0 }.sorted()
        guard valid.count >= minimumWalks else {
            return HealthStrideCalibration(k: 1, sampleCount: valid.count)
        }
        let middle = valid.count / 2
        let median = valid.count.isMultiple(of: 2) ? (valid[middle - 1] + valid[middle]) / 2 : valid[middle]
        return HealthStrideCalibration(
            k: min(max(median, range.lowerBound), range.upperBound),
            sampleCount: valid.count
        )
    }
}

// MARK: - Walk distance

enum HealthWalkDistanceDecision: Equatable, Sendable {
    case apply(meters: Double)
    case keep(HealthWalkDistanceKeepReason)
}

enum HealthWalkDistanceKeepReason: String, Equatable, Sendable {
    case notOnFoot
    case notEligible
    case wellRecorded
    case unknownHealth
    case noSteps
    case shorterThanStraightLine
    case implausiblyLong
    case unchanged
}

enum HealthWalkDistance {
    static let straightLineFloor = 0.9
    static let routeCeiling = 3.0
    static let noRouteAllowance: Double = 300

    /// A distance for a poorly recorded walk, or why the stored one stays.
    /// - Parameter originalDistance: The trip's distance before any Health
    ///   correction, so a re-run with a new k derives from the same base.
    static func decide(
        trip: HealthTripFacts,
        quality: HealthRecordingQuality,
        originalDistance: Double,
        calibration: HealthStrideCalibration,
        healthDistance: HealthValue,
        steps: HealthValue
    ) -> HealthWalkDistanceDecision {
        guard trip.isOnFootMode else { return .keep(.notOnFoot) }
        guard trip.permitsDistanceCorrection else { return .keep(.notEligible) }
        guard !quality.isWellRecordedWalk(trip) else { return .keep(.wellRecorded) }
        guard let health = healthDistance.known, health > 0 else { return .keep(.unknownHealth) }
        guard let stepCount = steps.known, stepCount > 0 else { return .keep(.noSteps) }

        let candidate = calibration.k * health
        let straight = trip.straightLineMeters ?? 0
        guard candidate >= straightLineFloor * straight else { return .keep(.shorterThanStraightLine) }
        let ceiling = originalDistance > 0
            ? routeCeiling * originalDistance
            : routeCeiling * straight + noRouteAllowance
        guard candidate <= ceiling else { return .keep(.implausiblyLong) }
        // Small differences are not worth a write (or a CloudKit round trip).
        guard abs(candidate - originalDistance) >= max(20, originalDistance * 0.05) else {
            return .keep(.unchanged)
        }
        return .apply(meters: candidate.rounded())
    }
}

// MARK: - Mode evidence

/// A vote from steps, never a verdict on its own.
enum HealthModeVote: String, Codable, Equatable, Sendable {
    case notOnFoot
    case onFoot
}

enum HealthModeEvidence {
    static let minimumDuration: TimeInterval = 3 * 60
    static let minimumNotOnFootDistance: Double = 400
    /// Below this, a "walk" did not move anyone's feet. Bumpy roads and scooters
    /// produce some false steps, but far fewer than a real walk's ~100 a minute.
    static let notOnFootStepsPerMinute: Double = 15
    static let onFootStepsPerMinute: Double = 70
    static let onFootMaximumSpeed: Double = 2
    /// Share of the trip that must sit in walking-rate buckets.
    static let onFootCoverage: Double = 0.6
    static let vehicleSpeed: Double = 9
    static let unresolvedRideSpeed: Double = 3
    static let unresolvedRideStepsPerMinute: Double = 25

    static func stepsPerMinute(steps: Double, duration: TimeInterval) -> Double {
        duration > 0 ? steps / (duration / 60) : 0
    }

    /// - Parameters:
    ///   - steps: Merged steps over the trip (known).
    ///   - buckets: Bucketed steps covering the trip; used only for the on-foot vote.
    static func vote(trip: HealthTripFacts, steps: Double, buckets: [HealthBucket]) -> HealthModeVote? {
        let duration = trip.duration
        guard duration > minimumDuration else { return nil }
        let rate = stepsPerMinute(steps: steps, duration: duration)
        let distance = max(trip.distanceMeters, trip.straightLineMeters ?? 0)

        let speed = distance / duration

        switch trip.mode {
        case .walking, .running:
            guard distance > minimumNotOnFootDistance, rate < notOnFootStepsPerMinute else { return nil }
            return .notOnFoot
        case .automotive, .unknown:
            if speed < onFootMaximumSpeed, rate > onFootStepsPerMinute,
               walkingCoverage(of: trip, buckets: buckets) >= onFootCoverage {
                return .onFoot
            }
            // An unresolved trip at riding pace with few steps (a scooter in city
            // traffic). Driving with no steps is already right, so no vote there.
            if trip.mode == .unknown, distance > minimumNotOnFootDistance,
               speed >= unresolvedRideSpeed, rate < unresolvedRideStepsPerMinute {
                return .notOnFoot
            }
            return nil
        case .stationary, .swimming, .cycling, .train, .plane, .boat:
            return nil
        }
    }

    /// Share of the trip's time covered by buckets at a walking step rate.
    static func walkingCoverage(of trip: HealthTripFacts, buckets: [HealthBucket]) -> Double {
        let duration = trip.duration
        guard duration > 0 else { return 0 }
        let covered = buckets.reduce(0.0) { total, bucket in
            guard bucket.duration > 0,
                  stepsPerMinute(steps: bucket.steps, duration: bucket.duration) > onFootStepsPerMinute
            else { return total }
            let overlap = min(bucket.end, trip.end).timeIntervalSince(max(bucket.start, trip.start))
            return total + max(overlap, 0)
        }
        return min(covered / duration, 1)
    }

    /// The mode a vote leads to, or nil when nothing should change.
    /// A ride ruled out as a walk becomes driving only when clearly fast; otherwise
    /// it is left unresolved for the person to name.
    static func proposedMode(
        for trip: HealthTripFacts,
        vote: HealthModeVote,
        preferences: AutomaticTransportModes
    ) -> TransportMode? {
        guard trip.permitsModeChange else { return nil }
        let proposed: TransportMode
        switch (vote, trip.mode) {
        case (.notOnFoot, .walking), (.notOnFoot, .running):
            let distance = max(trip.distanceMeters, trip.straightLineMeters ?? 0)
            let speed = trip.duration > 0 ? distance / trip.duration : 0
            proposed = speed >= vehicleSpeed ? .automotive : .unknown
        case (.onFoot, .automotive), (.onFoot, .unknown):
            proposed = .walking
        default:
            return nil
        }
        let allowed = preferences.allowedMode(proposed)
        return allowed == trip.mode ? nil : allowed
    }
}

// MARK: - Step evidence seam

/// Health's step evidence for one trip, handed to the automatic-mode rules.
///
/// `MoveSegment.stepCount` stores 0 both for "no steps" and for "no pedometer data"
/// (older than seven days, imported). This keeps the two apart: `steps` is
/// `.value(0)` only when Health answered for the trip's interval inside a day it has
/// data for; anything else is `.unknown`.
struct HealthStepEvidence: Equatable, Codable, Sendable {
    var steps: HealthValue
    var stepsPerMinute: Double?
    var vote: HealthModeVote?

    init(steps: HealthValue, duration: TimeInterval, vote: HealthModeVote?) {
        self.steps = steps
        self.stepsPerMinute = steps.known.map { HealthModeEvidence.stepsPerMinute(steps: $0, duration: duration) }
        self.vote = vote
    }

    /// The step count the existing classifiers should read: Health's merged total
    /// when known, else the stored pedometer value. Existing rules treat 0 as "no
    /// data", so a Health 0 changes nothing there; `vote` carries that evidence.
    func classifierStepCount(stored: Int?) -> Int? {
        steps.known.map { Int($0.rounded()) } ?? stored
    }
}

// MARK: - Stays and days

/// Walking inside a stay, for display only.
struct HealthStayWalking: Equatable, Codable, Sendable {
    static let minimumStayDuration: TimeInterval = 20 * 60
    static let displayThreshold: Double = 400

    var stayID: UUID
    var steps: Int
    var walkedMeters: Double

    var isWorthShowing: Bool { walkedMeters >= Self.displayThreshold }

    static func summarize(
        stay: HealthStayFacts,
        steps: HealthValue,
        distance: HealthValue,
        calibration: HealthStrideCalibration
    ) -> HealthStayWalking? {
        guard stay.duration >= minimumStayDuration,
              let steps = steps.known, let distance = distance.known else { return nil }
        return HealthStayWalking(
            stayID: stay.id,
            steps: Int(steps.rounded()),
            walkedMeters: (calibration.k * distance).rounded()
        )
    }
}

/// One timeline day's Health totals. A nil field is unknown, never zero.
struct HealthDaySummary: Equatable, Codable, Sendable {
    var dayKey: String
    var steps: Int?
    var walkedMeters: Double?
    var flights: Int?

    var hasAnyValue: Bool { steps != nil || walkedMeters != nil || flights != nil }

    static func summarize(
        dayKey: String,
        steps: HealthValue,
        distance: HealthValue,
        flights: HealthValue,
        calibration: HealthStrideCalibration
    ) -> HealthDaySummary {
        HealthDaySummary(
            dayKey: dayKey,
            steps: steps.known.map { Int($0.rounded()) },
            walkedMeters: distance.known.map { (calibration.k * $0).rounded() },
            flights: flights.known.map { Int($0.rounded()) }
        )
    }
}

// MARK: - Route plausibility

/// How a matched walking route compares with the distance Health measured.
enum HealthRouteSignal: String, Codable, Equatable, Sendable {
    /// Within 25%.
    case agree
    /// Health walked well over the route: a detour the fixes missed.
    case wandered
    /// Health walked well under the route although steps were taken: the match
    /// probably invented a detour.
    case shortfall
    /// Between the bands, or no usable Health distance.
    case inconclusive

    static func classify(routeMeters: Double, healthMeters: HealthValue, steps: HealthValue) -> HealthRouteSignal {
        guard routeMeters > 0, let health = healthMeters.known else { return .inconclusive }
        let ratio = health / routeMeters
        if ratio > 1.5 { return .wandered }
        if ratio < 0.5 { return (steps.known ?? 0) > 0 ? .shortfall : .inconclusive }
        if abs(ratio - 1) <= 0.25 { return .agree }
        return .inconclusive
    }
}

// MARK: - Helpers

enum HealthTimelineFusion {
    /// Within a day Health has data for, no samples during a trip means no steps.
    /// Outside such a day "no samples" stays unknown: read access is opaque.
    static func resolveTripValue(_ trip: HealthValue, dayHasData: Bool) -> HealthValue {
        if case .unknown(.noData) = trip, dayHasData { return .value(0) }
        return trip
    }

    /// A stable fingerprint of what the Health rules read from a day.
    static func signature(trips: [HealthTripFacts], stays: [HealthStayFacts], calibration: HealthStrideCalibration) -> String {
        var text = String(format: "k%.3f|", calibration.k)
        for trip in trips.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            text += "t\(trip.id.uuidString),\(Int(trip.start.timeIntervalSince1970)),\(Int(trip.end.timeIntervalSince1970)),"
            text += "\(trip.mode.rawValue),\(Int(trip.distanceMeters.rounded())),\(trip.sampleCount),"
            text += "\(trip.permitsModeChange ? 1 : 0)\(trip.permitsDistanceCorrection ? 1 : 0);"
        }
        for stay in stays.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            text += "s\(stay.id.uuidString),\(Int(stay.arrival.timeIntervalSince1970)),\(Int(stay.departure.timeIntervalSince1970));"
        }
        // FNV-1a: Swift's Hasher is seeded per process.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// A timeline day's interval from its own start, not the phone's current zone.
    static func dayInterval(dayStart: Date, calendar: Calendar = .current) -> DateInterval {
        let candidate = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let length = candidate.timeIntervalSince(dayStart)
        let end = (23 * 3_600...25 * 3_600).contains(length) ? candidate : dayStart.addingTimeInterval(86_400)
        return DateInterval(start: dayStart, end: end)
    }
}
