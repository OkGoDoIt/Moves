import SwiftData
import SwiftUI

/// Unified search: places, days, moments, and notes. Results open existing deep links.
struct MovesSearchView: View {
    @EnvironmentObject private var rootController: MovesRootController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var query = ""
    @State private var sections: [MovesSearchSection] = []
    /// The query `sections` answers. Differs from `query` while a search is pending.
    @State private var searchedQuery = ""
    /// Plain values read off the store once, then searched on every keystroke.
    @State private var corpus: MovesSearchCorpus?

    /// The days argument is no longer read: search loads its own values off the main actor.
    init(dayTimelines: [DayTimeline] = []) {}

    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Search your timeline"), systemImage: "magnifyingglass")
                } description: {
                    Text(String(localized: "Places, last Tuesday, Tue 3pm, or a note you wrote."))
                }
            } else if sections.isEmpty {
                if searchedQuery == query {
                    ContentUnavailableView.search(text: query)
                } else {
                    Color.clear
                }
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.hits) { hit in
                                Button {
                                    open(hit)
                                } label: {
                                    MovesSearchHitRow(hit: hit)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(String(localized: "Search"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "Places, days, times, notes")
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .task(id: query) {
            await runSearch(for: query)
        }
    }

    /// Waits for a pause in typing; the next keystroke cancels this task. The first search
    /// reads the store on a private context, so no main-context row is walked here.
    private func runSearch(for text: String) async {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
        }
        if corpus == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            corpus = try? await MovesSearchCorpus.load(from: modelContext.container)
            guard !Task.isCancelled else { return }
        }
        sections = MovesSearchIndex.results(
            parsed: SearchQueryParser.parse(text, now: .now, calendar: calendar),
            corpus: corpus ?? MovesSearchCorpus(),
            now: .now,
            calendar: calendar
        )
        searchedQuery = text
    }

    private func open(_ hit: MovesSearchHit) {
        dismiss()
        switch hit.action {
        case .knownPlace(let id):
            rootController.selectedTab = .places
            rootController.requestedKnownPlaceID = id
        case .visit(let id):
            rootController.selectedTab = .timeline
            rootController.requestedPlaceID = id
        case .day(let date):
            rootController.selectedTab = .timeline
            rootController.requestedJumpDate = date
            rootController.requestedJumpMoment = nil
        case .moment(let date):
            rootController.selectedTab = .timeline
            rootController.requestedJumpDate = date
            rootController.requestedJumpMoment = date
        }
    }
}

private struct MovesSearchHitRow: View {
    let hit: MovesSearchHit

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hit.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(hit.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

enum MovesSearchKind: String, Sendable {
    case place
    case day
    case moment
    case note
}

enum MovesSearchAction: Equatable, Sendable {
    case knownPlace(UUID)
    case visit(UUID)
    case day(Date)
    case moment(Date)
}

struct MovesSearchHit: Identifiable, Equatable {
    let id: String
    let kind: MovesSearchKind
    let title: String
    let subtitle: String
    let symbolName: String
    let action: MovesSearchAction

    var tint: Color {
        switch kind {
        case .place: return MovesPalette.place
        case .day: return MovesPalette.move
        case .moment: return MovesPalette.routeTracking
        case .note: return Color.orange
        }
    }
}

struct MovesSearchSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let hits: [MovesSearchHit]
}

/// Everything search reads, copied off the store on a private context.
struct MovesSearchCorpus: Sendable {
    struct Place: Sendable {
        let id: UUID
        let name: String
        let locality: String?
        let category: String?
        let countryCode: String?
    }

    struct Visit: Sendable {
        let id: UUID
        let title: String
        let locality: String?
        let comment: String?
        let knownPlaceID: UUID?
        let arrivalDate: Date
        let departureDate: Date?
    }

    struct Move: Sendable {
        let id: UUID
        let comment: String?
        let modeRaw: String
        let startDate: Date
        let duration: TimeInterval
    }

    struct Day: Sendable {
        let dayKey: String
        let dayStart: Date
        let uniqueLocationCount: Int
        var visits: [Visit] = []
        var moves: [Move] = []
    }

    var knownPlaces: [Place] = []
    /// Oldest first, as the timeline lists them.
    var days: [Day] = []

