import CoreLocation
import SwiftData
import XCTest
@testable import Moves

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
        context.insert(visit)
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
        context.insert(first)
        context.insert(second)
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
        XCTAssertTrue(snapshot.suggested.allSatisfy { $0.name == "Hobbemakade" })
        XCTAssertTrue(snapshot.suggested.allSatisfy(\.showsMapThumbnail))
        XCTAssertTrue(snapshot.suggested.contains { $0.subtitle.localizedCaseInsensitiveContains("away") })
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
        context.insert(visit)
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
        context.insert(visit)
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
        context.insert(autoVisit)
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
        context.insert(visit)
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
        context.insert(visit)
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

private struct FakePlaceReverseGeocoder: PlaceReverseGeocoding, Sendable {
    let region: PlaceGeocodeRegion

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> PlaceGeocodeRegion? {
        region
    }
}
