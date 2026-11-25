//
//  SettingsPages.swift
//  Moves
//
//  The smaller Settings pages: Map, Photos, Connections, Import, iCloud, Privacy Zones,
//  Maintenance, and About. Each composes existing cards; none owns sync or import logic.
//

import HealthKit
import SwiftData
import SwiftUI

// MARK: - Map

struct MapSettingsPage: View {
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true
    @AppStorage(RouteSnappingLevel.storageKey) private var snappingLevel = RouteSnappingLevel.normal.rawValue
    @AppStorage(LandscapeLayoutSettings.controlsOnLeftKey) private var landscapeControlsOnLeft = false

    private var snappingSummary: String {
        switch RouteSnappingLevel(rawValue: snappingLevel) ?? .normal {
        case .normal:
            return String(localized: "Routes follow the roads you took.")
        case .conservative:
            return String(localized: "Only well-recorded routes follow roads.")
        case .off:
            return String(localized: "Routes show exactly what was recorded.")
        }
    }

    var body: some View {
        SettingsScrollPage("Map") {
            SettingsCard(title: String(localized: "Places and Routes")) {
                Toggle("Big map markers", isOn: $showsBigMarkers)
                SettingsFootnote(String(localized: "Shows places as large pins instead of small dots."))

                Divider()

                Toggle("Shade routes by speed", isOn: $shadeRoutesBySpeed)
                SettingsFootnote(String(localized: "Routes get lighter where you went faster."))
            }

            SettingsCard(title: String(localized: "Path")) {
                Picker("Path", selection: $snappingLevel) {
                    ForEach(RouteSnappingLevel.allCases) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Path matching")

                SettingsFootnote(snappingSummary)
            }

            SettingsCard(title: String(localized: "Landscape")) {
                Toggle("Controls on the left", isOn: $landscapeControlsOnLeft)
                SettingsFootnote(String(localized: "Moves places, moves, and edit controls to the left side."))
            }
        }
    }
}

// MARK: - Photos

struct PhotosSettingsPage: View {
    let firstRecordedDayStart: Date?

    var body: some View {
        SettingsScrollPage("Photos") {
            PhotosSettingsCard(firstRecordedDayStart: firstRecordedDayStart)
        }
    }
}

// MARK: - Connections

struct ConnectionsSettingsPage: View {
    @EnvironmentObject private var locationServiceSyncManager: LocationServiceSyncManager
    @EnvironmentObject private var webhookSyncManager: WebhookSyncManager

