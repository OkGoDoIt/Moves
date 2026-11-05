import CoreLocation
import Foundation
import SwiftData
import XCTest
@testable import Moves

/// Photo-history clustering and persistence. Uses `FakePhotoAssetProvider` —
/// never the simulator photo library.
final class PhotoHistoryImporterTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
    private let cafe = CLLocationCoordinate2D(latitude: 52.5246, longitude: 13.4050)
    private let saigon = CLLocationCoordinate2D(latitude: 10.8231, longitude: 106.6297)
    private let epoch = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 00:00 UTC

    private var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - Clustering

    func testTwoPhotosFiveMinutesApartBecomeOneStay() {
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(5 * 60), coordinate: home),
        ]
        let stays = PhotoHistoryImporter.clusterStays(assets)
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays[0].assets.count, 2)
        XCTAssertEqual(stays[0].duration, 5 * 60, accuracy: 1)
    }

    func testNinetyMinuteGapSplitsSamePlaceIntoTwoStays() {
        let assets = [
            photo("a1", at: epoch, coordinate: home),
            photo("a2", at: epoch.addingTimeInterval(10 * 60), coordinate: home),
            photo("b1", at: epoch.addingTimeInterval(10 * 60 + 91 * 60), coordinate: home),
            photo("b2", at: epoch.addingTimeInterval(10 * 60 + 100 * 60), coordinate: home),
        ]
        let stays = PhotoHistoryImporter.clusterStays(assets)
        XCTAssertEqual(stays.count, 2, "A 90-minute gap starts a new stay even at the same spot")
    }

    func testDistanceOver500MetersStartsANewStay() {
        let far = offset(home, northMeters: 620)
        let assets = [
            photo("h1", at: epoch, coordinate: home),
            photo("h2", at: epoch.addingTimeInterval(4 * 60), coordinate: home),
            photo("c1", at: epoch.addingTimeInterval(8 * 60), coordinate: far),
            photo("c2", at: epoch.addingTimeInterval(12 * 60), coordinate: far),
        ]
        let stays = PhotoHistoryImporter.clusterStays(assets)
        XCTAssertEqual(stays.count, 2)
        let timeline = PhotoHistoryImporter.segment(assets)
        XCTAssertEqual(timeline.moves.count, 1)
        XCTAssertEqual(timeline.moves[0].transportMode, .unknown)
        XCTAssertEqual(timeline.stays.count, 2)
    }

    func testSinglePhotosDoNotBecomeStays() {
        let assets = [
            photo("solo", at: epoch, coordinate: home),
            photo("elsewhere", at: epoch.addingTimeInterval(30 * 60), coordinate: cafe),
        ]
        XCTAssertTrue(PhotoHistoryImporter.clusterStays(assets).isEmpty)
    }

    func testTwentyMinuteSpanWithTwoPhotosQualifies() {
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(20 * 60), coordinate: home),
        ]
        XCTAssertEqual(PhotoHistoryImporter.clusterStays(assets).count, 1)
    }

    func testPlaneSpeedBetweenClusters() {
        let assets = [
            photo("h1", at: epoch, coordinate: home),
            photo("h2", at: epoch.addingTimeInterval(5 * 60), coordinate: home),
            photo("s1", at: epoch.addingTimeInterval(8 * 60 * 60), coordinate: saigon),
            photo("s2", at: epoch.addingTimeInterval(8 * 60 * 60 + 5 * 60), coordinate: saigon),
        ]
        let timeline = PhotoHistoryImporter.segment(assets)
        XCTAssertEqual(timeline.stays.count, 2)
        XCTAssertEqual(timeline.moves.count, 1)
        XCTAssertEqual(timeline.moves[0].transportMode, .plane)
    }

    func testProviderFiltersToIntervalAndGeotaggedOnly() async throws {
        let provider = FakePhotoAssetProvider(assets: [
            photo("in", at: epoch.addingTimeInterval(60), coordinate: home),
            photo("out", at: epoch.addingTimeInterval(10_000), coordinate: home),
            PhotoAssetDescriptor(localIdentifier: "nogeo", capturedAt: epoch.addingTimeInterval(90), latitude: nil, longitude: nil),
        ])
        let interval = DateInterval(start: epoch, end: epoch.addingTimeInterval(3_600))
        let fetched = try await provider.geotaggedAssets(in: interval)
        XCTAssertEqual(fetched.map(\.localIdentifier), ["in"])
    }

    func testPreviewDoesNotRequireAPhotoLibrary() {
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(5 * 60), coordinate: home),
        ]
        let preview = PhotoHistoryImporter.preview(
            assets: assets,
            in: DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))
        )
        XCTAssertEqual(preview.geotaggedPhotoCount, 2)
        XCTAssertEqual(preview.estimatedVisitCount, 1)
        XCTAssertEqual(preview.dayCount, 1)
        XCTAssertTrue(preview.summary.contains("geotagged photos"))
    }

    // MARK: - Persistence

    func testImportCreatesPhotoInferredVisitAndAttachments() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(6 * 60), coordinate: home),
        ]

        let report = try importer.importHistory(
            assets: assets,
            in: DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))
        )

        XCTAssertEqual(report.createdVisitCount, 1)
        XCTAssertEqual(report.attachedPhotoCount, 2)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits[0].origin, .photoInferred)
        XCTAssertEqual(visits[0].photoAttachments.count, 2)
        let samples = try context.fetch(FetchDescriptor<LocationSample>())
        XCTAssertTrue(samples.allSatisfy { $0.source == .photoLibrary })
        XCTAssertFalse(LocationSampleSource.photoLibrary.isRouteTrack)
    }

    func testIsolatedPhotoImportsWithoutForcingAStay() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)

        let report = try importer.importHistory(
            assets: [photo("solo", at: epoch, coordinate: home)],
            in: DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))
        )

        XCTAssertEqual(report.createdVisitCount, 0)
        XCTAssertEqual(report.attachedPhotoCount, 1)
        XCTAssertEqual(report.dayOnlyAttachmentCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, 0)
    }

    func testPhotosInsideAMultiDayVisitAttachWithoutAddingAVisit() throws {
        let (context, _) = try makeContext()
        let day = DayTimeline(dayStart: epoch)
        context.insert(day)
        let hotel = VisitPlace(
            arrivalDate: epoch,
            departureDate: epoch.addingTimeInterval(3 * 24 * 60 * 60),
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 12
        )
        hotel.origin = .sensor
        hotel.dayTimeline = day
        context.insert(hotel)
        try context.save()

        // Far enough past the arrival to fall on another day in any time zone.
        let nextDay = epoch.addingTimeInterval(36 * 60 * 60)
        let far = offset(home, northMeters: 900)
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let report = try importer.importHistory(
            assets: [
                photo("hotel-1", at: nextDay, coordinate: home),
                photo("hotel-2", at: nextDay.addingTimeInterval(5 * 60), coordinate: home),
                photo("museum-1", at: nextDay.addingTimeInterval(30 * 60), coordinate: far),
                photo("museum-2", at: nextDay.addingTimeInterval(35 * 60), coordinate: far),
            ],
            in: DateInterval(start: epoch, end: epoch.addingTimeInterval(4 * 24 * 60 * 60))
        )

        XCTAssertEqual(report.createdVisitCount, 0)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(visits.map(\.id), [hotel.id])
        XCTAssertEqual(Set(hotel.photoAttachments.map(\.assetLocalIdentifier)), ["hotel-1", "hotel-2"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAttachment>()).count, 4)
    }

    func testImportCreatesEstimatedUnknownMoveUnlessPlane() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let far = offset(home, northMeters: 800)
        let assets = [
            photo("h1", at: epoch, coordinate: home),
            photo("h2", at: epoch.addingTimeInterval(4 * 60), coordinate: home),
            photo("c1", at: epoch.addingTimeInterval(20 * 60), coordinate: far),
            photo("c2", at: epoch.addingTimeInterval(24 * 60), coordinate: far),
        ]

        _ = try importer.importHistory(
            assets: assets,
            in: DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))
        )

        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].origin, .photoInferred)
        XCTAssertEqual(moves[0].routeMatchConfidence, .estimated)
        XCTAssertEqual(moves[0].transportMode, .unknown)
    }

    func testSensorDayOverlapAttachesOnly() throws {
        let (context, _) = try makeContext()
        let day = DayTimeline(dayStart: epoch)
        context.insert(day)
        let recorded = VisitPlace(
            arrivalDate: epoch,
            departureDate: epoch.addingTimeInterval(2 * 60 * 60),
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 12
        )
        recorded.origin = .sensor
        recorded.dayTimeline = day
        context.insert(recorded)
        try context.save()

        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let far = offset(home, northMeters: 900)
        let assets = [
            photo("at-home", at: epoch.addingTimeInterval(30 * 60), coordinate: home),
            photo("h2", at: epoch.addingTimeInterval(35 * 60), coordinate: home),
            photo("elsewhere-1", at: epoch.addingTimeInterval(50 * 60), coordinate: far),
            photo("elsewhere-2", at: epoch.addingTimeInterval(55 * 60), coordinate: far),
        ]

        let report = try importer.importHistory(
            assets: assets,
            in: DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3 * 60 * 60))
        )

        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(visits.count, 1, "Sensor days must not gain inferred visits")
        XCTAssertEqual(visits[0].id, recorded.id)
        XCTAssertEqual(visits[0].origin, .sensor)
        XCTAssertEqual(visits[0].arrivalDate, epoch)
        XCTAssertEqual(visits[0].departureDate, epoch.addingTimeInterval(2 * 60 * 60))
        XCTAssertGreaterThanOrEqual(report.attachedPhotoCount, 2)
        XCTAssertGreaterThan(report.sensorDaySkipCount, 0)
        XCTAssertEqual(visits[0].photoAttachments.count, 2, "Photos at the recorded visit attach to it")
        let dayOnly = try context.fetch(FetchDescriptor<PhotoAttachment>()).filter { $0.visitPlace == nil }
        XCTAssertEqual(dayOnly.count, 2, "Photos that do not match a visit attach to the day only")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MoveSegment>()).count, 0)
    }

    func testReimportIsIdempotent() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(8 * 60), coordinate: home),
        ]
        let interval = DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))

        _ = try importer.importHistory(assets: assets, in: interval)
        let report = try importer.importHistory(assets: assets, in: interval)

        XCTAssertEqual(report.createdVisitCount, 0)
        XCTAssertEqual(report.attachedPhotoCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VisitPlace>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAttachment>()).count, 2)
    }

    func testAttachMatchesVisitByTimeAndDistance() throws {
        let (context, _) = try makeContext()
        let day = DayTimeline(dayStart: epoch)
        context.insert(day)
        let visit = VisitPlace(
            arrivalDate: epoch.addingTimeInterval(60),
            departureDate: epoch.addingTimeInterval(40 * 60),
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 15
        )
        visit.dayTimeline = day
        context.insert(visit)
        try context.save()

        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let nearby = offset(home, northMeters: 80)
        let tooFar = offset(home, northMeters: 500)
        let attached = try importer.attachPhotos([
            photo("near", at: epoch.addingTimeInterval(10 * 60), coordinate: nearby),
            photo("far", at: epoch.addingTimeInterval(12 * 60), coordinate: tooFar),
        ])

        XCTAssertEqual(attached, 2)
        XCTAssertEqual(visit.photoAttachments.count, 1)
        XCTAssertEqual(visit.photoAttachments.first?.assetLocalIdentifier, "near")
        let dayOnly = try context.fetch(FetchDescriptor<PhotoAttachment>()).filter { $0.visitPlace == nil }
        XCTAssertEqual(dayOnly.map(\.assetLocalIdentifier), ["far"])
    }

    func testPlaceLearningRunsOnNewPhotoVisits() throws {
        let (context, _) = try makeContext()
        let known = KnownPlace(name: "Home", latitude: home.latitude, longitude: home.longitude, footprintRadius: 40)
        known.confirmedVisitCount = 4
        context.insert(known)
        try context.save()

        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        _ = try importer.importHistory(
            assets: [
                photo("a", at: epoch.addingTimeInterval(9 * 60 * 60), coordinate: home),
                photo("b", at: epoch.addingTimeInterval(9 * 60 * 60 + 8 * 60), coordinate: home),
            ],
            in: DateInterval(start: epoch, end: epoch.addingTimeInterval(24 * 60 * 60))
        )

        let visit = try context.fetch(FetchDescriptor<VisitPlace>()).first
        XCTAssertEqual(visit?.assignmentSource, .auto)
        XCTAssertEqual(visit?.knownPlace?.id, known.id)
        XCTAssertEqual(known.confirmedVisitCount, 4, "Auto assignment must not teach the place")
    }

    func testProtectedDayIgnoresPhotoOnlySamples() throws {
        let (context, _) = try makeContext()
        let day = DayTimeline(dayStart: epoch)
        context.insert(day)
        let visit = VisitPlace(
            arrivalDate: epoch,
            departureDate: epoch.addingTimeInterval(20 * 60),
            latitude: home.latitude,
            longitude: home.longitude,
            horizontalAccuracy: 20
        )
        visit.origin = .photoInferred
        visit.dayTimeline = day
        context.insert(visit)
        try context.save()

        XCTAssertFalse(day.isProtectedFromPhotoBackfill)
    }

    func testVisitAttachmentsAreQueryableByTripDateRange() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let visitPhotos = [
            photo("stay-a", at: epoch.addingTimeInterval(10 * 60 * 60), coordinate: home),
            photo("stay-b", at: epoch.addingTimeInterval(10 * 60 * 60 + 8 * 60), coordinate: home),
        ]
        _ = try importer.importHistory(
            assets: visitPhotos,
            in: DateInterval(start: epoch, end: epoch.addingTimeInterval(24 * 60 * 60))
        )

        let visit = try XCTUnwrap(try context.fetch(FetchDescriptor<VisitPlace>()).first)
        XCTAssertEqual(visit.photoAttachments.count, 2)

        let tripRange = DateInterval(
            start: epoch.addingTimeInterval(9 * 60 * 60),
            end: epoch.addingTimeInterval(12 * 60 * 60)
        )
        let inRange = try PhotoAttachmentQuery.photos(in: tripRange, context: context)
        XCTAssertEqual(inRange.map(\.assetLocalIdentifier), ["stay-a", "stay-b"])
        XCTAssertEqual(PhotoAttachmentQuery.coverPhoto(from: inRange)?.assetLocalIdentifier, "stay-a")
        XCTAssertTrue(inRange.allSatisfy { $0.visitPlace?.id == visit.id })

        let beforeVisit = DateInterval(start: epoch, end: epoch.addingTimeInterval(60 * 60))
        XCTAssertTrue(try PhotoAttachmentQuery.photos(in: beforeVisit, context: context).isEmpty)
    }

    // MARK: - Helpers

    private func makeContext() throws -> (ModelContext, ModelContainer) {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return (context, container)
    }

    private func photo(
        _ identifier: String,
        at date: Date,
        coordinate: CLLocationCoordinate2D
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            localIdentifier: identifier,
            capturedAt: date,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func offset(
        _ coordinate: CLLocationCoordinate2D,
        northMeters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        let delta = northMeters / 111_320
        return CLLocationCoordinate2D(latitude: coordinate.latitude + delta, longitude: coordinate.longitude)
    }
}
