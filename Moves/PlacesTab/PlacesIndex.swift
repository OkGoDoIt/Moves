import CoreLocation
import Foundation
import Observation
import SwiftData
import SwiftUI

/// How learned places are ordered inside a city section.
enum PlacesSort: String, CaseIterable, Identifiable, Sendable {
    case mostVisited
    case mostTime
    case recent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostVisited: return String(localized: "Most visited")
        case .mostTime: return String(localized: "Most time")
        case .recent: return String(localized: "Recent")
        case .name: return String(localized: "A–Z")
        }
    }
}

/// User-facing category stored on `KnownPlace.category`.
enum KnownPlaceCategory: String, CaseIterable, Identifiable, Sendable {
    case home
    case work
    case gym
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .work: return String(localized: "Work")
        case .gym: return String(localized: "Gym")
        case .other: return String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .gym: return "figure.strengthtraining.traditional"
        case .other: return "mappin.and.ellipse"
        }
    }

    init?(stored: String?) {
        guard let stored else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: trimmed)
    }
}

/// A 7×24 arrival heatmap. Weekday index 0 is Sunday in Gregorian calendars
/// (`Calendar.component(.weekday) - 1`); the chart remaps to the locale’s first weekday.
struct OccupancyGrid: Equatable, Sendable {
    static let weekdayCount = 7
    static let hourCount = 24

    /// `counts[weekday][hour]`.
    let counts: [[Int]]
    let maximum: Int

    static let empty = OccupancyGrid(
        counts: Array(repeating: Array(repeating: 0, count: hourCount), count: weekdayCount),
        maximum: 0
    )

    /// Builds a 7×24 grid from **user-confirmed** arrivals.
    ///
    /// Auto-assigned visits are ignored so occupancy matches
    /// `KnownPlace.arrivalHourHistogram` / `weekdayHistogram` (Sunday = 0).
    /// When there are no `.user` visits, reconstructs a rank‑1 grid from those
    /// stored histograms.
    static func build(
        visits: [PlacesVisitRecord],
        hourHistogram: [Int] = [],
        weekdayHistogram: [Int] = [],
        calendar: Calendar
    ) -> OccupancyGrid {
        var counts = Array(
            repeating: Array(repeating: 0, count: hourCount),
            count: weekdayCount
        )

        let confirmed = visits.filter { $0.assignmentSource == .user }
        if !confirmed.isEmpty {
            for visit in confirmed {
                let weekday = calendar.component(.weekday, from: visit.arrivalDate) - 1
                let hour = calendar.component(.hour, from: visit.arrivalDate)
                guard weekday >= 0, weekday < weekdayCount, hour >= 0, hour < hourCount else { continue }
                counts[weekday][hour] += 1
            }
        } else {
            let hours = paddedHistogram(hourHistogram, count: hourCount)
            let weekdays = paddedHistogram(weekdayHistogram, count: weekdayCount)
            for weekday in 0..<weekdayCount {
                for hour in 0..<hourCount {
                    counts[weekday][hour] = weekdays[weekday] * hours[hour]
                }
            }
        }

        let maximum = counts.flatMap { $0 }.max() ?? 0
        return OccupancyGrid(counts: counts, maximum: maximum)
    }

    var hasData: Bool { maximum > 0 }

    /// Peak cell used for VoiceOver.
    var peakSummary: String {
        guard hasData else { return String(localized: "No usual time yet") }
        var bestWeekday = 0
        var bestHour = 0
        var bestCount = 0
        for weekday in 0..<OccupancyGrid.weekdayCount {
            for hour in 0..<OccupancyGrid.hourCount {
                let value = counts[weekday][hour]
                if value > bestCount {
                    bestCount = value
                    bestWeekday = weekday
                    bestHour = hour
                }
            }
        }
        let symbols = Calendar.autoupdatingCurrent.veryShortWeekdaySymbols
        let weekdayLabel = symbols.indices.contains(bestWeekday) ? symbols[bestWeekday] : ""
        return String(localized: "Usually \(weekdayLabel) at \(bestHour):00")
    }

    private static func paddedHistogram(_ values: [Int], count: Int) -> [Int] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: 0, count: count - values.count)
    }
}

