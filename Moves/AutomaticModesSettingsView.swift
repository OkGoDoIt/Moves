import SwiftData
import SwiftUI

struct AutomaticModesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AutomaticTransportModes.storageKey) private var disabledRaw = ""
    @ScaledMetric(relativeTo: .body) private var modeLabelSize = 16
    @State private var candidateCounts: [TransportMode: Int] = [:]
    @State private var canUndo = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?
    private let history = AutomaticModeHistory()

    private var preferences: AutomaticTransportModes { .init(rawValue: disabledRaw) }
    private var candidateCount: Int { candidateCounts.values.reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: String(localized: "Detect automatically")) {
                    VStack(spacing: 0) {
                        ForEach(AutomaticTransportModes.choices) { mode in
                            if mode != AutomaticTransportModes.choices.first { Divider() }
                            Toggle(isOn: enabledBinding(for: mode)) {
                                HStack(spacing: 12) {
                                    Circle().fill(MovesPalette.transport(mode)).frame(width: 11, height: 11)
                                        .accessibilityHidden(true)
                                    Text(mode.title)
                                        .font(.system(size: modeLabelSize, design: .rounded))
                                }
                            }
                            .frame(minHeight: 49)
                            .accessibilityIdentifier("automatic-mode-\(mode.rawValue)")
                        }
                    }
                    Text("You can still choose any mode when editing a trip.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: String(localized: "Past trips")) {
                    Text(historyHeading)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text(preferences.disabled.isEmpty
                         ? "Turn off a mode to recheck its past guesses."
                         : "Recheck using your enabled modes. Trips without enough evidence become Unknown.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Your corrections, reviewed trips, and imported modes stay as they are.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)

                    Button {
                        runHistoryAction {
                            let report = try history.recheck(in: modelContext, preferences: preferences)
                            message = String(localized: "\(report.changed) trips updated. \(report.unknown) marked Unknown.")
                        }
                    } label: {
                        HStack {
                            if isWorking { ProgressView() }
                            Text(isWorking ? "Updating trips…" : "Recheck past trips")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(candidateCount == 0 || isWorking)
                    .accessibilityIdentifier("recheck-automatic-modes")

                    if let message {
                        Text(message)
                            .font(.system(.subheadline, design: .rounded))
                            .accessibilityIdentifier("automatic-mode-history-result")
                    }
                    if canUndo {
                        Button("Undo history changes") {
                            runHistoryAction {
                                let count = try history.undo(in: modelContext)
                                message = String(localized: "\(count) trips restored.")
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(isWorking)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(MovesPalette.backgroundTop.ignoresSafeArea())
        .navigationTitle("Automatic modes")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .onChange(of: disabledRaw) { _, _ in
            message = nil
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)) { _ in
                if !isWorking { refresh() }
            }
    }

    private var historyHeading: String {
        if candidateCounts.count == 1, let mode = candidateCounts.keys.first {
            return String(localized: "\(candidateCount) \(mode.title.lowercased()) guesses")
        }
        return String(localized: "\(candidateCount) guesses to recheck")
    }

    private func enabledBinding(for mode: TransportMode) -> Binding<Bool> {
        Binding(get: { preferences.allows(mode) }, set: { enabled in
            var updated = preferences
            if enabled { updated.disabled.remove(mode) }
            else { updated.disabled.insert(mode) }
            disabledRaw = updated.rawValue
        })
    }

    private func refresh() {
        canUndo = history.canUndo
        do {
            candidateCounts = Dictionary(grouping: try history.candidates(in: modelContext, preferences: preferences), by: \.transportMode)
                .mapValues(\.count)
            errorMessage = nil
        } catch {
            candidateCounts = [:]
            errorMessage = "Couldn’t read past trips. Try again."
        }
    }

    private func runHistoryAction(_ action: @escaping @MainActor () throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            await Task.yield()
            do {
                try action()
                refresh()
            } catch {
                errorMessage = "Couldn’t update past trips. Try again."
            }
            isWorking = false
        }
    }
}
