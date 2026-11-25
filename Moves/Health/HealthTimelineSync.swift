import CoreLocation
import Foundation
import os
import SwiftData

// MARK: - Settings

enum HealthActivitySettings {
    static let isEnabledKey = "Moves.healthActivity.isEnabled"
    static let didChangeNotification = Notification.Name("Moves.healthActivity.didChange")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: isEnabledKey) }

    /// The simulator has no real activity, so it reads synthetic data aligned with
    /// the demo days. `MOVES_HEALTH_REAL=1` reads the simulator's Health store instead.
    static var usesDemoData: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["MOVES_HEALTH_REAL"] != "1"
        #else
        return false
        #endif
    }

    /// On, or forced on in the simulator with `MOVES_HEALTH_DEMO=1`.
    static var isActive: Bool {
        isEnabled || (usesDemoData && ProcessInfo.processInfo.environment["MOVES_HEALTH_DEMO"] == "1")
    }
}

enum HealthStrideCalibrationStore {
    static let kKey = "Moves.healthActivity.strideK"
    static let sampleCountKey = "Moves.healthActivity.strideSampleCount"

    static func load(from defaults: UserDefaults = .standard) -> HealthStrideCalibration {
        let k = defaults.double(forKey: kKey)
        return HealthStrideCalibration(
            k: k > 0 ? k : 1,
            sampleCount: defaults.integer(forKey: sampleCountKey)
        )
    }

    static func save(_ calibration: HealthStrideCalibration, to defaults: UserDefaults = .standard) {
        defaults.set(calibration.k, forKey: kKey)
        defaults.set(calibration.sampleCount, forKey: sampleCountKey)
    }
}

// MARK: - Local cache

/// Health-derived numbers. Re-derivable and health-adjacent, so they live in a
/// local file, never in the CloudKit-mirrored timeline store.
struct HealthTimelineCacheData: Codable, Equatable {
    struct DayEntry: Codable, Equatable {
        var signature: String
        var summary: HealthDaySummary
        var processedAt: Date
        /// All totals were known and the day ended long enough ago for late
        /// Watch samples to have arrived. Unsettled days are read again.
        var isSettled: Bool
    }

    struct ModeChange: Codable, Equatable {
        var before: TransportMode
        var after: TransportMode
        var vote: HealthModeVote
    }

    struct TripEntry: Codable, Equatable {
        var dayKey: String
        var evidence: HealthStepEvidence
        var healthMeters: Double?
        /// The trip's distance before Moves replaced it with a Health estimate.
        var originalDistance: Double?
        /// The Health estimate written to the trip. Present means "distance is an estimate".
        var appliedDistance: Double?
        var modeChange: ModeChange?
        var routeSignal: HealthRouteSignal?
    }

    struct CalibrationSample: Codable, Equatable {
        var ratio: Double
        var date: Date
    }

    var days: [String: DayEntry] = [:]
    var stays: [UUID: HealthStayWalking] = [:]
    var trips: [UUID: TripEntry] = [:]
    var calibrationSamples: [UUID: CalibrationSample] = [:]

    static let maximumCalibrationSamples = 200
    static let maximumDays = 400

    mutating func prune() {
        if calibrationSamples.count > Self.maximumCalibrationSamples {
            let keep = calibrationSamples.sorted { $0.value.date > $1.value.date }.prefix(Self.maximumCalibrationSamples)
            calibrationSamples = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if days.count > Self.maximumDays {
            let keep = Set(days.keys.sorted().suffix(Self.maximumDays))
            days = days.filter { keep.contains($0.key) }
            trips = trips.filter { keep.contains($0.value.dayKey) }
        }
    }
}

final class HealthTimelineCacheStore: @unchecked Sendable {
    static let shared = HealthTimelineCacheStore(url: URL.applicationSupportDirectory
        .appendingPathComponent("Moves", isDirectory: true)
        .appendingPathComponent("health-timeline-cache.json"))

    let url: URL
    private let lock = NSLock()
    private var loaded: HealthTimelineCacheData?

    init(url: URL) { self.url = url }

    /// The cached values. Empty when the file is missing or still protected (locked
    /// device); a protected read is retried on the next call.
    func data() -> HealthTimelineCacheData {
        lock.withLock {
            if let loaded { return loaded }
            guard FileManager.default.fileExists(atPath: url.path) else {
                loaded = HealthTimelineCacheData()
                return loaded!
            }
            guard let bytes = try? Data(contentsOf: url) else { return HealthTimelineCacheData() }
            let decoded = (try? JSONDecoder().decode(HealthTimelineCacheData.self, from: bytes)) ?? HealthTimelineCacheData()
            loaded = decoded
            return decoded
        }
    }

