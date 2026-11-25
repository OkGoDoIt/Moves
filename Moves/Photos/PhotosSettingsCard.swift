import Photos
import SwiftData
import SwiftUI

/// Settings → Photos. Additive card: access, Limited Library, and history backfill.
struct PhotosSettingsCard: View {
    @EnvironmentObject private var photoLibrary: PhotoLibraryController
    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showOnVisits = true
    @AppStorage(PhotoLibrarySettings.usesCameraPhotosAsFixesKey) private var usesCameraPhotos = true

    let firstRecordedDayStart: Date?

    @State private var isShowingImporter = false

    var body: some View {
        SettingsCard(title: "Photos") {
            Toggle("Show photos on visits", isOn: $showOnVisits)
                .onChange(of: showOnVisits) { _, isOn in
                    if isOn {
                        Task { await enablePhotos() }
                    }
                }

            Toggle("Use photos I take for location", isOn: $usesCameraPhotos)
                .onChange(of: usesCameraPhotos) { _, isOn in
                    if isOn {
                        Task { await enableCameraPhotos() }
                    }
                }

            Text("A photo you take with this iPhone adds its location to your timeline. Screenshots, saved photos, and photos from other phones in your library are left out.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if usesCameraPhotos, photoLibrary.hasReadAccess {
                PhotoFixStatusLine(
                    status: photoLibrary.fixStatus,
                    isChecking: photoLibrary.isCheckingRecentPhotos
                )
            }

            if !photoLibrary.ownCameraPeriods.isEmpty {
                OwnCameraList(periods: photoLibrary.ownCameraPeriods)
            }

            Text(accessExplanation)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if photoLibrary.isLimited {
                Button {
                    photoLibrary.presentLimitedLibraryPicker()
                } label: {
                    Label("Choose Photos…", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }

            Divider()

            Button {
                Task { await presentImporter() }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Label("Rebuild history from photos…", systemImage: "clock.arrow.circlepath")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let job = photoLibrary.historyJob {
                        PhotoHistoryProgressSummary(
                            job: job,
                            isWorking: photoLibrary.isHistoryImportWorking,
                            timeRemaining: photoLibrary.historyTimeRemaining,
                            isReadingLibrary: photoLibrary.isReadingLibrary
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)

            Text("Photos stay on this device. Moves never changes your library, and share cards do not include them.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $isShowingImporter) {
            PhotoHistoryImportSheet(firstRecordedDayStart: firstRecordedDayStart)
                .environmentObject(photoLibrary)
        }
    }

    private var accessExplanation: String {
        switch photoLibrary.authorizationStatus {
        case .limited:
            return "Limited Access is on. Only the photos you pick can appear on visits or rebuild history. iOS has no read-only option; Moves still never adds, edits, or deletes photos."
        case .authorized:
            return "Moves can read geotagged photos to show them on visits. It never adds, edits, or deletes anything in your library."
        case .denied, .restricted:
            return "Photos access is off. Enable it in Settings if you want thumbnails on visits or to rebuild earlier days from photo locations."
        default:
            return "iOS only offers full or limited library access — there is no read-only switch. Moves never modifies photos. If you choose Limited Access, only the photos you pick are used."
        }
    }

    private func enablePhotos() async {
        let status = await photoLibrary.requestAccess()
        if status == .denied || status == .restricted {
            showOnVisits = false
        }
    }

    private func enableCameraPhotos() async {
        let status = await photoLibrary.requestAccess()
        if status == .denied || status == .restricted {
            usesCameraPhotos = false
        }
    }

    private func presentImporter() async {
        if !photoLibrary.hasReadAccess {
            let status = await photoLibrary.requestAccess()
            guard status == .authorized || status == .limited else { return }
        }
        isShowingImporter = true
    }
}

/// The phones recognized as the owner's, newest first, each with the months it was in use.
struct OwnCameraList: View {
    let periods: [OwnCameraRoster.Period]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Your phones")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(Array(periods.reversed().enumerated()), id: \.offset) { _, period in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(period.model)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 8)
                    Text(Self.months(period))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func months(_ period: OwnCameraRoster.Period) -> String {
        let style = Date.FormatStyle().month(.abbreviated).year()
        let from = period.from.formatted(style)
        let through = period.through.formatted(style)
        return from == through ? from : "\(from) – \(through)"
    }
}

/// Whether new photos are being picked up, and what they added lately.
struct PhotoFixStatusLine: View {
    let status: PhotoFixStatus
    let isChecking: Bool

    var body: some View {
        // "2 minutes ago" goes stale on a screen left open.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isChecking ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .foregroundStyle(isChecking ? Color.secondary : MovesPalette.place)
                Text(text(at: timeline.date))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }

    private func text(at now: Date) -> String {
        if isChecking {
            return String(localized: "Checking for new photos…")
        }
        guard let checked = status.lastCheckedAt else {
            return String(localized: "New photos are checked when you open Moves.")
        }
        let checkedAgo = Self.ago(checked, now: now)
        guard status.recentFixCount > 0, let latest = status.latestFixAt else {
            return String(localized: "No photos used this week. Last checked \(checkedAgo).")
        }
        let count = status.recentFixCount.formatted(.number)
        let latestAgo = Self.ago(latest, now: now)
        if status.recentFixCount == 1 {
            return String(localized: "1 photo used this week, \(latestAgo). Last checked \(checkedAgo).")
        }
        return String(localized: "\(count) photos used this week, the latest \(latestAgo). Last checked \(checkedAgo).")
    }

    private static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Where a history import stands: a bar for how much is done, a word for whether it is
/// working, the date it has reached, and how long is left.
struct PhotoHistoryProgressSummary: View {
    let job: PhotoHistoryJob
    let isWorking: Bool
    let timeRemaining: TimeInterval?
    /// The import is still working out which photos the owner's phone took.
    var isReadingLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.state != .finished {
                ProgressView(value: job.fractionComplete)
                    .tint(job.state == .running ? MovesPalette.place : .secondary)
            }
            HStack(spacing: 6) {
                if job.state == .running, isWorking || isReadingLibrary {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                }
                Text(headline)
                    .foregroundStyle(job.state == .failed ? .red : .primary)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))

            if let reached {
                Text(reached)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch job.state {
        case .running: "clock"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .running, .paused: .secondary
        case .failed: .red
        case .finished: MovesPalette.place
        }
    }

    private var headline: String {
        switch job.state {
        case .running:
            if isReadingLibrary {
                String(localized: "Finding the photos your phone took…")
            } else if isWorking {
                String(localized: "Importing now")
            } else {
                String(localized: "Starting…")
            }
        case .paused:
            String(localized: "Paused")
        case .failed:
            String(localized: "Import stopped")
        case .finished:
            if let finishedAt = job.finishedAt {
                String(localized: "Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                String(localized: "Finished")
            }
        }
    }

    /// The line that answers "how far back has it got?"
    private var reached: String? {
        if job.state == .finished {
            guard let earliest = job.earliestPhotoAt else { return nil }
            return String(localized: "Photos imported back to \(earliest.formatted(date: .long, time: .omitted)).")
        }
        guard job.cursor < job.rangeEnd else { return nil }
        return String(localized: "Imported back through \(job.cursor.formatted(date: .long, time: .omitted)).")
    }

    private var detail: String {
        if job.state == .finished {
            return job.report.geotaggedPhotoCount == 0
                ? String(localized: "No photos with a location in these dates.")
                : job.report.summary
        }
        if let message = job.message {
            return message
        }
        let checked = job.checkedPhotoCount.formatted(.number)
        let total = job.totalPhotoCount.formatted(.number)
        let counts = String(localized: "\(checked) of \(total) photos checked")
        switch job.state {
        case .running:
            guard let timeRemaining else {
                return String(localized: "\(counts). Working out how long is left…")
            }
            return "\(Self.remainingText(timeRemaining)) · \(counts)"
        case .paused:
            return String(localized: "\(counts). Resume to carry on from here.")
        case .failed, .finished:
            return counts
        }
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return String(localized: "Less than a minute left") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 90 * 60 ? [.hour] : [.minute]
        formatter.unitsStyle = .full
        // "About 20 minutes" should not become "19 minutes" a second later.
        let rounded = seconds >= 90 * 60 ? (seconds / 3_600).rounded() * 3_600 : (seconds / 60).rounded(.up) * 60
        let duration = formatter.string(from: rounded) ?? ""
        return String(localized: "About \(duration) left")
    }
}

/// Date range, preview counts, import progress, and a report.
///
/// The import belongs to the app, not this sheet: closing the sheet or leaving Moves
/// does not lose it, and it carries on from where it stopped.
struct PhotoHistoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var photoLibrary: PhotoLibraryController

    let firstRecordedDayStart: Date?

    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @State private var includesSavedPhotos = false
    @State private var preview: PhotoHistoryPreview?
    @State private var isLoadingPreview = false
    @State private var previewError: String?

    init(firstRecordedDayStart: Date?) {
        self.firstRecordedDayStart = firstRecordedDayStart
        let calendar = Calendar.current
        let lastImportDay: Date
        if let firstRecordedDayStart {
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: firstRecordedDayStart))
            lastImportDay = dayBefore ?? firstRecordedDayStart
        } else {
            lastImportDay = Date.now
        }
        let start = calendar.date(byAdding: .year, value: -20, to: lastImportDay) ?? lastImportDay
        _rangeStart = State(initialValue: calendar.startOfDay(for: start))
        _rangeEnd = State(initialValue: calendar.startOfDay(for: lastImportDay))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rebuild days from geotagged photos taken before you tracked. Inferred visits are marked as coming from photos. Recorded days are left as they are — photos are attached only.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    if let job = photoLibrary.historyJob {
                        progress(for: job)
                    } else {
                        setup
                    }

                    Text("Photos never leave this device.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Photos history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if photoLibrary.historyJob == nil {
                        Button("Import") {
                            photoLibrary.startHistoryImport(
                                in: selectedInterval,
                                includesSavedPhotos: includesSavedPhotos
                            )
                        }
                        .disabled(preview?.geotaggedPhotoCount == 0 || photoLibrary.isPreparingHistoryImport)
                    }
                }
            }
            .task(id: previewKey) {
                await refreshPreview()
            }
        }
    }

