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
    case routeTrackingOptions
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
        "routeTracking": [.routeTracking],
        "routeTrackingOptions": [.routeTracking, .routeTrackingOptions],
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
    @ObservedObject private var routeTrackingPreview = RouteTrackingPreview.shared

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
                        row(.routeTracking, String(localized: "Route Tracking"), "location.fill.viewfinder", routeTrackingStatus)
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
        case .routeTrackingOptions:
            RouteTrackingOptionsPage(captureManager: captureManager)
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

    /// "Off" or "On until 6:00 PM", the same words the Route Tracking card uses.
    private var routeTrackingStatus: String {
        RouteTrackingControl(captureManager: captureManager, preview: routeTrackingPreview).statusText()
    }

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
        if captureManager.isPreciseLocationOff {
            return String(localized: "Precise Location off")
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

/// The sheet behind the timeline's route-tracking button: Start (or Stop) first, then
/// everyday recording.
struct RouteTrackingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let captureManager: MovesLocationCaptureManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    RouteTrackingCard(captureManager: captureManager)
                    EverydayTrackingCard(captureManager: captureManager)
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
            .navigationTitle(String(localized: "Route Tracking"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                if page == .routeTrackingOptions {
                    RouteTrackingOptionsPage(captureManager: captureManager)
                }
            }
        }
    }
}

/// Settings → Route Tracking, one tap from the root. The same card sits on the Tracking page.
struct RouteTrackingSettingsPage: View {
    let captureManager: MovesLocationCaptureManager

    var body: some View {
        SettingsScrollPage("Route Tracking") {
            RouteTrackingCard(captureManager: captureManager)
        }
    }
}

// MARK: Route tracking state

/// Debug builds only: `MOVES_ROUTE_TRACKING_PREVIEW=1` stands in for route tracking in the
/// simulator, where capture runs in demo mode and Start does nothing. It changes what the
/// screens show, never what is recorded; a release build never reads the variable.
@MainActor
final class RouteTrackingPreview: ObservableObject {
    static let shared = RouteTrackingPreview()
    private static let durationKey = "MovesRouteTrackingPreviewDuration"

    let isActive: Bool
    @Published private(set) var endsAt: Date?
    @Published private(set) var duration: TemporaryRouteTrackingDuration

    private init() {
        #if DEBUG
        isActive = ProcessInfo.processInfo.environment["MOVES_ROUTE_TRACKING_PREVIEW"] == "1"
        #else
        isActive = false
        #endif
        duration = UserDefaults.standard.string(forKey: Self.durationKey)
            .flatMap(TemporaryRouteTrackingDuration.init(rawValue:)) ?? .endOfDay
    }

    func start(_ duration: TemporaryRouteTrackingDuration) {
        guard isActive else { return }
        self.duration = duration
        UserDefaults.standard.set(duration.rawValue, forKey: Self.durationKey)
        if let interval = duration.timeInterval {
            endsAt = Date.now.addingTimeInterval(interval)
        } else {
            let calendar = Calendar.autoupdatingCurrent
            endsAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))?
                .addingTimeInterval(-1)
        }
    }

    func stop() {
        endsAt = nil
    }
}

/// Route Tracking's state, Start, and Stop for every surface that shows them: the timeline
/// button and banner, the sheet, the Tracking page, and the Settings root row.
@MainActor
struct RouteTrackingControl {
    let captureManager: MovesLocationCaptureManager
    var preview: RouteTrackingPreview = .shared

    var endsAt: Date? {
        preview.isActive ? preview.endsAt : captureManager.temporaryRouteTrackingEndsAt
    }

    /// The last duration used, which Start offers again.
    var duration: TemporaryRouteTrackingDuration {
        preview.isActive ? preview.duration : captureManager.temporaryRouteTrackingDuration
    }

    var authorization: CLAuthorizationStatus {
        preview.isActive ? .authorizedAlways : captureManager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    }

    func isRunning(at date: Date = .now) -> Bool {
        guard isAuthorized, let endsAt else { return false }
        return endsAt > date
    }

    func start(_ duration: TemporaryRouteTrackingDuration) {
        if preview.isActive {
            preview.start(duration)
        } else {
            captureManager.enableTemporaryRouteTracking(duration: duration)
        }
    }

    func stop() {
        if preview.isActive {
            preview.stop()
        } else {
            captureManager.disableTemporaryRouteTracking()
        }
    }

    /// "On until 6:00 PM" or "Off".
    func statusText(at date: Date = .now) -> String {
        guard isRunning(at: date), let endsAt else { return String(localized: "Off") }
        return String(localized: "On until \(endsAt.formatted(date: .omitted, time: .shortened))")
    }

    /// "1h 12m left", or seconds in the last minute, the way the timeline button counts down.
    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(max(Int(ceil(seconds)), 0))s"
        }
        return DurationFormatter.text(for: seconds)
    }
}

/// Start and Stop for Route Tracking, with the duration. The one implementation, shown in
/// the timeline's sheet, on the Tracking page, and on its own page from the Settings root.
struct RouteTrackingCard: View {
    @ObservedObject var captureManager: MovesLocationCaptureManager
    @ObservedObject private var preview = RouteTrackingPreview.shared
    var showsOptions = true

    /// A duration picked here but not started yet; nil offers the last one used.
    @State private var pickedDuration: TemporaryRouteTrackingDuration?

    private var control: RouteTrackingControl {
        RouteTrackingControl(captureManager: captureManager, preview: preview)
    }

    private var duration: TemporaryRouteTrackingDuration {
        pickedDuration ?? control.duration
    }

