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
        case failed
    }

    var id = UUID()
    var rangeStart: Date
    var rangeEnd: Date
    /// Also reads photos that were saved, received, or imported rather than taken.
    var includesSavedPhotos: Bool
    /// Photos captured at or after this are done; the import continues backward from here.
    var cursor: Date
    /// Photos in the range, with or without a location, when the import began.
    var totalPhotoCount: Int
    var remainingPhotoCount: Int
    var state: State = .running
    var report = PhotoHistoryImportReport()
    var message: String?
    var finishedAt: Date?
    /// Capture time of the oldest photo imported so far.
    var earliestPhotoAt: Date?
    /// Times the step at `cursor` began without finishing. Two means it is the step
    /// itself that stops Moves, so the import waits to be resumed by hand.
    var unfinishedStepStarts = 0

    var fractionComplete: Double {
        guard state != .finished else { return 1 }
        guard totalPhotoCount > 0 else { return 0 }
        return min(max(1 - Double(remainingPhotoCount) / Double(totalPhotoCount), 0), 1)
    }

    var checkedPhotoCount: Int {
        max(totalPhotoCount - remainingPhotoCount, 0)
    }

    var isUnfinished: Bool {
        state == .running || state == .paused || state == .failed
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
struct PhotoHistoryImportRunner: Sendable {
    let provider: any PhotoAssetProviding
    let container: ModelContainer
    /// Photos looked at per step. A step saves once and takes a second or two.
    var pageSize = 1_500
    /// A step grows until it ends between outings, but not past this many photos.
    var maximumPageSize = 24_000
    var configuration = PhotoHistoryImporter.Configuration()

    func makeJob(in interval: DateInterval, includesSavedPhotos: Bool) async throws -> PhotoHistoryJob {
        let count = try await provider.photoCount(in: interval)
        return PhotoHistoryJob(
            rangeStart: interval.start,
            rangeEnd: interval.end,
            includesSavedPhotos: includesSavedPhotos,
            cursor: interval.end,
            totalPhotoCount: count,
            remainingPhotoCount: count
        )
    }

    /// Imports the newest photos before the job's cursor and returns the job moved past them.
    func runStep(_ job: PhotoHistoryJob) async throws -> PhotoHistoryJob {
        var limit = pageSize
        var found: PhotoHistoryPaging.Batch?
        while found == nil {
            let page = try await provider.newestAssets(
                in: DateInterval(start: job.rangeStart, end: max(job.cursor, job.rangeStart)),
                limit: limit
            )
            try Task.checkCancellation()
            found = PhotoHistoryPaging.batch(
                from: page,
                usable: job.includesSavedPhotos ? page.assets : page.assets.filter(\.isCameraCapture),
                cursor: job.cursor,
                start: job.rangeStart,
                limit: limit,
                stayGap: configuration.stayGap,
                mayCutAnOuting: limit >= maximumPageSize
            )
            limit *= 2
        }
        guard let batch = found else { return job }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stepReport = try PhotoHistoryImporter(modelContext: context, configuration: configuration)
            .importStep(batch.assets)

        var next = job
        next.report = job.report + stepReport
        next.unfinishedStepStarts = 0
        next.cursor = batch.nextCursor
        if let oldest = batch.assets.first?.capturedAt {
            next.earliestPhotoAt = min(job.earliestPhotoAt ?? oldest, oldest)
        }
        if batch.isLast {
            next.remainingPhotoCount = 0
            next.state = .finished
            next.finishedAt = .now
        } else {
            next.remainingPhotoCount = try await provider.photoCount(
                in: DateInterval(start: job.rangeStart, end: max(batch.nextCursor, job.rangeStart))
            )
        }
        return next
    }
}
