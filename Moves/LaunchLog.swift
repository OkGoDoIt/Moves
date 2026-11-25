import Darwin
import Foundation
import os

/// Timings for what runs while the app comes up: stage names, counts, and milliseconds.
///
/// Read them with
/// `log stream --predicate 'subsystem == "<bundle id>" AND category == "Launch"'`, or in
/// Instruments through the matching signposts. Nothing here carries a name or a coordinate.
enum LaunchLog {
    static let logger = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Launch")
    static let signposter = OSSignposter(logger: logger)

    /// When the kernel started this process, so a stage can say how far into launch it ran.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return .now }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// Milliseconds since the process started.
    static var sinceProcessStart: Int {
        Int(Date.now.timeIntervalSince(processStart) * 1_000)
    }

    /// Records a moment in launch, such as the first timeline frame.
    static func mark(_ event: StaticString) {
        signposter.emitEvent(event)
        logger.notice("\(event, privacy: .public) at \(sinceProcessStart) ms")
    }

    /// Records one stage's duration, with an optional count of what it handled.
    static func finished(_ stage: StaticString, startedAt start: ContinuousClock.Instant, count: Int? = nil) {
        let elapsed = milliseconds(ContinuousClock.now - start)
        if let count {
            logger.notice("\(stage, privacy: .public): \(elapsed) ms, \(count) rows, ended at \(sinceProcessStart) ms")
        } else {
            logger.notice("\(stage, privacy: .public): \(elapsed) ms, ended at \(sinceProcessStart) ms")
        }
    }

    /// Times a synchronous stage.
    static func measure<T>(_ stage: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(stage)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(stage, state)
            finished(stage, startedAt: start)
        }
        return try work()
    }

    /// Times a synchronous stage that returns how many rows it handled.
    static func measureCount(_ stage: StaticString, _ work: () throws -> Int) rethrows -> Int {
        let state = signposter.beginInterval(stage)
        let start = ContinuousClock.now
        let count = try work()
        signposter.endInterval(stage, state)
        finished(stage, startedAt: start, count: count)
        return count
    }

    /// Times an asynchronous stage.
    static func measure<T>(_ stage: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(stage)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(stage, state)
            finished(stage, startedAt: start)
        }
        return try await work()
    }

    /// Logs each main-thread stall of more than half a second during the first minute, when
    /// launch work most often holds the interface up.
    static func watchMainThread(for window: Duration = .seconds(60)) {
        let queue = DispatchQueue(label: "Launch.mainThreadWatch", qos: .utility)
        let started = ContinuousClock.now
        @Sendable func ping() {
            let sent = ContinuousClock.now
            DispatchQueue.main.async {
                let waited = milliseconds(ContinuousClock.now - sent)
                if waited > 500 {
                    logger.notice("Main thread stalled \(waited) ms, until \(sinceProcessStart) ms")
                }
                guard ContinuousClock.now - started < window else { return }
                queue.asyncAfter(deadline: .now() + 0.25) { ping() }
            }
        }
        queue.async { ping() }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
