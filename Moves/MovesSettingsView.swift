//
//  MovesSettingsView.swift
//  Raul
//
//  Settings root: a short list of destinations, each pushing its own page.
//  The pages live in `Moves/Settings/`.
//

import Foundation
import Combine
import CoreLocation
import HealthKit
import SwiftData
import SwiftUI
import UIKit

/// Every page Settings can push. Launch flags and the iCloud page's backup row build a
/// path from these, so each page is reachable without scrolling a long screen.
enum SettingsPage: Hashable {
    case tracking
    case routeTracking
    case travelModes
    case map
    case health
    case photos
    case calendar
    case connections
    case service(LocationService)
    case webhook
    case importData
    case googleTimeline
    case timelineArchive
    case routeFiles
    case fogOfWorld
    case export
    case iCloud
    case privacy
    case appIcon
    case maintenance
    case about

    /// Pages that screenshot agents can open directly with `MOVES_SETTINGS_PAGE=<name>`.
    private static let launchNames: [String: [SettingsPage]] = [
        "tracking": [.tracking],
        "routeTracking": [.tracking, .routeTracking],
        "travelModes": [.travelModes],
        "map": [.map],
        "health": [.health],
        "photos": [.photos],
        "calendar": [.calendar],
        "connections": [.connections],
        "webhook": [.connections, .webhook],
        "import": [.importData],
        "googleTimeline": [.importData, .googleTimeline],
        "export": [.export],
        "iCloud": [.iCloud],
        "privacy": [.privacy],
        "appIcon": [.appIcon],
        "maintenance": [.maintenance],
        "about": [.about],
    ]

    /// The stack Settings opens on for this launch. Empty means the root list.
    static func launchPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> [SettingsPage] {
        if let name = env["MOVES_SETTINGS_PAGE"], let path = launchNames[name] {
            return path
        }
        if env["MOVES_OPEN_GOOGLE_IMPORT"] == "1" { return [.importData, .googleTimeline] }
        if env["MOVES_OPEN_WEBHOOK"] == "1" { return [.connections, .webhook] }
        if env["MOVES_OPEN_ICLOUD"] == "1" { return [.iCloud] }
        if env["MOVES_OPEN_PRIVACY"] == "1" { return [.privacy] }
        if env["MOVES_OPEN_AUTOMATIC_MODES"] == "1" { return [.travelModes] }
        return []
    }
}

extension EnvironmentValues {
    /// Closes the whole Settings sheet from any page. `nil` outside Settings.
    @Entry var closeSettings: DismissAction? = nil
}

