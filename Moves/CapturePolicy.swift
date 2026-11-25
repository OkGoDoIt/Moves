import CoreLocation
import Foundation

// Decides how densely Moves records location, independent of CLLocationManager so every
// rule here runs in unit tests. `MovesLocationCaptureManager` feeds it events and applies
// the configuration it returns.

extension LocationSampleSource {
    /// Fixes this phone or its watch recorded as they happened, rather than history brought in.
    var isLiveCapture: Bool {
        switch self {
        case .visit, .significantChange, .routeTracking, .watchRouteTracking, .watchSignificantChange,
             .launchBackfill, .authorizationGrant, .lastMile, .continuous, .cameraPhoto:
            return true
        case .fileRouteImport, .googleTimelineImport, .arcImport, .healthWorkoutRoute, .photoLibrary:
            return false
        }
    }
}

// MARK: - Detail level

/// How much of each trip Moves records while nobody has started route tracking.
enum CaptureDetailLevel: String, CaseIterable, Identifiable, Sendable {
    /// Visits, significant changes, and a short burst after a ride. The original behaviour.
    case batterySaver
    /// Follows trips with GPS and rests while the person stays put.
    case balanced
    /// Like balanced, with closer fixes, and never thinned out for battery.
    case detailed

    static let storageKey = "Moves.capture.detailLevel"
    /// Used when nothing is stored.
    static let defaultLevel: CaptureDetailLevel = .balanced

    var id: String { rawValue }

    static func load(from defaults: UserDefaults) -> CaptureDetailLevel {
        defaults.string(forKey: storageKey).flatMap(CaptureDetailLevel.init(rawValue:)) ?? defaultLevel
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    var title: String {
        switch self {
        case .batterySaver: return String(localized: "Battery Saver")
        case .balanced: return String(localized: "Balanced")
        case .detailed: return String(localized: "Detailed")
        }
    }

    var summary: String {
        switch self {
        case .batterySaver:
            return String(localized: "Records places and the rough shape of trips, with the least battery use.")
        case .balanced:
            return String(localized: "Follows your walks and drives, and rests while you stay put.")
        case .detailed:
            return String(localized: "Captures every turn of your walks, rides, and drives. Uses more battery.")
        }
    }

    /// Whether trips are followed with continuous fixes and departures are watched for.
    var followsTrips: Bool {
        switch self {
        case .batterySaver: return false
        case .balanced, .detailed: return true
        }
    }
}

// MARK: - Inputs

/// What the motion coprocessor last said, reduced to what capture needs.
enum CaptureMotionState: String, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    var isMoving: Bool {
        switch self {
        case .walking, .running, .cycling, .automotive: return true
        case .stationary, .unknown: return false
        }
    }

    /// Low-confidence activity is treated as unknown: it flips too often to start GPS on.
    static func from(
        stationary: Bool,
        walking: Bool,
        running: Bool,
        cycling: Bool,
        automotive: Bool,
        isLowConfidence: Bool
    ) -> CaptureMotionState {
        guard !isLowConfidence else { return .unknown }
        if automotive { return .automotive }
        if cycling { return .cycling }
        if running { return .running }
        if walking { return .walking }
        if stationary { return .stationary }
        return .unknown
    }
}

struct CaptureEnergyState: Equatable, Sendable {
    var isLowPowerModeEnabled: Bool
    /// 0...1, or nil when iOS does not report it.
    var batteryLevel: Float?
    var isCharging: Bool

    static let unconstrained = CaptureEnergyState(isLowPowerModeEnabled: false, batteryLevel: nil, isCharging: false)

    /// Low Power Mode, or a low battery that is not charging.
    var isConstrained: Bool {
        if isLowPowerModeEnabled { return true }
        guard !isCharging, let batteryLevel else { return false }
        return batteryLevel < CapturePolicy.Tuning.lowBatteryLevel
    }
}

/// The kind of travel the current fixes describe, from motion first and speed second.
enum CaptureMovementProfile: String, Sendable {
    case onFoot
    case cycling
    case vehicle
    case unknownMoving
}

// MARK: - Output

