import Foundation
import CoreLocation

/// Year chip on Insights, plus an all-time rollup.
enum InsightsPeriod: Hashable, Sendable {
    case year(Int)
    case all

    var id: String {
        switch self {
        case .year(let year): return "year-\(year)"
        case .all: return "all"
        }
    }

    /// Stable sort: All last, years descending.
    static func ordered(_ years: [Int]) -> [InsightsPeriod] {
        years.sorted(by: >).map { .year($0) } + [.all]
    }
}

/// One day’s worth of insight inputs, copied off SwiftData so aggregation can run off-main.
struct InsightsDayRecord: Equatable, Sendable {
    var dayStart: Date
    var moves: [InsightsMoveRecord]
    var visits: [InsightsVisitRecord]

    init(dayStart: Date, moves: [InsightsMoveRecord] = [], visits: [InsightsVisitRecord] = []) {
        self.dayStart = dayStart
        self.moves = moves
        self.visits = visits
    }

    /// Copies relationship values while the caller still has a valid `ModelContext`.
    init(_ day: DayTimeline) {
        dayStart = day.dayStart
        moves = day.moves.map(InsightsMoveRecord.init)
        visits = day.places.map(InsightsVisitRecord.init)
    }
}

/// A move’s duration, distance, and mode for yearly totals.
struct InsightsMoveRecord: Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var distanceMeters: Double
    var modeRaw: String

    var mode: TransportMode {
        TransportMode(rawValue: modeRaw) ?? .unknown
    }

    init(
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        distanceMeters: Double,
        mode: TransportMode
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.modeRaw = mode.rawValue
    }

    init(_ move: MoveSegment) {
        startDate = move.timelineStartDate
        endDate = move.endDate
        duration = move.timelineDuration
        distanceMeters = max(move.distanceMeters, 0)
        modeRaw = move.transportMode.rawValue
    }
}

/// Country / city fields already stored on the visit or its learned place.
struct InsightsVisitRecord: Equatable, Sendable {
    var countryCode: String?
    var locality: String?

    init(countryCode: String? = nil, locality: String? = nil) {
        self.countryCode = countryCode
        self.locality = locality
    }

    init(_ visit: VisitPlace) {
        countryCode = Self.firstNonEmpty(visit.knownPlace?.countryCode, visit.countryCode)
        locality = Self.firstNonEmpty(visit.knownPlace?.locality, visit.locality)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// Pure yearly (or all-time) aggregates for the Insights tab.
struct InsightsSnapshot: Equatable, Sendable {
    /// Minimum moving distance for a calendar day to count toward streaks.
    static let activeDayMinimumDistance: CLLocationDistance = 500

    let period: InsightsPeriod
    let availableYears: [Int]
    let modes: [ModeStats]
    let countries: [PlaceCount]
    let cities: [PlaceCount]
    let calendarDays: [CalendarDay]
    let currentStreakDays: Int
    let longestStreakDays: Int
    let showsCurrentStreak: Bool
    let monthlyDistance: [MonthDistance]
    /// Moving seconds by hour of day (0…23).
    let hourDurations: [TimeInterval]
    /// Moving seconds by `Calendar.component(.weekday)` index (Sunday = 0).
    let weekdayDurations: [TimeInterval]
    let totalDistanceMeters: Double
    let totalMovingDuration: TimeInterval
    let activeDayCount: Int
    /// Wall time of this build, used by tests that measure cache vs recompute.
    let builtAt: Date

    struct ModeStats: Identifiable, Equatable, Sendable {
        var id: String { modeRaw }
        let modeRaw: String
        let duration: TimeInterval
        let distanceMeters: Double
        let previousDuration: TimeInterval
        let previousDistanceMeters: Double

        var mode: TransportMode {
            TransportMode(rawValue: modeRaw) ?? .unknown
        }

        var hasActivity: Bool {
            duration > 0 || distanceMeters > 0 || previousDuration > 0 || previousDistanceMeters > 0
        }

        /// `(current − previous) / previous` when last year had distance.
        var distanceDeltaFraction: Double? {
            guard previousDistanceMeters > 0 else { return nil }
            return (distanceMeters - previousDistanceMeters) / previousDistanceMeters
        }

        var durationDeltaFraction: Double? {
            guard previousDuration > 0 else { return nil }
            return (duration - previousDuration) / previousDuration
        }
    }

    struct PlaceCount: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let flagEmoji: String
        let visitCount: Int
        let countryCode: String?
    }

    struct CalendarDay: Identifiable, Equatable, Sendable {
        var id: String { dayKey }
        let date: Date
        let dayKey: String
        let distanceMeters: Double
        let isActive: Bool
        let isFuture: Bool
    }

    struct MonthDistance: Identifiable, Equatable, Sendable {
        let id: String
        let date: Date
        let distanceMeters: Double
    }

    static func empty(period: InsightsPeriod, availableYears: [Int], builtAt: Date = .now) -> InsightsSnapshot {
        InsightsSnapshot(
            period: period,
            availableYears: availableYears,
            modes: [],
            countries: [],
            cities: [],
            calendarDays: [],
            currentStreakDays: 0,
            longestStreakDays: 0,
            showsCurrentStreak: false,
            monthlyDistance: [],
            hourDurations: Array(repeating: 0, count: 24),
            weekdayDurations: Array(repeating: 0, count: 7),
            totalDistanceMeters: 0,
            totalMovingDuration: 0,
            activeDayCount: 0,
            builtAt: builtAt
        )
    }
}

/// Builds `InsightsSnapshot` from day records. Safe to call off the main actor.
enum InsightsSnapshotBuilder {
    /// Display order for the activity grid. Stationary / unknown stay omitted unless they have distance.
    static let modeOrder: [TransportMode] = [
        .walking, .running, .cycling, .automotive, .train, .plane, .boat, .swimming
    ]

