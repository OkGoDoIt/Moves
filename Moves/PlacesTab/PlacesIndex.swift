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
            // Hours and weekdays on the clock where each visit happened: a home in San
            // Francisco charts its evenings, whatever zone the phone is in now.
            var calendars: [TimeZone: Calendar] = [:]
            for visit in confirmed {
                let zone = visit.timeZone ?? calendar.timeZone
                let local = calendars[zone] ?? PlaceClock.calendar(calendar, in: zone)
                calendars[zone] = local
                let weekday = local.component(.weekday, from: visit.arrivalDate) - 1
                let hour = local.component(.hour, from: visit.arrivalDate)
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
    var userLabel: String?
    var autoLabel: String?
    var thoroughfare: String?
    var formattedAddress: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// `name` as an optional, for helpers that read optional labels.
    var optionalName: String? { name }

    /// The clock where this visit happened; nil for a coordinate that is not a real position.
    var timeZone: TimeZone? { PlaceTimeZone.timeZone(at: coordinate) }

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
        assignmentSource: PlaceAssignmentSource = .none,
        userLabel: String? = nil,
        autoLabel: String? = nil,
        thoroughfare: String? = nil,
        formattedAddress: String? = nil
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
        self.userLabel = userLabel
        self.autoLabel = autoLabel
        self.thoroughfare = thoroughfare
        self.formattedAddress = formattedAddress
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
        userLabel = visit.userLabel
        autoLabel = visit.autoLabel
        thoroughfare = visit.thoroughfare
        formattedAddress = visit.formattedAddress
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
    var thoroughfare: String?
    var formattedAddress: String?

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
        stayDurationSamples: [Double] = [],
        thoroughfare: String? = nil,
        formattedAddress: String? = nil
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
        self.thoroughfare = thoroughfare
        self.formattedAddress = formattedAddress
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
        thoroughfare = place.thoroughfare
        formattedAddress = place.formattedAddress
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
    /// List title: POI, street, "Naming…", or a compact coordinate — never "Untitled place".
    var name: String
    /// Street or formatted address when it differs from `name`.
    var address: String?
    var isNaming: Bool
    /// Mini map in the list when several suggestions share the same title.
    var showsMapThumbnail: Bool
    var visitIDs: [UUID]
    var visitCount: Int
    var totalStay: TimeInterval
    var lastVisitAt: Date?
    var latitude: Double
    var longitude: Double
    /// Footprint the place would learn from these visits, same rule as `PlaceLearningEngine`.
    var spreadRadius: CLLocationDistance = PlaceLearningEngine.minimumFootprintRadius
    var countryCode: String?
    var locality: String?
    var thoroughfare: String?
    var formattedAddress: String?
    var subtitle: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String { name }
}