struct CaptureConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        /// Visits and significant changes only. No standard location session.
        case lowPower
        /// Battery saver's short pedestrian burst after a ride.
        case lastMile
        /// A coarse standard session that keeps the app running while settled,
        /// so live motion updates can start continuous capture within seconds.
        case departureWatch
        /// Following a trip.
        case continuous
        /// Manual route tracking with its Live Activity.
        case routeTracking
    }

    var mode: Mode
    var desiredAccuracy: CLLocationAccuracy
    var distanceFilter: CLLocationDistance
    var activityType: CLActivityType
    /// Fixes closer together in time than this are not stored.
    var minimumInterval: TimeInterval
    var pausesLocationUpdatesAutomatically: Bool
    var profile: CaptureMovementProfile?
    /// On a straight road, fixes closer together in time than this are not stored.
    var straightSegmentInterval: TimeInterval? = nil

    var usesStandardLocationUpdates: Bool { mode != .lowPower }

    /// For logs. No coordinates.
    var logDescription: String {
        let accuracy: String
        switch desiredAccuracy {
        case kCLLocationAccuracyBestForNavigation: accuracy = "bestForNavigation"
        case kCLLocationAccuracyBest: accuracy = "best"
        case kCLLocationAccuracyNearestTenMeters: accuracy = "10m"
        case kCLLocationAccuracyHundredMeters: accuracy = "100m"
        case kCLLocationAccuracyKilometer: accuracy = "1km"
        default: accuracy = "\(Int(desiredAccuracy))m"
        }
        let straight = straightSegmentInterval.map { " straight=\(Int($0))s" } ?? ""
        return "\(mode.rawValue) profile=\(profile?.rawValue ?? "-") accuracy=\(accuracy) filter=\(Int(distanceFilter))m interval=\(Int(minimumInterval))s\(straight) pauses=\(pausesLocationUpdatesAutomatically)"
    }
}

/// How far back a rebuild of stops and trips reads stored fixes.
enum CaptureRebuildScope: Equatable, Sendable, CustomStringConvertible {
    /// The current trip, from shortly before `since`. Cheap enough to run during a trip.
    case recentTrip(since: Date)
    /// The last seven days. Launch, foreground, settling, visits, and the end of tracking.
    case week

    /// One rebuild that covers both requests.
    func merged(with other: CaptureRebuildScope) -> CaptureRebuildScope {
        switch (self, other) {
        case (.week, _), (_, .week): return .week
        case (.recentTrip(let a), .recentTrip(let b)): return .recentTrip(since: min(a, b))
        }
    }

    /// Whether a rebuild of `self` also covers what `other` would read.
    func covers(_ other: CaptureRebuildScope) -> Bool {
        merged(with: other) == self
    }

    var description: String {
        switch self {
        case .week: return "week"
        case .recentTrip(let since): return "trip(\(Int(max(0, Date.now.timeIntervalSince(since)) / 60)) min)"
        }
    }
}

// MARK: - Policy

enum CapturePolicy {
    /// Every tunable number for automatic capture.
    enum Tuning {
        // Energy
        static let lowBatteryLevel: Float = 0.20

        // Visits + significant changes (all levels, and battery saver's resting state)
        static let lowPowerAccuracy = kCLLocationAccuracyHundredMeters
        static let lowPowerDistanceFilter: CLLocationDistance = 150

        // Battery saver's burst after a ride or a walk away
        static let lastMileAccuracy = kCLLocationAccuracyNearestTenMeters
        static let lastMileDistanceFilter: CLLocationDistance = 20
        static let lastMileDuration: TimeInterval = 10 * 60
        static let lastMileMaximumDuration: TimeInterval = 12 * 60

        // Manual route tracking
        static let routeTrackingAccuracy = kCLLocationAccuracyBestForNavigation
        static let routeTrackingDistanceFilter: CLLocationDistance = 10

        // Settled: departure watch
        static let watchAccuracy = kCLLocationAccuracyHundredMeters
        static let watchDistanceFilter: CLLocationDistance = 50
        /// The circle registered around a settled point. Leaving it wakes the app.
        static let departureRegionRadius: CLLocationDistance = 100
        /// Only register a circle around a point known at least this well.
        static let departureRegionMaximumAnchorAccuracy: CLLocationAccuracy = 100
        /// A settled fix this far from where the person settled means they left.
        static let departureDistance: CLLocationDistance = 120
        /// A significant-change wake this close to the settled point is a tower change, not a trip.
        static let significantChangeIgnoreRadius: CLLocationDistance = 150
        /// While settled, store one fix this often so a long stay still has fixes.
        static let settledHeartbeatInterval: TimeInterval = 10 * 60

