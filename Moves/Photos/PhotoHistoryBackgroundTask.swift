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

    /// Asks for time while the phone is idle.
    static func scheduleResume() {
        guard !ProcessInfo.processInfo.isRunningUnitTests else { return }
        let request = BGProcessingTaskRequest(identifier: resumeIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
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
        task.progress.totalUnitCount = 1_000
        let reporting = Task { @MainActor in
            // The system ends a task that shows no progress, and reading a large library
            // takes a while before the first photo is imported.
            var readingShare: Int64 = 0
            while !Task.isCancelled, let job = controller.historyJob {
                if job.lastProgressAt == nil || controller.isReadingLibrary {
                    readingShare = min(readingShare + 1, 50)
                }
                let imported = Int64((Double(1_000 - readingShare) * job.fractionComplete).rounded(.down))
                let completed = min(readingShare + imported, 999)
                if completed > task.progress.completedUnitCount {
                    task.progress.completedUnitCount = completed
                }
                task.updateTitle(controller.continuingTitle, subtitle: controller.continuingSubtitle)
                try? await Task.sleep(for: .seconds(1))
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
            Task { @MainActor in
                controller.endWork(with: .continuedTask)
                _ = await work.value
            }
        }
    }
}
