import CoreLocation
import Foundation
import os

/// Offline list of the world's cities and towns, used to say which city a stay was in.
///
/// Reverse geocoding answers with whatever sits at the bottom of the local address: a ward
/// of Ho Chi Minh City, a district of Bangkok, a suburb of Sydney. Each city here reaches
/// out by the square root of its population, so a stay belongs to the city it is deepest
/// inside, and a town on the edge of a big city keeps its own surroundings.
///
/// `WorldCities.tsv` is built from GeoNames (CC BY 4.0) by `Scripts/build-world-cities.py`.
struct WorldCityIndex: Sendable {
    struct City: Equatable, Sendable {
        let id: String
        let name: String
        let countryCode: String
    }

    struct Match: Sendable {
        let city: City
        /// Distance from the city's center, in multiples of its reach. Inside is 1 or less.
        let reach: Double
        let distanceKm: Double
    }

    static let bundled: WorldCityIndex? = {
        guard let url = Bundle.main.url(forResource: "WorldCities", withExtension: "tsv"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WorldCityIndex(data: data)
    }()

    /// Towns smaller than this reach still cover their own streets.
    private static let minimumReachKm = 2.5
    private static let reachPerRootPerson = 0.0085

    private let bytes: [UInt8]
    private let names: [Range<Int>]
    private let countries: [UInt16]
    private let latitudes: [Double]
    private let longitudes: [Double]
    private let reaches: [Double]
    private let cells: [Int: [Int]]

    init(data: Data) {
        let bytes = [UInt8](data)
        var names: [Range<Int>] = []
        var countries: [UInt16] = []
        var latitudes: [Double] = []
        var longitudes: [Double] = []
        var reaches: [Double] = []
        names.reserveCapacity(61_000)

        bytes.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                var tabs: [Int] = []
                var end = start
                while end < buffer.count, buffer[end] != 10 {
                    if buffer[end] == 9 { tabs.append(end) }
                    end += 1
                }
                defer { start = end + 1 }
                guard tabs.count == 4, tabs[1] - tabs[0] == 3 else { continue }
                names.append(start..<tabs[0])
                countries.append(UInt16(buffer[tabs[0] + 1]) << 8 | UInt16(buffer[tabs[0] + 2]))
                latitudes.append(Double(Self.integer(buffer, tabs[1] + 1, tabs[2])) / 10_000)
                longitudes.append(Double(Self.integer(buffer, tabs[2] + 1, tabs[3])) / 10_000)
                let population = Double(Self.integer(buffer, tabs[3] + 1, end))
                reaches.append(max(Self.minimumReachKm, Self.reachPerRootPerson * population.squareRoot()))
            }
        }

