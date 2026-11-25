import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// One real place should have one name, and naming it once should fix it everywhere.
@MainActor
final class PlaceIdentityTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)

    // MARK: G. Readable automatic labels

    func testHouseNumberRunsKeepTheirFirstAndLastNumber() {
        XCTAssertEqual(
            PlaceDisplayNamer.normalizedAutomaticLabel("135-137-139-141-143-145 Example Street"),
            "135–145 Example Street"
        )
        XCTAssertEqual(PlaceDisplayNamer.normalizedAutomaticLabel("12-14 Main Road"), "12–14 Main Road")
        XCTAssertEqual(PlaceDisplayNamer.normalizedAutomaticLabel("10, 12 & 14 King St"), "10–14 King St")
        XCTAssertEqual(PlaceDisplayNamer.normalizedAutomaticLabel("  8 Market Lane "), "8 Market Lane")
        // An alley address and a brand are not lists.
        XCTAssertEqual(PlaceDisplayNamer.normalizedAutomaticLabel("114/134 Example Street"), "114/134 Example Street")
        XCTAssertEqual(PlaceDisplayNamer.normalizedAutomaticLabel("7-Eleven"), "7-Eleven")
        XCTAssertEqual(
            PlaceDisplayNamer.labelComparisonKey("135-137-139 Phố Ví Dụ"),
            PlaceDisplayNamer.labelComparisonKey("135–139 pho vi du")
        )
    }

    func testRejectedLabelsStayRejectedInTheirReadableForm() throws {
        let (context, _) = try makeContext()
        let place = KnownPlace(name: "Hotel", latitude: origin.latitude, longitude: origin.longitude)
        place.rejectedAutoLabels = ["135-137-139 Example Street"]
        context.insert(place)
        XCTAssertTrue(PlaceLearningEngine.shouldSuppress("135–139 Example Street", nearbyPlaces: [place]))
        XCTAssertTrue(PlaceLearningEngine.shouldSuppress("135-137-139 example street", nearbyPlaces: [place]))
        XCTAssertFalse(PlaceLearningEngine.shouldSuppress("140 Example Street", nearbyPlaces: [place]))
    }

    func testAutomaticLabelsAreStoredInReadableForm() throws {
        let (repository, context, _) = try makeRepository()
        let visit = insertVisit(context, at: origin, hours: 9...10)
        try context.save()
        try repository.setAutomaticLabel("135-137-139-141 Example Street", for: visit.id)
        XCTAssertEqual(visit.autoLabel, "135–141 Example Street")
    }

    // MARK: A. Reuse before geocoding

    func testReusedLabelIsTheOneMostTimeWasSpentUnder() {
        let target = stay(at: origin, accuracy: 10, hours: 20...21, label: nil)
        let others = [
            stay(at: offset(origin, north: 10), accuracy: 10, hours: 0...8, label: "24 Example Street"),
            stay(at: offset(origin, north: -12), accuracy: 10, hours: 9...10, label: "48 Example Street"),
            stay(at: offset(origin, east: 15), accuracy: 10, hours: 11...12, label: "48 Example Street"),
        ]
        XCTAssertEqual(PlaceLearningEngine.reusableLabel(for: target, among: others), "24 Example Street")
    }

    func testReuseTiesGoToTheMostRecentStay() {
        let target = stay(at: origin, accuracy: 10, hours: 20...21, label: nil)
        let others = [
            stay(at: offset(origin, north: 10), accuracy: 10, hours: 1...3, label: "Older"),
            stay(at: offset(origin, north: -10), accuracy: 10, hours: 5...7, label: "Newer"),
        ]
        XCTAssertEqual(PlaceLearningEngine.reusableLabel(for: target, among: others), "Newer")
    }

    func testReuseDistanceGrowsWithAccuracyAndStopsAt100Metres() {
        XCTAssertEqual(PlaceLearningEngine.sameSpotDistance(5, 10), 50)
        XCTAssertEqual(PlaceLearningEngine.sameSpotDistance(150, 10), 100)
        let target = stay(at: origin, accuracy: 5, hours: 20...21, label: nil)
        let precise = stay(at: offset(origin, north: 60), accuracy: 5, hours: 0...8, label: "Too far")
        XCTAssertNil(PlaceLearningEngine.reusableLabel(for: target, among: [precise]))
        let vague = stay(at: offset(origin, north: 60), accuracy: 30, hours: 0...8, label: "Close enough")
        XCTAssertEqual(PlaceLearningEngine.reusableLabel(for: target, among: [vague]), "Close enough")
        let vagueButFar = stay(at: offset(origin, north: 120), accuracy: 150, hours: 0...8, label: "Past the cap")
        XCTAssertNil(PlaceLearningEngine.reusableLabel(for: target, among: [vagueButFar]))
    }

    func testNewStayReusesTheNearbyLabelInsteadOfAFreshGeocode() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let earlier = insertVisit(seed, at: offset(origin, north: 20), hours: 0...8)
        earlier.autoLabel = "24 Example Street"
        try seed.save()

        let assembler = DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContainer: container),
            motionClassifier: IdentityStubMotionClassifier(),
            placeNameResolver: IdentityStubResolver(name: "48 Example Street")
        )
        await assembler.ingestVisit(MockVisit(
            coordinate: origin,
            horizontalAccuracy: 12,
            arrivalDate: day(hour: 18),
            departureDate: day(hour: 22)
        ))
        await assembler.ingestVisit(MockVisit(
            coordinate: offset(origin, north: 400),
            horizontalAccuracy: 12,
            arrivalDate: day(hour: 23),
            departureDate: day(hour: 23, minute: 50)
        ))

        let visits = try ModelContext(container).fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        XCTAssertEqual(visits.map(\.autoLabel), ["24 Example Street", "24 Example Street", "48 Example Street"])
    }

    func testAReusedLabelTheUserRejectedHereIsNotReused() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let earlier = insertVisit(seed, at: offset(origin, north: 20), hours: 0...8)
        earlier.autoLabel = "Wrong Name"
        let known = KnownPlace(name: "Office", latitude: offset(origin, north: -200).latitude, longitude: origin.longitude)
        known.rejectedAutoLabels = ["Wrong Name"]
        seed.insert(known)
        try seed.save()

        let assembler = DefaultTimelineAssembler(
            repository: SwiftDataTimelineRepository(modelContainer: container),
            motionClassifier: IdentityStubMotionClassifier(),
            placeNameResolver: IdentityStubResolver(name: "Right Name")
        )
        await assembler.ingestVisit(MockVisit(
            coordinate: origin,
            horizontalAccuracy: 12,
            arrivalDate: day(hour: 18),
            departureDate: day(hour: 22)
        ))
        let visit = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<VisitPlace>()).first { $0.id != earlier.id })
        XCTAssertEqual(visit.autoLabel, "Right Name")
    }

    // MARK: B. Robust stay centre

    func testRobustCentreIsTheMedianOfGoodFixes() throws {
        let fixes = [0.0, 4, 8, 12, 300].map { north in
            let point = offset(origin, north: north)
            return (latitude: point.latitude, longitude: point.longitude, accuracy: north == 300 ? 5.0 : 20.0)
        }
        let vague = offset(origin, north: -500)
        let center = try XCTUnwrap(PlaceLearningEngine.robustCenter(
            of: fixes + [(latitude: vague.latitude, longitude: vague.longitude, accuracy: 400)]
        ))
        XCTAssertEqual(distance(center, offset(origin, north: 8)), 0, accuracy: 0.5)
        XCTAssertNil(PlaceLearningEngine.robustCenter(of: [(origin.latitude, origin.longitude, 10), (0, 0, 80)]))
    }

    func testDepartureReportTakesItsCentreFromTheStaysOwnFixes() throws {
        let (repository, context, _) = try makeRepository()
        _ = try repository.addOrUpdateVisit(from: MockVisit(
            coordinate: origin,
            horizontalAccuracy: 30,
            arrivalDate: day(hour: 9),
            departureDate: .distantFuture
        ))
        let fixes = (0..<6).map { index in
            CLLocation(
                coordinate: offset(origin, north: Double(index % 3) * 4),
                altitude: 0,
                horizontalAccuracy: 15,
                verticalAccuracy: -1,
                timestamp: day(hour: 9, minute: 30).addingTimeInterval(Double(index) * 40 * 60)
            )
        }
        _ = try repository.appendSamples(from: fixes, source: .significantChange)
        // The departure report claims a precise fix 60 m away, indoors.
        let visit = try repository.addOrUpdateVisit(from: MockVisit(
            coordinate: offset(origin, north: 60),
            horizontalAccuracy: 5,
            arrivalDate: day(hour: 9),
            departureDate: day(hour: 14)
        ))
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, 1)
        XCTAssertLessThan(distance(visit.coordinate, origin), 10)
    }

    func testJoinedStaysTakeTheirCentreFromTheirFixes() throws {
        let (repository, context, _) = try makeRepository()
        let first = insertVisit(context, at: origin, hours: 9...12, accuracy: 30)
        let second = insertVisit(context, at: offset(origin, north: 40), hours: 11...14, accuracy: 5)
        try context.save()
        let fixes = (0..<8).map { index in
            CLLocation(
                coordinate: offset(origin, north: Double(index % 2) * 6),
                altitude: 0,
                horizontalAccuracy: 20,
                verticalAccuracy: -1,
                timestamp: day(hour: 9, minute: 20).addingTimeInterval(Double(index) * 35 * 60)
            )
        }
        _ = try repository.appendSamples(from: fixes, source: .significantChange)
        try repository.repairDuplicateStays()
        let remaining = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, first.id)
        XCTAssertLessThan(distance(try XCTUnwrap(remaining.first).coordinate, offset(origin, north: 3)), 2)
        _ = second
    }

    // MARK: C. Name once, fixed everywhere

    func testNamingAStayAssignsThePastStaysAtThatSpotInOneUndoStep() throws {
        let (repository, context, _) = try makeRepository()
        let named = insertVisit(context, at: origin, hours: 20...23)
        let sameSpot = [
            insertVisit(context, at: offset(origin, north: 15), hours: 0...7, label: "24 Example Street"),
            insertVisit(context, at: offset(origin, east: -20), hours: 8...9, label: "48 Example Street"),
            insertVisit(context, at: offset(origin, north: 45), hours: 10...11, label: "56 Example Street"),
            insertVisit(context, at: offset(origin, north: 90), hours: 12...13),
            insertVisit(context, at: offset(origin, north: 135), hours: 14...15),
        ]
        // Reached through the chain, but past 150 m from the named stay.
        let neighbour = insertVisit(context, at: offset(origin, north: 180), hours: 16...17)
        let elsewhere = KnownPlace(name: "Gym", latitude: offset(origin, north: 300).latitude, longitude: origin.longitude)
        context.insert(elsewhere)
        let theirs = insertVisit(context, at: offset(origin, north: 10), hours: 17...18)
        theirs.knownPlace = elsewhere
        theirs.assignmentSource = .user
        let ownName = insertVisit(context, at: offset(origin, east: 10), hours: 18...19)
        ownName.userLabel = "Studio"
        try context.save()
        // The setup is not something the person can undo.
        context.undoManager?.removeAllActions()

        // The path every naming takes: rename, Home/Work/Gym, chip, and Places confirm
        // all create or assign through the repository.
        _ = try repository.createKnownPlace(from: named, name: "Hotel")

        let hotel = try XCTUnwrap(named.knownPlace)
        XCTAssertEqual(Set(sameSpot.map { $0.knownPlace?.id }), [hotel.id])
        XCTAssertTrue(sameSpot.allSatisfy { $0.assignmentSource == .auto })
        XCTAssertNil(neighbour.knownPlace)
        XCTAssertEqual(theirs.knownPlace?.id, elsewhere.id)
        XCTAssertNil(ownName.knownPlace)
        XCTAssertEqual(hotel.confirmedVisitCount, 1)
        // The footprint holds every stay it now owns.
        for visit in sameSpot + [named] {
            XCTAssertLessThanOrEqual(distance(hotel.coordinate, visit.coordinate), hotel.footprintRadius)
        }
        XCTAssertTrue(context.undoManager?.canUndo == true)

        context.undoManager?.undo()
        if context.hasChanges { try context.save() }

        XCTAssertTrue(try context.fetch(FetchDescriptor<KnownPlace>()).allSatisfy { $0.name != "Hotel" })
        for visit in sameSpot + [named] {
            XCTAssertNil(visit.knownPlace)
            XCTAssertEqual(visit.assignmentSource, .none)
        }
        XCTAssertEqual(theirs.knownPlace?.id, elsewhere.id)
    }

    /// The repository's naming is one undo group: one Undo takes back the place, the
    /// named stay, and every stay it adopted.
    func testOneUndoTakesBackTheNamingAndEveryAdoptedStay() throws {
        let (repository, context, _) = try makeRepository()
        let named = insertVisit(context, at: origin, hours: 20...23)
        let past = [
            insertVisit(context, at: offset(origin, north: 15), hours: 0...7, label: "24 Example Street"),
            insertVisit(context, at: offset(origin, north: 45), hours: 8...9),
        ]
        try context.save()
        context.undoManager?.removeAllActions()

        let place = try repository.createKnownPlace(from: named, name: "Hotel")
        XCTAssertEqual(Set(past.map { $0.knownPlace?.id }), [place.id])

        context.undoManager?.undo()
        if context.hasChanges { try context.save() }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 0)
        for visit in past + [named] {
            XCTAssertNil(visit.knownPlace)
            XCTAssertEqual(visit.assignmentSource, .none)
        }
        XCTAssertNil(named.userLabel)
        XCTAssertEqual(past[0].autoLabel, "24 Example Street")
    }

    func testAssigningToAnExistingPlaceRespectsStaysTheUserMovedAway() throws {
        let (repository, context, _) = try makeRepository()
        let place = KnownPlace(name: "Home", latitude: origin.latitude, longitude: origin.longitude, footprintRadius: 30)
        context.insert(place)
        let named = insertVisit(context, at: origin, hours: 20...23)
        let past = insertVisit(context, at: offset(origin, north: 45), hours: 0...7)
        let movedAway = insertVisit(context, at: offset(origin, north: -20), hours: 8...9)
        context.insert(PlaceCorrectionEvent(
            visitPlaceID: movedAway.id,
            fromKnownPlaceID: place.id,
            fromAutoLabel: nil,
            toKnownPlaceID: nil,
            latitude: movedAway.latitude,
            longitude: movedAway.longitude,
            arrivalHour: 8,
            weekday: 2,
            stayDuration: 3600
        ))
        try context.save()

        try repository.assign(named, to: place, source: .user, confidence: 1)

        XCTAssertEqual(past.knownPlace?.id, place.id)
        XCTAssertNil(movedAway.knownPlace)
        XCTAssertEqual(place.centerLatitude, origin.latitude, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(place.footprintRadius, distance(origin, past.coordinate))
    }

    // MARK: D. One label per real place in history

    func testHistoryTakesOneLabelPerPlaceAndASecondPassChangesNothing() throws {
        let (_, context, _) = try makeRepository()
        let longest = insertVisit(context, at: origin, hours: 0...10, label: "24 Example Street")
        let others = [
            insertVisit(context, at: offset(origin, north: 20), hours: 11...12, label: "48 Example Street"),
            insertVisit(context, at: offset(origin, north: -25), hours: 13...15, label: "92 Other Road"),
            insertVisit(context, at: offset(origin, east: 30), hours: 16...17, label: "135-137-139 Example Street"),
        ]
        let farAway = insertVisit(context, at: offset(origin, north: 900), hours: 18...19, label: "Park")
        let named = insertVisit(context, at: offset(origin, north: 10), hours: 19...20, label: "Something")
        named.userLabel = "My Spot"
        try context.save()

        XCTAssertEqual(try TimelineSchemaUpgrader.unifyAutomaticLabels(in: context), 3)
        XCTAssertEqual(Set((others + [longest]).map(\.autoLabel)), ["24 Example Street"])
        XCTAssertEqual(farAway.autoLabel, "Park")
        XCTAssertEqual(named.autoLabel, "Something")
        XCTAssertEqual(try TimelineSchemaUpgrader.unifyAutomaticLabels(in: context), 0)
    }

    // MARK: E. Addresses copied across a kilometre

    func testKilometreCellsFillOnlyCountryCityAndArea() throws {
        let (_, context, _) = try makeRepository()
        let visit = insertVisit(context, at: origin, hours: 9...10)
        try context.save()
        let region = PlaceGeocodeRegion(
            countryCode: "DE",
            locality: "Berlin",
            administrativeArea: "Berlin",
            name: "Some Café",
            thoroughfare: "24 Example Street",
            formattedAddress: "24 Example Street, Berlin, Germany"
        )
        try PlaceGeocodeBackfill.apply(region, cellKey: PlaceGeocodeCellCache.cellKey(for: origin), in: context)
        XCTAssertEqual(visit.locality, "Berlin")
        XCTAssertNil(visit.thoroughfare)
        XCTAssertNil(visit.formattedAddress)

        try PlaceGeocodeBackfill.applyName(region, cellKey: PlaceGeocodeCellCache.nameCellKey(for: origin), in: context)
        XCTAssertEqual(visit.formattedAddress, "24 Example Street, Berlin, Germany")
        XCTAssertEqual(visit.thoroughfare, "24 Example Street")
    }

    func testACountryIsNeverWrittenAsTheCity() throws {
        let (_, context, _) = try makeRepository()
        let fresh = insertVisit(context, at: origin, hours: 9...10)
        let written = insertVisit(context, at: offset(origin, north: 3_000), hours: 11...12)
        written.countryCode = "DE"
        written.locality = "Germany"
        let real = insertVisit(context, at: offset(origin, north: 6_000), hours: 13...14)
        real.countryCode = "DE"
        real.locality = "Berlin"
        let place = KnownPlace(name: "Hotel", latitude: origin.latitude, longitude: origin.longitude)
        place.countryCode = "DE"
        place.locality = "DE"
        context.insert(place)
        try context.save()

        let region = PlaceGeocodeRegion(countryCode: "DE", locality: "Germany", administrativeArea: "Brandenburg")
        try PlaceGeocodeBackfill.apply(region, cellKey: PlaceGeocodeCellCache.cellKey(for: origin), in: context)
        XCTAssertEqual(fresh.countryCode, "DE")
        XCTAssertNil(fresh.locality)
        XCTAssertEqual(fresh.administrativeArea, "Brandenburg")

        XCTAssertEqual(try TimelineSchemaUpgrader.clearCountryNamedCities(in: context), 2)
        XCTAssertNil(written.locality)
        XCTAssertNil(place.locality)
        XCTAssertEqual(real.locality, "Berlin")
        XCTAssertTrue(PlaceGeocodeRegion.isCountryName("Türkiye", countryCode: "TR"))
        XCTAssertFalse(PlaceGeocodeRegion.isCountryName("Istanbul", countryCode: "TR"))
    }

    func testAddressesCopiedAcrossDistantStaysAreCleared() throws {
        let (_, context, _) = try makeRepository()
        let copied = "24 Example Street, Berlin, Germany"
        let spread = [0.0, 500, 900].map { north -> VisitPlace in
            let visit = insertVisit(context, at: offset(origin, north: north), hours: 9...10)
            visit.formattedAddress = copied
            visit.thoroughfare = "24 Example Street"
            return visit
        }
        let together = [0.0, 20].map { east -> VisitPlace in
            let visit = insertVisit(context, at: offset(offset(origin, north: 2_000), east: east), hours: 11...12)
            visit.formattedAddress = "7 Real Road, Berlin, Germany"
            return visit
        }
        let place = KnownPlace(name: "Hotel", latitude: origin.latitude, longitude: origin.longitude)
        place.formattedAddress = copied
        context.insert(place)
        try context.save()

        XCTAssertEqual(try TimelineSchemaUpgrader.clearCellCopiedAddresses(in: context), 7)
        XCTAssertTrue(spread.allSatisfy { $0.formattedAddress == nil && $0.thoroughfare == nil })
        XCTAssertTrue(together.allSatisfy { $0.formattedAddress == "7 Real Road, Berlin, Germany" })
        XCTAssertNil(place.formattedAddress)
        XCTAssertEqual(try TimelineSchemaUpgrader.clearCellCopiedAddresses(in: context), 0)
        // The cleared stays are queued for the ~100 m backfill.
        let work = try PlaceGeocodeBackfill.pendingNameWork(in: context)
        XCTAssertTrue(spread.allSatisfy { visit in
            work.contains { $0.cellKey == PlaceGeocodeCellCache.nameCellKey(for: visit.coordinate) }
        })
    }

    // MARK: F. Duplicate confirmed places

    func testTwinPlacesMergeIntoTheEarliestAndOthersAreLeftAlone() throws {
        let (_, context, _) = try makeRepository()
        let original = KnownPlace(name: "Home", latitude: origin.latitude, longitude: origin.longitude, footprintRadius: 30)
        original.createdAt = day(hour: 1)
        let twin = KnownPlace(name: "home", latitude: offset(origin, north: 18).latitude, longitude: origin.longitude, footprintRadius: 150)
        twin.createdAt = day(hour: 5)
        let otherHome = KnownPlace(name: "Home", latitude: offset(origin, north: 2_000).latitude, longitude: origin.longitude)
        let cafe = KnownPlace(name: "Café", latitude: origin.latitude, longitude: origin.longitude)
        [original, twin, otherHome, cafe].forEach(context.insert)
        let visit = insertVisit(context, at: origin, hours: 9...10)
        visit.knownPlace = twin
        visit.assignmentSource = .user
        let event = PlaceCorrectionEvent(
            visitPlaceID: visit.id,
            fromKnownPlaceID: nil,
            fromAutoLabel: nil,
            toKnownPlaceID: twin.id,
            latitude: visit.latitude,
            longitude: visit.longitude,
            arrivalHour: 9,
            weekday: 2,
            stayDuration: 3600
        )
        context.insert(event)
        try context.save()
        let originalID = original.id

        XCTAssertEqual(try TimelineSchemaUpgrader.mergeDuplicateKnownPlaces(in: context), 1)
        let remaining = try context.fetch(FetchDescriptor<KnownPlace>())
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(visit.knownPlace?.id, originalID)
        XCTAssertEqual(event.toKnownPlaceID, originalID)
        XCTAssertEqual(try TimelineSchemaUpgrader.mergeDuplicateKnownPlaces(in: context), 0)
    }

    func testNamingAPlaceAgainNearbyReusesIt() throws {
        let (repository, context, _) = try makeRepository()
        let first = insertVisit(context, at: origin, hours: 9...10)
        let later = insertVisit(context, at: offset(origin, north: 200), hours: 20...22)
        try context.save()
        let place = try repository.createKnownPlace(from: first, name: "Home")
        let again = try repository.createKnownPlace(from: later, name: "home")
        XCTAssertEqual(again.id, place.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KnownPlace>()), 1)
    }

    func testFreshInstallDoesNotRebuildPlacesForStaysAlreadyAssigned() throws {
        let (_, context, _) = try makeRepository()
        // Synced from iCloud before the place it belongs to.
        let synced = insertVisit(context, at: origin, hours: 9...10)
        synced.userLabel = "Home"
        synced.assignmentSource = .user
        let legacy = insertVisit(context, at: offset(origin, north: 3_000), hours: 11...12)
        legacy.userLabel = "Studio"
        try context.save()

        try TimelineSchemaUpgrader.upgrade(in: context, from: 0)

        XCTAssertEqual(try context.fetch(FetchDescriptor<KnownPlace>()).map(\.name), ["Studio"])
        XCTAssertNil(synced.knownPlace)
    }

    // MARK: H. Footprint holds its visits

    func testSmallHistoryFootprintReachesItsFarthestVisit() {
        let visits = (0..<12).map { index in
            PlaceLearningEngine.VisitSnapshot(
                latitude: offset(origin, north: index == 0 ? 90 : Double(index)).latitude,
                longitude: origin.longitude,
                horizontalAccuracy: 10,
                arrivalDate: day(hour: index),
                departureDate: day(hour: index, minute: 50)
            )
        }
        let footprint = PlaceLearningEngine.learnedFootprint(from: visits)
        let center = CLLocationCoordinate2D(latitude: footprint.centerLatitude, longitude: footprint.centerLongitude)
        for visit in visits {
            XCTAssertLessThanOrEqual(distance(center, visit.coordinate), footprint.footprintRadius)
        }
        // A long history keeps the 90th percentile, so one stray stay does not stretch it.
        let long = (0..<40).map { index in
            PlaceLearningEngine.VisitSnapshot(
                latitude: offset(origin, north: index == 0 ? 140 : Double(index % 10)).latitude,
                longitude: origin.longitude,
                horizontalAccuracy: 10,
                arrivalDate: day(hour: 0).addingTimeInterval(Double(index) * 3600),
                departureDate: nil
            )
        }
        XCTAssertLessThan(PlaceLearningEngine.learnedFootprint(from: long).footprintRadius, 60)
    }

    // MARK: Helpers

    private func stay(
        at coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        hours: ClosedRange<Int>,
        label: String?
    ) -> PlaceLearningEngine.StaySnapshot {
        PlaceLearningEngine.StaySnapshot(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy,
            arrivalDate: day(hour: hours.lowerBound),
            departureDate: day(hour: hours.upperBound),
            label: label
        )
    }

    @discardableResult
    private func insertVisit(
        _ context: ModelContext,
        at coordinate: CLLocationCoordinate2D,
        hours: ClosedRange<Int>,
        accuracy: Double = 12,
        label: String? = nil
    ) -> VisitPlace {
        let visit = VisitPlace(
            arrivalDate: day(hour: hours.lowerBound),
            departureDate: day(hour: hours.upperBound),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy,
            autoLabel: label
        )
        context.insert(visit)
        return visit
    }
}

