import CoreLocation
import Foundation
import SwiftUI

/// The time zone in force at a coordinate, worked out offline.
///
/// A day in Moves is the calendar day where the person was, so a stay or trip is filed
/// by the clock on the wall where it happened, not by the zone the phone is in when the
/// row is written. The country comes from the outlines Insights already bundles
/// (`ExplorationCountryBoundaries.json`); a country with one zone maps straight to it,
/// and a country with several picks the zone of the nearest of a few reference cities.
/// Near a zone border inside such a country the guess can be an hour off, which only
/// matters within an hour of midnight. Over open sea the zone is the nautical one,
/// 15° of longitude to the hour. No network and no data file beyond the outlines.
enum PlaceTimeZone {
    /// The zone at `coordinate`, or nil when the coordinate is not a real position.
    static func timeZone(at coordinate: CLLocationCoordinate2D) -> TimeZone? {
        guard isUsable(coordinate) else { return nil }
        let key = cacheKey(for: coordinate)
        if let cached = cache.zone(for: key) { return cached }
        let zone = resolve(coordinate)
        cache.store(zone, for: key)
        return zone
    }

    /// Finite, on the globe, and not the (0, 0) a missing fix is often written as.
    static func isUsable(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && abs(coordinate.latitude) <= 90 && abs(coordinate.longitude) <= 180
            && !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    /// The zone a ship would keep at this longitude.
    static func nauticalZone(longitude: Double) -> TimeZone {
        let hours = max(-12, min(12, Int((longitude / 15).rounded())))
        return TimeZone(secondsFromGMT: hours * 3600) ?? TimeZone(identifier: "UTC")!
    }

    private static func resolve(_ coordinate: CLLocationCoordinate2D) -> TimeZone {
        if let country = countryID(near: coordinate),
           let identifier = zoneIdentifier(country: country, coordinate: coordinate),
           let zone = TimeZone(identifier: identifier) {
            return zone
        }
        return nauticalZone(longitude: coordinate.longitude)
    }

    /// Simplified coastlines leave harbours and beaches just outside their country, so a
    /// miss tries a ring of nearby points before calling it open sea.
    private static func countryID(near coordinate: CLLocationCoordinate2D) -> String? {
        guard let resolver = countryResolver else { return nil }
        if let country = resolver.country(at: coordinate) { return country.id }
        for step in [0.02, 0.06, 0.2] {
            for (north, east) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let probe = CLLocationCoordinate2D(
                    latitude: max(-90, min(90, coordinate.latitude + north * step)),
                    longitude: coordinate.longitude + east * step
                )
                if let country = resolver.country(at: probe) { return country.id }
            }
        }
        return nil
    }

    static func zoneIdentifier(country: String, coordinate: CLLocationCoordinate2D) -> String? {
        if let seeds = referenceCities[country], !seeds.isEmpty {
            let scale = cos(coordinate.latitude * .pi / 180)
            return seeds.min { lhs, rhs in
                squaredDistance(lhs, coordinate, scale) < squaredDistance(rhs, coordinate, scale)
            }?.zone
        }
        return singleZones[country]
    }

    private static func squaredDistance(
        _ seed: (zone: String, latitude: Double, longitude: Double),
        _ coordinate: CLLocationCoordinate2D,
        _ scale: Double
    ) -> Double {
        let north = seed.latitude - coordinate.latitude
        var east = seed.longitude - coordinate.longitude
        if east > 180 { east -= 360 }
        if east < -180 { east += 360 }
        return north * north + (east * scale) * (east * scale)
    }

    private static let countryResolver: ExplorationCountryResolver? = try? ExplorationCountryResolver.bundled()

    // MARK: Cache

    /// About 2 km cells; a person's whole history touches a few thousand.
    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> Int64 {
        let latitude = Int64(((coordinate.latitude + 90) * 50).rounded(.down))
        let longitude = Int64(((coordinate.longitude + 180) * 50).rounded(.down))
        return latitude * 100_000 + longitude
    }

    private static let cache = ZoneCache()

    private final class ZoneCache: @unchecked Sendable {
        private let lock = NSLock()
        private var zones: [Int64: TimeZone] = [:]