        var cells: [Int: [Int]] = [:]
        for index in names.indices {
            cells[Self.cell(latitudes[index], longitudes[index]), default: []].append(index)
        }
        self.bytes = bytes
        self.names = names
        self.countries = countries
        self.latitudes = latitudes
        self.longitudes = longitudes
        self.reaches = reaches
        self.cells = cells
    }

    var count: Int { names.count }

    /// The city a point is deepest inside, or nearest to when it is inside none.
    func deepest(latitude: Double, longitude: Double, countryCode: String?) -> Match? {
        var best: (index: Int, reach: Double, distance: Double)?
        forEachNear(latitude: latitude, longitude: longitude, countryCode: countryCode) { index, distance in
            let reach = distance / reaches[index]
            if reach < best?.reach ?? .infinity { best = (index, reach, distance) }
        }
        return best.map { Match(city: city($0.index), reach: $0.reach, distanceKm: $0.distance) }
    }

    /// The nearest city called `name` within `kilometers`.
    func named(_ name: String, latitude: Double, longitude: Double, countryCode: String?, within kilometers: Double) -> City? {
        let key = Self.key(name)
        guard let first = key.utf8.first else { return nil }
        var best: (index: Int, distance: Double)?
        forEachNear(latitude: latitude, longitude: longitude, countryCode: countryCode) { index, distance in
            guard distance <= kilometers, distance < best?.distance ?? .infinity else { return }
            // Folding a name is the slow part; most are ruled out by their first letter.
            let initial = bytes[names[index].lowerBound]
            if initial < 0x80, initial | 0x20 != first | 0x20 { return }
            if Self.key(self.name(index)) == key { best = (index, distance) }
        }
        return best.map { city($0.index) }
    }

    /// Letters only, so "Đà Lạt", "Da Lat", and "da-lat" are one city.
    static func key(_ name: String) -> String {
        name.replacingOccurrences(of: "đ", with: "d", options: .caseInsensitive)
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private func forEachNear(
        latitude: Double,
        longitude: Double,
        countryCode: String?,
        _ body: (Int, Double) -> Void
    ) {
        let wanted = countryCode.flatMap(Self.packed)
        for rowOffset in -1...1 {
            for columnOffset in -1...1 {
                let cell = Self.cell(latitude + Double(rowOffset), longitude + Double(columnOffset))
                for index in cells[cell] ?? [] {
                    if let wanted, countries[index] != wanted { continue }
                    let mean = (latitude + latitudes[index]) / 2 * .pi / 180
                    let dx = (longitude - longitudes[index]) * 111.32 * cos(mean)
                    let dy = (latitude - latitudes[index]) * 110.57
                    body(index, (dx * dx + dy * dy).squareRoot())
                }
            }
        }
    }

    private func name(_ index: Int) -> String {
        String(decoding: bytes[names[index]], as: UTF8.self)
    }

    private func city(_ index: Int) -> City {
        let country = String(decoding: [UInt8(countries[index] >> 8), UInt8(countries[index] & 0xFF)], as: UTF8.self)
        return City(id: "\(country)|\(name(index))|\(index)", name: name(index), countryCode: country)
    }

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int {
        let column = (Int(longitude.rounded(.down)) + 180 + 360) % 360
        return Int(latitude.rounded(.down)) * 1_000 + column
    }

    private static func packed(_ code: String) -> UInt16? {
        let letters = Array(code.utf8)
        return letters.count == 2 ? UInt16(letters[0]) << 8 | UInt16(letters[1]) : nil
    }

    private static func integer(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Int {
        var value = 0
        var negative = false
        for position in start..<end {
            switch buffer[position] {
            case 45: negative = true
            case 48...57: value = value * 10 + Int(buffer[position] - 48)
            default: break
            }
        }
        return negative ? -value : value
    }
}

/// Country and city of a stay, worked out offline and remembered for the life of the app.
enum VisitGeography {
    struct Resolved: Equatable, Sendable {
        var countryCode: String?
        var cityID: String?
        var cityName: String?
    }

    private struct Key: Hashable {
        let latitude: Int
        let longitude: Int
        let countryCode: String?
        let locality: String?
        let administrativeArea: String?
    }

    /// How far past a city's edge a stay without a name of its own still counts as there.
    private static let outskirtsKm = 7.0
    /// How far off a simplified coastline a stay may be and still be in that country.
    private static let coastKm = 25.0
    private static let sameNameKm = 30.0

    private static let memo = OSAllocatedUnfairLock(initialState: [Key: Resolved]())

    static func resolve(_ visit: InsightsVisitRecord) -> Resolved {
        guard let latitude = visit.latitude, let longitude = visit.longitude,
              CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else {
            return resolve(visit, latitude: nil, longitude: nil)
        }
        let key = Key(
            latitude: Int((latitude * 1_000).rounded()),
            longitude: Int((longitude * 1_000).rounded()),
            countryCode: visit.countryCode,
            locality: visit.locality,
            administrativeArea: visit.administrativeArea
        )
        if let known = memo.withLock({ $0[key] }) { return known }
        // Worked out for the key's own point, so the answer never depends on which stay came first.
        let resolved = resolve(visit, latitude: Double(key.latitude) / 1_000, longitude: Double(key.longitude) / 1_000)
        memo.withLock { $0[key] = resolved }
        return resolved
    }

    private static func resolve(_ visit: InsightsVisitRecord, latitude: Double?, longitude: Double?) -> Resolved {
        // A stored country wins; the bundled borders fill in what geocoding has not reached,
        // and only from stays, never from a line flown over a country.
        var country = isoCode(visit.countryCode)
            ?? isoCode(OfflineVisitGeography.country(latitude: latitude, longitude: longitude))
        let names = cityNames(from: visit.locality)

        guard let latitude, let longitude, let index = WorldCityIndex.bundled else {
            return named(names.first, country: country)
        }
        let deepest = index.deepest(latitude: latitude, longitude: longitude, countryCode: country)
        // A beach or a ferry can fall just outside the simplified coastline.
        if country == nil, let deepest, deepest.distanceKm <= coastKm { country = deepest.city.countryCode }
        guard country != nil else { return Resolved() }

        for name in names {
            if let city = index.named(name, latitude: latitude, longitude: longitude, countryCode: country, within: sameNameKm) {
                return Resolved(countryCode: country, cityID: city.id, cityName: city.name)
            }
        }
        if let deepest, deepest.reach <= 1 {
            return Resolved(countryCode: country, cityID: deepest.city.id, cityName: deepest.city.name)
        }
        // A named village too small for the list. A province repeated as the city is not one.
        if let name = names.first, WorldCityIndex.key(name) != WorldCityIndex.key(visit.administrativeArea ?? "") {
            return named(name, country: country)
        }
        if let deepest, deepest.distanceKm - deepest.distanceKm / deepest.reach <= outskirtsKm {
            return Resolved(countryCode: country, cityID: deepest.city.id, cityName: deepest.city.name)
        }
        return Resolved(countryCode: country)
    }

    private static func named(_ name: String?, country: String?) -> Resolved {
        guard let name else { return Resolved(countryCode: country) }
        return Resolved(countryCode: country, cityID: "\(country ?? "")|\(WorldCityIndex.key(name))", cityName: name)
    }

    /// The names a geocoded locality may go by: "Xuan Huong - Da Lat" is also "Da Lat", and
    /// "Hua Hin District" is "Hua Hin".
    private static func cityNames(from locality: String?) -> [String] {
        var name = locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.hasSuffix(" District") { name.removeLast(" District".count) }
        if name.hasPrefix("Kabupaten ") { name.removeFirst("Kabupaten ".count) }
        guard !name.isEmpty else { return [] }
        let parts = name.components(separatedBy: " - ")
        return parts.count > 1 ? parts.reversed() : [name]
    }

    private static func isoCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.utf8.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return code
    }
}

/// Immutable bundled lookup, initialized on the Insights aggregation worker only when needed.
enum OfflineVisitGeography {
    static let resolver = try? ExplorationCountryResolver.bundled()

    static func country(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude,
              CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else { return nil }
        return resolver?.country(at: .init(latitude: latitude, longitude: longitude))?.id
    }
}