    static func build(
        days: [InsightsDayRecord],
        period: InsightsPeriod,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        builtAt: Date = .now
    ) -> InsightsSnapshot {
        let availableYears = availableYears(in: days, now: now, calendar: calendar)
        let currentDays = days.filter { day in
            contains(period, dayStart: day.dayStart, calendar: calendar)
        }
        let previousDays: [InsightsDayRecord]
        if case .year(let year) = period {
            previousDays = days.filter { calendar.component(.year, from: $0.dayStart) == year - 1 }
        } else {
            previousDays = []
        }

        let currentModes = modeTotals(in: currentDays)
        let previousModes = modeTotals(in: previousDays)
        let modes = modeOrder.compactMap { mode -> InsightsSnapshot.ModeStats? in
            let current = currentModes[mode.rawValue] ?? (0, 0)
            let previous = previousModes[mode.rawValue] ?? (0, 0)
            let stats = InsightsSnapshot.ModeStats(
                modeRaw: mode.rawValue,
                duration: current.duration,
                distanceMeters: current.distance,
                previousDuration: previous.duration,
                previousDistanceMeters: previous.distance
            )
            return stats.hasActivity ? stats : nil
        }

        let geography = geographyCounts(in: currentDays)
        let distanceByDay = dailyDistance(in: currentDays, calendar: calendar)
        let calendarRange = calendarGridRange(period: period, now: now, calendar: calendar)
        let calendarDays = makeCalendarDays(
            range: calendarRange,
            distanceByDay: distanceByDay,
            now: now,
            calendar: calendar
        )
        let activeDays = Set(
            distanceByDay.compactMap { key, meters in
                meters >= InsightsSnapshot.activeDayMinimumDistance ? key : nil
            }
        )
        let showsCurrent = periodContainsToday(period, now: now, calendar: calendar)
        let longest = streakCounts(
            activeDays: activeDays,
            now: now,
            calendar: calendar,
            includeCurrent: false
        ).longest
        // A streak running through January 1 keeps counting, so it reads every day, not this period's.
        let current = showsCurrent
            ? streakCounts(
                activeDays: Set(
                    dailyDistance(in: days, calendar: calendar).compactMap { key, meters in
                        isActiveDay(distanceMeters: meters) ? key : nil
                    }
                ),
                now: now,
                calendar: calendar,
                includeCurrent: true
            ).current
            : 0
        let monthly = monthlyDistance(
            distanceByDay: distanceByDay,
            period: period,
            now: now,
            calendar: calendar
        )
        let hours = hourDurations(in: currentDays, calendar: calendar)
        let weekdays = weekdayDurations(in: currentDays, calendar: calendar)
        let totalDistance = distanceByDay.values.reduce(0, +)
        let totalDuration = currentDays.reduce(0.0) { partial, day in
            partial + day.moves.reduce(0) { $0 + $1.duration }
        }
        let activeCount = activeDays.count

        return InsightsSnapshot(
            period: period,
            availableYears: availableYears,
            modes: modes,
            countries: geography.countries,
            cities: geography.cities,
            calendarDays: calendarDays,
            currentStreakDays: current,
            longestStreakDays: max(longest, current),
            showsCurrentStreak: showsCurrent,
            monthlyDistance: monthly,
            hourDurations: hours,
            weekdayDurations: weekdays,
            totalDistanceMeters: totalDistance,
            totalMovingDuration: totalDuration,
            activeDayCount: activeCount,
            builtAt: builtAt
        )
    }

