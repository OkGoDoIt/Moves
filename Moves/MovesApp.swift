//
//  MovesApp.swift
//  Moves
//
//  Created by Holger Krupp on 23.07.24.
//

import SwiftUI
import SwiftData
import AppIntents
import UIKit
import UserNotifications

final class MovesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.applicationSupportsShakeToEdit = true
        UNUserNotificationCenter.current().delegate = self
        DailyTimelineBackup.registerBackgroundTask()
        ShareMapAggregateBackgroundTask.register()
        RouteMatchBackgroundTask.register()
        PlaceGeocodeBackfill.register()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class AppUndoController: ObservableObject {
    let manager = UndoManager()
}

@main
struct MovesApp: App {
    @UIApplicationDelegateAdaptor(MovesAppDelegate.self) private var appDelegate
    private static let cloudKitContainerIdentifier = MovesAppIdentity.cloudKitContainerIdentifier
    private static var processContainer: ModelContainer?
    static private(set) var privateMirrorIsActive: Bool?
    @State private var startup: Result<MovesRuntime, Error>

    init() { _startup = State(initialValue: Result { MovesRuntime(container: try Self.sharedContainer()) }) }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let runtime):
                MovesRunningContent(runtime: runtime)
            case .failure:
                ContentUnavailableView {
                    Label("Timeline couldn’t be opened", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Try again to reopen your saved history.")
                } actions: {
                    Button("Try again") { startup = Result { MovesRuntime(container: try Self.sharedContainer()) } }
                }
            }
        }
    }

    /// The store's one container for this process.
    ///
    /// Background tasks launch alongside the app, and a second container would mean a
    /// second CloudKit mirror and a second coordinator on one file, with neither told
    /// about the other's deletes.
    static func sharedContainer() throws -> ModelContainer {
        if let processContainer { return processContainer }
        _ = MovesMirrorEventBuffer.shared
        let container = try makeModelContainer()
        processContainer = container
        return container
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let timelineSchema = Schema(MovesTimelineSchema.models)
        let cacheSchema = Schema([ShareMapAggregate.self])
        let schema = Schema(MovesTimelineSchema.models + [ShareMapAggregate.self])

        let cacheConfiguration: ModelConfiguration
        #if targetEnvironment(simulator)
        privateMirrorIsActive = false
        // Opens a copy of a real store, to check a change against real history.
        if let path = ProcessInfo.processInfo.environment["MOVES_SIMULATOR_STORE"] {
            let storeURL = URL(fileURLWithPath: path)
            let cacheURL = storeURL.deletingLastPathComponent().appendingPathComponent("ShareMapCache.store")
            return try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(schema: timelineSchema, url: storeURL, cloudKitDatabase: .none),
                    ModelConfiguration("ShareMapCache", schema: cacheSchema, url: cacheURL, cloudKitDatabase: .none),
                ]
            )
        }
        let modelConfiguration = ModelConfiguration(
            schema: timelineSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: cacheSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration, cacheConfiguration]
        )
        SimulatorDemoDataSeeder.seedIfNeeded(in: container)
        return container
        #else
        cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: cacheSchema,
            cloudKitDatabase: .none
        )
        let allowsMirror = allowsCloudKitContainer()
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase =
            allowsMirror ? .private(Self.cloudKitContainerIdentifier) : .none
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(schema: timelineSchema, cloudKitDatabase: cloudKitDatabase),
                    cacheConfiguration,
                ]
            )
            privateMirrorIsActive = allowsMirror
            return container
        } catch {
            privateMirrorIsActive = false
            // A local-only store still records today's timeline, which beats refusing
            // to launch.
            return try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(schema: timelineSchema, cloudKitDatabase: .none),
                    cacheConfiguration,
                ]
            )
        }
        #endif
    }

    /// Whether this process may mirror the timeline to its private CloudKit container.
    ///
    /// Core Data aborts the process (`SIGTRAP` on `com.apple.coredata.cloudkit.queue`)
    /// rather than throwing when SwiftData enables CloudKit without the iCloud
    /// container entitlement, so the decision has to be made up front. The `SecTask`
    /// entitlement APIs are not imported into Swift on iOS, which leaves reading the
    /// embedded provisioning profile.
    ///
    /// Locally signed builds embed a profile that can be inspected — a wildcard
    /// development profile, for instance, carries no iCloud identifiers. App Store
    /// builds embed no profile at all and are signed by Apple straight from the
    /// project's entitlements, so a missing profile means "trust the entitlements".
    static func allowsCloudKitContainer() -> Bool {
        guard let entitlements = embeddedProvisioningEntitlements() else { return true }
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        return containers?.contains(cloudKitContainerIdentifier) ?? false
    }

    /// Entitlements from the bundle's `embedded.mobileprovision`.
    ///
    /// - Returns: The entitlements dictionary, or `nil` when the bundle carries no
    ///   provisioning profile or it cannot be read.
    private static func embeddedProvisioningEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let xml = provisioningProfilePlistData(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist["Entitlements"] as? [String: Any]
    }

    /// Extracts the XML plist payload from a CMS-wrapped `.mobileprovision` file.
    private static func provisioningProfilePlistData(in data: Data) -> Data? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker),
              let end = data.range(of: endMarker, in: start.lowerBound..<data.endIndex)
        else {
            return nil
        }
        return Data(data[start.lowerBound..<end.upperBound])
    }

}

