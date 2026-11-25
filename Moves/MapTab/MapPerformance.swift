import Foundation
import OSLog
import QuartzCore
import UIKit

/// Map tab timings, logged under the `Map` category as plain numbers. A display link runs only
/// while the camera moves or the scrubber is dragged, and reports frames over 20 ms and 50 ms,
/// how often the tab's body was evaluated, and memory, once the activity stops.
@MainActor
final class MapPerformanceProbe {
    static let shared = MapPerformanceProbe()
    nonisolated static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Map")

    private var link: CADisplayLink?
    private var label = ""
    private var startedAt: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var activeUntil: CFTimeInterval = 0
    private var frames = 0
    private var over20 = 0
    private var over50 = 0
    private var worstFrame: CFTimeInterval = 0
    private var bodyAtStart = 0
    private var callbacks = 0
    private var callbackTime: CFTimeInterval = 0
    private var worstCallback: CFTimeInterval = 0

    private(set) var bodyEvaluations = 0
    /// When the tab last appeared, for time to first complete frame.
    var openedAt: CFTimeInterval?
    /// When the camera last settled, for the time until the layer is redrawn.
    var settledAt: CFTimeInterval?

    func bodyEvaluated() {
        bodyEvaluations += 1
    }

    /// Something is moving: keep measuring frames until it has been still for 0.4 s.
    func activity(_ label: String) {
        let now = CACurrentMediaTime()
        if link == nil {
            self.label = label
            startedAt = now
            lastFrame = 0
            frames = 0
            over20 = 0
            over50 = 0
            worstFrame = 0
            callbacks = 0
            callbackTime = 0
            worstCallback = 0
            bodyAtStart = bodyEvaluations
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        activeUntil = now + 0.4
    }

    /// Main-thread time spent in one camera-change callback.
    func cameraCallback(took seconds: CFTimeInterval) {
        callbacks += 1
        callbackTime += seconds
        worstCallback = max(worstCallback, seconds)
    }

    private var watchTimer: DispatchSourceTimer?

    /// Ticks the main queue every 10 ms for `seconds` and logs the longest gap, flagging anything
    /// over 100 ms. Used when the app leaves the foreground, where a busy main thread gets the
    /// app killed by the scene-update watchdog.
    func watchMainThread(_ label: String, for seconds: Double = 2) {
        watchTimer?.cancel()
        let started = CACurrentMediaTime()
        var last = started
        var worst: CFTimeInterval = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            last = now
            guard now - started > seconds else { return }
            self?.watchTimer?.cancel()
            self?.watchTimer = nil
            let ms = worst * 1_000
            Self.log.notice("\(label, privacy: .public): longest main-thread gap \(ms, format: .fixed(precision: 1), privacy: .public) ms\(ms > 100 ? " — over budget" : "", privacy: .public)")
        }
        watchTimer = timer
        timer.resume()
    }

    /// A new bitmap is on screen: time since the tab opened, or since the camera settled.
    func layerDrawn(_ layer: MapCoverageLayer) {
        if let openedAt {
            mark("open to \(layer.rawValue) ready", since: openedAt)
            self.openedAt = nil
        } else if let settledAt {
            mark("settle to \(layer.rawValue) redrawn", since: settledAt)
            self.settledAt = nil
        }
    }

    /// Logs `event` with the time since `start`, and clears nothing.
    func mark(_ event: String, since start: CFTimeInterval?) {
        guard let start else { return }
        let ms = (CACurrentMediaTime() - start) * 1_000
        Self.log.notice("\(event, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms, memory \(Self.memoryMegabytes(), format: .fixed(precision: 0), privacy: .public) MB")
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrame > 0 {
            let interval = now - lastFrame
            frames += 1
            worstFrame = max(worstFrame, interval)
            if interval > 0.020 { over20 += 1 }
            if interval > 0.050 { over50 += 1 }
        }
        lastFrame = now
        if CACurrentMediaTime() > activeUntil {
            finish()
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let seconds = CACurrentMediaTime() - startedAt
        let bodies = bodyEvaluations - bodyAtStart
        let meanCallback = callbacks > 0 ? callbackTime / Double(callbacks) * 1_000 : 0
        Self.log.notice("\(self.label, privacy: .public) \(seconds, format: .fixed(precision: 2), privacy: .public) s: frames \(self.frames, privacy: .public), over 20 ms \(self.over20, privacy: .public), over 50 ms \(self.over50, privacy: .public), worst \(self.worstFrame * 1_000, format: .fixed(precision: 1), privacy: .public) ms, body evaluations \(bodies, privacy: .public), camera callbacks \(self.callbacks, privacy: .public) mean \(meanCallback, format: .fixed(precision: 2), privacy: .public) ms worst \(self.worstCallback * 1_000, format: .fixed(precision: 2), privacy: .public) ms, memory \(Self.memoryMegabytes(), format: .fixed(precision: 0), privacy: .public) MB")
    }

    nonisolated static func memoryMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
