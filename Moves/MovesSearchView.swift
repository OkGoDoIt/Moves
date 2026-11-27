import CoreLocation
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
        // Matching walks every day and stay in the history and formats each day's date,
        // so it runs off the main actor; typing stays smooth while it works.
        let corpus = corpus ?? MovesSearchCorpus()
        let calendar = calendar
        let found = await Task.detached(priority: .userInitiated) {
            MovesSearchIndex.results(
                parsed: SearchQueryParser.parse(text, now: .now, calendar: calendar),
                corpus: corpus,
                now: .now,
                calendar: calendar
            )
        }.value
        guard !Task.isCancelled else { return }
        sections = found
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

struct MovesSearchHit: Identifiable, Equatable, Sendable {
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

struct MovesSearchSection: Identifiable, Equatable, Sendable {
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
        /// The clock where the stay happened.
        var timeZone: TimeZone = .current
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
        /// The clock the Timeline reads this day on (`DayTimeline.placeTimeZone`).
        var timeZone: TimeZone = .current

        /// The day's own date as midnight on `calendar`, as the Timeline pages by it.
        /// `dayStart` is midnight where the day happened, which on the phone's clock can
        /// fall on the date before.
        func calendarDate(in calendar: Calendar) -> Date {
            TimelineDayFiling.startOfDay(forKey: dayKey, in: calendar.timeZone) ?? calendar.startOfDay(for: dayStart)
        }
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

            var visitFetch = FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\.arrivalDate)])
            visitFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.knownPlace]
            var visits: [PersistentIdentifier: [Visit]] = [:]
            var buckets: [PersistentIdentifier: Set<String>] = [:]
            // The first stay and trip start of each day, for the day's clock.
            var firstStays: [PersistentIdentifier: (Date, CLLocationCoordinate2D)] = [:]
            var firstTripStarts: [PersistentIdentifier: (Date, CLLocationCoordinate2D)] = [:]
            let phone = Calendar.current.timeZone
            for visit in try context.fetch(visitFetch) {
                guard let day = visit.dayTimeline?.persistentModelID else { continue }
                let coordinate = visit.coordinate
                if firstStays[day] == nil { firstStays[day] = (visit.arrivalDate, coordinate) }
                visits[day, default: []].append(Visit(
                    id: visit.id,
                    title: visit.displayTitle,
                    locality: visit.locality,
                    comment: visit.comment,
                    knownPlaceID: visit.knownPlace?.id,
                    arrivalDate: visit.arrivalDate,
                    departureDate: visit.departureDate,
                    timeZone: PlaceTimeZone.timeZone(at: coordinate) ?? phone
                ))
                // Matches `DayTimeline.uniqueLocationCount`: ~10 m buckets.
                buckets[day, default: []].insert(
                    "\(Int((visit.latitude * 10_000).rounded()))|\(Int((visit.longitude * 10_000).rounded()))"
                )
            }

            var moveFetch = FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)])
            moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace]
            var moves: [PersistentIdentifier: [Move]] = [:]
            for move in try context.fetch(moveFetch) {
                guard let day = move.dayTimeline?.persistentModelID else { continue }
                if firstTripStarts[day] == nil, let start = move.startPlace {
                    firstTripStarts[day] = (move.startDate, start.coordinate)
                }
                moves[day, default: []].append(Move(
                    id: move.id,
                    comment: move.comment,
                    modeRaw: move.transportModeRawValue,
                    startDate: move.timelineStartDate,
                    duration: move.timelineDuration
                ))
            }

            corpus.days = try context.fetch(FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayKey)])).map { day in
                let id = day.persistentModelID
                return Day(
                    dayKey: day.dayKey,
                    dayStart: day.dayStart,
                    uniqueLocationCount: buckets[id]?.count ?? 0,
                    visits: visits[id] ?? [],
                    moves: moves[id] ?? [],
                    timeZone: DayTimeline.clock(
                        dayKey: day.dayKey,
                        firstStay: firstStays[id],
                        firstTripStart: firstTripStarts[id]
                    )
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
        let moments = momentHits(parsed: parsed, days: corpus.days, calendar: calendar)
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
                        subtitle: visitInterval(visit),
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
                // The day's own date, never `dayStart` read on the phone's clock.
                let date = timeline.calendarDate(in: calendar)
                let label = PlaceClock.format(date, Date.FormatStyle(date: .complete, time: .omitted), in: calendar.timeZone)
                let numeric = PlaceClock.format(date, Date.FormatStyle(date: .numeric, time: .omitted), in: calendar.timeZone)
                if label.localizedCaseInsensitiveContains(needle)
                    || numeric.localizedCaseInsensitiveContains(needle)
                    || timeline.dayKey.localizedCaseInsensitiveContains(needle) {
                    if hits.contains(where: { $0.id == "day-\(timeline.dayKey)" }) { continue }
                    hits.append(dayHit(for: date, timelines: days, calendar: calendar))
                }
                if hits.count >= resultLimit { break }
            }
        }
        return Array(hits.prefix(resultLimit))
    }

    private static func momentHits(
        parsed: SearchQueryParser.ParsedQuery,
        days: [MovesSearchCorpus.Day],
        calendar: Calendar
    ) -> [MovesSearchHit] {
        guard let typed = parsed.moment else { return [] }
        // The time typed means the clock of the day it names, as that day reads on the Timeline.
        let key = DayTimeline.makeDayKey(for: typed, in: calendar.timeZone)
        let zone = days.last { $0.dayKey == key }?.timeZone ?? calendar.timeZone
        let moment = parsed.moment(in: zone, calendar: calendar) ?? typed
        let title = MovesStatisticsFormatting.withZone(
            PlaceClock.format(moment, Date.FormatStyle(date: .abbreviated, time: .shortened), in: zone),
            zone,
            at: moment
        )
        let weekday = PlaceClock.format(moment, .dateTime.weekday(.wide), in: zone)
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
                        subtitle: "\(visit.title) · \(visitInterval(visit))",
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
        // `date` is a date on the phone's calendar; the day filed under that date is the
        // one with the same key, wherever it happened.
        let start = calendar.startOfDay(for: date)
        let key = DayTimeline.makeDayKey(for: start, in: calendar.timeZone)
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
            title: PlaceClock.format(start, Date.FormatStyle(date: .complete, time: .omitted), in: calendar.timeZone),
            subtitle: subtitle,
            symbolName: "calendar",
            action: .day(start)
        )
    }

    private static func visitInterval(_ visit: MovesSearchCorpus.Visit) -> String {
        MovesStatisticsFormatting.visitInterval(
            arrival: visit.arrivalDate,
            departure: visit.departureDate,
            timeZone: visit.timeZone
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