        // Settle detection
        /// Movement within this radius is standing still.
        static let settleRadius: CLLocationDistance = 35
        /// Still this long, with motion not reporting movement, ends continuous capture.
        static let settleDuration: TimeInterval = 4 * 60
        /// Still this long ends it even while motion keeps reporting a walk (pacing indoors).
        static let settleMaximumStillDuration: TimeInterval = 10 * 60
        /// A motion-started session that never left the settle radius ends this soon.
        static let falseStartDuration: TimeInterval = 2 * 60
        /// After a false start, motion alone does not restart capture for this long...
        static let motionRetriggerCooldown: TimeInterval = 5 * 60
        /// ...doubling with each false alarm in a row (pacing at home all day), up to this.
        static let motionRetriggerMaximumCooldown: TimeInterval = 30 * 60
        /// Wandering inside this radius (a large building, a garden) is staying...
        static let settleWanderRadius: CLLocationDistance = 100
        /// ...once it has gone on this long.
        static let settleWanderDuration: TimeInterval = 10 * 60
        /// How often settle detection runs while following a trip.
        static let settleCheckInterval: TimeInterval = 30

        // Fix quality
        /// A fix older than this when a session starts is a cached one.
        static let staleFixAge: TimeInterval = 10
        /// Continuous fixes worse than this are skipped...
        static let maximumContinuousAccuracy: CLLocationAccuracy = 65
        /// ...unless nothing better arrived for this long.
        static let poorFixGrace: TimeInterval = 60
        /// Never stored from continuous capture.
        static let absoluteMaximumAccuracy: CLLocationAccuracy = 200
        /// Below this speed (m/s), movement smaller than the accuracy is jitter.
        static let stationarySpeed: CLLocationSpeed = 0.5

        /// Balanced driving on a straight road keeps one fix this often...
        static let straightSegmentInterval: TimeInterval = 15
        /// ...and every fix whose heading turned at least this far from the last one kept.
        static let straightHeadingTolerance: CLLocationDirection = 12

        // Store writes
        /// Rebuild stops from fixes at most this often while following a trip.
        static let reconcileInterval: TimeInterval = 150
        /// A rebuild during a trip reads only from shortly before the trip, when the last
        /// full rebuild is no older than this. Otherwise it reads the whole week.
        static let recentRebuildMaximumSpan: TimeInterval = 6 * 60 * 60
        /// Write buffered fixes when this many are waiting...
        static let flushCount = 10
        /// ...or the oldest has waited this long.
        static let flushInterval: TimeInterval = 30

        // Speed thresholds (m/s) used when motion is unknown or lags behind
        static let vehicleSpeed: CLLocationSpeed = 7
        static let cyclingSpeed: CLLocationSpeed = 2.5
        static let onFootSpeed: CLLocationSpeed = 0.5
    }

    struct ContinuousSettings: Equatable {
        var accuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
        var activityType: CLActivityType
        var minimumInterval: TimeInterval
        /// On a straight road, fixes closer together in time than this are not stored.
        var straightSegmentInterval: TimeInterval? = nil
    }

