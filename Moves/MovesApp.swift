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
    @StateObject private var undoController = AppUndoController()
    @StateObject private var captureManager: MovesLocationCaptureManager
    @StateObject private var watchRouteInbox: WatchRouteInbox
    @StateObject private var healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager
    @StateObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @StateObject private var locationServiceSyncManager: LocationServiceSyncManager

    init() {
        do {
            let container = try Self.makeModelContainer()
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
            MovesIntentRuntime.shared.configure(
                modelContainer: container,
                captureManager: captureManager
            )
            MovesAppShortcuts.updateAppShortcutParameters()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    static func makeModelContainer() throws -> ModelContainer {
        let timelineSchema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])
        let cacheSchema = Schema([ShareMapAggregate.self])
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
            ShareMapAggregate.self,
        ])

        let cacheConfiguration: ModelConfiguration
        #if targetEnvironment(simulator)
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
    private static func allowsCloudKitContainer() -> Bool {
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
            ContentView()
                .environmentObject(captureManager)
                .environmentObject(undoController)
                .environmentObject(healthWorkoutRouteAutoImporter)
                .environmentObject(cloudDataPresencePublisher)
                .environmentObject(locationServiceSyncManager)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DailyTimelineBackup.scheduleNextRun()
                ShareMapAggregateBackgroundTask.scheduleNextRun()
                Task {
                    await captureManager.start()
                    await captureManager.refreshHistoricalBackfill()
                    healthWorkoutRouteAutoImporter.refreshInterruptedHistoricalImportState()
                    await healthWorkoutRouteAutoImporter.startIfNeeded()
                    await cloudDataPresencePublisher.publishNow()
                    await locationServiceSyncManager.syncNewSamplesIfEnabled()
                }
                Task(priority: .utility) {
                    await ShareMapAggregateBuilder.refreshAll(in: sharedModelContainer)
                }
            }
        }
    }
}

extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
