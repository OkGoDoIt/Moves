import Foundation

/// Map tab time grain. Chevrons and the scrubber axis follow this value.
enum MapGranularity: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
    case allTime

    /// Next coarser grain, used when pinching the scrubber out.
    var coarser: MapGranularity? {
        switch self {
        case .day: return .week
        case .week: return .month
        case .month: return .year
        case .year: return .allTime
        case .allTime: return nil
        }
    }

    /// Next finer grain, used when pinching the scrubber in.
    var finer: MapGranularity? {
        switch self {
        case .allTime: return .year
        case .year: return .month
        case .month: return .week
        case .week: return .day
        case .day: return nil
        }
    }

    /// Calendar component used to step this grain, if any.
    var stepComponent: Calendar.Component? {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        case .allTime: return nil
        }
    }

    /// Histogram / scrubber bucket component for this grain.
    var scrubberBucketComponent: Calendar.Component {
        switch self {
        case .day: return .hour
        case .week, .month: return .day
        case .year: return .month
        case .allTime: return .year
        }
    }
}

/// Named range shortcuts in the Map range sheet.
enum MapRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case thisYear
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .thisWeek: return String(localized: "This week")
        case .lastWeek: return String(localized: "Last week")
        case .thisMonth: return String(localized: "This month")
        case .lastMonth: return String(localized: "Last month")
        case .thisYear: return String(localized: "This year")
        case .allTime: return String(localized: "All time")
        }
    }

    var granularity: MapGranularity {
        switch self {
        case .today, .yesterday: return .day
        case .thisWeek, .lastWeek: return .week
        case .thisMonth, .lastMonth: return .month
        case .thisYear: return .year
        case .allTime: return .allTime
        }
    }
}

/// A Map tab window: the pill’s chosen interval plus an optional scrubber focus.
struct MapRangeSelection: Equatable, Sendable {
    /// Full interval chosen by a preset, custom pickers, or chevron step.
    var interval: DateInterval
    var granularity: MapGranularity
    /// Sub-range drawn by the scrubber handles. Always inside `interval`.
    var focus: DateInterval
    /// True when the user picked arbitrary start/end rather than a named preset.
    var isCustom: Bool