    /// Continuous capture settings by level, travel kind, and power state.
    static func continuousSettings(
        level: CaptureDetailLevel,
        profile: CaptureMovementProfile,
        isConstrained: Bool
    ) -> ContinuousSettings {
        switch level {
        case .detailed:
            switch profile {
            case .onFoot:
                return ContinuousSettings(accuracy: kCLLocationAccuracyBest, distanceFilter: 5, activityType: .fitness, minimumInterval: 2)
            case .cycling:
                return ContinuousSettings(accuracy: kCLLocationAccuracyBest, distanceFilter: 10, activityType: .fitness, minimumInterval: 3)
            case .vehicle:
                return ContinuousSettings(accuracy: kCLLocationAccuracyBest, distanceFilter: 15, activityType: .automotiveNavigation, minimumInterval: 3)
            case .unknownMoving:
                return ContinuousSettings(accuracy: kCLLocationAccuracyBest, distanceFilter: 10, activityType: .otherNavigation, minimumInterval: 2)
            }
        case .balanced, .batterySaver:
            if isConstrained {
                switch profile {
                case .onFoot:
                    return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 25, activityType: .fitness, minimumInterval: 10)
                case .cycling:
                    return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 40, activityType: .fitness, minimumInterval: 10)
                case .vehicle:
                    return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 80, activityType: .automotiveNavigation, minimumInterval: 15)
                case .unknownMoving:
                    return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 50, activityType: .otherNavigation, minimumInterval: 10)
                }
            }
            switch profile {
            case .onFoot:
                return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 10, activityType: .fitness, minimumInterval: 4)
            case .cycling:
                return ContinuousSettings(accuracy: kCLLocationAccuracyBest, distanceFilter: 15, activityType: .fitness, minimumInterval: 5)
            case .vehicle:
                // A fix every 5 s is 720 an hour. Straight stretches need far fewer:
                // keep the turns, and one fix every 15 s in between.
                return ContinuousSettings(
                    accuracy: kCLLocationAccuracyBest,
                    distanceFilter: 30,
                    activityType: .automotiveNavigation,
                    minimumInterval: 5,
                    straightSegmentInterval: Tuning.straightSegmentInterval
                )
            case .unknownMoving:
                return ContinuousSettings(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 20, activityType: .otherNavigation, minimumInterval: 4)
            }
        }
    }

    /// Motion first; speed when motion is unsure or still says walking at road speed.
    static func profile(motion: CaptureMotionState, recentSpeed: CLLocationSpeed?) -> CaptureMovementProfile {
        let speed = recentSpeed.flatMap { $0 >= 0 ? $0 : nil }
        switch motion {
        case .automotive:
            return .vehicle
        case .cycling:
            return .cycling
        case .walking, .running:
            if let speed, speed >= Tuning.vehicleSpeed { return .vehicle }
            return .onFoot
        case .stationary, .unknown:
            guard let speed else { return .unknownMoving }
            if speed >= Tuning.vehicleSpeed { return .vehicle }
            if speed >= Tuning.cyclingSpeed { return .cycling }
            if speed >= Tuning.onFootSpeed { return .onFoot }
            return .unknownMoving
        }
    }

    static let lowPower = CaptureConfiguration(
        mode: .lowPower,
        desiredAccuracy: Tuning.lowPowerAccuracy,
        distanceFilter: Tuning.lowPowerDistanceFilter,
        activityType: .otherNavigation,
        minimumInterval: 0,
        pausesLocationUpdatesAutomatically: true,
        profile: nil
    )

    static let lastMile = CaptureConfiguration(
        mode: .lastMile,
        desiredAccuracy: Tuning.lastMileAccuracy,
        distanceFilter: Tuning.lastMileDistanceFilter,
        activityType: .fitness,
        minimumInterval: 0,
        pausesLocationUpdatesAutomatically: true,
        profile: .onFoot
    )

    static let routeTracking = CaptureConfiguration(
        mode: .routeTracking,
        desiredAccuracy: Tuning.routeTrackingAccuracy,
        distanceFilter: Tuning.routeTrackingDistanceFilter,
        activityType: .otherNavigation,
        minimumInterval: 0,
        pausesLocationUpdatesAutomatically: false,
        profile: nil
    )

    static let departureWatch = CaptureConfiguration(
        mode: .departureWatch,
        desiredAccuracy: Tuning.watchAccuracy,
        distanceFilter: Tuning.watchDistanceFilter,
        activityType: .otherNavigation,
        minimumInterval: 0,
        // Paused updates are notorious for never resuming in the background.
        pausesLocationUpdatesAutomatically: false,
        profile: nil
    )

    /// The configuration for following trips (balanced and detailed).
    /// Battery saver and route tracking are chosen by the capture manager before this.
    static func configuration(
        level: CaptureDetailLevel,
        phase: CaptureStateMachine.Phase,
        motion: CaptureMotionState,
        recentSpeed: CLLocationSpeed?,
        energy: CaptureEnergyState,
        isRouteTrackingActive: Bool
    ) -> CaptureConfiguration {
        if isRouteTrackingActive { return routeTracking }
        guard level.followsTrips else { return lowPower }
        // Detailed is honoured as chosen; balanced steps down when power is tight.
        let isConstrained = level == .balanced && energy.isConstrained

        switch phase {
        case .off:
            return lowPower
        case .settled:
            // A constrained balanced level drops the keep-alive session and relies on the
            // departure circle, significant changes, and visits to notice a trip.
            return isConstrained ? lowPower : departureWatch
        case .moving:
            let profile = profile(motion: motion, recentSpeed: recentSpeed)
            let settings = continuousSettings(level: level, profile: profile, isConstrained: isConstrained)
            return CaptureConfiguration(
                mode: .continuous,
                desiredAccuracy: settings.accuracy,
                distanceFilter: settings.distanceFilter,
                activityType: settings.activityType,
                minimumInterval: settings.minimumInterval,
                pausesLocationUpdatesAutomatically: false,
                profile: profile,
                straightSegmentInterval: settings.straightSegmentInterval
            )
        }
    }

    /// Which stretch the periodic rebuild during a trip should read.
    ///
    /// The trip itself, from shortly before it began (the repository pads an hour), is all
    /// a new fix can change, provided everything older was rebuilt with full context. That
    /// holds when the last full-week rebuild read its inputs no earlier than an hour before
    /// the window. A relaunch mid-trip, or a long trip, gets the full week instead.
    static func tripRebuildScope(
        movingSince: Date?,
        lastFullRebuildAt: Date?,
        now: Date
    ) -> CaptureRebuildScope {
        guard let lastFullRebuildAt, lastFullRebuildAt <= now else { return .week }
        let since = min(movingSince ?? lastFullRebuildAt, lastFullRebuildAt)
        guard now.timeIntervalSince(since) <= Tuning.recentRebuildMaximumSpan else { return .week }
        return .recentTrip(since: since)
    }

    /// The departure circle to keep registered, or nil for none. At most one exists, so
    /// anything else that wants one replaces it and anything that does not removes it.
    ///
    /// Region monitoring needs Always and precise location. While manual route tracking
    /// runs, an existing circle stays: leaving it relaunches the app if iOS ends it.
    static func departureRegion(
        followsTrips: Bool,
        phase: CaptureStateMachine.Phase,
        anchor: CaptureAnchor?,
        isAlwaysAuthorized: Bool,
        hasFullAccuracy: Bool,
        maximumMonitoringDistance: CLLocationDistance
    ) -> (anchor: CaptureAnchor, radius: CLLocationDistance)? {
        guard followsTrips, phase == .settled, isAlwaysAuthorized, hasFullAccuracy,
              let anchor, anchor.supportsDepartureRegion
        else { return nil }
        // A negative maximum means monitoring is unavailable on this device.
        guard maximumMonitoringDistance > 0 else { return nil }
        return (anchor, min(Tuning.departureRegionRadius, maximumMonitoringDistance))
    }

    /// Whether buffered continuous fixes should be written now.
    static func shouldFlush(pendingCount: Int, oldestPendingAt: Date?, now: Date) -> Bool {
        guard pendingCount > 0 else { return false }
        if pendingCount >= Tuning.flushCount { return true }
        guard let oldestPendingAt else { return true }
        return now.timeIntervalSince(oldestPendingAt) >= Tuning.flushInterval
    }
}

