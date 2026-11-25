import Foundation
import CoreLocation
import SwiftData

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
}

/// Everything Insights reads from the store, as plain values.
struct InsightsSource: Equatable, Sendable {
    var days: [InsightsDayRecord] = []
    /// Any visit, trip, or fix at all; decides between the cards and the empty state.
    var hasRecordedActivity = false
}

/// Reads Insights' inputs on a private context, never from the view's `@Query` rows.
///
/// The reconciler deletes and rebuilds trips on its own context after every batch of
/// fixes. A main-context model whose row went before the merge aborts the process the
/// moment a property is read (field crash in `MoveSegment.startPlace` under
/// `InsightsDayRecord.init`), and nothing can catch it. A fresh context reads the
/// committed store, and each fetch prefetches the relationships it follows and is copied
/// out at once, so nothing faults lazily against a row another context may delete.
enum InsightsSourceLoader {
    static func load(from container: ModelContainer) throws -> InsightsSource {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let days = try context.fetch(FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayKey)]))
        var order: [PersistentIdentifier] = []
        var dayStarts: [PersistentIdentifier: Date] = [:]
        for day in days {
            let id = day.persistentModelID
            if dayStarts[id] == nil { order.append(id) }
            // The day's own date on the phone's calendar: every grouping below works in
            // `Calendar.current`, and a day east of the phone starts on its previous date.
            dayStarts[id] = day.calendarDate()
        }

        var moveFetch = FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)])
        moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace]
        var moves: [PersistentIdentifier: [InsightsMoveRecord]] = [:]
        var moveCount = 0
        for move in try context.fetch(moveFetch) {
            moveCount += 1
            guard let day = move.dayTimeline?.persistentModelID else { continue }
            moves[day, default: []].append(InsightsMoveRecord(move))
        }

        var visitFetch = FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\.arrivalDate)])
        visitFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.knownPlace]
        var visits: [PersistentIdentifier: [InsightsVisitRecord]] = [:]
        var visitCount = 0
        for visit in try context.fetch(visitFetch) {
            visitCount += 1
            guard let day = visit.dayTimeline?.persistentModelID else { continue }
            visits[day, default: []].append(InsightsVisitRecord(visit))
        }

        var sampleFetch = FetchDescriptor<LocationSample>()
        sampleFetch.fetchLimit = 1
        let hasSamples = try context.fetchCount(sampleFetch) > 0

        return InsightsSource(
            days: order.compactMap { id in
                dayStarts[id].map { InsightsDayRecord(dayStart: $0, moves: moves[id] ?? [], visits: visits[id] ?? []) }
            },
            hasRecordedActivity: moveCount > 0 || visitCount > 0 || hasSamples
        )
    }
}

/// Which saves can change a reader built from trips, stops, and days. Capture saves a
/// batch of fixes every few seconds; those alone change nothing Insights shows.
enum TimelineSaveFilter {
    static let timelineEntities: Set<String> = ["DayTimeline", "MoveSegment", "VisitPlace", "KnownPlace"]

    static func touchesTimeline(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        guard let info = notification.userInfo else { return true }
        if let invalidated = info[ModelContext.NotificationKey.invalidatedAllIdentifiers]
            ?? info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue],
           (invalidated as? Bool) != false { return true }
        var understood = false
        for key in keys {
            guard let payload = info[key] ?? info[key.rawValue] else { continue }
            let identifiers: [PersistentIdentifier]
            if let values = payload as? [PersistentIdentifier] { identifiers = values }
            else if let values = payload as? Set<PersistentIdentifier> { identifiers = Array(values) }
            else { return true }
            understood = true
            if identifiers.contains(where: { timelineEntities.contains($0.entityName) }) { return true }
        }
        return !understood
    }
}

