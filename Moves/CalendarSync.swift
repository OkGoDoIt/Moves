import Combine
import EventKit
import SwiftData
import SwiftUI

/// The calendar copy contains a name and times, never coordinates, notes, or photos.
struct CalendarVisit: Equatable {
    let id: UUID
    let title: String
    let start: Date
    let end: Date

    init?(visit: VisitPlace, since: Date, now: Date) {
        guard let end = visit.departureDate, end > visit.arrivalDate,
              end <= now, visit.arrivalDate >= since, !visit.isHiddenAsShortStop
        else { return nil }
        id = visit.id
        title = [visit.userLabel, visit.knownPlace?.name, visit.autoLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? String(localized: "Visit")
        start = visit.arrivalDate
        self.end = end
    }

    var url: URL { URL(string: "moves://calendar-visit/\(id.uuidString)")! }

    static func ownedID(in url: URL?) -> UUID? {
        guard let url, url.scheme == "moves", url.host == "calendar-visit" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// Reconciliation only touches events carrying this integration's ownership URL.
enum CalendarEventAction: Equatable {
    case keep
    case remove
    case update(CalendarVisit)

    static func resolve(url: URL?, visits: [UUID: CalendarVisit], seen: inout Set<UUID>) -> Self {
        guard let id = CalendarVisit.ownedID(in: url) else { return .keep }
        guard let visit = visits[id], seen.insert(id).inserted else { return .remove }
        return .update(visit)
    }
}

/// Keeps an explicitly enabled, dedicated calendar in sync with completed visits.
/// It lives above the tab hierarchy, and never reads or changes another calendar's events.
@MainActor
final class MovesCalendarSync: ObservableObject {
    private enum Keys {
        static let enabled = "calendarSync.enabled"
        static let calendar = "calendarSync.calendarID"
        static let since = "calendarSync.since"
        static let lastSync = "calendarSync.lastSync"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var message: String?
    @Published private(set) var sources: [EKSource] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var since: Date
    @Published private(set) var calendarTitle: String?
    private let container: ModelContainer
    private let store = EKEventStore()
    private let defaults: UserDefaults
    private var observers: Set<AnyCancellable> = []
    private var scheduledSync: Task<Void, Never>?

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        since = defaults.object(forKey: Keys.since) as? Date ?? Calendar.current.startOfDay(for: .now)
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
        // Capture saves a location batch every few minutes. Only a change to a visit or a
        // place name can change the calendar, so the rest skip a read of every synced visit.
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter(PlaceSaveFilter.touchesPlaces)
            .merge(with: NotificationCenter.default.publisher(for: .EKEventStoreChanged))
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &observers)
    }

    func refreshAccess() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else { sources = []; return }
        sources = store.sources.filter { [.local, .calDAV, .exchange].contains($0.sourceType) }
        if let id = defaults.string(forKey: Keys.calendar), let calendar = store.calendar(withIdentifier: id) {
            calendarTitle = "\(calendar.title) · \(calendar.source.title)"
        }
    }

    var preferredSourceID: String {
        if let id = defaults.string(forKey: Keys.calendar), let calendar = store.calendar(withIdentifier: id) {
            return calendar.source.sourceIdentifier
        }
        return store.defaultCalendarForNewEvents?.source.sourceIdentifier ?? sources.first?.sourceIdentifier ?? ""
    }

    func requestAccess() async {
        do {
            hasAccess = try await store.requestFullAccessToEvents()
            refreshAccess()
            if !hasAccess { message = String(localized: "Calendar access is off. You can change it in Settings.") }
        } catch { message = error.localizedDescription }
    }

    func enable(sourceID: String, from date: Date) async {
        refreshAccess()
        guard hasAccess, let source = sources.first(where: { $0.sourceIdentifier == sourceID }) else { return }
        do {
            // Reuse only the calendar this installation created, never one matched by name.
            let calendar: EKCalendar
            if let id = defaults.string(forKey: Keys.calendar), let existing = store.calendar(withIdentifier: id),
               existing.source.sourceIdentifier == sourceID {
                guard existing.allowsContentModifications else {
                    message = String(localized: "The Moves calendar is read-only.")
                    return
                }
                calendar = existing
            } else {
                calendar = EKCalendar(for: .event, eventStore: store)
                calendar.title = "Moves"
                calendar.source = source
                try store.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: Keys.calendar)
            }
            since = date
            defaults.set(date, forKey: Keys.since)
            isEnabled = true
            defaults.set(true, forKey: Keys.enabled)
            calendarTitle = "\(calendar.title) · \(calendar.source.title)"
            await sync()
        } catch { message = error.localizedDescription }
    }

    func disable() {
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        scheduledSync?.cancel()
        message = String(localized: "Sync is off. Existing calendar events are kept.")
    }

    func schedule() {
        guard isEnabled, !ProcessInfo.processInfo.isRunningUnitTests else { return }
        scheduledSync?.cancel()
        scheduledSync = Task { await sync() }
    }