// MARK: - Settle detection

/// Notices that a trip has ended: no displacement beyond a small radius for a few minutes.
struct CaptureSettleDetector: Sendable {
    /// Where the current still period began.
    private(set) var anchor: CLLocation?
    /// When the current still period began.
    private(set) var stillSince: Date?
    /// Whether this session has moved beyond the settle radius at least once.
    private(set) var hasDisplaced = false
    /// Where the current wander (moving about, but inside `settleWanderRadius`) began.
    private(set) var wanderAnchor: CLLocation?
    private(set) var wanderSince: Date?

    mutating func reset(at date: Date) {
        anchor = nil
        stillSince = date
        hasDisplaced = false
        wanderAnchor = nil
        wanderSince = date
    }

    /// The system clock jumped. Keep where the person is; restart the timers from now.
    mutating func restartClock(at date: Date) {
        stillSince = date
        wanderSince = date
    }

    mutating func observe(_ location: CLLocation) {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0, accuracy <= CapturePolicy.Tuning.absoluteMaximumAccuracy else { return }
        observeWander(location)
        guard let anchor else {
            anchor = location
            if stillSince == nil { stillSince = location.timestamp }
            return
        }
        let distance = location.distance(from: anchor)
        if distance > max(CapturePolicy.Tuning.settleRadius, accuracy) {
            self.anchor = location
            stillSince = location.timestamp
            hasDisplaced = true
        } else if accuracy < anchor.horizontalAccuracy {
            // Same spot, better fix: keep the clock, sharpen the point.
            self.anchor = location
        }
    }

    private mutating func observeWander(_ location: CLLocation) {
        guard let wanderAnchor else {
            wanderAnchor = location
            if wanderSince == nil { wanderSince = location.timestamp }
            return
        }
        let reach = max(CapturePolicy.Tuning.settleWanderRadius, location.horizontalAccuracy)
        if location.distance(from: wanderAnchor) > reach {
            self.wanderAnchor = location
            wanderSince = location.timestamp
        }
    }

    enum Verdict: Equatable {
        case stillWithoutMotion
        case stillTooLong
        case falseStart
        /// Moving about for a long while without leaving a building-sized circle.
        case wanderedInPlace