struct MovesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationServiceSyncManager: LocationServiceSyncManager
    @EnvironmentObject private var webhookSyncManager: WebhookSyncManager
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @EnvironmentObject private var calendarSync: MovesCalendarSync
    @EnvironmentObject private var photoLibrary: PhotoLibraryController
    @EnvironmentObject private var importQueue: DurableImportQueue
    @AppStorage(DailyTimelineBackup.isEnabledKey) private var dailyBackupIsEnabled = false
    @AppStorage(PrivacyZoneSettings.isEnabledKey) private var privacyZonesAreEnabled = false
    @AppStorage(HealthWorkoutRouteImportSettings.isEnabledKey) private var healthRoutesAreEnabled = false
    @AppStorage(HealthActivitySettings.isEnabledKey) private var healthActivityIsEnabled = false
    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showsPhotosOnVisits = true
    @AppStorage(PhotoLibrarySettings.usesCameraPhotosAsFixesKey) private var usesCameraPhotos = true

    let dayTimelines: [DayTimeline]
    let selectedDayKey: String
    @ObservedObject private var captureManager: MovesLocationCaptureManager

    @State private var path: [SettingsPage] = SettingsPage.launchPath()
    @State private var appIconStore = AppIconStore()

    init(
        dayTimelines: [DayTimeline],
        selectedDayKey: String,
        captureManager: MovesLocationCaptureManager
    ) {
        self.dayTimelines = dayTimelines
        self.selectedDayKey = selectedDayKey
        self.captureManager = captureManager
    }

    /// Earliest day that already has GPS, imported, or manual timeline items.
    private var firstProtectedDayStart: Date? {
        dayTimelines
            .filter(\.isProtectedFromPhotoBackfill)
            .map(\.dayStart)
            .min()
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    SettingsCard(title: String(localized: "Recording")) {
                        row(.tracking, String(localized: "Tracking"), "location.fill", trackingStatus)
                        row(.travelModes, String(localized: "Travel Modes"), "figure.walk", nil)
                        row(.map, String(localized: "Map"), "map", nil)
                    }

                    SettingsCard(title: String(localized: "Apps and Services")) {
                        row(.health, String(localized: "Apple Health"), "heart.fill", healthStatus)
                        row(.photos, String(localized: "Photos"), "photo.on.rectangle", photosStatus)
                        row(.calendar, String(localized: "Calendar"), "calendar", calendarStatus)
                        row(.connections, String(localized: "Connections"), "server.rack", connectionsStatus)
                    }

                    SettingsCard(title: String(localized: "Your Data")) {
                        row(.importData, String(localized: "Import"), "square.and.arrow.down", importStatus)
                        row(.export, String(localized: "Export and Backup"), "square.and.arrow.up", exportStatus)
                        row(.iCloud, String(localized: "iCloud"), "icloud", cloudDataPresencePublisher.status.title)
                        row(.privacy, String(localized: "Privacy Zones"), "hand.raised.fill", privacyStatus)
                    }

                    SettingsCard(title: String(localized: "App")) {
                        if appIconStore.isSupported {
                            row(.appIcon, String(localized: "App Icon"), "app.badge", nil)
                        }
                        row(.maintenance, String(localized: "Maintenance"), "wrench.and.screwdriver", nil)
                        row(.about, String(localized: "About"), "info.circle", appVersion)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                destination(for: page)
            }
        }
        .environment(\.closeSettings, dismiss)
        .onAppear {
            DailyTimelineBackup.scheduleNextRun()
        }
    }

    private func row(_ page: SettingsPage, _ title: String, _ systemImage: String, _ status: String?) -> some View {
        NavigationLink(value: page) {
            SettingsNavigationRow(title: title, systemImage: systemImage, status: status)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func destination(for page: SettingsPage) -> some View {
        switch page {
        case .tracking:
            TrackingSettingsPage(captureManager: captureManager)
        case .routeTracking:
            RouteTrackingSettingsPage(captureManager: captureManager)
        case .travelModes:
            AutomaticModesSettingsView()
        case .map:
            MapSettingsPage()
        case .health:
            HealthWorkoutRouteImportSettingsView()
        case .photos:
            PhotosSettingsPage(firstRecordedDayStart: firstProtectedDayStart)
        case .calendar:
            CalendarSyncSettingsView()
        case .connections:
            ConnectionsSettingsPage()
        case .service(let service):
            LocationServiceSettingsView(service: service)
        case .webhook:
            WebhookSettingsView()
        case .importData:
            ImportSettingsPage()
        case .googleTimeline:
            GoogleTimelineImportSettingsView(modelContext: modelContext)
        case .timelineArchive:
            TimelineArchiveImportSettingsView(modelContext: modelContext)
        case .routeFiles:
            RouteFileImportSettingsView(modelContext: modelContext)
        case .fogOfWorld:
            FogCoverageSettingsView()
        case .export:
            ExportSettingsPage(dayTimelines: dayTimelines, selectedDayKey: selectedDayKey)
        case .iCloud:
            ICloudSettingsPage {
                path.append(.export)
            }
        case .privacy:
            PrivacyZonesSettingsPage()
        case .appIcon:
            AppIconPickerView(store: appIconStore)
        case .maintenance:
            MaintenanceSettingsPage()
        case .about:
            AboutSettingsPage()
        }
    }

    // MARK: Row states

    private var trackingStatus: String {
        if captureManager.isDemoMode {
            return captureManager.captureDetailLevel.title
        }
        switch captureManager.authorizationStatus {
        case .notDetermined, .denied, .restricted:
            return String(localized: "Needs location access")
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            break
        }
        if let endsAt = captureManager.temporaryRouteTrackingEndsAt, endsAt > .now {
            return String(localized: "Route tracking on")
        }
        guard captureManager.isBackgroundLocationListeningEnabled else {
            return String(localized: "Off")
        }
        return captureManager.captureDetailLevel.title
    }

    private var healthStatus: String {
        guard HKHealthStore.isHealthDataAvailable() else { return String(localized: "Unavailable") }
        return healthRoutesAreEnabled || healthActivityIsEnabled ? String(localized: "On") : String(localized: "Off")
    }

    private var photosStatus: String {
        guard photoLibrary.hasReadAccess, showsPhotosOnVisits || usesCameraPhotos else {
            return String(localized: "Off")
        }
        return photoLibrary.isLimited ? String(localized: "Selected photos") : String(localized: "On")
    }

    private var calendarStatus: String {
        calendarSync.isEnabled ? String(localized: "On") : String(localized: "Off")
    }

    private var connectionsStatus: String {
        let services = LocationService.allCases.filter { locationServiceSyncManager.state(for: $0).isConfigured }
        let count = services.count + (webhookSyncManager.state.isConfigured ? 1 : 0)
        switch count {
        case 0:
            return String(localized: "None")
        case 1:
            if let service = services.first {
                return locationServiceSyncManager.connectionSummary(for: service)
            }
            return webhookSyncManager.connectionSummary
        default:
            return String(localized: "\(count) connected")
        }
    }

    private var importStatus: String? {
        importQueue.workingJobID != nil || importQueue.isStaging ? String(localized: "Importing") : nil
    }

    private var exportStatus: String? {
        dailyBackupIsEnabled ? String(localized: "Daily backup on") : nil
    }

    private var privacyStatus: String {
        privacyZonesAreEnabled ? String(localized: "On") : String(localized: "Off")
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

// MARK: - Shared page pieces

/// Background, inline title, and a Done button that closes Settings, for every page.
struct SettingsPageChrome: ViewModifier {
    @Environment(\.closeSettings) private var closeSettings
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey

    func body(content: Content) -> some View {
        content
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if let closeSettings {
                            closeSettings()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
    }
}

extension View {
    func settingsPageChrome(_ title: LocalizedStringKey) -> some View {
        modifier(SettingsPageChrome(title: title))
    }
}

/// A scrolling column of cards with the standard Settings spacing.
struct SettingsScrollPage<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .settingsPageChrome(title)
    }
}

/// One line of explanation under a setting.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

struct SettingsActionRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .padding(.vertical, 5)
    }
}

