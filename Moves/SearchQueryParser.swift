import Foundation

/// Turns a search field into leftover place/note text plus an optional day and clock time.
enum SearchQueryParser {
    /// Result of parsing a unified search query.
    struct ParsedQuery: Equatable, Sendable {
        /// Place names, cities, and note text after date/time phrases are stripped.
        var freeText: String = ""
        /// Start of a matched calendar day.
        var day: Date?
        /// Instant for moment search (`moves://at/`).
        var moment: Date?

        var isEmpty: Bool {
            freeText.isEmpty && day == nil && moment == nil
        }

        var hasTemporalMatch: Bool {
            day != nil || moment != nil
        }
    }

    private struct ClockTime: Equatable {
        var hour: Int
        var minute: Int
    }

    /// Parses `query` relative to `now`. Weekday phrases use `calendar`; English names always work.
    static func parse(
        _ query: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ParsedQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedQuery() }

        var working = trimmed
        let clock = extractTime(from: &working)
        let day = extractDay(from: &working, now: now, calendar: calendar)

        var moment: Date?
        if let day, let clock {
            moment = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day)
        } else if let clock, day == nil {
            if let today = calendar.date(
                bySettingHour: clock.hour,
                minute: clock.minute,
                second: 0,
                of: now
            ) {
                moment = today <= now
                    ? today
                    : calendar.date(byAdding: .day, value: -1, to: today)
            }
        }

        let freeText = working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedQuery(
            freeText: freeText,
            day: day.map { calendar.startOfDay(for: $0) },
            moment: moment
        )
    }

    /// Deep link for a moment result, using the calendar time zone.
    static func momentURL(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        var components = URLComponents()
        components.scheme = "moves"
        components.host = "at"
        components.queryItems = [URLQueryItem(name: "t", value: formatter.string(from: date))]
        return components.url
    }

    /// Deep link for a day result (`yyyy-MM-dd`).
    static func dayURL(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> URL? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return URL(string: "moves://day/\(formatter.string(from: calendar.startOfDay(for: date)))")
    }

    // MARK: - Time

    private static func extractTime(from text: inout String) -> ClockTime? {
        let pattern = #"(?i)(?:\bat\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b|(?i)(?:\bat\s+)(\d{1,2}):(\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else {
            return extractTwentyFourHourTime(from: &text)
        }

        let clock: ClockTime?
        if match.range(at: 1).location != NSNotFound {
            let hour = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let minute = match.range(at: 2).location != NSNotFound
                ? Int(ns.substring(with: match.range(at: 2))) ?? 0
                : 0
            let meridiem = ns.substring(with: match.range(at: 3)).lowercased()
            clock = ClockTime(hour: hour24(hour, meridiem: meridiem), minute: minute)
        } else {
            let hour = Int(ns.substring(with: match.range(at: 4))) ?? 0
            let minute = Int(ns.substring(with: match.range(at: 5))) ?? 0
            clock = ClockTime(hour: hour, minute: minute)
        }

        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return clock
    }

    private static func extractTwentyFourHourTime(from text: inout String) -> ClockTime? {
        let pattern = #"(?i)(?:\bat\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        let hour = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let minute = Int(ns.substring(with: match.range(at: 2))) ?? 0
        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return ClockTime(hour: hour, minute: minute)
    }

    private static func hour24(_ hour: Int, meridiem: String) -> Int {
        let isPM = meridiem.contains("p")
        if hour == 12 {
            return isPM ? 12 : 0
        }
        return isPM ? hour + 12 : hour
    }

    // MARK: - Day

    private static func extractDay(from text: inout String, now: Date, calendar: Calendar) -> Date? {
        let lowered = text.lowercased()

        if let date = matchRelativeWord(in: &text, now: now, calendar: calendar) {
            return date
        }
        if let date = matchLastOrThisWeekday(in: &text, now: now, calendar: calendar) {
            return date
        }
        if let date = matchHoliday(in: &text, now: now, calendar: calendar) {
            return date
        }
        if let date = matchISODate(in: &text, calendar: calendar) {
            return date
        }
        if let date = matchBareWeekday(in: &text, now: now, calendar: calendar) {
            return date
        }
        if let date = matchFormattedDate(in: lowered, now: now, calendar: calendar) {
            removeFirstOccurrence(of: lowered, matchingDate: date, from: &text, calendar: calendar)
            return date
        }
        return nil
    }

    private static func matchRelativeWord(
        in text: inout String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        let patterns: [(String, Int)] = [
            ("the day before yesterday", -2),
            ("day before yesterday", -2),
            ("yesterday", -1),
            ("tomorrow", 1),
            ("today", 0)
        ]
        let lowered = text.lowercased()
        for (word, offset) in patterns {
            if let range = lowered.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) {
                let nsRange = NSRange(range, in: text)
                if let swiftRange = Range(nsRange, in: text) {
                    text.removeSubrange(swiftRange)
                }
                return calendar.date(byAdding: .day, value: offset, to: today)
            }
        }
        return nil
    }

    private static func matchLastOrThisWeekday(
        in text: inout String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pattern = #"(?i)\b(last|this)\s+(weekday)\b"#.replacingOccurrences(
            of: "weekday",
            with: weekdayAlternation()
        )
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        let qualifier = ns.substring(with: match.range(at: 1)).lowercased()
        let weekdayToken = ns.substring(with: match.range(at: 2))
        guard let weekday = weekdayNumber(from: weekdayToken, calendar: calendar) else { return nil }
        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        if qualifier == "last" {
            return lastOccurrence(of: weekday, before: now, calendar: calendar, excludingToday: true)
        }
        return occurrenceThisWeek(of: weekday, now: now, calendar: calendar)
    }

    private static func matchBareWeekday(
        in text: inout String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pattern = #"(?i)\b(weekday)\b"#.replacingOccurrences(of: "weekday", with: weekdayAlternation())
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        let token = ns.substring(with: match.range(at: 1))
        guard let weekday = weekdayNumber(from: token, calendar: calendar) else { return nil }
        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return lastOccurrence(of: weekday, before: now, calendar: calendar, excludingToday: false)
    }

    private static func matchHoliday(
        in text: inout String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pattern = #"(?i)\b(last\s+)?(christmas|xmas|halloween|new\s+year'?s(?:\s+eve)?|new\s+year'?s\s+day|valentine'?s(?:\s+day)?)(?:\s+(\d{4}))?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        let wantsLast = match.range(at: 1).location != NSNotFound
        let name = ns.substring(with: match.range(at: 2)).lowercased()
        let year: Int?
        if match.range(at: 3).location != NSNotFound {
            year = Int(ns.substring(with: match.range(at: 3)))
        } else {
            year = nil
        }
        guard let date = holidayDate(name: name, year: year, now: now, calendar: calendar, last: wantsLast) else {
            return nil
        }
        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return date
    }

    private static func matchISODate(in text: inout String, calendar: Calendar) -> Date? {
        let pattern = #"\b(\d{4})-(\d{2})-(\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        let year = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let month = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let day = Int(ns.substring(with: match.range(at: 3))) ?? 0
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        if let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return calendar.startOfDay(for: date)
    }

    private static func matchFormattedDate(
        in lowered: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let formats = ["d MMMM yyyy", "MMMM d yyyy", "d MMM yyyy", "MMM d yyyy", "d MMMM", "MMMM d", "d MMM", "MMM d"]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.defaultDate = calendar.startOfDay(for: now)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: lowered.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func removeFirstOccurrence(
        of lowered: String,
        matchingDate: Date,
        from text: inout String,
        calendar: Calendar
    ) {
        _ = matchingDate
        _ = calendar
        // The formatted-date path only runs when the whole remainder is a date.
        if lowered.count == text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).count {
            text = ""
        }
    }

    private static func holidayDate(
        name: String,
        year: Int?,
        now: Date,
        calendar: Calendar,
        last: Bool
    ) -> Date? {
        let currentYear = calendar.component(.year, from: now)
        let monthDay: (Int, Int)
        if name.contains("christmas") || name == "xmas" {
            monthDay = (12, 25)
        } else if name.contains("halloween") {
            monthDay = (10, 31)
        } else if name.contains("eve") {
            monthDay = (12, 31)
        } else if name.contains("new") {
            monthDay = (1, 1)
        } else if name.contains("valentine") {
            monthDay = (2, 14)
        } else {
            return nil
        }

        func date(in year: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: monthDay.0, day: monthDay.1))
        }

        if let year, let date = date(in: year) {
            return calendar.startOfDay(for: date)
        }

        guard let thisYear = date(in: currentYear) else { return nil }
        let start = calendar.startOfDay(for: thisYear)
        let today = calendar.startOfDay(for: now)
        if last || start > today {
            return date(in: currentYear - 1).map { calendar.startOfDay(for: $0) }
        }
        return start
    }

    /// Previous (or current, when `excludingToday` is false) occurrence of `weekday`.
    static func lastOccurrence(
        of weekday: Int,
        before now: Date,
        calendar: Calendar,
        excludingToday: Bool
    ) -> Date {
        var date = calendar.startOfDay(for: now)
        let todayWeekday = calendar.component(.weekday, from: date)
        if !excludingToday, todayWeekday == weekday {
            return date
        }
        for _ in 1...7 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
            if calendar.component(.weekday, from: date) == weekday {
                return date
            }
        }
        return date
    }

    private static func occurrenceThisWeek(
        of weekday: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let interval = calendar.dateInterval(of: .weekOfYear, for: today) ?? DateInterval(start: today, duration: 7 * 24 * 3600)
        var cursor = calendar.startOfDay(for: interval.start)
        for _ in 0..<7 {
            if calendar.component(.weekday, from: cursor) == weekday {
                return cursor
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return today
    }

    static func weekdayNumber(from token: String, calendar: Calendar) -> Int? {
        let folded = token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: calendar.locale)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            .lowercased()

        let english: [String: Int] = [
            "sunday": 1, "sun": 1,
            "monday": 2, "mon": 2,
            "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4,
            "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
            "friday": 6, "fri": 6,
            "saturday": 7, "sat": 7
        ]
        if let value = english[folded] {
            return value
        }

        let lists = [
            calendar.weekdaySymbols,
            calendar.shortWeekdaySymbols,
            calendar.veryShortWeekdaySymbols,
            calendar.standaloneWeekdaySymbols,
            calendar.shortStandaloneWeekdaySymbols
        ]
        for symbols in lists {
            if let index = symbols.firstIndex(where: {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: calendar.locale)
                    .lowercased() == folded
            }) {
                return index + 1
            }
        }
        return nil
    }

    private static func weekdayAlternation() -> String {
        [
            "tuesday", "tues", "thu", "thur", "thurs", "thursday",
            "wednesday", "monday", "friday", "saturday", "sunday",
            "mon", "tue", "wed", "fri", "sat", "sun"
        ].joined(separator: "|")
    }
}