    /// Years that have at least one recorded day, plus the current year so the chip exists before January 1 data.
    static func availableYears(
        in days: [InsightsDayRecord],
        now: Date,
        calendar: Calendar
    ) -> [Int] {
        var years = Set(days.map { calendar.component(.year, from: $0.dayStart) })
        years.insert(calendar.component(.year, from: now))
        return years.sorted(by: >)
    }

    static func contains(_ period: InsightsPeriod, dayStart: Date, calendar: Calendar) -> Bool {
        switch period {
        case .all:
            return true
        case .year(let year):
            return calendar.component(.year, from: dayStart) == year
        }
    }

    /// A day is active when its moving distance is at least 500 m.
    static func isActiveDay(distanceMeters: Double) -> Bool {
        distanceMeters >= InsightsSnapshot.activeDayMinimumDistance
    }

    /// Current streak ends on today when today is active; otherwise it is zero.
    /// Longest is the longest run of consecutive active calendar days in `activeDays`.
    static func streakCounts(
        activeDays: Set<Date>,
        now: Date,
        calendar: Calendar,
        includeCurrent: Bool
    ) -> (current: Int, longest: Int) {
        let normalized = Set(activeDays.map { calendar.startOfDay(for: $0) })
        let longest = longestStreak(in: normalized, calendar: calendar)
        guard includeCurrent else {
            return (0, longest)
        }
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = today
        while normalized.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    // MARK: - Internals

    private static func modeTotals(
        in days: [InsightsDayRecord]
    ) -> [String: (duration: TimeInterval, distance: Double)] {
        var totals: [String: (duration: TimeInterval, distance: Double)] = [:]
        for day in days {
            for move in day.moves {
                guard modeOrder.contains(move.mode) else { continue }
                var entry = totals[move.modeRaw] ?? (0, 0)
                entry.duration += move.duration
                entry.distance += move.distanceMeters
                totals[move.modeRaw] = entry
            }
        }
        return totals
    }

    private static func geographyCounts(
        in days: [InsightsDayRecord]
    ) -> (countries: [InsightsSnapshot.PlaceCount], cities: [InsightsSnapshot.PlaceCount]) {
        var countryVisits: [String: Int] = [:]
        var cityVisits: [String: (name: String, country: String?, count: Int)] = [:]

        for day in days {
            for visit in day.visits {
                if let country = normalized(visit.countryCode)?.uppercased() {
                    countryVisits[country, default: 0] += 1
                }
                if let city = normalized(visit.locality) {
                    let country = normalized(visit.countryCode)?.uppercased()
                    let key = "\(country ?? "")|\(city.lowercased())"
                    var entry = cityVisits[key] ?? (city, country, 0)
                    entry.count += 1
                    cityVisits[key] = entry
                }
            }
        }

        let countries = countryVisits
            .map { code, count in
                InsightsSnapshot.PlaceCount(
                    id: code,
                    name: PlacesGeography.countryName(forCountryCode: code),
                    flagEmoji: PlacesGeography.flagEmoji(forCountryCode: code),
                    visitCount: count,
                    countryCode: code
                )
            }
            .sorted {
                if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        let cities = cityVisits
            .map { key, value in
                InsightsSnapshot.PlaceCount(
                    id: key,
                    name: value.name,
                    flagEmoji: PlacesGeography.flagEmoji(forCountryCode: value.country),
                    visitCount: value.count,
                    countryCode: value.country
                )
            }
            .sorted {
                if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        return (countries, cities)
    }

    private static func dailyDistance(
        in days: [InsightsDayRecord],
        calendar: Calendar
    ) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for day in days {
            let key = calendar.startOfDay(for: day.dayStart)
            let distance = day.moves.reduce(0) { $0 + $1.distanceMeters }
            result[key, default: 0] += distance
        }
        return result
    }

    private static func calendarGridRange(
        period: InsightsPeriod,
        now: Date,
        calendar: Calendar
    ) -> DateInterval {
        switch period {
        case .year(let year):
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
                ?? calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)
                ?? start
            return DateInterval(start: start, end: calendar.startOfDay(for: end))
        case .all:
            let end = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -364, to: end) ?? end
            return DateInterval(start: start, end: end)
        }
    }

