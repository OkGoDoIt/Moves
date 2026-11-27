import Foundation
import Combine
import CoreLocation
import CoreMotion
import MapKit
import os
import SwiftData
import UserNotifications
import UIKit

@MainActor
protocol LocationCaptureService: AnyObject {
    func start() async
    func requestTrackingAuthorization()
    func enableTemporaryRouteTracking(duration: TemporaryRouteTrackingDuration)
    func updateTemporaryRouteTrackingAutoStopRules(
        stopsAtFiftyPercentBattery: Bool,
        stopsInLowPowerMode: Bool
    )
    func disableTemporaryRouteTracking()
    func stop()
    func refreshHistoricalBackfill() async
}

enum TemporaryRouteTrackingDuration: String, CaseIterable, Identifiable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case endOfDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .fourHours:
            return "4 hours"
        case .endOfDay:
            return "Until end of day"
        }
    }

    var availabilityText: String {
        switch self {
        case .thirtyMinutes:
            return "for 30 minutes"
        case .oneHour:
            return "for 1 hour"
        case .twoHours:
            return "for 2 hours"
        case .fourHours:
            return "for 4 hours"
        case .endOfDay:
            return "until the end of today"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        case .endOfDay:
            return nil
        }
    }

    func endDate(from startDate: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .thirtyMinutes:
            return startDate.addingTimeInterval(30 * 60)
        case .oneHour:
            return startDate.addingTimeInterval(60 * 60)
        case .twoHours:
            return startDate.addingTimeInterval(2 * 60 * 60)
        case .fourHours:
            return startDate.addingTimeInterval(4 * 60 * 60)
        case .endOfDay:
            let startOfDay = calendar.startOfDay(for: startDate)
            return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(24 * 60 * 60)
        }
    }
}

enum TemporaryRouteTrackingStopNotificationPermissionResult: Equatable {
    case enabled
    case needsSettings
}

/// Coalesces launch/authorization fixes without starting a timer or GPS session.
/// A missing callback expires on the next event; failures retain the cooldown.
/// Upstream uses a 45-second foreground throttle and a 20-second request window.
struct OneShotLocationRequestGate {
    private var lastRequestedAt: Date?
    private var pending: (source: LocationSampleSource, expiresAt: Date)?

    mutating func begin(source: LocationSampleSource, at date: Date) -> Bool {
        if let lastRequestedAt, date.timeIntervalSince(lastRequestedAt) < 45 { return false }
        lastRequestedAt = date
        pending = (source, date.addingTimeInterval(20))
        return true
    }

    mutating func takeSource(at date: Date) -> LocationSampleSource? {
        defer { pending = nil }
        guard let pending, date < pending.expiresAt else { return nil }
        return pending.source
    }

    mutating func cancel() {
        pending = nil
    }
}

protocol MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double)
    /// Steps in the interval, or nil when there is no step data: the interval is older
    /// than the pedometer's history, or the query failed. Zero means nobody walked.
    func stepCount(start: Date, end: Date) async -> Int?
    /// Core Motion's own dominant activity over the interval, before any preference or
    /// speed correction. Nil when it has no reading.
    func dominantActivity(start: Date, end: Date) async -> TransportMode?
    /// True when the minutes before `date` include a vehicle ride.
    func approachWasAutomotive(before date: Date) async -> Bool
    /// True when the last few minutes are on foot and not in a vehicle.
    func recentlyWalking(at date: Date) async -> Bool
}

extension MotionClassifier {
    func dominantActivity(start: Date, end: Date) async -> TransportMode? { nil }
    func approachWasAutomotive(before date: Date) async -> Bool { false }
    func recentlyWalking(at date: Date) async -> Bool { false }
}

protocol PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String?
}

@MainActor
protocol TimelineAssembler {
    func ingestVisit(_ visit: CLVisit) async
    /// Stores fixes. With `reconcile` false the stops are not rebuilt; the caller
    /// coalesces that work (continuous capture delivers a batch every few seconds).
    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource, reconcile: Bool) async
    /// Writes fixes synchronously. Only for the moment the app is about to end.
    func storeImmediately(_ locations: [CLLocation], source: LocationSampleSource)
    /// Rebuilds stops and trips from stored fixes over `scope`.
    func reconcile(_ scope: CaptureRebuildScope) async
    func approachWasAutomotive(before date: Date) async -> Bool
    func recentlyWalking(at date: Date) async -> Bool
}

extension TimelineAssembler {
    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async {
        await ingestLocations(locations, source: source, reconcile: true)
    }

    /// Rebuilds the last week.
    func reconcileSampleStays() async {
        await reconcile(.week)
    }
}

final class CoreMotionTransportClassifier: MotionClassifier {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let defaults: UserDefaults
    private static let minimumDistanceForNonStationaryOverride: CLLocationDistance = 450

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func restrict(_ mode: TransportMode, confidence: Double, locations: [CLLocation]) -> (mode: TransportMode, confidence: Double) {
        AutomaticTransportModes.load(from: defaults).restrict(mode: mode, confidence: confidence, locations: locations)
    }

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        guard end > start else { return (.stationary, 0.25) }
        let fallback = Self.inferredMode(from: locations, preferences: AutomaticTransportModes.load(from: defaults))

        if CMMotionActivityManager.isActivityAvailable(),
           let activities = await queryActivities(from: start, to: end),
           !activities.isEmpty {
            let scores = Self.durationWeightedActivityScores(
                activities.map {
                    (start: $0.startDate, confidence: confidenceWeight(for: $0.confidence), mode: Self.mode(for: $0))
                },
                from: start,
                to: end
            )

            if let best = scores.max(by: { $0.value < $1.value }) {
                let corrected = correctedModeIfNeeded(best.key, locations: locations)
                let refined = refinedLongDistanceMode(for: corrected, locations: locations)
                let mode = Self.rejectingImplausibleContinuousTrip(
                    refined,
                    duration: end.timeIntervalSince(start),
                    straightLineDistance: Self.straightLineDistance(for: locations)
                )
                let total = max(scores.values.reduce(0, +), 1)
                let dominance = Double(best.value) / Double(total)
                let coverageAndQuality = min(1, Double(best.value) / max(end.timeIntervalSince(start) * 3, 1))
                let motionConfidence = 0.35 + 0.6 * min(dominance, coverageAndQuality)
                let speedConfidence = Self.speedBasedConfidence(mode: mode, locations: locations)
                let confidence = mode == best.key
                    ? max(motionConfidence, speedConfidence * 0.5)
                    : min(0.59, min(motionConfidence, speedConfidence))
                return restrict(mode, confidence: min(max(confidence, 0), 1), locations: locations)
            }
        }

        let corrected = correctedModeIfNeeded(fallback, locations: locations)
        let refined = refinedLongDistanceMode(for: corrected, locations: locations)
        let mode = Self.rejectingImplausibleContinuousTrip(
            refined,
            duration: end.timeIntervalSince(start),
            straightLineDistance: Self.straightLineDistance(for: locations)
        )
        var confidence = Self.speedBasedConfidence(mode: mode, locations: locations)
        if mode != fallback {
            confidence = min(confidence, 0.72)
        }
        if locations.count < 3 {
            confidence *= 0.9
        }
        // Speed alone leaves overlapping modes ambiguous even in the middle of
        // a speed bucket. Do not present that bucket's center as 95% certainty.
        return restrict(mode, confidence: min(max(confidence, 0), 0.59), locations: locations)
    }

    func approachWasAutomotive(before date: Date) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let start = date.addingTimeInterval(-12 * 60)
        guard let activities = await queryActivities(from: start, to: date) else { return false }
        return activities.contains { $0.automotive && $0.confidence != .low }
    }

    func recentlyWalking(at date: Date) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let start = date.addingTimeInterval(-5 * 60)
        guard let activities = await queryActivities(from: start, to: date), !activities.isEmpty else {
            return false
        }
        let onFoot = activities.contains { ($0.walking || $0.running) && $0.confidence != .low }
        let riding = activities.contains { $0.automotive && $0.confidence != .low }
        return onFoot && !riding
    }

    /// A multi-hour "walk" whose ends are a short distance apart is time spent
    /// stopped, not a single trip. Visit monitoring sometimes never closes the
    /// gap; calling that walking is how a day at home becomes a 36-hour hike.
    static func rejectingImplausibleContinuousTrip(
        _ mode: TransportMode,
        duration: TimeInterval,
        straightLineDistance: CLLocationDistance
    ) -> TransportMode {
        guard duration >= 6 * 60 * 60 else { return mode }
        switch mode {
        case .walking, .running, .cycling:
            break
        case .automotive, .train, .plane, .boat, .swimming, .stationary, .unknown:
            return mode
        }
        let speed = straightLineDistance / duration
        guard speed < 0.25 else { return mode }
        return .unknown
    }

    /// 0…1 certainty that `mode` matches the observed speeds. Highest at the
    /// centre of the mode's speed bucket, lowest at the boundaries.
    static func speedBasedConfidence(mode: TransportMode, locations: [CLLocation]) -> Double {
        guard TransportSpeedEvidence(locations: locations).hasSustainedCoverage else { return 0.25 }
        let speed = averageSpeed(for: locations)
        guard let range = speedRange(for: mode) else { return 0.5 }
        let width = max(range.upper - range.lower, 0.1)
        if speed < range.lower || speed >= range.upper {
            let overshoot = speed < range.lower ? range.lower - speed : speed - range.upper
            return min(max(0.6 - overshoot / max(width, 1), 0.25), 0.6)
        }
        let mid = (range.lower + range.upper) / 2
        let half = width / 2
        let distanceFromEdge = half - abs(speed - mid)
        let t = min(max(distanceFromEdge / half, 0), 1)
        return 0.45 + 0.5 * t
    }

    static func speedRange(for mode: TransportMode) -> (lower: CLLocationSpeed, upper: CLLocationSpeed)? {
        switch mode {
        case .stationary: return (0, 0.7)
        case .walking: return (0.7, 2.0)
        case .running: return (2.0, 4.5)
        case .cycling: return (4.5, 9.0)
        case .automotive: return (9.0, 32)
        case .train: return (32, 75)
        case .plane: return (75, 1_000)
        case .swimming, .boat, .unknown: return nil
        }
    }

    /// The pedometer answers for its last seven days only. Older intervals come back
    /// as zero steps, which would read as "nobody walked".
    static let pedometerHistory: TimeInterval = MoveSegment.pedometerHistory

    func stepCount(start: Date, end: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable(), end > start,
              start > Date.now.addingTimeInterval(-Self.pedometerHistory + 60)
        else {
            return nil
        }

        let pedometer = pedometer
        // Core Motion can leave a query unanswered when iOS suspends the app part-way.
        return await BoundedWait.run(seconds: Self.queryTimeLimit, fallback: nil) {
            await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, error in
                    // No data is not zero steps: the rules treat nil as unknown.
                    guard error == nil, let data else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: data.numberOfSteps.intValue)
                }
            }
        }
    }

    func dominantActivity(start: Date, end: Date) async -> TransportMode? {
        guard CMMotionActivityManager.isActivityAvailable(),
              let activities = await queryActivities(from: start, to: end),
              !activities.isEmpty
        else { return nil }
        let scores = Self.durationWeightedActivityScores(
            activities.map {
                (start: $0.startDate, confidence: confidenceWeight(for: $0.confidence), mode: Self.mode(for: $0))
            },
            from: start,
            to: end
        )
        return scores.max { $0.value < $1.value }?.key
    }

    private static let queryTimeLimit: TimeInterval = 6

    private func queryActivities(from start: Date, to end: Date) async -> [CMMotionActivity]? {
        guard end > start else { return nil }

        let activityManager = activityManager
        return await BoundedWait.run(seconds: Self.queryTimeLimit, fallback: nil) {
            await withCheckedContinuation { continuation in
                activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                    guard error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: activities)
                }
            }
        }
    }

    /// Core Motion reports state transitions, not equally spaced votes. Adapted
    /// from upstream's duration weighting while retaining the fork's confidence
    /// and implausible-trip checks. Unknown intervals end the previous activity
    /// but do not override the location-based fallback.
    static func durationWeightedActivityScores(
        _ activities: [(start: Date, confidence: Int, mode: TransportMode)],
        from start: Date,
        to end: Date
    ) -> [TransportMode: TimeInterval] {
        guard end > start else { return [:] }
        let ordered = activities.sorted { $0.start < $1.start }
        var scores: [TransportMode: TimeInterval] = [:]
        for index in ordered.indices {
            let intervalStart = max(start, ordered[index].start)
            let intervalEnd = index + 1 < ordered.count
                ? min(end, ordered[index + 1].start)
                : end
            let duration = intervalEnd.timeIntervalSince(intervalStart)
            guard duration > 0, ordered[index].mode != .unknown else { continue }
            scores[ordered[index].mode, default: 0] += duration * Double(max(ordered[index].confidence, 1))
        }
        return scores
    }

    private static func mode(for activity: CMMotionActivity) -> TransportMode {
        if activity.automotive { return .automotive }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private func confidenceWeight(for confidence: CMMotionActivityConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        @unknown default: return 1
        }
    }

    /// Speed buckets shared with Live Activity tinting.
    static func inferredMode(
        from locations: [CLLocation],
        preferences: AutomaticTransportModes = .load()
    ) -> TransportMode {
        preferences.allowedMode(speedInferredMode(from: locations))
    }

    private static func speedInferredMode(from locations: [CLLocation]) -> TransportMode {
        TransportSpeedEvidence(locations: locations).inferredMode
    }

    private func correctedModeIfNeeded(
        _ candidate: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        guard candidate == .stationary else { return candidate }
        let evidence = TransportSpeedEvidence(locations: locations)
        let inferred = evidence.inferredMode
        guard evidence.hasSustainedCoverage, evidence.directLowerDistance >= Self.minimumDistanceForNonStationaryOverride,
              inferred != .unknown, inferred != .stationary else { return candidate }
        return inferred
    }

    private func refinedLongDistanceMode(
        for candidate: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        switch candidate {
        case .walking, .running, .swimming, .cycling, .train, .plane, .boat:
            return candidate
        case .stationary, .automotive, .unknown:
            break
        }

        // Road and rail speeds overlap; a single speed spike is not a flight.
        if TransportSpeedEvidence(locations: locations).inferredMode == .plane { return .plane }
        return candidate
    }

    static func averageSpeed(for locations: [CLLocation]) -> CLLocationSpeed {
        TransportSpeedEvidence(locations: locations).typicalSpeed
    }

    private static func straightLineDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard let first = locations.first, let last = locations.last else { return 0 }
        return first.distance(from: last)
    }
}

