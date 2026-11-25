import Photos
import SwiftData
import SwiftUI

/// Settings → Photos. Additive card: access, Limited Library, and history backfill.
struct PhotosSettingsCard: View {
    @EnvironmentObject private var photoLibrary: PhotoLibraryController
    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showOnVisits = true
    @AppStorage(PhotoLibrarySettings.usesCameraPhotosAsFixesKey) private var usesCameraPhotos = true

    let firstRecordedDayStart: Date?

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

            PhotoHistorySection()
        }
    }

    private var accessExplanation: String {
        switch photoLibrary.authorizationStatus {
        case .limited:
            return String(localized: "Moves uses only the photos you choose.")
        case .authorized:
            return String(localized: "Moves can see all your photos.")
        case .denied, .restricted:
            return String(localized: "Photos access is off. Turn it on in Settings to use your photos.")
        default:
            return String(localized: "Moves asks for access when you turn on an option above.")
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
}

/// Starts the history import with one tap, then says where it stands.
///
/// The import belongs to the app, not to this view: nothing here has to stay open for it.
struct PhotoHistorySection: View {
    @EnvironmentObject private var photoLibrary: PhotoLibraryController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = photoLibrary.historyJob {
                Label("Past days from photos", systemImage: "clock.arrow.circlepath")
                PhotoHistoryProgressSummary(
                    job: job,
                    isWorking: photoLibrary.isHistoryImportWorking,
                    timeRemaining: photoLibrary.historyTimeRemaining,
                    isReadingLibrary: photoLibrary.isReadingLibrary,
                    libraryReadShare: photoLibrary.libraryReadShare,
                    hasAccess: photoLibrary.hasReadAccess
                )
                switch job.state {
                case .running:
                    Text("Keeps going on its own when you leave Moves.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Pause") { photoLibrary.pauseHistoryImport() }
                        .buttonStyle(.bordered)
                case .paused:
                    Button("Resume") { withAccess { photoLibrary.resumeHistoryImport() } }
                        .buttonStyle(.borderedProminent)
                case .finished:
                    Button("Check Again") { withAccess { photoLibrary.startHistoryImport() } }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Add the places where your phone took photos to days you didn't record.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAccess { photoLibrary.startHistoryImport() }
                } label: {
                    Label("Fill In Past Days", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    private func withAccess(_ action: @escaping @MainActor () -> Void) {
        Task {
            if !photoLibrary.hasReadAccess {
                _ = await photoLibrary.requestAccess()
            }
            guard photoLibrary.hasReadAccess else { return }
            action()
        }
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
    var libraryReadShare = 0.0
    var hasAccess = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.state == .running, job.cursor >= job.rangeEnd {
                ProgressView(value: min(max(libraryReadShare, 0), 1))
                    .tint(MovesPalette.place)
            } else if job.state != .finished {
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
            if let leftOut {
                Text(leftOut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch job.state {
        case .running: hasAccess ? "clock" : "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .running: hasAccess ? .secondary : .red
        case .paused: .secondary
        case .finished: MovesPalette.place
        }
    }

    private var headline: String {
        switch job.state {
        case .running:
            if !hasAccess {
                String(localized: "Waiting for Photos access")
            } else if isReadingLibrary {
                String(localized: "Finding the photos your phone took…")
            } else if isWorking {
                String(localized: "Importing now")
            } else {
                String(localized: "Starting…")
            }
        case .paused:
            String(localized: "Paused")
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
                ? String(localized: "No photos with a location were found.")
                : job.report.summary
        }
        if job.cursor >= job.rangeEnd, job.state == .running {
            guard job.isCounted else {
                return String(localized: "Looking through your library…")
            }
            let total = job.totalPhotoCount.formatted(.number)
            let share = libraryReadShare.formatted(.percent.precision(.fractionLength(0)))
            return String(localized: "\(share) of \(total) photos looked at. Importing starts after that.")
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
                return counts
            }
            return "\(Self.remainingText(timeRemaining)) · \(counts)"
        case .paused, .finished:
            return counts
        }
    }

    /// What was looked at and not used, and why.
    private var leftOut: String? {
        var parts: [String] = []
        if job.otherDevicePhotoCount > 0 {
            parts.append(String(localized: "\(job.otherDevicePhotoCount.formatted(.number)) from other phones"))
        }
        if job.receivedPhotoCount > 0 {
            parts.append(String(localized: "\(job.receivedPhotoCount.formatted(.number)) saved or sent to you"))
        }
        if job.conflictingPhotoCount > 0 {
            parts.append(String(localized: "\(job.conflictingPhotoCount.formatted(.number)) with a doubtful location"))
        }
        if job.unreadablePhotoCount > 0 {
            parts.append(String(localized: "\(job.unreadablePhotoCount.formatted(.number)) that couldn't be read"))
        }
        guard !parts.isEmpty else { return nil }
        return String(localized: "Left out: \(ListFormatter.localizedString(byJoining: parts)).")
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

/// The history import, started from setup.
struct PhotoHistoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var photoLibrary: PhotoLibraryController

    let firstRecordedDayStart: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                PhotoHistorySection()
                    .padding(20)
            }
            .navigationTitle("Photo history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Choosing Photos is what opened this, so there is nothing left to ask.
                if photoLibrary.historyJob == nil {
                    photoLibrary.startHistoryImport()
                }
            }
        }
    }
}
