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

/// Waits for an answer that depends on something outside the app (the network, Core
/// Motion's history) for a limited time, so one answer that never comes cannot hold up
/// everything queued behind it.
enum BoundedWait {
    static func run<Value>(
        seconds: TimeInterval,
        fallback: Value,
        _ operation: @escaping () async -> Value
    ) async -> Value {
        let gate = Gate<Value>()
        return await withCheckedContinuation { continuation in
            gate.open(continuation)
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.finish(fallback)
            }
            Task {
                let value = await operation()
                timer.cancel()
                gate.finish(value)
            }
        }
    }

    /// Resumes its continuation once, with whichever answer arrives first.
    private final class Gate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        func open(_ continuation: CheckedContinuation<Value, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: Value) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }
}

/// Hands fixes, visits, and rebuilds to the assembler one at a time, in the order capture
/// produced them, so a visit or a rebuild never runs ahead of the fixes before it.
///
/// Enqueueing never waits: the work runs on its own task, one job after another.
/// Adjacent writes from the same source are combined, and a rebuild that another queued
/// or running rebuild already covers is dropped.
///
/// The order holds while jobs keep moving. A job that runs longer than `stallAllowance`
/// (a place lookup with no network, a rebuild iOS suspended part-way) no longer holds
/// fixes back: they are written past it, because a fix lost when the process ends cannot
/// be recorded again.
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
    /// How long a job may run before the fixes waiting behind it are written past it.
    private let stallAllowance: TimeInterval
    private var queue: [Job] = []
    private var running: Job?
    private var runningSince: ContinuousClock.Instant?
    /// Counts jobs, so a stall check can tell whether the job it was set for is still the one running.
    private var runningSerial = 0
    /// Fixes were written past the running job, so it has not seen everything in the store.
    private var wroteFixesPastRunningJob = false
    private var consumer: Task<Void, Never>?
    private var backgroundTask: Int?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Rebuild requests dropped because another rebuild already covered them. For tests and logs.
    private(set) var coalescedRebuilds = 0
    /// Fixes written past a job that was taking too long. For tests and logs.
    private(set) var fixesWrittenPastStalls = 0

    init(
        assembler: TimelineAssembler,
        backgroundTime: CaptureBackgroundTime = .application,
        stallAllowance: TimeInterval = 4
    ) {
        self.assembler = assembler
        self.backgroundTime = backgroundTime
        self.stallAllowance = stallAllowance
    }

    var isIdle: Bool { consumer == nil }
    var queuedCount: Int { queue.count }

    /// What the pipeline is doing, for the capture heartbeat.
    var statusDescription: String {
        guard let running, let runningSince else { return "idle" }
        let seconds = Int((ContinuousClock.now - runningSince) / .seconds(1))
        return "\(running.logName) for \(seconds) s, \(queue.count) waiting"
    }

    func store(_ locations: [CLLocation], source: LocationSampleSource) {
        guard !locations.isEmpty else { return }
        if isStalled {
            // A fix is the one thing that cannot be had again later. It does not wait
            // behind a place lookup or a rebuild that has stopped making progress.
            writeFixesPastRunningJob(adding: locations, source: source)
            return
        }
        enqueue(.store(locations, source: source))
    }

    private var isStalled: Bool {
        guard running != nil, let runningSince else { return false }
        return ContinuousClock.now - runningSince >= .seconds(stallAllowance)
    }

    private func writeFixesPastRunningJob(adding locations: [CLLocation] = [], source: LocationSampleSource? = nil) {
        var written = writeQueuedFixesBeforeTermination()
        if let source, !locations.isEmpty {
            assembler.storeImmediately(locations, source: source)
            written += locations.count
        }
        guard written > 0 else { return }
        wroteFixesPastRunningJob = true
        fixesWrittenPastStalls += written
        Self.log.notice(
            "Wrote \(written) fixes past a slow job: \(self.statusDescription, privacy: .public)"
        )
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
            // With nothing waiting behind a running rebuild, and nothing written past it,
            // no fix has arrived since it read its inputs.
            if queue.isEmpty, !wroteFixesPastRunningJob,
               case .rebuild(let current)? = running, current.covers(scope) {
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
            let started = ContinuousClock.now
            running = job
            runningSince = started
            runningSerial += 1
            wroteFixesPastRunningJob = false
            watchForStall(serial: runningSerial)
            await perform(job)
            running = nil
            runningSince = nil
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            if seconds >= stallAllowance {
                Self.log.notice("Capture job \(job.logName, privacy: .public) took \(Int(seconds)) s")
            }
        }
        // Same actor turn as the empty check above: nothing can be enqueued in between.
        consumer = nil
        endBackgroundTime()
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Fixes queued behind a job that turns out to be slow are written once it has had its
    /// time, even if no further fix arrives to notice.
    private func watchForStall(serial: Int) {
        let allowance = stallAllowance
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(allowance))
            guard let self, self.running != nil, self.runningSerial == serial else { return }
            self.writeFixesPastRunningJob()
        }
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