actor CLGeocoderPlaceNameResolver: PlaceNameResolver {
    private var cache: [String: String] = [:]

    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let cacheKey = Self.cacheKey(for: coordinate)
        if let cached = cache[cacheKey] {
            return cached.isEmpty ? nil : cached
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                cache[cacheKey] = ""
                return nil
            }
            let mapItems = try await request.mapItems
            let resolvedName = mapItems.first.flatMap(Self.bestName(from:))
            cache[cacheKey] = resolvedName ?? ""
            return resolvedName
        } catch {
            cache[cacheKey] = ""
            return nil
        }
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let roundedLat = String(format: "%.4f", coordinate.latitude)
        let roundedLon = String(format: "%.4f", coordinate.longitude)
        return "\(roundedLat)|\(roundedLon)"
    }

    private static func bestName(from mapItem: MKMapItem) -> String? {
        let candidates: [String?] = [
            mapItem.name,
            mapItem.address?.shortAddress,
            mapItem.address?.fullAddress,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map(PlaceDisplayNamer.normalizedAutomaticLabel)
    }
}

@MainActor
final class DefaultTimelineAssembler: TimelineAssembler {
    private static let timelineLog = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Timeline")

    private let repository: TimelineRepository
    private let motionClassifier: MotionClassifier
    private let placeNameResolver: PlaceNameResolver
    private let automaticModes: () -> AutomaticTransportModes
    private let now: () -> Date
    /// Where the pace-rule sweep records that it ran; nil never runs it.
    private let paceRulesDefaults: UserDefaults?
    /// Pedometer answers the stop rules asked for, kept so later passes decide alike.
    private let stopStepEvidence = ReconcileStepEvidence()
    /// Pedometer queries per pass, so a first pass over a busy week stays bounded.
    private static let stepQueriesPerPass = 1_000
    private static let stepRoundsPerPass = 6
    /// One rebuild at a time. Callers that overlap wait for the running one.
    private var reconcileDriver: Task<Void, Never>?
    /// What callers asked for while a rebuild ran, if it still needs doing.
    private var pendingScope: CaptureRebuildScope?
    /// The scope of the pass in progress.
    private var activeScope: CaptureRebuildScope?
    /// Bumped when new fixes or a visit reach the store.
    private var storeGeneration = 0
    /// The generation and scope the running rebuild read its inputs at.
    private var runningInputs: (generation: Int, scope: CaptureRebuildScope)?
    /// When the last full-week rebuild read its inputs. Capture narrows later rebuilds to it.
    private(set) var lastWeekRebuildReadAt: Date?
    /// Rebuilds actually run, and the stops and trips the last one changed. For tests and logs.
    private(set) var rebuildCount = 0
    private(set) var lastRebuildChanges = (stops: 0, trips: 0)

