import Foundation
import SwiftData

/// A photo-history import that picks up where it stopped.
///
/// The import works back through the library from the newest photo, one saved step at a
/// time, so the most recent years appear first. After each step the job is written down
/// with how far back it got, so closing Moves, a crash, or a restart costs at most the
/// step that was running.
struct PhotoHistoryJob: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case running
        case paused
        case finished
    }

    /// Raised when the rules for which photos count change enough to read the library again.
    static let currentRules = 2

    /// Photos taken in the last week are the live timeline's, which still rebuilds it.
    static let liveDays = 7
    /// Cameras with a dead clock date their photos to the year they were built.
    static let earliestDate = Date(timeIntervalSince1970: 946_684_800)

    var id = UUID()
    var rangeStart: Date
    var rangeEnd: Date
    /// Photos captured at or after this are done; the import continues backward from here.
    var cursor: Date
    /// Photos in the range, with or without a location, once they have been counted.
    var totalPhotoCount = 0
    var remainingPhotoCount = 0
    var isCounted = false
    var state: State = .running
    var report = PhotoHistoryImportReport()
    var message: String?
    var finishedAt: Date?
    /// When a step last finished.
    var lastProgressAt: Date?
    /// Photos passed over because another device took them.
    var otherDevicePhotoCount = 0
    /// Photos passed over because they were saved or sent by someone.
    var receivedPhotoCount = 0
    /// Photos passed over because the place or time in them can't be right.
    var conflictingPhotoCount = 0
    /// Photos given up on after several tries.
    var unreadablePhotoCount = 0
    /// Capture time of the oldest photo imported so far.
    var earliestPhotoAt: Date?
    /// Times the step at `cursor` began, counting the one under way.
    var unfinishedStepStarts = 0
    /// Times reading the library began without finishing.
    var ledgerAttempts = 0
    var rules = Self.currentRules

    /// A job over the whole library, up to the days the live timeline is still writing.
    static func wholeLibrary(now: Date = .now, calendar: Calendar = .current) -> PhotoHistoryJob {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: -liveDays, to: today) ?? today
        return PhotoHistoryJob(rangeStart: earliestDate, rangeEnd: end, cursor: end)
    }

    var fractionComplete: Double {
        guard state != .finished else { return 1 }
        guard totalPhotoCount > 0 else { return 0 }
        return min(max(1 - Double(remainingPhotoCount) / Double(totalPhotoCount), 0), 1)
    }

    var checkedPhotoCount: Int {
        max(totalPhotoCount - remainingPhotoCount, 0)
    }

    var isUnfinished: Bool {
        state != .finished
    }
}

extension PhotoHistoryJob {
    /// A job outlives the version of Moves that began it. Everything that was not in the
    /// first version falls back to its default, so an update never loses the import.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int {
            (try? values.decodeIfPresent(Int.self, forKey: key)) ?? 0
        }
        func date(_ key: CodingKeys) -> Date? {
            (try? values.decodeIfPresent(Date.self, forKey: key)) ?? nil
        }
        self.init(
            id: (try? values.decode(UUID.self, forKey: .id)) ?? UUID(),
            rangeStart: try values.decode(Date.self, forKey: .rangeStart),
            rangeEnd: try values.decode(Date.self, forKey: .rangeEnd),
            cursor: try values.decode(Date.self, forKey: .cursor)
        )
        totalPhotoCount = count(.totalPhotoCount)
        remainingPhotoCount = count(.remainingPhotoCount)
        isCounted = (try? values.decode(Bool.self, forKey: .isCounted)) ?? (totalPhotoCount > 0)
        // An import that stopped on an error in an earlier version carries on.
        state = (try? values.decode(State.self, forKey: .state)) ?? .running
        report = (try? values.decode(PhotoHistoryImportReport.self, forKey: .report)) ?? PhotoHistoryImportReport()
        message = (try? values.decodeIfPresent(String.self, forKey: .message)) ?? nil
        finishedAt = date(.finishedAt)
        lastProgressAt = date(.lastProgressAt)
        otherDevicePhotoCount = count(.otherDevicePhotoCount)
        receivedPhotoCount = count(.receivedPhotoCount)
        conflictingPhotoCount = count(.conflictingPhotoCount)
        unreadablePhotoCount = count(.unreadablePhotoCount)
        earliestPhotoAt = date(.earliestPhotoAt)
        unfinishedStepStarts = count(.unfinishedStepStarts)
        ledgerAttempts = count(.ledgerAttempts)
        rules = (try? values.decode(Int.self, forKey: .rules)) ?? 1
    }
}