/// Snapshot of a single visit used while grouping off the main actor.
struct PlacesVisitRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var knownPlaceID: UUID?
    var name: String
    var latitude: Double
    var longitude: Double
    var arrivalDate: Date
    var departureDate: Date?
    var countryCode: String?
    var locality: String?
    var administrativeArea: String?
    var isHiddenAsShortStop: Bool
    var dayKey: String?
    var assignmentSource: PlaceAssignmentSource

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Stay length; open visits run until `now`.
    func stayDuration(now: Date) -> TimeInterval {
        let end = min(departureDate ?? now, now)
        return max(end.timeIntervalSince(arrivalDate), 0)
    }

    init(
        id: UUID = UUID(),
        knownPlaceID: UUID? = nil,
        name: String,
        latitude: Double,
        longitude: Double,
        arrivalDate: Date,
        departureDate: Date?,
        countryCode: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        isHiddenAsShortStop: Bool = false,
        dayKey: String? = nil,
        assignmentSource: PlaceAssignmentSource = .none
    ) {
        self.id = id
        self.knownPlaceID = knownPlaceID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.countryCode = countryCode
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.isHiddenAsShortStop = isHiddenAsShortStop
        self.dayKey = dayKey
        self.assignmentSource = assignmentSource
    }

    init(_ visit: VisitPlace) {
        id = visit.id
        knownPlaceID = visit.knownPlace?.id
        name = visit.displayTitle
        latitude = visit.latitude
        longitude = visit.longitude
        arrivalDate = visit.arrivalDate
        departureDate = visit.departureDate
        countryCode = visit.countryCode
        locality = visit.locality
        administrativeArea = visit.administrativeArea
        isHiddenAsShortStop = visit.isHiddenAsShortStop
        dayKey = visit.dayTimeline?.dayKey
        assignmentSource = visit.assignmentSource
    }
}

/// Snapshot of a learned place used while grouping off the main actor.
struct PlacesKnownRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var category: String?
    var latitude: Double
    var longitude: Double
    var footprintRadius: Double
    var countryCode: String?
    var locality: String?
    var administrativeArea: String?
    var confirmedVisitCount: Int
    var lastVisitAt: Date?
    var arrivalHourHistogram: [Int]
    var weekdayHistogram: [Int]
    var stayDurationSamples: [Double]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var parsedCategory: KnownPlaceCategory? {
        KnownPlaceCategory(stored: category)
    }

    init(
        id: UUID = UUID(),
        name: String,
        category: String? = nil,
        latitude: Double,
        longitude: Double,
        footprintRadius: Double = 40,
        countryCode: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        confirmedVisitCount: Int = 0,
        lastVisitAt: Date? = nil,
        arrivalHourHistogram: [Int] = Array(repeating: 0, count: 24),
        weekdayHistogram: [Int] = Array(repeating: 0, count: 7),
        stayDurationSamples: [Double] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.footprintRadius = footprintRadius
        self.countryCode = countryCode
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.confirmedVisitCount = confirmedVisitCount
        self.lastVisitAt = lastVisitAt
        self.arrivalHourHistogram = arrivalHourHistogram
        self.weekdayHistogram = weekdayHistogram
        self.stayDurationSamples = stayDurationSamples
    }

    init(_ place: KnownPlace) {
        id = place.id
        name = place.name
        category = place.category
        latitude = place.centerLatitude
        longitude = place.centerLongitude
        footprintRadius = place.footprintRadius
        countryCode = place.countryCode
        locality = place.locality
        administrativeArea = place.administrativeArea
        confirmedVisitCount = place.confirmedVisitCount
        lastVisitAt = place.lastVisitAt
        arrivalHourHistogram = place.arrivalHourHistogram
        weekdayHistogram = place.weekdayHistogram
        stayDurationSamples = place.stayDurationSamples
    }
}

/// One learned place as shown in the Places list and detail.
struct PlacesPlaceSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var category: KnownPlaceCategory?
    var countryCode: String?
    var locality: String?
    var administrativeArea: String?
    var visitCount: Int
    var totalStay: TimeInterval
    var averageStay: TimeInterval
    var firstVisitAt: Date?
    var lastVisitAt: Date?
    var latitude: Double
    var longitude: Double
    var footprintRadius: Double
    var occupancy: OccupancyGrid
    var visitIDs: [UUID]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var subtitle: String {
        let visits = visitCount == 1
            ? String(localized: "1 visit")
            : String(localized: "\(visitCount) visits")
        let time = MovesStatisticsFormatting.duration(totalStay)
        if let lastVisitAt {
            return "\(visits) · \(time) · \(lastVisitAt.formatted(.relative(presentation: .named)))"
        }
        return "\(visits) · \(time)"
    }
}