        func zone(for key: Int64) -> TimeZone? {
            lock.withLock { zones[key] }
        }

        func store(_ zone: TimeZone, for key: Int64) {
            lock.withLock {
                if zones.count > 50_000 { zones.removeAll(keepingCapacity: true) }
                zones[key] = zone
            }
        }
    }

    // MARK: Tables

    /// Countries whose land keeps one clock. From the IANA `zone.tab`, plus the outline
    /// dataset's own codes for Taiwan, Kosovo, and Northern Cyprus.
    static let singleZones: [String: String] = {
        var table: [String: String] = [:]
        for entry in singleZoneTable.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            table[String(parts[0])] = String(parts[1])
        }
        return table
    }()

    /// Countries spanning several clocks, as reference cities per zone. The United States,
    /// Canada, and Australia carry extra cities so the nearest one follows the real
    /// borders more closely; the rest are the principal cities in `zone.tab`.
    static let referenceCities: [String: [(zone: String, latitude: Double, longitude: Double)]] = {
        var table: [String: [(zone: String, latitude: Double, longitude: Double)]] = [:]
        for line in referenceCityTable.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 4, let latitude = Double(parts[2]), let longitude = Double(parts[3]) else { continue }
            table[String(parts[0]), default: []].append((String(parts[1]), latitude, longitude))
        }
        return table
    }()

    private static let singleZoneTable = """
    AD=Europe/Andorra AE=Asia/Dubai AF=Asia/Kabul AG=America/Antigua AI=America/Anguilla
    AL=Europe/Tirane AM=Asia/Yerevan AO=Africa/Luanda AR=America/Argentina/Buenos_Aires
    AS=Pacific/Pago_Pago AT=Europe/Vienna AW=America/Aruba AX=Europe/Mariehamn AZ=Asia/Baku
    BA=Europe/Sarajevo BB=America/Barbados BD=Asia/Dhaka BE=Europe/Brussels BF=Africa/Ouagadougou
    BG=Europe/Sofia BH=Asia/Bahrain BI=Africa/Bujumbura BJ=Africa/Porto-Novo BL=America/St_Barthelemy
    BM=Atlantic/Bermuda BN=Asia/Brunei BO=America/La_Paz BQ=America/Kralendijk BS=America/Nassau
    BT=Asia/Thimphu BW=Africa/Gaborone BY=Europe/Minsk BZ=America/Belize CC=Indian/Cocos
    CF=Africa/Bangui CG=Africa/Brazzaville CH=Europe/Zurich CI=Africa/Abidjan CK=Pacific/Rarotonga
    CM=Africa/Douala CN=Asia/Shanghai CN-TW=Asia/Taipei CO=America/Bogota CR=America/Costa_Rica
    CU=America/Havana CV=Atlantic/Cape_Verde CW=America/Curacao CX=Indian/Christmas CY=Asia/Nicosia
    CZ=Europe/Prague DE=Europe/Berlin DJ=Africa/Djibouti DK=Europe/Copenhagen DM=America/Dominica
    DO=America/Santo_Domingo DZ=Africa/Algiers EE=Europe/Tallinn EG=Africa/Cairo EH=Africa/El_Aaiun
    ER=Africa/Asmara ET=Africa/Addis_Ababa FI=Europe/Helsinki FJ=Pacific/Fiji FK=Atlantic/Stanley
    FO=Atlantic/Faroe FR=Europe/Paris GA=Africa/Libreville GB=Europe/London GD=America/Grenada
    GE=Asia/Tbilisi GF=America/Cayenne GG=Europe/Guernsey GH=Africa/Accra GI=Europe/Gibraltar
    GM=Africa/Banjul GN=Africa/Conakry GP=America/Guadeloupe GQ=Africa/Malabo GR=Europe/Athens
    GS=Atlantic/South_Georgia GT=America/Guatemala GU=Pacific/Guam GW=Africa/Bissau GY=America/Guyana
    HK=Asia/Hong_Kong HN=America/Tegucigalpa HR=Europe/Zagreb HT=America/Port-au-Prince
    HU=Europe/Budapest IE=Europe/Dublin IL=Asia/Jerusalem IM=Europe/Isle_of_Man IN=Asia/Kolkata
    IO=Indian/Chagos IQ=Asia/Baghdad IR=Asia/Tehran IS=Atlantic/Reykjavik IT=Europe/Rome
    JE=Europe/Jersey JM=America/Jamaica JO=Asia/Amman JP=Asia/Tokyo KE=Africa/Nairobi KG=Asia/Bishkek
    KH=Asia/Phnom_Penh KM=Indian/Comoro KN=America/St_Kitts KP=Asia/Pyongyang KR=Asia/Seoul
    KW=Asia/Kuwait KY=America/Cayman KZ=Asia/Almaty LA=Asia/Vientiane LB=Asia/Beirut LC=America/St_Lucia
    LI=Europe/Vaduz LK=Asia/Colombo LR=Africa/Monrovia LS=Africa/Maseru LT=Europe/Vilnius
    LU=Europe/Luxembourg LV=Europe/Riga LY=Africa/Tripoli MA=Africa/Casablanca MC=Europe/Monaco
    MD=Europe/Chisinau ME=Europe/Podgorica MF=America/Marigot MG=Indian/Antananarivo MH=Pacific/Majuro
    MK=Europe/Skopje ML=Africa/Bamako MM=Asia/Yangon MO=Asia/Macau MP=Pacific/Saipan
    MQ=America/Martinique MR=Africa/Nouakchott MS=America/Montserrat MT=Europe/Malta MU=Indian/Mauritius
    MV=Indian/Maldives MW=Africa/Blantyre MY=Asia/Kuala_Lumpur MZ=Africa/Maputo NA=Africa/Windhoek
    NC=Pacific/Noumea NE=Africa/Niamey NF=Pacific/Norfolk NG=Africa/Lagos NI=America/Managua
    NL=Europe/Amsterdam NO=Europe/Oslo NP=Asia/Kathmandu NR=Pacific/Nauru NU=Pacific/Niue OM=Asia/Muscat
    PA=America/Panama PE=America/Lima PH=Asia/Manila PK=Asia/Karachi PL=Europe/Warsaw
    PM=America/Miquelon PN=Pacific/Pitcairn PR=America/Puerto_Rico PS=Asia/Gaza PW=Pacific/Palau
    PY=America/Asuncion QA=Asia/Qatar RE=Indian/Reunion RO=Europe/Bucharest RS=Europe/Belgrade
    RW=Africa/Kigali SA=Asia/Riyadh SB=Pacific/Guadalcanal SC=Indian/Mahe SD=Africa/Khartoum
    SE=Europe/Stockholm SG=Asia/Singapore SH=Atlantic/St_Helena SI=Europe/Ljubljana
    SJ=Arctic/Longyearbyen SK=Europe/Bratislava SL=Africa/Freetown SM=Europe/San_Marino SN=Africa/Dakar
    SO=Africa/Mogadishu SR=America/Paramaribo SS=Africa/Juba ST=Africa/Sao_Tome SV=America/El_Salvador
    SX=America/Lower_Princes SY=Asia/Damascus SZ=Africa/Mbabane TC=America/Grand_Turk TD=Africa/Ndjamena
    TF=Indian/Kerguelen TG=Africa/Lome TH=Asia/Bangkok TJ=Asia/Dushanbe TK=Pacific/Fakaofo TL=Asia/Dili
    TM=Asia/Ashgabat TN=Africa/Tunis TO=Pacific/Tongatapu TR=Europe/Istanbul TT=America/Port_of_Spain
    TV=Pacific/Funafuti TW=Asia/Taipei TZ=Africa/Dar_es_Salaam UG=Africa/Kampala UY=America/Montevideo
    UZ=Asia/Samarkand VA=Europe/Vatican VC=America/St_Vincent VE=America/Caracas VG=America/Tortola
    VI=America/St_Thomas VN=Asia/Ho_Chi_Minh VU=Pacific/Efate WF=Pacific/Wallis WS=Pacific/Apia
    XC=Asia/Famagusta XK=Europe/Belgrade YE=Asia/Aden YT=Indian/Mayotte ZA=Africa/Johannesburg
    ZM=Africa/Lusaka ZW=Africa/Harare
    """

    private static let referenceCityTable = """
    US America/Los_Angeles 34.05 -118.24
    US America/Los_Angeles 37.77 -122.42
    US America/Los_Angeles 47.61 -122.33
    US America/Los_Angeles 45.52 -122.68
    US America/Los_Angeles 36.17 -115.14
    US America/Los_Angeles 39.53 -119.81
    US America/Los_Angeles 47.66 -117.43
    US America/Los_Angeles 40.80 -124.16
    US America/Phoenix 33.45 -112.07
    US America/Phoenix 32.22 -110.97
    US America/Phoenix 35.20 -111.65
    US America/Denver 39.74 -104.99
    US America/Denver 40.76 -111.89
    US America/Denver 35.08 -106.65
    US America/Denver 43.62 -116.20
    US America/Denver 31.76 -106.49
    US America/Denver 41.14 -104.82
    US America/Denver 45.78 -108.50
    US America/Denver 46.59 -112.04
    US America/Denver 44.08 -103.23
    US America/Chicago 41.88 -87.63
    US America/Chicago 32.78 -96.80
    US America/Chicago 29.76 -95.37
    US America/Chicago 44.98 -93.27
    US America/Chicago 39.10 -94.58
    US America/Chicago 29.95 -90.07
    US America/Chicago 36.16 -86.78
    US America/Chicago 35.15 -90.05
    US America/Chicago 38.63 -90.20
    US America/Chicago 35.47 -97.52
    US America/Chicago 41.26 -95.94
    US America/Chicago 46.88 -96.79
    US America/Chicago 46.81 -100.78
    US America/Chicago 43.55 -96.73
    US America/Chicago 37.69 -97.34
    US America/Chicago 29.42 -98.49
    US America/Chicago 43.04 -87.91
    US America/Chicago 33.52 -86.80
    US America/Chicago 35.22 -101.83
    US America/Chicago 30.69 -88.04
    US America/New_York 40.71 -74.00
    US America/New_York 33.75 -84.39
    US America/New_York 25.76 -80.19
    US America/New_York 42.36 -71.06
    US America/New_York 38.90 -77.04
    US America/New_York 35.23 -80.84
    US America/New_York 40.44 -79.99
    US America/New_York 41.50 -81.69
    US America/New_York 39.96 -83.00
    US America/New_York 30.33 -81.66
    US America/New_York 27.95 -82.46
    US America/New_York 35.78 -78.64
    US America/New_York 35.96 -83.92
    US America/New_York 42.89 -78.88
    US America/New_York 43.66 -70.26
    US America/New_York 30.44 -84.28
    US America/New_York 38.25 -85.76
    US America/New_York 39.10 -84.51
    US America/New_York 32.08 -81.09
    US America/Detroit 42.33 -83.05
    US America/Detroit 42.96 -85.67
    US America/Indiana/Indianapolis 39.77 -86.16
    US America/Anchorage 61.22 -149.90
    US America/Anchorage 64.84 -147.72
    US America/Juneau 58.30 -134.42
    US America/Adak 51.88 -176.66
    US Pacific/Honolulu 21.31 -157.86
    US Pacific/Honolulu 19.71 -155.08
    CA America/Vancouver 49.28 -123.12
    CA America/Vancouver 53.92 -122.75
    CA America/Edmonton 53.55 -113.49
    CA America/Edmonton 51.05 -114.07
    CA America/Edmonton 62.45 -114.37
    CA America/Regina 50.45 -104.62
    CA America/Regina 52.13 -106.67
    CA America/Winnipeg 49.90 -97.14
    CA America/Winnipeg 58.77 -94.17
    CA America/Toronto 43.65 -79.38
    CA America/Toronto 45.42 -75.70
    CA America/Toronto 45.50 -73.57
    CA America/Toronto 46.81 -71.21
    CA America/Toronto 48.38 -89.25
    CA America/Toronto 46.49 -80.99
    CA America/Halifax 44.65 -63.57
    CA America/Moncton 46.09 -64.78
    CA America/Halifax 46.24 -63.13
    CA America/St_Johns 47.56 -52.71
    CA America/Whitehorse 60.72 -135.06
    CA America/Iqaluit 63.75 -68.52
    AU Australia/Perth -31.95 115.86
    AU Australia/Perth -20.31 118.58
    AU Australia/Darwin -12.46 130.84
    AU Australia/Darwin -23.70 133.88
    AU Australia/Adelaide -34.93 138.60
    AU Australia/Adelaide -32.49 137.77
    AU Australia/Broken_Hill -31.95 141.45
    AU Australia/Brisbane -27.47 153.03
    AU Australia/Brisbane -16.92 145.77
    AU Australia/Brisbane -19.26 146.82
    AU Australia/Brisbane -20.73 139.49
    AU Australia/Brisbane -23.38 150.51
    AU Australia/Sydney -33.87 151.21
    AU Australia/Sydney -35.28 149.13
    AU Australia/Sydney -32.93 151.78
    AU Australia/Sydney -30.30 153.11
    AU Australia/Sydney -35.12 147.37
    AU Australia/Melbourne -37.81 144.96
    AU Australia/Melbourne -36.76 144.28
    AU Australia/Hobart -42.88 147.33
    AQ Antarctica/McMurdo -77.83 166.60
    AQ Antarctica/Palmer -64.80 -64.10
    AQ Antarctica/Casey -66.28 110.52
    BR America/Noronha -3.85 -32.42
    BR America/Belem -1.45 -48.48
    BR America/Fortaleza -3.72 -38.50
    BR America/Recife -8.05 -34.90
    BR America/Araguaina -7.20 -48.20
    BR America/Maceio -9.67 -35.72
    BR America/Bahia -12.98 -38.52
    BR America/Sao_Paulo -23.53 -46.62
    BR America/Campo_Grande -20.45 -54.62
    BR America/Cuiaba -15.58 -56.08
    BR America/Santarem -2.43 -54.87
    BR America/Porto_Velho -8.77 -63.90
    BR America/Boa_Vista 2.82 -60.67
    BR America/Manaus -3.13 -60.02
    BR America/Eirunepe -6.67 -69.87
    BR America/Rio_Branco -9.97 -67.80
    CD Africa/Kinshasa -4.30 15.30
    CD Africa/Lubumbashi -11.67 27.47
    CL America/Santiago -33.45 -70.67
    CL America/Coyhaique -45.57 -72.07
    CL America/Punta_Arenas -53.15 -70.92
    CL Pacific/Easter -27.15 -109.43
    EC America/Guayaquil -2.17 -79.83
    EC Pacific/Galapagos -0.90 -89.60
    ES Europe/Madrid 40.40 -3.68
    ES Africa/Ceuta 35.88 -5.32
    ES Atlantic/Canary 28.10 -15.40
    FM Pacific/Chuuk 7.42 151.78
    FM Pacific/Pohnpei 6.97 158.22
    FM Pacific/Kosrae 5.32 162.98
    GL America/Nuuk 64.18 -51.73
    GL America/Danmarkshavn 76.77 -18.67
    GL America/Scoresbysund 70.48 -21.97
    GL America/Thule 76.57 -68.78
    ID Asia/Jakarta -6.17 106.80
    ID Asia/Pontianak -0.03 109.33
    ID Asia/Makassar -5.12 119.40
    ID Asia/Makassar -8.65 115.22
    ID Asia/Jayapura -2.53 140.70
    KI Pacific/Tarawa 1.42 173.00
    KI Pacific/Kanton -2.78 -171.72
    KI Pacific/Kiritimati 1.87 -157.33
    MN Asia/Ulaanbaatar 47.92 106.88
    MN Asia/Hovd 48.02 91.65
    MX America/Mexico_City 19.40 -99.15
    MX America/Cancun 21.08 -86.77
    MX America/Merida 20.97 -89.62
    MX America/Monterrey 25.67 -100.32
    MX America/Matamoros 25.83 -97.50
    MX America/Chihuahua 28.63 -106.08
    MX America/Ciudad_Juarez 31.73 -106.48
    MX America/Ojinaga 29.57 -104.42
    MX America/Mazatlan 23.22 -106.42
    MX America/Bahia_Banderas 20.80 -105.25
    MX America/Hermosillo 29.07 -110.97
    MX America/Tijuana 32.53 -117.02
    NZ Pacific/Auckland -36.87 174.77
    NZ Pacific/Auckland -45.87 170.50
    NZ Pacific/Chatham -43.95 -176.55
    PF Pacific/Tahiti -17.53 -149.57
    PF Pacific/Marquesas -9.00 -139.50
    PF Pacific/Gambier -23.13 -134.95
    PG Pacific/Port_Moresby -9.50 147.17
    PG Pacific/Bougainville -6.22 155.57
    PT Europe/Lisbon 38.72 -9.13
    PT Atlantic/Madeira 32.63 -16.90
    PT Atlantic/Azores 37.73 -25.67
    RU Europe/Kaliningrad 54.72 20.50
    RU Europe/Moscow 55.76 37.62
    RU Europe/Kirov 58.60 49.65
    RU Europe/Volgograd 48.73 44.42
    RU Europe/Astrakhan 46.35 48.05
    RU Europe/Saratov 51.57 46.03
    RU Europe/Ulyanovsk 54.33 48.40
    RU Europe/Samara 53.20 50.15
    RU Asia/Yekaterinburg 56.85 60.60
    RU Asia/Omsk 55.00 73.40
    RU Asia/Novosibirsk 55.03 82.92
    RU Asia/Barnaul 53.37 83.75
    RU Asia/Tomsk 56.50 84.97
    RU Asia/Novokuznetsk 53.75 87.12
    RU Asia/Krasnoyarsk 56.02 92.83
    RU Asia/Irkutsk 52.27 104.33
    RU Asia/Chita 52.05 113.47
    RU Asia/Yakutsk 62.00 129.67
    RU Asia/Khandyga 62.66 135.55
    RU Asia/Vladivostok 43.17 131.93
    RU Asia/Ust-Nera 64.56 143.23
    RU Asia/Magadan 59.57 150.80
    RU Asia/Sakhalin 46.97 142.70
    RU Asia/Srednekolymsk 67.47 153.72
    RU Asia/Kamchatka 53.02 158.65
    RU Asia/Anadyr 64.75 177.48
    UA Europe/Simferopol 44.95 34.10
    UA Europe/Kyiv 50.43 30.52
    UM Pacific/Midway 28.22 -177.37
    UM Pacific/Wake 19.28 166.62
    """
}