/// A move’s duration, distance, and mode for yearly totals.
struct InsightsMoveRecord: Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var distanceMeters: Double
    var modeRaw: String
    /// The clock where the trip began, for hour-of-day totals; nil when it left from no stop.
    var timeZone: TimeZone? = nil

    var mode: TransportMode {
        TransportMode(rawValue: modeRaw) ?? .unknown
    }

    init(
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        distanceMeters: Double,
        mode: TransportMode,
        timeZone: TimeZone? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.modeRaw = mode.rawValue
        self.timeZone = timeZone
    }

    init(_ move: MoveSegment) {
        startDate = move.timelineStartDate
        endDate = move.endDate
        duration = move.timelineDuration
        distanceMeters = max(move.distanceMeters, 0)
        modeRaw = move.transportMode.rawValue
        // The start stop only: `placeTimeZone` would fall back to walking the whole day.
        timeZone = move.startPlace.flatMap { PlaceTimeZone.timeZone(at: $0.coordinate) }
    }
}

/// Country / city fields already stored on the visit or its learned place.
struct InsightsVisitRecord: Equatable, Sendable {
    var countryCode: String?
    var locality: String?
    var latitude: Double? = nil
    var longitude: Double? = nil

    init(countryCode: String? = nil, locality: String? = nil) {
        self.countryCode = countryCode
        self.locality = locality
    }

    init(_ visit: VisitPlace) {
        countryCode = Self.firstNonEmpty(visit.knownPlace?.countryCode, visit.countryCode)
        locality = Self.firstNonEmpty(visit.knownPlace?.locality, visit.locality)
        latitude = visit.latitude
        longitude = visit.longitude
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
    /// Ground distance by month (or by year for All). Flights are left out so one long
    /// flight does not flatten every other bar; `airDistanceMeters` states them.
    let monthlyDistance: [MonthDistance]
    /// Ground moving seconds by hour of day (0…23).
    let hourDurations: [TimeInterval]
    /// Ground moving seconds by `Calendar.component(.weekday)` index (Sunday = 0).
    let weekdayDurations: [TimeInterval]
    /// Every trip, flights included.
    let totalDistanceMeters: Double
    let totalMovingDuration: TimeInterval
    /// Every trip except flights. Ground plus air is the total.
    let groundDistanceMeters: Double
    let groundMovingDuration: TimeInterval
    let airDistanceMeters: Double
    let airMovingDuration: TimeInterval
    /// The same span a year earlier, when that year has any trips; otherwise nil.
    let comparison: Comparison?
    let activeDayCount: Int
    /// Countries with visits in the period but no city name on any of them yet.
    let countriesWithoutCityNames: Int
    /// `DayTimeline.dayKey` for every day of the period up to today, for Health totals.
    let periodDayKeys: [String]
    /// Wall time of this build, used by tests that measure cache vs recompute.
    let builtAt: Date

    /// Which earlier span the deltas compare against.
    struct Comparison: Equatable, Sendable {
        let year: Int
        /// The period is the year in progress, so the earlier span stops on the same date.
        let isSameDates: Bool
        let groundDistanceMeters: Double

        func deltaFraction(current: Double) -> Double? {
            guard groundDistanceMeters > 0 else { return nil }
            return (current - groundDistanceMeters) / groundDistanceMeters
        }
    }

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

        var isAir: Bool { mode == .plane }

        var hasActivity: Bool {
            duration > 0 || distanceMeters > 0
        }

        /// `(current − previous) / previous` when the earlier span had distance in this mode.
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
            groundDistanceMeters: 0,
            groundMovingDuration: 0,
            airDistanceMeters: 0,
            airMovingDuration: 0,
            comparison: nil,
            activeDayCount: 0,
            countriesWithoutCityNames: 0,
            periodDayKeys: [],
            builtAt: builtAt
        )
    }

    /// Nothing at all happened in the period: no trips and no named places.
    var isEmptyPeriod: Bool {
        modes.isEmpty && countries.isEmpty && cities.isEmpty && totalDistanceMeters == 0
    }
}