    private static func makeCalendarDays(
        range: DateInterval,
        distanceByDay: [Date: Double],
        now: Date,
        calendar: Calendar
    ) -> [InsightsSnapshot.CalendarDay] {
        let today = calendar.startOfDay(for: now)
        var days: [InsightsSnapshot.CalendarDay] = []
        var cursor = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: range.end)
        let formatter = dayKeyFormatter
        while cursor <= last {
            let distance = distanceByDay[cursor] ?? 0
            days.append(
                InsightsSnapshot.CalendarDay(
                    date: cursor,
                    dayKey: formatter.string(from: cursor),
                    distanceMeters: distance,
                    isActive: isActiveDay(distanceMeters: distance),
                    isFuture: cursor > today
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private static func monthlyDistance(
        distanceByDay: [Date: Double],
        period: InsightsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [InsightsSnapshot.MonthDistance] {
        switch period {
        case .year(let year):
            return (1...12).compactMap { month in
                guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                    return nil
                }
                let distance = distanceByDay.reduce(0.0) { partial, item in
                    calendar.component(.month, from: item.key) == month
                        && calendar.component(.year, from: item.key) == year
                        ? partial + item.value
                        : partial
                }
                return InsightsSnapshot.MonthDistance(
                    id: String(format: "%04d-%02d", year, month),
                    date: start,
                    distanceMeters: distance
                )
            }
        case .all:
            let years = Set(distanceByDay.keys.map { calendar.component(.year, from: $0) }).sorted()
            return years.map { year in
                let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
                    ?? calendar.startOfDay(for: now)
                let distance = distanceByDay.reduce(0.0) { partial, item in
                    calendar.component(.year, from: item.key) == year ? partial + item.value : partial
                }
                return InsightsSnapshot.MonthDistance(
                    id: "\(year)",
                    date: start,
                    distanceMeters: distance
                )
            }
        }
    }

    private static func hourDurations(
        in days: [InsightsDayRecord],
        calendar: Calendar
    ) -> [TimeInterval] {
        var hours = Array(repeating: 0.0, count: 24)
        for day in days {
            for move in day.moves {
                add(move, toHours: &hours, calendar: calendar)
            }
        }
        return hours
    }

    private static func weekdayDurations(
        in days: [InsightsDayRecord],
        calendar: Calendar
    ) -> [TimeInterval] {
        var weekdays = Array(repeating: 0.0, count: 7)
        for day in days {
            let index = calendar.component(.weekday, from: day.dayStart) - 1
            guard weekdays.indices.contains(index) else { continue }
            weekdays[index] += day.moves.reduce(0) { $0 + $1.duration }
        }
        return weekdays
    }

    /// Splits a move’s duration across the hours it spans so a 90-minute ride is not a single bar.
    static func add(
        _ move: InsightsMoveRecord,
        toHours hours: inout [TimeInterval],
        calendar: Calendar
    ) {
        let end = max(move.endDate, move.startDate)
        var cursor = move.startDate
        var remaining = max(move.duration, 0)
        guard remaining > 0 else { return }

        var guardCount = 0
        while remaining > 0, cursor < end, guardCount < 48 {
            guardCount += 1
            let hour = calendar.component(.hour, from: cursor)
            guard let hourStart = calendar.date(
                bySettingHour: hour,
                minute: 0,
                second: 0,
                of: cursor
            ), let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) else {
                hours[hour] += remaining
                return
            }
            let slice = min(remaining, nextHour.timeIntervalSince(cursor))
            if hours.indices.contains(hour) {
                hours[hour] += max(slice, 0)
            }
            remaining -= slice
            cursor = nextHour
        }
        if remaining > 0 {
            let hour = calendar.component(.hour, from: end)
            if hours.indices.contains(hour) {
                hours[hour] += remaining
            }
        }
    }

    private static func longestStreak(in activeDays: Set<Date>, calendar: Calendar) -> Int {
        let sorted = activeDays.sorted()
        guard !sorted.isEmpty else { return 0 }
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let expected = calendar.date(byAdding: .day, value: 1, to: sorted[index - 1])
            if expected == sorted[index] {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return longest
    }

    private static func periodContainsToday(
        _ period: InsightsPeriod,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        contains(period, dayStart: calendar.startOfDay(for: now), calendar: calendar)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// In-memory year cache. A 5-year history recomputes in well under 300 ms, so Insights
/// does not persist a SwiftData `InsightsYearCache` model.
enum InsightsComputeCache {
    /// Set from `InsightsSnapshotTests.testFiveYearRecomputeStaysUnder300ms`.
    static let recomputeBudget: TimeInterval = 0.3

    /// Returns a cached snapshot when `key` matches, otherwise runs `compute`.
    static func snapshot(
        key: String,
        storage: inout [String: InsightsSnapshot],
        compute: () -> InsightsSnapshot
    ) -> InsightsSnapshot {
        if let cached = storage[key] {
            return cached
        }
        let built = compute()
        storage[key] = built
        return built
    }
}