/// Nearby unassigned visits that can become a `KnownPlace` with Confirm.
struct PlacesSuggestedCluster: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var visitIDs: [UUID]
    var visitCount: Int
    var totalStay: TimeInterval
    var lastVisitAt: Date?
    var latitude: Double
    var longitude: Double
    var countryCode: String?
    var locality: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var subtitle: String {
        let visits = visitCount == 1
            ? String(localized: "1 visit")
            : String(localized: "\(visitCount) visits")
        if let lastVisitAt {
            return "\(visits) · \(lastVisitAt.formatted(.relative(presentation: .named)))"
        }
        return visits
    }
}

/// City bucket inside a country.
struct PlacesCitySection: Equatable, Sendable, Identifiable {
    var id: String
    var cityName: String
    var places: [PlacesPlaceSummary]
}

/// Country bucket (flag + localized name) containing city sections.
struct PlacesCountrySection: Equatable, Sendable, Identifiable {
    var id: String
    var countryCode: String?
    var countryName: String
    var flagEmoji: String
    var cities: [PlacesCitySection]
}

/// Complete Places tab model, built off-main from `KnownPlace` + unassigned visits.
struct PlacesIndexSnapshot: Equatable, Sendable {
    var countries: [PlacesCountrySection]
    var suggested: [PlacesSuggestedCluster]
    var placeCount: Int
    var visitCount: Int

    static let empty = PlacesIndexSnapshot(countries: [], suggested: [], placeCount: 0, visitCount: 0)

    var isEmpty: Bool { placeCount == 0 && suggested.isEmpty }

    func place(id: UUID) -> PlacesPlaceSummary? {
        for country in countries {
            for city in country.cities {
                if let place = city.places.first(where: { $0.id == id }) {
                    return place
                }
            }
        }
        return nil
    }

    func suggestedCluster(id: String) -> PlacesSuggestedCluster? {
        suggested.first { $0.id == id }
    }
}

/// Pure grouping / sorting used by the Places tab and unit tests.
enum PlacesIndexBuilder {
    /// Distance used to cluster unassigned visits that share a name.
    static let namedClusterRadius: CLLocationDistance = 120
    /// Unnamed visits share a ~100 m bucket.
    static let unnamedBucketDegrees = 1_000.0

