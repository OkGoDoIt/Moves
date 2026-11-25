import CoreLocation
import Foundation

/// Countries and cities a person has been to, with the dates they were there.
struct InsightsGeography: Equatable, Sendable {
    /// An unbroken run of days in one country or city. Both ends are starts of days.
    struct Stay: Equatable, Hashable, Sendable {
        var start: Date
        var end: Date
        var dayCount: Int
    }

    struct Point: Equatable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    struct City: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let countryCode: String
        let visitCount: Int
        let dayCount: Int
        let stays: [Stay]
        /// Middle of the stays there; nil when none has coordinates.
        let center: Point?
        /// Where the stays were, thinned out for a map.
        let points: [Point]
    }

    struct Country: Identifiable, Equatable, Sendable {
        var id: String { code }
        let code: String
        let name: String
        let visitCount: Int
        let dayCount: Int
        let stays: [Stay]
        /// Most days first.
        let cities: [City]

        var flagEmoji: String { PlacesGeography.flagEmoji(forCountryCode: code) }
        var continent: WorldContinent { WorldContinent(countryCode: code) }
        var firstDay: Date? { stays.first?.start }
        var lastDay: Date? { stays.last?.end }
    }

    struct ContinentGroup: Identifiable, Equatable, Sendable {
        var id: String { continent.id }
        let continent: WorldContinent
        /// Most days first.
        let countries: [Country]

        var dayCount: Int { countries.reduce(0) { $0 + $1.dayCount } }
        var cities: [City] { countries.flatMap(\.cities) }
    }

    /// Most days first.
    let countries: [Country]

    static let empty = InsightsGeography(countries: [])

    var cityCount: Int { countries.reduce(0) { $0 + $1.cities.count } }
    var countryCodes: Set<String> { Set(countries.map(\.code)) }

    /// Continents, the one with the most days first.
    var continents: [ContinentGroup] {
        Dictionary(grouping: countries, by: \.continent)
            .map { ContinentGroup(continent: $0.key, countries: $0.value) }
            .sorted {
                if $0.dayCount != $1.dayCount { return $0.dayCount > $1.dayCount }
                return $0.continent.name.localizedStandardCompare($1.continent.name) == .orderedAscending
            }
    }

    func country(_ code: String) -> Country? {
        countries.first { $0.code == code }
    }

    func city(_ id: String) -> City? {
        for country in countries {
            if let city = country.cities.first(where: { $0.id == id }) { return city }
        }
        return nil
    }
}

/// A continent by its UN M49 code, named by the system in the reader's language.
struct WorldContinent: Hashable, Sendable, Identifiable {
    let id: String

    init(countryCode: String) {
        // The system files Antarctica under Oceania and keeps the Americas as one.
        if countryCode == "AQ" {
            id = "AQ"
        } else {
            let region = Locale.Region(countryCode)
            let continent = region.continent?.identifier ?? ""
            let isSouthAmerica = region.containingRegion?.identifier == "005"
            id = continent == "019" ? (isSouthAmerica ? "005" : "003") : continent
        }
    }

    var name: String {
        guard !id.isEmpty, let name = Locale.current.localizedString(forRegionCode: id) else {
            return String(localized: "Other")
        }
        return name
    }
}

/// Builds `InsightsGeography` from day records. Safe to call off the main actor.
enum InsightsGeographyBuilder {
    /// Days with nothing recorded still belong to a stay when the same country, or city,
    /// comes both before and after them and nowhere else comes between.
    static let countryGapDays = 7
    static let cityGapDays = 3
    /// One stay never counts for longer than this, however late its departure was found.
    private static let longestVisitDays = 366
    private static let pointLimit = 150