// MARK: - Measurement on a copy of a real store

/// Measures the repairs on a copy of a real store. Set `MOVES_PLACE_IDENTITY_REAL_STORE`
/// to a directory holding `default.store` (and its -wal/-shm); it is copied before use.
/// `MOVES_PLACE_IDENTITY_FOCUS` ("lat,lon") names one place to report on. Results are
/// printed only, so no real names or coordinates live in the repository.
@MainActor
final class PlaceIdentityRealStoreTests: XCTestCase {
    func testMeasureRepairsOnRealStoreCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["MOVES_PLACE_IDENTITY_REAL_STORE"], !source.isEmpty else {
            throw XCTSkip("No real store copy given")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source).appendingPathComponent("default.store" + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let schema = Schema(MovesTimelineSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let liveStart = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z")!
        let rowsBefore = try context.fetchCount(FetchDescriptor<VisitPlace>())

        func report(_ label: String) throws {
            let visits = try context.fetch(FetchDescriptor<VisitPlace>()).filter { $0.arrivalDate >= liveStart }
            for radius in [60.0, 100.0] {
                let (groups, surplus) = Self.surplusNames(visits, within: radius)
                print("PLACEID \(label): \(groups) groups within \(Int(radius)) m carry more than one name, \(surplus) surplus names (\(visits.count) live stays)")
            }
        }

        try report("before")
        let focus = Self.focusCoordinate()
        if let focus {
            try reportFocus(focus, in: context, liveStart: liveStart, label: "before")
        }

        let cleared = try TimelineSchemaUpgrader.clearCellCopiedAddresses(in: context)
        print("PLACEID E: \(cleared) address fields cleared")
        print("PLACEID E: \(try TimelineSchemaUpgrader.clearCountryNamedCities(in: context)) country-named cities cleared")
        let work = try PlaceGeocodeBackfill.pendingNameWork(in: context)
        print("PLACEID E: \(work.count) ~100 m cells queued for the name backfill (1 per second)")
        let merged = try TimelineSchemaUpgrader.mergeDuplicateKnownPlaces(in: context)
        print("PLACEID F: \(merged) duplicate places merged; \(try context.fetchCount(FetchDescriptor<KnownPlace>())) places remain")
        let relabeled = try TimelineSchemaUpgrader.unifyAutomaticLabels(in: context)
        print("PLACEID D: \(relabeled) labels changed; second pass changes \(try TimelineSchemaUpgrader.unifyAutomaticLabels(in: context))")
        try report("after D")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitPlace>()), rowsBefore)

