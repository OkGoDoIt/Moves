import CoreLocation
import Foundation
import SwiftData

/// Applies only to guesses. Imported labels and explicit mode choices bypass it.
struct AutomaticTransportModes: Equatable {
    static let storageKey = "disabledAutomaticTransportModes"
    static let choices: [TransportMode] = [
        .walking, .running, .cycling, .automotive, .train, .plane, .boat, .swimming,
    ]
    var disabled: Set<TransportMode>

    init(disabled: Set<TransportMode> = []) {
        self.disabled = disabled.intersection(Self.choices)
    }

    init(rawValue: String) {
        self.init(disabled: Set(rawValue.split(separator: ",").compactMap {
            TransportMode(rawValue: String($0))
        }))
    }

    var rawValue: String { disabled.map(\.rawValue).sorted().joined(separator: ",") }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "")
    }

    func allows(_ mode: TransportMode) -> Bool { !disabled.contains(mode) }

    func allowedMode(_ mode: TransportMode) -> TransportMode {
        allows(mode) ? mode : .unknown
    }

    /// A rejected motion reading can fall back to independent speed evidence, but
    /// never turn cycling into driving simply because cycling has been disabled.
    func restrict(
        mode: TransportMode,
        confidence: Double,
        locations: [CLLocation]
    ) -> (mode: TransportMode, confidence: Double) {
        guard !allows(mode) else { return (mode, confidence) }
        let speedMode = CoreMotionTransportClassifier.inferredMode(
            from: locations, preferences: self
        )
        guard speedMode != .unknown, speedMode != .stationary else { return (.unknown, 0) }
        return (speedMode, min(0.59, CoreMotionTransportClassifier.speedBasedConfidence(
            mode: speedMode, locations: locations
        )))
    }
}

extension MoveSegment {
    /// Shared with automatic stay repair: a person's curated trip is not a guess.
    var permitsAutomaticModeChanges: Bool {
        guard transportModeSource == .auto, origin == .sensor,
              reviewState != .confirmed, reviewState != .dismissed,
              routeMatchPolicy != .manual, routeMatchPolicy != .roads,
              manualRouteCoordinatesData == nil,
              (comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        else { return false }
        return !samples.contains { $0.source == .healthWorkoutRoute }
    }

    /// How long the pedometer keeps its history.
    static let pedometerHistory: TimeInterval = 7 * 24 * 60 * 60

    /// Steps the automatic rules may treat as measured, or nil when nobody knows.
    ///
    /// Health's merged count comes first. A stored count is a measurement when it is
    /// positive, and a stored zero only when the trip was recorded here while the
    /// pedometer still held it: older builds also stored 0 for "no data" (an import,
    /// or a trip rebuilt after the pedometer's seven days had passed).
    var knownStepCount: Int? {
        if let health = HealthStepEvidenceLookup.evidence(for: id)?.steps.known {
            return Int(health.rounded())
        }
        guard let stepCount else { return nil }
        if stepCount > 0 { return stepCount }
        guard origin == .sensor,
              transportModeSource != .imported,
              createdAt.timeIntervalSince(endDate) < Self.pedometerHistory,
              !samples.contains(where: { $0.source.isHistoryImport })
        else { return nil }
        return 0
    }
}

/// Local, explicit history cleanup. No rows, points, times, or distances are deleted.
/// There is no await while holding SwiftData models, and undo stores IDs and values.
@MainActor
struct AutomaticModeHistory {
    struct Change: Codable {
        let id: UUID
        let before: TransportMode
        let after: TransportMode
        let reviewBefore: ReviewState
    }

    struct Report {
        let changed: Int
        let unknown: Int
    }

    let undoURL: URL

    init(undoURL: URL? = nil) {
        self.undoURL = undoURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("Moves", isDirectory: true)
            .appendingPathComponent("automatic-mode-history-undo.json")
    }

    var canUndo: Bool { FileManager.default.fileExists(atPath: undoURL.path) }