    /// Reads on a fresh context off the main actor, prefetching every relationship it
    /// follows. The reconciler deletes trips on its own context, and a main-context row
    /// read before the merge aborts the process.
    static func load(from container: ModelContainer) async throws -> MovesSearchCorpus {
        try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var corpus = MovesSearchCorpus()
            corpus.knownPlaces = try context.fetch(FetchDescriptor<KnownPlace>(sortBy: [SortDescriptor(\.name)]))
                .map { Place(id: $0.id, name: $0.name, locality: $0.locality, category: $0.category, countryCode: $0.countryCode) }

            var visitFetch = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)])
            visitFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.knownPlace]
            var visits: [PersistentIdentifier: [Visit]] = [:]
            var buckets: [PersistentIdentifier: Set<String>] = [:]
            for visit in try context.fetch(visitFetch) {
                guard let day = visit.dayTimeline?.persistentModelID else { continue }
                visits[day, default: []].append(Visit(
                    id: visit.id,
                    title: visit.displayTitle,
                    locality: visit.locality,
                    comment: visit.comment,
                    knownPlaceID: visit.knownPlace?.id,
                    arrivalDate: visit.arrivalDate,
                    departureDate: visit.departureDate
                ))
                // Matches `DayTimeline.uniqueLocationCount`: ~10 m buckets.
                buckets[day, default: []].insert(
                    "\(Int((visit.latitude * 10_000).rounded()))|\(Int((visit.longitude * 10_000).rounded()))"
                )
            }

            var moveFetch = FetchDescriptor<MoveSegment>(sortBy: [SortDescriptor(\.startDate)])
            moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace]
            var moves: [PersistentIdentifier: [Move]] = [:]
            for move in try context.fetch(moveFetch) {
                guard let day = move.dayTimeline?.persistentModelID else { continue }
                moves[day, default: []].append(Move(
                    id: move.id,
                    comment: move.comment,
                    modeRaw: move.transportModeRawValue,
                    startDate: move.timelineStartDate,
                    duration: move.timelineDuration
                ))
            }

            corpus.days = try context.fetch(FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart)])).map { day in
                let id = day.persistentModelID
                return Day(
                    dayKey: day.dayKey,
                    dayStart: day.dayStart,
                    uniqueLocationCount: buckets[id]?.count ?? 0,
                    visits: visits[id] ?? [],
                    moves: moves[id] ?? []
                )
            }
            return corpus
        }.value
    }
}

/// Builds grouped search hits from the parsed query and values read off the store.
enum MovesSearchIndex {
    static let resultLimit = 8

