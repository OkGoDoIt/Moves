import Foundation

/// Read model for the timeline and Insights: Health totals as plain values.
///
/// Injected at the app root. Views read it; only `HealthTimelineSync` fills it.
/// Every accessor returns nil while Steps and Walking Distance is off.
@MainActor
final class HealthSummaryStore: ObservableObject {
    @Published private(set) var isActive: Bool
    @Published private(set) var days: [String: HealthDaySummary] = [:]
    @Published private(set) var staysWalking: [UUID: HealthStayWalking] = [:]
    @Published private(set) var healthEstimatedTripIDs: Set<UUID> = []

    var onRequestDay: ((Date) -> Void)?

    init(cache: HealthTimelineCacheStore = .shared) {
        isActive = HealthActivitySettings.isActive
        if isActive { load(cache.data()) }
    }

    func load(_ data: HealthTimelineCacheData) {
        days = data.days.mapValues(\.summary)
        staysWalking = data.stays
        healthEstimatedTripIDs = Set(data.trips.compactMap { $0.value.appliedDistance == nil ? nil : $0.key })
    }

    func refreshActivity() {
        isActive = HealthActivitySettings.isActive
    }

    /// Steps, walked distance, and flights for a timeline day (`DayTimeline.dayKey`).
    func daySummary(forDayKey dayKey: String) -> HealthDaySummary? {
        guard isActive, let summary = days[dayKey], summary.hasAnyValue else { return nil }
        return summary
    }

    /// Metres walked during a stay, only when worth a caption (400 m or more).
    func walkedHereMeters(stayID: UUID) -> Double? {
        guard isActive, let walking = staysWalking[stayID], walking.isWorthShowing else { return nil }
        return walking.walkedMeters
    }

    /// The trip's distance is a Health estimate rather than a measured path.
    func isHealthEstimatedDistance(moveID: UUID) -> Bool {
        isActive && healthEstimatedTripIDs.contains(moveID)
    }

    /// Totals over several days, for Insights. Nil when no day in the range is known.
    func totals<Keys: Sequence>(forDayKeys dayKeys: Keys) -> (steps: Int?, walkedMeters: Double?) where Keys.Element == String {
        guard isActive else { return (nil, nil) }
        let summaries = dayKeys.compactMap { days[$0] }
        let steps = summaries.compactMap(\.steps)
        let meters = summaries.compactMap(\.walkedMeters)
        return (steps.isEmpty ? nil : steps.reduce(0, +), meters.isEmpty ? nil : meters.reduce(0, +))
    }

    /// Asks for an older day to be read, for example when the person opens it.
    func requestDay(_ dayStart: Date) {
        guard isActive else { return }
        onRequestDay?(dayStart)
    }
}

enum HealthSummaryText {
    /// "8,412 steps"
    static func steps(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 step")
            : String(localized: "\(count.formatted()) steps")
    }

    /// "0.4 mi" or "650 m", matching the app's other distances.
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// "walked 0.4 mi"
    static func walkedHere(_ meters: Double) -> String {
        String(localized: "walked \(distance(meters))")
    }
}