extension PlacesSuggestedCluster: Hashable {}

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
    /// Visits named only by a street address join the longest nearby stay within this distance.
    ///
    /// Reverse geocoding a hotel or apartment returns a different house number for each
    /// GPS fix, so the address cannot hold these visits together; distance does.
    static let unnamedClusterRadius: CLLocationDistance = 100
    /// "1.2 km away" helps tell neighbors apart; a distance from another city does not.
    static let nearbyDistanceLimit: CLLocationDistance = 50_000

    static func build(
        knownPlaces: [PlacesKnownRecord],
        visits: [PlacesVisitRecord],
        sort: PlacesSort,
        query: String,
        now: Date,
        calendar: Calendar,
        userCoordinate: CLLocationCoordinate2D? = nil
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
            now: now,
            userCoordinate: userCoordinate
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
        now: Date,
        userCoordinate: CLLocationCoordinate2D? = nil
    ) -> [PlacesSuggestedCluster] {
        let streets = streetNames(in: visits)
        var named: [(key: String, visit: PlacesVisitRecord)] = []
        var unnamed: [PlacesVisitRecord] = []
        for visit in visits {
            if let key = clusteringKey(visit, streets: streets) {
                named.append((key, visit))
            } else {
                unnamed.append(visit)
            }
        }

        var clusters: [PlacesSuggestedCluster] = []

        // Named visits: same name within `namedClusterRadius` of the first one seen.
        var remainingNamed = named
        while let seed = remainingNamed.first {
            remainingNamed.removeFirst()
            var members = [seed.visit]
            remainingNamed.removeAll { candidate in
                let belongs = candidate.key == seed.key
                    && distance(from: seed.visit.coordinate, to: candidate.visit.coordinate) <= namedClusterRadius
                if belongs { members.append(candidate.visit) }
                return belongs
            }
            clusters.append(makeCluster(from: members, now: now))
        }

        // Street-addressed visits: the longest stay seeds a cluster and gathers
        // everything within `unnamedClusterRadius`, so an overnight stay anchors it.
        var remainingUnnamed = unnamed.sorted { lhs, rhs in
            let left = lhs.stayDuration(now: now)
            let right = rhs.stayDuration(now: now)
            if left != right { return left > right }
            return lhs.arrivalDate > rhs.arrivalDate
        }
        while let seed = remainingUnnamed.first {
            remainingUnnamed.removeFirst()
            var members = [seed]
            remainingUnnamed.removeAll { candidate in
                let belongs = distance(from: seed.coordinate, to: candidate.coordinate) <= unnamedClusterRadius
                if belongs { members.append(candidate) }
                return belongs
            }
            clusters.append(makeCluster(from: members, now: now))
        }

        let disambiguated = disambiguate(clusters, userCoordinate: userCoordinate, now: now)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = needle.isEmpty
            ? disambiguated
            : disambiguated.filter { cluster in
                cluster.name.localizedCaseInsensitiveContains(needle)
                    || (cluster.address?.localizedCaseInsensitiveContains(needle) == true)
                    || (cluster.locality?.localizedCaseInsensitiveContains(needle) == true)
            }

        // Where the person spent the most time is the most worth naming.
        return visible.sorted {
            if $0.totalStay != $1.totalStay { return $0.totalStay > $1.totalStay }
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeCluster(from members: [PlacesVisitRecord], now: Date) -> PlacesSuggestedCluster {
        let latitude = members.map(\.latitude).reduce(0, +) / Double(members.count)
        let longitude = members.map(\.longitude).reduce(0, +) / Double(members.count)
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let pending = members.allSatisfy {
            PlaceDisplayNamer.meaningful($0.userLabel) == nil
                && PlaceDisplayNamer.meaningful($0.autoLabel) == nil
                && PlaceDisplayNamer.meaningful($0.thoroughfare) == nil
                && PlaceDisplayNamer.meaningful($0.name) == nil
        }
        let resolved = PlaceDisplayNamer.resolve(
            userLabel: dominantMeaningful(members, \.userLabel, now: now),
            autoLabel: dominantMeaningful(members, \.autoLabel, now: now),
            thoroughfare: dominantMeaningful(members, \.thoroughfare, now: now),
            formattedAddress: dominantMeaningful(members, \.formattedAddress, now: now),
            locality: firstMeaningful(members.map(\.locality)) ?? majority(members.map(\.locality)),
            coordinate: coordinate,
            isPending: pending,
            fallbackName: dominantMeaningful(members, \.optionalName, now: now)
        )
        let address = consistentAddress(
            title: resolved.primary,
            address: resolved.address,
            locality: majority(members.map(\.locality))
        )
        let lastVisitAt = members.map(\.arrivalDate).max()
        let visitCount = members.count
        let spread = members
            .map { distance(from: coordinate, to: $0.coordinate) }
            .sorted()
        let spreadIndex = min(spread.count - 1, Int((Double(spread.count - 1) * 0.9).rounded()))
        let spreadRadius = PlaceLearningEngine.clampRadius(
            (spread.isEmpty ? 0 : spread[spreadIndex]) * PlaceLearningEngine.radiusGrowthFactor
        )
        return PlacesSuggestedCluster(
            id: members.map(\.id.uuidString).sorted().joined(separator: "|"),
            name: resolved.primary,
            address: address,
            isNaming: resolved.isPending,
            showsMapThumbnail: false,
            visitIDs: members.map(\.id),
            visitCount: visitCount,
            totalStay: members.reduce(0) { $0 + $1.stayDuration(now: now) },
            lastVisitAt: lastVisitAt,
            latitude: latitude,
            longitude: longitude,
            spreadRadius: spreadRadius,
            countryCode: majority(members.map(\.countryCode)),
            locality: majority(members.map(\.locality)),
            thoroughfare: dominantMeaningful(members, \.thoroughfare, now: now),
            formattedAddress: dominantMeaningful(members, \.formattedAddress, now: now),
            subtitle: defaultSubtitle(
                address: resolved.isPending ? String(localized: "Naming…") : address,
                visitCount: visitCount,
                lastVisitAt: lastVisitAt,
                now: now,
                placeCoordinate: coordinate
            )
        )
    }

    /// Same-street clusters keep visit time, distance, and a map thumbnail so Confirm isn't random.
    private static func disambiguate(
        _ clusters: [PlacesSuggestedCluster],
        userCoordinate: CLLocationCoordinate2D?,
        now: Date
    ) -> [PlacesSuggestedCluster] {
        let groups = Dictionary(grouping: clusters) { PlaceDisplayNamer.folded($0.name) }
        return clusters.map { cluster in
            let peers = groups[PlaceDisplayNamer.folded(cluster.name)] ?? [cluster]
            guard peers.count > 1 else { return cluster }
            var copy = cluster
            copy.showsMapThumbnail = true
            // "Hobbemakade" twice reads as a duplicate; "Hobbemakade 40" and "Hobbemakade 120" do not.
            var address = cluster.address
            if let specific = specificTitle(from: cluster.address, sharing: cluster.name) {
                copy.name = specific
                address = remainder(of: cluster.address, after: specific)
            }
            copy.address = address
            copy.subtitle = defaultSubtitle(
                address: address,
                visitCount: cluster.visitCount,
                lastVisitAt: cluster.lastVisitAt,
                now: now,
                placeCoordinate: cluster.coordinate,
                distanceMeters: userCoordinate
                    .map { distance(from: cluster.coordinate, to: $0) }
                    .flatMap { $0 <= nearbyDistanceLimit ? $0 : nil }
            )
            return copy
        }
    }

    /// A house-number title ("41 Hai Ba Trung") under a different house number from
    /// another geocode reads as two places; show only the area then.
    static func consistentAddress(title: String, address: String?, locality: String?) -> String? {
        guard streetPart(of: title) != nil else { return address }
        let first = address?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first, PlaceDisplayNamer.folded(first) == PlaceDisplayNamer.folded(title) {
            let rest = address?.split(separator: ",").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: ", ")
            return rest?.isEmpty == false ? rest : PlaceDisplayNamer.meaningful(locality)
        }
        return PlaceDisplayNamer.meaningful(locality)
    }

    /// First address component when it names the same street more precisely ("Hobbemakade 40").
    private static func specificTitle(from address: String?, sharing name: String) -> String? {
        guard let first = address?.split(separator: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty,
            PlaceDisplayNamer.folded(first) != PlaceDisplayNamer.folded(name),
            PlaceDisplayNamer.folded(first).contains(PlaceDisplayNamer.folded(name))
        else { return nil }
        return first
    }

    private static func remainder(of address: String?, after title: String) -> String? {
        guard let address else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.first == title else { return address }
        let rest = parts.dropFirst().joined(separator: ", ")
        return rest.isEmpty ? nil : rest
    }

    /// Visit count first so it is never the part a narrow row cuts off.
    static func defaultSubtitle(
        address: String?,
        visitCount: Int,
        lastVisitAt: Date?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        placeCoordinate: CLLocationCoordinate2D? = nil,
        distanceMeters: CLLocationDistance? = nil
    ) -> String {
        var parts: [String] = [
            visitCount == 1 ? String(localized: "1 visit") : String(localized: "\(visitCount) visits")
        ]
        if let lastVisitAt {
            // The date of the last visit where it happened, not on the phone's clock.
            let zone = placeCoordinate.flatMap(PlaceTimeZone.timeZone(at:)) ?? calendar.timeZone
            parts.append(shortDay(PlaceClock.calendarDate(of: lastVisitAt, in: zone, on: calendar), now: now, calendar: calendar))
        }
        if let distanceMeters {
            parts.append(String(localized: "\(MovesStatisticsFormatting.distance(distanceMeters)) away"))
        }
        if let address, !address.isEmpty {
            parts.append(address)
        }
        return parts.joined(separator: " · ")
    }

    /// "Today", "Yesterday", "Nov 24", or "Nov 24, 2025" outside the current year.
    static func shortDay(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// A name that holds visits together, or nil when the visit is known only by its street.
    /// Bare street names ("To Ngoc Van" beside "92 To Ngoc Van") count as streets.
    private static func clusteringKey(_ visit: PlacesVisitRecord, streets: Set<String>) -> String? {
        let key = PlaceDisplayNamer.clusteringName(
            userLabel: visit.userLabel,
            autoLabel: visit.autoLabel,
            thoroughfare: visit.thoroughfare,
            fallbackName: visit.name
        )
        guard let key else { return nil }
        if PlaceDisplayNamer.meaningful(visit.userLabel) != nil { return key }
        // "8 Nguyen Bieu" is an address even with a one-digit house number.
        if let label = PlaceDisplayNamer.meaningful(visit.autoLabel) ?? PlaceDisplayNamer.meaningful(visit.name),
           streetPart(of: label) != nil {
            return nil
        }
        return streets.contains(key) ? nil : key
    }

    /// Folded street names seen in house-number labels ("92 To Ngoc Van", "Hobbemakade 120").
    static func streetNames(in visits: [PlacesVisitRecord]) -> Set<String> {
        var streets = Set<String>()
        for visit in visits {
            for label in [visit.autoLabel, visit.thoroughfare] {
                guard let label = PlaceDisplayNamer.meaningful(label),
                      let street = streetPart(of: label) else { continue }
                streets.insert(PlaceDisplayNamer.folded(street))
            }
        }
        return streets
    }

    /// The street in "<number> <street>" or "<street> <number>", nil for anything else.
    static func streetPart(of label: String) -> String? {
        let tokens = label.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }
        let isNumber: (Substring) -> Bool = { token in
            token.first?.isNumber == true
        }
        if let first = tokens.first, isNumber(first) {
            return tokens.dropFirst().joined(separator: " ")
        }
        if let last = tokens.last, isNumber(last) {
            return tokens.dropLast().joined(separator: " ")
        }
        return nil
    }

    /// The label the person spent the most time under, so one stray fix cannot rename a place.
    private static func dominantMeaningful(
        _ members: [PlacesVisitRecord],
        _ field: KeyPath<PlacesVisitRecord, String?>,
        now: Date
    ) -> String? {
        var totals: [String: (label: String, stay: TimeInterval, latest: Date)] = [:]
        for member in members {
            guard let label = PlaceDisplayNamer.meaningful(member[keyPath: field]) else { continue }
            let key = PlaceDisplayNamer.folded(label)
            let stay = member.stayDuration(now: now)
            if var entry = totals[key] {
                entry.stay += stay
                if member.arrivalDate > entry.latest {
                    entry.latest = member.arrivalDate
                    entry.label = label
                }
                totals[key] = entry
            } else {
                totals[key] = (label, stay, member.arrivalDate)
            }
        }
        return totals.values.max { lhs, rhs in
            if lhs.stay != rhs.stay { return lhs.stay < rhs.stay }
            if lhs.latest != rhs.latest { return lhs.latest < rhs.latest }
            return lhs.label > rhs.label
        }?.label
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

    private static func firstMeaningful(_ values: [String?]) -> String? {
        values.compactMap { PlaceDisplayNamer.meaningful($0) }.first
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
    /// False until the first build finishes, so the empty state never flashes while loading.
    private(set) var hasLoaded = false

    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    private var ingested: (known: [PlacesKnownRecord], visits: [PlacesVisitRecord], userCoordinate: CLLocationCoordinate2D?)?

    /// Copies SwiftData rows into sendable records, then groups off-main.
    func ingest(
        knownPlaces: [KnownPlace],
        visits: [VisitPlace],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        userCoordinate: CLLocationCoordinate2D? = nil
    ) {
        let knownRecords = knownPlaces.map(PlacesKnownRecord.init)
        let visitRecords = visits.map(PlacesVisitRecord.init)
        ingested = (knownRecords, visitRecords, userCoordinate)
        rebuild(
            knownRecords: knownRecords,
            visitRecords: visitRecords,
            now: now,
            calendar: calendar,
            userCoordinate: userCoordinate
        )
    }

    /// Re-applies `query` and `sort` to the last ingested rows, so typing never copies SwiftData again.
    func refilter() {
        guard let ingested else { return }
        rebuild(
            knownRecords: ingested.known,
            visitRecords: ingested.visits,
            userCoordinate: ingested.userCoordinate
        )
    }

    func rebuild(
        knownRecords: [PlacesKnownRecord],
        visitRecords: [PlacesVisitRecord],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        userCoordinate: CLLocationCoordinate2D? = nil
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
                calendar: calendar,
                userCoordinate: userCoordinate
            )
            await MainActor.run {
                guard generation == self.generation else { return }
                self.snapshot = snapshot
                self.hasLoaded = true
            }
        }
    }
}

/// Place mutations for the Places tab. Learning (footprints, occupancy,
/// merge, shrink) is `PlaceLearningEngine`; Confirm uses `createKnownPlace`.
/// Each edit returns its `AppUndoStep`, which the Undo pill runs.
@MainActor
enum PlacesLibrary {
    /// Creates or assigns a `KnownPlace` from the cluster’s visits.
    /// `createKnownPlace` / `.user` assign already call `PlaceLearningEngine.learn`.
    @discardableResult
    static func confirmSuggested(
        visitIDs: [UUID],
        name: String,
        in context: ModelContext,
        formattedAddress: String? = nil,
        thoroughfare: String? = nil,
        category: String? = nil,
        existingPlaceID: UUID? = nil,
        center: CLLocationCoordinate2D? = nil,
        undoStep: ((AppUndoStep) -> Void)? = nil
    ) throws -> KnownPlace {
        var created: KnownPlace?
        // Every visit's assignment and the new place are one step on the Undo pill.
        let visitsBefore = VisitAssignmentSnapshot(try fetchVisits(ids: visitIDs, in: context))
        let existingBefore = try existingPlaceID.flatMap { id in
            try context.fetch(FetchDescriptor<KnownPlace>(predicate: #Predicate { $0.id == id })).first
        }.map(KnownPlaceUndoPayload.init)
        let placeIDsBefore = Set(try context.fetch(FetchDescriptor<KnownPlace>()).map(\.id))
        var createdID: UUID?
        let step = try performingRestorableDelete(
            named: String(localized: "Confirmed"),
            in: context,
            restore: { context in
                visitsBefore.restore(in: context)
                existingBefore?.overwriteExisting(in: context)
                if let createdID,
                   let place = try? context.fetch(FetchDescriptor<KnownPlace>(predicate: #Predicate { $0.id == createdID })).first {
                    context.delete(place)
                }
            }
        ) {
            created = try confirmSuggestedWithoutUndoStep(
                visitIDs: visitIDs,
                name: name,
                in: context,
                formattedAddress: formattedAddress,
                thoroughfare: thoroughfare,
                category: category,
                existingPlaceID: existingPlaceID,
                center: center
            )
            if let id = created?.id, !placeIDsBefore.contains(id) { createdID = id }
        }
        guard let created else { throw PlacesLibraryError.missingVisit }
        undoStep?(step)
        return created
    }

    private static func confirmSuggestedWithoutUndoStep(
        visitIDs: [UUID],
        name: String,
        in context: ModelContext,
        formattedAddress: String?,
        thoroughfare: String?,
        category: String?,
        existingPlaceID: UUID?,
        center: CLLocationCoordinate2D?
    ) throws -> KnownPlace {
        let visits = try fetchVisits(ids: visitIDs, in: context)
        guard let first = visits.first else {
            throw PlacesLibraryError.missingVisit
        }
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? first.placesDisplayName : trimmedName

        let place: KnownPlace
        if let existingPlaceID,
           let existing = try context.fetch(FetchDescriptor<KnownPlace>()).first(where: { $0.id == existingPlaceID }) {
            place = existing
            try repository.assign(first, to: place, source: .user, confidence: 1)
        } else {
            place = try repository.createKnownPlace(from: first, name: resolvedName)
        }

        if let center, CLLocationCoordinate2DIsValid(center) {
            place.centerLatitude = center.latitude
            place.centerLongitude = center.longitude
        }
        if let formattedAddress, !formattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            place.formattedAddress = formattedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let thoroughfare, !thoroughfare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            place.thoroughfare = thoroughfare.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let category {
            let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCategory.isEmpty {
                place.category = nil
            } else if let parsed = KnownPlaceCategory(stored: trimmedCategory), parsed != .other {
                place.category = parsed.rawValue
            } else {
                place.category = trimmedCategory
            }
        }

        for visit in visits.dropFirst() {
            try repository.assign(visit, to: place, source: .user, confidence: 1)
        }
        if context.hasChanges {
            try context.save()
        }
        return place
    }

    @discardableResult
    static func rename(_ place: KnownPlace, to name: String, in context: ModelContext) throws -> AppUndoStep? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != place.name else { return nil }
        return try performingUndoableChange(named: String(localized: "Renamed"), place: place, in: context) {
            place.name = trimmed
            for visit in place.visits where visit.assignmentSource == .user {
                visit.userLabel = trimmed
            }
        }
    }

    @discardableResult
    static func setCategory(_ place: KnownPlace, to category: KnownPlaceCategory?, in context: ModelContext) throws -> AppUndoStep {
        try performingUndoableChange(named: String(localized: "Set category"), place: place, in: context) {
            place.category = category?.rawValue
        }
    }

    @discardableResult
    static func shrinkFootprint(_ place: KnownPlace, in context: ModelContext) throws -> AppUndoStep {
        try performingUndoableChange(named: String(localized: "Shrunk footprint"), place: place, in: context) {
            place.footprintRadius = PlaceLearningEngine.clampRadius(
                place.footprintRadius * PlaceLearningEngine.radiusShrinkFactor
            )
        }
    }

    @discardableResult
    static func merge(_ source: KnownPlace, into target: KnownPlace, in context: ModelContext) throws -> AppUndoStep? {
        guard source.id != target.id else { return nil }
        let sourcePayload = KnownPlaceUndoPayload(source)
        let targetPayload = KnownPlaceUndoPayload(target)
        return try performingRestorableDelete(
            named: String(localized: "Merged places"),
            in: context,
            restore: { context in
                sourcePayload.recreate(in: context)
                targetPayload.overwriteExisting(in: context)
            },
            {
                PlaceLearningEngine.merge(source, into: target)
                context.delete(source)
            }
        )
    }

    /// Unassigns visits and deletes the learned place. Visits stay on the timeline.
    @discardableResult
    static func deletePlace(_ place: KnownPlace, in context: ModelContext) throws -> AppUndoStep {
        let payload = KnownPlaceUndoPayload(place)
        return try performingRestorableDelete(
            named: String(localized: "Deleted place"),
            in: context,
            restore: { context in payload.recreate(in: context) },
            {
                for visit in place.visits {
                    visit.knownPlace = nil
                    visit.assignmentSource = .none
                    visit.assignmentConfidence = 0
                }
                context.delete(place)
            }
        )
    }

    private static func fetchVisits(ids: [UUID], in context: ModelContext) throws -> [VisitPlace] {
        let wanted = Set(ids)
        let all = try context.fetch(FetchDescriptor<VisitPlace>.live())
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return ids.compactMap { id in
            guard wanted.contains(id) else { return nil }
            return byID[id]
        }
    }

    /// An edit to one place and its visits' names, put back from a copy taken first.
    private static func performingUndoableChange(
        named name: String,
        place: KnownPlace,
        in context: ModelContext,
        _ body: () throws -> Void
    ) throws -> AppUndoStep {
        let payload = KnownPlaceUndoPayload(place)
        // Labelling can also assign the earlier stays at the place, so the stays around it
        // are copied too, not only the ones matched to it now.
        let visits = VisitAssignmentSnapshot(place.visits + nearbyVisits(of: place, in: context))
        return try performingRestorableDelete(
            named: name,
            in: context,
            restore: { context in
                payload.overwriteExisting(in: context)
                visits.restore(in: context)
            },
            body
        )
    }

    /// Stays within a kilometer of the place's center.
    private static func nearbyVisits(of place: KnownPlace, in context: ModelContext) -> [VisitPlace] {
        let latitudeDelta = 1_000.0 / 111_000
        let longitudeDelta = latitudeDelta / max(cos(place.centerLatitude * .pi / 180), 0.01)
        let minLat = place.centerLatitude - latitudeDelta, maxLat = place.centerLatitude + latitudeDelta
        let minLon = place.centerLongitude - longitudeDelta, maxLon = place.centerLongitude + longitudeDelta
        // Retired stays are left out in code. A predicate that compares `dayTimeline` with
        // nil does not compile in this file on an incremental build.
        let inBox = (try? context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate {
            $0.latitude >= minLat && $0.latitude <= maxLat && $0.longitude >= minLon && $0.longitude <= maxLon
        }))) ?? []
        return inBox.filter { !TimelineRetirement.isRetired($0) }
    }

    /// SwiftData auto-undo of a delete can crash, so these changes run with undo registration
    /// off and put back a copy of what they removed, the way `TimelineEditController` does.
    private static func performingRestorableDelete(
        named name: String,
        in context: ModelContext,
        restore: @escaping (ModelContext) -> Void,
        _ body: () throws -> Void
    ) throws -> AppUndoStep {
        let undoManager = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undoManager }
        try body()
        if context.hasChanges {
            try context.save()
        }
        return AppUndoStep.register(named: name, on: undoManager) { [weak context] in
            guard let context else { return }
            let previous = context.undoManager
            context.undoManager = nil
            restore(context)
            if context.hasChanges {
                try? context.save()
            }
            context.undoManager = previous
        }
    }
}