/// Process-lifetime owners; rendering or rotating a view cannot create capture or upload workers.
@MainActor
private final class MovesRuntime: ObservableObject {
    let container: ModelContainer
    let undoController = AppUndoController()
    let captureManager: MovesLocationCaptureManager
    let watchRouteInbox: WatchRouteInbox
    let healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager
    let cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    let locationServiceSyncManager: LocationServiceSyncManager
    let photoLibraryController: PhotoLibraryController
    let webhookSyncManager: WebhookSyncManager
    let calendarSync: MovesCalendarSync
    let importQueue: DurableImportQueue
    init(container: ModelContainer) {
        self.container = container
        captureManager = MovesLocationCaptureManager(modelContainer: container)
        watchRouteInbox = WatchRouteInbox(modelContainer: container)
        healthWorkoutRouteAutoImporter = HealthWorkoutRouteAutoImportManager(modelContainer: container)
        cloudDataPresencePublisher = MovesCloudDataPresencePublisher(modelContainer: container)
        locationServiceSyncManager = LocationServiceSyncManager(modelContainer: container)
        photoLibraryController = PhotoLibraryController(modelContainer: container)
        webhookSyncManager = WebhookSyncManager(modelContainer: container)
        calendarSync = MovesCalendarSync(container: container)
        importQueue = DurableImportQueue(container: container)
        MovesIntentRuntime.shared.configure(modelContainer: container, captureManager: captureManager)
        MovesAppShortcuts.updateAppShortcutParameters()
        if !ProcessInfo.processInfo.isRunningUnitTests { TimelineSchemaUpgrader.runIfNeeded(container: container) }
    }
}

/// Workers exist only after the authoritative store opens; a failed launch never creates a replacement history.
private struct MovesRunningContent: View {
    @Environment(\.scenePhase) private var scenePhase
    private let sharedModelContainer: ModelContainer
    @State private var isUpgradingTimeline: Bool
    @ObservedObject private var undoController: AppUndoController
    @ObservedObject private var captureManager: MovesLocationCaptureManager
    @ObservedObject private var watchRouteInbox: WatchRouteInbox
    @ObservedObject private var healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager
    @ObservedObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @ObservedObject private var locationServiceSyncManager: LocationServiceSyncManager
    @ObservedObject private var photoLibraryController: PhotoLibraryController
    @ObservedObject private var webhookSyncManager: WebhookSyncManager
    @ObservedObject private var importQueue: DurableImportQueue
    @ObservedObject private var calendarSync: MovesCalendarSync

    init(runtime: MovesRuntime) {
        sharedModelContainer = runtime.container
        _captureManager = ObservedObject(wrappedValue: runtime.captureManager)
        _watchRouteInbox = ObservedObject(wrappedValue: runtime.watchRouteInbox)
        _healthWorkoutRouteAutoImporter = ObservedObject(wrappedValue: runtime.healthWorkoutRouteAutoImporter)
        _cloudDataPresencePublisher = ObservedObject(wrappedValue: runtime.cloudDataPresencePublisher)
        _locationServiceSyncManager = ObservedObject(wrappedValue: runtime.locationServiceSyncManager)
        _photoLibraryController = ObservedObject(wrappedValue: runtime.photoLibraryController)
        _webhookSyncManager = ObservedObject(wrappedValue: runtime.webhookSyncManager)
        _calendarSync = ObservedObject(wrappedValue: runtime.calendarSync)
        _importQueue = ObservedObject(wrappedValue: runtime.importQueue)
        _undoController = ObservedObject(wrappedValue: runtime.undoController)
        _isUpgradingTimeline = State(initialValue: TimelineSchemaUpgrader.isRunning)
    }

    var body: some View {
        Group {
            if isUpgradingTimeline {
                // The upgrade deletes duplicate rows, and a view reading a row deleted on
                // another context aborts the process, so no timeline views exist until it ends.
                TimelineUpgradeView()
                    .task {
                        await TimelineSchemaUpgrader.waitUntilFinished()
                        isUpgradingTimeline = false
                    }
            } else {
                MovesRootView()
                    .environmentObject(captureManager)
                    .environmentObject(undoController)
                    .environmentObject(healthWorkoutRouteAutoImporter)
                    .environmentObject(cloudDataPresencePublisher)
                    .environmentObject(locationServiceSyncManager)
                    .environmentObject(photoLibraryController)
                    .environmentObject(webhookSyncManager)
                    .environmentObject(calendarSync)
                    .environmentObject(importQueue)
            }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            importQueue.sceneChanged(newPhase)
            if newPhase == .active {
                DailyTimelineBackup.scheduleNextRun()
                ShareMapAggregateBackgroundTask.scheduleNextRun()
                PlaceGeocodeBackfill.scheduleNextRun()
                Task {
                    await TimelineSchemaUpgrader.waitUntilFinished()
                    await captureManager.start()
                    await captureManager.refreshHistoricalBackfill()
                    healthWorkoutRouteAutoImporter.refreshInterruptedHistoricalImportState()
                    await healthWorkoutRouteAutoImporter.startIfNeeded()
                    await cloudDataPresencePublisher.publishNow()
                    await locationServiceSyncManager.syncNewSamplesIfEnabled()
                    await photoLibraryController.handleSceneBecameActive()
                    await webhookSyncManager.syncNewItemsIfEnabled()
                    calendarSync.schedule()
                }
                Task(priority: .utility) {
                    await ShareMapAggregateBuilder.refreshAll(in: sharedModelContainer)
                }
                Task(priority: .utility) {
                    await TimelineSchemaUpgrader.waitUntilFinished()
                    await PlaceGeocodeBackfill.runForegroundTrickle(in: sharedModelContainer)
                }
            }
        }
    }
}

private struct TimelineUpgradeView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Updating your timeline")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
