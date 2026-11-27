import CoreLocation
import MapKit
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class PlacesIndexTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_779_580_800) // 2026-05-01 00:00 UTC

    func testGroupsPlacesByCountryThenCity() {
        let amsterdam = known(
            name: "Rijksmuseum",
            country: "NL",
            city: "Amsterdam",
            visits: 8,
            stay: 3_600,
            last: hours(10)
        )
        let vondelpark = known(
            name: "Vondelpark",
            country: "NL",
            city: "Amsterdam",
            visits: 3,
            stay: 1_800,
            last: hours(8)
        )
        let orsay = known(
            name: "Musée d'Orsay",
            country: "FR",
            city: "Paris",
            visits: 2,
            stay: 7_200,
            last: hours(30)
        )

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [amsterdam.place, vondelpark.place, orsay.place],
            visits: amsterdam.visits + vondelpark.visits + orsay.visits,
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.countries.map(\.countryCode), ["FR", "NL"])
        XCTAssertEqual(snapshot.countries[0].flagEmoji, "🇫🇷")
        XCTAssertEqual(snapshot.countries[1].flagEmoji, "🇳🇱")
        XCTAssertEqual(snapshot.countries[1].cities.map(\.cityName), ["Amsterdam"])
        XCTAssertEqual(snapshot.countries[1].cities[0].places.map(\.name), ["Rijksmuseum", "Vondelpark"])
        XCTAssertEqual(snapshot.countries[0].cities[0].places.map(\.name), ["Musée d'Orsay"])
    }

    func testUnknownCountrySortsLast() {
        let named = known(name: "Home", country: "DE", city: "Hamburg", visits: 1, stay: 600, last: hours(2))
        let loose = known(name: "Layover", country: nil, city: nil, visits: 4, stay: 900, last: hours(1))

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [named.place, loose.place],
            visits: named.visits + loose.visits,
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.countries.map(\.countryCode), ["DE", nil])
        XCTAssertEqual(snapshot.countries.last?.cities.first?.cityName, GeographyKey.unknownCity)
    }

    func testSearchMatchesNameCityAndCountry() {
        let cafe = known(name: "Cafe Nero", country: "GB", city: "London", visits: 4, stay: 1_200, last: hours(5))
        let gym = known(name: "Gym", country: "GB", city: "Manchester", visits: 2, stay: 3_600, last: hours(20))

        let byName = PlacesIndexBuilder.build(
            knownPlaces: [cafe.place, gym.place],
            visits: cafe.visits + gym.visits,
            sort: .name,
            query: "nero",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(byName.placeCount, 1)
        XCTAssertEqual(byName.countries.first?.cities.first?.places.first?.name, "Cafe Nero")

        let byCity = PlacesIndexBuilder.build(
            knownPlaces: [cafe.place, gym.place],
            visits: cafe.visits + gym.visits,
            sort: .name,
            query: "Manchester",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(byCity.countries.first?.cities.first?.places.map(\.name), ["Gym"])

        let byCountry = PlacesIndexBuilder.build(
            knownPlaces: [cafe.place, gym.place],
            visits: cafe.visits + gym.visits,
            sort: .name,
            query: "GB",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(byCountry.placeCount, 2)
    }

    func testSortOrdersByTimeNameAndRecency() {
        let home = known(name: "Alpha", country: "US", city: "Austin", visits: 2, stay: 10_000, last: hours(40))
        let work = known(name: "Beta", country: "US", city: "Austin", visits: 5, stay: 1_000, last: hours(2))

        func names(_ sort: PlacesSort) -> [String] {
            let snapshot = PlacesIndexBuilder.build(
                knownPlaces: [home.place, work.place],
                visits: home.visits + work.visits,
                sort: sort,
                query: "",
                now: now,
                calendar: calendar
            )
            return snapshot.countries.first?.cities.first?.places.map(\.name) ?? []
        }

        XCTAssertEqual(names(.mostVisited), ["Beta", "Alpha"])
        XCTAssertEqual(names(.mostTime), ["Alpha", "Beta"])
        XCTAssertEqual(names(.recent), ["Beta", "Alpha"])
        XCTAssertEqual(names(.name), ["Alpha", "Beta"])
    }

    func testSuggestedClustersNamedVisitsWithinRadiusAndSkipsAssigned() {
        let knownID = UUID()
        let assigned = PlacesVisitRecord(
            knownPlaceID: knownID,
            name: "Home",
            latitude: 52.52,
            longitude: 13.40,
            arrivalDate: hours(10),
            departureDate: hours(12)
        )
        let first = PlacesVisitRecord(
            name: "Cafe",
            latitude: 52.5200,
            longitude: 13.4050,
            arrivalDate: hours(3),
            departureDate: hours(4)
        )
        let nearby = PlacesVisitRecord(
            name: "cafe",
            latitude: 52.5204,
            longitude: 13.4052,
            arrivalDate: hours(27),
            departureDate: hours(28)
        )
        let far = PlacesVisitRecord(
            name: "Cafe",
            latitude: 52.54,
            longitude: 13.43,
            arrivalDate: hours(50),
            departureDate: hours(51)
        )

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [
                PlacesKnownRecord(id: knownID, name: "Home", latitude: 52.52, longitude: 13.40, countryCode: "DE", locality: "Berlin")
            ],
            visits: [assigned, first, nearby, far],
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.suggested.count, 2)
        XCTAssertEqual(snapshot.suggested[0].visitCount, 2)
        XCTAssertEqual(snapshot.suggested[0].name, "Cafe")
        XCTAssertEqual(snapshot.suggested[1].visitCount, 1)
        XCTAssertFalse(snapshot.suggested.contains { $0.name == "Home" })
    }

    func testOccupancyGridCountsArrivalWeekdayAndHour() {
        var fridayComponents = DateComponents()
        fridayComponents.year = 2026
        fridayComponents.month = 5
        fridayComponents.day = 1
        fridayComponents.hour = 18
        fridayComponents.timeZone = TimeZone(secondsFromGMT: 0)
        let fridayEvening = calendar.date(from: fridayComponents)!
        XCTAssertEqual(calendar.component(.weekday, from: fridayEvening), 6, "1 May 2026 is a Friday")

        let saturdayMorning = fridayEvening.addingTimeInterval(12 * 3_600)
        let visits = [
            PlacesVisitRecord(name: "Home", latitude: 0, longitude: 0, arrivalDate: fridayEvening, departureDate: fridayEvening.addingTimeInterval(3_600), assignmentSource: .user),
            PlacesVisitRecord(name: "Home", latitude: 0, longitude: 0, arrivalDate: saturdayMorning, departureDate: saturdayMorning.addingTimeInterval(1_800), assignmentSource: .user),
            PlacesVisitRecord(name: "Home", latitude: 0, longitude: 0, arrivalDate: fridayEvening.addingTimeInterval(7 * 24 * 3_600), departureDate: nil, assignmentSource: .user)
        ]

        let grid = OccupancyGrid.build(visits: visits, calendar: calendar)
        XCTAssertEqual(grid.counts[5][18], 2)
        XCTAssertEqual(grid.counts[6][6], 1)
        XCTAssertEqual(grid.maximum, 2)
        XCTAssertTrue(grid.hasData)
    }

    func testOccupancyFallsBackToHistogramsWhenVisitsAreMissing() {
        let grid = OccupancyGrid.build(
            visits: [],
            hourHistogram: Array(repeating: 0, count: 24).enumerated().map { $0.offset == 9 ? 4 : 0 },
            weekdayHistogram: [0, 3, 0, 0, 0, 0, 0],
            calendar: calendar
        )
        XCTAssertEqual(grid.counts[1][9], 12)
        XCTAssertEqual(grid.maximum, 12)
    }

    func testOccupancyIgnoresAutoAssignedVisits() {
        var fridayComponents = DateComponents()
        fridayComponents.year = 2026
        fridayComponents.month = 5
        fridayComponents.day = 1
        fridayComponents.hour = 18
        fridayComponents.timeZone = TimeZone(secondsFromGMT: 0)
        let fridayEvening = calendar.date(from: fridayComponents)!
        let auto = PlacesVisitRecord(
            name: "Home",
            latitude: 0,
            longitude: 0,
            arrivalDate: fridayEvening,
            departureDate: fridayEvening.addingTimeInterval(600),
            assignmentSource: .auto
        )
        let user = PlacesVisitRecord(
            name: "Home",
            latitude: 0,
            longitude: 0,
            arrivalDate: fridayEvening.addingTimeInterval(7 * 24 * 3_600),
            departureDate: nil,
            assignmentSource: .user
        )

        let grid = OccupancyGrid.build(visits: [auto, user], calendar: calendar)
        XCTAssertEqual(grid.counts[5][18], 1)
        XCTAssertEqual(grid.maximum, 1)
    }

    func testOccupancyFallsBackToHistogramsWhenOnlyAutoVisitsExist() {
        let auto = PlacesVisitRecord(
            name: "Home",
            latitude: 0,
            longitude: 0,
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            assignmentSource: .auto
        )
        let grid = OccupancyGrid.build(
            visits: [auto],
            hourHistogram: Array(repeating: 0, count: 24).enumerated().map { $0.offset == 9 ? 4 : 0 },
            weekdayHistogram: [0, 3, 0, 0, 0, 0, 0],
            calendar: calendar
        )
        XCTAssertEqual(grid.counts[1][9], 12)
        XCTAssertEqual(grid.maximum, 12)
    }

    func testGeocodeCacheKeyBucketsToOneHundredthDegree() {
        let a = PlaceGeocodeCellCache.cellKey(
            for: CLLocationCoordinate2D(latitude: 52.359997, longitude: 4.885218)
        )
        let b = PlaceGeocodeCellCache.cellKey(
            for: CLLocationCoordinate2D(latitude: 52.358400, longitude: 4.868500)
        )
        let paris = PlaceGeocodeCellCache.cellKey(
            for: CLLocationCoordinate2D(latitude: 48.846200, longitude: 2.337200)
        )
        XCTAssertEqual(a, "5236|489")
        XCTAssertEqual(b, "5236|487")
        XCTAssertEqual(paris, "4885|234")
        XCTAssertNotEqual(a, paris)
    }

    func testGeocodeApplyFillsMissingCountryAndCityOnly() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 52.37,
            longitude: 4.89,
            horizontalAccuracy: 12,
            userLabel: "Rijksmuseum"
        )
        visit.countryCode = "NL"
        context.insertOnDay(visit)
        let place = KnownPlace(name: "Rijksmuseum", latitude: 52.37, longitude: 4.89)
        context.insert(place)
        try context.save()

        let region = PlaceGeocodeRegion(countryCode: "XX", locality: "Amsterdam", administrativeArea: "North Holland")
        let key = PlaceGeocodeCellCache.cellKey(for: visit.coordinate)
        let changed = try PlaceGeocodeBackfill.apply(region, cellKey: key, in: context)

        XCTAssertGreaterThanOrEqual(changed, 1)
        XCTAssertEqual(visit.countryCode, "NL")
        XCTAssertEqual(visit.locality, "Amsterdam")
        XCTAssertEqual(place.countryCode, "XX")
        XCTAssertEqual(place.locality, "Amsterdam")
    }

    func testConfirmSuggestedCreatesKnownPlaceThroughRepository() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        let first = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(1_200),
            latitude: 48.86,
            longitude: 2.33,
            horizontalAccuracy: 10,
            userLabel: "Orsay"
        )
        let second = VisitPlace(
            arrivalDate: now.addingTimeInterval(86_400),
            departureDate: now.addingTimeInterval(87_000),
            latitude: 48.8602,
            longitude: 2.3304,
            horizontalAccuracy: 10,
            userLabel: "Orsay"
        )
        context.insertOnDay(first)
        context.insertOnDay(second)
        try context.save()

        let created = try PlacesLibrary.confirmSuggested(
            visitIDs: [first.id, second.id],
            name: "Musée d'Orsay",
            in: context
        )

        XCTAssertEqual(created.name, "Musée d'Orsay")
        XCTAssertEqual(first.knownPlace?.id, created.id)
        XCTAssertEqual(second.knownPlace?.id, created.id)
        XCTAssertEqual(first.assignmentSource, .user)
        XCTAssertEqual(second.assignmentSource, .user)
        XCTAssertGreaterThan(created.confirmedVisitCount, 0)
        XCTAssertFalse(created.arrivalHourHistogram.allSatisfy { $0 == 0 })
    }

    /// A place visited a thousand times (Roger's theatre has 1,109 stays) confirms in one
    /// pass: every stay named, the unplaced stays beside it adopted, Undo putting all of it
    /// back, and Rename relabelling every stay. Confirming used to learn, adopt, and save
    /// once per stay and froze the app.
    func testConfirmAndRenameAPlaceWithAThousandStays() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        let latitude = 37.7962, longitude = -122.4068
        var stays: [VisitPlace] = []
        for index in 0..<1_200 {
            let arrival = now.addingTimeInterval(TimeInterval(-index) * 86_400)
            let jitter = Double(index % 7 - 3) * 0.00003
            let visit = VisitPlace(
                arrivalDate: arrival,
                departureDate: arrival.addingTimeInterval(4 * 3_600),
                latitude: latitude + jitter,
                longitude: longitude - jitter,
                horizontalAccuracy: 15
            )
            context.insertOnDay(visit)
            stays.append(visit)
        }
        var neighbors: [VisitPlace] = []
        for index in 0..<30 {
            let arrival = now.addingTimeInterval(TimeInterval(-index) * 86_400 + 6 * 3_600)
            let visit = VisitPlace(
                arrivalDate: arrival,
                departureDate: arrival.addingTimeInterval(1_800),
                latitude: latitude + 0.0003,
                longitude: longitude,
                horizontalAccuracy: 10
            )
            context.insertOnDay(visit)
            neighbors.append(visit)
        }
        let far = VisitPlace(
            arrivalDate: now.addingTimeInterval(8 * 3_600),
            departureDate: now.addingTimeInterval(9 * 3_600),
            latitude: latitude + 0.01,
            longitude: longitude,
            horizontalAccuracy: 10
        )
        context.insertOnDay(far)
        try context.save()

        var step: AppUndoStep?
        let started = Date()
        let place = try PlacesLibrary.confirmSuggested(
            visitIDs: stays.map(\.id),
            name: "The Great Star Theater",
            in: context,
            undoStep: { step = $0 }
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "Confirming 1,200 stays took \(elapsed) s")

        XCTAssertTrue(stays.allSatisfy { $0.knownPlace?.id == place.id && $0.assignmentSource == .user })
        XCTAssertTrue(stays.allSatisfy { $0.userLabel == "The Great Star Theater" })
        XCTAssertEqual(place.confirmedVisitCount, 1_200)
        XCTAssertTrue(neighbors.allSatisfy { $0.knownPlace?.id == place.id && $0.assignmentSource == .auto })
        XCTAssertNil(far.knownPlace)
        XCTAssertEqual(far.assignmentSource, .none)

        let renamed = try PlacesLibrary.rename(place, to: "Great Star", in: context)
        XCTAssertNotNil(renamed)
        XCTAssertEqual(place.name, "Great Star")
        XCTAssertTrue(stays.allSatisfy { $0.userLabel == "Great Star" })
        renamed?.undo()
        XCTAssertEqual(place.name, "The Great Star Theater")
        XCTAssertTrue(stays.allSatisfy { $0.userLabel == "The Great Star Theater" })

        let placeID = place.id
        try XCTUnwrap(step).undo()
        XCTAssertTrue(try context.fetch(FetchDescriptor<KnownPlace>(predicate: #Predicate { $0.id == placeID })).isEmpty)
        XCTAssertTrue(stays.allSatisfy { $0.knownPlace == nil && $0.assignmentSource == .none && $0.userLabel == nil })
        XCTAssertTrue(neighbors.allSatisfy { $0.knownPlace == nil && $0.assignmentSource == .none })
    }

    func testSuggestedClusterExposesDisplayNameAndAddressForUnconfirmedVisits() {
        let first = PlacesVisitRecord(
            name: "10.81393, 106.71000",
            latitude: 10.81393,
            longitude: 106.71000,
            arrivalDate: hours(3),
            departureDate: hours(2),
            autoLabel: nil,
            thoroughfare: "Ben Van Don",
            formattedAddress: "150 Ben Van Don, District 4"
        )
        let nearby = PlacesVisitRecord(
            name: "10.81395, 106.71002",
            latitude: 10.81395,
            longitude: 106.71002,
            arrivalDate: hours(30),
            departureDate: hours(28),
            thoroughfare: "Ben Van Don",
            formattedAddress: "150 Ben Van Don, District 4"
        )

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [],
            visits: [first, nearby],
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.suggested.count, 1)
        XCTAssertEqual(snapshot.suggested[0].displayName, "Ben Van Don")
        XCTAssertEqual(snapshot.suggested[0].address, "150 Ben Van Don, District 4")
        XCTAssertFalse(snapshot.suggested[0].name.localizedCaseInsensitiveContains("Untitled"))
        XCTAssertTrue(snapshot.suggested[0].subtitle.contains("Ben Van Don") || snapshot.suggested[0].subtitle.contains("visit"))
    }

    func testUnlabeledClustersUseCompactCoordinatesInsteadOfUntitled() {
        let visit = PlacesVisitRecord(
            name: "52.52000, 13.40500",
            latitude: 52.52000,
            longitude: 13.40500,
            arrivalDate: hours(4),
            departureDate: hours(3)
        )

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [],
            visits: [visit],
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.suggested.count, 1)
        XCTAssertEqual(snapshot.suggested[0].displayName, PlaceDisplayName.compactCoordinate(visit.coordinate))
        XCTAssertTrue(snapshot.suggested[0].isNaming)
        XCTAssertFalse(snapshot.suggested[0].name.contains("Untitled"))
        XCTAssertTrue(snapshot.suggested[0].subtitle.contains("Naming"))
    }

    func testSameStreetClustersStaySeparateAndShowThumbnails() {
        let north = PlacesVisitRecord(
            name: "coord",
            latitude: 52.35580,
            longitude: 4.89120,
            arrivalDate: hours(8),
            departureDate: hours(6),
            thoroughfare: "Hobbemakade",
            formattedAddress: "Hobbemakade 120"
        )
        let south = PlacesVisitRecord(
            name: "coord",
            latitude: 52.35390,
            longitude: 4.89380,
            arrivalDate: hours(40),
            departureDate: hours(38),
            thoroughfare: "Hobbemakade",
            formattedAddress: "Hobbemakade 40"
        )
        let user = CLLocationCoordinate2D(latitude: 52.35580, longitude: 4.89120)

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [],
            visits: [north, south],
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar,
            userCoordinate: user
        )

        XCTAssertEqual(snapshot.suggested.count, 2)
        // Same street, different buildings: the house number tells them apart.
        XCTAssertEqual(Set(snapshot.suggested.map(\.name)), ["Hobbemakade 120", "Hobbemakade 40"])
        XCTAssertTrue(snapshot.suggested.allSatisfy(\.showsMapThumbnail))
        XCTAssertTrue(snapshot.suggested.contains { $0.subtitle.localizedCaseInsensitiveContains("away") })
    }

    /// A hotel geocodes to a different house number on each stay; it must stay one suggestion.
    func testHouseNumberLabelsAroundOneStayFormOneSuggestion() {
        func stay(_ label: String, dLat: Double, dLon: Double, start: Int, hours length: Int) -> PlacesVisitRecord {
            PlacesVisitRecord(
                name: label,
                latitude: 45.0 + dLat,
                longitude: 7.0 + dLon,
                arrivalDate: hours(start),
                departureDate: hours(start - length),
                locality: "Sampletown",
                autoLabel: label,
                thoroughfare: "24 Oak Row",
                formattedAddress: "24 Oak Row, Sampletown"
            )
        }
        let visits = [
            stay("32 Oak Row", dLat: 0, dLon: 0, start: 100, hours: 14),
            stay("32 Oak Row", dLat: 0.00004, dLon: -0.00003, start: 76, hours: 12),
            stay("28 Oak Row", dLat: 0.00006, dLon: -0.00025, start: 52, hours: 15),
            stay("41 Oak Row", dLat: 0.0003, dLon: 0.0001, start: 4, hours: 3),
            stay("74 Oak Row", dLat: 0.0004, dLon: 0.0003, start: 30, hours: 10),
            stay("Elm Row", dLat: -0.0003, dLon: -0.0001, start: 150, hours: 20),
            stay("8 Elm Row", dLat: -0.0005, dLon: 0.0001, start: 170, hours: 1),
            // A real place next door keeps its own suggestion.
            stay("Corner Bakery", dLat: 0.0002, dLon: 0.0002, start: 10, hours: 1),
        ]

        let snapshot = PlacesIndexBuilder.build(
            knownPlaces: [],
            visits: visits,
            sort: .mostVisited,
            query: "",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.suggested.count, 2)
        let hotel = snapshot.suggested[0]
        XCTAssertEqual(hotel.visitCount, 7)
        // Named after where the most time was spent, not the latest stray fix.
        XCTAssertEqual(hotel.name, "32 Oak Row")
        XCTAssertEqual(hotel.address, "Sampletown")
        XCTAssertEqual(snapshot.suggested[1].name, "Corner Bakery")
        XCTAssertTrue(hotel.subtitle.hasPrefix("7 visits"))
        XCTAssertGreaterThan(hotel.spreadRadius, PlaceLearningEngine.minimumFootprintRadius)
    }

    func testHouseNumberTitleNeverSitsOverADifferentHouseNumber() {
        XCTAssertEqual(
            PlacesIndexBuilder.consistentAddress(title: "41 Oak Row", address: "24 Oak Row, Sampletown", locality: "Sampletown"),
            "Sampletown"
        )
        XCTAssertEqual(
            PlacesIndexBuilder.consistentAddress(title: "41 Oak Row", address: "41 Oak Row, Sampletown", locality: nil),
            "Sampletown"
        )
        XCTAssertEqual(
            PlacesIndexBuilder.consistentAddress(title: "Ben Van Don", address: "150 Ben Van Don, District 4", locality: nil),
            "150 Ben Van Don, District 4"
        )
        XCTAssertEqual(PlacesIndexBuilder.streetPart(of: "Hobbemakade 120"), "Hobbemakade")
        XCTAssertEqual(PlacesIndexBuilder.streetPart(of: "8 Nguyen Bieu"), "Nguyen Bieu")
        XCTAssertNil(PlacesIndexBuilder.streetPart(of: "Corner Bakery"))
    }

    func testPlaceDisplayNamerPrefersPOIThenStreetThenCoordinate() {
        let poi = PlaceDisplayNamer.resolve(
            userLabel: nil,
            autoLabel: "Highlands Coffee",
            thoroughfare: "Ben Van Don",
            formattedAddress: "150 Ben Van Don",
            locality: "Ho Chi Minh City",
            coordinate: CLLocationCoordinate2D(latitude: 10.81, longitude: 106.71),
            isPending: false
        )
        XCTAssertEqual(poi.primary, "Highlands Coffee")
        XCTAssertEqual(poi.address, "150 Ben Van Don")

        let street = PlaceDisplayNamer.resolve(
            userLabel: nil,
            autoLabel: nil,
            thoroughfare: "Museumstraat",
            formattedAddress: nil,
            locality: "Amsterdam",
            coordinate: CLLocationCoordinate2D(latitude: 52.36, longitude: 4.88),
            isPending: false
        )
        XCTAssertEqual(street.primary, "Museumstraat")
        XCTAssertEqual(street.address, "Amsterdam")
    }

    func testConfirmSuggestedStoresCategoryAndAddress() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(1_200),
            latitude: 52.36,
            longitude: 4.88,
            horizontalAccuracy: 10
        )
        visit.thoroughfare = "Museumstraat"
        context.insertOnDay(visit)
        try context.save()

        let created = try PlacesLibrary.confirmSuggested(
            visitIDs: [visit.id],
            name: "Rijksmuseum Garden",
            in: context,
            formattedAddress: "Museumstraat, Amsterdam",
            thoroughfare: "Museumstraat",
            category: "Gym"
        )

        XCTAssertEqual(created.name, "Rijksmuseum Garden")
        XCTAssertEqual(created.formattedAddress, "Museumstraat, Amsterdam")
        XCTAssertEqual(created.thoroughfare, "Museumstraat")
        XCTAssertEqual(created.category, KnownPlaceCategory.gym.rawValue)
        XCTAssertEqual(visit.assignmentSource, .user)
        XCTAssertEqual(visit.userLabel, "Rijksmuseum Garden")
    }

    func testFillMissingNamesWritesAutoLabelFromFakeGeocode() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 10.8139,
            longitude: 106.7100,
            horizontalAccuracy: 12
        )
        context.insertOnDay(visit)
        try context.save()

        let region = PlaceGeocodeRegion(
            countryCode: "VN",
            locality: "Ho Chi Minh City",
            name: nil,
            thoroughfare: "Ben Van Don",
            formattedAddress: "150 Ben Van Don, District 4"
        )
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("places-name-\(UUID().uuidString).json")
        let cache = PlaceGeocodeCellCache(regions: [:], url: cacheURL)
        let filled = await PlaceGeocodeBackfill.fillMissingNames(
            in: container,
            geocoder: FakePlaceReverseGeocoder(region: region),
            searcher: nil,
            cache: cache,
            limit: 4
        )

        XCTAssertGreaterThanOrEqual(filled, 1)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(reloaded.first?.autoLabel, "Ben Van Don")
        XCTAssertEqual(reloaded.first?.thoroughfare, "Ben Van Don")
        XCTAssertEqual(reloaded.first?.formattedAddress, "150 Ben Van Don, District 4")
        XCTAssertEqual(reloaded.first?.locality, "Ho Chi Minh City")
    }

    /// Apple's rate limit ended the whole backfill at its first refusal, so on a phone
    /// with a long history the trickle rarely got past a handful of cells.
    func testBackfillWaitsOutRateLimitAndCarriesOn() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 10.8139,
            longitude: 106.7100,
            horizontalAccuracy: 12
        )
        context.insertOnDay(visit)
        try context.save()

        let region = PlaceGeocodeRegion(countryCode: "VN", locality: "Ho Chi Minh City")
        let throttled = NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
        let geocoder = RefusingThenAnsweringGeocoder(refusals: [throttled], region: region)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("places-busy-\(UUID().uuidString).json")
        let filled = await PlaceGeocodeBackfill.run(
            in: container,
            geocoder: geocoder,
            cache: PlaceGeocodeCellCache(regions: [:], url: cacheURL),
            busyWait: .milliseconds(10)
        )

        XCTAssertEqual(filled, 1)
        XCTAssertEqual(geocoder.calls, 2)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(reloaded.first?.locality, "Ho Chi Minh City")
        XCTAssertEqual(PlaceGeocodeBackfill.trouble(NSError(domain: kCLErrorDomain, code: CLError.Code.network.rawValue)), .busy)
        XCTAssertEqual(PlaceGeocodeBackfill.trouble(URLError(.notConnectedToInternet)), .offline)
        XCTAssertNil(PlaceGeocodeBackfill.trouble(NSError(domain: kCLErrorDomain, code: CLError.Code.geocodeFoundNoResult.rawValue)))
    }

    func testMergeUsesPlaceLearningEngineAndDeletesSource() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        let keeper = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.40, footprintRadius: 40)
        let duplicate = KnownPlace(name: "Home 2", latitude: 52.5204, longitude: 13.405, footprintRadius: 50)
        context.insert(keeper)
        context.insert(duplicate)
        let autoVisit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 52.5204,
            longitude: 13.405,
            horizontalAccuracy: 10,
            userLabel: "Home 2"
        )
        autoVisit.knownPlace = duplicate
        autoVisit.assignmentSource = .auto
        context.insertOnDay(autoVisit)
        try context.save()

        try PlacesLibrary.merge(duplicate, into: keeper, in: context)

        XCTAssertEqual(autoVisit.knownPlace?.id, keeper.id)
        XCTAssertEqual(autoVisit.assignmentSource, .auto)
        XCTAssertTrue(try context.fetch(FetchDescriptor<KnownPlace>()).allSatisfy { $0.id != duplicate.id })
    }

    func testUndoingADeletedPlaceBringsItBackWithItsVisits() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let place = KnownPlace(name: "Studio", latitude: 52.52, longitude: 13.40, footprintRadius: 60)
        place.category = KnownPlaceCategory.gym.rawValue
        context.insert(place)
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 52.52,
            longitude: 13.40,
            horizontalAccuracy: 10,
            userLabel: "Studio"
        )
        visit.knownPlace = place
        visit.assignmentSource = .user
        visit.assignmentConfidence = 1
        context.insertOnDay(visit)
        try context.save()
        let placeID = place.id

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        context.undoManager = undoManager

        try PlacesLibrary.deletePlace(place, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 0)
        XCTAssertNil(visit.knownPlace)

        undoManager.undo()

        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<KnownPlace>()).first)
        XCTAssertEqual(restored.id, placeID)
        XCTAssertEqual(restored.name, "Studio")
        XCTAssertEqual(restored.footprintRadius, 60)
        XCTAssertEqual(restored.category, KnownPlaceCategory.gym.rawValue)
        XCTAssertEqual(visit.knownPlace?.id, placeID)
        XCTAssertEqual(visit.assignmentSource, .user)
        XCTAssertEqual(visit.assignmentConfidence, 1)
    }

    func testUndoingAMergeRestoresBothPlaces() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let keeper = KnownPlace(name: "Home", latitude: 52.52, longitude: 13.40, footprintRadius: 40)
        let duplicate = KnownPlace(name: "Home 2", latitude: 52.5204, longitude: 13.405, footprintRadius: 50)
        duplicate.rejectedAutoLabels = ["Corner shop"]
        context.insert(keeper)
        context.insert(duplicate)
        let visit = VisitPlace(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(600),
            latitude: 52.5204,
            longitude: 13.405,
            horizontalAccuracy: 10,
            userLabel: "Home 2"
        )
        visit.knownPlace = duplicate
        visit.assignmentSource = .user
        context.insertOnDay(visit)
        try context.save()
        let duplicateID = duplicate.id

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        context.undoManager = undoManager

        try PlacesLibrary.merge(duplicate, into: keeper, in: context)
        XCTAssertEqual(visit.knownPlace?.id, keeper.id)
        XCTAssertEqual(keeper.rejectedAutoLabels, ["Corner shop"])

        undoManager.undo()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 2)
        XCTAssertEqual(visit.knownPlace?.id, duplicateID)
        XCTAssertEqual(visit.knownPlace?.rejectedAutoLabels, ["Corner shop"])
        XCTAssertEqual(keeper.rejectedAutoLabels, [])
        XCTAssertEqual(keeper.footprintRadius, 40)
    }

    /// The Undo pill on a place undoes that edit, even after something else wrote to the
    /// store, and the edit leaves the shared stack so shake-to-undo cannot run it twice.
    func testThePlaceUndoPillUndoesItsOwnEditAfterOtherWrites() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        // Event grouping on, as in the app, so SwiftData can record the other write.
        let undoManager = UndoManager()
        context.undoManager = undoManager
        let place = KnownPlace(name: "Cafe", latitude: 48.86, longitude: 2.33, footprintRadius: 80)
        let other = KnownPlace(name: "Library", latitude: 48.87, longitude: 2.34, footprintRadius: 60)
        context.insert(place)
        context.insert(other)
        try context.save()

        let shrink = try PlacesLibrary.shrinkFootprint(place, in: context)
        // A write nobody asked to undo, recorded on the same manager.
        other.locality = "Paris"
        try context.save()
        shrink.undo(removingFrom: undoManager)
        XCTAssertEqual(place.footprintRadius, 80)
        XCTAssertEqual(other.locality, "Paris")

        let rename = try XCTUnwrap(try PlacesLibrary.rename(place, to: "Corner Cafe", in: context))
        other.locality = "Paris 1er"
        try context.save()
        rename.undo(removingFrom: undoManager)
        XCTAssertEqual(place.name, "Cafe")
        XCTAssertEqual(other.locality, "Paris 1er")
        XCTAssertFalse(shrink.isPending)
        XCTAssertFalse(rename.isPending)

        let gym = try PlacesLibrary.setCategory(other, to: .gym, in: context)
        let delete = try PlacesLibrary.deletePlace(other, in: context)
        delete.undo(removingFrom: undoManager)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 2)
        XCTAssertTrue(gym.isPending)
    }

    func testShrinkFootprintUsesEngineClamp() throws {
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.undoManager = UndoManager()
        let place = KnownPlace(name: "Cafe", latitude: 48.86, longitude: 2.33, footprintRadius: 40)
        context.insert(place)
        try context.save()

        try PlacesLibrary.shrinkFootprint(place, in: context)
        XCTAssertEqual(place.footprintRadius, PlaceLearningEngine.clampRadius(40 * PlaceLearningEngine.radiusShrinkFactor), accuracy: 0.001)

        place.footprintRadius = PlaceLearningEngine.minimumFootprintRadius
        try PlacesLibrary.shrinkFootprint(place, in: context)
        XCTAssertEqual(place.footprintRadius, PlaceLearningEngine.minimumFootprintRadius, accuracy: 0.001)
    }

    private struct Fixture {
        var place: PlacesKnownRecord
        var visits: [PlacesVisitRecord]
    }

    private func known(
        name: String,
        country: String?,
        city: String?,
        visits visitCount: Int,
        stay: TimeInterval,
        last: Date
    ) -> Fixture {
        let id = UUID()
        let place = PlacesKnownRecord(
            id: id,
            name: name,
            latitude: 1,
            longitude: 2,
            countryCode: country,
            locality: city,
            confirmedVisitCount: visitCount,
            lastVisitAt: last
        )
        let perVisit = stay / Double(max(visitCount, 1))
        let visits = (0..<visitCount).map { index in
            let arrival = last.addingTimeInterval(TimeInterval(-index) * 86_400)
            return PlacesVisitRecord(
                knownPlaceID: id,
                name: name,
                latitude: 1,
                longitude: 2,
                arrivalDate: arrival,
                departureDate: arrival.addingTimeInterval(perVisit),
                countryCode: country,
                locality: city,
                assignmentSource: .user
            )
        }
        return Fixture(place: place, visits: visits)
    }

    private func hours(_ value: Int) -> Date {
        now.addingTimeInterval(TimeInterval(-value) * 3_600)
    }
}

