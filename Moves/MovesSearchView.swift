import SwiftData
import SwiftUI

/// Unified search: places, days, moments, and notes. Results open existing deep links.
struct MovesSearchView: View {
    @EnvironmentObject private var rootController: MovesRootController
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KnownPlace.name) private var knownPlaces: [KnownPlace]

    let dayTimelines: [DayTimeline]
    @State private var query = ""
    @State private var sections: [MovesSearchSection] = []
    /// The query `sections` answers. Differs from `query` while a search is pending.
    @State private var searchedQuery = ""

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

    /// Walks every day on the main thread, so it waits for a pause in typing. The next
    /// keystroke cancels this task.
    private func runSearch(for text: String) async {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
        }
        sections = MovesSearchIndex.results(
            parsed: SearchQueryParser.parse(text, now: .now, calendar: calendar),
            knownPlaces: knownPlaces,
            days: dayTimelines,
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

/// Builds grouped search hits from the parsed query and live SwiftData rows.
enum MovesSearchIndex {
    static let resultLimit = 8

    static func results(
        parsed: SearchQueryParser.ParsedQuery,
        knownPlaces: [KnownPlace],
        days: [DayTimeline],
        now: Date,
        calendar: Calendar
    ) -> [MovesSearchSection] {
        guard !parsed.isEmpty else { return [] }

        var sections: [MovesSearchSection] = []
        let places = placeHits(parsed: parsed, knownPlaces: knownPlaces, days: days)
        if !places.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Places"), hits: places))
        }
        let dayHits = dayHits(parsed: parsed, days: days, calendar: calendar)
        if !dayHits.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Days"), hits: dayHits))
        }
        let moments = momentHits(parsed: parsed)
        if !moments.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Moments"), hits: moments))
        }
        let notes = noteHits(parsed: parsed, days: days)
        if !notes.isEmpty {
            sections.append(MovesSearchSection(title: String(localized: "Notes"), hits: notes))
        }
        return sections
    }

    private static func placeHits(
        parsed: SearchQueryParser.ParsedQuery,
        knownPlaces: [KnownPlace],
        days: [DayTimeline]
    ) -> [MovesSearchHit] {
        let needle = parsed.freeText
        guard needle.count >= 2 || (needle.count == 1 && parsed.day == nil) else { return [] }
        guard !needle.isEmpty else { return [] }

        var hits: [MovesSearchHit] = []
        var seen = Set<UUID>()

        for place in knownPlaces {
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

        for day in days {
            for visit in day.places {
                if let knownID = visit.knownPlace?.id, seen.contains(knownID) { continue }
                guard visit.displayTitle.localizedCaseInsensitiveContains(needle)
                    || (visit.locality?.localizedCaseInsensitiveContains(needle) == true) else {
                    continue
                }
                hits.append(
                    MovesSearchHit(
                        id: "visit-\(visit.id.uuidString)",
                        kind: .place,
                        title: visit.displayTitle,
                        subtitle: MovesStatisticsFormatting.visitInterval(visit),
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
        days: [DayTimeline],
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
        days: [DayTimeline]
    ) -> [MovesSearchHit] {
        let needle = parsed.freeText
        guard needle.count >= 2 else { return [] }
        var hits: [MovesSearchHit] = []
        for day in days.reversed() {
            for visit in day.places {
                guard let comment = visit.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !comment.isEmpty,
                      comment.localizedCaseInsensitiveContains(needle) else { continue }
                hits.append(
                    MovesSearchHit(
                        id: "note-\(visit.id.uuidString)",
                        kind: .note,
                        title: comment,
                        subtitle: "\(visit.displayTitle) · \(MovesStatisticsFormatting.visitInterval(visit))",
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
                hits.append(
                    MovesSearchHit(
                        id: "note-move-\(move.id.uuidString)",
                        kind: .note,
                        title: comment,
                        subtitle: "\(move.transportMode.title) · \(MovesStatisticsFormatting.duration(move.timelineDuration))",
                        symbolName: "note.text",
                        action: .moment(move.timelineStartDate)
                    )
                )
                if hits.count >= resultLimit { return hits }
            }
        }
        return hits
    }

    private static func dayHit(
        for date: Date,
        timelines: [DayTimeline],
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

    private static func placeMatches(_ place: KnownPlace, needle: String) -> Bool {
        if place.name.localizedCaseInsensitiveContains(needle) { return true }
        if place.locality?.localizedCaseInsensitiveContains(needle) == true { return true }
        if place.category?.localizedCaseInsensitiveContains(needle) == true { return true }
        if place.countryCode?.localizedCaseInsensitiveContains(needle) == true { return true }
        let country = PlacesGeography.countryName(forCountryCode: place.countryCode)
        return country.localizedCaseInsensitiveContains(needle)
    }
}