    func candidates(in context: ModelContext, preferences: AutomaticTransportModes) throws -> [MoveSegment] {
        guard !preferences.disabled.isEmpty else { return [] }
        let rawModes = preferences.disabled.map(\.rawValue)
        let automatic = TransportModeSource.auto.rawValue
        let sensor = TimelineItemOrigin.sensor.rawValue
        let descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate {
            rawModes.contains($0.transportModeRawValue)
                && $0.transportModeSourceRaw == automatic && $0.originRaw == sensor
        })
        return try context.fetch(descriptor).filter(\.permitsAutomaticModeChanges)
    }

    func recheck(in context: ModelContext, preferences: AutomaticTransportModes) throws -> Report {
        // Finish any unrelated edit before temporarily detaching SwiftData's undo.
        if context.hasChanges { try context.save() }
        let moves = try candidates(in: context, preferences: preferences)
        let changes = moves.map { move in
            Change(id: move.id, before: move.transportMode,
                   after: Self.reclassifiedMode(move, preferences: preferences),
                   reviewBefore: move.reviewState)
        }
        guard !changes.isEmpty else { return Report(changed: 0, unknown: 0) }

        // Write recovery information first. A failed backup must leave history intact.
        let previousUndo = canUndo ? try Data(contentsOf: undoURL) : nil
        try FileManager.default.createDirectory(at: undoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(changes).write(to: undoURL, options: .atomic)
        let undoManager = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undoManager }
        do {
            for (move, change) in zip(moves, changes) {
                Self.apply(change.after, review: .pending, to: move)
            }
            try context.save()
        } catch {
            for (move, change) in zip(moves, changes) {
                Self.apply(change.before, review: change.reviewBefore, to: move)
            }
            if let previousUndo { try? previousUndo.write(to: undoURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: undoURL) }
            throw error
        }
        return Report(changed: changes.count, unknown: changes.filter { $0.after == .unknown }.count)
    }