    @ViewBuilder
    private var setup: some View {
        DatePicker("From", selection: $rangeStart, displayedComponents: .date)
        DatePicker("To", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)

        Toggle("Include saved and imported photos", isOn: $includesSavedPhotos)

        Text("Photos your own phone took are always read. Saved and imported photos can carry someone else's location, and photos from other phones in your library are never read.")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if isLoadingPreview {
            ProgressView("Finding the photos your phone took…")
        } else if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.geotaggedPhotoCount == 0 ? String(localized: "No photos with a location in these dates") : preview.summary)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if preview.otherDevicePhotoCount > 0 {
                    Text("\(preview.otherDevicePhotoCount.formatted(.number)) from other phones in your library left out")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if preview.skippedPhotoCount > 0 {
                    Text("\(preview.skippedPhotoCount.formatted(.number)) saved or imported photos left out")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        } else if let previewError {
            Text(previewError)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
        }

        if let message = photoLibrary.lastErrorMessage {
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func progress(for job: PhotoHistoryJob) -> some View {
        PhotoHistoryProgressSummary(
            job: job,
            isWorking: photoLibrary.isHistoryImportWorking,
            timeRemaining: photoLibrary.historyTimeRemaining,
            isReadingLibrary: photoLibrary.isReadingLibrary
        )

        switch job.state {
        case .running:
            Text("You can close this and keep using Moves. If Moves is closed, the import carries on from here the next time you open it.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pause") { photoLibrary.pauseHistoryImport() }
                .buttonStyle(.bordered)
        case .paused, .failed:
            let buttons = Group {
                Button(job.state == .failed ? "Try Again" : "Resume") { photoLibrary.resumeHistoryImport() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Other Dates") { photoLibrary.clearHistoryImport() }
                    .buttonStyle(.bordered)
            }
            // Side by side where they fit, stacked on a narrow phone or at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        case .finished:
            Button("Import Another Range") { photoLibrary.clearHistoryImport() }
                .buttonStyle(.bordered)
        }
    }

    private func close() {
        dismiss()
    }

    private var selectedInterval: DateInterval {
        let start = Calendar.current.startOfDay(for: min(rangeStart, rangeEnd))
        let endDay = Calendar.current.startOfDay(for: max(rangeStart, rangeEnd))
        let end = Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: start, end: end)
    }

    private var previewKey: String {
        let isSettingUp = photoLibrary.historyJob == nil
        return "\(rangeStart.timeIntervalSince1970)|\(rangeEnd.timeIntervalSince1970)|\(includesSavedPhotos)|\(isSettingUp)"
    }

    private func refreshPreview() async {
        guard photoLibrary.historyJob == nil else { return }
        isLoadingPreview = true
        previewError = nil
        do {
            preview = try await photoLibrary.previewHistory(
                in: selectedInterval,
                includesSavedPhotos: includesSavedPhotos
            )
        } catch is CancellationError {
            return
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
        isLoadingPreview = false
    }
}