    static func build(
        knownPlaces: [PlacesKnownRecord],
        visits: [PlacesVisitRecord],
        sort: PlacesSort,
        query: String,
        now: Date,
        calendar: Calendar
    ) -> PlacesIndexSnapshot {
        let visitsByKnownID = Dictionary(grouping: visits.filter { $0.knownPlaceID != nil }) { record in
            record.knownPlaceID ?? UUID()
        }

        let summaries = knownPlaces.map { place in
            summary(
                for: place,
                visits: visitsByKnownID[place.id] ?? [],
                now: now,
                calendar: calendar
            )
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = needle.isEmpty
            ? summaries
            : summaries.filter { matches($0, query: needle) }

        let countries = groupByGeography(visible, sort: sort)
        let suggested = suggestedClusters(
            from: visits.filter { $0.knownPlaceID == nil && !$0.isHiddenAsShortStop },
            query: needle,
            now: now
        )

        return PlacesIndexSnapshot(
            countries: countries,
            suggested: suggested,
            placeCount: visible.count,
            visitCount: visits.count
        )
    }

    static func summary(
        for place: PlacesKnownRecord,
        visits: [PlacesVisitRecord],
        now: Date,
        calendar: Calendar
    ) -> PlacesPlaceSummary {
        let confirmed = visits.filter { $0.assignmentSource == .user }
        let sampleTotal = place.stayDurationSamples.reduce(0, +)
        let visitTotal = confirmed.reduce(0) { $0 + $1.stayDuration(now: now) }
        let totalStay = sampleTotal > 0 ? sampleTotal : visitTotal
        let visitCount = max(confirmed.count, place.confirmedVisitCount)
        let averageStay: TimeInterval = {
            if !place.stayDurationSamples.isEmpty {
                return sampleTotal / Double(place.stayDurationSamples.count)
            }
            return visitCount > 0 ? totalStay / Double(visitCount) : 0
        }()
        let firstVisit = confirmed.map(\.arrivalDate).min() ?? visits.map(\.arrivalDate).min()
        let lastVisit = confirmed.map(\.arrivalDate).max() ?? place.lastVisitAt ?? visits.map(\.arrivalDate).max()
        let country = firstNonEmpty(place.countryCode, majority(visits.map(\.countryCode)))
        let locality = firstNonEmpty(place.locality, majority(visits.map(\.locality)))
        let admin = firstNonEmpty(place.administrativeArea, majority(visits.map(\.administrativeArea)))

        return PlacesPlaceSummary(
            id: place.id,
            name: place.name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: place.parsedCategory,
            countryCode: country,
            locality: locality,
            administrativeArea: admin,
            visitCount: visitCount,
            totalStay: totalStay,
            averageStay: averageStay,
            firstVisitAt: firstVisit,
            lastVisitAt: lastVisit,
            latitude: place.latitude,
            longitude: place.longitude,
            footprintRadius: place.footprintRadius,
            occupancy: OccupancyGrid.build(
                visits: confirmed,
                hourHistogram: place.arrivalHourHistogram,
                weekdayHistogram: place.weekdayHistogram,
                calendar: calendar
            ),
            visitIDs: visits.sorted { $0.arrivalDate > $1.arrivalDate }.map(\.id)
        )
    }

    static func groupByGeography(
        _ places: [PlacesPlaceSummary],
        sort: PlacesSort
    ) -> [PlacesCountrySection] {
        let grouped = Dictionary(grouping: places) { GeographyKey(countryCode: $0.countryCode) }
        let sections: [PlacesCountrySection] = grouped.map { key, countryPlaces in
            let cityGroups = Dictionary(grouping: countryPlaces) { GeographyKey(city: $0.locality, fallback: $0.administrativeArea) }
            let cities: [PlacesCitySection] = cityGroups.map { cityKey, cityPlaces in
                PlacesCitySection(
                    id: "\(key.id)|\(cityKey.id)",
                    cityName: cityKey.displayName,
                    places: cityPlaces.sorted { compare($0, $1, sort: sort) }
                )
            }
            .sorted { lhs, rhs in
                if lhs.cityName == GeographyKey.unknownCity { return false }
                if rhs.cityName == GeographyKey.unknownCity { return true }
                return lhs.cityName.localizedStandardCompare(rhs.cityName) == .orderedAscending
            }

            return PlacesCountrySection(
                id: key.id,
                countryCode: key.countryCode,
                countryName: key.displayName,
                flagEmoji: PlacesGeography.flagEmoji(forCountryCode: key.countryCode),
                cities: cities
            )
        }

        return sections.sorted { lhs, rhs in
            if lhs.countryCode == nil { return false }
            if rhs.countryCode == nil { return true }
            return lhs.countryName.localizedStandardCompare(rhs.countryName) == .orderedAscending
        }
    }

    static func suggestedClusters(
        from visits: [PlacesVisitRecord],
        query: String,
        now: Date
    ) -> [PlacesSuggestedCluster] {
        var remaining = visits
        var clusters: [PlacesSuggestedCluster] = []

        while let seed = remaining.first {
            remaining.removeFirst()
            let seedName = normalizedName(seed.name)
            var members = [seed]
            remaining.removeAll { candidate in
                let belongs: Bool
                if seedName != nil {
                    belongs = normalizedName(candidate.name) == seedName
                        && distance(from: seed.coordinate, to: candidate.coordinate) <= namedClusterRadius
                } else {
                    belongs = normalizedName(candidate.name) == nil
                        && unnamedBucket(candidate) == unnamedBucket(seed)
                }
                if belongs {
                    members.append(candidate)
                }
                return belongs
            }

            let name = members.compactMap { normalizedDisplayName($0.name) }.first
                ?? String(localized: "Untitled place")
            let latitude = members.map(\.latitude).reduce(0, +) / Double(members.count)
            let longitude = members.map(\.longitude).reduce(0, +) / Double(members.count)
            let cluster = PlacesSuggestedCluster(
                id: members.map(\.id.uuidString).sorted().joined(separator: "|"),
                name: name,
                visitIDs: members.map(\.id),
                visitCount: members.count,
                totalStay: members.reduce(0) { $0 + $1.stayDuration(now: now) },
                lastVisitAt: members.map(\.arrivalDate).max(),
                latitude: latitude,
                longitude: longitude,
                countryCode: majority(members.map(\.countryCode)),
                locality: majority(members.map(\.locality))
            )
            clusters.append(cluster)
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = needle.isEmpty
            ? clusters
            : clusters.filter { $0.name.localizedCaseInsensitiveContains(needle) }

        return visible.sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func matches(_ place: PlacesPlaceSummary, query: String) -> Bool {
        if place.name.localizedCaseInsensitiveContains(query) { return true }
        if place.category?.title.localizedCaseInsensitiveContains(query) == true { return true }
        if place.locality?.localizedCaseInsensitiveContains(query) == true { return true }
        if place.administrativeArea?.localizedCaseInsensitiveContains(query) == true { return true }
        if place.countryCode?.localizedCaseInsensitiveContains(query) == true { return true }
        let countryName = PlacesGeography.countryName(forCountryCode: place.countryCode)
        return countryName.localizedCaseInsensitiveContains(query)
    }

    private static func compare(_ lhs: PlacesPlaceSummary, _ rhs: PlacesPlaceSummary, sort: PlacesSort) -> Bool {
        switch sort {
        case .mostVisited:
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .mostTime:
            if lhs.totalStay != rhs.totalStay { return lhs.totalStay > rhs.totalStay }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .recent:
            let left = lhs.lastVisitAt ?? .distantPast
            let right = rhs.lastVisitAt ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func majority(_ values: [String?]) -> String? {
        let cleaned = values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !cleaned.isEmpty else { return nil }
        let counts = Dictionary(grouping: cleaned, by: \.self).mapValues(\.count)
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }?.key
    }

    private static func normalizedName(_ name: String) -> String? {
        guard let display = normalizedDisplayName(name) else { return nil }
        return display.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func normalizedDisplayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^-?\d+\.\d+,\s*-?\d+\.\d+$"#, options: .regularExpression) != nil {
            return nil
        }
        return trimmed
    }

    private static func unnamedBucket(_ visit: PlacesVisitRecord) -> String {
        let latitudeBucket = Int((visit.latitude * unnamedBucketDegrees).rounded())
        let longitudeBucket = Int((visit.longitude * unnamedBucketDegrees).rounded())
        return "\(latitudeBucket)|\(longitudeBucket)"
    }

    private static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}

/// Country / city keys used while grouping.
struct GeographyKey: Hashable {
    static let unknownCountry = String(localized: "Unknown country")
    static let unknownCity = String(localized: "Unknown city")

    var countryCode: String?
    var cityName: String?
    var id: String
    var displayName: String

    init(countryCode: String?) {
        let trimmed = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let resolved = (trimmed?.isEmpty == false) ? trimmed : nil
        self.countryCode = resolved
        self.cityName = nil
        self.id = resolved ?? "country:unknown"
        self.displayName = PlacesGeography.countryName(forCountryCode: resolved)
    }

    init(city: String?, fallback: String?) {
        let trimmedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmedCity?.isEmpty == false) ? trimmedCity : ((trimmedFallback?.isEmpty == false) ? trimmedFallback : nil)
        self.countryCode = nil
        self.cityName = resolved
        self.id = resolved?.lowercased() ?? "city:unknown"
        self.displayName = resolved ?? GeographyKey.unknownCity
    }
}

enum PlacesGeography {
    /// Regional-indicator flag from an ISO 3166‑1 alpha‑2 code.
    static func flagEmoji(forCountryCode code: String?) -> String {
        guard let code, code.count == 2 else { return "" }
        let upper = code.uppercased()
        var emoji = ""
        for scalar in upper.unicodeScalars {
            guard let flagScalar = UnicodeScalar(127397 + scalar.value) else { return "" }
            emoji.unicodeScalars.append(flagScalar)
        }
        return emoji
    }

    static func countryName(forCountryCode code: String?) -> String {
        guard let code, !code.isEmpty else { return GeographyKey.unknownCountry }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

/// Builds grouped Places data off the main actor from live SwiftData rows.
@MainActor
@Observable
final class PlacesIndex {
    var sort: PlacesSort = .mostVisited
    var query: String = ""
    private(set) var snapshot: PlacesIndexSnapshot = .empty

    @ObservationIgnored
    private var generation = 0

    /// Copies SwiftData rows into sendable records, then groups off-main.
    func ingest(
        knownPlaces: [KnownPlace],
        visits: [VisitPlace],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let knownRecords = knownPlaces.map(PlacesKnownRecord.init)
        let visitRecords = visits.map(PlacesVisitRecord.init)
        rebuild(knownRecords: knownRecords, visitRecords: visitRecords, now: now, calendar: calendar)
    }

    func rebuild(
        knownRecords: [PlacesKnownRecord],
        visitRecords: [PlacesVisitRecord],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        generation += 1
        let generation = generation
        let sort = sort
        let query = query
        Task.detached(priority: .userInitiated) {
            let snapshot = PlacesIndexBuilder.build(
                knownPlaces: knownRecords,
                visits: visitRecords,
                sort: sort,
                query: query,
                now: now,
                calendar: calendar
            )
            await MainActor.run {
                guard generation == self.generation else { return }
                self.snapshot = snapshot
            }
        }
    }
}

/// Place mutations for the Places tab. Learning (footprints, occupancy,
/// merge, shrink) is `PlaceLearningEngine`; Confirm uses `createKnownPlace`.
enum PlacesLibrary {
    /// Creates a `KnownPlace` from the cluster’s first visit and assigns the rest.
    /// `createKnownPlace` / `.user` assign already call `PlaceLearningEngine.learn`.
    @discardableResult
    static func confirmSuggested(
        visitIDs: [UUID],
        name: String,
        in context: ModelContext
    ) throws -> KnownPlace {
        let visits = try fetchVisits(ids: visitIDs, in: context)
        guard let first = visits.first else {
            throw PlacesLibraryError.missingVisit
        }
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let place = try repository.createKnownPlace(from: first, name: name)
        for visit in visits.dropFirst() {
            try repository.assign(visit, to: place, source: .user, confidence: 1)
        }
        return place
    }

    static func rename(_ place: KnownPlace, to name: String, in context: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try performingUndoableChange(named: String(localized: "Renamed"), in: context) {
            place.name = trimmed
            for visit in place.visits where visit.assignmentSource == .user {
                visit.userLabel = trimmed
            }
        }
    }

    static func setCategory(_ place: KnownPlace, to category: KnownPlaceCategory?, in context: ModelContext) throws {
        try performingUndoableChange(named: String(localized: "Set category"), in: context) {
            place.category = category?.rawValue
        }
    }

    static func shrinkFootprint(_ place: KnownPlace, in context: ModelContext) throws {
        try performingUndoableChange(named: String(localized: "Shrunk footprint"), in: context) {
            place.footprintRadius = PlaceLearningEngine.clampRadius(
                place.footprintRadius * PlaceLearningEngine.radiusShrinkFactor
            )
        }
    }

    static func merge(_ source: KnownPlace, into target: KnownPlace, in context: ModelContext) throws {
        guard source.id != target.id else { return }
        try performingUndoableChange(named: String(localized: "Merged places"), in: context) {
            PlaceLearningEngine.merge(source, into: target)
            context.delete(source)
        }
    }

    /// Unassigns visits and deletes the learned place. Visits stay on the timeline.
    static func deletePlace(_ place: KnownPlace, in context: ModelContext) throws {
        try performingUndoableChange(named: String(localized: "Deleted place"), in: context) {
            for visit in place.visits {
                visit.knownPlace = nil
                visit.assignmentSource = .none
                visit.assignmentConfidence = 0
            }
            context.delete(place)
        }
    }

    private static func fetchVisits(ids: [UUID], in context: ModelContext) throws -> [VisitPlace] {
        let wanted = Set(ids)
        let all = try context.fetch(FetchDescriptor<VisitPlace>())
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return ids.compactMap { id in
            guard wanted.contains(id) else { return nil }
            return byID[id]
        }
    }

    private static func performingUndoableChange(named name: String, in context: ModelContext, _ body: () throws -> Void) throws {
        let undoManager = context.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(name)
        defer { undoManager?.endUndoGrouping() }
        try body()
        if context.hasChanges {
            try context.save()
        }
    }
}

enum PlacesLibraryError: Error {
    case missingVisit
}