    func replace(_ data: HealthTimelineCacheData) throws {
        let bytes = try JSONEncoder().encode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Syncs run in the background with the phone locked, where a fully protected file
        // cannot be written. The timeline store itself has this same protection.
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        lock.withLock { loaded = data }
    }

    func clear() {
        lock.withLock { loaded = HealthTimelineCacheData() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The seam the automatic-mode rules read Health step evidence through.
enum HealthStepEvidenceLookup {
    /// Health's evidence for a trip, or nil when the feature is off or the trip was
    /// never read. Values come from the local cache; nothing is queried here.
    static func evidence(for moveID: UUID, cache: HealthTimelineCacheStore = .shared) -> HealthStepEvidence? {
        guard HealthActivitySettings.isActive else { return nil }
        return cache.data().trips[moveID]?.evidence
    }
}

// MARK: - Snapshots

/// One timeline day, copied out of the store.
struct HealthDaySnapshot: Sendable, Equatable {
    var dayKey: String
    var interval: DateInterval
    var trips: [HealthTripFacts]
    var stays: [HealthStayFacts]
}

enum HealthTimelineSnapshotReader {
    /// Reads plain values on its own context. Every relationship is prefetched and
    /// copied at once; no model outlives this call.
    static func read(container: ModelContainer, from start: Date, to end: Date) throws -> [HealthDaySnapshot] {
        let context = ModelContext(container)
        var dayFetch = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayStart >= start && $0.dayStart < end })
        dayFetch.propertiesToFetch = [\.dayKey, \.dayStart]
        var dayStarts: [String: Date] = [:]
        for day in try context.fetch(dayFetch) {
            dayStarts[day.dayKey] = min(dayStarts[day.dayKey] ?? day.dayStart, day.dayStart)
        }
        guard !dayStarts.isEmpty else { return [] }

        let lower = start.addingTimeInterval(-86_400)
        let upper = end.addingTimeInterval(86_400)
        var moveFetch = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.startDate >= lower && $0.startDate < upper })
        moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace, \.endPlace, \.samplesStorage]
        var tripsByDay: [String: [HealthTripFacts]] = [:]
        var seenMoves = Set<UUID>()
        for move in try context.fetch(moveFetch) {
            guard !move.isDeleted, let dayKey = move.dayTimeline?.dayKey, dayStarts[dayKey] != nil,
                  seenMoves.insert(move.id).inserted else { continue }
            tripsByDay[dayKey, default: []].append(facts(for: move))
        }

