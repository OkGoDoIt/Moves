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

protocol MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode
    func stepCount(start: Date, end: Date) async -> Int?
    /// True when the minutes before `date` include a vehicle ride.
    func approachWasAutomotive(before date: Date) async -> Bool
    /// True when the last few minutes are on foot and not in a vehicle.
    func recentlyWalking(at date: Date) async -> Bool
}

extension MotionClassifier {
    func approachWasAutomotive(before date: Date) async -> Bool { false }
    func recentlyWalking(at date: Date) async -> Bool { false }
}

protocol PlaceNameResolver {
    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String?
}

@MainActor
protocol TimelineAssembler {
    func ingestVisit(_ visit: CLVisit) async
    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async
    func reconcileSampleStays() async
    func approachWasAutomotive(before date: Date) async -> Bool
    func recentlyWalking(at date: Date) async -> Bool
}

final class CoreMotionTransportClassifier: MotionClassifier {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private static let minimumDistanceForNonStationaryOverride: CLLocationDistance = 450

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode {
        guard end > start else { return .stationary }
        let fallback = inferFromSpeed(locations)

        if CMMotionActivityManager.isActivityAvailable(),
           let activities = await queryActivities(from: start, to: end),
           !activities.isEmpty {
            var scores: [TransportMode: Int] = [:]

            for activity in activities {
                let weight = confidenceWeight(for: activity.confidence)
                if activity.automotive { scores[.automotive, default: 0] += weight }
                if activity.cycling { scores[.cycling, default: 0] += weight }
                if activity.running { scores[.running, default: 0] += weight }
                if activity.walking { scores[.walking, default: 0] += weight }
                if activity.stationary { scores[.stationary, default: 0] += weight }
            }

            if let best = scores.max(by: { $0.value < $1.value })?.key {
                let corrected = correctedModeIfNeeded(best, fallback: fallback, locations: locations)
                let refined = refinedLongDistanceMode(for: corrected, fallback: fallback, locations: locations)
                return Self.rejectingImplausibleContinuousTrip(
                    refined,
                    duration: end.timeIntervalSince(start),
                    straightLineDistance: Self.straightLineDistance(for: locations)
                )
            }
        }

        let corrected = correctedModeIfNeeded(fallback, fallback: fallback, locations: locations)
        let refined = refinedLongDistanceMode(for: corrected, fallback: fallback, locations: locations)
        return Self.rejectingImplausibleContinuousTrip(
            refined,
            duration: end.timeIntervalSince(start),
            straightLineDistance: Self.straightLineDistance(for: locations)
        )
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

    func stepCount(start: Date, end: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable(), end > start else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }

    private func queryActivities(from start: Date, to end: Date) async -> [CMMotionActivity]? {
        guard end > start else { return nil }

        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: activities)
            }
        }
    }

    private func confidenceWeight(for confidence: CMMotionActivityConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        @unknown default: return 1
        }
    }

    private func inferFromSpeed(_ locations: [CLLocation]) -> TransportMode {
        let validSpeeds = locations.map(\.speed).filter { $0 >= 0 }

        let averageSpeed: CLLocationSpeed
        if validSpeeds.isEmpty {
            guard
                let first = locations.first,
                let last = locations.last,
                last.timestamp > first.timestamp
            else {
                return .unknown
            }

            let distance = first.distance(from: last)
            averageSpeed = distance / last.timestamp.timeIntervalSince(first.timestamp)
        } else {
            averageSpeed = validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        }

        switch averageSpeed {
        case ..<0.7:
            return .stationary
        case ..<2.0:
            return .walking
        case ..<4.5:
            return .running
        case ..<9.0:
            return .cycling
        case ..<32:
            return .automotive
        case ..<75:
            return .train
        default:
            return .plane
        }
    }

    private func correctedModeIfNeeded(
        _ candidate: TransportMode,
        fallback: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        guard candidate == .stationary else { return candidate }

        let traveledDistance = Self.totalDistance(for: locations)
        guard traveledDistance >= Self.minimumDistanceForNonStationaryOverride else {
            return candidate
        }

        if fallback != .stationary && fallback != .unknown {
            return fallback
        }

        let maxObservedSpeed = locations
            .map(\.speed)
            .filter { $0 >= 0 }
            .max() ?? -1

        switch maxObservedSpeed {
        case 9...:
            return .automotive
        case 4.5...:
            return .cycling
        case 2.0...:
            return .running
        case 0.8...:
            return .walking
        default:
            break
        }

        let directDistance = Self.straightLineDistance(for: locations)
        if directDistance >= 1_500 {
            return .automotive
        }
        if directDistance >= 500 {
            return .cycling
        }
        return .walking
    }

    private func refinedLongDistanceMode(
        for candidate: TransportMode,
        fallback: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        switch candidate {
        case .walking, .running, .swimming, .cycling, .train, .plane, .boat:
            return candidate
        case .stationary, .automotive, .unknown:
            break
        }

        let directDistance = Self.straightLineDistance(for: locations)
        let averageSpeed = Self.averageSpeed(for: locations)
        let maxObservedSpeed = Self.maxObservedSpeed(for: locations)
        let baseline = candidate == .stationary ? fallback : candidate

        if maxObservedSpeed >= 80 ||
            averageSpeed >= 55 ||
            (directDistance >= 120_000 && averageSpeed >= 40) {
            return .plane
        }

        if averageSpeed >= 16 &&
            directDistance >= 18_000 &&
            baseline != .cycling &&
            baseline != .walking &&
            baseline != .running {
            return .train
        }

        return candidate
    }

    private static func totalDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard locations.count > 1 else { return 0 }
        return zip(locations, locations.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + pair.0.distance(from: pair.1)
        }
    }

    private static func averageSpeed(for locations: [CLLocation]) -> CLLocationSpeed {
        let validSpeeds = locations.map(\.speed).filter { $0 >= 0 }
        if !validSpeeds.isEmpty {
            return validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        }

        guard
            let first = locations.first,
            let last = locations.last,
            last.timestamp > first.timestamp
        else {
            return 0
        }

        return first.distance(from: last) / last.timestamp.timeIntervalSince(first.timestamp)
    }

    private static func maxObservedSpeed(for locations: [CLLocation]) -> CLLocationSpeed {
        locations
            .map(\.speed)
            .filter { $0 >= 0 }
            .max() ?? 0
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
    }
}

