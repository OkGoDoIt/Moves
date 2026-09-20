import Photos
import SwiftData
import SwiftUI

/// Settings → Photos. Additive card: access, Limited Library, and history backfill.
struct PhotosSettingsCard: View {
    @EnvironmentObject private var photoLibrary: PhotoLibraryController
    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showOnVisits = true

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
                HStack(spacing: 12) {
                    Label("Rebuild history from photos…", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
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

    private func presentImporter() async {
        if !photoLibrary.hasReadAccess {
            let status = await photoLibrary.requestAccess()
            guard status == .authorized || status == .limited else { return }
        }
        isShowingImporter = true
    }
}

/// Date range, preview counts, import progress, and a report. Re-running is idempotent.
struct PhotoHistoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var photoLibrary: PhotoLibraryController

    let firstRecordedDayStart: Date?

    @State private var rangeStart: Date
    @State private var rangeEnd: Date
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

                    DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)

                    if isLoadingPreview {
                        ProgressView("Counting photos…")
                    } else if let preview {
                        Text(preview.summary)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else if let previewError {
                        Text(previewError)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                    }

                    if photoLibrary.isImporting {
                        ProgressView(value: photoLibrary.importProgress)
                        Text(photoLibrary.importProgressText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else if let report = photoLibrary.lastReport {
                        Text(report.summary)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.green)
                    } else if let message = photoLibrary.lastErrorMessage {
                        Text(message)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
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
                    Button("Close") { dismiss() }
                        .disabled(photoLibrary.isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if photoLibrary.isImporting {
                        Button("Cancel", role: .cancel) {
                            photoLibrary.cancelImport()
                        }
                    } else {
                        Button("Import") {
                            photoLibrary.importHistory(in: selectedInterval)
                        }
                        .disabled(preview?.geotaggedPhotoCount == 0)
                    }
                }
            }
            .task(id: rangeKey) {
                await refreshPreview()
            }
        }
    }

    private var selectedInterval: DateInterval {
        let start = Calendar.current.startOfDay(for: min(rangeStart, rangeEnd))
        let endDay = Calendar.current.startOfDay(for: max(rangeStart, rangeEnd))
        let end = Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: start, end: end)
    }

    private var rangeKey: String {
        "\(rangeStart.timeIntervalSince1970)|\(rangeEnd.timeIntervalSince1970)"
    }

    private func refreshPreview() async {
        isLoadingPreview = true
        previewError = nil
        do {
            preview = try await photoLibrary.previewHistory(in: selectedInterval)
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
        isLoadingPreview = false
    }
}
