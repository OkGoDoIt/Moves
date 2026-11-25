import XCTest
@testable import Moves

/// Which country and city a stay counts for, and how stays add up to days.
final class InsightsGeographyTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func visit(
        _ latitude: Double,
        _ longitude: Double,
        country: String? = nil,
        locality: String? = nil,
        area: String? = nil,
        from arrival: Date? = nil,
        to departure: Date? = nil
    ) -> InsightsVisitRecord {
        var record = InsightsVisitRecord(countryCode: country, locality: locality)
        record.administrativeArea = area
        record.latitude = latitude
        record.longitude = longitude
        record.arrivalDate = arrival
        record.departureDate = departure
        return record
    }

    private func day(_ visit: InsightsVisitRecord, on date: Date) -> InsightsDayRecord {
        InsightsDayRecord(dayStart: calendar.startOfDay(for: date), visits: [visit])
    }

    /// Taiwan was listed as a second, flagless "China mainland": the borders call it CN-TW.
    func testEveryBorderCodeIsACountryWithAFlagAndAContinent() throws {
        XCTAssertEqual(OfflineVisitGeography.country(latitude: 25.033, longitude: 121.565), "TW")
        let resolver = try ExplorationCountryResolver.bundled()
        for code in Set(resolver.availableCountries.map(\.id)) where code != "-99" {
            XCTAssertEqual(code.count, 2, code)
            XCTAssertNotEqual(PlacesGeography.countryName(forCountryCode: code), code)
            XCTAssertFalse(PlacesGeography.flagEmoji(forCountryCode: code).isEmpty, code)
            XCTAssertFalse(WorldContinent(countryCode: code).id.isEmpty, code)
        }
        XCTAssertEqual(WorldContinent(countryCode: "US").name, "North America")
        XCTAssertEqual(WorldContinent(countryCode: "BR").name, "South America")
    }

    /// Geocoding answers with wards and suburbs; the list must say the city.
    func testStaysBelongToCitiesNotTheirDistricts() {
        let cases: [(InsightsVisitRecord, String?)] = [
            (visit(10.768, 106.702, country: "VN", locality: "Xom Chieu", area: "Ho Chi Minh City"), "Ho Chi Minh City"),
            (visit(10.710, 106.708, country: "VN", locality: "Nha Be", area: "Ho Chi Minh City"), "Ho Chi Minh City"),
            (visit(11.934, 108.436, country: "VN", locality: "Xuan Huong - Da Lat", area: "Lam Dong"), "Da Lat"),
            (visit(10.341, 107.082, country: "VN", locality: "Vung Tau", area: "Ho Chi Minh City"), "Vung Tau"),
            (visit(13.718, 100.534, country: "TH", locality: "Sathon District", area: "Bangkok"), "Bangkok"),
            (visit(12.514, 99.971, country: "TH", locality: "Hua Hin District", area: "Prachuap Khiri Khan"), "Hua Hin"),
            (visit(-33.896, 151.275, country: "AU", locality: "Bondi Beach", area: "NSW"), "Sydney"),
            // Cities beside a bigger one keep their own name.
            (visit(37.688, -122.470, country: "US", locality: "Daly City", area: "CA"), "Daly City"),
            // No geocode at all: offline borders and cities answer.
            (visit(31.230, 121.470), "Shanghai"),
            // A village too small for the list keeps the name geocoding gave it.
            (visit(41.651, -82.822, country: "US", locality: "Put In Bay", area: "OH"), "Put In Bay"),
            // A province repeated as the city is no city, and open ocean is nowhere.
            (visit(-8.711, 115.348, country: "ID", locality: "Bali", area: "Bali"), nil),
            (visit(0, -140), nil)
        ]
        for (record, expected) in cases {
            XCTAssertEqual(VisitGeography.resolve(record).cityName, expected, record.locality ?? "\(record)")
        }
        XCTAssertEqual(VisitGeography.resolve(visit(31.230, 121.470)).countryCode, "CN")
    }

    func testStaysJoinAcrossUnrecordedDaysAndBreakAtAnotherCountry() throws {
        let saigon = { self.visit(10.77, 106.70, country: "VN", from: $0, to: $0.addingTimeInterval(3_600)) }
        let bangkok = { self.visit(13.75, 100.50, country: "TH", from: $0, to: $0.addingTimeInterval(3_600)) }
        let days = [
            day(saigon(date(2026, 3, 1)), on: date(2026, 3, 1)),
            // Two days without records, then the same country.
            day(saigon(date(2026, 3, 4)), on: date(2026, 3, 4)),
            day(bangkok(date(2026, 3, 5)), on: date(2026, 3, 5)),
            day(saigon(date(2026, 3, 6)), on: date(2026, 3, 6)),
            // A month of silence is not a month in Vietnam.
            day(saigon(date(2026, 4, 20)), on: date(2026, 4, 20))
        ]
        let geography = InsightsGeographyBuilder.build(days: days, calendar: calendar)
        let vietnam = try XCTUnwrap(geography.country("VN"))
        XCTAssertEqual(vietnam.stays.map(\.dayCount), [4, 1, 1])
        XCTAssertEqual(vietnam.dayCount, 6)
        XCTAssertEqual(vietnam.visitCount, 4)
        XCTAssertEqual(vietnam.cities.map(\.name), ["Ho Chi Minh City"])
        XCTAssertEqual(geography.countries.map(\.code), ["VN", "TH"])
        XCTAssertEqual(geography.continents.map(\.continent.name), ["Asia"])
    }

    func testAnOvernightStayCountsBothDaysAndAYearCutsItAtNewYear() throws {
        let hotel = visit(40.4168, -3.7038, from: date(2025, 12, 30, 18), to: date(2026, 1, 2, 9))
        let days = [day(hotel, on: date(2025, 12, 30))]
        let all = InsightsGeographyBuilder.build(days: days, calendar: calendar)
        XCTAssertEqual(all.country("ES")?.dayCount, 4)
        XCTAssertEqual(all.city(try XCTUnwrap(all.country("ES")?.cities.first?.id))?.name, "Madrid")
        XCTAssertEqual(InsightsGeographyBuilder.build(days: days, period: .year(2025), calendar: calendar).country("ES")?.dayCount, 2)
        XCTAssertEqual(InsightsGeographyBuilder.build(days: days, period: .year(2026), calendar: calendar).country("ES")?.dayCount, 2)
        XCTAssertTrue(InsightsGeographyBuilder.build(days: days, period: .year(2024), calendar: calendar).countries.isEmpty)
    }

    /// A morning in Tokyo is one Tokyo date, though the phone's clock has it across midnight.
    func testDaysAreCountedOnTheClockWhereTheStayHappened() throws {
        // 8:30 to 10:00 on March 11 in Tokyo; 23:30 on the 10th to 1:00 on the 11th on this calendar.
        let breakfast = visit(35.6812, 139.7671, country: "JP", from: date(2026, 3, 10, 23).addingTimeInterval(1800), to: date(2026, 3, 11, 1))
        let geography = InsightsGeographyBuilder.build(days: [day(breakfast, on: date(2026, 3, 11))], calendar: calendar)
        let japan = try XCTUnwrap(geography.country("JP"))
        XCTAssertEqual(japan.dayCount, 1)
        XCTAssertEqual(japan.stays.map(\.start), [calendar.startOfDay(for: date(2026, 3, 11))])
    }

    func testTheMapHoldsEveryCountryAndFindsTheOneTapped() async throws {
        let loaded = await WorldMapGeometry.load()
        let map = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(map.countries.count, 230)
        func tapped(_ longitude: Double, _ latitude: Double, marked: Set<String> = []) -> String? {
            map.country(
                at: WorldMapGeometry.projectWrapping(longitude: longitude, latitude: latitude),
                slop: 0.02,
                marked: marked
            )?.code
        }
        XCTAssertEqual(tapped(108, 14), "VN")
        XCTAssertEqual(tapped(-98, 39), "US")
        XCTAssertEqual(tapped(134, -25), "AU")
        // Lesotho is a hole in South Africa; the far tip of Russia is past 180 degrees.
        XCTAssertEqual(tapped(28.2, -29.5), "LS")
        XCTAssertEqual(tapped(-175, 67), "RU")
        // A visited island nation is easy to hit; open ocean is not a country.
        XCTAssertEqual(tapped(103.9, 0.9, marked: ["SG"]), "SG")
        XCTAssertNil(tapped(-140, 0))
    }
}