extension View {
    /// Shows and edits times on `zone`'s clock: text formatted from the environment and
    /// every `DatePicker` below read `\.timeZone` and `\.calendar`.
    func timelineClock(_ zone: TimeZone) -> some View {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return environment(\.timeZone, zone).environment(\.calendar, calendar)
    }
}

extension VisitPlace {
    /// The clock this stay is read and edited on: the zone where it is.
    var placeTimeZone: TimeZone {
        PlaceTimeZone.timeZone(at: coordinate) ?? dayTimeline?.placeTimeZone ?? Calendar.current.timeZone
    }
}

extension MoveSegment {
    /// The clock this trip is read and edited on: the zone of the stop it left from.
    var placeTimeZone: TimeZone {
        startPlace.flatMap { PlaceTimeZone.timeZone(at: $0.coordinate) }
            ?? dayTimeline?.placeTimeZone
            ?? Calendar.current.timeZone
    }
}

extension PhotoAttachment {
    /// The clock the photo's time is read on: where it was taken, else its stay or day.
    var placeTimeZone: TimeZone {
        if let latitude, let longitude,
           let zone = PlaceTimeZone.timeZone(at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            return zone
        }
        return visitPlace?.placeTimeZone ?? dayTimeline?.placeTimeZone ?? Calendar.current.timeZone
    }
}

