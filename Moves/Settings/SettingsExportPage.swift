//
//  SettingsExportPage.swift
//  Moves
//
//  Settings → Export and Backup: one export (what, which format, one button) and the
//  nightly iCloud Drive backup.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the person can export. Everything is a zip of every format for all days.
enum SettingsExportFormat: String, CaseIterable, Identifiable {
    case gpx
    case geoJSON
    case kml
    case csv
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpx: return String(localized: "GPX")
        case .geoJSON: return String(localized: "GeoJSON")
        case .kml: return String(localized: "KML")
        case .csv: return String(localized: "CSV")
        case .everything: return String(localized: "Everything")
        }
    }

    var timelineFormat: TimelineExportFormat? {
        switch self {
        case .gpx: return .gpx
        case .geoJSON: return .geoJSON
        case .kml: return .kml
        case .csv: return .csv
        case .everything: return nil
        }
    }
}

enum SettingsExportRange: String, CaseIterable, Identifiable {
    case selectedDay
    case allDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedDay: return String(localized: "Selected Day")
        case .allDays: return String(localized: "All Days")
        }
    }
}

struct ExportSettingsPage: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(DailyTimelineBackup.isEnabledKey) private var dailyBackupIsEnabled = false
    @AppStorage(DailyTimelineBackup.formatKey) private var dailyBackupFormat = DailyTimelineBackupFormat.gpx.rawValue
    @AppStorage(DailyTimelineBackup.usesMonthlyFoldersKey) private var dailyBackupUsesMonthlyFolders = false

    let dayTimelines: [DayTimeline]
    let selectedDayKey: String

    @State private var format: SettingsExportFormat = .gpx
    @State private var range: SettingsExportRange = .selectedDay
    @State private var isExporting = false
    @State private var exportDocument: TimelineExportDocument?
    @State private var exportContentType: UTType = .xml
    @State private var exportFilename = "moves-export"
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false
    @State private var dailyBackupMessage = ""
    @State private var isShowingDailyBackupMessage = false
    @State private var isRunningDailyBackup = false
    @State private var dailyBackupDidFail = false

    private var selectedDay: DayTimeline? {
        dayTimelines.first(where: { $0.dayKey == selectedDayKey })
    }

    private var rangeSummary: String {
        if format == .everything {
            return String(localized: "Every day in every format, with your places.")
        }
        switch range {
        case .selectedDay:
            guard let selectedDay else { return String(localized: "No day selected") }
            // The day's own date: `dayStart` on the phone's clock can be the date before.
            return selectedDay.calendarDate().formatted(date: .complete, time: .omitted)
        case .allDays:
            let count = dayTimelines.count
            return count == 1 ? String(localized: "1 day") : String(localized: "\(count.formatted(.number)) days")
        }
    }

    private var canExport: Bool {
        guard !dayTimelines.isEmpty else { return false }
        if format != .everything, range == .selectedDay {
            return selectedDay != nil
        }
        return true
    }

    var body: some View {
        SettingsScrollPage("Export and Backup") {
            SettingsCard(title: String(localized: "Export")) {
                LabeledContent("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(SettingsExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                }

                if format != .everything {
                    Picker("Days", selection: $range) {
                        ForEach(SettingsExportRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Days")
                }

                SettingsFootnote(rangeSummary)

                Button {
                    runExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!canExport)
            }

            SettingsCard(title: String(localized: "Daily Backup")) {
                Toggle("Back up to iCloud Drive every night", isOn: $dailyBackupIsEnabled)

                if dailyBackupIsEnabled {
                    LabeledContent("Format") {
                        Picker("Format", selection: $dailyBackupFormat) {
                            Text("GPX").tag(DailyTimelineBackupFormat.gpx.rawValue)
                            Text("GeoJSON").tag(DailyTimelineBackupFormat.geoJSON.rawValue)
                            Text("CSV").tag(DailyTimelineBackupFormat.csv.rawValue)
                        }
                        .labelsHidden()
                    }

                    Toggle("Sort into year and month folders", isOn: $dailyBackupUsesMonthlyFolders)

                    SettingsActionRow(
                        title: isRunningDailyBackup
                            ? String(localized: "Backing up…")
                            : String(localized: "Back up yesterday now"),
                        systemImage: "icloud.and.arrow.up",
                        isDisabled: isRunningDailyBackup
                    ) {
                        backUpYesterday()
                    }
                }

                // Shown inline as well as in the alert, so a result is never lost if
                // the alert cannot present.
                if !dailyBackupMessage.isEmpty {
                    Text(dailyBackupMessage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(dailyBackupDidFail ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsFootnote(String(localized: "Saves each day to the Moves folder in iCloud Drive."))
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success(let url):
                exportMessage = String(localized: "Saved \(url.lastPathComponent).")
            case .failure(let error):
                exportMessage = String(localized: "Couldn’t export: \(error.localizedDescription)")
            }
            isShowingExportMessage = true
        }
        .onChange(of: dailyBackupIsEnabled) { _, _ in
            if let error = DailyTimelineBackup.scheduleNextRun() {
                dailyBackupMessage = error.localizedDescription
                isShowingDailyBackupMessage = true
            }
        }
        .onChange(of: dailyBackupFormat) { _, _ in
            DailyTimelineBackup.scheduleNextRun()
        }
        .onChange(of: dailyBackupUsesMonthlyFolders) { _, _ in
            DailyTimelineBackup.scheduleNextRun()
        }
        .alert("Export", isPresented: $isShowingExportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
        .alert("Daily Backup", isPresented: $isShowingDailyBackupMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dailyBackupMessage)
        }
    }

    private func runExport() {
        if let timelineFormat = format.timelineFormat {
            export(timelineFormat, scope: range == .allDays ? .allDays : .selectedDay)
        } else {
            exportZip()
        }
    }

    private func export(_ format: TimelineExportFormat, scope: TimelineExportScope) {
        let days: [DayTimeline]
        let scopeName: String

        switch scope {
        case .allDays:
            days = dayTimelines
            scopeName = "all-days"

        case .selectedDay:
            guard let selectedDay else {
                exportMessage = String(localized: "Choose a day on the timeline first.")
                isShowingExportMessage = true
                return
            }
            days = [selectedDay]
            scopeName = selectedDay.dayKey
        }

        guard !days.isEmpty else {
            exportMessage = String(localized: "There’s nothing to export yet.")
            isShowingExportMessage = true
            return
        }

        guard let payload = TimelineExporter.makePayload(
            days: days,
            format: format,
            fileStem: "moves-\(scopeName)",
            privacyZones: currentExportPrivacyZones()
        ) else {
            exportMessage = String(localized: "Couldn’t create the export.")
            isShowingExportMessage = true
            return
        }

        exportDocument = TimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    private func currentExportPrivacyZones(places: [KnownPlace]? = nil) -> [PrivacyZone] {
        PrivacyZoneResolver.exportZones(
            from: places ?? PrivacyZoneResolver.loadPlaces(from: modelContext)
        )
    }

    /// Writes GPX, GeoJSON, CSV, KML, `places.json`, and `photos.csv` into one zip.
    private func exportZip() {
        guard !dayTimelines.isEmpty else {
            exportMessage = String(localized: "There’s nothing to export yet.")
            isShowingExportMessage = true
            return
        }

        let knownPlaces = (try? modelContext.fetch(FetchDescriptor<KnownPlace>())) ?? []
        let photos = (try? modelContext.fetch(FetchDescriptor<PhotoAttachment>())) ?? []

        guard let payload = TimelineExporter.makeZipPayload(
            days: dayTimelines,
            knownPlaces: knownPlaces,
            photos: photos,
            fileStem: "moves-all-days",
            privacyZones: currentExportPrivacyZones(places: knownPlaces)
        ) else {
            exportMessage = String(localized: "Couldn’t create the export.")
            isShowingExportMessage = true
            return
        }

        exportDocument = TimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    private func backUpYesterday() {
        guard !isRunningDailyBackup else { return }
        isRunningDailyBackup = true

        let container = modelContext.container
        Task { @MainActor in
            defer { isRunningDailyBackup = false }
            do {
                let url = try await DailyTimelineBackup.saveYesterday(in: container)
                dailyBackupDidFail = false
                dailyBackupMessage = String(localized: "Saved \(url.lastPathComponent) to iCloud Drive.")
            } catch {
                dailyBackupDidFail = true
                dailyBackupMessage = String(localized: "Backup didn’t finish: \(error.localizedDescription)")
                DailyTimelineBackup.log.error("Manual backup failed: \(String(describing: error), privacy: .public)")
            }
            isShowingDailyBackupMessage = true
        }
    }
}
