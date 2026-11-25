import BackgroundTasks
import Foundation

/// Keeps the photo-history import going when Moves is not on screen.
///
/// Three kinds of time carry it. Started or resumed while Moves is open, a continued task
/// goes on after the person leaves, with its progress shown by the system. After Moves was
/// closed, crashed, or the phone restarted, a processing task brings it back while the
/// phone is idle. And each time the phone wakes Moves for a new fix, a step or two fit in
/// (`PhotoLibraryController.workBriefly`).
enum PhotoHistoryBackgroundTask {
    /// Must stay in sync with `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
    static let resumeIdentifier = "\(MovesAppIdentity.bundleIdentifier).photoHistory"
    static let continuedIdentifier = "\(MovesAppIdentity.bundleIdentifier).photoHistoryNow.import"

    static func register() {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: resumeIdentifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { return }
            MainActor.assumeIsolated { handle(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedIdentifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated { handle(task) }
        }
    }

    /// Asks for time while the phone is idle. A request that is already waiting is left
    /// alone: replacing it would send it to the back of the line.
    static func scheduleResume() {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            guard !pending.contains(where: { $0.identifier == resumeIdentifier }) else { return }
            let request = BGProcessingTaskRequest(identifier: resumeIdentifier)
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    static func cancelResume() {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: resumeIdentifier)
    }

    /// Asks to go on after the person leaves Moves. Only possible while Moves is open.
    static func requestContinuing(title: String, subtitle: String) throws {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedIdentifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .queue
        try BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGProcessingTask) {
        // Covers being stopped before this run can say what comes next.
        scheduleResume()
        guard let controller = PhotoLibraryController.current else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            await controller.workUntilDone(with: .processingTask)
            if controller.isImporting {
                scheduleResume()
            } else {
                cancelResume()
            }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            Task { @MainActor in
                controller.endWork(with: .processingTask)
                _ = await work.value
            }
        }
    }

    @MainActor
    private static func handle(_ task: BGContinuedProcessingTask) {
        guard let controller = PhotoLibraryController.current else {
            task.setTaskCompleted(success: false)
            return
        }
        task.progress.totalUnitCount = 1_000_000
        let reporting = Task { @MainActor in
            // The system ends a task that looks stalled, and between two parts of a large
            // library or two steps of the import there is nothing new to count. So the
            // progress also creeps toward the next of them while it is being worked on.
            var subtitle = ""
            while !Task.isCancelled, let job = controller.historyJob {
                let isImportStarted = job.lastProgressAt != nil
                let read = 100_000 * (isImportStarted ? 1 : controller.libraryReadShare)
                let done = read + 900_000 * job.fractionComplete
                let nextStretch = isImportStarted ? 4_000.0 : 1_000.0
                let shown = Double(task.progress.completedUnitCount)
                let creeping = shown + max((done + nextStretch - shown) * 0.05, 1)
                task.progress.completedUnitCount = min(Int64(max(done, creeping)), 999_000)
                if controller.continuingSubtitle != subtitle {
                    subtitle = controller.continuingSubtitle
                    task.updateTitle(controller.continuingTitle, subtitle: subtitle)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let work = Task { @MainActor in
            await controller.workUntilDone(with: .continuedTask)
            reporting.cancel()
            if !controller.isImporting {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: !controller.isImporting)
        }
        task.expirationHandler = {
            let reached = task.progress.completedUnitCount
            Task { @MainActor in
                controller.continuedTaskExpired(after: reached)
                _ = await work.value
            }
        }
    }
}