/// Stays' place match, name, and answer as they were, found by id when Undo runs.
struct VisitAssignmentSnapshot {
    private struct Row {
        let knownPlaceID: UUID?
        let assignmentSourceRaw: String
        let assignmentConfidence: Double
        let userLabel: String?
        let reviewStateRaw: String
    }

    private let rows: [UUID: Row]

    init(_ visits: [VisitPlace]) {
        rows = Dictionary(visits.map { visit in
            (visit.id, Row(
                knownPlaceID: visit.knownPlace?.id,
                assignmentSourceRaw: visit.assignmentSourceRaw,
                assignmentConfidence: visit.assignmentConfidence,
                userLabel: visit.userLabel,
                reviewStateRaw: visit.reviewStateRaw
            ))
        }, uniquingKeysWith: { first, _ in first })
    }

    func restore(in context: ModelContext) {
        let ids = Array(rows.keys)
        guard !ids.isEmpty else { return }
        // Retired stays are left out in code, as in `nearbyVisits`.
        let visits = ((try? context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { ids.contains($0.id) }))) ?? [])
            .filter { !TimelineRetirement.isRetired($0) }
        let places = (try? context.fetch(FetchDescriptor<KnownPlace>())) ?? []
        let placesByID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for visit in visits {
            guard let row = rows[visit.id] else { continue }
            visit.knownPlace = row.knownPlaceID.flatMap { placesByID[$0] }
            visit.assignmentSourceRaw = row.assignmentSourceRaw
            visit.assignmentConfidence = row.assignmentConfidence
            visit.userLabel = row.userLabel
            visit.reviewStateRaw = row.reviewStateRaw
        }
    }
}

