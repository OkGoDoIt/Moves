//
//  MovesStatisticsSearchView.swift
//  Moves
//
//  Visit / journey aggregates used by Insights Connections. The former
//  Statistics & Search sheet was retired in WS8.
//

import CoreLocation
import Foundation
import SwiftData

/// One visit, copied off the store so Connections never holds a model another context can delete.
struct ConnectionVisit: Identifiable, Sendable {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let title: String
    let comment: String?
    let locationKey: String
    /// The clock where the stay happened.
    let timeZone: TimeZone

    init(_ place: VisitPlace) {
        id = place.id
        arrivalDate = place.arrivalDate
        departureDate = place.departureDate
        title = place.displayTitle
        comment = place.comment
        locationKey = MovesStatisticsSnapshot.locationKey(place)
        timeZone = PlaceTimeZone.timeZone(at: place.coordinate) ?? .autoupdatingCurrent
    }
}

/// One trip, copied off the store with what its two ends need.
struct ConnectionLeg: Identifiable, Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let distanceMeters: Double
    let modeRaw: String
    let startKey: String?
    let endKey: String?
    let startTitle: String?
    let endTitle: String?
    /// The clock where the trip began: its start stop, else its end stop.
    let timeZone: TimeZone

    var transportMode: TransportMode { TransportMode(rawValue: modeRaw) ?? .unknown }
    var duration: TimeInterval { max(endDate.timeIntervalSince(startDate), 0) }

    init(_ move: MoveSegment) {
        id = move.id
        startDate = move.timelineStartDate
        endDate = move.endDate
        distanceMeters = move.distanceMeters
        modeRaw = move.transportModeRawValue
        startKey = MovesStatisticsSnapshot.locationKey(move.startPlace)
        endKey = MovesStatisticsSnapshot.locationKey(move.endPlace)
        startTitle = move.startPlace?.displayTitle
        endTitle = move.endPlace?.displayTitle
        timeZone = (move.startPlace ?? move.endPlace).flatMap { PlaceTimeZone.timeZone(at: $0.coordinate) }
            ?? .autoupdatingCurrent
    }
}

struct MovesLocationSummary: Identifiable, Sendable {
    let id: String
    let title: String
    let visits: [ConnectionVisit]
    let totalDuration: TimeInterval

    var visitCount: Int { visits.count }
    var averageDuration: TimeInterval { visits.isEmpty ? 0 : totalDuration / Double(visits.count) }
    var latestVisit: ConnectionVisit? { visits.max(by: { $0.arrivalDate < $1.arrivalDate }) }
}

struct MovesConnectionJourney: Identifiable, Sendable {
    let legs: [ConnectionLeg]

    var id: String { legs.map { $0.id.uuidString }.joined(separator: "|") }
    var startDate: Date { legs.first?.startDate ?? .distantPast }
    var endDate: Date { legs.last?.endDate ?? startDate }
    var duration: TimeInterval { max(endDate.timeIntervalSince(startDate), 0) }
    var distanceMeters: Double { legs.reduce(0) { $0 + max($1.distanceMeters, 0) } }
    var isDirect: Bool { legs.count == 1 }
    var originTitle: String { legs.first?.startTitle ?? "Unknown place" }
    var destinationTitle: String { legs.last?.endTitle ?? "Unknown place" }

    /// When the journey set out, on the clock where it did, with the zone when that is
    /// not the phone's.
    func startText(_ base: Date.FormatStyle) -> String {
        let zone = legs.first?.timeZone ?? .autoupdatingCurrent
        return MovesStatisticsFormatting.withZone(PlaceClock.format(startDate, base, in: zone), zone, at: startDate)
    }
}

struct MovesConnectionStatistics {
    let journeys: [MovesConnectionJourney]

    var minimumDuration: TimeInterval? { journeys.map(\.duration).min() }
    var maximumDuration: TimeInterval? { journeys.map(\.duration).max() }
    var averageDuration: TimeInterval? {
        guard !journeys.isEmpty else { return nil }
        return journeys.reduce(0) { $0 + $1.duration } / Double(journeys.count)
    }
}

/// Visit and journey aggregates for Insights Connections, held as plain values.
struct MovesStatisticsSnapshot: Sendable {
    let locations: [MovesLocationSummary]
    let visits: [ConnectionVisit]
    let moves: [ConnectionLeg]

