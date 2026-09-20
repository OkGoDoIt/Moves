import CloudDataPresence
import Foundation
import SwiftData
import SwiftUI

/// Whether this install may mirror the timeline into the user’s private iCloud.
enum MovesCloudKitAvailability {
    /// Simulator builds always use an in-memory store, so they never mirror.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Fail-open when no profile is embedded (App Store). Wildcard profiles without
    /// the container stay local-only.
    static var allowsPrivateMirror: Bool {
        if isSimulator { return false }
        return MovesApp.allowsCloudKitContainer()
    }
}

/// User-facing iCloud state. Avoids CloudKit jargon.
enum MovesICloudStatus: Equatable {
    case simulatorLocalOnly
    case localOnly
    case privateICloud(lastUpdated: Date?)

    static func resolve(
        allowsPrivateMirror: Bool,
        isSimulator: Bool,
        lastUpdated: Date?
    ) -> MovesICloudStatus {
        if isSimulator { return .simulatorLocalOnly }
        if allowsPrivateMirror { return .privateICloud(lastUpdated: lastUpdated) }
        return .localOnly
    }

    var title: String {
        switch self {
        case .simulatorLocalOnly, .localOnly:
            return String(localized: "On this iPhone")
        case .privateICloud:
            return String(localized: "Private iCloud")
        }
    }

    var detail: String {
        switch self {
        case .simulatorLocalOnly:
            return String(localized: "This simulator keeps your timeline on this device. Daily Backup can still copy yesterday to iCloud Drive.")
        case .localOnly:
            return String(localized: "This install keeps your timeline on this iPhone. It isn’t mirroring to iCloud. Daily Backup can still copy yesterday to iCloud Drive.")
        case .privateICloud(let lastUpdated):
            if let lastUpdated {
                let when = lastUpdated.formatted(.relative(presentation: .named))
                return String(localized: "Your timeline stays in your private iCloud. Last updated \(when).")
            }
            return String(localized: "Your timeline stays in your private iCloud when you’re signed in. A nightly copy can also go to iCloud Drive.")
        }
    }
}

@MainActor
final class MovesCloudDataPresencePublisher: ObservableObject {
    private enum PresenceKeys {
        static let moves = "cloudPresence.moves.v1"
        static let places = "cloudPresence.places.v1"
        static var all: [String] { [moves, places] }
    }

    private let modelContainer: ModelContainer
    private var pendingPublishTask: Task<Void, Never>?

    @Published private(set) var presence: CloudDataPresenceSummary?
    @Published private(set) var status: MovesICloudStatus

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.status = MovesICloudStatus.resolve(
            allowsPrivateMirror: MovesCloudKitAvailability.allowsPrivateMirror,
            isSimulator: MovesCloudKitAvailability.isSimulator,
            lastUpdated: nil
        )
        refreshFromStore()
    }

    func publishNow() async {
        pendingPublishTask?.cancel()
        await publishCurrentCounts()
    }

    func publishSoon() {
        pendingPublishTask?.cancel()
        pendingPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await self?.publishCurrentCounts()
        }
    }

    func refreshFromStore() {
        let summary = CloudDataPresenceStore.loadSummary(forKeys: PresenceKeys.all)
        presence = summary
        status = MovesICloudStatus.resolve(
            allowsPrivateMirror: MovesCloudKitAvailability.allowsPrivateMirror,
            isSimulator: MovesCloudKitAvailability.isSimulator,
            lastUpdated: summary?.updatedAt
        )
    }

    private func publishCurrentCounts() async {
        let context = ModelContext(modelContainer)

        do {
            let placeCount = try context.fetchCount(FetchDescriptor<VisitPlace>())
            let moveCount = try context.fetchCount(FetchDescriptor<MoveSegment>())

            CloudDataPresenceStore.publish(
                recordCountsByKey: [
                    PresenceKeys.places: placeCount,
                    PresenceKeys.moves: moveCount,
                ]
            )
            refreshFromStore()
        } catch {
            print("Failed to publish CloudDataPresence counts: \(error.localizedDescription)")
            refreshFromStore()
        }
    }
}

/// Settings card for iCloud mirroring plus a jump to Daily Backup.
struct ICloudSettingsCard: View {
    @ObservedObject var publisher: MovesCloudDataPresencePublisher
    let onOpenDailyBackup: () -> Void

    var body: some View {
        SettingsCard(title: String(localized: "iCloud")) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(publisher.status.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(publisher.status.detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            Button(action: onOpenDailyBackup) {
                HStack {
                    Label(String(localized: "Daily Backup"), systemImage: "externaldrive.badge.icloud")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .accessibilityHint(String(localized: "Scrolls to nightly iCloud Drive backup"))
        }
        .onAppear {
            publisher.refreshFromStore()
        }
    }
}