private extension ModelContext {
    /// Inserts a stay on the day it starts, as the app always files one: a stay with no
    /// day is retired and every reader leaves it out.
    func insertOnDay(_ visit: VisitPlace) {
        insert(visit)
        let key = DayTimeline.makeDayKey(for: visit.arrivalDate)
        let existing = try? fetch(FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })).first
        let day = existing ?? DayTimeline(dayStart: visit.arrivalDate)
        if existing == nil { insert(day) }
        visit.dayTimeline = day
    }
}

private struct FakePlaceReverseGeocoder: PlaceReverseGeocoding, Sendable {
    let region: PlaceGeocodeRegion

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> PlaceGeocodeRegion? {
        region
    }
}

/// Throws each of `refusals` in turn, then answers with `region`.
private final class RefusingThenAnsweringGeocoder: PlaceReverseGeocoding, @unchecked Sendable {
    private let lock = NSLock()
    private var refusals: [any Error]
    private var callCount = 0
    let region: PlaceGeocodeRegion

    init(refusals: [any Error], region: PlaceGeocodeRegion) {
        self.refusals = refusals
        self.region = region
    }

    var calls: Int { lock.withLock { callCount } }

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> PlaceGeocodeRegion? {
        let refusal: (any Error)? = lock.withLock {
            callCount += 1
            return refusals.isEmpty ? nil : refusals.removeFirst()
        }
        if let refusal { throw refusal }
        return region
    }
}