        var placeFetch = FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.arrivalDate >= lower && $0.arrivalDate < upper })
        placeFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline]
        var staysByDay: [String: [HealthStayFacts]] = [:]
        var seenPlaces = Set<UUID>()
        for place in try context.fetch(placeFetch) {
            guard !place.isDeleted, let dayKey = place.dayTimeline?.dayKey, dayStarts[dayKey] != nil,
                  let departure = place.departureDate, departure > place.arrivalDate,
                  seenPlaces.insert(place.id).inserted else { continue }
            staysByDay[dayKey, default: []].append(HealthStayFacts(id: place.id, arrival: place.arrivalDate, departure: departure))
        }

        return dayStarts.map { key, dayStart in
            HealthDaySnapshot(
                dayKey: key,
                interval: HealthTimelineFusion.dayInterval(dayStart: dayStart),
                trips: (tripsByDay[key] ?? []).sorted { $0.start < $1.start },
                stays: (staysByDay[key] ?? []).sorted { $0.arrival < $1.arrival }
            )
        }.sorted { $0.interval.start < $1.interval.start }
    }

    static func facts(for move: MoveSegment) -> HealthTripFacts {
        let samples = move.samples
        let fixes = samples.map {
            HealthFix(latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.timestamp, horizontalAccuracy: $0.horizontalAccuracy)
        }.sorted { $0.timestamp < $1.timestamp }
        let route = RouteCoordinateStorage.decode(move.routeCacheCoordinatesData)
            .map { HealthCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        return HealthTripFacts(
            id: move.id,
            start: move.startDate,
            end: move.endDate,
            mode: move.transportMode,
            distanceMeters: move.distanceMeters,
            startCoordinate: move.startPlace.map { HealthCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
            endCoordinate: move.endPlace.map { HealthCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
            fixes: fixes,
            permitsModeChange: move.permitsAutomaticModeChanges,
            permitsDistanceCorrection: permitsDistanceCorrection(move),
            pedometerSteps: move.stepCount,
            matchedRouteMeters: route.count > 1 ? HealthGeo.pathLength(route) : nil,
            sampleCount: samples.count
        )
    }

    /// A sensor trip whose distance nobody drew or imported. A mode the person set is
    /// fine: saying "this was a walk" does not make a sparse path accurate.
    static func permitsDistanceCorrection(_ move: MoveSegment) -> Bool {
        move.origin == .sensor
            && move.transportModeSource != .imported
            && move.routeMatchPolicy != .manual
            && move.manualRouteCoordinatesData == nil
            && !move.samples.contains { $0.source.isHistoryImport || $0.source == .healthWorkoutRoute }
    }
}

// MARK: - Writes

/// A targeted change to one trip, applied only if the row still looks as it did.
struct HealthTripWrite: Sendable, Equatable {
    var id: UUID
    var expectedStart: Date
    var expectedEnd: Date
    var expectedMode: TransportMode
    var expectedDistance: Double
    var newMode: TransportMode?
    var newDistance: Double?
    var asksForReview: Bool
}

enum HealthTimelineWriter {
    /// Re-fetches each row by id right before writing: a background reconcile may
    /// have deleted or rebuilt it since the snapshot. Returns the ids written.
    static func apply(_ writes: [HealthTripWrite], container: ModelContainer) throws -> Set<UUID> {
        guard !writes.isEmpty else { return [] }
        let context = ModelContext(container)
        var applied = Set<UUID>()
        for write in writes {
            let id = write.id
            var fetch = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id })
            fetch.relationshipKeyPathsForPrefetching = [\.samplesStorage]
            for move in try context.fetch(fetch) where !move.isDeleted {
                guard abs(move.startDate.timeIntervalSince(write.expectedStart)) < 1,
                      abs(move.endDate.timeIntervalSince(write.expectedEnd)) < 1,
                      move.transportMode == write.expectedMode,
                      abs(move.distanceMeters - write.expectedDistance) < 1 else { continue }
                var changed = false
                if let newMode = write.newMode, move.permitsAutomaticModeChanges {
                    move.transportMode = newMode
                    move.clearCachedRouteCoordinates()
                    move.speedProfileData = nil
                    move.routeMatchConfidence = .unknown
                    move.routeMatchSummary = nil
                    // Same convention as trip classification: ask only when unsure,
                    // and never ask twice.
                    if write.asksForReview, move.reviewState == .none { move.reviewState = .pending }
                    changed = true
                }
                if let newDistance = write.newDistance, HealthTimelineSnapshotReader.permitsDistanceCorrection(move) {
                    move.distanceMeters = newDistance
                    changed = true
                }
                if changed { applied.insert(id) }
            }
        }
        if context.hasChanges { try context.save() }
        return applied
    }
}

// MARK: - Orchestrator

struct HealthSyncReport: Equatable {
    var processedDays = 0
    var skippedDays = 0
    var correctedDistances = 0
    var restoredDistances = 0
    var changedModes = 0
    var votes = 0
    var unknownReasons: [HealthUnknownReason: Int] = [:]
    var calibration = HealthStrideCalibration.identity
}

/// Reads Health for recent timeline days and folds it into the timeline.
///
/// Runs when the app becomes active and when an older day is opened. It never
/// blocks the UI: store reads and writes happen on their own contexts off the main
/// actor, and Health answers that are unknown are retried on a later run.
@MainActor
final class HealthTimelineSync {
    static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Health")
    static let recentDays = 14
    static let minimumInterval: TimeInterval = 2 * 60
    /// Late Apple Watch samples arrive within hours, not days.
    static let settleDelay: TimeInterval = 6 * 3_600

    private let container: ModelContainer
    private let summaryStore: HealthSummaryStore
    private let cache: HealthTimelineCacheStore
    private let readerOverride: HealthActivityReading?
    private let now: () -> Date
    private lazy var healthKitReader = HealthKitActivityReader()
    private var runTask: Task<Void, Never>?
    private var rerunRequested = false
    private var pendingDayStarts: Set<Date> = []
    private var lastRunAt: Date?
    private var didLogDiagnostic = false
    private var settingsObserver: NSObjectProtocol?

