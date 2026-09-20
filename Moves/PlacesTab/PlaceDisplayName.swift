import CoreLocation
import Foundation

/// Resolved name + address for an unconfirmed visit or suggested cluster.
///
/// Never returns "Untitled place". Callers show a POI / street, a compact
/// coordinate, or "Naming…" while reverse geocode is still in flight.
struct PlaceDisplayName: Equatable, Sendable {
    /// Primary list title (POI, street, locality, coordinate, or "Naming…").
    var primary: String
    /// Street or formatted address when it adds information beyond `primary`.
    var address: String?
    /// True when reverse geocode has not produced a street or POI yet.
    var isPending: Bool

    /// Compact 4-decimal coordinate (~11 m), unique per cluster centroid.
    static func compactCoordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }
}

/// Chooses a human name for Places UI from labels the engine already stores.
enum PlaceDisplayNamer {
    /// Coordinate pairs written by `VisitPlace.displayTitle` when no label exists.
    private static let coordinatePattern = #"^-?\d+\.\d+,\s*-?\d+\.\d+$"#

    /// Trims and drops empty, coordinate, and placeholder titles.
    static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveCompare(String(localized: "Untitled place")) == .orderedSame {
            return nil
        }
        if isCoordinateLabel(trimmed) { return nil }
        return trimmed
    }

    static func isCoordinateLabel(_ name: String) -> Bool {
        name.range(of: coordinatePattern, options: .regularExpression) != nil
    }

    /// Best list title for one visit. Pending geocode uses a compact coordinate
    /// so neighboring unlabeled rows stay distinguishable.
    static func resolve(
        userLabel: String?,
        autoLabel: String?,
        thoroughfare: String?,
        formattedAddress: String?,
        locality: String?,
        coordinate: CLLocationCoordinate2D,
        isPending: Bool,
        fallbackName: String? = nil
    ) -> PlaceDisplayName {
        let user = meaningful(userLabel)
        let auto = meaningful(autoLabel)
        let street = meaningful(thoroughfare)
        let formatted = meaningful(formattedAddress)
        let city = meaningful(locality)
        let fallback = meaningful(fallbackName)

        let primary = user
            ?? auto
            ?? street
            ?? fallback
            ?? city
            ?? PlaceDisplayName.compactCoordinate(coordinate)

        let address = firstDistinct(from: [formatted, street, city], notEqualTo: primary)
        return PlaceDisplayName(
            primary: primary,
            address: address,
            isPending: isPending && user == nil && auto == nil && street == nil && fallback == nil
        )
    }

    static func resolve(from visit: PlacesVisitRecord, isPending: Bool) -> PlaceDisplayName {
        resolve(
            userLabel: visit.userLabel,
            autoLabel: visit.autoLabel,
            thoroughfare: visit.thoroughfare,
            formattedAddress: visit.formattedAddress,
            locality: visit.locality,
            coordinate: visit.coordinate,
            isPending: isPending,
            fallbackName: visit.name
        )
    }

    static func resolve(from visit: VisitPlace, isPending: Bool) -> PlaceDisplayName {
        resolve(
            userLabel: visit.userLabel,
            autoLabel: visit.autoLabel,
            thoroughfare: visit.thoroughfare,
            formattedAddress: visit.formattedAddress,
            locality: visit.locality,
            coordinate: visit.coordinate,
            isPending: isPending,
            fallbackName: visit.displayTitle
        )
    }

    /// Name used to merge nearby visits into one suggestion. Streets stay
    /// spatial so two buildings on the same road remain separate clusters.
    static func clusteringName(
        userLabel: String?,
        autoLabel: String?,
        thoroughfare: String? = nil,
        fallbackName: String?
    ) -> String? {
        if let user = meaningful(userLabel) { return fold(user) }
        if let auto = meaningful(autoLabel) {
            if looksLikeStreet(auto) { return nil }
            if let street = meaningful(thoroughfare), auto.caseInsensitiveCompare(street) == .orderedSame {
                return nil
            }
            return fold(auto)
        }
        if let fallback = meaningful(fallbackName), !looksLikeStreet(fallback) { return fold(fallback) }
        return nil
    }

    /// Street-like labels should not collapse distinct footprints.
    static func looksLikeStreet(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let tokens = ["street", "st.", "st ", "road", "rd.", "avenue", "ave", "alley", "lane", "boulevard", "blvd", "drive", "dr.", "weg", "straat", "gasse", "kade", "dike", "đường", "hẻm", "ngõ"]
        if tokens.contains(where: { lowered.contains($0) }) { return true }
        let digits = name.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return digits >= 2 && name.count <= 48
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func firstDistinct(from values: [String?], notEqualTo primary: String) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            if value.caseInsensitiveCompare(primary) == .orderedSame { return nil }
            return value
        }.first
    }
}

extension VisitPlace {
    /// Stay length; open visits run until `now`.
    func stayDuration(now: Date = .now) -> TimeInterval {
        let end = min(departureDate ?? now, now)
        return max(end.timeIntervalSince(arrivalDate), 0)
    }

    /// Places-tab title; never "Untitled place".
    var placesDisplayName: String {
        PlaceDisplayNamer.resolve(from: self, isPending: needsPlaceNameGeocode).primary
    }

    /// Street or formatted address when it differs from the title.
    var placesAddressLine: String? {
        PlaceDisplayNamer.resolve(from: self, isPending: needsPlaceNameGeocode).address
    }

    /// True when reverse geocode has not yet filled a POI or street.
    var needsPlaceNameGeocode: Bool {
        PlaceDisplayNamer.meaningful(userLabel) == nil
            && PlaceDisplayNamer.meaningful(autoLabel) == nil
            && PlaceDisplayNamer.meaningful(thoroughfare) == nil
    }
}