    static func results(
        parsed: SearchQueryParser.ParsedQuery,
        corpus: MovesSearchCorpus,
        now: Date,
        calendar: Calendar
    ) -> [MovesSearchSection] {
        guard !parsed.isEmpty else { return [] }

        var sections: [MovesSearchSection] = []
        let places = placeHits(parsed: parsed, corpus: corpus)
        if !places.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Places"), hits: places))
        }
        let dayHits = dayHits(parsed: parsed, days: corpus.days, calendar: calendar)
        if !dayHits.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Days"), hits: dayHits))
        }
        let moments = momentHits(parsed: parsed)
        if !moments.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Moments"), hits: moments))
        }
        let notes = noteHits(parsed: parsed, days: corpus.days)
        if !notes.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Notes"), hits: notes))
        }
        return sections
    }

    private static func placeHits(
        parsed: SearchQueryParser.ParsedQuery,
        corpus: MovesSearchCorpus
    ) -> [MovesSearchHit] {
        let needle = parsed.freeText
        guard needle.count >= 2 || (needle.count == 1 && parsed.day == nil) else { return [] }
        guard !needle.isEmpty else { return [] }

        var hits: [MovesSearchHit] = []
        var seen = Set<UUID>()

        for place in corpus.knownPlaces {
            guard placeMatches(place, needle: needle) else { continue }
            seen.insert(place.id)
            let city = [place.locality, PlacesGeography.countryName(forCountryCode: place.countryCode)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            hits.append(
                MovesSearchHit(
                    id: "known-\(place.id.uuidString)",
                    kind: .place,
                    title: place.name,
                    subtitle: city,
                    symbolName: KnownPlaceCategory(stored: place.category)?.symbolName ?? "mappin.and.ellipse",
                    action: .knownPlace(place.id)
                )
            )
            if hits.count >= resultLimit { return hits }
        }

        for day in corpus.days {
            for visit in day.visits {
                if let knownID = visit.knownPlaceID, seen.contains(knownID) { continue }
                guard visit.title.localizedCaseInsensitiveContains(needle)
                    || (visit.locality?.localizedCaseInsensitiveContains(needle) == true) else {
                    continue
                }
                hits.append(
                    MovesSearchHit(
                        id: "visit-\(visit.id.uuidString)",
                        kind: .place,
                        title: visit.title,
                        subtitle: MovesStatisticsFormatting.visitInterval(arrival: visit.arrivalDate, departure: visit.departureDate),
                        symbolName: "mappin",
                        action: .visit(visit.id)
                    )
                )
                if hits.count >= resultLimit { return hits }
            }
        }
        return hits
    }

    private static func dayHits(
        parsed: SearchQueryParser.ParsedQuery,
        days: [MovesSearchCorpus.Day],
        calendar: Calendar
    ) -> [MovesSearchHit] {
        var hits: [MovesSearchHit] = []
        if let day = parsed.day {
            hits.append(dayHit(for: day, timelines: days, calendar: calendar))
        }

        let needle = parsed.freeText
        if needle.count >= 3 {
            for timeline in days.reversed() {
                let label = timeline.dayStart.formatted(date: .complete, time: .omitted)
                let numeric = timeline.dayStart.formatted(date: .numeric, time: .omitted)
                if label.localizedCaseInsensitiveContains(needle)
                    || numeric.localizedCaseInsensitiveContains(needle)
                    || timeline.dayKey.localizedCaseInsensitiveContains(needle) {
                    if hits.contains(where: { $0.id == "day-\(timeline.dayKey)" }) { continue }
                    hits.append(dayHit(for: timeline.dayStart, timelines: days, calendar: calendar))
                }
                if hits.count >= resultLimit { break }
            }
        }
        return Array(hits.prefix(resultLimit))
    }

    private static func momentHits(
        parsed: SearchQueryParser.ParsedQuery
    ) -> [MovesSearchHit] {
        guard let moment = parsed.moment else { return [] }
        let title = moment.formatted(date: .abbreviated, time: .shortened)
        let weekday = moment.formatted(.dateTime.weekday(.wide))
        return [
            MovesSearchHit(
                id: "moment-\(moment.timeIntervalSince1970)",
                kind: .moment,
                title: title,
                subtitle: String(localized: "Where you were on \(weekday)"),
                symbolName: "clock",
                action: .moment(moment)
            )
        ]
    }

    private static func noteHits(
        parsed: SearchQueryParser.ParsedQuery,
        days: [MovesSearchCorpus.Day]
    ) -> [MovesSearchHit] {
        let needle = parsed.freeText
        guard needle.count >= 2 else { return [] }
        var hits: [MovesSearchHit] = []
        for day in days.reversed() {
            for visit in day.visits {
                guard let comment = visit.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !comment.isEmpty,
                      comment.localizedCaseInsensitiveContains(needle) else { continue }
                hits.append(
                    MovesSearchHit(
                        id: "note-\(visit.id.uuidString)",
                        kind: .note,
                        title: comment,
                        subtitle: "\(visit.title) · \(MovesStatisticsFormatting.visitInterval(arrival: visit.arrivalDate, departure: visit.departureDate))",
                        symbolName: "note.text",
                        action: .visit(visit.id)
                    )
                )
                if hits.count >= resultLimit { return hits }
            }
            for move in day.moves {
                guard let comment = move.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !comment.isEmpty,
                      comment.localizedCaseInsensitiveContains(needle) else { continue }
                let mode = TransportMode(rawValue: move.modeRaw) ?? .unknown
                hits.append(
                    MovesSearchHit(
                        id: "note-move-\(move.id.uuidString)",
                        kind: .note,
                        title: comment,
                        subtitle: "\(mode.title) · \(MovesStatisticsFormatting.duration(move.duration))",
                        symbolName: "note.text",
                        action: .moment(move.startDate)
                    )
                )
                if hits.count >= resultLimit { return hits }
            }
        }
        return hits
    }

    private static func dayHit(
        for date: Date,
        timelines: [MovesSearchCorpus.Day],
        calendar: Calendar
    ) -> MovesSearchHit {
        let start = calendar.startOfDay(for: date)
        let key = DayTimeline.makeDayKey(for: start)
        let timeline = timelines.first { $0.dayKey == key }
        let subtitle: String
        if let timeline {
            let places = timeline.uniqueLocationCount
            subtitle = String(localized: "\(places) places")
        } else {
            subtitle = String(localized: "Open this day")
        }
        return MovesSearchHit(
            id: "day-\(key)",
            kind: .day,
            title: start.formatted(date: .complete, time: .omitted),
            subtitle: subtitle,
            symbolName: "calendar",
            action: .day(start)
        )
    }

    private static func placeMatches(_ place: MovesSearchCorpus.Place, needle: String) -> Bool {
        if place.name.localizedCaseInsensitiveContains(needle) { return true }
        if place.locality?.localizedCaseInsensitiveContains(needle) == true { return true }
        if place.category?.localizedCaseInsensitiveContains(needle) == true { return true }
        if place.countryCode?.localizedCaseInsensitiveContains(needle) == true { return true }
        let country = PlacesGeography.countryName(forCountryCode: place.countryCode)
        return country.localizedCaseInsensitiveContains(needle)
    }
}