        guard let focus else { return }
        try reportFocus(focus, in: context, liveStart: liveStart, label: "after D")

        // C: name the focus place once from its longest stay.
        context.undoManager = UndoManager()
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let candidates = try context.fetch(FetchDescriptor<VisitPlace>()).filter {
            $0.knownPlace == nil && $0.assignmentSource == .none
                && PlaceLearningEngine.distance(from: $0.coordinate, to: focus) <= 60
        }
        guard let seed = candidates.max(by: { $0.stayDuration() < $1.stayDuration() }) else { return }
        let place = try repository.createKnownPlace(from: seed, name: "Focus place")
        let assigned = place.visits.count
        let stillOutside = try context.fetch(FetchDescriptor<VisitPlace>()).filter {
            $0.knownPlace == nil && $0.arrivalDate >= liveStart
                && PlaceLearningEngine.distance(from: $0.coordinate, to: focus) <= 200
                && $0.stayDuration() >= 6 * 3600
        }.count
        print("PLACEID C: naming once assigned \(assigned) stays (radius \(Int(place.footprintRadius)) m); \(stillOutside) stays of 6 h or more within 200 m stay unassigned")
        context.undoManager?.undo()
        print("PLACEID C: after Undo \(try context.fetch(FetchDescriptor<VisitPlace>()).filter { $0.knownPlace?.name == "Focus place" }.count) stays remain assigned")
    }

    private func reportFocus(
        _ focus: CLLocationCoordinate2D,
        in context: ModelContext,
        liveStart: Date,
        label: String
    ) throws {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>()).filter {
            $0.arrivalDate >= liveStart && $0.knownPlace == nil
                && PlaceLearningEngine.distance(from: $0.coordinate, to: focus) <= 200
        }
        let names = Set(visits.compactMap { PlaceDisplayNamer.meaningful($0.userLabel ?? $0.autoLabel) }.map(PlaceDisplayNamer.labelComparisonKey))
        let nights = visits.filter { $0.stayDuration() >= 6 * 3600 }
        print("PLACEID focus \(label): \(visits.count) stays within 200 m, \(names.count) names; \(nights.count) stays of 6 h or more")
        guard label == "before" else { return }

        // B: stored centre versus the robust centre from each long stay's own fixes.
        let repository = SwiftDataTimelineRepository(modelContext: context)
        var stored: [CLLocationCoordinate2D] = []
        var robust: [CLLocationCoordinate2D] = []
        for visit in nights {
            stored.append(visit.coordinate)
            let end = visit.departureDate ?? visit.arrivalDate
            let fixes = try repository.samples(from: visit.arrivalDate, to: end)
                .filter { $0.source != .photoLibrary }
                .map { (latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.horizontalAccuracy) }
            robust.append(PlaceLearningEngine.robustCenter(of: fixes) ?? visit.coordinate)
        }
        for (name, centres) in [("stored", stored), ("robust", robust)] {
            let distances = centres.map { PlaceLearningEngine.distance(from: Self.medianPoint(centres), to: $0) }.sorted()
            guard !distances.isEmpty else { continue }
            print("PLACEID B \(name) centres of \(centres.count) long stays: median \(Int(PlaceLearningEngine.median(distances))) m, max \(Int(distances.last ?? 0)) m from their median point")
        }
    }

    private static func medianPoint(_ points: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: PlaceLearningEngine.median(points.map(\.latitude)),
            longitude: PlaceLearningEngine.median(points.map(\.longitude))
        )
    }

    private static func focusCoordinate() -> CLLocationCoordinate2D? {
        guard let raw = ProcessInfo.processInfo.environment["MOVES_PLACE_IDENTITY_FOCUS"] else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    /// Stays linked within `radius` of each other form a group; a group showing n
    /// different names has n − 1 surplus names.
    static func surplusNames(_ visits: [VisitPlace], within radius: CLLocationDistance) -> (groups: Int, surplus: Int) {
        var parent = Array(visits.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for lhs in visits.indices {
            for rhs in visits.indices where rhs > lhs {
                if PlaceLearningEngine.distance(from: visits[lhs].coordinate, to: visits[rhs].coordinate) <= radius {
                    parent[root(lhs)] = root(rhs)
                }
            }
        }
        var names: [Int: Set<String>] = [:]
        for index in visits.indices {
            let visit = visits[index]
            let shown = PlaceDisplayNamer.meaningful(visit.knownPlace?.name)
                ?? PlaceDisplayNamer.meaningful(visit.userLabel)
                ?? PlaceDisplayNamer.meaningful(visit.autoLabel)
            guard let shown else { continue }
            names[root(index), default: []].insert(PlaceDisplayNamer.labelComparisonKey(shown))
        }
        let multi = names.values.filter { $0.count > 1 }
        return (multi.count, multi.reduce(0) { $0 + $1.count - 1 })
    }
}

// MARK: - Shared helpers

private struct IdentityStubMotionClassifier: MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> (mode: TransportMode, confidence: Double) {
        (.walking, 0.9)
    }

    func stepCount(start: Date, end: Date) async -> Int? { nil }
}