    /// Undo only this cleanup's remaining results. Later corrections and deleted
    /// trips stay untouched; the automatic-mode preferences remain as selected.
    func undo(in context: ModelContext) throws -> Int {
        let changes = try JSONDecoder().decode([Change].self, from: Data(contentsOf: undoURL))
        if context.hasChanges { try context.save() }
        let ids = changes.map(\.id)
        let rows = try context.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate { ids.contains($0.id) }))
        // CloudKit mirroring cannot enforce unique IDs, so a duplicated row must
        // not trap here; each copy is restored on its own merits.
        let byID = Dictionary(grouping: rows, by: \.id)
        var seen = Set<UUID>()
        let restorable: [(move: MoveSegment, change: Change)] = changes.flatMap { change in
            guard seen.insert(change.id).inserted else { return [(MoveSegment, Change)]() }
            return (byID[change.id] ?? []).filter { move in
                move.permitsAutomaticModeChanges && move.transportMode == change.after
                    && move.reviewState == .pending
            }.map { ($0, change) }
        }
        let undoManager = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undoManager }
        do {
            for (move, change) in restorable {
                Self.apply(change.before, review: change.reviewBefore, to: move)
            }
            try context.save()
        } catch {
            for (move, change) in restorable {
                Self.apply(change.after, review: .pending, to: move)
            }
            throw error
        }
        try FileManager.default.removeItem(at: undoURL)
        return restorable.count
    }

    private static func reclassifiedMode(_ move: MoveSegment, preferences: AutomaticTransportModes) -> TransportMode {
        let locations = move.samples.map(\.asLocation)
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 200 }
            .sorted { $0.timestamp < $1.timestamp }
        // Old Core Motion readings expire. Use only stored fixes, never a matched
        // route (which was calculated using the very mode being reconsidered).
        guard locations.count >= 2, let first = locations.first, let last = locations.last,
              last.timestamp > first.timestamp else { return .unknown }
        let proposed = TransportSpeedEvidence(locations: locations).inferredMode
        let direct = first.distance(from: last)
        let duration = move.endDate.timeIntervalSince(move.startDate)
        // Health's merged steps when known; a stored 0 only when it was a measurement.
        let corrected = StepModeRules.refinedMode(
            proposed: proposed, straightLine: direct, distance: move.distanceMeters, duration: duration,
            stepCount: move.knownStepCount, locations: locations
        )
        let plausible = CoreMotionTransportClassifier.rejectingImplausibleContinuousTrip(
            corrected, duration: duration, straightLineDistance: direct
        )
        return preferences.allowedMode(plausible)
    }

    // MARK: Paces nobody keeps on foot, at any age

    /// Bump when `ImplausibleFootPace` changes, so the sweep runs once more.
    static let paceRulesVersion = 1
    static let paceRulesVersionKey = "Moves.automaticModes.paceRulesVersion"

    struct PaceReport: Equatable {
        var checked = 0
        var changed: [TransportMode: Int] = [:]
        var total: Int { changed.values.reduce(0, +) }
    }

    /// Relabels "runs" and "walks" of any age whose pace rules out feet.
    ///
    /// The stay rebuild only revisits the last week, and the settings recheck only trips
    /// whose mode was turned off, so history (much of it imported, with no step data)
    /// would otherwise keep a 37 km "run" at 21 km/h forever. Speed is the evidence, so
    /// imported trips are included; a mode the person chose, a reviewed trip, a drawn or
    /// commented trip, and a Health workout never change. Only recent recorded trips are
    /// marked for review.
    @discardableResult
    static func applyPaceRules(
        in context: ModelContext,
        now: Date = .now,
        preferences: AutomaticTransportModes = .load()
    ) throws -> PaceReport {
        let foot = [TransportMode.walking.rawValue, TransportMode.running.rawValue]
        let user = TransportModeSource.user.rawValue
        let moves = try context.fetch(FetchDescriptor<MoveSegment>(predicate: #Predicate {
            foot.contains($0.transportModeRawValue) && $0.transportModeSourceRaw != user
        }))
        var report = PaceReport()
        for move in moves where !TimelineRetirement.isRetired(move) && permitsPaceRelabel(move) {
            report.checked += 1
            let duration = move.endDate.timeIntervalSince(move.startDate)
            var straight: CLLocationDistance = 0
            if let start = move.startPlace, let end = move.endPlace {
                straight = CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            }
            guard let paced = ImplausibleFootPace.mode(
                proposed: move.transportMode,
                distance: max(move.distanceMeters, straight),
                duration: duration,
                stepCount: move.knownStepCount
            ) else { continue }
            let mode = preferences.allowedMode(paced)
            guard mode != move.transportMode else { continue }
            let recordedHere = move.origin == .sensor && move.transportModeSource == .auto
                && !TimelineReviewHeuristics.isImportedHistory(move)
            let asks = recordedHere && move.reviewState == .none
                && now.timeIntervalSince(move.startDate) <= TimelineReviewHeuristics.newQuestionWindow
            apply(mode, review: asks ? .pending : move.reviewState, to: move)
            // The label is now this rule's guess, not the file's.
            if move.transportModeSource == .imported { move.transportModeSource = .auto }
            report.changed[mode, default: 0] += 1
        }
        if context.hasChanges { try context.save() }
        return report
    }

    /// `permitsAutomaticModeChanges` without the imported-origin exclusion.
    static func permitsPaceRelabel(_ move: MoveSegment) -> Bool {
        // Photo-inferred trips are not a mode anyone measured; the photo import owns them.
        move.origin != .photoInferred
            && move.transportModeSource != .user
            && move.reviewState != .confirmed && move.reviewState != .dismissed
            && move.routeMatchPolicy != .manual && move.routeMatchPolicy != .roads
            && move.manualRouteCoordinatesData == nil
            && (move.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !move.samples.contains { $0.source == .healthWorkoutRoute }
    }

    private static func apply(_ mode: TransportMode, review: ReviewState, to move: MoveSegment) {
        move.transportMode = mode
        move.reviewState = review
        move.clearCachedRouteCoordinates()
        move.speedProfileData = nil
        move.routeMatchConfidence = .unknown
        move.routeMatchSummary = nil
    }
}