        /// Motion kept saying "moving" while the person went nowhere.
        var isMotionFalseAlarm: Bool {
            switch self {
            case .falseStart, .stillTooLong, .wanderedInPlace: return true
            case .stillWithoutMotion: return false
            }
        }
    }

    func verdict(now: Date, motion: CaptureMotionState, startedByMotion: Bool) -> Verdict? {
        guard let stillSince else { return nil }
        // A clock set back leaves the start in the future; that is not standing still.
        let stillFor = max(0, now.timeIntervalSince(stillSince))
        if stillFor >= CapturePolicy.Tuning.settleMaximumStillDuration { return .stillTooLong }
        if startedByMotion, !hasDisplaced, stillFor >= CapturePolicy.Tuning.falseStartDuration { return .falseStart }
        if stillFor >= CapturePolicy.Tuning.settleDuration, !motion.isMoving { return .stillWithoutMotion }
        if let wanderSince, wanderAnchor != nil,
           now.timeIntervalSince(wanderSince) >= CapturePolicy.Tuning.settleWanderDuration {
            return .wanderedInPlace
        }
        return nil
    }
}

// MARK: - State machine

/// A point without the CLLocation identity, so transitions compare by value.
struct CaptureAnchor: Equatable, Sendable {
    var latitude: CLLocationDegrees
    var longitude: CLLocationDegrees
    var horizontalAccuracy: CLLocationAccuracy

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
    }

    init(latitude: CLLocationDegrees, longitude: CLLocationDegrees, horizontalAccuracy: CLLocationAccuracy) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: .distantPast
        )
    }

    var supportsDepartureRegion: Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= CapturePolicy.Tuning.departureRegionMaximumAnchorAccuracy
    }
}

/// Settled or following a trip, for balanced and detailed capture.
struct CaptureStateMachine: Sendable {
    enum Phase: String, Sendable {
        /// Battery saver, or background listening off. Nothing here runs.
        case off
        /// Staying put. Watching for a departure.
        case settled
        /// Following a trip with continuous fixes.
        case moving
    }

    enum Trigger: String, Sendable {
        case launch
        case significantChange
        case visitDeparture
        case regionExit
        case motionActivity
        case displacement
    }

    enum Transition: Equatable {
        case none
        case startedMoving(Trigger)
        case settled(anchor: CaptureAnchor?, verdict: CaptureSettleDetector.Verdict)
        case turnedOff
    }

    private(set) var phase: Phase
    private(set) var level: CaptureDetailLevel
    private(set) var isListening: Bool
    private(set) var motion: CaptureMotionState = .unknown
    /// Where the person last settled. The departure circle is drawn around it.
    private(set) var departureAnchor: CaptureAnchor?
    private(set) var detector = CaptureSettleDetector()
    private(set) var movingStartedBy: Trigger?
    private(set) var movingSince: Date?
    private(set) var motionTriggersSuppressedUntil: Date?
    /// Settles in a row where motion said "moving" and the person went nowhere.
    private(set) var motionFalseAlarms = 0

    /// With no known settled point (first launch, or a relaunch mid-trip) it starts by looking:
    /// settle detection ends that within minutes if the person is staying put.
    init(level: CaptureDetailLevel, isListening: Bool, departureAnchor: CaptureAnchor?, now: Date) {
        self.level = level
        self.isListening = isListening
        self.departureAnchor = departureAnchor
        if !level.followsTrips || !isListening {
            phase = .off
        } else if departureAnchor != nil {
            phase = .settled
        } else {
            phase = .moving
            movingStartedBy = .launch
            movingSince = now
            detector.reset(at: now)
        }
    }

    /// Level or listening changed.
    mutating func configure(level: CaptureDetailLevel, isListening: Bool, now: Date) -> Transition {
        self.level = level
        self.isListening = isListening
        guard level.followsTrips, isListening else {
            guard phase != .off else { return .none }
            phase = .off
            movingStartedBy = nil
            movingSince = nil
            return .turnedOff
        }
        guard phase == .off else { return .none }
        // Coming back on: look first, then settle.
        return startMoving(.launch, now: now)
    }

    mutating func handleWake(_ trigger: Trigger, location: CLLocation?, now: Date) -> Transition {
        guard phase == .settled else {
            if phase == .moving, let location { detector.observe(location) }
            return .none
        }
        if trigger == .significantChange, let location, let anchor = departureAnchor {
            let distance = location.distance(from: anchor.location)
            if distance < max(CapturePolicy.Tuning.significantChangeIgnoreRadius, location.horizontalAccuracy) {
                return .none
            }
        }
        return startMoving(trigger, now: now)
    }