    var body: some View {
        SettingsScrollPage("Connections") {
            SettingsCard(title: String(localized: "Location Servers")) {
                ForEach(LocationService.allCases) { service in
                    NavigationLink(value: SettingsPage.service(service)) {
                        SettingsNavigationRow(
                            title: service.title,
                            systemImage: service.systemImage,
                            status: locationServiceSyncManager.connectionSummary(for: service)
                        )
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink(value: SettingsPage.webhook) {
                    SettingsNavigationRow(
                        title: String(localized: "Webhook"),
                        systemImage: "link",
                        status: webhookSyncManager.connectionSummary
                    )
                }
                .buttonStyle(.plain)

                SettingsFootnote(String(localized: "Sends new points to your own location server as you record."))
            }
        }
    }
}

// MARK: - Import

struct ImportSettingsPage: View {
    var body: some View {
        SettingsScrollPage("Import") {
            ImportQueueCard()

            SettingsCard(title: String(localized: "Import From")) {
                row(
                    .googleTimeline,
                    title: String(localized: "Google Timeline"),
                    detail: String(localized: "Your Location History from Google Takeout"),
                    systemImage: "globe"
                )
                row(
                    .timelineArchive,
                    title: String(localized: "Moves Export"),
                    detail: String(localized: "Files exported or backed up from Moves"),
                    systemImage: "clock.arrow.circlepath"
                )
                row(
                    .routeFiles,
                    title: String(localized: "GPS Files"),
                    detail: String(localized: "Tracks from other apps and devices"),
                    systemImage: "square.and.arrow.down"
                )
                row(
                    .health,
                    title: String(localized: "Apple Health Workouts"),
                    detail: String(localized: "Routes from your past workouts"),
                    systemImage: "figure.run",
                    status: HKHealthStore.isHealthDataAvailable() ? nil : String(localized: "Unavailable")
                )
                row(
                    .fogOfWorld,
                    title: String(localized: "Fog of World"),
                    detail: String(localized: "Areas you’ve explored"),
                    systemImage: "map"
                )
            }
        }
    }

    private func row(
        _ page: SettingsPage,
        title: String,
        detail: String,
        systemImage: String,
        status: String? = nil
    ) -> some View {
        NavigationLink(value: page) {
            SettingsNavigationRow(title: title, systemImage: systemImage, status: status, detail: detail)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iCloud

struct ICloudSettingsPage: View {
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    let onOpenBackup: () -> Void

    var body: some View {
        SettingsScrollPage("iCloud") {
            ICloudSettingsCard(publisher: cloudDataPresencePublisher, onOpenDailyBackup: onOpenBackup)
        }
    }
}

// MARK: - Privacy Zones

struct PrivacyZonesSettingsPage: View {
    var body: some View {
        SettingsScrollPage("Privacy Zones") {
            PrivacyZonesSettingsCard()
        }
    }
}

// MARK: - Maintenance

struct MaintenanceSettingsPage: View {
    @Environment(\.modelContext) private var modelContext

    @State private var hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot
    @State private var isConfirmingHistoricalDeduplication = false
    @State private var isRunningHistoricalDeduplication = false
    @State private var isUndoingHistoricalDeduplication = false
    @State private var maintenanceMessage = ""
    @State private var isShowingMaintenanceMessage = false

    var body: some View {
        SettingsScrollPage("Maintenance") {
            SettingsCard(title: String(localized: "Duplicates")) {
                SettingsActionRow(
                    title: isRunningHistoricalDeduplication
                        ? String(localized: "Removing duplicates…")
                        : String(localized: "Remove duplicate places and moves"),
                    systemImage: "wand.and.stars",
                    isDisabled: isRunningHistoricalDeduplication || isUndoingHistoricalDeduplication
                ) {
                    isConfirmingHistoricalDeduplication = true
                }

                SettingsActionRow(
                    title: isUndoingHistoricalDeduplication
                        ? String(localized: "Putting them back…")
                        : String(localized: "Undo last cleanup"),
                    systemImage: "arrow.uturn.backward.circle",
                    isDisabled: !hasDedupeUndoSnapshot
                        || isRunningHistoricalDeduplication
                        || isUndoingHistoricalDeduplication
                ) {
                    undoHistoricalDeduplication()
                }

                SettingsFootnote(String(localized: "You can undo a cleanup here afterward."))
            }
        }
        .onAppear {
            hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot
        }
        .confirmationDialog(
            "Remove Duplicates?",
            isPresented: $isConfirmingHistoricalDeduplication,
            titleVisibility: .visible
        ) {
            Button("Remove Duplicates", role: .destructive) {
                runHistoricalDeduplication()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Merges places and moves that were recorded twice. You can undo this afterward.")
        }
        .alert("Maintenance", isPresented: $isShowingMaintenanceMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(maintenanceMessage)
        }
    }

    @MainActor
    private func runHistoricalDeduplication() {
        guard !isRunningHistoricalDeduplication, !isUndoingHistoricalDeduplication else { return }

        isRunningHistoricalDeduplication = true

        Task { @MainActor in
            defer { isRunningHistoricalDeduplication = false }

            do {
                let repository = SwiftDataTimelineRepository(modelContext: modelContext)
                let snapshot = try repository.createUndoSnapshot()
                try TimelineDeduplicationSnapshotStore.save(snapshot)

                let report = try repository.runHistoricalDeduplication()
                try TimelineDeduplicationSnapshotStore.save(
                    snapshot.changes(comparedTo: repository.createUndoSnapshot())
                )
                hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot

                if report.totalRemovedCount == 0 {
                    maintenanceMessage = String(localized: "No duplicates found.")
                } else {
                    let places = report.removedPlaceCount.formatted(.number)
                    let moves = report.removedMoveCount.formatted(.number)
                    maintenanceMessage = String(localized: "Removed duplicates: \(places) places and \(moves) moves.")
                }
            } catch {
                maintenanceMessage = String(localized: "Couldn’t remove duplicates: \(error.localizedDescription)")
            }

            isShowingMaintenanceMessage = true
        }
    }

    @MainActor
    private func undoHistoricalDeduplication() {
        guard hasDedupeUndoSnapshot, !isUndoingHistoricalDeduplication, !isRunningHistoricalDeduplication else {
            return
        }

        isUndoingHistoricalDeduplication = true

        Task { @MainActor in
            defer { isUndoingHistoricalDeduplication = false }

            do {
                let snapshot = try TimelineDeduplicationSnapshotStore.load()
                let repository = SwiftDataTimelineRepository(modelContext: modelContext)
                try repository.restoreFromUndoSnapshot(snapshot)
                try TimelineDeduplicationSnapshotStore.clear()
                hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot
                maintenanceMessage = String(localized: "Put back what the last cleanup merged.")
            } catch {
                maintenanceMessage = String(localized: "Couldn’t undo: \(error.localizedDescription)")
            }

            isShowingMaintenanceMessage = true
        }
    }
}

// MARK: - About

struct AboutSettingsPage: View {
    var body: some View {
        SettingsScrollPage("About") {
            CreatedByView()
                .frame(maxWidth: .infinity)
                .panelSurface()
        }
    }
}