    init(
        container: ModelContainer,
        summaryStore: HealthSummaryStore,
        cache: HealthTimelineCacheStore = .shared,
        reader: HealthActivityReading? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.container = container
        self.summaryStore = summaryStore
        self.cache = cache
        self.readerOverride = reader
        self.now = now
        summaryStore.onRequestDay = { [weak self] dayStart in self?.requestDay(dayStart) }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: HealthActivitySettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func sceneBecameActive() {
        summaryStore.refreshActivity()
        if let lastRunAt, now().timeIntervalSince(lastRunAt) < Self.minimumInterval { return }
        schedule()
    }

    /// Reads one day (for example an older day the person opened) along with the recent window.
    func requestDay(_ dayStart: Date) {
        pendingDayStarts.insert(dayStart)
        schedule()
    }

    private func settingsChanged() {
        summaryStore.refreshActivity()
        if HealthActivitySettings.isActive { lastRunAt = nil; schedule() }
    }

    private func schedule() {
        guard HealthActivitySettings.isActive else { return }
        if runTask != nil { rerunRequested = true; return }
        runTask = Task { [weak self] in
            guard let self else { return }
            var demoRetries = 0
            repeat {
                rerunRequested = false
                let report = await perform()
                // Demo days are seeded on their own task after launch; look again shortly.
                if HealthActivitySettings.usesDemoData, readerOverride == nil, demoRetries < 4,
                   report.processedDays + report.skippedDays == 0, !Task.isCancelled {
                    demoRetries += 1
                    try? await Task.sleep(for: .seconds(15))
                    rerunRequested = true
                }
            } while rerunRequested
            runTask = nil
        }
    }

    /// One pass. Exposed for tests; the app goes through `sceneBecameActive`.
    @discardableResult
    func perform() async -> HealthSyncReport {
        await TimelineSchemaUpgrader.waitUntilFinished()
        lastRunAt = now()
        let requested = pendingDayStarts
        pendingDayStarts.removeAll()
        var report = HealthSyncReport()

        let current = now()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: current)
        let windowStart = calendar.date(byAdding: .day, value: -(Self.recentDays - 1), to: today) ?? today
        let windowEnd = today.addingTimeInterval(2 * 86_400)
        let container = container

        let snapshots: [HealthDaySnapshot]
        do {
            snapshots = try await Task.detached(priority: .utility) {
                var days = try HealthTimelineSnapshotReader.read(container: container, from: windowStart, to: windowEnd)
                for dayStart in requested where dayStart < windowStart {
                    let start = calendar.startOfDay(for: dayStart)
                    days += try HealthTimelineSnapshotReader.read(container: container, from: start, to: start.addingTimeInterval(86_400))
                }
                return days
            }.value
        } catch {
            Self.log.error("Health sync could not read the timeline: \(error.localizedDescription, privacy: .public)")
            return report
        }

        let reader: HealthActivityReading = readerOverride
            ?? (HealthActivitySettings.usesDemoData ? HealthDemoProfile.reader(for: snapshots) : healthKitReader)
        if readerOverride == nil, !HealthActivitySettings.usesDemoData, !didLogDiagnostic,
           ProcessInfo.processInfo.environment["MOVES_HEALTH_DIAGNOSTIC"] == "1" {
            didLogDiagnostic = true
            await healthKitReader.logStepSampleDurationHistogram()
        }

        var data = cache.data()
        var calibration = HealthStrideCalibration.calibrate(ratios: data.calibrationSamples.values.map(\.ratio))
        let requestedKeys = Set(requested.map { DayTimeline.makeDayKey(for: $0) })

        let toProcess = snapshots.filter { day in
            guard let entry = data.days[day.dayKey], !requestedKeys.contains(day.dayKey) else { return true }
            return !entry.isSettled
                || entry.signature != HealthTimelineFusion.signature(trips: day.trips, stays: day.stays, calibration: calibration)
        }
        report.skippedDays = snapshots.count - toProcess.count

        // 1. Read Health for each day, trip, and long stay.
        struct TripReading { var steps: HealthValue; var meters: HealthValue; var buckets: [HealthBucket] }
        struct DayReading {
            var totals: HealthDayTotals
            var trips: [UUID: TripReading] = [:]
            var stays: [UUID: (steps: HealthValue, meters: HealthValue)] = [:]
        }
        var readings: [String: DayReading] = [:]
        func count(_ value: HealthValue) {
            if let reason = value.unknownReason { report.unknownReasons[reason, default: 0] += 1 }
        }
        for day in toProcess {
            let totals = await reader.dayTotals(for: day.interval)
            count(totals.steps)
            let dayHasData = (totals.steps.known ?? 0) > 0
            var reading = DayReading(totals: totals)
            for trip in day.trips where trip.duration > 0 {
                let interval = DateInterval(start: trip.start, end: trip.end)
                let steps = HealthTimelineFusion.resolveTripValue(await reader.steps(in: interval), dayHasData: dayHasData)
                let meters = HealthTimelineFusion.resolveTripValue(await reader.walkingDistance(in: interval), dayHasData: dayHasData)
                count(steps)
                var buckets: [HealthBucket] = []
                if (trip.mode == .automotive || trip.mode == .unknown),
                   let known = steps.known,
                   HealthModeEvidence.stepsPerMinute(steps: known, duration: trip.duration) > HealthModeEvidence.onFootStepsPerMinute {
                    buckets = await reader.buckets(in: interval, minutes: 5).buckets ?? []
                }
                reading.trips[trip.id] = TripReading(steps: steps, meters: meters, buckets: buckets)
            }
            for stay in day.stays where stay.duration >= HealthStayWalking.minimumStayDuration {
                let interval = DateInterval(start: stay.arrival, end: stay.departure)
                let steps = HealthTimelineFusion.resolveTripValue(await reader.steps(in: interval), dayHasData: dayHasData)
                let meters = HealthTimelineFusion.resolveTripValue(await reader.walkingDistance(in: interval), dayHasData: dayHasData)
                reading.stays[stay.id] = (steps, meters)
            }
            readings[day.dayKey] = reading
        }

        // 2. Calibrate the stride from well-recorded walks.
        for day in toProcess {
            for trip in day.trips {
                guard let reading = readings[day.dayKey]?.trips[trip.id],
                      data.trips[trip.id]?.appliedDistance == nil else { continue }
                let quality = HealthRecordingQuality(fixes: trip.fixes)
                if let ratio = HealthStrideCalibration.ratio(trip: trip, quality: quality, healthDistance: reading.meters) {
                    data.calibrationSamples[trip.id] = .init(ratio: ratio, date: trip.start)
                } else {
                    data.calibrationSamples[trip.id] = nil
                }
            }
        }
        data.prune()
        calibration = HealthStrideCalibration.calibrate(ratios: data.calibrationSamples.values.map(\.ratio))
        HealthStrideCalibrationStore.save(calibration)
        report.calibration = calibration

        // 3. Decide mode votes and walk distances.
        let preferences = AutomaticTransportModes.load()
        var writes: [HealthTripWrite] = []
        var pending: [UUID: HealthTimelineCacheData.TripEntry] = [:]
        for day in toProcess {
            guard let dayReading = readings[day.dayKey] else { continue }
            for trip in day.trips {
                guard let reading = dayReading.trips[trip.id] else { continue }
                var entry = data.trips[trip.id]
                // Something else rewrote the distance: that value is the new original.
                if let applied = entry?.appliedDistance, abs(applied - trip.distanceMeters) >= 1 {
                    entry?.appliedDistance = nil
                    entry?.originalDistance = nil
                }
                let vote = reading.steps.known.flatMap {
                    HealthModeEvidence.vote(trip: trip, steps: $0, buckets: reading.buckets)
                }
                if vote != nil { report.votes += 1 }
                var newEntry = HealthTimelineCacheData.TripEntry(
                    dayKey: day.dayKey,
                    evidence: HealthStepEvidence(steps: reading.steps, duration: trip.duration, vote: vote),
                    healthMeters: reading.meters.known,
                    originalDistance: entry?.originalDistance,
                    appliedDistance: entry?.appliedDistance,
                    modeChange: entry?.modeChange
                )

                var write = HealthTripWrite(
                    id: trip.id, expectedStart: trip.start, expectedEnd: trip.end,
                    expectedMode: trip.mode, expectedDistance: trip.distanceMeters,
                    newMode: nil, newDistance: nil, asksForReview: false
                )
                // Change a mode at most once per trip, and never one the person chose.
                if entry?.modeChange == nil, let vote,
                   let mode = HealthModeEvidence.proposedMode(for: trip, vote: vote, preferences: preferences) {
                    write.newMode = mode
                    write.asksForReview = vote == .notOnFoot
                    newEntry.modeChange = .init(before: trip.mode, after: mode, vote: vote)
                }

                var effective = trip
                effective.mode = write.newMode ?? trip.mode
                let original = newEntry.appliedDistance != nil ? (newEntry.originalDistance ?? trip.distanceMeters) : trip.distanceMeters
                let decision = HealthWalkDistance.decide(
                    trip: effective,
                    quality: HealthRecordingQuality(fixes: trip.fixes),
                    originalDistance: original,
                    calibration: calibration,
                    healthDistance: reading.meters,
                    steps: reading.steps
                )
                switch decision {
                case .apply(let meters):
                    if abs(meters - trip.distanceMeters) >= 1 { write.newDistance = meters }
                    newEntry.originalDistance = original
                    newEntry.appliedDistance = meters
                case .keep:
                    if newEntry.appliedDistance != nil {
                        // A new k or a changed trip no longer supports the estimate.
                        write.newDistance = original
                        newEntry.originalDistance = nil
                        newEntry.appliedDistance = nil
                    }
                }
                if effective.isOnFootMode, let route = trip.matchedRouteMeters {
                    newEntry.routeSignal = HealthRouteSignal.classify(
                        routeMeters: route,
                        healthMeters: reading.meters.known.map { .value(calibration.k * $0) } ?? reading.meters,
                        steps: reading.steps
                    )
                }
                if write.newMode != nil || write.newDistance != nil { writes.append(write) }
                pending[trip.id] = newEntry
            }
        }

        // 4. Write the few trips that changed, each re-fetched by id.
        var applied = Set<UUID>()
        if !writes.isEmpty {
            let batch = writes
            do {
                applied = try await Task.detached(priority: .utility) {
                    try HealthTimelineWriter.apply(batch, container: container)
                }.value
            } catch {
                Self.log.error("Health sync could not save trips: \(error.localizedDescription, privacy: .public)")
            }
        }
        let writesByID = Dictionary(writes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 5. Record what is now true, and publish it.
        for day in toProcess {
            guard let reading = readings[day.dayKey] else { continue }
            var trips = day.trips
            for index in trips.indices {
                let id = trips[index].id
                guard var entry = pending[id] else { continue }
                if let write = writesByID[id] {
                    if applied.contains(id) {
                        if let mode = write.newMode {
                            trips[index].mode = mode
                            trips[index].permitsModeChange = true
                            report.changedModes += 1
                        }
                        if let meters = write.newDistance {
                            trips[index].distanceMeters = meters
                            if entry.appliedDistance != nil { report.correctedDistances += 1 } else { report.restoredDistances += 1 }
                        }
                    } else {
                        // The row changed under us: keep what was there before.
                        entry.modeChange = data.trips[id]?.modeChange
                        entry.appliedDistance = data.trips[id]?.appliedDistance
                        entry.originalDistance = data.trips[id]?.originalDistance
                    }
                }
                data.trips[id] = entry
            }
            for stay in day.stays {
                if let values = reading.stays[stay.id],
                   let walking = HealthStayWalking.summarize(stay: stay, steps: values.steps, distance: values.meters, calibration: calibration) {
                    data.stays[stay.id] = walking
                } else {
                    data.stays[stay.id] = nil
                }
            }
            let totals = reading.totals
            let known = totals.steps.known != nil && totals.walkingDistance.known != nil
            data.days[day.dayKey] = .init(
                signature: HealthTimelineFusion.signature(trips: trips, stays: day.stays, calibration: calibration),
                summary: HealthDaySummary.summarize(
                    dayKey: day.dayKey, steps: totals.steps, distance: totals.walkingDistance,
                    flights: totals.flights, calibration: calibration
                ),
                processedAt: current,
                isSettled: known && day.interval.end.addingTimeInterval(Self.settleDelay) < current
            )
            report.processedDays += 1
        }
        data.prune()
        do {
            try cache.replace(data)
        } catch {
            Self.log.error("Health sync could not save its cache: \(error.localizedDescription, privacy: .public)")
        }
        summaryStore.load(data)

        let unknown = report.unknownReasons.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
        Self.log.info("""
            Health sync: \(report.processedDays, privacy: .public) days read, \(report.skippedDays, privacy: .public) unchanged, \
            \(report.votes, privacy: .public) votes, \(report.changedModes, privacy: .public) modes changed, \
            \(report.correctedDistances, privacy: .public) distances estimated, \(report.restoredDistances, privacy: .public) restored, \
            k=\(calibration.k, format: .fixed(precision: 3), privacy: .public) from \(calibration.sampleCount, privacy: .public) walks, \
            unknown: \(unknown.isEmpty ? "none" : unknown, privacy: .public)
            """)
        return report
    }
}