    init(
        repository: TimelineRepository,
        motionClassifier: MotionClassifier,
        placeNameResolver: PlaceNameResolver,
        automaticModes: @escaping () -> AutomaticTransportModes = { .load() },
        now: @escaping () -> Date = Date.init,
        paceRulesDefaults: UserDefaults? = .standard
    ) {
        self.repository = repository
        self.motionClassifier = motionClassifier
        self.placeNameResolver = placeNameResolver
        self.automaticModes = automaticModes
        self.now = now
        self.paceRulesDefaults = paceRulesDefaults
    }

    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource, reconcile: Bool = true) async {
        guard !locations.isEmpty else { return }

        await withStoreWriteTime {
            storeImmediately(locations, source: source)
            if reconcile {
                await reconcileSampleStays()
            }
        }
    }

    func storeImmediately(_ locations: [CLLocation], source: LocationSampleSource) {
        guard !locations.isEmpty else { return }
        let writeStarted = Date.now
        do {
            let samples = try repository.appendSamples(from: locations, source: source)
            try repository.saveIfNeeded()
            // A fix the store already had changes nothing a rebuild would read.
            if samples.contains(where: { $0.createdAt >= writeStarted }) {
                storeGeneration += 1
            }
        } catch {
            Self.timelineLog.error("Failed to persist \(locations.count) location samples: \(error.localizedDescription, privacy: .public)")
        }
    }

    func ingestVisit(_ visit: CLVisit) async {
        await withStoreWriteTime {
            // A kilometre-wide visit fix is a cell tower, not a place. The sample
            // is already stored; stays are built from the fixes that are actually
            // near the person.
            guard visit.horizontalAccuracy <= 300 else {
                Self.timelineLog.info("Skipped a visit whose accuracy was \(Int(visit.horizontalAccuracy)) m")
                await reconcileSampleStays()
                return
            }

            do {
                if try repository.visitWasRemoved(visit) {
                    await reconcileSampleStays()
                    return
                }
                let visitPlace = try repository.addOrUpdateVisit(from: visit)
                storeGeneration += 1
                try repository.applyPlaceLearning(to: visitPlace)
                await fillAutomaticPlaceLabelIfNeeded(forPlaceID: visitPlace.id)
                try repository.saveIfNeeded()
            } catch {
                print("Failed to build timeline segment: \(error.localizedDescription)")
            }

            await reconcileSampleStays()
        }
    }

    /// Keeps the process running until a store write finishes.
    ///
    /// The store is in the shared App Group container, and iOS kills a process it
    /// would otherwise suspend while it holds a lock on a file there (0xdead10cc).
    /// Location callbacks arrive in the background, so that suspension is a real risk.
    private func withStoreWriteTime(_ work: () async -> Void) async {
        final class Assertion {
            var identifier = UIBackgroundTaskIdentifier.invalid

            func end() {
                guard identifier != .invalid else { return }
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }

        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: "Timeline write") {
            assertion.end()
        }
        await work()
        assertion.end()
    }

    func approachWasAutomotive(before date: Date) async -> Bool {
        await motionClassifier.approachWasAutomotive(before: date)
    }

    func recentlyWalking(at date: Date) async -> Bool {
        await motionClassifier.recentlyWalking(at: date)
    }

    /// Rebuilds stops from the fixes already on disk, then classifies each new trip.
    ///
    /// The work is local and, once a trip has a mode, later passes leave it. One pass runs
    /// at a time. A request that arrives during a pass waits for it, and a second pass runs
    /// only if new fixes or a visit arrived after the running pass read its inputs, or the
    /// request reads further back than the running pass does.
    func reconcile(_ scope: CaptureRebuildScope) async {
        if let reconcileDriver {
            let covered: Bool
            if let running = runningInputs {
                // Nothing new since that pass read the store: its result is this one's.
                covered = running.generation == storeGeneration && running.scope.covers(scope)
            } else {
                // That pass has not read the store yet, so it will see everything so far.
                covered = activeScope?.covers(scope) ?? false
            }
            if !covered {
                pendingScope = pendingScope.map { $0.merged(with: scope) } ?? scope
            }
            await reconcileDriver.value
            return
        }

        pendingScope = scope
        let driver = Task { @MainActor in
            while let next = self.pendingScope {
                self.pendingScope = nil
                self.activeScope = next
                await self.withStoreWriteTime {
                    await self.performSampleStayReconciliation(next)
                }
                self.activeScope = nil
            }
            // Same actor turn as the empty check: no request can slip in unserved.
            self.reconcileDriver = nil
        }
        reconcileDriver = driver
        await driver.value
    }

    private func performSampleStayReconciliation(_ scope: CaptureRebuildScope) async {
        await TimelineSchemaUpgrader.waitUntilFinished()
        // Once per version of the pace rules: history the weekly rebuild never revisits.
        if let defaults = paceRulesDefaults,
           defaults.integer(forKey: AutomaticModeHistory.paceRulesVersionKey) < AutomaticModeHistory.paceRulesVersion {
            do {
                let report = try repository.applyPaceRulesToHistory(now: now())
                defaults.set(AutomaticModeHistory.paceRulesVersion, forKey: AutomaticModeHistory.paceRulesVersionKey)
                if report.total > 0 {
                    Self.timelineLog.info("Relabeled \(report.total) foot trips whose pace ruled out feet")
                }
            } catch {
                Self.timelineLog.error("Failed to recheck foot trip paces: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            let now = self.now()
            let started = ContinuousClock.now
            stopStepEvidence.forget(before: now.addingTimeInterval(-8 * 24 * 60 * 60))
            // Read synchronously with the generation recorded: no write can interleave.
            runningInputs = (storeGeneration, scope)
            defer { runningInputs = nil }
            // Both entry points read the same pedometer answers, so a trip-only pass never
            // decides differently from the full week about the stops they share.
            let rebuild: () throws -> SampleStayReconciliationResult = { [repository, stopStepEvidence] in
                switch scope {
                case .week:
                    return try repository.reconcileSampleStays(now: now, steps: stopStepEvidence)
                case .recentTrip(let since):
                    // A clock set back can put `since` after now; the repository allows for it.
                    return try repository.reconcileRecentTrip(since: since, now: now, steps: stopStepEvidence)
                }
            }
            if case .week = scope { lastWeekRebuildReadAt = now }
            // The stop rules may ask about steps the pass has no answer for. Ask the
            // pedometer and rebuild again, until the rules ask nothing new: a question left
            // for the next pass would let that pass decide differently. (Holding the first
            // rebuild's writes and rolling them back would write each row once, but
            // `ModelContext.rollback()` aborted inside SwiftData on a real store copy.)
            var result = try rebuild()
            var queries = 0
            for _ in 0..<Self.stepRoundsPerPass {
                let wanted = stopStepEvidence.takeWanted()
                guard !wanted.isEmpty, queries < Self.stepQueriesPerPass else { break }
                for interval in wanted.prefix(Self.stepQueriesPerPass - queries) {
                    let steps = await motionClassifier.stepCount(start: interval.start, end: interval.end)
                    stopStepEvidence.record(steps, for: interval)
                    queries += 1
                }
                let earlier = result
                result = try rebuild()
                let survivors = earlier.newPlaces.filter { place in
                    !place.isDeleted && place.modelContext != nil && !TimelineRetirement.isRetired(place)
                        && !result.newPlaces.contains { $0.id == place.id }
                }
                result.newPlaces = survivors + result.newPlaces
            }
            _ = stopStepEvidence.takeWanted()
            rebuildCount += 1
            let rebuilt = ContinuousClock.now - started
            try await apply(result)
            let total = ContinuousClock.now - started
            Self.timelineLog.debug(
                "Rebuilt \(scope, privacy: .public) in \(Self.milliseconds(rebuilt)) ms (\(Self.milliseconds(total)) ms with classification)"
            )
        } catch {
            Self.timelineLog.error("Failed to rebuild stops from fixes: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// One-time repair of older trips that swallowed a stop, rebuilt from their own fixes.
    func repairLongHistoricalTrips() async {
        do {
            // Rebuilt trips have no motion history this far back, so most would read as
            // unsure. Nobody should be asked to review August because of an upgrade.
            for trip in try repository.implausiblyLongTrips() {
                try await apply(try repository.reconcileSampleStays(covering: trip), asksForReview: false)
            }
            for stretch in try repository.splitStopsAroundContainedOnes() {
                try await apply(try repository.reconcileSampleStays(covering: stretch), asksForReview: false)
            }
            try repository.repairTripLabels()
        } catch {
            Self.timelineLog.error("Failed to repair long trips: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What a trip looked like before a pass wrote it, to tell a change from a rewrite.
    private struct TripShape: Equatable {
        var mode: TransportMode
        var startDate: Date
        var endDate: Date
        var distanceMeters: Int

        init(_ move: MoveSegment) {
            mode = move.transportMode
            startDate = move.startDate
            endDate = move.endDate
            distanceMeters = Int(move.distanceMeters.rounded())
        }
    }

    private func apply(_ result: SampleStayReconciliationResult, asksForReview: Bool = true) async throws {
        var changedTrips = 0
        // Stops are read before the motion queries and looked up again by id after them,
        // never held across one: the person can delete a stop meanwhile on another context.
        let newPlaceIDs = result.newPlaces.map(\.id)
        for leg in result.moveLegs {
            guard Self.isLive(leg.startPlace), Self.isLive(leg.endPlace) else { continue }
            let startID = leg.startPlace.id
            let endID = leg.endPlace.id
            let before = leg.startPlace.outgoingMoves
                .first { $0.endPlace?.id == endID }
                .map(TripShape.init)
            let straightLine = leg.straightLineMeters > 0
                ? leg.straightLineMeters
                : CLLocation(latitude: leg.startPlace.latitude, longitude: leg.startPlace.longitude)
                    .distance(from: CLLocation(latitude: leg.endPlace.latitude, longitude: leg.endPlace.longitude))
            var steps = await motionClassifier.stepCount(start: leg.startDate, end: leg.endDate)
            if steps == nil, let id = leg.existingMoveID,
               let health = HealthStepEvidenceLookup.evidence(for: id)?.steps.known {
                // Older than the pedometer's week, or imported: Health may still know.
                steps = Int(health.rounded())
            }
            let duration = leg.endDate.timeIntervalSince(leg.startDate)

            let classification: (mode: TransportMode, confidence: Double)
            let afterLastBlock: TransportMode
            var transportMode: TransportMode
            var dominant: TransportMode?
            if let kept = leg.keptMode {
                // Only the trip's fixes, ends, or distance changed: its mode stands, unless
                // the steps now stored with it rule that mode out. The next pass checks the
                // stored trip with exactly that rule, so it is applied here, not there.
                classification = (kept, 1)
                afterLastBlock = kept
                transportMode = kept
                if let ruled = ImplausibleWalk.stepEvidenceMode(
                    proposed: kept,
                    straightLine: straightLine,
                    duration: duration,
                    stepCount: steps
                ) {
                    transportMode = automaticModes().allowedMode(ruled)
                }
            } else {
                classification = await motionClassifier.classifyTransport(
                    start: leg.startDate,
                    end: leg.endDate,
                    locations: leg.locations
                )
                dominant = await motionClassifier.dominantActivity(start: leg.startDate, end: leg.endDate)
                afterLastBlock = LastBlockWalk.mode(
                    proposed: classification.mode,
                    distance: straightLine,
                    duration: duration,
                    stepCount: steps
                )
                let proposedMode = ImplausibleWalk.refinedMode(
                    proposed: afterLastBlock,
                    straightLine: straightLine,
                    distance: leg.keptDistance ?? leg.distanceMeters,
                    duration: duration,
                    stepCount: steps,
                    dominantActivity: dominant,
                    locations: leg.locations
                )
                // Post-classification step/distance rules can change a mode too.
                // Read the current preference after the motion query awaits.
                transportMode = automaticModes().allowedMode(proposedMode)
            }
            guard let startPlace = try repository.livePlace(id: startID),
                  let endPlace = try repository.livePlace(id: endID) else { continue }

            var distance = leg.keptDistance ?? leg.distanceMeters
            if leg.keptDistance == nil,
               OnFootDistanceEstimate.applies(mode: transportMode, interiorFixCount: leg.interiorFixCount) {
                // Two or fewer fixes cannot draw a walk; steps measure it better.
                distance = OnFootDistanceEstimate.distance(
                    straightLine: straightLine,
                    stepCount: steps,
                    stride: Self.onFootStride()
                )
            }
            // The stored distance is what later checks read; the pace rule must agree with it,
            // or the next pass would relabel the trip it just wrote.
            if let paced = ImplausibleFootPace.mode(
                proposed: transportMode,
                distance: max(distance, straightLine),
                duration: duration,
                stepCount: steps,
                dominantActivity: dominant
            ) {
                transportMode = automaticModes().allowedMode(paced)
                distance = leg.keptDistance ?? leg.distanceMeters
            }
            let between = try repository.samples(from: leg.startDate, to: leg.endDate)
            let move = try repository.upsertMove(
                startPlace: startPlace,
                endPlace: endPlace,
                startDate: leg.startDate,
                endDate: leg.endDate,
                transportMode: transportMode,
                distanceMeters: distance,
                stepCount: steps,
                samples: between
            )
            // No fix between the stops: the path is a guess, shown as one.
            if leg.interiorFixCount == 0, move.routeMatchConfidence == .unknown, move.routeMatchSummary == nil {
                move.routeMatchConfidence = .estimated
                move.routeMatchSummary = RouteMatchSummaries.estimatedNoFixes
            }
            // Duplicate enrichment may supply an older guessed mode. It must
            // obey the same preference without touching a curated replacement.
            if move.permitsAutomaticModeChanges {
                let allowed = automaticModes().allowedMode(move.transportMode)
                if allowed != move.transportMode {
                    move.transportMode = allowed
                    move.clearCachedRouteCoordinates()
                    move.speedProfileData = nil
                }
            }
            if before != TripShape(move) {
                changedTrips += 1
            }
            // Ask only about what the rules left unsure, and never ask twice. A ride read
            // as a walk is one of those: the steps rule it out, but not which vehicle.
            // A ride with few steps that motion left unresolved is read as a ride, which is
            // the answer, not a question; only a relabeled walk or an unresolved result asks.
            let relabeledByRules = transportMode != afterLastBlock
                && (transportMode == .unknown || afterLastBlock == .walking || afterLastBlock == .running)
            let unsureOfMode = transportMode == classification.mode
                ? classification.confidence < TimelineReviewHeuristics.uncertainModeConfidence
                : relabeledByRules
            // Only recent, recorded trips are worth a question: nobody should be asked
            // about imported history or last month.
            if asksForReview, move.reviewState == .none, move.transportModeSource == .auto, unsureOfMode,
               self.now().timeIntervalSince(move.startDate) <= TimelineReviewHeuristics.newQuestionWindow,
               !TimelineReviewHeuristics.isImportedHistory(move) {
                move.reviewState = .pending
            }
            if asksForReview, TimelineReviewHeuristics.shouldAskAboutStay(startPlace) {
                startPlace.reviewState = .pending
            }
        }

        for id in newPlaceIDs {
            guard let place = try repository.livePlace(id: id) else { continue }
            try repository.applyPlaceLearning(to: place)
        }
        for id in newPlaceIDs.prefix(8) {
            await fillAutomaticPlaceLabelIfNeeded(forPlaceID: id)
        }
        try repository.saveIfNeeded()

        // A pass that only rewrote the same trips (an unknown mode retried) changed nothing.
        lastRebuildChanges = (result.newPlaces.count, changedTrips)
        if !result.newPlaces.isEmpty || changedTrips > 0 {
            Self.timelineLog.info(
                "Rebuilt \(result.newPlaces.count) stops and \(changedTrips) trips from stored fixes"
            )
        }
    }

    private static func isLive(_ place: VisitPlace) -> Bool {
        !place.isDeleted && !TimelineRetirement.isRetired(place)
    }

    /// Metres a step, for walks the fixes cannot draw. Health's learned k scales its own
    /// distance to the GPS ruler; applied to the nominal stride it does the same here.
    static func onFootStride(
        healthIsActive: Bool = HealthActivitySettings.isActive,
        calibration: () -> HealthStrideCalibration = { HealthStrideCalibrationStore.load() }
    ) -> CLLocationDistance {
        guard healthIsActive else { return OnFootDistanceEstimate.defaultStride }
        let learned = calibration()
        guard learned.isCalibrated else { return OnFootDistanceEstimate.defaultStride }
        return OnFootDistanceEstimate.defaultStride * learned.k
    }

    private func fillAutomaticPlaceLabelIfNeeded(forPlaceID placeID: UUID) async {
        guard let place = try? repository.livePlace(id: placeID) else { return }
        let hasUserLabel = !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAutoLabel = !(place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard place.assignmentSource == .none, place.knownPlace == nil else { return }
        guard !hasUserLabel, !hasAutoLabel else { return }
        guard place.horizontalAccuracy <= 180 else { return }

        // Earlier stays at this spot already have a name; a fresh geocode would only
        // add another house number for the same building.
        do {
            if let reused = try repository.reusableAutomaticLabel(for: placeID) {
                try repository.setAutomaticLabel(reused, for: placeID)
                try repository.saveIfNeeded()
                return
            }
        } catch {
            print("Failed to reuse a nearby place label: \(error.localizedDescription)")
        }

        // A lookup needs the network, and capture runs in the background where a request
        // can go unanswered. The place keeps no name for now; the backfill names it later.
        let resolver = placeNameResolver
        let coordinate = place.coordinate
        let name = await BoundedWait.run(seconds: 8, fallback: nil) {
            await resolver.resolveName(for: coordinate)
        }
        // The wait may have outlived the stay: it is not touched again, only its id and
        // where it was; `setAutomaticLabel` looks it up and skips one deleted or retired.
        if let resolvedName = name {
            do {
                let nearby = try repository.knownPlaces(
                    near: coordinate,
                    within: PlaceLearningEngine.rejectedLabelSearchRadius
                )
                if PlaceLearningEngine.shouldSuppress(resolvedName, nearbyPlaces: nearby) {
                    return
                }
                try repository.setAutomaticLabel(resolvedName, for: placeID)
                try repository.saveIfNeeded()
            } catch {
                print("Failed to persist automatic place label: \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
final class MovesLocationCaptureManager: NSObject, ObservableObject, LocationCaptureService {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring = false
    @Published private(set) var isBackgroundLocationListeningEnabled = true
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var temporaryRouteTrackingDuration: TemporaryRouteTrackingDuration = .endOfDay
    @Published private(set) var temporaryRouteTrackingStartedAt: Date?
    @Published private(set) var temporaryRouteTrackingEndsAt: Date?
    @Published private(set) var temporaryRouteTrackingStopsAtFiftyPercentBattery = false
    @Published private(set) var temporaryRouteTrackingStopsInLowPowerMode = false
    @Published private(set) var temporaryRouteTrackingStopNotificationEnabled = false
    @Published private(set) var captureDetailLevel: CaptureDetailLevel = .defaultLevel
    /// Location is allowed, but only approximately. Trips cannot be followed then.
    @Published private(set) var isPreciseLocationOff = false

    private static let captureLog = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Capture")
    private static let departureRegionIdentifier = "Moves.capture.departure"

    private let manager = CLLocationManager()
    private let userDefaults: UserDefaults
    #if targetEnvironment(simulator)
    let isDemoMode = true
    #else
    let isDemoMode = false
    #endif
    private let assembler: DefaultTimelineAssembler
    /// Every capture write goes through here, so fixes, visits, and rebuilds stay in order.
    private let pipeline: CaptureIngestPipeline
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    /// Route tracking ran out while the app was not running; its final rebuild is owed.
    private var routeTrackingExpiredWhileAway = false
    /// A departure circle iOS refused. Not registered again until the person settles elsewhere.
    private var failedDepartureAnchor: CaptureAnchor?
    /// This process removed the departure circle and has not registered one since.
    private var departureRegionKnownAbsent = false
    private let routeTrackingLiveActivity = RouteTrackingLiveActivityCoordinator()
    private var oneShotRequestGate = OneShotLocationRequestGate()
    private var pendingTemporaryRouteTrackingDuration: TemporaryRouteTrackingDuration?
    private var shouldChainToAlwaysAfterWhenInUse = false
    /// A standard location session (`startUpdatingLocation`) is running.
    private var isStandardLocationRunning = false
    /// Settled or following a trip, for balanced and detailed capture.
    private var captureMachine = CaptureStateMachine(level: .batterySaver, isListening: false, departureAnchor: nil, now: .now)
    private var fixFilter = CaptureFixFilter()
    private var reconcileThrottle = ReconcileThrottle()
    /// Continuous fixes waiting to be written, so the store is not saved every few seconds.
    private var pendingContinuousFixes: [CLLocation] = []
    private var pendingContinuousSince: Date?
    /// Fixes iOS delivered since the last heartbeat line, before any filtering.
    private var deliveredFixesSinceHeartbeat = 0
    private var lastDeliveredFixAt: Date?
    private var lastHeartbeatAt: Date?
    private var heartbeatTask: Task<Void, Never>?
    private var lastSessionRestartAt: Date?
    /// The last motion Core Motion was sure of. A second of "unknown" in the middle of a
    /// walk should not change how the walk is recorded.
    private var lastDefiniteMotion: (state: CaptureMotionState, at: Date)?
    private var lastStoredSettledFixAt: Date?
    private var appliedConfiguration: CaptureConfiguration?
    /// The distance filter for sessions that ask Core Location for every fix.
    private var distanceGate = CaptureDistanceGate()
    /// Held only while manual route tracking runs. iOS shows the location indicator in the
    /// Dynamic Island while one is held, and everyday capture must never show it
    /// (`CaptureConfiguration.showsLocationIndicator`).
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var appliedShowsIndicator = false
    private let motionActivityManager = CMMotionActivityManager()
    private var isReceivingMotionUpdates = false
    private var settleCheckTask: Task<Void, Never>?
    private var continuousSessionStartedAt: Date? {
        didSet {
            if followedTripStartedAt != continuousSessionStartedAt {
                followedTripStartedAt = continuousSessionStartedAt
            }
        }
    }
    /// When the trip being followed right now began, or nil while staying put. The
    /// timeline shows the trip in progress from the fixes recorded since then.
    @Published private(set) var followedTripStartedAt: Date?
    private var temporaryRouteTrackingExpiryTask: Task<Void, Never>?
    /// When the short post-ride / departure fix burst should stop.
    private var lastMileEndsAt: Date?
    /// When the current burst began, so a hike cannot chain bursts into all-day GPS.
    private var lastMileStartedAt: Date?
    private var lastMileExpiryTask: Task<Void, Never>?
    private var lastMileRecentLocations: [CLLocation] = []
    private var temporaryRouteTrackingEnergyStateObserverTokens: [NSObjectProtocol] = []

    private enum TemporaryRouteTrackingStorageKey {
        static let duration = "Moves.temporaryRouteTracking.duration"
        static let startedAt = "Moves.temporaryRouteTracking.startedAt"
        static let endsAt = "Moves.temporaryRouteTracking.endsAt"
        static let stopAtFiftyPercentBattery = "Moves.temporaryRouteTracking.stopAtFiftyPercentBattery"
        static let stopInLowPowerMode = "Moves.temporaryRouteTracking.stopInLowPowerMode"
        static let stopNotificationEnabled = "Moves.temporaryRouteTracking.stopNotificationEnabled"
    }

    enum BackgroundLocationListeningSettings {
        static let isEnabledKey = "Moves.backgroundLocationListening.isEnabled"
    }

    private static let stopNotificationIdentifier = "Moves.temporaryRouteTracking.stoppedNotification"

    private var shouldSkipLiveTracking: Bool {
        isDemoMode || ProcessInfo.processInfo.isRunningUnitTests
    }

    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
        let assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: CoreMotionTransportClassifier(defaults: userDefaults),
            placeNameResolver: CLGeocoderPlaceNameResolver(),
            automaticModes: { .load(from: userDefaults) }
        )
        self.assembler = assembler
        self.pipeline = CaptureIngestPipeline(assembler: assembler)

        super.init()

        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = CapturePolicy.Tuning.lowPowerAccuracy
        manager.distanceFilter = CapturePolicy.Tuning.lowPowerDistanceFilter
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false

        authorizationStatus = manager.authorizationStatus
        if !shouldSkipLiveTracking {
            UIDevice.current.isBatteryMonitoringEnabled = true
            installTemporaryRouteTrackingEnergyObservers()
        }
        restoreTemporaryRouteTrackingState()
        restoreBackgroundLocationListeningState()
        captureDetailLevel = CaptureDetailLevel.load(from: userDefaults)
        isPreciseLocationOff = isAuthorizedForTracking && !hasFullAccuracy
        let storedAnchor = shouldSkipLiveTracking ? nil : storedDepartureAnchor()
        captureMachine = CaptureStateMachine(
            level: captureDetailLevel,
            isListening: machineIsListening,
            departureAnchor: storedAnchor,
            now: .now
        )
        if !shouldSkipLiveTracking {
            Self.captureLog.notice(
                "Capture launched at \(self.captureDetailLevel.rawValue, privacy: .public), phase \(self.captureMachine.phase.rawValue, privacy: .public), departure circle \(storedAnchor == nil ? "none" : "kept", privacy: .public), authorization \(self.authorizationStatus.rawValue), precise \(self.hasFullAccuracy)"
            )
        }
        if captureMachine.phase == .moving {
            continuousSessionStartedAt = .now
            // Property observers do not run during init.
            followedTripStartedAt = continuousSessionStartedAt
            fixFilter.beginSession(at: .now)
        }
        updateBackgroundLocationAllowance()
        if !shouldSkipLiveTracking {
            installLifecycleObservers()
            startHeartbeat()
            if routeTrackingExpiredWhileAway {
                // The rebuild that ending it would have run.
                Self.captureLog.notice("Route tracking ended while Moves was not running; rebuilding")
                pipeline.rebuild(.week)
            }
        }
    }

    var trackingStatusText: String {
        if isDemoMode {
            return "Simulator demo mode"
        }

        if isTemporaryRouteTrackingActive {
            switch authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return "Route tracking on"
            case .notDetermined:
                return "Route tracking waiting for permission"
            case .denied, .restricted:
                return "Route tracking paused"
            @unknown default:
                return "Route tracking on"
            }
        }

        if isPreciseLocationOff, isBackgroundLocationListeningEnabled {
            // Approximate fixes are kilometres wide: places only, no trips.
            return "Precise Location off"
        }

        switch authorizationStatus {
        case .authorizedAlways:
            if isMonitoring {
                return "Tracking in background"
            }
            return isBackgroundLocationListeningEnabled ? "Ready" : "Background listening off"
        case .authorizedWhenInUse:
            return isBackgroundLocationListeningEnabled
                ? "Tracking only while app is active"
                : "Background listening off"
        case .denied:
            return "Location access denied"
        case .restricted:
            return "Location access restricted"
        case .notDetermined:
            return "Waiting for location permission"
        @unknown default:
            return "Unknown location state"
        }
    }

    func start() async {
        guard !shouldSkipLiveTracking else { return }

        let status = manager.authorizationStatus
        handleAuthorization(status)
        scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
        await routeTrackingLiveActivity.synchronize(
            startedAt: temporaryRouteTrackingStartedAt,
            endsAt: temporaryRouteTrackingEndsAt
        )

        if status == .notDetermined {
            requestTrackingAuthorization()
        }
    }

    func requestTrackingAuthorization() {
        guard !shouldSkipLiveTracking else { return }

        let status = manager.authorizationStatus
        authorizationStatus = status
        updateBackgroundLocationAllowance()

        switch status {
        case .notDetermined:
            shouldChainToAlwaysAfterWhenInUse = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            shouldChainToAlwaysAfterWhenInUse = false
            manager.requestAlwaysAuthorization()
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
        case .authorizedAlways:
            shouldChainToAlwaysAfterWhenInUse = false
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
        case .restricted, .denied:
            shouldChainToAlwaysAfterWhenInUse = false
            stop()
        @unknown default:
            shouldChainToAlwaysAfterWhenInUse = false
        }
    }

    func stop() {
        guard !shouldSkipLiveTracking else { return }

        storePendingContinuousFixes(reason: "capture stopped", rebuild: .none)
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        oneShotRequestGate.cancel()
        isMonitoring = false
        isStandardLocationRunning = false
        appliedConfiguration = nil
        distanceGate.reset()
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
        stopMotionUpdates()
        removeDepartureRegion()
        updateSettleChecks()
        Self.captureLog.notice("Capture stopped (authorization \(self.authorizationStatus.rawValue))")
    }

    func setBackgroundLocationListeningEnabled(_ isEnabled: Bool) {
        isBackgroundLocationListeningEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: BackgroundLocationListeningSettings.isEnabledKey)

        guard !shouldSkipLiveTracking else { return }

        Self.captureLog.notice("Background listening \(isEnabled ? "on" : "off", privacy: .public)")
        syncCaptureMachine()
        applyTrackingConfiguration()
    }

    /// Settings → Tracking detail.
    func setCaptureDetailLevel(_ level: CaptureDetailLevel) {
        guard level != captureDetailLevel else { return }
        let previous = captureDetailLevel
        captureDetailLevel = level
        level.save(to: userDefaults)

        guard !shouldSkipLiveTracking else { return }

        Self.captureLog.notice(
            "Tracking detail \(previous.rawValue, privacy: .public) -> \(level.rawValue, privacy: .public)"
        )
        syncCaptureMachine()
        applyTrackingConfiguration()
    }

    /// Whether balanced and detailed capture can follow trips right now. Approximate
    /// location fixes are kilometres wide, so the battery-saver behaviour is all that works.
    private var machineIsListening: Bool {
        !shouldSkipLiveTracking && isBackgroundLocationListeningEnabled && isAuthorizedForTracking && hasFullAccuracy
    }

    private var hasFullAccuracy: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    /// Tells the state machine about the level, listening, and permissions. Turning back on
    /// looks first: the old settled point may be stale.
    private func syncCaptureMachine(now: Date = .now) {
        handle(captureMachine.configure(level: captureDetailLevel, isListening: machineIsListening, now: now), now: now)
    }

    /// Fixes from photos taken with this phone's camera. They are stored like any other
    /// fix, and stops and trips are rebuilt with them.
    func ingestPhotoFixes(_ locations: [CLLocation]) async {
        guard !locations.isEmpty else { return }
        pipeline.store(locations, source: .cameraPhoto)
        pipeline.rebuild(.week)
        await pipeline.drain()
    }

    func refreshHistoricalBackfill() async {
        guard !shouldSkipLiveTracking else { return }

        guard isAuthorizedForTracking else { return }

        // iOS does not expose requestHistoricalLocations for third-party apps.
        // One current fix bridges a short silence, and the fixes already stored
        // are re-read so a missed visit does not stay a single multi-hour trip.
        requestOneShotLocation(source: .launchBackfill)
        // The app came forward: write what is buffered and rebuild the week, after
        // anything already queued.
        storePendingContinuousFixes(reason: "foreground", rebuild: .now(.week))
        await pipeline.drain()
    }

    func enableTemporaryRouteTracking(duration: TemporaryRouteTrackingDuration) {
        guard !shouldSkipLiveTracking else { return }
        guard isAuthorizedForTracking else {
            if authorizationStatus == .notDetermined {
                pendingTemporaryRouteTrackingDuration = duration
                requestTrackingAuthorization()
            }
            return
        }

        pendingTemporaryRouteTrackingDuration = nil

        temporaryRouteTrackingDuration = duration
        temporaryRouteTrackingStartedAt = .now
        temporaryRouteTrackingEndsAt = duration.endDate(from: .now)
        persistTemporaryRouteTrackingState()

        if shouldExpireTemporaryRouteTrackingNow {
            expireTemporaryRouteTracking(notifyImmediately: true)
            return
        }

        scheduleTemporaryRouteTrackingExpiryTask()
        scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
        applyTrackingConfiguration()
        requestOneShotLocation(source: .routeTracking)
        Task {
            await routeTrackingLiveActivity.synchronize(
                startedAt: temporaryRouteTrackingStartedAt,
                endsAt: temporaryRouteTrackingEndsAt
            )
        }
    }

    func enableTemporaryRouteTrackingStopNotifications() async -> TemporaryRouteTrackingStopNotificationPermissionResult {
        guard !shouldSkipLiveTracking else { return .enabled }

        temporaryRouteTrackingStopNotificationEnabled = true
        persistTemporaryRouteTrackingState()

        let status = await notificationAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
            return .enabled
        case .notDetermined:
            let granted = await requestNotificationAuthorization()
            if granted {
                scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
                return .enabled
            }
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        case .denied:
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        @unknown default:
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        }
    }

    func disableTemporaryRouteTrackingStopNotifications() {
        guard !shouldSkipLiveTracking else { return }

        temporaryRouteTrackingStopNotificationEnabled = false
        persistTemporaryRouteTrackingState()
        cancelTemporaryRouteTrackingStoppedNotification()
    }

    func updateTemporaryRouteTrackingAutoStopRules(
        stopsAtFiftyPercentBattery: Bool,
        stopsInLowPowerMode: Bool
    ) {
        guard !shouldSkipLiveTracking else { return }

        temporaryRouteTrackingStopsAtFiftyPercentBattery = stopsAtFiftyPercentBattery
        temporaryRouteTrackingStopsInLowPowerMode = stopsInLowPowerMode
        persistTemporaryRouteTrackingState()
        refreshTemporaryRouteTrackingStateIfNeeded()
    }

    func disableTemporaryRouteTracking() {
        guard !shouldSkipLiveTracking else { return }
        guard temporaryRouteTrackingEndsAt != nil else { return }

        cancelTemporaryRouteTrackingExpiryTask()
        temporaryRouteTrackingStartedAt = nil
        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
        notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded()
        routeTrackingDidEnd(reason: "stopped")
    }

    /// After manual route tracking: automatic capture resumes looking, as at launch, since
    /// the point it last settled at may be far away, and the stops get their final rebuild.
    private func routeTrackingDidEnd(reason: String) {
        Self.captureLog.notice("Route tracking ended (\(reason, privacy: .public))")
        Task {
            await routeTrackingLiveActivity.end()
        }
        pipeline.rebuild(.week)
        if isFollowingTrips {
            handle(captureMachine.restartLooking(now: .now))
        }
        applyTrackingConfiguration()
    }

    private var isAuthorizedForTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        let previous = (authorizationStatus, isPreciseLocationOff)
        authorizationStatus = status
        isPreciseLocationOff = isAuthorizedForTracking && !hasFullAccuracy
        if previous != (status, isPreciseLocationOff), !shouldSkipLiveTracking {
            Self.captureLog.notice(
                "Authorization \(previous.0.rawValue) -> \(status.rawValue), precise \(!self.isPreciseLocationOff)"
            )
            // Capture may be about to stop: write what is buffered first.
            storePendingContinuousFixes(reason: "authorization changed", rebuild: .none)
        }
        updateBackgroundLocationAllowance()
        refreshTemporaryRouteTrackingStateIfNeeded()
        if !shouldSkipLiveTracking {
            syncCaptureMachine()
        }

        switch status {
        case .notDetermined:
            stop()
        case .authorizedAlways:
            shouldChainToAlwaysAfterWhenInUse = false
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
            startPendingTemporaryRouteTrackingIfNeeded()
        case .authorizedWhenInUse:
            if shouldChainToAlwaysAfterWhenInUse {
                shouldChainToAlwaysAfterWhenInUse = false
                manager.requestAlwaysAuthorization()
            }

            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
            startPendingTemporaryRouteTrackingIfNeeded()
        case .restricted, .denied:
            shouldChainToAlwaysAfterWhenInUse = false
            pendingTemporaryRouteTrackingDuration = nil
            stop()
        @unknown default:
            shouldChainToAlwaysAfterWhenInUse = false
            stop()
        }
    }

    private func startPendingTemporaryRouteTrackingIfNeeded() {
        guard let duration = pendingTemporaryRouteTrackingDuration else { return }
        pendingTemporaryRouteTrackingDuration = nil
        enableTemporaryRouteTracking(duration: duration)
    }

    private func startLowPowerMonitoringIfNeeded() {
        guard isBackgroundLocationListeningEnabled else {
            manager.stopMonitoringVisits()
            isMonitoring = false
            return
        }
        guard !isMonitoring else { return }

        manager.startMonitoringVisits()
        isMonitoring = true
    }

    /// Balanced or detailed capture: follow trips and watch for departures.
    private var isFollowingTrips: Bool {
        !shouldSkipLiveTracking
            && captureDetailLevel.followsTrips
            && isBackgroundLocationListeningEnabled
            && captureMachine.phase != .off
    }

    private var currentEnergyState: CaptureEnergyState {
        let device = UIDevice.current
        let level = device.batteryLevel
        return CaptureEnergyState(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: level >= 0 ? level : nil,
            isCharging: device.batteryState == .charging || device.batteryState == .full
        )
    }

    private func applyTrackingConfiguration() {
        guard isAuthorizedForTracking else {
            stop()
            return
        }

        startLowPowerMonitoringIfNeeded()
        updateBackgroundLocationAllowance()

        if isTemporaryRouteTrackingActive {
            // Manual route tracking overrides every level, exactly as before.
            manager.stopMonitoringSignificantLocationChanges()
            applyLocationConfiguration(CapturePolicy.routeTracking)
            updateSettleChecks()
            return
        }

        if isFollowingTrips {
            // Significant changes and visits stay on in every phase: they relaunch the
            // app if iOS ends it, and visits still close stops.
            manager.startMonitoringSignificantLocationChanges()
            startMotionUpdatesIfNeeded()
            if lastMileEndsAt != nil {
                clearLastMile()
            }
            let configuration = CapturePolicy.configuration(
                level: captureDetailLevel,
                phase: captureMachine.phase,
                motion: profileMotion(now: .now),
                recentSpeed: fixFilter.lastAccepted?.speed,
                energy: currentEnergyState,
                isRouteTrackingActive: false
            )
            // Automatic capture never shows the location indicator or a Live Activity. The
            // standard session runs from the stop through the trip without restarting, so
            // it is never started anew in the background.
            applyLocationConfiguration(configuration)
            updateSettleChecks()
            ensureDepartureRegion()
            return
        }

        // Battery saver, listening off, or approximate location: the original behaviour.
        stopMotionUpdates()
        ensureDepartureRegion()
        updateSettleChecks()
        if isLastMileActive {
            // Visits stay on so a real stop still closes. Continuous fixes are
            // only for this short walk, at pedestrian accuracy.
            manager.stopMonitoringSignificantLocationChanges()
            applyLocationConfiguration(CapturePolicy.lastMile)
        } else {
            if isBackgroundLocationListeningEnabled {
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                isMonitoring = false
            }
            applyLocationConfiguration(CapturePolicy.lowPower)
        }
    }

    private func applyLocationConfiguration(_ configuration: CaptureConfiguration) {
        let showsIndicator = configuration.showsLocationIndicator && authorizationStatus == .authorizedAlways
        let isRunningAsWanted = isStandardLocationRunning == configuration.usesStandardLocationUpdates
        if configuration == appliedConfiguration, showsIndicator == appliedShowsIndicator, isRunningAsWanted {
            return
        }
        if configuration.mode != .continuous, !pendingContinuousFixes.isEmpty {
            // Route tracking, battery saver, or settling took over from following a trip.
            storePendingContinuousFixes(reason: "left continuous capture", rebuild: .none)
        }

        if !configuration.usesStandardLocationUpdates, isStandardLocationRunning {
            manager.stopUpdatingLocation()
            isStandardLocationRunning = false
        }
        if updateBackgroundActivitySession(for: configuration), isStandardLocationRunning {
            // The session has to exist before the updates start, so start them again.
            manager.stopUpdatingLocation()
            isStandardLocationRunning = false
        }
        manager.activityType = configuration.activityType
        manager.desiredAccuracy = configuration.desiredAccuracy
        // Following a trip and waiting for one ask for every fix, or iOS suspends the app
        // in the background; `distanceGate` then applies the configuration's filter.
        manager.distanceFilter = configuration.systemDistanceFilter
        manager.pausesLocationUpdatesAutomatically = configuration.pausesLocationUpdatesAutomatically
        manager.showsBackgroundLocationIndicator = showsIndicator
        if configuration.usesStandardLocationUpdates, !isStandardLocationRunning {
            manager.startUpdatingLocation()
            isStandardLocationRunning = true
        }

        if configuration != appliedConfiguration {
            Self.captureLog.notice(
                "Configuration: \(configuration.logDescription, privacy: .public) level=\(self.captureDetailLevel.rawValue, privacy: .public) phase=\(self.captureMachine.phase.rawValue, privacy: .public) motion=\(self.captureMachine.motion.rawValue, privacy: .public) constrained=\(self.currentEnergyState.isConstrained)"
            )
        }
        appliedConfiguration = configuration
        appliedShowsIndicator = showsIndicator
    }

    // MARK: Following trips

    private func handle(_ transition: CaptureStateMachine.Transition, now: Date = .now) {
        switch transition {
        case .none:
            return
        case .startedMoving(let trigger):
            Self.captureLog.notice(
                "Following a trip: started by \(trigger.rawValue, privacy: .public), motion \(self.captureMachine.motion.rawValue, privacy: .public)"
            )
            storePendingContinuousFixes(reason: "trip started", rebuild: .none, now: now)
            lastHeartbeatAt = nil
            deliveredFixesSinceHeartbeat = 0
            fixFilter.beginSession(at: now)
            continuousSessionStartedAt = now
        case .settled(let anchor, let verdict):
            let minutes = continuousSessionStartedAt.map { Int(now.timeIntervalSince($0) / 60) } ?? -1
            Self.captureLog.notice(
                "Settled (\(String(describing: verdict), privacy: .public)) after \(minutes) min: stored \(self.fixFilter.acceptedCount) fixes, dropped \(self.fixFilter.droppedCount) [\(self.fixFilter.dropSummary, privacy: .public)]"
            )
            if verdict.isMotionFalseAlarm, let until = captureMachine.motionTriggersSuppressedUntil {
                Self.captureLog.notice(
                    "Motion alone ignored for \(Int(until.timeIntervalSince(now) / 60)) min (\(self.captureMachine.motionFalseAlarms) false alarms in a row)"
                )
            }
            continuousSessionStartedAt = nil
            lastStoredSettledFixAt = now
            failedDepartureAnchor = nil
            storePendingContinuousFixes(reason: "settled", rebuild: .now(.week), now: now)
            if anchor?.supportsDepartureRegion != true {
                Self.captureLog.notice("Settled without a precise point; relying on motion, visits, and significant changes")
            }
        case .turnedOff:
            Self.captureLog.notice("Trip following off")
            continuousSessionStartedAt = nil
            storePendingContinuousFixes(reason: "following off", rebuild: .now(.week), now: now)
        }
        // Registers or removes the departure circle to match the new phase.
        applyTrackingConfiguration()
    }

    /// Fixes while balanced or detailed capture is on and route tracking is not.
    private func handleFollowedFixes(_ locations: [CLLocation]) {
        let now = Date.now
        var departureFixes: [CLLocation] = []

        for location in locations {
            let phaseBefore = captureMachine.phase
            if phaseBefore == .settled, !CaptureStateMachine.isCurrent(location, now: now) {
                // Starting significant-change monitoring hands back its last fix: hours old,
                // from the far end of the last trip. It is not a departure and not worth keeping.
                Self.captureLog.info(
                    "Ignored a cached fix from \(Int(now.timeIntervalSince(location.timestamp) / 60)) min ago while settled"
                )
                continue
            }
            let transition: CaptureStateMachine.Transition
            if phaseBefore == .settled, !isStandardLocationRunning {
                // No keep-alive session (balanced on low power): a fix while settled
                // is a significant-change wake.
                transition = captureMachine.handleWake(.significantChange, location: location, now: now)
            } else {
                transition = captureMachine.handleFix(location, now: now)
            }

            switch phaseBefore {
            case .moving:
                let minimumInterval = appliedConfiguration?.minimumInterval ?? 0
                let accepted = fixFilter.accept(
                    [location],
                    minimumInterval: minimumInterval,
                    straightSegmentInterval: appliedConfiguration?.straightSegmentInterval
                )
                if !accepted.isEmpty {
                    if pendingContinuousFixes.isEmpty { pendingContinuousSince = now }
                    pendingContinuousFixes.append(contentsOf: accepted)
                }
            case .settled:
                // Keep the first fix of a departure, and one now and then during a long stay.
                // The rest is the coarse keep-alive session and would only add jitter.
                if case .startedMoving(let trigger) = transition {
                    Self.captureLog.notice(
                        "Departure fix (\(trigger.rawValue, privacy: .public)): accuracy \(Int(location.horizontalAccuracy)) m, \(Int(now.timeIntervalSince(location.timestamp))) s old"
                    )
                    departureFixes.append(location)
                    lastStoredSettledFixAt = now
                } else if location.horizontalAccuracy >= 0,
                          location.horizontalAccuracy <= CapturePolicy.Tuning.absoluteMaximumAccuracy,
                          lastStoredSettledFixAt.map({ now.timeIntervalSince($0) >= CapturePolicy.Tuning.settledHeartbeatInterval }) ?? true {
                    departureFixes.append(location)
                    lastStoredSettledFixAt = now
                }
            case .off:
                break
            }

            handle(transition, now: now)
        }

        if !departureFixes.isEmpty {
            // The trip's first rebuild comes with its first buffered fixes.
            pipeline.store(departureFixes, source: .significantChange)
        }

        if CapturePolicy.shouldFlush(
            pendingCount: pendingContinuousFixes.count,
            oldestPendingAt: pendingContinuousSince,
            now: now
        ) {
            storePendingContinuousFixes(reason: "batch", rebuild: .throttled, now: now)
        }

        // Speed can change the travel kind (motion lags when boarding a bus).
        if captureMachine.phase == .moving {
            applyTrackingConfiguration()
        } else if captureMachine.phase == .settled {
            // A settled fix can sharpen the point the departure circle is drawn around.
            ensureDepartureRegion()
        }
    }

    private enum RebuildRequest {
        case none
        /// The trip so far, at most every `reconcileInterval`, when fixes were written.
        case throttled
        case now(CaptureRebuildScope)
    }

    /// Writes buffered continuous fixes through the pipeline, then rebuilds if asked.
    /// Called on every sign that the process may stop, so a kill loses as little as possible.
    private func storePendingContinuousFixes(reason: String, rebuild: RebuildRequest, now: Date = .now) {
        let fixes = pendingContinuousFixes
        pendingContinuousFixes.removeAll()
        pendingContinuousSince = nil

        let scope: CaptureRebuildScope?
        switch rebuild {
        case .none:
            scope = nil
        case .throttled:
            scope = !fixes.isEmpty && reconcileThrottle.shouldRun(at: now)
                ? tripRebuildScope(movingSince: captureMachine.movingSince, now: now)
                : nil
        case .now(let requested):
            reconcileThrottle.recordRun(at: now)
            scope = requested
        }
        guard !fixes.isEmpty || scope != nil else { return }

        if fixes.isEmpty {
            Self.captureLog.debug("Rebuild \(scope?.description ?? "-", privacy: .public) (\(reason, privacy: .public))")
        } else if reason == "batch" {
            Self.captureLog.debug("Writing \(fixes.count) continuous fixes, rebuild \(scope?.description ?? "-", privacy: .public)")
        } else {
            Self.captureLog.notice("Wrote \(fixes.count) buffered fixes (\(reason, privacy: .public)), rebuild \(scope?.description ?? "-", privacy: .public)")
        }
        pipeline.store(fixes, source: .continuous)
        if let scope {
            pipeline.rebuild(scope)
        }
    }

    private func tripRebuildScope(movingSince: Date?, now: Date) -> CaptureRebuildScope {
        CapturePolicy.tripRebuildScope(
            movingSince: movingSince,
            lastFullRebuildAt: assembler.lastWeekRebuildReadAt,
            now: now
        )
    }

    private func updateSettleChecks() {
        let needsChecks = isFollowingTrips
            && captureMachine.phase == .moving
            && !isTemporaryRouteTrackingActive
            && isAuthorizedForTracking
        guard needsChecks else {
            settleCheckTask?.cancel()
            settleCheckTask = nil
            return
        }
        guard settleCheckTask == nil else { return }

        let interval = CapturePolicy.Tuning.settleCheckInterval
        settleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.runSettleCheck()
            }
        }
    }

    /// No fixes arrive while standing still, so settling is noticed on a timer.
    private func runSettleCheck() {
        let now = Date.now
        if CapturePolicy.shouldFlush(
            pendingCount: pendingContinuousFixes.count,
            oldestPendingAt: pendingContinuousSince,
            now: now
        ) {
            storePendingContinuousFixes(reason: "batch", rebuild: .throttled, now: now)
        }
        logTripHeartbeat(now: now)
        restartSilentLocationSessionIfNeeded(now: now)
        handle(captureMachine.tick(now: now), now: now)
    }

    /// One line a minute while a trip is followed. The gap between two lines shows whether
    /// the app kept running, and the counts show what iOS delivered and what was kept.
    private func logTripHeartbeat(now: Date) {
        guard captureMachine.phase != .off, isFollowingTrips else { return }
        let isMoving = captureMachine.phase == .moving
        let sinceLast = lastHeartbeatAt.map { now.timeIntervalSince($0) }
        // Every minute on a trip, every five at a stop.
        if let sinceLast, sinceLast < (isMoving ? 60 : 300) { return }
        lastHeartbeatAt = now
        let lastFix = lastDeliveredFixAt.map { "\(Int(now.timeIntervalSince($0))) s ago" } ?? "none yet"
        let appState = UIApplication.shared.applicationState == .active ? "open" : "background"
        // Memory is here because a large app is the first one iOS ends in the background.
        let gap = (sinceLast.map { "\(Int($0)) s" } ?? "first")
            + ", memory \(Int(MapPerformanceProbe.memoryMegabytes())) MB"
            + ", background updates \(manager.allowsBackgroundLocationUpdates ? "allowed" : "not allowed")"
            + ", activity session \(backgroundActivitySession == nil ? "off" : "on")"
            + ", indicator \(manager.showsBackgroundLocationIndicator ? "on" : "off")"
            + ", updates \(isStandardLocationRunning ? "running" : "stopped")"
        if isMoving {
            Self.captureLog.notice(
                "Trip heartbeat: \(self.deliveredFixesSinceHeartbeat) fixes from iOS, \(self.fixFilter.acceptedCount) kept this trip, last \(lastFix, privacy: .public), \(self.pendingContinuousFixes.count) buffered, motion \(self.captureMachine.motion.rawValue, privacy: .public), app \(appState, privacy: .public), writes \(self.pipeline.statusDescription, privacy: .public), since last heartbeat \(gap, privacy: .public)"
            )
        } else {
            Self.captureLog.notice(
                "Stop heartbeat: \(self.deliveredFixesSinceHeartbeat) fixes from iOS, last \(lastFix, privacy: .public), motion \(self.captureMachine.motion.rawValue, privacy: .public), app \(appState, privacy: .public), writes \(self.pipeline.statusDescription, privacy: .public), since last heartbeat \(gap, privacy: .public)"
            )
        }
        deliveredFixesSinceHeartbeat = 0
    }

    /// Runs for the life of the process. It only writes log lines, and it does not keep the
    /// app awake: when iOS suspends the app the lines stop, which is what they are for.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.logTripHeartbeat(now: .now)
            }
        }
    }

    /// Holds a background activity session while manual route tracking runs, and ends it
    /// otherwise. Returns true when one was just created. iOS shows the location indicator
    /// for as long as a session is held, so everyday capture never holds one.
    private func updateBackgroundActivitySession(for configuration: CaptureConfiguration) -> Bool {
        let wanted = configuration.showsLocationIndicator && isAuthorizedForTracking
        if wanted, backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
            Self.captureLog.notice("Background activity session started")
            return true
        }
        if !wanted, let session = backgroundActivitySession {
            session.invalidate()
            backgroundActivitySession = nil
            Self.captureLog.notice("Background activity session ended")
        }
        return false
    }

    /// A location session can go quiet while the person is plainly moving. Starting it
    /// again costs nothing and brings the fixes back.
    private func restartSilentLocationSessionIfNeeded(now: Date) {
        guard captureMachine.phase == .moving, isStandardLocationRunning, !isTemporaryRouteTrackingActive,
              profileMotion(now: now).isMoving
        else { return }
        let quietSince = lastDeliveredFixAt ?? continuousSessionStartedAt ?? now
        guard now.timeIntervalSince(quietSince) >= 90 else { return }
        if let lastSessionRestartAt, now.timeIntervalSince(lastSessionRestartAt) < 120 { return }
        lastSessionRestartAt = now
        Self.captureLog.notice(
            "No fixes for \(Int(now.timeIntervalSince(quietSince))) s while \(self.captureMachine.motion.rawValue, privacy: .public); restarted location updates"
        )
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    /// The motion that decides how a trip is recorded: the live one, or the last sure one
    /// for half a minute after Core Motion stops being sure.
    private func profileMotion(now: Date) -> CaptureMotionState {
        let live = captureMachine.motion
        guard live == .unknown, let last = lastDefiniteMotion,
              now.timeIntervalSince(last.at) <= 30
        else { return live }
        return last.state
    }

    private func startMotionUpdatesIfNeeded() {
        guard !isReceivingMotionUpdates,
              CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized
        else { return }

        isReceivingMotionUpdates = true
        motionActivityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated {
                self?.handleMotionActivity(activity)
            }
        }
        Self.captureLog.notice("Live motion updates on")
    }

    private func stopMotionUpdates() {
        guard isReceivingMotionUpdates else { return }
        motionActivityManager.stopActivityUpdates()
        isReceivingMotionUpdates = false
        Self.captureLog.notice("Live motion updates off")
    }

    private func handleMotionActivity(_ activity: CMMotionActivity) {
        let state = CaptureMotionState.from(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive,
            isLowConfidence: activity.confidence == .low
        )
        let previous = captureMachine.motion
        if state.isMoving {
            lastDefiniteMotion = (state, .now)
        } else if state == .stationary {
            lastDefiniteMotion = nil
        }
        guard isFollowingTrips, !isTemporaryRouteTrackingActive else {
            // Route tracking is in charge: remember the motion, but start nothing.
            captureMachine.noteMotion(state)
            return
        }
        let transition = captureMachine.handleMotion(state, now: .now)
        if state != previous {
            Self.captureLog.info("Motion \(previous.rawValue, privacy: .public) -> \(state.rawValue, privacy: .public)")
        }
        if transition != .none {
            handle(transition)
        } else if state != previous, captureMachine.phase == .moving {
            applyTrackingConfiguration()
        }
    }

    // MARK: Departure circle

    private func storedDepartureAnchor() -> CaptureAnchor? {
        guard let region = manager.monitoredRegions
            .first(where: { $0.identifier == Self.departureRegionIdentifier }) as? CLCircularRegion
        else { return nil }
        return CaptureAnchor(
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            horizontalAccuracy: 0
        )
    }

    /// Registers, moves, or removes the one departure circle so it matches the phase,
    /// the settled point, and the permissions. Never more than one; never left behind.
    private func ensureDepartureRegion() {
        guard !shouldSkipLiveTracking else { return }
        // While route tracking runs, a circle from before stays: leaving it relaunches
        // the app if iOS ends it, and route tracking then resumes.
        guard !isTemporaryRouteTrackingActive else { return }

        let monitoringAvailable = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        let wanted = CapturePolicy.departureRegion(
            followsTrips: isFollowingTrips,
            phase: captureMachine.phase,
            anchor: captureMachine.departureAnchor,
            isAlwaysAuthorized: authorizationStatus == .authorizedAlways,
            hasFullAccuracy: hasFullAccuracy,
            maximumMonitoringDistance: monitoringAvailable ? manager.maximumRegionMonitoringDistance : -1
        )
        guard let wanted, wanted.anchor != failedDepartureAnchor else {
            // Called on every batch while following a trip; skip the lookup once gone.
            if !departureRegionKnownAbsent {
                removeDepartureRegion()
            }
            return
        }

        let existing = manager.monitoredRegions
            .filter { $0.identifier == Self.departureRegionIdentifier }
            .compactMap { $0 as? CLCircularRegion }
        let center = CLLocation(latitude: wanted.anchor.latitude, longitude: wanted.anchor.longitude)
        if existing.count == 1, let region = existing.first,
           abs(region.radius - wanted.radius) < 1,
           CLLocation(latitude: region.center.latitude, longitude: region.center.longitude).distance(from: center) < 1 {
            return
        }
        registerDepartureRegion(around: wanted.anchor, radius: wanted.radius)
    }

    /// Leaving this circle wakes or relaunches the app, even when it is suspended.
    /// Registering under the same identifier replaces the previous circle.
    private func registerDepartureRegion(around anchor: CaptureAnchor, radius: CLLocationDistance) {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude),
            radius: radius,
            identifier: Self.departureRegionIdentifier
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        departureRegionKnownAbsent = false
        Self.captureLog.notice("Watching for departure: \(Int(radius)) m circle, point accuracy \(Int(anchor.horizontalAccuracy)) m")
    }

    private func removeDepartureRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.departureRegionIdentifier {
            manager.stopMonitoring(for: region)
            Self.captureLog.notice("Departure circle removed")
        }
        departureRegionKnownAbsent = true
    }

    // MARK: Battery saver's burst

    /// Records the walk off a bus, or the first minutes after leaving on foot.
    ///
    /// Significant-change updates are about 500 metres apart, so the last
    /// couple of blocks never arrive. A ten-minute pedestrian session covers
    /// that without leaving navigation GPS on for the rest of the day.
    /// Battery saver only; the other levels follow the whole trip.
    private func startLastMileTracking() {
        guard !shouldSkipLiveTracking else { return }
        guard !isTemporaryRouteTrackingActive else { return }
        guard !isFollowingTrips else { return }
        guard isAuthorizedForTracking else { return }
        guard isBackgroundLocationListeningEnabled else { return }

        let now = Date.now
        if lastMileStartedAt == nil {
            lastMileStartedAt = now
        }
        guard let startedAt = lastMileStartedAt else { return }
        let cap = startedAt.addingTimeInterval(CapturePolicy.Tuning.lastMileMaximumDuration)
        guard now < cap else { return }

        lastMileEndsAt = min(now.addingTimeInterval(CapturePolicy.Tuning.lastMileDuration), cap)
        Self.captureLog.notice("Battery saver burst started")
        scheduleLastMileExpiry()
        applyTrackingConfiguration()
    }

    private var isLastMileActive: Bool {
        guard let lastMileEndsAt else { return false }
        return lastMileEndsAt > .now
    }

    private func scheduleLastMileExpiry() {
        lastMileExpiryTask?.cancel()
        guard let endsAt = lastMileEndsAt else { return }
        let seconds = endsAt.timeIntervalSinceNow
        guard seconds > 0 else {
            expireLastMile()
            return
        }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        lastMileExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.lastMileEndsAt == endsAt else { return }
                self.expireLastMile()
            }
        }
    }

    private func clearLastMile() {
        lastMileEndsAt = nil
        lastMileStartedAt = nil
        lastMileRecentLocations.removeAll()
        lastMileExpiryTask?.cancel()
        lastMileExpiryTask = nil
    }

    private func expireLastMile() {
        guard lastMileEndsAt != nil else { return }
        clearLastMile()
        Self.captureLog.notice("Battery saver burst ended")
        applyTrackingConfiguration()
    }

    /// Ends the burst once the walk has clearly stopped, so sitting down does
    /// not keep the radio on for the full ten minutes.
    private func stopLastMileIfSettled(_ locations: [CLLocation]) {
        guard isLastMileActive else { return }
        lastMileRecentLocations.append(contentsOf: locations)
        if lastMileRecentLocations.count > 16 {
            lastMileRecentLocations.removeFirst(lastMileRecentLocations.count - 16)
        }
        guard let newest = lastMileRecentLocations.last,
              let origin = lastMileRecentLocations.first
        else { return }

        let hasMoved = lastMileRecentLocations.contains { $0.distance(from: origin) > 40 }
        guard hasMoved else { return }
        guard let settledSince = lastMileRecentLocations.first(where: {
            newest.timestamp.timeIntervalSince($0.timestamp) >= 90
        }) else { return }

        let settled = lastMileRecentLocations
            .filter { $0.timestamp >= settledSince.timestamp }
            .allSatisfy { $0.distance(from: newest) <= 30 }
        if settled {
            expireLastMile()
        }
    }

    private func requestOneShotLocation(source: LocationSampleSource) {
        guard isAuthorizedForTracking,
              isBackgroundLocationListeningEnabled || isTemporaryRouteTrackingActive || isLastMileActive,
              !isStandardLocationRunning,
              oneShotRequestGate.begin(source: source, at: .now) else { return }
        manager.requestLocation()
    }

    private func updateBackgroundLocationAllowance() {
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
            && (isBackgroundLocationListeningEnabled || isTemporaryRouteTrackingActive || isLastMileActive)
    }

    private func restoreBackgroundLocationListeningState() {
        if userDefaults.object(forKey: BackgroundLocationListeningSettings.isEnabledKey) == nil {
            isBackgroundLocationListeningEnabled = true
        } else {
            isBackgroundLocationListeningEnabled = userDefaults.bool(
                forKey: BackgroundLocationListeningSettings.isEnabledKey
            )
        }
    }

    var isTemporaryRouteTrackingActive: Bool {
        guard let endsAt = temporaryRouteTrackingEndsAt else { return false }
        return endsAt > .now
    }

    private func refreshTemporaryRouteTrackingStateIfNeeded() {
        guard let endsAt = temporaryRouteTrackingEndsAt else { return }

        if endsAt <= .now {
            expireTemporaryRouteTracking()
            return
        }

        if shouldExpireTemporaryRouteTrackingNow {
            expireTemporaryRouteTracking(notifyImmediately: true)
        }
    }

    private func restoreTemporaryRouteTrackingState() {
        if let durationRawValue = userDefaults.string(forKey: TemporaryRouteTrackingStorageKey.duration),
           let duration = TemporaryRouteTrackingDuration(rawValue: durationRawValue) {
            temporaryRouteTrackingDuration = duration
        }

        temporaryRouteTrackingStartedAt = userDefaults.object(
            forKey: TemporaryRouteTrackingStorageKey.startedAt
        ) as? Date

        temporaryRouteTrackingStopsAtFiftyPercentBattery = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopAtFiftyPercentBattery
        )
        temporaryRouteTrackingStopsInLowPowerMode = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopInLowPowerMode
        )
        temporaryRouteTrackingStopNotificationEnabled = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopNotificationEnabled
        )

        guard let storedEndsAt = userDefaults.object(forKey: TemporaryRouteTrackingStorageKey.endsAt) as? Date else {
            return
        }

        if storedEndsAt > .now {
            temporaryRouteTrackingEndsAt = storedEndsAt
            if temporaryRouteTrackingStartedAt == nil,
               let interval = temporaryRouteTrackingDuration.timeInterval {
                temporaryRouteTrackingStartedAt = storedEndsAt.addingTimeInterval(-interval)
            }
            if shouldExpireTemporaryRouteTrackingNow {
                expireTemporaryRouteTracking(notifyImmediately: true)
                return
            }
            scheduleTemporaryRouteTrackingExpiryTask()
            scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
            return
        }

        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
        routeTrackingExpiredWhileAway = true
    }

    private func scheduleTemporaryRouteTrackingExpiryTask() {
        cancelTemporaryRouteTrackingExpiryTask()

        guard let endsAt = temporaryRouteTrackingEndsAt else { return }
        let secondsUntilExpiry = endsAt.timeIntervalSinceNow
        guard secondsUntilExpiry > 0 else {
            expireTemporaryRouteTracking()
            return
        }

        let nanoseconds = UInt64((secondsUntilExpiry * 1_000_000_000).rounded())
        temporaryRouteTrackingExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            await MainActor.run {
                self?.expireTemporaryRouteTrackingIfStillCurrent(expectedEndDate: endsAt)
            }
        }
    }

    private func cancelTemporaryRouteTrackingExpiryTask() {
        temporaryRouteTrackingExpiryTask?.cancel()
        temporaryRouteTrackingExpiryTask = nil
    }

    private func persistTemporaryRouteTrackingState() {
        userDefaults.set(temporaryRouteTrackingDuration.rawValue, forKey: TemporaryRouteTrackingStorageKey.duration)
        if let temporaryRouteTrackingStartedAt {
            userDefaults.set(temporaryRouteTrackingStartedAt, forKey: TemporaryRouteTrackingStorageKey.startedAt)
        } else {
            userDefaults.removeObject(forKey: TemporaryRouteTrackingStorageKey.startedAt)
        }
        userDefaults.set(
            temporaryRouteTrackingStopsAtFiftyPercentBattery,
            forKey: TemporaryRouteTrackingStorageKey.stopAtFiftyPercentBattery
        )
        userDefaults.set(
            temporaryRouteTrackingStopsInLowPowerMode,
            forKey: TemporaryRouteTrackingStorageKey.stopInLowPowerMode
        )
        userDefaults.set(
            temporaryRouteTrackingStopNotificationEnabled,
            forKey: TemporaryRouteTrackingStorageKey.stopNotificationEnabled
        )

        if let temporaryRouteTrackingEndsAt {
            userDefaults.set(temporaryRouteTrackingEndsAt, forKey: TemporaryRouteTrackingStorageKey.endsAt)
        } else {
            userDefaults.removeObject(forKey: TemporaryRouteTrackingStorageKey.endsAt)
        }
    }

    private func expireTemporaryRouteTracking() {
        expireTemporaryRouteTracking(notifyImmediately: false)
    }

    private func expireTemporaryRouteTracking(notifyImmediately: Bool) {
        cancelTemporaryRouteTrackingExpiryTask()
        temporaryRouteTrackingStartedAt = nil
        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
        if notifyImmediately {
            notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded()
        }
        routeTrackingDidEnd(reason: notifyImmediately ? "battery or Low Power Mode rule" : "time up")
    }

    private func expireTemporaryRouteTrackingIfStillCurrent(expectedEndDate: Date) {
        guard temporaryRouteTrackingEndsAt == expectedEndDate else { return }
        guard expectedEndDate <= .now else { return }
        expireTemporaryRouteTracking()
    }

    private var shouldExpireTemporaryRouteTrackingNow: Bool {
        if temporaryRouteTrackingStopsInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }

        if temporaryRouteTrackingStopsAtFiftyPercentBattery {
            let batteryLevel = UIDevice.current.batteryLevel
            if batteryLevel >= 0 && batteryLevel <= 0.5 {
                return true
            }
        }

        return false
    }

    private func installTemporaryRouteTrackingEnergyObservers() {
        let center = NotificationCenter.default

        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                    self?.energyStateDidChange()
                }
            }
        )
        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                    self?.energyStateDidChange()
                }
            }
        )
        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                    self?.energyStateDidChange()
                }
            }
        )
    }

    /// Signs that the process may stop soon, and clock jumps. Buffered fixes are written on
    /// each; the pipeline holds a background task until the write lands.
    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        let flushOn: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory warning"),
        ]
        for (name, reason) in flushOn {
            lifecycleObserverTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.storePendingContinuousFixes(reason: reason, rebuild: .none)
                    }
                }
            )
        }
        lifecycleObserverTokens.append(
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.writeEverythingBeforeTermination()
                }
            }
        )
        lifecycleObserverTokens.append(
            center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemClockDidChange()
                }
            }
        )
    }

    /// Nothing async runs after this returns, so the writes happen here, on this thread.
    private func writeEverythingBeforeTermination() {
        let queued = pipeline.writeQueuedFixesBeforeTermination()
        let buffered = pendingContinuousFixes
        pendingContinuousFixes.removeAll()
        pendingContinuousSince = nil
        assembler.storeImmediately(buffered, source: .continuous)
        Self.captureLog.notice("Terminating: wrote \(queued) queued and \(buffered.count) buffered fixes")
    }

    /// The clock was set by hand or by the network. Fix timestamps follow the new clock,
    /// so timers that compare them with older ones start over.
    private func systemClockDidChange() {
        let now = Date.now
        Self.captureLog.notice("System clock changed; capture timers restart")
        captureMachine.clockDidChange(now: now)
        fixFilter.restartClock(at: now)
        reconcileThrottle = ReconcileThrottle()
        if !pendingContinuousFixes.isEmpty {
            pendingContinuousSince = now
        }
        if continuousSessionStartedAt != nil {
            continuousSessionStartedAt = now
        }
    }

    /// Balanced capture thins out in Low Power Mode or on a low battery.
    private func energyStateDidChange() {
        guard isFollowingTrips, !isTemporaryRouteTrackingActive, isAuthorizedForTracking else { return }
        applyTrackingConfiguration()
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestNotificationAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded() {
        guard temporaryRouteTrackingStopNotificationEnabled else { return }
        guard let endsAt = temporaryRouteTrackingEndsAt, endsAt > .now else { return }

        Task { @MainActor in
            guard temporaryRouteTrackingStopNotificationEnabled,
                  temporaryRouteTrackingEndsAt == endsAt else {
                return
            }

            let authorizationStatus = await notificationAuthorizationStatus()
            guard authorizationStatus == .authorized ||
                authorizationStatus == .provisional ||
                authorizationStatus == .ephemeral else {
                cancelTemporaryRouteTrackingStoppedNotification()
                return
            }

            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Route tracking stopped"
            content.body = "Moves switched back to lower-power tracking."
            content.sound = .default

            let interval = max(endsAt.timeIntervalSinceNow, 1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.stopNotificationIdentifier,
                content: content,
                trigger: trigger
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.stopNotificationIdentifier])
            center.add(request) { _ in }
        }
    }

    private func cancelTemporaryRouteTrackingStoppedNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.stopNotificationIdentifier]
        )
    }

    private func notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded() {
        guard temporaryRouteTrackingStopNotificationEnabled else { return }

        Task { @MainActor in
            cancelTemporaryRouteTrackingStoppedNotification()

            guard temporaryRouteTrackingStopNotificationEnabled else { return }

            let authorizationStatus = await notificationAuthorizationStatus()
            guard authorizationStatus == .authorized ||
                authorizationStatus == .provisional ||
                authorizationStatus == .ephemeral else {
                return
            }

            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Route tracking stopped"
            content.body = "Moves switched back to lower-power tracking."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: Self.stopNotificationIdentifier,
                content: content,
                trigger: nil
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.stopNotificationIdentifier])
            center.add(request) { _ in }
        }
    }
}

