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

    // MARK: - Resumable import

    func testInterruptedImportResumesToTheSameTimeline() async throws {
        let assets = libraryAcrossManyDays()
        let interval = DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(90 * 24 * 3_600))

        // One uninterrupted pass over everything is the reference.
        let (wholeContext, _) = try makeContext()
        let camera = assets.filter(\.isCameraCapture)
        _ = try PhotoHistoryImporter(modelContext: wholeContext, calendar: gmt).importHistory(assets: camera, in: interval)
        let expected = try snapshot(wholeContext)
        XCTAssertGreaterThan(expected.visits.count, 10)
        XCTAssertGreaterThan(expected.moves, 0)

        // The same library in small steps, stopped and restarted along the way.
        let (_, container) = try makeContext()
        var runner = PhotoHistoryImportRunner(provider: FakePhotoAssetProvider(assets: assets), container: container)
        runner.pageSize = 9
        var job = try await runner.counted(job(over: interval))
        XCTAssertEqual(job.totalPhotoCount, assets.count)

        var steps = 0
        while job.state == .running {
            let saved = job
            job = try await runner.runStep(saved)
            if steps.isMultiple(of: 3) {
                // Moves was closed after the step saved but before its progress was
                // written down, so the step runs again from the older cursor.
                job = try await runner.runStep(saved)
            }
            // What survives a restart is the job as it is stored.
            let defaults = UserDefaults(suiteName: "photo-history-\(UUID().uuidString)")!
            let store = PhotoHistoryJobStore(defaults: defaults)
            store.save(job)
            job = try XCTUnwrap(store.load())
            XCTAssertLessThan(job.cursor, saved.cursor, "Every step reaches further back")
            steps += 1
            XCTAssertLessThan(steps, 200)
        }

        XCTAssertGreaterThan(steps, 5, "The library was imported in several steps")
        XCTAssertEqual(job.state, .finished)
        XCTAssertEqual(job.fractionComplete, 1)
        let resumed = try snapshot(ModelContext(container))
        XCTAssertEqual(resumed.visits, expected.visits)
        XCTAssertEqual(resumed.photos, expected.photos)
        XCTAssertEqual(resumed.moves, expected.moves)
        XCTAssertEqual(resumed.samples, expected.samples)
        XCTAssertFalse(resumed.photos.contains { $0.hasPrefix("saved") }, "Saved photos are left out")
        XCTAssertEqual(job.earliestPhotoAt, camera.map(\.capturedAt).min())
    }

    func testAnImportOutlivesTheVersionThatBeganIt() throws {
        let defaults = UserDefaults(suiteName: "photo-history-\(UUID().uuidString)")!
        // Exactly what an earlier version left behind.
        let saved = #"{"rangeEnd":798397200,"rangeStart":167158800,"cursor":781534444.688,"remainingPhotoCount":305617,"totalPhotoCount":319809,"state":"paused","report":{"reusedVisitCount":2,"attachedPhotoCount":11907,"dayOnlyAttachmentCount":315,"createdMoveCount":698,"geotaggedPhotoCount":11907,"sensorDaySkipCount":0,"createdVisitCount":751},"unfinishedStepStarts":0,"includesSavedPhotos":false,"earliestPhotoAt":781534444.688,"id":"6903FBE2-620E-41F3-8E3A-0FD5F520CC67"}"#
        defaults.set(Data(saved.utf8), forKey: PhotoHistoryJobStore.key)
        let job = try XCTUnwrap(PhotoHistoryJobStore(defaults: defaults).load())
        XCTAssertEqual(job.state, .paused)
        XCTAssertEqual(job.report.createdVisitCount, 751)
        XCTAssertEqual(job.checkedPhotoCount, 14_192)
        XCTAssertNotEqual(job.rules, PhotoHistoryJob.currentRules, "It read fewer photos than this version does")

        // One that had stopped on an error carries on.
        defaults.set(Data(saved.replacingOccurrences(of: "paused", with: "failed").utf8), forKey: PhotoHistoryJobStore.key)
        XCTAssertEqual(PhotoHistoryJobStore(defaults: defaults).load()?.state, .running)
    }

    func testPhotosThatKeepStoppingTheImportAreTakenInSmallerStepsAndThenPassedOver() async throws {
        let assets = libraryAcrossManyDays()
        let (_, container) = try makeContext()
        var runner = PhotoHistoryImportRunner(provider: FakePhotoAssetProvider(assets: assets), container: container)
        runner.pageSize = 64
        runner.minimumPageSize = 4
        let interval = DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(90 * 24 * 3_600))
        var job = try await runner.counted(job(over: interval))

        job.unfinishedStepStarts = 1
        let whole = try await runner.runStep(job)
        job.unfinishedStepStarts = PhotoHistoryImportRunner.triesAtFullSize + 1
        let smaller = try await runner.runStep(job)
        XCTAssertGreaterThan(smaller.cursor, whole.cursor, "A step that failed before takes fewer photos")
        XCTAssertLessThan(smaller.cursor, job.cursor)

        job.unfinishedStepStarts = PhotoHistoryImportRunner.triesBeforePassingOver + 1
        let past = try await runner.runStep(job)
        XCTAssertEqual(past.unreadablePhotoCount, 4)
        XCTAssertLessThan(past.cursor, job.cursor)
        XCTAssertEqual(past.unfinishedStepStarts, 0)
        XCTAssertEqual(past.state, .running)
    }

    func testAStepNeverEndsInTheMiddleOfAnOuting() {
        let outing = (0..<4).map { photo("a\($0)", at: epoch.addingTimeInterval(Double($0) * 600), coordinate: home) }
        let nextDay = (0..<3).map {
            photo("b\($0)", at: epoch.addingTimeInterval(86_400 + Double($0) * 600), coordinate: cafe)
        }
        let usable = outing + nextDay
        let page = PhotoAssetPage(assets: usable, scannedCount: 7, earliestScannedAt: usable.first?.capturedAt)

        // The page is full, so the oldest outing on it may have begun before the page did.
        let cut = PhotoHistoryPaging.batch(
            from: page, usable: usable, cursor: .distantFuture, start: .distantPast, limit: 7, stayGap: 90 * 60
        )
        XCTAssertEqual(cut?.assets.map(\.localIdentifier), nextDay.map(\.localIdentifier))
        XCTAssertEqual(cut?.nextCursor, nextDay[0].capturedAt, "The unfinished outing is read whole next time")
        XCTAssertEqual(cut?.isLast, false)

        // A page that is all one outing is not imported in pieces; it asks for a longer page.
        let onlyOuting = PhotoAssetPage(assets: outing, scannedCount: 4, earliestScannedAt: outing[0].capturedAt)
        XCTAssertNil(
            PhotoHistoryPaging.batch(
                from: onlyOuting, usable: outing, cursor: .distantFuture, start: .distantPast, limit: 4, stayGap: 90 * 60
            )
        )

        let last = PhotoHistoryPaging.batch(
            from: page, usable: usable, cursor: .distantFuture, start: .distantPast, limit: 8, stayGap: 90 * 60
        )
        XCTAssertEqual(last?.assets.count, 7)
        XCTAssertEqual(last?.isLast, true)
    }

    func testRemovedStopIsNotRebuiltFromItsPhotos() throws {
        let (context, _) = try makeContext()
        let importer = PhotoHistoryImporter(modelContext: context, calendar: gmt)
        let assets = [
            photo("a", at: epoch, coordinate: home),
            photo("b", at: epoch.addingTimeInterval(10 * 60), coordinate: home),
        ]
        let interval = DateInterval(start: epoch.addingTimeInterval(-1), end: epoch.addingTimeInterval(3_600))
        _ = try importer.importHistory(assets: assets, in: interval)
        let visit = try XCTUnwrap(try context.fetch(FetchDescriptor<VisitPlace>()).first)

        let repository = SwiftDataTimelineRepository(modelContext: context)
        repository.recordRemoval(of: visit)
        visit.keepPhotosOnDay()
        context.delete(visit)
        try context.save()

        let report = try importer.importHistory(assets: assets, in: interval)

        XCTAssertEqual(report.createdVisitCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VisitPlace>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoAttachment>()), 2, "The photos stay on the day")
    }

    // MARK: - Photos taken with this phone

    func testOnlyPhotosAddedWhenTheyWereTakenCountAsCameraPhotos() {
        XCTAssertTrue(PhotoCaptureClassifier.isCameraCapture(capturedAt: epoch, addedAt: epoch.addingTimeInterval(4)))
        XCTAssertFalse(
            PhotoCaptureClassifier.isCameraCapture(capturedAt: epoch, addedAt: epoch.addingTimeInterval(3 * 86_400)),
            "A photo saved days after it was taken came from somewhere else"
        )
        XCTAssertFalse(PhotoCaptureClassifier.isCameraCapture(capturedAt: epoch, addedAt: nil))
    }

    func testPhotoFixIsCheckedAgainstWhereThePhoneWas() {
        let now = epoch.addingTimeInterval(12 * 3_600)
        func fix(_ coordinate: CLLocationCoordinate2D, minutes: Double) -> RecordedFix {
            RecordedFix(
                date: epoch.addingTimeInterval(minutes * 60),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
        let acrossTown = offset(home, northMeters: 9_000)
        let atHomeAllAlong = [fix(home, minutes: -20), fix(home, minutes: 25)]

        // The phone sat at home before and after: a photo from across town is someone else's.
        XCTAssertEqual(
            PhotoFixPlausibility.verdict(for: photo("partner", at: epoch, coordinate: acrossTown), fixes: atHomeAllAlong),
            .reject
        )
        XCTAssertEqual(
            PhotoFixPlausibility.verdict(for: photo("mine", at: epoch, coordinate: cafe), fixes: atHomeAllAlong),
            .accept
        )
        // Tracking went quiet after leaving home: the photo is the news, not a contradiction.
        XCTAssertEqual(
            PhotoFixPlausibility.verdict(
                for: photo("out", at: epoch, coordinate: acrossTown),
                fixes: [fix(home, minutes: -40)]
            ),
            .accept
        )
        // Another continent minutes after a fix at home waits for the phone's own word,
        // and is refused when the phone turns out not to have gone.
        let abroad = photo("abroad", at: epoch, coordinate: saigon)
        XCTAssertEqual(PhotoFixPlausibility.verdict(for: abroad, fixes: [fix(home, minutes: -30)]), .wait)
        XCTAssertEqual(
            PhotoFixPlausibility.verdict(for: abroad, fixes: [fix(home, minutes: -30), fix(home, minutes: 400)]),
            .reject
        )
        // After a flight the phone's own fixes are a continent apart, and so may the photo be.
        XCTAssertEqual(
            PhotoFixPlausibility.verdict(
                for: photo("landed", at: epoch.addingTimeInterval(11 * 3_600), coordinate: saigon),
                fixes: [fix(home, minutes: 0), fix(saigon, minutes: 11 * 60 + 5)]
            ),
            .accept
        )

        // Saved photos, vague fixes, and photos already weighed are never offered.
        let saved = PhotoAssetDescriptor(
            localIdentifier: "saved", capturedAt: epoch, latitude: cafe.latitude, longitude: cafe.longitude,
            isCameraCapture: false
        )
        let vague = PhotoAssetDescriptor(
            localIdentifier: "vague", capturedAt: epoch, latitude: cafe.latitude, longitude: cafe.longitude,
            horizontalAccuracy: 900
        )
        let selection = PhotoFixSelection(
            photos: [saved, vague, abroad, photo("mine", at: epoch, coordinate: cafe), photo("seen", at: epoch, coordinate: cafe)],
            fixes: atHomeAllAlong,
            handled: ["seen": epoch],
            now: now
        )
        XCTAssertEqual(selection.accepted.map(\.localIdentifier), ["mine"])
        XCTAssertEqual(Set(selection.handled.keys), ["seen", "vague", "abroad", "mine"])
    }

    // MARK: - Whose phone took it

    func testLedgerSeparatesTwoPhonesByTheirFileCounters() {
        var entries: [CameraRollEntry] = []
        var mine: [CameraRollEntry] = []
        var theirs: [CameraRollEntry] = []
        // Two phones of any model share a library for three weeks. Mine also takes screenshots;
        // theirs starts a few numbers ahead of mine, the hardest place for it to be.
        for step in 0..<600 {
            let time = epoch.addingTimeInterval(Double(step) * 3_000)
            let own = CameraRollEntry(addedAt: time, number: (9_700 + step) % 10_000, isScreenshot: step % 25 == 0)
            entries.append(own)
            if !own.isScreenshot { mine.append(own) }
            if step % 3 == 0 {
                let other = CameraRollEntry(
                    addedAt: time.addingTimeInterval(700),
                    number: (9_712 + step / 3) % 10_000,
                    isScreenshot: false
                )
                entries.append(other)
                theirs.append(other)
            }
        }
        // My phone again after a pause and a burst I deleted, with no screenshot yet.
        let later = (0..<40).map {
            CameraRollEntry(addedAt: epoch.addingTimeInterval(2_400_000 + Double($0) * 60), number: 700 + $0, isScreenshot: false)
        }
        entries += later

        let ledger = OwnDeviceLedger(entries: entries.shuffled())

        let keptMine = mine.count { ledger.contains(addedAt: $0.addedAt, number: $0.number) }
        let keptTheirs = theirs.count { ledger.contains(addedAt: $0.addedAt, number: $0.number) }
        XCTAssertGreaterThan(Double(keptMine), 0.97 * Double(mine.count))
        XCTAssertLessThan(Double(keptTheirs), 0.05 * Double(theirs.count), "The other phone's photos are not mine")
        XCTAssertTrue(later.allSatisfy { ledger.contains(addedAt: $0.addedAt, number: $0.number) }, "A run that continues my counter is mine")
    }

    func testPhotoOriginFallsBackWhenTheLedgerCannotTell() {
        let added = epoch.addingTimeInterval(3)
        let photo = PhotoAssetDescriptor(
            localIdentifier: "p", capturedAt: epoch, latitude: home.latitude, longitude: home.longitude,
            addedAt: added, rollNumber: 4_317
        )
        // No file names at all, or a library without one screenshot: the older rule stands.
        XCTAssertTrue(photo.resolved(with: nil).isCameraCapture)
        XCTAssertTrue(photo.resolved(with: PhotoOriginLedger(entries: [])).isCameraCapture)
        func taken(_ step: Int, number: Int, isScreenshot: Bool) -> LibraryRollEntry {
            let time = added.addingTimeInterval(Double(step))
            return LibraryRollEntry(capturedAt: time, addedAt: time, number: number, isScreenshot: isScreenshot)
        }
        let noScreenshots = PhotoOriginLedger(entries: (0..<50).map { taken($0, number: 4_317 + $0, isScreenshot: false) })
        XCTAssertTrue(photo.resolved(with: noScreenshots).isCameraCapture)

        // With screenshots on another counter, this photo is someone else's.
        let elsewhere = PhotoOriginLedger(
            entries: (0..<50).map { taken($0, number: 100 + $0, isScreenshot: $0 % 5 == 0) }
                + [taken(0, number: 4_317, isScreenshot: false)]
        )
        let resolved = photo.resolved(with: elsewhere)
        XCTAssertFalse(resolved.isCameraCapture)
        XCTAssertTrue(resolved.isFromAnotherDevice)
        XCTAssertEqual(CameraRollEntry.number(inFileName: "IMG_4317.HEIC"), 4_317)
        XCTAssertNil(CameraRollEntry.number(inFileName: "FullSizeRender.jpg"))
        XCTAssertNil(CameraRollEntry.number(inFileName: "IMG_E4317.JPG"))
    }

    func testAnotherPhonesPhotosAreNeverImported() async throws {
        let (_, container) = try makeContext()
        func shot(_ id: String, minute: Double, number: Int, at place: CLLocationCoordinate2D) -> PhotoAssetDescriptor {
            let time = epoch.addingTimeInterval(minute * 60)
            return PhotoAssetDescriptor(
                localIdentifier: id, capturedAt: time, latitude: place.latitude, longitude: place.longitude,
                addedAt: time.addingTimeInterval(1), rollNumber: number
            )
        }
        let mine = (0..<6).map { shot("mine-\($0)", minute: Double($0) * 3, number: 2_000 + $0 * 2, at: home) }
        let theirs = (0..<6).map { shot("theirs-\($0)", minute: Double($0) * 3 + 1, number: 6_500 + $0, at: saigon) }
        let screenshots = (0..<6).map { (index: Int) -> LibraryRollEntry in
            let time = epoch.addingTimeInterval(Double(index) * 180 + 30)
            return LibraryRollEntry(capturedAt: time, addedAt: time, number: 2_001 + index * 2, isScreenshot: true)
        }
        let defaults = UserDefaults(suiteName: "photo-roster-\(UUID().uuidString)")!
        let provider = FakePhotoAssetProvider(
            assets: mine + theirs,
            otherRollEntries: screenshots,
            models: Dictionary(uniqueKeysWithValues: mine.map { ($0.localIdentifier, "iPhone 17") })
        )
        let runner = PhotoHistoryImportRunner(
            provider: provider, container: container, rosterStore: OwnCameraRosterStore(defaults: defaults)
        )
        var job = job(over: DateInterval(start: epoch.addingTimeInterval(-60), end: epoch.addingTimeInterval(3_600)))
        // The library is read in parts; one that is lost before the end is read again.
        let cache = PhotoOriginLedgerCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let pieces = runner.libraryPieces(for: job)
        XCTAssertEqual(pieces.first?.end, PhotoOriginLedger.span(around: DateInterval(start: job.rangeStart, end: job.rangeEnd)).end)
        XCTAssertEqual(zip(pieces, pieces.dropFirst()).allSatisfy { $0.start == $1.end }, true)
        for index in pieces.indices.dropLast() {
            try await runner.readPiece(index, of: pieces, for: job, cache: cache)
            XCTAssertTrue(cache.hasPiece(index, for: job.id))
        }
        let ledger = try await runner.makeLedger(for: job, cache: cache)
        XCTAssertFalse(cache.hasPiece(0, for: job.id), "The finished ledger replaces the parts")
        XCTAssertNotNil(cache.load(for: job.id))
        cache.clear()
        job = try await runner.runStep(job, ledger: ledger)

        let attached = Set(try ModelContext(container).fetch(FetchDescriptor<PhotoAttachment>()).map(\.assetLocalIdentifier))
        XCTAssertEqual(attached, Set(mine.map(\.localIdentifier)))
        XCTAssertEqual(job.otherDevicePhotoCount, 6)
        XCTAssertEqual(OwnCameraRosterStore(defaults: defaults).load().periods(calendar: gmt).map(\.model), ["iPhone 17"])
    }

    /// A library the way a move from another service leaves it: years of photos added on
    /// one day, a partner's among them, and a few that friends sent.
    func testImportedPhotosAreJudgedByTheCounterTheyCarry() {
        let imported = epoch.addingTimeInterval(900 * 86_400)
        var entries: [LibraryRollEntry] = []
        func add(_ time: Date, _ number: Int?, shot: Bool = false, at place: CLLocationCoordinate2D? = nil, added: Date? = nil) {
            entries.append(
                LibraryRollEntry(
                    capturedAt: time, addedAt: added ?? imported, number: number, isScreenshot: shot,
                    place: place.map { PhotoPlace(latitude: $0.latitude, longitude: $0.longitude, accuracy: 10) }
                )
            )
        }
        // Mine, with a hole of 45 numbers every few days, across 300 days.
        func mine(_ index: Int) -> (Date, Int) {
            (epoch.addingTimeInterval(Double(index) * 21_600), (3_000 + index + index / 20 * 45) % 10_000)
        }
        for index in 0..<1_200 {
            add(mine(index).0, mine(index).1, shot: index % 15 == 0, at: home)
        }
        // My partner's phone, on a counter of its own and often elsewhere.
        func theirs(_ index: Int) -> (Date, Int) { (epoch.addingTimeInterval(Double(index) * 43_200 + 300), (8_200 + index) % 10_000) }
        for index in 0..<500 {
            add(theirs(index).0, theirs(index).1, at: index % 3 == 0 ? saigon : home)
        }
        // My old phone, in someone else's hands with a few of my screenshots still to come.
        func old(_ index: Int) -> (Date, Int) { (epoch.addingTimeInterval(100 * 86_400 + Double(index) * 3_600 + 120), 5_900 + index) }
        for index in 0..<60 {
            add(old(index).0, old(index).1, shot: index % 25 == 0, at: saigon)
        }
        // From before any of it, without a counter: an old camera.
        let older = epoch.addingTimeInterval(-400 * 86_400)
        for index in 0..<100 { add(older.addingTimeInterval(Double(index) * 60), nil) }

        let ledger = PhotoOriginLedger(entries: entries.shuffled())
        func share(_ count: Int, _ item: (Int) -> (Date, Int), _ origin: PhotoOrigin) -> Double {
            let hits = (0..<count).count { ledger.origin(capturedAt: item($0).0, addedAt: imported, number: item($0).1) == origin }
            return Double(hits) / Double(count)
        }
        XCTAssertGreaterThan(share(1_200, mine, .archive), 0.97)
        XCTAssertGreaterThan(share(500, theirs, .otherDevice), 0.97)
        XCTAssertEqual(share(60, old, .otherDevice), 1, "A second phone that was elsewhere is not the one in my pocket")
        XCTAssertEqual(ledger.origin(capturedAt: older, addedAt: imported, number: nil), .presumed)
        XCTAssertEqual(
            ledger.origin(capturedAt: older, addedAt: imported.addingTimeInterval(40 * 86_400), number: nil), .received,
            "One photo that arrived by itself is not a backup"
        )
        XCTAssertEqual(ledger.origin(capturedAt: mine(40).0, addedAt: imported, number: nil), .received)
        XCTAssertEqual(CameraRollEntry.number(inFileName: "IMG_4317(1).HEIC", allowingSuffix: true), 4_317)
        XCTAssertNil(CameraRollEntry.number(inFileName: "IMG_20140101_120000.jpg", allowingSuffix: true))

        // It survives being put away and read back.
        let cache = PhotoOriginLedgerCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let job = UUID()
        cache.save(ledger, for: job)
        XCTAssertNil(cache.load(for: UUID()))
        XCTAssertEqual(cache.load(for: job)?.origin(capturedAt: mine(40).0, addedAt: imported, number: mine(40).1), .archive)
        cache.clear()
        XCTAssertNil(cache.load(for: job))
    }

    func testPhotosThatPutTheOwnerInTwoPlacesAreLeftOut() {
        func shot(_ id: String, minute: Double, at place: CLLocationCoordinate2D, accuracy: Double? = 8, _ origin: PhotoOrigin) -> PhotoAssetDescriptor {
            var photo = PhotoAssetDescriptor(
                localIdentifier: id, capturedAt: epoch.addingTimeInterval(minute * 60),
                latitude: place.latitude, longitude: place.longitude, horizontalAccuracy: accuracy
            )
            photo.origin = origin
            return photo
        }
        let photos = [
            shot("home", minute: 0, at: home, .camera),
            shot("vague", minute: 5, at: home, accuracy: 400, .camera),
            shot("imported elsewhere", minute: 10, at: saigon, .archive),
            shot("imported here", minute: 12, at: offset(home, northMeters: 600), .archive),
            shot("drive", minute: 30, at: offset(home, northMeters: 25_000), .camera),
            shot("stale", minute: 34, at: offset(home, northMeters: -60_000), .camera),
            shot("drive on", minute: 38, at: offset(home, northMeters: 30_000), .camera),
            shot("flight", minute: 38 + 180, at: offset(home, northMeters: 1_500_000), .camera),
        ]
        XCTAssertEqual(
            PhotoTrailFilter.possible(photos).map(\.localIdentifier),
            ["home", "imported here", "drive", "drive on", "flight"]
        )
    }

    func testRosterFollowsAReplacementPhoneAndDoubtsAStray() {
        var roster = OwnCameraRoster()
        func photos(_ model: String, _ ids: Range<Int>, day: Double) -> [(id: String, model: String?, capturedAt: Date)] {
            ids.map { ("\(model)-\($0)", model, epoch.addingTimeInterval(day * 86_400 + Double($0) * 60)) }
        }
        XCTAssertEqual(roster.acceptNew(photos("iPhone 16 Pro", 0..<8, day: 0)).count, 8)

        // One photo from another model among mine waits; mine carry on.
        let mixed = photos("iPhone 16 Pro", 8..<10, day: 1) + photos("iPhone 12", 0..<1, day: 1) + photos("iPhone 16 Pro", 10..<12, day: 1)
        XCTAssertEqual(roster.acceptNew(mixed).sorted(), ["iPhone 16 Pro-10", "iPhone 16 Pro-11", "iPhone 16 Pro-8", "iPhone 16 Pro-9"])

        // A new phone: its first photos are taken in a row and nothing follows from the old one.
        XCTAssertEqual(roster.acceptNew(photos("iPhone 17", 0..<2, day: 40)).count, 0, "Two photos are not yet a new phone")
        XCTAssertEqual(roster.acceptNew(photos("iPhone 17", 0..<4, day: 40)).count, 4, "The same photos count once a third joins them")
        XCTAssertEqual(roster.periods(calendar: gmt).map(\.model), ["iPhone 16 Pro", "iPhone 17"])

        // In history, a model that is rare in its month is a stray; a file that cannot be read is not judged.
        for _ in 0..<30 { roster.record(model: "iPhone 16 Pro", capturedAt: epoch.addingTimeInterval(-100 * 86_400)) }
        roster.record(model: "iPhone 12", capturedAt: epoch.addingTimeInterval(-100 * 86_400))
        XCTAssertTrue(roster.isStray(model: "iPhone 12", capturedAt: epoch.addingTimeInterval(-100 * 86_400)))
        XCTAssertFalse(roster.isStray(model: "iPhone 16 Pro", capturedAt: epoch.addingTimeInterval(-100 * 86_400)))
        XCTAssertFalse(roster.isStray(model: "iPhone 12", capturedAt: epoch.addingTimeInterval(-400 * 86_400)))
    }

    // MARK: - Helpers

    private func job(over interval: DateInterval) -> PhotoHistoryJob {
        PhotoHistoryJob(rangeStart: interval.start, rangeEnd: interval.end, cursor: interval.end)
    }

    /// Three weeks of outings a few stops long, with saved photos and photos without a
    /// location mixed in the way a real library has them.
    private func libraryAcrossManyDays() -> [PhotoAssetDescriptor] {
        var assets: [PhotoAssetDescriptor] = []
        for day in 0..<21 {
            let morning = epoch.addingTimeInterval(Double(day) * 86_400 + 9 * 3_600)
            let stops = [home, offset(home, northMeters: 900 + Double(day) * 40), offset(home, northMeters: 2_400)]
            for (stopIndex, stop) in stops.enumerated() {
                let arrival = morning.addingTimeInterval(Double(stopIndex) * 35 * 60)
                for shot in 0..<(2 + (day + stopIndex) % 3) {
                    assets.append(
                        photo("d\(day)-s\(stopIndex)-\(shot)", at: arrival.addingTimeInterval(Double(shot) * 240), coordinate: stop)
                    )
                }
            }
            assets.append(
                PhotoAssetDescriptor(
                    localIdentifier: "saved-\(day)",
                    capturedAt: morning.addingTimeInterval(20 * 60),
                    latitude: saigon.latitude,
                    longitude: saigon.longitude,
                    isCameraCapture: false
                )
            )
            assets.append(PhotoAssetDescriptor(localIdentifier: "nowhere-\(day)", capturedAt: morning.addingTimeInterval(5 * 3_600)))
        }
        return assets
    }

    private struct TimelineSnapshot: Equatable {
        var visits: [String]
        var photos: Set<String>
        var moves: Int
        var samples: Int
    }

    private func snapshot(_ context: ModelContext) throws -> TimelineSnapshot {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)]))
        return TimelineSnapshot(
            visits: visits.map { visit in
                let photos = visit.photoAttachments.map(\.assetLocalIdentifier).sorted().joined(separator: ",")
                return "\(Int(visit.arrivalDate.timeIntervalSince1970))-\(Int(visit.departureDate?.timeIntervalSince1970 ?? 0)):\(photos)"
            },
            photos: Set(try context.fetch(FetchDescriptor<PhotoAttachment>()).map(\.assetLocalIdentifier)),
            moves: try context.fetchCount(FetchDescriptor<MoveSegment>()),
            samples: try context.fetchCount(FetchDescriptor<LocationSample>())
        )
    }

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
