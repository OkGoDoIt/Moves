import CloudDataPresence
import CloudKit
import Combine
import CoreData
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

/// What the private iCloud mirror has reported, as plain values so tests can drive it
/// without a real container.
struct MovesICloudSyncState: Equatable {
    /// What is standing in the way of syncing, in the person's terms.
    enum Problem: Hashable {
        case signedOut
        case storageFull
        case offline
        case other

        /// Reads a mirroring failure, which may wrap the CloudKit error that caused it.
        init(error: Error?) {
            guard let error else { self = .other; return }
            // Core Data can wrap several errors, each with CloudKit partial
            // failures of its own. Inspect the tree without depending on dictionary
            // order, and prefer an actionable account/quota issue over connectivity.
            var queue = [error as NSError]
            var seen = Set<ObjectIdentifier>()
            var problems: Set<Problem> = []
            var index = 0
            while index < queue.count, index < 64 {
                let current = queue[index]
                index += 1
                guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
                if current.domain == CKError.errorDomain {
                    switch CKError.Code(rawValue: current.code) {
                    case .notAuthenticated: problems.insert(.signedOut)
                    case .quotaExceeded: problems.insert(.storageFull)
                    case .networkUnavailable, .networkFailure: problems.insert(.offline)
                    default: break
                    }
                } else if current.domain == NSCocoaErrorDomain, current.code == 134400 {
                    problems.insert(.signedOut)
                } else if current.domain == NSURLErrorDomain,
                          [URLError.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                           .timedOut, .dnsLookupFailed].contains(URLError.Code(rawValue: current.code)) {
                    problems.insert(.offline)
                }
                var children: [NSError] = []
                if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                    children.append(underlying)
                }
                if let multiple = current.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                    children.append(contentsOf: multiple)
                }
                if let partial = current.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
                    children.append(contentsOf: partial.allValues.compactMap { $0 as? NSError })
                }
                queue.append(contentsOf: children.prefix(max(64 - queue.count, 0)))
            }
            self = problems.contains(.signedOut) ? .signedOut
                : problems.contains(.storageFull) ? .storageFull
                : problems.contains(.offline) ? .offline : .other
        }
    }

    enum EventKind {
        case setup
        case transfer
    }

    var lastSyncedAt: Date?
    var problem: Problem?
    private var activeEventIDs: Set<UUID> = []

    init(lastSyncedAt: Date? = nil, problem: Problem? = nil) {
        self.lastSyncedAt = lastSyncedAt
        self.problem = problem
    }

    var isSyncing: Bool { !activeEventIDs.isEmpty }

    /// The mirror reports each event twice: once when it starts and once with an end date.
    mutating func apply(eventID: UUID, kind: EventKind, endDate: Date?, succeeded: Bool, error: Error?) {
        guard let endDate else {
            activeEventIDs.insert(eventID)
            return
        }
        activeEventIDs.remove(eventID)
        if !succeeded {
            problem = Problem(error: error)
        } else if kind == .transfer {
            lastSyncedAt = endDate
            problem = nil
        }
    }

    mutating func apply(accountStatus: CKAccountStatus) {
        switch accountStatus {
        case .noAccount, .restricted:
            problem = .signedOut
        case .available:
            if problem == .signedOut { problem = nil }
        case .couldNotDetermine, .temporarilyUnavailable:
            break
        @unknown default:
            break
        }
    }
}

/// User-facing iCloud state. Avoids CloudKit jargon.
enum MovesICloudStatus: Equatable {
    case simulatorLocalOnly
    case localOnly
    case privateICloud(MovesICloudSyncState)