    var body: some View {
        SettingsCard(title: String(localized: "Route Tracking")) {
            SettingsFootnote(String(localized: "Follows every turn of a trip for a set time. Uses more battery."))

            if control.isAuthorized {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if control.isRunning(at: context.date) {
                        running(at: context.date)
                    } else {
                        idle
                    }
                }

                if control.authorization == .authorizedWhenInUse {
                    SettingsFootnote(String(localized: "Allow Always location access to keep this on while Moves is closed."))
                }
            } else {
                SettingsFootnote(String(localized: "Allow location access to use Route Tracking."))
            }

            if let error = captureManager.lastErrorMessage, !preview.isActive {
                SettingsFootnote(error)
                    .foregroundStyle(.red)
            }

            if showsOptions {
                Divider()
                NavigationLink(value: SettingsPage.routeTrackingOptions) {
                    SettingsNavigationRow(
                        title: String(localized: "Options"),
                        systemImage: "slider.horizontal.3",
                        status: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "For"))
                    .font(.system(.body, design: .rounded, weight: .medium))
                Spacer(minLength: 8)
                Menu {
                    ForEach(TemporaryRouteTrackingDuration.allCases) { option in
                        Button {
                            pickedDuration = option
                        } label: {
                            if option == duration {
                                Label(option.localizedTitle, systemImage: "checkmark")
                            } else {
                                Text(option.localizedTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(duration.localizedTitle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(String(localized: "Duration, \(duration.localizedTitle)"))
            }

            Button {
                control.start(duration)
                pickedDuration = nil
            } label: {
                Label(String(localized: "Start Route Tracking"), systemImage: "location.fill.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(MovesPalette.routeTracking)
        }
    }

    private func running(at date: Date) -> some View {
        let remaining = (control.endsAt ?? date).timeIntervalSince(date)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "location.fill.viewfinder")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.statusText(at: date))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text(String(localized: "\(RouteTrackingControl.remainingText(remaining)) left"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Button(role: .destructive) {
                control.stop()
            } label: {
                Label(String(localized: "Stop"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.red)
        }
    }
}

extension TemporaryRouteTrackingDuration {
    /// "30 minutes", "Until end of day".
    var localizedTitle: String {
        switch self {
        case .thirtyMinutes: return String(localized: "30 minutes")
        case .oneHour: return String(localized: "1 hour")
        case .twoHours: return String(localized: "2 hours")
        case .fourHours: return String(localized: "4 hours")
        case .endOfDay: return String(localized: "Until end of day")
        }
    }
}

/// Background recording and tracking detail, under Route Tracking in the timeline's sheet.
/// In Settings these sit on the Tracking page.
private struct EverydayTrackingCard: View {
    @ObservedObject var captureManager: MovesLocationCaptureManager

    var body: some View {
        SettingsCard(title: String(localized: "Everyday Tracking")) {
            Toggle(
                "Record in the background",
                isOn: Binding(
                    get: { captureManager.isBackgroundLocationListeningEnabled },
                    set: { captureManager.setBackgroundLocationListeningEnabled($0) }
                )
            )
            .font(.system(size: 15, weight: .semibold, design: .rounded))

            SettingsFootnote(String(localized: "Records your places and trips while Moves is closed."))

            Divider()

            Picker(
                "Tracking detail",
                selection: Binding(
                    get: { captureManager.captureDetailLevel },
                    set: { captureManager.setCaptureDetailLevel($0) }
                )
            ) {
                ForEach(CaptureDetailLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Tracking detail")

            SettingsFootnote(captureManager.captureDetailLevel.summary)
        }
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

// MARK: - Route tracking options

/// Settings → Route Tracking → Options: the rules for stopping on its own.
struct RouteTrackingOptionsPage: View {
    let captureManager: MovesLocationCaptureManager

    var body: some View {
        SettingsScrollPage("Options") {
            RouteTrackingOptionsCard(captureManager: captureManager)
        }
    }
}

private struct RouteTrackingOptionsCard: View {
    @Environment(\.openURL) private var openURL
    let captureManager: MovesLocationCaptureManager

    @State private var routeTrackingStopsAtFiftyPercentBattery: Bool
    @State private var routeTrackingStopsInLowPowerMode: Bool
    @State private var routeTrackingStopNotificationEnabled: Bool
    @State private var isShowingNotificationPermissionAlert = false

    init(captureManager: MovesLocationCaptureManager) {
        self.captureManager = captureManager
        _routeTrackingStopsAtFiftyPercentBattery = State(
            initialValue: captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
        )
        _routeTrackingStopsInLowPowerMode = State(
            initialValue: captureManager.temporaryRouteTrackingStopsInLowPowerMode
        )
        _routeTrackingStopNotificationEnabled = State(
            initialValue: captureManager.temporaryRouteTrackingStopNotificationEnabled
        )
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

    @MainActor
    private func enableRouteTrackingStopNotifications() async {
        let result = await captureManager.enableTemporaryRouteTrackingStopNotifications()
        routeTrackingStopNotificationEnabled = true

        if result == .needsSettings {
            isShowingNotificationPermissionAlert = true
        }
    }

    var body: some View {
        SettingsCard(title: String(localized: "Stop on Its Own")) {
            Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
            Divider()
            Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)
            Divider()
            Toggle("Notify when tracking stops", isOn: routeTrackingStopNotificationBinding)
        }
        .font(.system(size: 15, weight: .medium, design: .rounded))
        .onReceive(captureManager.$temporaryRouteTrackingStopsAtFiftyPercentBattery.removeDuplicates()) { routeTrackingStopsAtFiftyPercentBattery = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsInLowPowerMode.removeDuplicates()) { routeTrackingStopsInLowPowerMode = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopNotificationEnabled.removeDuplicates()) { routeTrackingStopNotificationEnabled = $0 }
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
