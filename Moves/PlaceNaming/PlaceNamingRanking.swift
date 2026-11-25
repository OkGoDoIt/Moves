import CoreLocation
import Foundation
import MapKit

/// Pure rules for naming a stay: which nearby names to offer, in what order, and how
/// each is shown. Shared by the default chips, the narrowed chips, and Choose a Place.
enum PlaceNamingRanking {
    /// Kinds of places people name a stay after: food, lodging, shops, transit, parks, gyms.
    static let favoredCategories: Set<MKPointOfInterestCategory> = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .nightlife, .foodMarket,
        .hotel, .campground, .rvPark,
        .store, .pharmacy, .beauty, .spa, .laundry,
        .publicTransport, .airport,
        .park, .nationalPark, .beach, .marina,
        .fitnessCenter, .swimming, .tennis, .golf, .rockClimbing, .bowling, .skating, .stadium,
        .school, .university, .library, .hospital, .museum, .theater, .movieTheater, .musicVenue,
        .conventionCenter, .zoo, .aquarium, .amusementPark,
    ]

    /// Kinds of places a stay is almost never named after, even when they are the closest pin.
    static let rarelyNamedCategories: Set<MKPointOfInterestCategory> = [
        .atm, .parking, .evCharger, .restroom, .mailbox, .fireStation,
    ]

    /// How far a stay's true spot may be from its recorded centre: its accuracy, held to a
    /// sane band, plus a little for the size of a storefront.
    static func stayReach(accuracy: CLLocationDistance) -> CLLocationDistance {
        min(max(accuracy, 20), 150) + 15
    }

    /// Lower is better. Zero for a favored place whose footprint plausibly holds the stay;
    /// every 40 m beyond that reach costs one point, a neutral kind one, a rare kind four.
    static func score(_ candidate: NearbyPlaceCandidate, accuracy: CLLocationDistance) -> Double {
        let reach = stayReach(accuracy: accuracy)
        let proximity = candidate.distanceMeters <= reach ? 0 : (candidate.distanceMeters - reach) / 40
        return proximity + categoryPenalty(candidate.category)
    }

    static func categoryPenalty(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 1.5 }
        let category = MKPointOfInterestCategory(rawValue: raw)
        if favoredCategories.contains(category) { return 0 }
        if rarelyNamedCategories.contains(category) { return 4 }
        return 1
    }

    // MARK: Matching

    /// Case- and diacritic-folded, trimmed text for comparing a query with a name.
    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    /// Letters and digits only, folded: "Starbucks Coffee", "STARBUCKS  coffee!" match.
    static func comparisonKey(_ name: String) -> String {
        String(folded(name).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The name contains the query anywhere, ignoring case and accents. An empty query matches.
    static func matches(_ name: String, query: String?) -> Bool {
        let needle = folded(query ?? "")
        guard !needle.isEmpty else { return true }
        return folded(name).contains(needle)
    }

    /// A word of the name begins with the query ("Sta" → "Blue Star Café").
    static func isWordPrefixMatch(_ name: String, query: String) -> Bool {
        let needle = folded(query)
        guard !needle.isEmpty else { return false }
        let haystack = folded(name)
        if haystack.hasPrefix(needle) { return true }
        return haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(needle) }
    }

    // MARK: Candidates

    struct RankedKnown {
        var candidate: NearbyPlaceCandidate
        var footprint: Double?
        var distanceMeters: CLLocationDistance { candidate.distanceMeters }
    }

    static func distance(from origin: CLLocationCoordinate2D, latitude: Double, longitude: Double) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    /// Learned places within `radius` whose name matches `query`.
    static func knownCandidates(
        _ known: [NearbyKnownPlace],
        origin: CLLocationCoordinate2D,
        within radius: CLLocationDistance,
        query: String?
    ) -> [RankedKnown] {
        known.compactMap { place in
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, matches(name, query: query) else { return nil }
            let meters = distance(from: origin, latitude: place.latitude, longitude: place.longitude)
            guard meters <= radius else { return nil }
            return RankedKnown(
                candidate: NearbyPlaceCandidate(
                    id: "known-\(place.id.uuidString)",
                    name: name,
                    subtitle: place.locality,
                    distanceMeters: meters,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    source: .knownPlace(id: place.id),
                    confirmedVisitCount: place.confirmedVisitCount,
                    category: place.category
                ),
                footprint: place.footprintRadius
            )
        }
    }

    /// Two hits are the same place when their names fold to the same key this close together.
    static let duplicateDistance: CLLocationDistance = 100

    /// Apple hits within `radius` (nil: any distance) whose name matches `query` when
    /// `filtersByName`, minus names the person rejected nearby, names already offered as
    /// learned places, and near-duplicates (the nearer one stays).
    static func searchCandidates(
        _ hits: [NearbySearchHit],
        origin: CLLocationCoordinate2D,
        within radius: CLLocationDistance?,
        query: String?,
        filtersByName: Bool = true,
        known: [NearbyKnownPlace],
        excludingNames: [String]
    ) -> [NearbyPlaceCandidate] {
        let rejected = Set(known.flatMap(\.rejectedAutoLabels).map(comparisonKey).filter { !$0.isEmpty })
        let taken = Set(excludingNames.map(comparisonKey))

        let candidates: [NearbyPlaceCandidate] = hits.compactMap { hit in
            let name = hit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if filtersByName, !matches(name, query: query) { return nil }
            let key = comparisonKey(name)
            guard !key.isEmpty, !taken.contains(key), !rejected.contains(key) else { return nil }
            let meters = distance(from: origin, latitude: hit.latitude, longitude: hit.longitude)
            if let radius, meters > radius { return nil }
            return NearbyPlaceCandidate(
                id: "search-\(String(format: "%.5f", hit.latitude))-\(String(format: "%.5f", hit.longitude))-\(key)",
                name: name,
                subtitle: PlaceDisplayNamer.meaningful(hit.subtitle),
                distanceMeters: meters,
                latitude: hit.latitude,
                longitude: hit.longitude,
                source: .search,
                confirmedVisitCount: 0,
                category: hit.category
            )
        }
        return deduplicated(candidates)
    }

    /// Keeps the nearest of each near-identical name at one spot, in nearest-first order.
    static func deduplicated(_ candidates: [NearbyPlaceCandidate]) -> [NearbyPlaceCandidate] {
        var kept: [NearbyPlaceCandidate] = []
        var seenIDs = Set<String>()
        for candidate in candidates.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
            guard seenIDs.insert(candidate.id).inserted else { continue }
            let key = comparisonKey(candidate.name)
            let duplicate = kept.contains { other in
                comparisonKey(other.name) == key
                    && distance(
                        from: CLLocationCoordinate2D(latitude: other.latitude, longitude: other.longitude),
                        latitude: candidate.latitude,
                        longitude: candidate.longitude
                    ) <= duplicateDistance
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }

    // MARK: Display

    /// The glyph for a place's kind. Learned places use their own category's symbol.
    static func symbolName(for candidate: NearbyPlaceCandidate) -> String {
        if case .knownPlace = candidate.source {
            return KnownPlaceCategory(stored: candidate.category)?.symbolName ?? "mappin.and.ellipse"
        }
        return symbolName(forCategory: candidate.category)
    }

    static func symbolName(forCategory raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "mappin" }
        switch MKPointOfInterestCategory(rawValue: raw) {
        case .restaurant: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        case .bakery: return "birthday.cake.fill"
        case .brewery: return "mug.fill"
        case .winery, .distillery, .nightlife: return "wineglass.fill"
        case .foodMarket: return "cart.fill"
        case .hotel: return "bed.double.fill"
        case .campground, .rvPark: return "tent.fill"
        case .store: return "bag.fill"
        case .pharmacy: return "pills.fill"
        case .hospital: return "cross.case.fill"
        case .beauty, .spa: return "sparkles"
        case .laundry: return "washer.fill"
        case .publicTransport: return "tram.fill"
        case .airport: return "airplane"
        case .park, .nationalPark: return "tree.fill"
        case .beach: return "beach.umbrella.fill"
        case .marina, .kayaking, .surfing: return "sailboat.fill"
        case .fitnessCenter: return "figure.strengthtraining.traditional"
        case .swimming: return "figure.pool.swim"
        case .tennis, .basketball, .baseball, .soccer, .volleyball, .golf, .stadium: return "sportscourt.fill"
        case .school, .university: return "graduationcap.fill"
        case .library: return "books.vertical.fill"
        case .museum, .nationalMonument, .landmark, .castle, .fortress: return "building.columns.fill"
        case .theater: return "theatermasks.fill"
        case .movieTheater: return "film.fill"
        case .musicVenue: return "music.note"
        case .bank, .atm: return "banknote.fill"
        case .gasStation: return "fuelpump.fill"
        case .evCharger: return "bolt.car.fill"
        case .parking: return "parkingsign"
        case .carRental, .automotiveRepair: return "car.fill"
        case .postOffice, .mailbox: return "envelope.fill"
        case .police, .fireStation: return "shield.fill"
        case .zoo, .animalService: return "pawprint.fill"
        case .aquarium: return "fish.fill"
        case .amusementPark, .fairground: return "ticket.fill"
        case .hiking: return "figure.hiking"
        default: return "mappin"
        }
    }

    /// "120 ft" or "40 m" up close, "0.4 mi" or "1.2 km" farther, in the person's units.
    static func distanceText(_ meters: CLLocationDistance, locale: Locale = .current) -> String {
        let usesMiles = locale.measurementSystem == .us || locale.measurementSystem == .uk
        let measurement: Measurement<UnitLength>
        let fraction: ClosedRange<Int>
        if usesMiles {
            let miles = meters / 1609.344
            if miles < 0.1 {
                let feet = max((meters * 3.28084 / 10).rounded() * 10, 10)
                measurement = Measurement(value: feet, unit: .feet)
                fraction = 0...0
            } else {
                measurement = Measurement(value: miles, unit: .miles)
                fraction = miles < 10 ? 1...1 : 0...0
            }
        } else if meters < 1000 {
            measurement = Measurement(value: max((meters / 10).rounded() * 10, 10), unit: .meters)
            fraction = 0...0
        } else {
            let kilometers = meters / 1000
            measurement = Measurement(value: kilometers, unit: .kilometers)
            fraction = kilometers < 10 ? 1...1 : 0...0
        }
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(fraction))
            )
            .locale(locale)
        )
    }
}