/// Everything a `KnownPlace` stores, so an undone delete, merge, or confirmation can bring
/// it back as it was.
struct KnownPlaceUndoPayload {
    let id: UUID
    let name: String
    let centerLatitude: Double
    let centerLongitude: Double
    let footprintRadius: Double
    let confirmedVisitCount: Int
    let category: String?
    let countryCode: String?
    let locality: String?
    let administrativeArea: String?
    let thoroughfare: String?
    let formattedAddress: String?
    let rejectedAutoLabels: [String]
    let arrivalHourHistogram: [Int]
    let weekdayHistogram: [Int]
    let stayDurationSamples: [Double]
    let createdAt: Date
    let lastVisitAt: Date?
    let visits: [(id: UUID, source: PlaceAssignmentSource, confidence: Double)]

    init(_ place: KnownPlace) {
        id = place.id
        name = place.name
        centerLatitude = place.centerLatitude
        centerLongitude = place.centerLongitude
        footprintRadius = place.footprintRadius
        confirmedVisitCount = place.confirmedVisitCount
        category = place.category
        countryCode = place.countryCode
        locality = place.locality
        administrativeArea = place.administrativeArea
        thoroughfare = place.thoroughfare
        formattedAddress = place.formattedAddress
        rejectedAutoLabels = place.rejectedAutoLabels
        arrivalHourHistogram = place.arrivalHourHistogram
        weekdayHistogram = place.weekdayHistogram
        stayDurationSamples = place.stayDurationSamples
        createdAt = place.createdAt
        lastVisitAt = place.lastVisitAt
        visits = place.visits.map { ($0.id, $0.assignmentSource, $0.assignmentConfidence) }
    }