@MainActor
final class DefaultTimelineAssembler: TimelineAssembler {
    private static let timelineLog = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Timeline")

    private let repository: TimelineRepository
    private let motionClassifier: MotionClassifier
    private let placeNameResolver: PlaceNameResolver
    /// One rebuild at a time. Location callbacks and foreground refresh overlap.
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false

    init(
        repository: TimelineRepository,
        motionClassifier: MotionClassifier,
        placeNameResolver: PlaceNameResolver
    ) {
        self.repository = repository
        self.motionClassifier = motionClassifier
        self.placeNameResolver = placeNameResolver
    }

    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async {
        guard !locations.isEmpty else { return }

        do {
            _ = try repository.appendSamples(from: locations, source: source)
            try repository.saveIfNeeded()
        } catch {
            print("Failed to persist location samples: \(error.localizedDescription)")
        }

        await reconcileSampleStays()
    }

    func ingestVisit(_ visit: CLVisit) async {
        // A kilometre-wide visit fix is a cell tower, not a place. The sample
        // is already stored; stays are built from the fixes that are actually
        // near the person.
        guard visit.horizontalAccuracy <= 300 else {
            Self.timelineLog.info("Skipped a visit whose accuracy was \(Int(visit.horizontalAccuracy)) m")
            await reconcileSampleStays()
            return
        }

        do {
            let visitPlace = try repository.addOrUpdateVisit(from: visit)
            await fillAutomaticPlaceLabelIfNeeded(for: visitPlace)
            try repository.saveIfNeeded()
        } catch {
            print("Failed to build timeline segment: \(error.localizedDescription)")
        }

        await reconcileSampleStays()
    }