/// Reads a row's date and time on the clock of the place where it happened, the way the
/// Timeline tab does, for screens that list rows from many days and places at once.
enum PlaceClock {
    /// `base` formatting on `zone`'s clock.
    static func style(_ base: Date.FormatStyle, in zone: TimeZone) -> Date.FormatStyle {
        var style = base
        style.timeZone = zone
        return style
    }

    /// `date` formatted with `base` on `zone`'s clock.
    static func format(_ date: Date, _ base: Date.FormatStyle, in zone: TimeZone) -> String {
        date.formatted(style(base, in: zone))
    }

    /// The zone's short name ("PDT") at `moment` when that clock is not the phone's, else nil.
    static func foreignAbbreviation(of zone: TimeZone, at moment: Date, phone: TimeZone = .current) -> String? {
        guard zone.secondsFromGMT(for: moment) != phone.secondsFromGMT(for: moment) else { return nil }
        return zone.abbreviation(for: moment) ?? zone.identifier
    }

    /// The date `moment` falls on where it happened, as midnight of that date on `calendar`.
    /// Use it to compare with today, or to group beside `DayTimeline.calendarDate(in:)`.
    static func calendarDate(of moment: Date, in zone: TimeZone, on calendar: Calendar = .current) -> Date {
        let key = TimelineDayFiling.dayKey(for: moment, in: zone)
        return TimelineDayFiling.startOfDay(forKey: key, in: calendar.timeZone) ?? calendar.startOfDay(for: moment)
    }