private struct IdentityStubResolver: PlaceNameResolver {
    let name: String?

    func resolveName(for coordinate: CLLocationCoordinate2D) async -> String? { name }
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(MovesTimelineSchema.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [configuration])
}

@MainActor
private func makeContext() throws -> (ModelContext, ModelContainer) {
    let container = try makeContainer()
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return (context, container)
}

@MainActor
private func makeRepository() throws -> (SwiftDataTimelineRepository, ModelContext, ModelContainer) {
    let (context, container) = try makeContext()
    context.undoManager = UndoManager()
    return (SwiftDataTimelineRepository(modelContext: context), context, container)
}

private var gmt: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// 15 Sep 2026 in GMT, a few days before now so nothing reads as open.
private func day(hour: Int, minute: Int = 0) -> Date {
    gmt.date(from: DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2026,
        month: 9,
        day: 15,
        hour: hour,
        minute: minute
    ))!
}

private func offset(
    _ coordinate: CLLocationCoordinate2D,
    north: Double = 0,
    east: Double = 0
) -> CLLocationCoordinate2D {
    let perDegreeLatitude = 111_320.0
    let perDegreeLongitude = perDegreeLatitude * cos(coordinate.latitude * .pi / 180)
    return CLLocationCoordinate2D(
        latitude: coordinate.latitude + north / perDegreeLatitude,
        longitude: coordinate.longitude + east / perDegreeLongitude
    )
}

private func distance(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
    PlaceLearningEngine.distance(from: lhs, to: rhs)
}