    /// Reads every visit and trip on a private context off the main actor. The reconciler
    /// deletes trips on its own context, and reading one on the main context before the
    /// merge aborts the process, so this never walks the view's `@Query` rows.
    static func load(from container: ModelContainer, now: Date = .now) async throws -> MovesStatisticsSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var placeFetch = FetchDescriptor<VisitPlace>.live()
            placeFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline]
            let visits = try context.fetch(placeFetch)
                .filter { $0.dayTimeline != nil }
                .map(ConnectionVisit.init)
            var moveFetch = FetchDescriptor<MoveSegment>.live()
            moveFetch.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace, \.endPlace]
            let moves = try context.fetch(moveFetch)
                .filter { $0.dayTimeline != nil }
                .map(ConnectionLeg.init)
            return MovesStatisticsSnapshot(visits: visits, moves: moves, now: now)
        }.value
    }

    /// Only for models no other context can delete: unsaved fixtures, or rows on a private context.
    init(dayTimelines: [DayTimeline], now: Date = .now) {
        var places: [UUID: ConnectionVisit] = [:]
        var moves: [UUID: ConnectionLeg] = [:]
        for day in dayTimelines {
            for place in day.places {
                places[place.id] = ConnectionVisit(place)
            }
            for move in day.moves {
                moves[move.id] = ConnectionLeg(move)
                if let startPlace = move.startPlace { places[startPlace.id] = ConnectionVisit(startPlace) }
                if let endPlace = move.endPlace { places[endPlace.id] = ConnectionVisit(endPlace) }
            }
        }
        self.init(visits: Array(places.values), moves: Array(moves.values), now: now)
    }

    init(visits: [ConnectionVisit], moves: [ConnectionLeg], now: Date = .now) {
        var uniqueVisits: [UUID: ConnectionVisit] = [:]
        for visit in visits { uniqueVisits[visit.id] = visit }
        let allVisits = uniqueVisits.values.sorted { $0.arrivalDate > $1.arrivalDate }
        let groupedVisits = Dictionary(grouping: allVisits, by: \.locationKey)

        locations = groupedVisits.map { key, grouped in
            let sortedVisits = grouped.sorted { $0.arrivalDate > $1.arrivalDate }
            let totalDuration = sortedVisits.reduce(0) { partial, visit in
                let departure = min(visit.departureDate ?? now, now)
                return partial + max(departure.timeIntervalSince(visit.arrivalDate), 0)
            }
            return MovesLocationSummary(
                id: key,
                title: sortedVisits.first?.title ?? "Unknown place",
                visits: sortedVisits,
                totalDuration: totalDuration
            )
        }
        .sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        self.visits = allVisits
        var uniqueMoves: [UUID: ConnectionLeg] = [:]
        for move in moves { uniqueMoves[move.id] = move }
        self.moves = uniqueMoves.values.sorted { $0.startDate < $1.startDate }
    }

    func filteredLocations(matching query: String) -> [MovesLocationSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }
        return locations.filter { location in
            location.title.localizedCaseInsensitiveContains(query)
                || location.visits.contains { Self.visit($0, matches: query) }
        }
    }

    func filteredVisits(matching query: String) -> [ConnectionVisit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visits }
        return visits.filter { Self.visit($0, matches: query) }
    }

    func journeys(
        from originKey: String,
        to destinationKey: String,
        includingIndirect: Bool,
        maximumIntermediateStop: TimeInterval = 12 * 60 * 60,
        maximumLegCount: Int = 8
    ) -> [MovesConnectionJourney] {
        guard originKey != destinationKey, maximumLegCount > 0 else { return [] }

        var results: [MovesConnectionJourney] = []
        for startIndex in moves.indices {
            let firstMove = moves[startIndex]
            guard firstMove.startKey == originKey else { continue }

            var legs = [firstMove]
            guard let firstDestination = firstMove.endKey else { continue }
            if firstDestination == destinationKey {
                results.append(MovesConnectionJourney(legs: legs))
                continue
            }
            guard includingIndirect else { continue }

            var currentLocationKey = firstDestination
            var nextIndex = moves.index(after: startIndex)
            while nextIndex < moves.endIndex, legs.count < maximumLegCount {
                let nextMove = moves[nextIndex]
                guard nextMove.startKey == currentLocationKey else { break }

                let stopDuration = nextMove.startDate.timeIntervalSince(legs.last?.endDate ?? nextMove.startDate)
                guard stopDuration >= -60, stopDuration <= maximumIntermediateStop else { break }

                legs.append(nextMove)
                guard let nextDestination = nextMove.endKey else { break }
                if nextDestination == destinationKey {
                    results.append(MovesConnectionJourney(legs: legs))
                    break
                }
                if nextDestination == originKey { break }

                currentLocationKey = nextDestination
                nextIndex = moves.index(after: nextIndex)
            }
        }

        var seen = Set<String>()
        return results
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.startDate > $1.startDate }
    }

    static func locationKey(_ place: VisitPlace) -> String {
        if let userLabel = normalized(place.userLabel) {
            return "user:\(userLabel)"
        }
        if let autoLabel = normalized(place.autoLabel) {
            return "auto:\(autoLabel)"
        }

        // Unnamed visits use roughly 100 m buckets. This absorbs normal GPS drift
        // while keeping nearby but distinct named places separate.
        let latitudeBucket = Int((place.latitude * 1_000).rounded())
        let longitudeBucket = Int((place.longitude * 1_000).rounded())
        return "coordinate:\(latitudeBucket)|\(longitudeBucket)"
    }

    static func locationKey(_ place: VisitPlace?) -> String? {
        place.map(locationKey)
    }

    private static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func visit(_ visit: ConnectionVisit, matches query: String) -> Bool {
        if visit.title.localizedCaseInsensitiveContains(query) { return true }
        if visit.comment?.localizedCaseInsensitiveContains(query) == true { return true }

        // A typed date finds the visits on that date where they happened.
        let dateText = PlaceClock.format(visit.arrivalDate, Date.FormatStyle(date: .long, time: .shortened), in: visit.timeZone)
        let numericDateText = PlaceClock.format(visit.arrivalDate, Date.FormatStyle(date: .numeric, time: .shortened), in: visit.timeZone)
        return dateText.localizedCaseInsensitiveContains(query)
            || numericDateText.localizedCaseInsensitiveContains(query)
    }
}