/// Builds `InsightsSnapshot` from day records. Safe to call off the main actor.
enum InsightsSnapshotBuilder {
    /// Display order for the activity rows: ground modes, then trips without a mode
    /// (shown as Other, so the rows add up to the headline), then flights.
    /// Stationary trips fold into Other.
    static let modeOrder: [TransportMode] = [
        .walking, .running, .cycling, .swimming, .automotive, .train, .boat, .unknown, .plane
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
        let previous = previousSpan(days: days, period: period, now: now, calendar: calendar)
        let previousDays = previous?.days ?? []

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
        let previousGround = previousModes
            .filter { $0.key != TransportMode.plane.rawValue }
            .reduce(0.0) { $0 + $1.value.distance }
        let comparison = previous.flatMap { span -> InsightsSnapshot.Comparison? in
            // No trips at all in the earlier span: there is nothing to compare with.
            guard previousModes.values.contains(where: { $0.distance > 0 || $0.duration > 0 }) else { return nil }
            return InsightsSnapshot.Comparison(year: span.year, isSameDates: span.isSameDates, groundDistanceMeters: previousGround)
        }

        let geography = geographyCounts(in: currentDays)
        let groundDays = currentDays.map { day in
            // Visits stay: a trip that left from no stop reads its hour on their clock.
            InsightsDayRecord(dayStart: day.dayStart, moves: day.moves.filter { $0.mode != .plane }, visits: day.visits)
        }
        let groundDistanceByDay = dailyDistance(in: groundDays, calendar: calendar)
        let distanceByDay = dailyDistance(in: currentDays, calendar: calendar)
        let calendarRange = calendarGridRange(period: period, now: now, calendar: calendar)
        let calendarDays = makeCalendarDays(
            range: calendarRange,
            distanceByDay: distanceByDay,
            groundDistanceByDay: groundDistanceByDay,
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
            distanceByDay: groundDistanceByDay,
            period: period,
            now: now,
            calendar: calendar
        )
        let hours = hourDurations(in: groundDays, calendar: calendar)
        let weekdays = weekdayDurations(in: groundDays, calendar: calendar)
        let totalDistance = distanceByDay.values.reduce(0, +)
        let totalDuration = currentDays.reduce(0.0) { partial, day in
            partial + day.moves.reduce(0) { $0 + $1.duration }
        }
        let groundDistance = groundDistanceByDay.values.reduce(0, +)
        let groundDuration = groundDays.reduce(0.0) { partial, day in
            partial + day.moves.reduce(0) { $0 + $1.duration }
        }
        // Summed from the flights themselves; a subtraction leaves rounding crumbs.
        let air = currentModes[TransportMode.plane.rawValue] ?? (0, 0)
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
            groundDistanceMeters: groundDistance,
            groundMovingDuration: groundDuration,
            airDistanceMeters: air.distance,
            airMovingDuration: air.duration,
            comparison: comparison,
            activeDayCount: activeCount,
            countriesWithoutCityNames: geography.countriesWithoutCityNames,
            periodDayKeys: periodDayKeys(period: period, days: days, now: now, calendar: calendar),
            builtAt: builtAt
        )
    }

    /// The earlier span deltas compare against: the previous calendar year, cut at
    /// today's date a year ago while the selected year is still in progress, so a
    /// part year is never measured against a whole one. All has no earlier span.
    static func previousSpan(
        days: [InsightsDayRecord],
        period: InsightsPeriod,
        now: Date,
        calendar: Calendar
    ) -> (year: Int, isSameDates: Bool, days: [InsightsDayRecord])? {
        guard case .year(let year) = period else { return nil }
        let inProgress = calendar.component(.year, from: now) == year
        var cutoff: Date?
        if inProgress,
           let yearAgo = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now)) {
            cutoff = calendar.date(byAdding: .day, value: 1, to: yearAgo)
        }
        let earlier = days.filter { day in
            guard calendar.component(.year, from: day.dayStart) == year - 1 else { return false }
            if let cutoff { return day.dayStart < cutoff }
            return true
        }
        return (year - 1, inProgress, earlier)
    }

    /// Day keys from the period's first day (or the first recorded day, for All) through today.
    private static func periodDayKeys(
        period: InsightsPeriod,
        days: [InsightsDayRecord],
        now: Date,
        calendar: Calendar
    ) -> [String] {
        let today = calendar.startOfDay(for: now)
        let start: Date
        var end = today
        switch period {
        case .year(let year):
            guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let last = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return [] }
            start = first
            end = min(today, last)
        case .all:
            guard let first = days.map(\.dayStart).min() else { return [] }
            start = calendar.startOfDay(for: first)
        }
        var keys: [String] = []
        var cursor = start
        let formatter = dayKeyFormatter(for: calendar)
        while cursor <= end {
            keys.append(formatter.string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
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
                // Every trip lands in a row, so the rows add up to the headline.
                let mode = modeOrder.contains(move.mode) ? move.mode : .unknown
                var entry = totals[mode.rawValue] ?? (0, 0)
                entry.duration += move.duration
                entry.distance += move.distanceMeters
                totals[mode.rawValue] = entry
            }
        }
        return totals
    }

    /// Countries come from the stored country, or from the bundled boundaries when a
    /// visit has none yet; cities come only from stored names, which arrive later. A
    /// country whose visits carry no city name yet is counted in
    /// `countriesWithoutCityNames`, so the view can say the city count is still growing.
    private static func geographyCounts(
        in days: [InsightsDayRecord]
    ) -> (countries: [InsightsSnapshot.PlaceCount], cities: [InsightsSnapshot.PlaceCount], countriesWithoutCityNames: Int) {
        var countryVisits: [String: Int] = [:]
        var countriesWithCity: Set<String> = []
        var cityVisits: [String: (name: String, country: String?, count: Int)] = [:]

        for day in days {
            for visit in day.visits {
                // Use stored names first. Offline boundary lookup fills only missing country
                // labels and only from visits, never from a line flown over a country.
                let resolvedCode = normalized(visit.countryCode)?.uppercased() ?? OfflineVisitGeography.country(latitude: visit.latitude, longitude: visit.longitude)
                if let country = resolvedCode {
                    countryVisits[country, default: 0] += 1
                }
                if let city = normalized(visit.locality) {
                    let country = resolvedCode
                    if let country { countriesWithCity.insert(country) }
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

        let unnamed = Set(countryVisits.keys).subtracting(countriesWithCity).count
        return (countries, cities, unnamed)
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
        groundDistanceByDay: [Date: Double],
        now: Date,
        calendar: Calendar
    ) -> [InsightsSnapshot.CalendarDay] {
        let today = calendar.startOfDay(for: now)
        var days: [InsightsSnapshot.CalendarDay] = []
        var cursor = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: range.end)
        let formatter = dayKeyFormatter(for: calendar)
        while cursor <= last {
            // Shading follows ground distance so a flight day does not wash out the rest;
            // a day with a flight still counts as active.
            let distance = distanceByDay[cursor] ?? 0
            days.append(
                InsightsSnapshot.CalendarDay(
                    date: cursor,
                    dayKey: formatter.string(from: cursor),
                    distanceMeters: groundDistanceByDay[cursor] ?? 0,
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
        // Each trip counts in the hours of the clock where it happened: a commute in San
        // Francisco is a morning one, whatever zone the phone is in now.
        var calendars: [TimeZone: Calendar] = [:]
        func local(_ zone: TimeZone) -> Calendar {
            if let cached = calendars[zone] { return cached }
            let made = PlaceClock.calendar(calendar, in: zone)
            calendars[zone] = made
            return made
        }
        for day in days {
            // A trip that left from no stop reads on the clock of the day's first stay.
            let dayZone = day.moves.contains { $0.timeZone == nil }
                ? day.visits.lazy.compactMap { visit -> TimeZone? in
                    guard let latitude = visit.latitude, let longitude = visit.longitude else { return nil }
                    return PlaceTimeZone.timeZone(at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                }.first
                : nil
            for move in day.moves {
                add(move, toHours: &hours, calendar: local(move.timeZone ?? dayZone ?? calendar.timeZone))
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

    /// Same shape as `DayTimeline.makeDayKey`, in the calendar's time zone.
    private static func dayKeyFormatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
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

/// Immutable bundled lookup, initialized on the Insights aggregation worker only when needed.
enum OfflineVisitGeography {
    private static let resolver = try? ExplorationCountryResolver.bundled()
    static func country(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude,
              CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else { return nil }
        return resolver?.country(at: .init(latitude: latitude, longitude: longitude))?.id
    }
}