    static func resolve(
        allowsPrivateMirror: Bool,
        isSimulator: Bool,
        sync: MovesICloudSyncState
    ) -> MovesICloudStatus {
        if isSimulator { return .simulatorLocalOnly }
        if allowsPrivateMirror { return .privateICloud(sync) }
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

    var systemImage: String {
        switch self {
        case .simulatorLocalOnly, .localOnly:
            return "iphone"
        case .privateICloud(let sync):
            switch sync.problem {
            case .signedOut:
                return "icloud.slash"
            case .storageFull:
                return "exclamationmark.icloud"
            case .offline, .other, nil:
                if sync.isSyncing { return "arrow.clockwise.icloud" }
                if sync.problem != nil { return "exclamationmark.icloud" }
                return sync.lastSyncedAt == nil ? "icloud" : "checkmark.icloud"
            }
        }
    }

    var needsAttention: Bool {
        guard case .privateICloud(let sync) = self else { return false }
        return sync.problem != nil && !sync.isSyncing
    }

    func detail(now: Date = .now) -> String {
        switch self {
        case .simulatorLocalOnly:
            return String(localized: "This simulator keeps your timeline on this device. Daily Backup can still copy yesterday to iCloud Drive.")
        case .localOnly:
            return String(localized: "This install keeps your timeline on this iPhone. It isn’t mirroring to iCloud. Daily Backup can still copy yesterday to iCloud Drive.")
        case .privateICloud(let sync):
            switch sync.problem {
            case .signedOut:
                return String(localized: "Not signed in to iCloud. Your timeline stays on this iPhone until you sign in.")
            case .storageFull:
                return String(localized: "Your iCloud storage is full, so new changes stay on this iPhone.")
            case .offline, .other, nil:
                break
            }
            if sync.isSyncing {
                return String(localized: "Syncing now.")
            }
            let lastSynced = sync.lastSyncedAt.map { Self.lastSyncedPhrase(for: $0, now: now) }
            switch sync.problem {
            case .offline:
                return [String(localized: "Waiting for a connection."), lastSynced]
                    .compactMap { $0 }
                    .joined(separator: " ")
            case .other:
                return [String(localized: "Moves will try again."), lastSynced]
                    .compactMap { $0 }
                    .joined(separator: " ")
            default:
                return lastSynced ?? String(localized: "Waiting for the first sync.")
            }
        }
    }

    private static func lastSyncedPhrase(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "Synced just now.")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let when = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Last synced \(when).")
    }
}

@MainActor
final class MovesCloudDataPresencePublisher: ObservableObject {
    private enum PresenceKeys {
        static let moves = "cloudPresence.moves.v1"
        static let places = "cloudPresence.places.v1"
    }

    private static let lastSyncedAtKey = "moves.iCloud.lastSyncedAt"

    private let modelContainer: ModelContainer
    private var pendingPublishTask: Task<Void, Never>?
    private var syncState: MovesICloudSyncState
    private var observers: Set<AnyCancellable> = []

    @Published private(set) var status: MovesICloudStatus

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let sync = MovesICloudSyncState(
            lastSyncedAt: UserDefaults.standard.object(forKey: Self.lastSyncedAtKey) as? Date
        )
        self.syncState = sync
        self.status = MovesICloudStatus.resolve(
            allowsPrivateMirror: MovesCloudKitAvailability.allowsPrivateMirror,
            isSimulator: MovesCloudKitAvailability.isSimulator,
            sync: sync
        )
        guard MovesCloudKitAvailability.allowsPrivateMirror else { return }
        observeMirror()
        refreshSyncStatus()
    }

    /// The mirror behind SwiftData reports through `NSPersistentCloudKitContainer`.
    private func observeMirror() {
        NotificationCenter.default
            .publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { $0.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.apply(event)
            }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSyncStatus()
            }
            .store(in: &observers)
    }

    private func apply(_ event: NSPersistentCloudKitContainer.Event) {
        let previousLastSync = syncState.lastSyncedAt
        syncState.apply(
            eventID: event.identifier,
            kind: event.type == .setup ? .setup : .transfer,
            endDate: event.endDate,
            succeeded: event.succeeded,
            error: event.error
        )
        if syncState.lastSyncedAt != previousLastSync {
            UserDefaults.standard.set(syncState.lastSyncedAt, forKey: Self.lastSyncedAtKey)
        }
        publishStatus()
    }

    /// Picks up a sign-in or sign-out made in Settings while Moves was in the background.
    func refreshSyncStatus() {
        publishStatus()
        guard MovesCloudKitAvailability.allowsPrivateMirror else { return }
        Task { [weak self] in
            let container = CKContainer(identifier: MovesAppIdentity.cloudKitContainerIdentifier)
            guard let accountStatus = try? await container.accountStatus() else { return }
            self?.syncState.apply(accountStatus: accountStatus)
            self?.publishStatus()
        }
    }

    private func publishStatus() {
        status = MovesICloudStatus.resolve(
            allowsPrivateMirror: MovesCloudKitAvailability.allowsPrivateMirror,
            isSimulator: MovesCloudKitAvailability.isSimulator,
            sync: syncState
        )
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
        } catch {
            print("Failed to publish CloudDataPresence counts: \(error.localizedDescription)")
        }
    }
}

/// Settings card for iCloud mirroring plus a jump to Daily Backup.
struct ICloudSettingsCard: View {
    @ObservedObject var publisher: MovesCloudDataPresencePublisher
    let onOpenDailyBackup: () -> Void

    var body: some View {
        SettingsCard(title: String(localized: "iCloud")) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: publisher.status.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(publisher.status.needsAttention ? Color.orange : MovesPalette.routeTracking)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(publisher.status.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(publisher.status.detail())
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
            publisher.refreshSyncStatus()
        }
    }
}
