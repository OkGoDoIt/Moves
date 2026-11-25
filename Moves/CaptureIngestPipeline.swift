import CoreLocation
import Foundation
import OSLog
import UIKit

/// Keeps the process running while capture still has something to write.
///
/// A flush starts a write that runs a moment later on the main actor. Without an
/// assertion, iOS can suspend the app between the two, and a suspended app that is
/// then ended loses the fixes it was holding.
struct CaptureBackgroundTime {
    var begin: @MainActor (_ name: String, _ expired: @escaping @MainActor () -> Void) -> Int
    var end: @MainActor (_ identifier: Int) -> Void

    static let application = CaptureBackgroundTime(
        begin: { name, expired in
            UIApplication.shared.beginBackgroundTask(withName: name) {
                MainActor.assumeIsolated { expired() }
            }.rawValue
        },
        end: { identifier in
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
        }
    )

    static let unavailable = CaptureBackgroundTime(begin: { _, _ in 0 }, end: { _ in })
}

/// Hands fixes, visits, and rebuilds to the assembler one at a time, in the order capture
/// produced them, so a visit or a rebuild never runs ahead of the fixes before it.
///
/// Enqueueing never waits: the work runs on its own task, one job after another.
/// Adjacent writes from the same source are combined, and a rebuild that another queued
/// or running rebuild already covers is dropped.
@MainActor
final class CaptureIngestPipeline {
    enum Job {
        case store([CLLocation], source: LocationSampleSource)
        case visit(CLVisit)
        case rebuild(CaptureRebuildScope)
        /// Anything else that has to happen in order with the writes around it.
        case run(String, @MainActor () async -> Void)

        var logName: String {
            switch self {
            case .store(let locations, let source): return "store \(locations.count) \(source.rawValue)"
            case .visit: return "visit"
            case .rebuild(let scope): return "rebuild \(scope)"
            case .run(let name, _): return name
            }
        }
    }

    private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Capture")

    private let assembler: TimelineAssembler
    private let backgroundTime: CaptureBackgroundTime
    private var queue: [Job] = []
    private var running: Job?
    private var consumer: Task<Void, Never>?
    private var backgroundTask: Int?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Rebuild requests dropped because another rebuild already covered them. For tests and logs.
    private(set) var coalescedRebuilds = 0

    init(assembler: TimelineAssembler, backgroundTime: CaptureBackgroundTime = .application) {
        self.assembler = assembler
        self.backgroundTime = backgroundTime
    }

    var isIdle: Bool { consumer == nil }
    var queuedCount: Int { queue.count }

    func store(_ locations: [CLLocation], source: LocationSampleSource) {
        guard !locations.isEmpty else { return }
        enqueue(.store(locations, source: source))
    }

    func visit(_ visit: CLVisit) {
        enqueue(.visit(visit))
    }

    func rebuild(_ scope: CaptureRebuildScope) {
        enqueue(.rebuild(scope))
    }

    func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        enqueue(.run(name, work))
    }

    /// Returns once everything queued so far, and anything queued meanwhile, has run.
    func drain() async {
        guard consumer != nil else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    /// The app is about to end and nothing async will run again. Writes the queued fixes
    /// now, on this thread. Visits and rebuilds wait for the next launch, which rebuilds.
    func writeQueuedFixesBeforeTermination() -> Int {
        var written = 0
        var kept: [Job] = []
        for job in queue {
            if case .store(let locations, let source) = job {
                assembler.storeImmediately(locations, source: source)
                written += locations.count
            } else {
                kept.append(job)
            }
        }
        queue = kept
        return written
    }

    private func enqueue(_ job: Job) {
        switch job {
        case .store(let locations, let source):
            if case .store(let queued, let queuedSource)? = queue.last, queuedSource == source {
                queue[queue.count - 1] = .store(queued + locations, source: source)
                return
            }
        case .rebuild(let scope):
            if case .rebuild(let queued)? = queue.last {
                queue[queue.count - 1] = .rebuild(queued.merged(with: scope))
                coalescedRebuilds += 1
                return
            }
            // Writes only reach the store through this queue, so with nothing waiting
            // behind a running rebuild, no fix has arrived since it read its inputs.
            if queue.isEmpty, case .rebuild(let current)? = running, current.covers(scope) {
                coalescedRebuilds += 1
                Self.log.debug("Rebuild \(scope, privacy: .public) already running")
                return
            }
        case .visit, .run:
            break
        }

        queue.append(job)
        if backgroundTask == nil {
            backgroundTask = backgroundTime.begin("Moves capture write") { [weak self] in
                self?.endBackgroundTime()
            }
        }
        if consumer == nil {
            consumer = Task { [weak self] in
                await self?.consume()
            }
        }
    }

    private func consume() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            running = job
            await perform(job)
            running = nil
        }
        // Same actor turn as the empty check above: nothing can be enqueued in between.
        consumer = nil
        endBackgroundTime()
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func perform(_ job: Job) async {
        switch job {
        case .store(let locations, let source):
            await assembler.ingestLocations(locations, source: source, reconcile: false)
        case .visit(let visit):
            await assembler.ingestVisit(visit)
        case .rebuild(let scope):
            await assembler.reconcile(scope)
        case .run(_, let work):
            await work()
        }
    }

    private func endBackgroundTime() {
        guard let backgroundTask else { return }
        self.backgroundTask = nil
        backgroundTime.end(backgroundTask)
    }
}