    func approachWasAutomotive(before date: Date) async -> Bool {
        await motionClassifier.approachWasAutomotive(before: date)
    }

    func recentlyWalking(at date: Date) async -> Bool {
        await motionClassifier.recentlyWalking(at: date)
    }

    /// Rebuilds stops from the fixes already on disk, then classifies each new trip.
    ///
    /// Called after every batch of fixes and whenever the app comes forward.
    /// The work is local and, once a trip has a mode, later passes leave it.
    func reconcileSampleStays() async {
        if reconcileTask != nil {
            reconcileAgain = true
            await reconcileTask?.value
            return
        }

        let task = Task { @MainActor in
            await self.performSampleStayReconciliation()
        }
        reconcileTask = task
        await task.value
        reconcileTask = nil

        if reconcileAgain {
            reconcileAgain = false
            await reconcileSampleStays()
        }
    }

    private func performSampleStayReconciliation() async {
        do {
            let result = try repository.reconcileSampleStays(now: .now)

            for leg in result.moveLegs {
                let proposed = await motionClassifier.classifyTransport(
                    start: leg.startDate,
                    end: leg.endDate,
                    locations: leg.locations
                )
                let steps = await motionClassifier.stepCount(start: leg.startDate, end: leg.endDate)
                let straightLine = CLLocation(
                    latitude: leg.startPlace.latitude,
                    longitude: leg.startPlace.longitude
                ).distance(from: CLLocation(
                    latitude: leg.endPlace.latitude,
                    longitude: leg.endPlace.longitude
                ))
                let transportMode = LastBlockWalk.mode(
                    proposed: proposed,
                    distance: straightLine,
                    duration: leg.endDate.timeIntervalSince(leg.startDate),
                    stepCount: steps
                )
                let between = try repository.samples(from: leg.startDate, to: leg.endDate)
                _ = try repository.upsertMove(
                    startPlace: leg.startPlace,
                    endPlace: leg.endPlace,
                    startDate: leg.startDate,
                    endDate: leg.endDate,
                    transportMode: transportMode,
                    distanceMeters: leg.distanceMeters,
                    stepCount: steps,
                    samples: between
                )
            }

            for place in result.newPlaces.prefix(8) {
                await fillAutomaticPlaceLabelIfNeeded(for: place)
            }

            if !result.newPlaces.isEmpty || !result.moveLegs.isEmpty {
                Self.timelineLog.info(
                    "Rebuilt \(result.newPlaces.count) stops and \(result.moveLegs.count) trips from stored fixes"
                )
            }
        } catch {
            Self.timelineLog.error("Failed to rebuild stops from fixes: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fillAutomaticPlaceLabelIfNeeded(for place: VisitPlace) async {
        let hasUserLabel = !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAutoLabel = !(place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard !hasUserLabel, !hasAutoLabel else { return }
        guard place.horizontalAccuracy <= 180 else { return }

        if let resolvedName = await placeNameResolver.resolveName(for: place.coordinate) {
            do {
                try repository.setAutomaticLabel(resolvedName, for: place.id)
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

    private let manager = CLLocationManager()
    private let userDefaults: UserDefaults
    #if targetEnvironment(simulator)
    let isDemoMode = true
    #else
    let isDemoMode = false
    #endif
    private let assembler: TimelineAssembler
    private let routeTrackingLiveActivity = RouteTrackingLiveActivityCoordinator()
    private var pendingOneShotLocationSource: LocationSampleSource?
    private var pendingTemporaryRouteTrackingDuration: TemporaryRouteTrackingDuration?
    private var shouldChainToAlwaysAfterWhenInUse = false
    private var isHighAccuracyMonitoring = false
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

    private static let lowPowerDesiredAccuracy = kCLLocationAccuracyHundredMeters
    private static let lowPowerDistanceFilter: CLLocationDistance = 150
    private static let highAccuracyDesiredAccuracy = kCLLocationAccuracyBestForNavigation
    private static let highAccuracyDistanceFilter: CLLocationDistance = 10
    /// Ten-metre fixes for a few minutes. Enough to draw a walk off a bus,
    /// far cheaper than navigation-grade GPS left on all day.
    private static let lastMileDesiredAccuracy = kCLLocationAccuracyNearestTenMeters
    private static let lastMileDistanceFilter: CLLocationDistance = 20
    private static let lastMileDuration: TimeInterval = 10 * 60
    private static let lastMileMaximumDuration: TimeInterval = 12 * 60

    private var shouldSkipLiveTracking: Bool {
        isDemoMode || ProcessInfo.processInfo.isRunningUnitTests
    }

    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
        self.assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: CoreMotionTransportClassifier(),
            placeNameResolver: CLGeocoderPlaceNameResolver()
        )

        super.init()

        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = Self.lowPowerDesiredAccuracy
        manager.distanceFilter = Self.lowPowerDistanceFilter
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false

        authorizationStatus = manager.authorizationStatus
        if !shouldSkipLiveTracking {
            UIDevice.current.isBatteryMonitoringEnabled = true
            installTemporaryRouteTrackingEnergyObservers()
        }
        restoreTemporaryRouteTrackingState()
        restoreBackgroundLocationListeningState()
        updateBackgroundLocationAllowance()
    }

    var trackingStatusText: String {
        if isDemoMode {
            return "Simulator demo mode"
        }

        if isTemporaryRouteTrackingActive {
            switch authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return "Real route tracking on"
            case .notDetermined:
                return "Real route tracking waiting for permission"
            case .denied, .restricted:
                return "Real route tracking paused"
            @unknown default:
                return "Real route tracking on"
            }
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

        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        pendingOneShotLocationSource = nil
        isMonitoring = false
        isHighAccuracyMonitoring = false
    }

    func setBackgroundLocationListeningEnabled(_ isEnabled: Bool) {
        isBackgroundLocationListeningEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: BackgroundLocationListeningSettings.isEnabledKey)

        guard !shouldSkipLiveTracking else { return }

        applyTrackingConfiguration()
    }

    func refreshHistoricalBackfill() async {
        guard !shouldSkipLiveTracking else { return }

        guard isAuthorizedForTracking else { return }

        // iOS does not expose requestHistoricalLocations for third-party apps.
        // One current fix bridges a short silence, and the fixes already stored
        // are re-read so a missed visit does not stay a single multi-hour trip.
        requestOneShotLocation(source: .launchBackfill)
        await assembler.reconcileSampleStays()
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
        applyTrackingConfiguration()
        Task {
            await routeTrackingLiveActivity.end()
        }
    }

    private var isAuthorizedForTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        updateBackgroundLocationAllowance()
        refreshTemporaryRouteTrackingStateIfNeeded()

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

    private func applyTrackingConfiguration() {
        guard isAuthorizedForTracking else {
            stop()
            return
        }

        startLowPowerMonitoringIfNeeded()
        updateBackgroundLocationAllowance()

        let shouldUseHighAccuracy = isTemporaryRouteTrackingActive
        if shouldUseHighAccuracy {
            manager.stopMonitoringSignificantLocationChanges()
            manager.activityType = .otherNavigation
            manager.desiredAccuracy = Self.highAccuracyDesiredAccuracy
            manager.distanceFilter = Self.highAccuracyDistanceFilter
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = authorizationStatus == .authorizedAlways

            if !isHighAccuracyMonitoring {
                manager.startUpdatingLocation()
                isHighAccuracyMonitoring = true
            }
        } else if isLastMileActive {
            // Visits stay on so a real stop still closes. Continuous fixes are
            // only for this short walk, at pedestrian accuracy.
            manager.stopMonitoringSignificantLocationChanges()
            manager.activityType = .fitness
            manager.desiredAccuracy = Self.lastMileDesiredAccuracy
            manager.distanceFilter = Self.lastMileDistanceFilter
            manager.pausesLocationUpdatesAutomatically = true
            manager.showsBackgroundLocationIndicator = authorizationStatus == .authorizedAlways
            if !isHighAccuracyMonitoring {
                manager.startUpdatingLocation()
                isHighAccuracyMonitoring = true
            }
        } else {
            if isBackgroundLocationListeningEnabled {
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                isMonitoring = false
            }
            manager.stopUpdatingLocation()
            isHighAccuracyMonitoring = false
            manager.activityType = .otherNavigation
            manager.desiredAccuracy = Self.lowPowerDesiredAccuracy
            manager.distanceFilter = Self.lowPowerDistanceFilter
            manager.pausesLocationUpdatesAutomatically = true
            manager.showsBackgroundLocationIndicator = false
        }
    }

    /// Records the walk off a bus, or the first minutes after leaving on foot.
    ///
    /// Significant-change updates are about 500 metres apart, so the last
    /// couple of blocks never arrive. A ten-minute pedestrian session covers
    /// that without leaving navigation GPS on for the rest of the day.
    private func startLastMileTracking() {
        guard !shouldSkipLiveTracking else { return }
        guard !isTemporaryRouteTrackingActive else { return }
        guard isAuthorizedForTracking else { return }
        guard isBackgroundLocationListeningEnabled else { return }

        let now = Date.now
        if lastMileStartedAt == nil {
            lastMileStartedAt = now
        }
        guard let startedAt = lastMileStartedAt else { return }
        let cap = startedAt.addingTimeInterval(Self.lastMileMaximumDuration)
        guard now < cap else { return }

        lastMileEndsAt = min(now.addingTimeInterval(Self.lastMileDuration), cap)
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

    private func expireLastMile() {
        guard lastMileEndsAt != nil else { return }
        lastMileEndsAt = nil
        lastMileStartedAt = nil
        lastMileRecentLocations.removeAll()
        lastMileExpiryTask?.cancel()
        lastMileExpiryTask = nil
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
        guard isAuthorizedForTracking else { return }

        pendingOneShotLocationSource = source
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
        applyTrackingConfiguration()
        Task {
            await routeTrackingLiveActivity.end()
        }
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
                }
            }
        )
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
            content.title = "Real route tracking stopped"
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
            content.title = "Real route tracking stopped"
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

        Task {
            await assembler.ingestLocations([visitLocation], source: .visit)
            await assembler.ingestVisit(visit)
            // Getting off a bus is a visit. The walk to the door happens in
            // the next few minutes, and significant-change will not see it.
            if await assembler.approachWasAutomotive(before: visitTimestamp) {
                startLastMileTracking()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        refreshTemporaryRouteTrackingStateIfNeeded()

        guard pendingOneShotLocationSource != nil
            || isTemporaryRouteTrackingActive
            || isLastMileActive
            || isBackgroundLocationListeningEnabled
        else { return }

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
        pendingOneShotLocationSource = nil

        Task {
            if source == .routeTracking {
                await routeTrackingLiveActivity.record(
                    locations,
                    endsAt: temporaryRouteTrackingEndsAt
                )
            }
            await assembler.ingestLocations(locations, source: source)
            // Left somewhere on foot after a long pause. Catch the rest of
            // the walk; a ride keeps the cheaper significant-change stream.
            if source == .significantChange,
               let idleFor, idleFor >= 8 * 60,
               await assembler.recentlyWalking(at: Date()) {
                startLastMileTracking()
            }
        }

        if source == .lastMile {
            stopLastMileIfSettled(locations)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.locationUnknown.rawValue {
            return
        }

        lastErrorMessage = error.localizedDescription
    }
}