    /// A calendar for hour and weekday arithmetic on `zone`'s clock, keeping the rest of `calendar`.
    static func calendar(_ calendar: Calendar = .current, in zone: TimeZone) -> Calendar {
        var calendar = calendar
        calendar.timeZone = zone
        return calendar
    }
}

/// Which day a moment is filed under, and when that day starts, in a given zone.
enum TimelineDayFiling {
    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// `yyyy-MM-dd` of `date` on the clocks of `zone`.
    static func dayKey(for date: Date, in zone: TimeZone) -> String {
        let day = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    static func startOfDay(for date: Date, in zone: TimeZone) -> Date {
        calendar(in: zone).startOfDay(for: date)
    }

    /// Midnight that begins `dayKey` in `zone`, or nil for a malformed key.
    static func startOfDay(forKey dayKey: String, in zone: TimeZone) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = calendar(in: zone)
        guard let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return nil }
        return calendar.startOfDay(for: noon)
    }
}

/// Where the person was around a moment, from stored fixes, for rows that carry no
/// coordinate of their own (a trip with no stop yet, a photo without a location).
struct RecordedTimeZones {
    /// Farther than this from any fix, the moment is not placed at all.
    static let reach: TimeInterval = 12 * 60 * 60

    private(set) var times: [TimeInterval] = []
    private(set) var coordinates: [CLLocationCoordinate2D] = []