    /// The whole history, or the part of it inside `period`.
    static func build(
        days: [InsightsDayRecord],
        period: InsightsPeriod = .all,
        calendar: Calendar = .autoupdatingCurrent
    ) -> InsightsGeography {
        var countryDays: [String: Set<Date>] = [:]
        var cityDays: [String: Set<Date>] = [:]
        var countryVisits: [String: Int] = [:]
        var cities: [String: CityDraft] = [:]

        for day in days {
            for visit in day.visits {
                let place = VisitGeography.resolve(visit)
                guard let country = place.countryCode else { continue }
                let span = daySpan(of: visit, dayStart: day.dayStart, calendar: calendar)
                let counts = InsightsSnapshotBuilder.contains(period, dayStart: day.dayStart, calendar: calendar)
                countryDays[country, default: []].formUnion(span)
                if counts { countryVisits[country, default: 0] += 1 }

                guard let cityID = place.cityID, let name = place.cityName else { continue }
                cityDays[cityID, default: []].formUnion(span)
                var draft = cities[cityID] ?? CityDraft(name: name, countryCode: country)
                draft.add(visit, counts: counts)
                cities[cityID] = draft
            }
        }

        let countryStays = stays(from: countryDays, gapDays: countryGapDays, calendar: calendar)
        let cityStays = stays(from: cityDays, gapDays: cityGapDays, calendar: calendar)
        let interval = dateInterval(of: period, calendar: calendar)

        var citiesByCountry: [String: [InsightsGeography.City]] = [:]
        for (id, draft) in cities {
            let stays = clipped(cityStays[id] ?? [], to: interval, calendar: calendar)
            guard !stays.isEmpty else { continue }
            citiesByCountry[draft.countryCode, default: []].append(InsightsGeography.City(
                id: id,
                name: draft.name,
                countryCode: draft.countryCode,
                visitCount: draft.visitCount,
                dayCount: stays.reduce(0) { $0 + $1.dayCount },
                stays: stays,
                center: draft.center,
                points: draft.thinnedPoints(limit: pointLimit)
            ))
        }

        let countries = countryStays.compactMap { code, allStays -> InsightsGeography.Country? in
            let stays = clipped(allStays, to: interval, calendar: calendar)
            guard !stays.isEmpty else { return nil }
            return InsightsGeography.Country(
                code: code,
                name: PlacesGeography.countryName(forCountryCode: code),
                visitCount: countryVisits[code] ?? 0,
                dayCount: stays.reduce(0) { $0 + $1.dayCount },
                stays: stays,
                cities: (citiesByCountry[code] ?? []).sorted {
                    if $0.dayCount != $1.dayCount { return $0.dayCount > $1.dayCount }
                    if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            )
        }
        return InsightsGeography(countries: countries.sorted {
            if $0.dayCount != $1.dayCount { return $0.dayCount > $1.dayCount }
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private struct CityDraft {
        let name: String
        let countryCode: String
        var visitCount = 0
        private var points: Set<InsightsGeography.Point> = []

        init(name: String, countryCode: String) {
            self.name = name
            self.countryCode = countryCode
        }

        mutating func add(_ visit: InsightsVisitRecord, counts: Bool) {
            if counts { visitCount += 1 }
            guard let latitude = visit.latitude, let longitude = visit.longitude else { return }
            // Stays a few doors apart are one dot at city scale.
            points.insert(.init(latitude: (latitude * 500).rounded() / 500, longitude: (longitude * 500).rounded() / 500))
        }

        /// Summed in one fixed order, so the same stays give the same center to the last digit.
        private var sorted: [InsightsGeography.Point] {
            points.sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }
        }

        var center: InsightsGeography.Point? {
            guard !points.isEmpty else { return nil }
            let sum = sorted.reduce((0.0, 0.0)) { ($0.0 + $1.latitude, $0.1 + $1.longitude) }
            return .init(latitude: sum.0 / Double(points.count), longitude: sum.1 / Double(points.count))
        }

        func thinnedPoints(limit: Int) -> [InsightsGeography.Point] {
            let sorted = sorted
            guard sorted.count > limit else { return sorted }
            let step = Double(sorted.count) / Double(limit)
            return (0..<limit).map { sorted[Int(Double($0) * step)] }
        }
    }

    /// Every day the visit touches. A night in a hotel counts for both of its days.
    ///
    /// The days are the dates on the clock where the visit happened, each held as midnight
    /// of that date on `calendar`: a night in Tokyo counts for its two Tokyo dates,
    /// whatever zone the phone is in now.
    private static func daySpan(of visit: InsightsVisitRecord, dayStart: Date, calendar: Calendar) -> Set<Date> {
        guard let arrival = visit.arrivalDate else { return [calendar.startOfDay(for: dayStart)] }
        var zone = calendar.timeZone
        if let latitude = visit.latitude, let longitude = visit.longitude,
           let placeZone = PlaceTimeZone.timeZone(at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            zone = placeZone
        }
        let first = PlaceClock.calendarDate(of: arrival, in: zone, on: calendar)
        var result: Set<Date> = [first]
        guard let departure = visit.departureDate, departure > arrival else { return result }
        let last = PlaceClock.calendarDate(of: departure, in: zone, on: calendar)
        var cursor = first
        while result.count < longestVisitDays,
              let next = calendar.date(byAdding: .day, value: 1, to: cursor), next <= last {
            result.insert(next)
            cursor = next
        }
        return result
    }

    /// Runs of days in each region, broken by a day seen only elsewhere or by a long gap.
    private static func stays(
        from daysByRegion: [String: Set<Date>],
        gapDays: Int,
        calendar: Calendar
    ) -> [String: [InsightsGeography.Stay]] {
        let seen = daysByRegion.values.reduce(into: Set<Date>()) { $0.formUnion($1) }.sorted()
        let order = Dictionary(uniqueKeysWithValues: seen.enumerated().map { ($1, $0) })

        return daysByRegion.mapValues { days in
            var result: [InsightsGeography.Stay] = []
            var previous: Date?
            for day in days.sorted() {
                let gap = previous.map { calendar.dateComponents([.day], from: $0, to: day).day ?? .max }
                // Adjacent among all days seen anywhere: nothing elsewhere came between.
                let isNextSeen = previous.flatMap { order[$0] }.map { $0 + 1 == order[day] } ?? false
                if let gap, isNextSeen, gap <= gapDays + 1, var stay = result.popLast() {
                    stay.end = day
                    stay.dayCount += gap
                    result.append(stay)
                } else {
                    result.append(.init(start: day, end: day, dayCount: 1))
                }
                previous = day
            }
            return result
        }
    }

    private static func clipped(
        _ stays: [InsightsGeography.Stay],
        to interval: DateInterval?,
        calendar: Calendar
    ) -> [InsightsGeography.Stay] {
        guard let interval else { return stays }
        return stays.compactMap { stay in
            guard stay.end >= interval.start, stay.start < interval.end else { return nil }
            let start = max(stay.start, interval.start)
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            let end = min(stay.end, calendar.startOfDay(for: lastDay))
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return .init(start: start, end: end, dayCount: days + 1)
        }
    }

    private static func dateInterval(of period: InsightsPeriod, calendar: Calendar) -> DateInterval? {
        guard case .year(let year) = period,
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        return calendar.dateInterval(of: .year, for: start)
    }
}