extension MovesLocationCaptureManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard isBackgroundLocationListeningEnabled else { return }

        refreshTemporaryRouteTrackingStateIfNeeded()

        let visitTimestamp = visit.arrivalDate == .distantPast ? Date.now : visit.arrivalDate
        let visitLocation = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: max(visit.horizontalAccuracy, 20),
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: visitTimestamp
        )

        lastCaptureAt = .now

        if isFollowingTrips {
            // A fresh departure is a sign of movement. Visits often arrive late, so
            // an old one is only history.
            let departedRecently = visit.departureDate != .distantFuture
                && Date.now.timeIntervalSince(visit.departureDate) < 10 * 60
            Self.captureLog.info(
                "Visit \(visit.departureDate == .distantFuture ? "arrival" : "departure", privacy: .public), accuracy \(Int(visit.horizontalAccuracy)) m"
            )
            if departedRecently, !isTemporaryRouteTrackingActive {
                handle(captureMachine.handleWake(.visitDeparture, location: nil, now: .now))
            }
            // A visit wakes the app, so it is also a moment to notice a session gone quiet.
            restartSilentLocationSessionIfNeeded(now: .now)
            // The visit rebuilds the week; the pipeline writes buffered fixes before it.
            storePendingContinuousFixes(reason: "visit", rebuild: .none)
            reconcileThrottle.recordRun(at: .now)
            pipeline.store([visitLocation], source: .visit)
            pipeline.visit(visit)
            return
        }

        // Storing the visit rebuilds the week, with its fix already written.
        pipeline.store([visitLocation], source: .visit)
        pipeline.visit(visit)
        pipeline.run("last-mile check after a visit") { [weak self] in
            guard let self else { return }
            // Getting off a bus is a visit. The walk to the door happens in
            // the next few minutes, and significant-change will not see it.
            if await self.assembler.approachWasAutomotive(before: visitTimestamp) {
                self.startLastMileTracking()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        deliveredFixesSinceHeartbeat += locations.count
        lastDeliveredFixAt = .now
        refreshTemporaryRouteTrackingStateIfNeeded()

        let pendingOneShotLocationSource = oneShotRequestGate.takeSource(at: .now)
        guard pendingOneShotLocationSource != nil
            || isTemporaryRouteTrackingActive
            || isLastMileActive
            || isBackgroundLocationListeningEnabled
        else { return }

        if pendingOneShotLocationSource == nil, !isTemporaryRouteTrackingActive, isFollowingTrips {
            oneShotRequestGate.cancel()
            var followed = locations
            if let configuration = appliedConfiguration, configuration.asksForEveryFix, isStandardLocationRunning {
                followed = distanceGate.pass(locations, minimumDistance: configuration.distanceFilter)
                guard !followed.isEmpty else { return }
            }
            lastCaptureAt = .now
            handleFollowedFixes(followed)
            return
        }

        // A fix requested at launch can come back cached, minutes old and still at the last
        // place. Stored as new, it reads as more time spent there and splits a stay in two.
        var locations = locations
        if pendingOneShotLocationSource != nil {
            locations = locations.filter { CaptureStateMachine.isCurrent($0, now: .now) }
            guard !locations.isEmpty else {
                Self.captureLog.info("Ignored a cached launch fix")
                return
            }
        }

        let idleFor = lastCaptureAt.map { Date.now.timeIntervalSince($0) }
        lastCaptureAt = .now
        let source: LocationSampleSource
        if let pendingOneShotLocationSource {
            source = pendingOneShotLocationSource
        } else if isTemporaryRouteTrackingActive {
            source = .routeTracking
        } else if isLastMileActive {
            source = .lastMile
        } else {
            source = .significantChange
        }
        oneShotRequestGate.cancel()

        // A one-shot fix while settled can still show the person has left.
        if isFollowingTrips, !isTemporaryRouteTrackingActive {
            for location in locations {
                handle(captureMachine.handleFix(location, now: .now))
            }
        }

        // Route tracking delivers a fix every few metres. Rebuilding a week of stops
        // for each one is wasted work; rebuild the tracked stretch every few minutes,
        // and the week when tracking ends.
        let rebuild: CaptureRebuildScope?
        if source == .routeTracking {
            rebuild = reconcileThrottle.shouldRun(at: .now)
                ? tripRebuildScope(movingSince: temporaryRouteTrackingStartedAt, now: .now)
                : nil
            // The Live Activity is not a store write; it updates as before.
            Task {
                await routeTrackingLiveActivity.record(locations, endsAt: temporaryRouteTrackingEndsAt)
            }
        } else {
            rebuild = .week
        }
        pipeline.store(locations, source: source)
        if let rebuild {
            pipeline.rebuild(rebuild)
        }

        // Left somewhere on foot after a long pause. Catch the rest of
        // the walk; a ride keeps the cheaper significant-change stream.
        if !isFollowingTrips, source == .significantChange, let idleFor, idleFor >= 8 * 60 {
            pipeline.run("last-mile check after a pause") { [weak self] in
                guard let self else { return }
                if await self.assembler.recentlyWalking(at: Date()) {
                    self.startLastMileTracking()
                }
            }
        }

        if source == .lastMile {
            stopLastMileIfSettled(locations)
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.departureRegionIdentifier else { return }
        Self.captureLog.notice("Left the departure circle")
        guard isFollowingTrips else {
            removeDepartureRegion()
            return
        }
        guard !isTemporaryRouteTrackingActive else { return }
        handle(captureMachine.handleWake(.regionExit, location: nil, now: .now))
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.departureRegionIdentifier else { return }
        Self.captureLog.error("Departure circle failed: \((error as NSError).code); relying on motion, visits, and significant changes")
        // Not retried at this point: the same request would fail the same way. A new
        // settled point gets a new attempt.
        failedDepartureAnchor = captureMachine.departureAnchor
        removeDepartureRegion()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Self.captureLog.notice("Location updates paused by iOS")
        storePendingContinuousFixes(reason: "updates paused", rebuild: .none)
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Self.captureLog.notice("Location updates resumed by iOS")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed request must not leave future callbacks tagged as its result.
        oneShotRequestGate.cancel()
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.locationUnknown.rawValue {
            return
        }

        Self.captureLog.error("Location error \(nsError.code)")
        lastErrorMessage = error.localizedDescription
        // Denied, or the session broke: nothing more may arrive, so keep what came.
        storePendingContinuousFixes(reason: "location error", rebuild: .none)
    }
}