    func sync() async {
        guard isEnabled, !isSyncing else { return }
        await TimelineSchemaUpgrader.waitUntilFinished()
        guard isEnabled, !Task.isCancelled else { return }
        refreshAccess()
        guard hasAccess else {
            message = String(localized: "Calendar access is off. You can change it in Settings.")
            return
        }
        guard let id = defaults.string(forKey: Keys.calendar),
              let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications
        else {
            disable()
            message = String(localized: "The Moves calendar is unavailable. Choose an account to reconnect.")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let now = Date.now
            let start = since
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.arrivalDate >= start }))
            let visits = rows.compactMap { CalendarVisit(visit: $0, since: start, now: now) }
            let wanted = Dictionary(visits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var events: [EKEvent] = []
            var window = start
            // EventKit predicates cover at most four years; yearly windows cover lifelong history.
            while window < now {
                let end = min(Calendar.current.date(byAdding: .year, value: 1, to: window) ?? now, now)
                events += store.events(matching: store.predicateForEvents(withStart: window, end: end, calendars: [calendar]))
                window = end
            }
            var seen: Set<UUID> = []
            var seenEvents: Set<String> = []
            var changed = false
            for event in events {
                guard let eventID = event.eventIdentifier, seenEvents.insert(eventID).inserted else { continue }
                switch CalendarEventAction.resolve(url: event.url, visits: wanted, seen: &seen) {
                case .keep:
                    continue
                case .update(let visit):
                    if event.title != visit.title || event.startDate != visit.start || event.endDate != visit.end {
                        apply(visit, to: event)
                        try store.save(event, span: .thisEvent, commit: false)
                        changed = true
                    }
                case .remove:
                    // Only Moves-owned copies are removed; unrelated events stay untouched.
                    try store.remove(event, span: .thisEvent, commit: false)
                    changed = true
                }
            }
            for visit in wanted.values where !seen.contains(visit.id) {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                apply(visit, to: event)
                try store.save(event, span: .thisEvent, commit: false)
                changed = true
            }
            if changed { try store.commit() }
            lastSync = now
            defaults.set(now, forKey: Keys.lastSync)
            message = nil
        } catch {
            store.reset()
            message = error.localizedDescription
        }
    }

    private func apply(_ visit: CalendarVisit, to event: EKEvent) {
        event.title = visit.title
        event.startDate = visit.start
        event.endDate = visit.end
        event.url = visit.url
        event.availability = .free
    }
}

/// Calendar setup uses the same cards and controls as the other integrations.
struct CalendarSyncSettingsView: View {
    @EnvironmentObject private var sync: MovesCalendarSync
    @Query(sort: \VisitPlace.arrivalDate, order: .reverse) private var visits: [VisitPlace]
    @State private var sourceID = ""
    @State private var from = Calendar.current.startOfDay(for: Date.now)
    @State private var isConnecting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: String(localized: "Completed visits")) {
                    if sync.isEnabled {
                        Toggle("Sync completed visits", isOn: Binding(
                            get: { sync.isEnabled }, set: { if !$0 { sync.disable() } }
                        ))
                        Text(sync.calendarTitle ?? "Moves")
                            .foregroundStyle(.secondary)
                        Text("Visits since \(sync.since.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                        SettingsActionRow(title: sync.isSyncing ? String(localized: "Syncing…") : String(localized: "Sync now"), systemImage: "arrow.triangle.2.circlepath", isDisabled: sync.isSyncing) {
                            Task { await sync.sync() }
                        }
                    } else {
                        Text("Add places and times to a separate Moves calendar in your chosen account.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if sync.hasAccess {
                            Picker("Account", selection: $sourceID) {
                                Text("Choose an account").tag("")
                                ForEach(sync.sources, id: \.sourceIdentifier) { source in
                                    Text(source.title).tag(source.sourceIdentifier)
                                }
                            }
                            DatePicker("Visits starting", selection: $from, in: ...Date.now, displayedComponents: .date)
                            if let preview = visits.lazy.compactMap({ CalendarVisit(visit: $0, since: from, now: .now) }).first {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                                    Text(preview.title).font(.headline)
                                    Text("\(preview.start.formatted(date: .abbreviated, time: .shortened)) – \(preview.end.formatted(date: .omitted, time: .shortened))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                            SettingsActionRow(title: String(localized: "Start syncing"), systemImage: "calendar.badge.plus", isDisabled: sourceID.isEmpty || isConnecting) {
                                isConnecting = true
                                Task {
                                    await sync.enable(sourceID: sourceID, from: from)
                                    isConnecting = false
                                }
                            }
                        } else {
                            if EKEventStore.authorizationStatus(for: .event) == .denied {
                                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                            } else {
                                SettingsActionRow(title: String(localized: "Allow calendar access"), systemImage: "calendar") {
                                    Task { await sync.requestAccess() }
                                }
                            }
                        }
                    }
                    if let message = sync.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    } else if let date = sync.lastSync, sync.isEnabled {
                        Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.refreshAccess(); from = sync.since; sourceID = sync.hasAccess ? sync.preferredSourceID : "" }
        .onChange(of: sync.hasAccess) { _, allowed in
            if allowed { sourceID = sync.preferredSourceID }
        }
    }
}