/// What Choose a Place lists for one query: the person's own places, then everything else.
struct PlaceChoiceListing: Equatable {
    var known: [NearbyPlaceCandidate]
    var places: [NearbyPlaceCandidate]

    static let empty = PlaceChoiceListing(known: [], places: [])

    var isEmpty: Bool { known.isEmpty && places.isEmpty }

    /// Nearby places are filtered by name as typed; Apple's results for the typed text are
    /// kept whole (a search for "coffee" finds cafés), then everything is nearest first.
    static func build(
        origin: CLLocationCoordinate2D,
        query: String,
        known: [NearbyKnownPlace],
        nearbyHits: [NearbySearchHit],
        typedHits: [NearbySearchHit]
    ) -> PlaceChoiceListing {
        let knownCandidates = PlaceNamingRanking.knownCandidates(
            known,
            origin: origin,
            within: NearbyPlaceSuggester.listRadius,
            query: query
        )
        .map(\.candidate)
        .sorted { $0.distanceMeters < $1.distanceMeters }

        let taken = knownCandidates.map(\.name)
        let local = PlaceNamingRanking.searchCandidates(
            nearbyHits,
            origin: origin,
            within: nil,
            query: query,
            known: known,
            excludingNames: taken
        )
        let typed = PlaceNamingRanking.searchCandidates(
            typedHits,
            origin: origin,
            within: nil,
            query: query,
            filtersByName: false,
            known: known,
            excludingNames: taken
        )
        return PlaceChoiceListing(
            known: knownCandidates,
            places: PlaceNamingRanking.deduplicated(local + typed)
        )
    }

    /// A short row of chips for the typed text: learned places, then names beginning with
    /// it, then names containing it, then Apple's other matches, each nearest first.
    func narrowedChips(query: String, limit: Int) -> [NearbyPlaceCandidate] {
        func tier(_ candidate: NearbyPlaceCandidate) -> Int {
            if PlaceNamingRanking.isWordPrefixMatch(candidate.name, query: query) { return 0 }
            if PlaceNamingRanking.matches(candidate.name, query: query) { return 1 }
            return 2
        }
        let ranked = places.sorted { lhs, rhs in
            let lhsTier = tier(lhs)
            let rhsTier = tier(rhs)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return lhs.distanceMeters < rhs.distanceMeters
        }
        return Array((known + ranked).prefix(limit))
    }
}