enum MovesStatisticsFormatting {
    static func duration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "—" }
        let totalMinutes = max(Int((value / 60).rounded()), 0)
        if totalMinutes < 60 { return "\(totalMinutes) min" }

        let totalHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if totalHours < 24 {
            return minutes == 0 ? "\(totalHours) hr" : "\(totalHours) hr \(minutes) min"
        }

        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days) d" : "\(days) d \(hours) hr"
    }

    /// Meters in the road unit the person's region uses, for chart axes.
    static var roadUnitMeters: Double {
        Locale.autoupdatingCurrent.measurementSystem == .metric ? 1_000 : 1_609.344
    }

    static var roadUnitTitle: String {
        Locale.autoupdatingCurrent.measurementSystem == .metric
            ? String(localized: "Kilometers")
            : String(localized: "Miles")
    }

    static func distance(_ meters: Double) -> String {
        Measurement(value: max(meters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func visitInterval(_ place: VisitPlace) -> String {
        visitInterval(arrival: place.arrivalDate, departure: place.departureDate, timeZone: place.placeTimeZone)
    }

    /// "Nov 3, 2025 at 4:22 PM · 2 hr" on the clock where the stay happened, ending with
    /// the zone ("· PST") when that clock is not the phone's, as the Timeline's day header does.
    static func visitInterval(
        arrival arrivalDate: Date,
        departure departureDate: Date?,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let arrival = PlaceClock.format(arrivalDate, Date.FormatStyle(date: .abbreviated, time: .shortened), in: timeZone)
        let text: String
        if let departureDate {
            text = "\(arrival) · \(duration(departureDate.timeIntervalSince(arrivalDate)))"
        } else {
            text = "Since \(arrival)"
        }
        return withZone(text, timeZone, at: arrivalDate)
    }

    /// "Nov 3 at 4:22 PM · PST" when `zone` is not the phone's clock at `moment`, else `text`.
    static func withZone(_ text: String, _ zone: TimeZone, at moment: Date) -> String {
        PlaceClock.foreignAbbreviation(of: zone, at: moment).map { "\(text) · \($0)" } ?? text
    }
}