    init() {}

    /// `fixes` in any order; unusable coordinates are dropped.
    init(fixes: [(date: Date, coordinate: CLLocationCoordinate2D)]) {
        let usable = fixes
            .filter { PlaceTimeZone.isUsable($0.coordinate) }
            .sorted { $0.date < $1.date }
        times = usable.map { $0.date.timeIntervalSinceReferenceDate }
        coordinates = usable.map(\.coordinate)
    }

    var isEmpty: Bool { times.isEmpty }

    mutating func insert(_ date: Date, _ coordinate: CLLocationCoordinate2D) {
        guard PlaceTimeZone.isUsable(coordinate) else { return }
        let time = date.timeIntervalSinceReferenceDate
        let index = Self.lowerBound(time, in: times)
        times.insert(time, at: index)
        coordinates.insert(coordinate, at: index)
    }

    /// The coordinate of the fix nearest `date`, when one lies within `reach`.
    func coordinate(near date: Date) -> CLLocationCoordinate2D? {
        guard !times.isEmpty else { return nil }
        let time = date.timeIntervalSinceReferenceDate
        let index = Self.lowerBound(time, in: times)
        var best: Int?
        for candidate in [index - 1, index] where candidate >= 0 && candidate < times.count {
            if best == nil || abs(times[candidate] - time) < abs(times[best!] - time) {
                best = candidate
            }
        }
        guard let best, abs(times[best] - time) <= Self.reach else { return nil }
        return coordinates[best]
    }

    func timeZone(near date: Date) -> TimeZone? {
        coordinate(near: date).flatMap(PlaceTimeZone.timeZone(at:))
    }

    private static func lowerBound(_ value: TimeInterval, in values: [TimeInterval]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