    mutating func handleMotion(_ state: CaptureMotionState, now: Date) -> Transition {
        motion = state
        guard phase == .settled, state.isMoving else { return .none }
        if let until = motionTriggersSuppressedUntil, now < until { return .none }
        return startMoving(.motionActivity, now: now)
    }

    /// Records motion without acting on it, while manual route tracking is in charge.
    mutating func noteMotion(_ state: CaptureMotionState) {
        motion = state
    }

    /// Forgets where the person settled and looks again, as at launch. For when the
    /// settled point may be stale: route tracking ended, or capture was off for a while.
    mutating func restartLooking(now: Date) -> Transition {
        guard phase != .off else { return .none }
        return startMoving(.launch, now: now)
    }

    /// The system clock jumped. Timers restart from now; where the person is stays known.
    mutating func clockDidChange(now: Date) {
        detector.restartClock(at: now)
        if let movingSince, movingSince > now { self.movingSince = now }
        if let until = motionTriggersSuppressedUntil,
           until.timeIntervalSince(now) > CapturePolicy.Tuning.motionRetriggerMaximumCooldown {
            motionTriggersSuppressedUntil = nil
        }
    }

    /// How long motion alone is ignored after `count` false alarms in a row.
    static func motionCooldown(afterFalseAlarms count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let doubled = CapturePolicy.Tuning.motionRetriggerCooldown * pow(2, Double(min(count, 8) - 1))
        return min(doubled, CapturePolicy.Tuning.motionRetriggerMaximumCooldown)
    }

    mutating func handleFix(_ location: CLLocation, now: Date) -> Transition {
        switch phase {
        case .off:
            return .none
        case .moving:
            detector.observe(location)
            return tick(now: now)
        case .settled:
            let accuracy = location.horizontalAccuracy
            guard accuracy >= 0, accuracy <= CapturePolicy.Tuning.absoluteMaximumAccuracy else { return .none }
            guard let anchor = departureAnchor else {
                departureAnchor = CaptureAnchor(location)
                return .none
            }
            let distance = location.distance(from: anchor.location)
            if distance > max(CapturePolicy.Tuning.departureDistance, 2 * accuracy) {
                return startMoving(.displacement, now: now)
            }
            if accuracy < anchor.horizontalAccuracy, distance <= CapturePolicy.Tuning.settleRadius {
                departureAnchor = CaptureAnchor(location)
            }
            return .none
        }
    }

    /// Settle detection. Called on every fix and on a timer while following a trip.
    mutating func tick(now: Date) -> Transition {
        guard phase == .moving else { return .none }
        guard let verdict = detector.verdict(
            now: now,
            motion: motion,
            startedByMotion: movingStartedBy == .motionActivity
        ) else { return .none }

        if verdict.isMotionFalseAlarm {
            // Pacing, fidgeting, or wandering a building: motion will say "walking" again
            // in a moment. Region exits, significant changes, and visits still count.
            let endedARealTrip = detector.hasDisplaced && verdict == .stillTooLong
            motionFalseAlarms = endedARealTrip ? 1 : motionFalseAlarms + 1
            motionTriggersSuppressedUntil = now.addingTimeInterval(Self.motionCooldown(afterFalseAlarms: motionFalseAlarms))
        } else if detector.hasDisplaced {
            motionFalseAlarms = 0
        }
        if let anchor = detector.anchor {
            departureAnchor = CaptureAnchor(anchor)
        }
        phase = .settled
        movingStartedBy = nil
        movingSince = nil
        return .settled(anchor: departureAnchor, verdict: verdict)
    }

    private mutating func startMoving(_ trigger: Trigger, now: Date) -> Transition {
        switch trigger {
        case .regionExit, .displacement, .significantChange, .visitDeparture:
            // A departure the location system saw: the false-alarm run is over.
            motionFalseAlarms = 0
            motionTriggersSuppressedUntil = nil
        case .launch:
            // Where the person is now is unknown; an old settled point may be far away.
            departureAnchor = nil
        case .motionActivity:
            break
        }
        phase = .moving
        movingStartedBy = trigger
        movingSince = now
        detector.reset(at: now)
        return .startedMoving(trigger)
    }
}

// MARK: - Fix quality

