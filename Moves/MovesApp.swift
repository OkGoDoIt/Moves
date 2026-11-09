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
    @Environment(\.scenePhase) private var scenePhase
    private static let cloudKitContainerIdentifier = MovesAppIdentity.cloudKitContainerIdentifier

    private let sharedModelContainer: ModelContainer
    private static var processContainer: ModelContainer?
    @State private var isUpgradingTimeline: Bool
    @StateObject private var undoController = AppUndoController()
    @StateObject private var captureManager: MovesLocationCaptureManager
    @StateObject private var watchRouteInbox: WatchRouteInbox
    @StateObject private var healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager
    @StateObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @StateObject private var locationServiceSyncManager: LocationServiceSyncManager
    @StateObject private var photoLibraryController: PhotoLibraryController
    @StateObject private var webhookSyncManager: WebhookSyncManager
    @StateObject private var calendarSync: MovesCalendarSync

    init() {
        do {
            let container = try Self.sharedContainer()
            let captureManager = MovesLocationCaptureManager(modelContainer: container)
            self.sharedModelContainer = container
            _captureManager = StateObject(
                wrappedValue: captureManager
            )
            _watchRouteInbox = StateObject(
                wrappedValue: WatchRouteInbox(modelContainer: container)
            )
            _healthWorkoutRouteAutoImporter = StateObject(
                wrappedValue: HealthWorkoutRouteAutoImportManager(modelContainer: container)
            )
            _cloudDataPresencePublisher = StateObject(
                wrappedValue: MovesCloudDataPresencePublisher(modelContainer: container)
            )
            _locationServiceSyncManager = StateObject(
                wrappedValue: LocationServiceSyncManager(modelContainer: container)
            )
            _photoLibraryController = StateObject(
                wrappedValue: PhotoLibraryController(modelContainer: container)
            )
            _webhookSyncManager = StateObject(
                wrappedValue: WebhookSyncManager(modelContainer: container)
            )
            _calendarSync = StateObject(wrappedValue: MovesCalendarSync(container: container))
            MovesIntentRuntime.shared.configure(
                modelContainer: container,
                captureManager: captureManager
            )
            MovesAppShortcuts.updateAppShortcutParameters()
            if !ProcessInfo.processInfo.isRunningUnitTests {
                TimelineSchemaUpgrader.runIfNeeded(container: container)
            }
            _isUpgradingTimeline = State(initialValue: TimelineSchemaUpgrader.isRunning)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// The store's one container for this process.
    ///
    /// Background tasks launch alongside the app, and a second container would mean a
    /// second CloudKit mirror and a second coordinator on one file, with neither told
    /// about the other's deletes.
    static func sharedContainer() throws -> ModelContainer {
        if let processContainer { return processContainer }
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
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase =
            allowsCloudKitContainer() ? .private(Self.cloudKitContainerIdentifier) : .none
        do {
            return try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(schema: timelineSchema, cloudKitDatabase: cloudKitDatabase),
                    cacheConfiguration,
                ]
            )
        } catch {
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

    var body: some Scene {
        WindowGroup {
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
            }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
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