    /// Inserts the removed place under its old ID and hands its visits back.
    func recreate(in context: ModelContext) {
        let place = KnownPlace(
            name: name,
            latitude: centerLatitude,
            longitude: centerLongitude,
            footprintRadius: footprintRadius
        )
        place.id = id
        context.insert(place)
        write(to: place)

        let assignments = Dictionary(visits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allVisits = (try? context.fetch(FetchDescriptor<VisitPlace>.live())) ?? []
        for visit in allVisits {
            guard let assignment = assignments[visit.id] else { continue }
            visit.knownPlace = place
            visit.assignmentSource = assignment.source
            visit.assignmentConfidence = assignment.confidence
        }
    }

    /// Rolls a merge target's learned fields back to what they were before the merge.
    func overwriteExisting(in context: ModelContext) {
        let identifier = id
        var descriptor = FetchDescriptor<KnownPlace>(predicate: #Predicate { $0.id == identifier })
        descriptor.fetchLimit = 1
        guard let place = try? context.fetch(descriptor).first else { return }
        place.name = name
        place.centerLatitude = centerLatitude
        place.centerLongitude = centerLongitude
        place.footprintRadius = footprintRadius
        write(to: place)
    }

    private func write(to place: KnownPlace) {
        place.confirmedVisitCount = confirmedVisitCount
        place.category = category
        place.countryCode = countryCode
        place.locality = locality
        place.administrativeArea = administrativeArea
        place.thoroughfare = thoroughfare
        place.formattedAddress = formattedAddress
        place.rejectedAutoLabels = rejectedAutoLabels
        place.arrivalHourHistogram = arrivalHourHistogram
        place.weekdayHistogram = weekdayHistogram
        place.stayDurationSamples = stayDurationSamples
        place.createdAt = createdAt
        place.lastVisitAt = lastVisitAt
    }
}

enum PlacesLibraryError: Error {
    case missingVisit
}