    /// Today’s calendar day. The Map tab always opens here.
    static func today(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> MapRangeSelection {
        preset(.today, now: now, calendar: calendar)
    }

    /// Builds a named preset relative to `now`.
    static func preset(
        _ preset: MapRangePreset,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        firstRecorded: Date? = nil
    ) -> MapRangeSelection {
        let interval: DateInterval
        switch preset {
        case .today:
            interval = period(containing: now, granularity: .day, calendar: calendar)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            interval = period(containing: yesterday, granularity: .day, calendar: calendar)
        case .thisWeek:
            interval = period(containing: now, granularity: .week, calendar: calendar)
        case .lastWeek:
            let thisWeek = period(containing: now, granularity: .week, calendar: calendar)
            let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start) ?? thisWeek.start
            interval = period(containing: previous, granularity: .week, calendar: calendar)
        case .thisMonth:
            interval = period(containing: now, granularity: .month, calendar: calendar)
        case .lastMonth:
            let thisMonth = period(containing: now, granularity: .month, calendar: calendar)
            let previous = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) ?? thisMonth.start
            interval = period(containing: previous, granularity: .month, calendar: calendar)
        case .thisYear:
            interval = period(containing: now, granularity: .year, calendar: calendar)
        case .allTime:
            interval = allTimeInterval(now: now, calendar: calendar, firstRecorded: firstRecorded)
        }
        return MapRangeSelection(
            interval: interval,
            granularity: preset.granularity,
            focus: interval,
            isCustom: false
        )
    }

    /// Inclusive start / exclusive end from the custom pickers.
    static func custom(
        start: Date,
        end: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapRangeSelection {
        let orderedStart = min(start, end)
        var orderedEnd = max(start, end)
        if orderedEnd.timeIntervalSince(orderedStart) < 60 {
            orderedEnd = orderedStart.addingTimeInterval(60)
        }
        let interval = DateInterval(start: orderedStart, end: orderedEnd)
        return MapRangeSelection(
            interval: interval,
            granularity: inferredGranularity(for: interval, calendar: calendar),
            focus: interval,
            isCustom: true
        )
    }

    /// Calendar period that contains `date` at `granularity`.
    static func period(
        containing date: Date,
        granularity: MapGranularity,
        calendar: Calendar
    ) -> DateInterval {
        switch granularity {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        case .week:
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            components.hour = 0
            components.minute = 0
            components.second = 0
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .year:
            let components = calendar.dateComponents([.year], from: date)
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .allTime:
            return allTimeInterval(now: date, calendar: calendar)
        }
    }

    /// The first recorded day through the start of tomorrow, so “now” is always inside.
    /// With nothing recorded yet, that is just today.
    static func allTimeInterval(now: Date, calendar: Calendar, firstRecorded: Date? = nil) -> DateInterval {
        let start = calendar.startOfDay(for: min(firstRecorded ?? now, now))
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return DateInterval(start: start, end: max(start, end))
    }

    /// Starting values for the custom pickers, which can't show a time after `customEndRange`.
    /// The focus can sit in the future: a handle dragged past now, or a deep link.
    func customPickerDates(now: Date) -> (start: Date, end: Date) {
        let start = min(focus.start, now)
        let end = min(focus.end.addingTimeInterval(-1), now.addingTimeInterval(60))
        return (start, max(start, end))
    }

    /// Range for the custom End picker. Always a valid range, wherever `start` sits.
    static func customEndRange(start: Date, now: Date) -> ClosedRange<Date> {
        let latest = now.addingTimeInterval(60)
        return min(start, latest)...latest
    }

    /// Picks a grain from a custom duration so the scrubber axis stays readable.
    static func inferredGranularity(for interval: DateInterval, calendar: Calendar) -> MapGranularity {
        let days = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        switch days {
        case ...1: return .day
        case ...8: return .week
        case ...45: return .month
        case ...400: return .year
        default: return .allTime
        }
    }

    /// Steps the current grain backward or forward. Never walks past today.
    func stepped(
        by delta: Int,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapRangeSelection {
        guard delta != 0, let component = granularity.stepComponent else { return self }
        guard let shifted = calendar.date(byAdding: component, value: delta, to: interval.start) else {
            return self
        }
        var next = MapRangeSelection(
            interval: Self.period(containing: shifted, granularity: granularity, calendar: calendar),
            granularity: granularity,
            focus: Self.period(containing: shifted, granularity: granularity, calendar: calendar),
            isCustom: false
        )
        if delta > 0, next.interval.start > Self.period(containing: now, granularity: granularity, calendar: calendar).start {
            next = Self.periodSelection(containing: now, granularity: granularity, calendar: calendar)
        }
        return next
    }

    /// Whether the pill chevron in `delta`’s direction should be enabled.
    func canStep(by delta: Int, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard delta != 0, granularity != .allTime else { return false }
        if delta < 0 { return true }
        let currentPeriod = Self.period(containing: now, granularity: granularity, calendar: calendar)
        return interval.start < currentPeriod.start
    }

    /// Replaces the scrubber focus, clamped to `interval`.
    func withFocus(_ proposed: DateInterval) -> MapRangeSelection {
        let start = min(max(proposed.start, interval.start), interval.end)
        let end = min(max(proposed.end, interval.start), interval.end)
        let clamped = DateInterval(start: min(start, end), end: max(start, end))
        var copy = self
        copy.focus = clamped.duration < 60
            ? DateInterval(start: clamped.start, end: min(clamped.start.addingTimeInterval(60), interval.end))
            : clamped
        return copy
    }

    /// Double-tap on the scrubber restores the full pill interval.
    func resettingFocus() -> MapRangeSelection {
        var copy = self
        copy.focus = interval
        return copy
    }

    /// Pinch on the scrubber: keep the midpoint and switch grain.
    func switchingGranularity(
        to granularity: MapGranularity,
        around date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        firstRecorded: Date? = nil
    ) -> MapRangeSelection {
        if granularity == .allTime {
            let allTime = Self.allTimeInterval(now: now, calendar: calendar, firstRecorded: firstRecorded)
            return MapRangeSelection(
                interval: allTime,
                granularity: .allTime,
                focus: allTime,
                isCustom: false
            )
        }
        let interval = Self.period(containing: date, granularity: granularity, calendar: calendar)
        let todayPeriod = Self.period(containing: now, granularity: granularity, calendar: calendar)
        let clamped = interval.start > todayPeriod.start ? todayPeriod : interval
        return MapRangeSelection(
            interval: clamped,
            granularity: granularity,
            focus: clamped,
            isCustom: false
        )
    }

    /// Glass pill title. Uses preset names when the full interval matches; otherwise a compact span.
    func title(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        let showingFocus = abs(focus.start.timeIntervalSince(interval.start)) > 1
            || abs(focus.end.timeIntervalSince(interval.end)) > 1
        if showingFocus {
            return Self.spanTitle(for: focus, granularity: granularity, now: now, calendar: calendar)
        }
        if let preset = matchingPreset(now: now, calendar: calendar) {
            switch preset {
            case .thisMonth, .lastMonth, .thisYear:
                return Self.periodTitle(for: interval, granularity: granularity, calendar: calendar)
            default:
                return preset.title
            }
        }
        return Self.spanTitle(for: interval, granularity: granularity, now: now, calendar: calendar)
    }

    /// Live caption above the scrubber for the focused span.
    func focusCaption(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        Self.spanTitle(for: focus, granularity: granularity, now: now, calendar: calendar)
    }

    /// Share-gallery period that best matches this grain.
    var sharePeriod: MovesSharePeriod {
        switch granularity {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        case .allTime: return .forever
        }
    }

    /// Histogram / handle axis covering `interval`.
    func scrubberBuckets(calendar: Calendar = .autoupdatingCurrent) -> [DateInterval] {
        Self.buckets(
            from: interval.start,
            to: interval.end,
            component: scrubberBucketComponent,
            calendar: calendar
        )
    }

    /// All Time spans whatever was recorded, so its bars size to the history, not to whole years.
    private var scrubberBucketComponent: Calendar.Component {
        guard granularity == .allTime else { return granularity.scrubberBucketComponent }
        switch interval.duration / 86_400 {
        case ...62: return .day
        case ...(5 * 366): return .month
        default: return .year
        }
    }

    /// Whole calendar days overlapping `focus`, used to filter share timelines.
    func overlappingDayStarts(calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        let start = calendar.startOfDay(for: focus.start)
        let last = calendar.startOfDay(for: focus.end.addingTimeInterval(-1))
        return Self.buckets(from: start, to: calendar.date(byAdding: .day, value: 1, to: last) ?? focus.end, component: .day, calendar: calendar)
            .map(\.start)
    }

    func matchingPreset(now: Date, calendar: Calendar) -> MapRangePreset? {
        guard !isCustom, abs(focus.start.timeIntervalSince(interval.start)) < 1,
              abs(focus.end.timeIntervalSince(interval.end)) < 1 else { return nil }
        return MapRangePreset.allCases.first { candidate in
            // All Time's start depends on the recorded data. Custom ranges already returned above.
            if candidate == .allTime { return granularity == .allTime }
            let other = Self.preset(candidate, now: now, calendar: calendar)
            return other.granularity == granularity
                && abs(other.interval.start.timeIntervalSince(interval.start)) < 1
                && abs(other.interval.end.timeIntervalSince(interval.end)) < 1
        }
    }

    private static func periodSelection(
        containing date: Date,
        granularity: MapGranularity,
        calendar: Calendar
    ) -> MapRangeSelection {
        let interval = period(containing: date, granularity: granularity, calendar: calendar)
        return MapRangeSelection(interval: interval, granularity: granularity, focus: interval, isCustom: false)
    }

    static func buckets(
        from start: Date,
        to end: Date,
        component: Calendar.Component,
        calendar: Calendar,
        limit: Int = 400
    ) -> [DateInterval] {
        var result: [DateInterval] = []
        var cursor = start
        while cursor < end {
            let next = calendar.date(byAdding: component, value: 1, to: cursor) ?? end
            result.append(DateInterval(start: cursor, end: min(next, end)))
            cursor = next
            if result.count >= limit { break }
        }
        return result
    }

    private static func periodTitle(for interval: DateInterval, granularity: MapGranularity, calendar: Calendar) -> String {
        switch granularity {
        case .month:
            return interval.start.formatted(.dateTime.month(.abbreviated).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        default:
            return spanTitle(for: interval, granularity: granularity, now: interval.start, calendar: calendar)
        }
    }

    private static func spanTitle(
        for interval: DateInterval,
        granularity: MapGranularity,
        now: Date,
        calendar: Calendar
    ) -> String {
        let lastIncluded = interval.end.addingTimeInterval(-1)
        if calendar.isDate(interval.start, inSameDayAs: lastIncluded) {
            if isFullDay(interval, calendar: calendar) {
                if calendar.isDateInToday(interval.start) { return String(localized: "Today") }
                if calendar.isDateInYesterday(interval.start) { return String(localized: "Yesterday") }
                return interval.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            }
            let locale = calendar.locale ?? Locale.autoupdatingCurrent
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.calendar = calendar
            weekdayFormatter.timeZone = calendar.timeZone
            weekdayFormatter.locale = locale
            weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
            let timeFormatter = DateFormatter()
            timeFormatter.calendar = calendar
            timeFormatter.timeZone = calendar.timeZone
            timeFormatter.locale = locale
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none
            let weekday = weekdayFormatter.string(from: interval.start)
            return "\(weekday) \(timeFormatter.string(from: interval.start))–\(timeFormatter.string(from: interval.end))"
        }

        switch granularity {
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: interval.start, to: lastIncluded)
        case .month:
            if calendar.component(.year, from: interval.start) == calendar.component(.year, from: lastIncluded),
               calendar.component(.month, from: interval.start) == calendar.component(.month, from: lastIncluded) {
                return interval.start.formatted(.dateTime.month(.abbreviated).year())
            }
            fallthrough
        case .year:
            if calendar.component(.year, from: interval.start) == calendar.component(.year, from: lastIncluded),
               calendar.component(.month, from: interval.start) == 1,
               calendar.component(.day, from: interval.start) == 1 {
                return interval.start.formatted(.dateTime.year())
            }
            fallthrough
        case .day, .allTime:
            let formatter = DateIntervalFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = granularity == .day ? .short : .none
            return formatter.string(from: interval.start, to: lastIncluded)
        }
    }

    private static func isFullDay(_ interval: DateInterval, calendar: Calendar) -> Bool {
        let day = period(containing: interval.start, granularity: .day, calendar: calendar)
        return abs(interval.start.timeIntervalSince(day.start)) < 1
            && abs(interval.end.timeIntervalSince(day.end)) < 1
    }
}

/// Parses `moves://map?from=&to=` into a custom interval.
enum MapDeepLink {
    static func interval(from url: URL) -> DateInterval? {
        guard url.scheme?.lowercased() == "moves" else { return nil }
        guard url.host?.lowercased() == "map" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fromRaw = items.first(where: { $0.name == "from" })?.value
        let toRaw = items.first(where: { $0.name == "to" })?.value
        guard let fromRaw, let start = TimelineDeepLink.parseTimestamp(fromRaw) else { return nil }
        let end = toRaw.flatMap(TimelineDeepLink.parseTimestamp) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: min(start, end), end: max(start, end))
    }

    /// Builds `moves://at?t=` for “Open in Timeline”.
    static func timelineURL(at date: Date) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var components = URLComponents()
        components.scheme = "moves"
        components.host = "at"
        components.queryItems = [URLQueryItem(name: "t", value: formatter.string(from: date))]
        return components.url
    }
}