/// A full-width row that pushes a page: icon, title, an optional line under the title,
/// and the current state at the trailing edge. The state truncates; the title never does.
/// At accessibility text sizes the state moves under the title.
struct SettingsNavigationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// One width for every icon, so titles line up down the list.
    @ScaledMetric(relativeTo: .body) private var iconWidth = 28

    let title: String
    let systemImage: String
    let status: String?
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if dynamicTypeSize.isAccessibilitySize, let status {
                        statusText(status)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: iconWidth)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !dynamicTypeSize.isAccessibilitySize, let status {
                statusText(status)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ status: String) -> some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Route tracking

/// The sheet behind the timeline's route-tracking button.
struct RouteTrackingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let captureManager: MovesLocationCaptureManager

    var body: some View {
        NavigationStack {
            ScrollView {
                RouteTrackingSettingsSection(captureManager: captureManager, showsEverydayTracking: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Real Route Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Settings → Tracking → Real Route Tracking. Everyday tracking is on the Tracking page itself.
struct RouteTrackingSettingsPage: View {
    let captureManager: MovesLocationCaptureManager

    var body: some View {
        ScrollView {
            RouteTrackingSettingsSection(captureManager: captureManager, showsEverydayTracking: false)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .settingsPageChrome("Real Route Tracking")
    }
}

// MARK: - Apple Health

struct HealthWorkoutRouteImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeSettings) private var closeSettings
    @EnvironmentObject private var healthRouteImportManager: HealthWorkoutRouteAutoImportManager
    @AppStorage(HealthWorkoutRouteImportSettings.isEnabledKey) private var isEnabled = false
    @AppStorage(HealthActivitySettings.isEnabledKey) private var usesActivity = false

    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: {
                isEnabled = $0
                notifySettingsChanged()
            }
        )
    }

    private var isHealthAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Turning it on shows the Health permission sheet (in one request with routes).
    private var usesActivityBinding: Binding<Bool> {
        Binding(
            get: { usesActivity },
            set: { newValue in
                guard newValue, !HealthActivitySettings.usesDemoData else {
                    usesActivity = newValue
                    notifyActivitySettingChanged()
                    return
                }
                Task { @MainActor in
                    do {
                        try await HealthKitActivityReader().requestAuthorization()
                        usesActivity = true
                        notifyActivitySettingChanged()
                    } catch {
                        importMessage = error.localizedDescription
                        isShowingImportMessage = true
                    }
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if !isHealthAvailable {
                    SettingsCard(title: String(localized: "Apple Health")) {
                        SettingsFootnote(String(localized: "Apple Health isn’t available on this device."))
                    }
                }

                SettingsCard(title: String(localized: "Steps and Walking Distance")) {
                    Toggle("Use steps and walking distance", isOn: usesActivityBinding)
                        .disabled(!isHealthAvailable)

                    SettingsFootnote(String(localized: "Makes walking distances and totals more accurate."))
                }

                SettingsCard(title: String(localized: "Workout Routes")) {
                    Toggle("Add workout routes", isOn: isEnabledBinding)
                        .disabled(!isHealthAvailable || healthRouteImportManager.isHistoricalImporting)

                    SettingsFootnote(String(localized: "Adds the routes of new workouts to your timeline."))
                }

                SettingsCard(title: String(localized: "Past Workouts")) {
                    Button {
                        importAllRoutes()
                    } label: {
                        Label {
                            Text(importAllButtonTitle)
                                .frame(maxWidth: .infinity)
                        } icon: {
                            Image(systemName: importAllButtonSystemImage)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .tint(isImporting ? .red : MovesPalette.routeTracking)
                    .disabled(!isHealthAvailable && !isImporting)

                    if isImporting {
                        ProgressView()
                            .tint(MovesPalette.routeTracking)

                        if !healthRouteImportManager.historicalImportProgressText.isEmpty {
                            SettingsFootnote(healthRouteImportManager.historicalImportProgressText)
                        }
                    }

                    SettingsFootnote(importAllHelpText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    if let closeSettings {
                        closeSettings()
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .alert("Apple Health", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .onChange(of: healthRouteImportManager.isHistoricalImporting) { wasImporting, isImporting in
            guard wasImporting, !isImporting else { return }
            showHistoricalImportResultIfAvailable()
        }
    }

    private var importAllButtonTitle: String {
        if isImporting {
            return String(localized: "Cancel Import")
        }

        if HealthWorkoutRouteImporter.hasInterruptedHistoricalImport {
            return String(localized: "Resume Workout Import")
        }

        return String(localized: "Import All Workout Routes")
    }

    private var importAllButtonSystemImage: String {
        isImporting ? "pause.circle.fill" : "tray.and.arrow.down.fill"
    }

    private var importAllHelpText: String {
        if isImporting {
            return String(localized: "You can leave this screen. If Moves is closed, you can resume from here.")
        }

        if HealthWorkoutRouteImporter.hasInterruptedHistoricalImport {
            return String(localized: "Resume picks up from the last workout it checked.")
        }

        return String(localized: "Adds the routes of every past workout in Apple Health.")
    }

    private func notifyActivitySettingChanged() {
        NotificationCenter.default.post(name: HealthActivitySettings.didChangeNotification, object: nil)
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(
            name: HealthWorkoutRouteImportSettings.didChangeNotification,
            object: nil
        )
    }

    @MainActor
    private func importAllRoutes() {
        if isImporting {
            healthRouteImportManager.cancelHistoricalImport()
            return
        }

        healthRouteImportManager.startHistoricalImportIfNeeded()
    }

    private var isImporting: Bool {
        healthRouteImportManager.isHistoricalImporting
    }

    private func showHistoricalImportResultIfAvailable() {
        if let report = healthRouteImportManager.lastHistoricalImportReport {
            let routes = report.routeCount.formatted(.number)
            let workouts = report.workoutCount.formatted(.number)
            importMessage = report.didResumeInterruptedImport
                ? String(localized: "Finished importing. Added \(routes) routes from \(workouts) workouts.")
                : String(localized: "Added \(routes) routes from \(workouts) workouts.")
            isShowingImportMessage = true
        } else if let message = healthRouteImportManager.lastHistoricalImportErrorMessage {
            importMessage = message
            isShowingImportMessage = true
        }
    }
}

// MARK: - Route tracking section

@MainActor
private func routeTrackingBannerData(
    authorizationStatus: CLAuthorizationStatus,
    lastErrorMessage: String?,
    duration: TemporaryRouteTrackingDuration,
    endsAt: Date?,
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool,
    isBackgroundLocationListeningEnabled: Bool,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
    if let lastErrorMessage {
        return TrackingStatusBannerData(
            title: String(localized: "Location tracking error"),
            message: lastErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    if let endsAt, endsAt > .now {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: String(localized: "Real route tracking on"),
                message: routeTrackingBannerMessage(
                    duration: duration,
                    stopsAtFiftyPercentBattery: stopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: stopsInLowPowerMode,
                    authorizationStatus: authorizationStatus
                ),
                systemImage: "location.fill.viewfinder",
                tint: MovesPalette.routeTracking,
                buttonTitle: context == .timeline ? String(localized: "Turn off now") : nil,
                buttonRole: context == .timeline ? .destructive : nil
            )
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    guard context == .settings else {
        return nil
    }

    switch authorizationStatus {
    case .authorizedAlways:
        if !isBackgroundLocationListeningEnabled {
            return TrackingStatusBannerData(
                title: String(localized: "Background recording is off"),
                message: String(localized: "Moves isn’t recording until you turn it back on."),
                systemImage: "location.slash",
                tint: .secondary
            )
        }

        return TrackingStatusBannerData(
            title: String(localized: "Recording in the background"),
            message: String(localized: "Moves records your places and trips."),
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        return TrackingStatusBannerData(
            title: String(localized: "Recording while Moves is open"),
            message: String(localized: "Allow Always location access to record in the background."),
            systemImage: "location.fill",
            tint: MovesPalette.start
        )
    case .notDetermined:
        return TrackingStatusBannerData(
            title: String(localized: "Location access needed"),
            message: String(localized: "Allow location access to start recording."),
            systemImage: "location.slash",
            tint: .secondary
        )
    case .denied:
        return TrackingStatusBannerData(
            title: String(localized: "Location access is off"),
            message: String(localized: "Turn on location for Moves in Settings to record your days."),
            systemImage: "location.slash",
            tint: .secondary
        )
    case .restricted:
        return TrackingStatusBannerData(
            title: String(localized: "Location access is blocked"),
            message: String(localized: "This iPhone doesn’t allow Moves to use location."),
            systemImage: "lock.fill",
            tint: .secondary
        )
    @unknown default:
        return nil
    }
}

private func routeTrackingBannerMessage(
    duration: TemporaryRouteTrackingDuration,
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool,
    authorizationStatus: CLAuthorizationStatus
) -> String {
    let durationText = duration.availabilityText
    let autoStopText = routeTrackingAutoStopText(
        stopsAtFiftyPercentBattery: stopsAtFiftyPercentBattery,
        stopsInLowPowerMode: stopsInLowPowerMode
    )

    switch authorizationStatus {
    case .authorizedWhenInUse:
        return String(localized: "Following every turn \(durationText) while Moves is open.\(autoStopText)")
    default:
        return String(localized: "Following every turn \(durationText).\(autoStopText)")
    }
}

private func routeTrackingAutoStopText(
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool
) -> String {
    switch (stopsAtFiftyPercentBattery, stopsInLowPowerMode) {
    case (true, true):
        return String(localized: " Stops at 50% battery or in Low Power Mode.")
    case (true, false):
        return String(localized: " Stops at 50% battery.")
    case (false, true):
        return String(localized: " Stops in Low Power Mode.")
    case (false, false):
        return ""
    }
}

private struct RouteTrackingSettingsSection: View {
    @Environment(\.openURL) private var openURL
    let captureManager: MovesLocationCaptureManager
    /// The timeline's sheet also shows background recording and tracking detail. In
    /// Settings those sit on the Tracking page one level up.
    let showsEverydayTracking: Bool

    @State private var routeTrackingDuration: TemporaryRouteTrackingDuration
    @State private var routeTrackingEndsAt: Date?
    @State private var routeTrackingAuthorizationStatus: CLAuthorizationStatus
    @State private var routeTrackingLastErrorMessage: String?
    @State private var routeTrackingStopsAtFiftyPercentBattery: Bool
    @State private var routeTrackingStopsInLowPowerMode: Bool
    @State private var routeTrackingStopNotificationEnabled: Bool
    @State private var isBackgroundLocationListeningEnabled: Bool
    @State private var captureDetailLevel: CaptureDetailLevel
    @State private var isShowingNotificationPermissionAlert = false

    init(captureManager: MovesLocationCaptureManager, showsEverydayTracking: Bool) {
        self.captureManager = captureManager
        self.showsEverydayTracking = showsEverydayTracking
        _routeTrackingDuration = State(initialValue: captureManager.temporaryRouteTrackingDuration)
        _routeTrackingEndsAt = State(initialValue: captureManager.temporaryRouteTrackingEndsAt)
        _routeTrackingAuthorizationStatus = State(initialValue: captureManager.authorizationStatus)
        _routeTrackingLastErrorMessage = State(initialValue: captureManager.lastErrorMessage)
        _routeTrackingStopsAtFiftyPercentBattery = State(
            initialValue: captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
        )
        _routeTrackingStopsInLowPowerMode = State(
            initialValue: captureManager.temporaryRouteTrackingStopsInLowPowerMode
        )
        _routeTrackingStopNotificationEnabled = State(
            initialValue: captureManager.temporaryRouteTrackingStopNotificationEnabled
        )
        _isBackgroundLocationListeningEnabled = State(
            initialValue: captureManager.isBackgroundLocationListeningEnabled
        )
        _captureDetailLevel = State(initialValue: captureManager.captureDetailLevel)
    }

    private var routeTrackingStopsAtBatteryFiftyBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopsAtFiftyPercentBattery },
            set: { newValue in
                routeTrackingStopsAtFiftyPercentBattery = newValue
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: newValue,
                    stopsInLowPowerMode: routeTrackingStopsInLowPowerMode
                )
            }
        )
    }

    private var routeTrackingStopsInLowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopsInLowPowerMode },
            set: { newValue in
                routeTrackingStopsInLowPowerMode = newValue
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: routeTrackingStopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: newValue
                )
            }
        )
    }

    private var routeTrackingStopNotificationBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopNotificationEnabled },
            set: { newValue in
                if newValue {
                    Task { @MainActor in
                        await enableRouteTrackingStopNotifications()
                    }
                } else {
                    routeTrackingStopNotificationEnabled = false
                    captureManager.disableTemporaryRouteTrackingStopNotifications()
                }
            }
        )
    }

    private var bannerData: TrackingStatusBannerData? {
        // The Tracking page already says whether recording works; here only route
        // tracking itself and errors are worth a banner.
        if !showsEverydayTracking, !isRouteTrackingActive, routeTrackingLastErrorMessage == nil {
            return nil
        }
        return routeTrackingBannerData(
            authorizationStatus: routeTrackingAuthorizationStatus,
            lastErrorMessage: routeTrackingLastErrorMessage,
            duration: routeTrackingDuration,
            endsAt: routeTrackingEndsAt,
            stopsAtFiftyPercentBattery: routeTrackingStopsAtFiftyPercentBattery,
            stopsInLowPowerMode: routeTrackingStopsInLowPowerMode,
            isBackgroundLocationListeningEnabled: isBackgroundLocationListeningEnabled,
            context: .settings
        )
    }

    private var isRouteTrackingActive: Bool {
        guard let routeTrackingEndsAt else { return false }
        return routeTrackingEndsAt > .now
    }

    @MainActor
    private func enableRouteTrackingStopNotifications() async {
        let result = await captureManager.enableTemporaryRouteTrackingStopNotifications()
        routeTrackingStopNotificationEnabled = true

        if result == .needsSettings {
            isShowingNotificationPermissionAlert = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let bannerData {
                TrackingStatusBanner(data: bannerData)
            }

            if showsEverydayTracking {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Everyday Tracking")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Record in the background",
                        isOn: $isBackgroundLocationListeningEnabled
                    )
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                    SettingsFootnote(String(localized: "Records your places and trips while Moves is closed."))

                    Divider()

                    Text("Tracking detail")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))

                    Picker("Tracking detail", selection: $captureDetailLevel) {
                        ForEach(CaptureDetailLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Tracking detail")

                    SettingsFootnote(captureDetailLevel.summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Real Route Tracking")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Follows every turn of a trip for a while. Uses more battery.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if routeTrackingAuthorizationStatus == .authorizedAlways ||
                    routeTrackingAuthorizationStatus == .authorizedWhenInUse {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Duration")
                                .gridColumnAlignment(.leading)

                            Menu {
                                ForEach(TemporaryRouteTrackingDuration.allCases) { duration in
                                    Button {
                                        routeTrackingDuration = duration
                                    } label: {
                                        if routeTrackingDuration == duration {
                                            Label(duration.title, systemImage: "checkmark")
                                        } else {
                                            Text(duration.title)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(routeTrackingDuration.title)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .buttonStyle(.bordered)
                            .gridColumnAlignment(.trailing)
                        }

                        GridRow {
                            Text("Turn off at 50% battery")

                            Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
                                .labelsHidden()
                        }

                        GridRow {
                            Text("Turn off in Low Power Mode")

                            Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)
                                .labelsHidden()
                        }

                        GridRow {
                            Text("Notify when tracking stops")

                            Toggle("Notify when tracking stops", isOn: routeTrackingStopNotificationBinding)
                                .labelsHidden()
                        }
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))

                    Button {
                        if isRouteTrackingActive {
                            captureManager.disableTemporaryRouteTracking()
                        } else {
                            captureManager.enableTemporaryRouteTracking(duration: routeTrackingDuration)
                        }
                    } label: {
                        Label(
                            isRouteTrackingActive
                            ? String(localized: "Turn Off")
                            : String(localized: "Start Real Route Tracking"),
                            systemImage: isRouteTrackingActive
                            ? "location.slash"
                            : "location.fill.viewfinder"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .tint(isRouteTrackingActive ? .red : nil)

                    if isRouteTrackingActive, let routeTrackingEndsAt {
                        SettingsFootnote(String(localized: "Turns off at \(routeTrackingEndsAt.formatted(date: .omitted, time: .shortened))."))
                    }

                    if routeTrackingAuthorizationStatus == .authorizedWhenInUse {
                        SettingsFootnote(String(localized: "Allow Always location access to keep this on while Moves is closed."))
                    }
                } else {
                    SettingsFootnote(String(localized: "Allow location access to use route tracking."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface()
        }
        .onReceive(captureManager.$temporaryRouteTrackingDuration.removeDuplicates()) { routeTrackingDuration = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingEndsAt.removeDuplicates()) { routeTrackingEndsAt = $0 }
        .onReceive(captureManager.$authorizationStatus.removeDuplicates()) { routeTrackingAuthorizationStatus = $0 }
        .onReceive(captureManager.$lastErrorMessage.removeDuplicates()) { routeTrackingLastErrorMessage = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsAtFiftyPercentBattery.removeDuplicates()) { routeTrackingStopsAtFiftyPercentBattery = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsInLowPowerMode.removeDuplicates()) { routeTrackingStopsInLowPowerMode = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopNotificationEnabled.removeDuplicates()) { routeTrackingStopNotificationEnabled = $0 }
        .onReceive(captureManager.$isBackgroundLocationListeningEnabled.removeDuplicates()) { isBackgroundLocationListeningEnabled = $0 }
        .onChange(of: isBackgroundLocationListeningEnabled) { _, isEnabled in
            captureManager.setBackgroundLocationListeningEnabled(isEnabled)
        }
        .onReceive(captureManager.$captureDetailLevel.removeDuplicates()) { captureDetailLevel = $0 }
        .onChange(of: captureDetailLevel) { _, level in
            captureManager.setCaptureDetailLevel(level)
        }
        .alert("Notifications Are Off", isPresented: $isShowingNotificationPermissionAlert) {
            Button("Open Settings") {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Allow notifications for Moves in Settings to hear when route tracking stops.")
        }
    }
}