/// Keeps the job outside the timeline store: it is this phone's progress, not history.
struct PhotoHistoryJobStore {
    static let key = "photos.historyJob"
    var defaults: UserDefaults = .standard

    func load() -> PhotoHistoryJob? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PhotoHistoryJob.self, from: data)
    }

    func save(_ job: PhotoHistoryJob?) {
        guard let job, let data = try? JSONEncoder().encode(job) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

/// Decides where one step ends so that no stay is cut in half.
enum PhotoHistoryPaging {
    struct Batch: Equatable {
        var assets: [PhotoAssetDescriptor]
        /// Photos captured before this are still to do.
        var nextCursor: Date
        var isLast: Bool
    }

    /// - Parameters:
    ///   - page: The newest photos before `cursor`, at most `limit` of them.
    ///   - usable: The page's photos this import reads, oldest first.
    ///   - start: Where the import ends, the oldest date it covers.
    ///   - stayGap: Photos closer together than this may belong to one stay.
    ///   - mayCutAnOuting: Take the page as it is even when it is one unbroken outing.
    /// - Returns: `nil` when the page is one unbroken outing that may reach further back
    ///   than the page does. A larger page is needed to read it whole.
    static func batch(
        from page: PhotoAssetPage,
        usable: [PhotoAssetDescriptor],
        cursor: Date,
        start: Date,
        limit: Int,
        stayGap: TimeInterval,
        mayCutAnOuting: Bool = false
    ) -> Batch? {
        guard page.scannedCount >= limit, let earliest = page.earliestScannedAt else {
            return Batch(assets: usable, nextCursor: start, isLast: true)
        }

        var assets = usable
        // Photos sharing the oldest instant may lie beyond the page, so it is read again.
        var next = earliest.addingTimeInterval(0.001)
        if let firstUsable = usable.first, firstUsable.capturedAt.timeIntervalSince(earliest) <= stayGap {
            // The page begins in the middle of an outing. Leave that outing for the next
            // step, which reads it whole.
            let breakIndex = usable.indices.dropFirst().first { index in
                usable[index].capturedAt.timeIntervalSince(usable[index - 1].capturedAt) > stayGap
            }
            if let breakIndex {
                assets = Array(usable[breakIndex...])
                next = usable[breakIndex].capturedAt
            } else if !mayCutAnOuting {
                return nil
            }
        }
        // Every photo on the page shares one instant; step past it rather than read it forever.
        if next >= cursor {
            next = earliest
        }
        return Batch(assets: assets, nextCursor: next, isLast: false)
    }
}

/// Runs a photo-history job one step at a time.
struct PhotoHistoryImportRunner: @unchecked Sendable {
    let provider: any PhotoAssetProviding
    let container: ModelContainer
    /// Where the owner's camera models are kept. Without one, models are not read.
    var rosterStore: OwnCameraRosterStore?
    /// Photos looked at per step. A step saves once and takes a second or two.
    var pageSize = 1_500
    /// A step grows until it ends between outings, but not past this many photos.
    var maximumPageSize = 24_000
    /// A step that keeps stopping Moves is cut down to this many photos, then passed over.
    var minimumPageSize = 50
    /// Photos per step whose camera model is read.
    var modelSampleSize = 24
    /// Where photos an earlier version used by mistake are noted.
    var rejectedStore: RejectedPhotoStore?
    var configuration = PhotoHistoryImporter.Configuration()

    /// Tries before a step is made smaller, and before its photos are passed over.
    static let triesAtFullSize = 2
    static let triesBeforePassingOver = 6

    /// Finds where the library begins and how much there is to do.
    func counted(_ job: PhotoHistoryJob) async throws -> PhotoHistoryJob {
        var next = job
        if let earliest = try await provider.earliestPhotoDate() {
            next.rangeStart = min(max(earliest, PhotoHistoryJob.earliestDate), job.rangeEnd)
        }
        next.totalPhotoCount = try await provider.photoCount(
            in: DateInterval(start: next.rangeStart, end: next.rangeEnd)
        )
        next.remainingPhotoCount = next.totalPhotoCount
        next.isCounted = true
        return next
    }

    /// The parts the library is read in to work out where its photos came from. The same
    /// for a job every time, so a part that was read before is not read again.
    func libraryPieces(for job: PhotoHistoryJob) -> [DateInterval] {
        PhotoOriginLedger.pieces(
            of: PhotoOriginLedger.span(around: DateInterval(start: job.rangeStart, end: job.rangeEnd))
        )
    }

    /// Reads one part of the library, unless an earlier try already has.
    func readPiece(_ index: Int, of pieces: [DateInterval], for job: PhotoHistoryJob, cache: PhotoOriginLedgerCache) async throws {
        guard !cache.hasPiece(index, for: job.id) else { return }
        // The end is the first moment of the piece before it.
        let entries = try await provider.libraryRoll(in: pieces[index])
        cache.savePiece(entries, index: index, for: job.id)
    }

    /// Where every photo in the job's range came from, once every part has been read.
    func makeLedger(for job: PhotoHistoryJob, cache: PhotoOriginLedgerCache) async throws -> PhotoOriginLedger {
        let pieces = libraryPieces(for: job)
        var entries: [LibraryRollEntry] = []
        for index in pieces.indices {
            if let piece = cache.loadPiece(index, for: job.id) {
                entries += piece
            } else {
                // The system may empty the cache at any time.
                entries += try await provider.libraryRoll(in: pieces[index])
            }
            try Task.checkCancellation()
        }
        let ledger = PhotoOriginLedger(entries: entries)
        cache.save(ledger, for: job.id)
        return ledger
    }

    /// Imports the newest photos before the job's cursor and returns the job moved past them.
    func runStep(_ job: PhotoHistoryJob, ledger: PhotoOriginLedger? = nil) async throws -> PhotoHistoryJob {
        // The same photos have stopped Moves before. Take fewer at a time to get past them.
        let failures = max(job.unfinishedStepStarts - 1, 0)
        let isCautious = failures >= Self.triesAtFullSize
        if failures >= Self.triesBeforePassingOver {
            return try await passOver(job)
        }
        var limit = isCautious
            ? max(pageSize >> (2 * (failures - Self.triesAtFullSize + 1)), minimumPageSize)
            : pageSize
        let largest = isCautious ? limit : maximumPageSize

        var found: PhotoHistoryPaging.Batch?
        var looked: [PhotoAssetDescriptor] = []
        while found == nil {
            let page = try await provider.newestAssets(
                in: DateInterval(start: job.rangeStart, end: max(job.cursor, job.rangeStart)),
                limit: limit
            )
            try Task.checkCancellation()
            looked = page.assets.map { $0.resolved(with: ledger) }
            found = PhotoHistoryPaging.batch(
                from: page,
                usable: PhotoTrailFilter.possible(looked.filter(\.origin.isOwn)),
                cursor: job.cursor,
                start: job.rangeStart,
                limit: limit,
                stayGap: configuration.stayGap,
                mayCutAnOuting: limit >= largest
            )
            limit *= 2
        }
        guard var batch = found else { return job }
        // The rest of the page is looked at again in the next step, and counted there.
        let done = looked.filter { batch.isLast || $0.capturedAt >= batch.nextCursor }
        let possibleCount = batch.assets.count
        try noteRejected(done, keeping: batch.assets)
        batch.assets = await withoutStrayCameras(batch.assets)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stepReport = try PhotoHistoryImporter(modelContext: context, configuration: configuration)
            .importStep(batch.assets)

        var next = job
        next.report = job.report + stepReport
        next.otherDevicePhotoCount += done.count(where: \.isFromAnotherDevice) + possibleCount - batch.assets.count
        next.receivedPhotoCount += done.count { $0.origin == .received }
        next.conflictingPhotoCount += max(done.count(where: \.origin.isOwn) - possibleCount, 0)
        if let oldest = batch.assets.first?.capturedAt {
            next.earliestPhotoAt = min(job.earliestPhotoAt ?? oldest, oldest)
        }
        return try await moved(next, to: batch.nextCursor, isLast: batch.isLast)
    }

    /// An earlier version read some photos this one leaves out. The ones in the timeline are
    /// noted here and taken out at the next launch: deleting a row that a screen may be
    /// showing ends the app.
    private func noteRejected(_ photos: [PhotoAssetDescriptor], keeping kept: [PhotoAssetDescriptor]) throws {
        guard let rejectedStore, let first = photos.first?.capturedAt, let last = photos.last?.capturedAt else { return }
        let keptIDs = Set(kept.map(\.localIdentifier))
        // A copy of a photo that was used says the same place.
        let rejected = Set(
            photos.filter { !keptIDs.contains($0.localIdentifier) && $0.origin != .duplicate }.map(\.localIdentifier)
        )
        guard !rejected.isEmpty else { return }
        let from = first.addingTimeInterval(-1)
        let through = last.addingTimeInterval(1)
        let context = ModelContext(container)
        let attached = try context.fetch(
            FetchDescriptor<PhotoAttachment>(predicate: #Predicate { $0.capturedAt >= from && $0.capturedAt <= through })
        )
        rejectedStore.add(
            Set(
                attached
                    .filter { rejected.contains($0.assetLocalIdentifier) && $0.visitPlace?.origin == .photoInferred }
                    .map(\.assetLocalIdentifier)
            )
        )
    }

    /// Leaves out a handful of photos that stop the import every time, so that the rest of
    /// the library is not held up by them.
    private func passOver(_ job: PhotoHistoryJob) async throws -> PhotoHistoryJob {
        let range = DateInterval(start: job.rangeStart, end: max(job.cursor, job.rangeStart))
        let page = try await provider.newestAssets(in: range, limit: minimumPageSize)
        var next = job
        next.unreadablePhotoCount += page.scannedCount
        let isLast = page.scannedCount < minimumPageSize
        return try await moved(next, to: page.earliestScannedAt ?? job.rangeStart, isLast: isLast)
    }

    private func moved(_ job: PhotoHistoryJob, to cursor: Date, isLast: Bool) async throws -> PhotoHistoryJob {
        var next = job
        next.unfinishedStepStarts = 0
        next.message = nil
        next.cursor = cursor
        next.lastProgressAt = .now
        if isLast {
            next.remainingPhotoCount = 0
            next.state = .finished
            next.finishedAt = .now
        } else {
            next.remainingPhotoCount = try await provider.photoCount(
                in: DateInterval(start: job.rangeStart, end: max(cursor, job.rangeStart))
            )
        }
        return next
    }

    /// Reads the camera model from the photos whose original is on the phone, adds them to
    /// the roster of the owner's phones, and drops the few whose model is a stranger to
    /// the month they were taken in.
    private func withoutStrayCameras(_ assets: [PhotoAssetDescriptor]) async -> [PhotoAssetDescriptor] {
        guard let rosterStore else { return assets }
        // Each reading opens a file, so a few from across the step speak for the rest.
        let candidates = assets.filter { $0.origin == .camera || $0.origin == .archive }
        let spacing = max(candidates.count / modelSampleSize, 1)
        let own = stride(from: 0, to: candidates.count, by: spacing).map { candidates[$0] }
        let models = await provider.cameraModels(for: own.map(\.localIdentifier))
        guard !models.isEmpty else { return assets }

        var roster = rosterStore.load()
        for photo in own {
            if let model = models[photo.localIdentifier] {
                roster.record(model: model, capturedAt: photo.capturedAt)
            }
        }
        rosterStore.save(roster)
        return assets.filter { photo in
            guard let model = models[photo.localIdentifier] else { return true }
            return !roster.isStray(model: model, capturedAt: photo.capturedAt)
        }
    }
}