/// Keeps clean, evenly spaced fixes from continuous capture.
struct CaptureFixFilter: Sendable {
    enum Drop: String, CaseIterable, Sendable {
        case invalid
        case stale
        case outOfOrder
        case inaccurate
        case tooSoon
        case jitter
        /// Balanced driving on a straight road between kept fixes.
        case straight
    }

    private(set) var lastAccepted: CLLocation?
    private(set) var sessionStartedAt: Date?
    private(set) var acceptedCount = 0
    private(set) var dropCounts: [Drop: Int] = [:]

    var droppedCount: Int { dropCounts.values.reduce(0, +) }

    /// For logs: "inaccurate=3 jitter=12".
    var dropSummary: String {
        Drop.allCases.compactMap { drop in
            dropCounts[drop].map { "\(drop.rawValue)=\($0)" }
        }.joined(separator: " ")
    }

    mutating func beginSession(at date: Date) {
        sessionStartedAt = date
        lastAccepted = nil
        acceptedCount = 0
        dropCounts = [:]
    }

    /// The system clock jumped: fixes stamped by the new clock are neither stale nor out
    /// of order. Counts are kept for the session log.
    mutating func restartClock(at date: Date) {
        sessionStartedAt = date
        lastAccepted = nil
    }

    /// Nil when the fix should be stored.
    func evaluate(
        _ location: CLLocation,
        minimumInterval: TimeInterval,
        straightSegmentInterval: TimeInterval? = nil
    ) -> Drop? {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0 else { return .invalid }

        if let sessionStartedAt,
           location.timestamp < sessionStartedAt.addingTimeInterval(-CapturePolicy.Tuning.staleFixAge) {
            return .stale
        }
        if let lastAccepted, location.timestamp <= lastAccepted.timestamp {
            return .outOfOrder
        }
        if accuracy > CapturePolicy.Tuning.absoluteMaximumAccuracy {
            return .inaccurate
        }
        if accuracy > CapturePolicy.Tuning.maximumContinuousAccuracy {
            let lastGood = lastAccepted?.timestamp ?? sessionStartedAt ?? location.timestamp
            if location.timestamp.timeIntervalSince(lastGood) < CapturePolicy.Tuning.poorFixGrace {
                return .inaccurate
            }
        }
        guard let lastAccepted else { return nil }

        let elapsed = location.timestamp.timeIntervalSince(lastAccepted.timestamp)
        if elapsed < minimumInterval {
            return .tooSoon
        }
        let distance = location.distance(from: lastAccepted)
        let isStill = location.speed < 0 || location.speed < CapturePolicy.Tuning.stationarySpeed
        if isStill, distance < accuracy {
            return .jitter
        }
        if let straightSegmentInterval, elapsed < straightSegmentInterval,
           location.speed >= CapturePolicy.Tuning.vehicleSpeed,
           location.course >= 0, lastAccepted.course >= 0,
           Self.headingChange(from: lastAccepted.course, to: location.course) < CapturePolicy.Tuning.straightHeadingTolerance {
            return .straight
        }
        return nil
    }

    /// Smallest angle between two headings, 0...180.
    static func headingChange(from a: CLLocationDirection, to b: CLLocationDirection) -> CLLocationDirection {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }

    /// The fixes worth storing, in order.
    mutating func accept(
        _ locations: [CLLocation],
        minimumInterval: TimeInterval,
        straightSegmentInterval: TimeInterval? = nil
    ) -> [CLLocation] {
        var accepted: [CLLocation] = []
        for location in locations {
            if let drop = evaluate(location, minimumInterval: minimumInterval, straightSegmentInterval: straightSegmentInterval) {
                dropCounts[drop, default: 0] += 1
            } else {
                lastAccepted = location
                acceptedCount += 1
                accepted.append(location)
            }
        }
        return accepted
    }
}

// MARK: - Reconcile throttle

/// Rebuilding a week of stops on every fix is too much work while following a trip.
struct ReconcileThrottle: Sendable {
    var interval: TimeInterval = CapturePolicy.Tuning.reconcileInterval
    private(set) var lastRunAt: Date?

    /// True, and records the run, when enough time has passed since the last one.
    mutating func shouldRun(at now: Date) -> Bool {
        // A clock set back puts the last run in the future: run, rather than wait it out.
        if let lastRunAt, now >= lastRunAt, now.timeIntervalSince(lastRunAt) < interval { return false }
        lastRunAt = now
        return true
    }

    mutating func recordRun(at now: Date) {
        lastRunAt = now
    }
}
