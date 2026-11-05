//
//  MovesStatisticsSearchView.swift
//  Moves
//
//  Visit / journey aggregates used by Insights Connections. The former
//  Statistics & Search sheet was retired in WS8.
//

import Foundation

struct MovesLocationSummary: Identifiable {
    let id: String
    let title: String
    let visits: [VisitPlace]
    let totalDuration: TimeInterval

    var visitCount: Int { visits.count }
    var averageDuration: TimeInterval { visits.isEmpty ? 0 : totalDuration / Double(visits.count) }
    var latestVisit: VisitPlace? { visits.max(by: { $0.arrivalDate < $1.arrivalDate }) }
}

struct MovesConnectionJourney: Identifiable {
    let legs: [MoveSegment]

    var id: String { legs.map { $0.id.uuidString }.joined(separator: "|") }
    var startDate: Date { legs.first?.timelineStartDate ?? .distantPast }
    var endDate: Date { legs.last?.endDate ?? startDate }
    var duration: TimeInterval { max(endDate.timeIntervalSince(startDate), 0) }
    var distanceMeters: Double { legs.reduce(0) { $0 + max($1.distanceMeters, 0) } }
    var isDirect: Bool { legs.count == 1 }
    var originTitle: String { legs.first?.startPlace?.displayTitle ?? "Unknown place" }
    var destinationTitle: String { legs.last?.endPlace?.displayTitle ?? "Unknown place" }
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

struct MovesStatisticsSnapshot {
    let locations: [MovesLocationSummary]
    let visits: [VisitPlace]
    let moves: [MoveSegment]

    init(dayTimelines: [DayTimeline], now: Date = .now) {
        var placesByID: [UUID: VisitPlace] = [:]
        var movesByID: [UUID: MoveSegment] = [:]

        for day in dayTimelines {
            for place in day.places {
                placesByID[place.id] = place
            }
            for move in day.moves {
                movesByID[move.id] = move
                if let startPlace = move.startPlace {
                    placesByID[startPlace.id] = startPlace
                }
                if let endPlace = move.endPlace {
                    placesByID[endPlace.id] = endPlace
                }
            }
        }

        let allVisits = placesByID.values.sorted { $0.arrivalDate > $1.arrivalDate }
        let groupedVisits = Dictionary(grouping: allVisits, by: Self.locationKey)

        locations = groupedVisits.map { key, grouped in
            let sortedVisits = grouped.sorted { $0.arrivalDate > $1.arrivalDate }
            let totalDuration = sortedVisits.reduce(0) { partial, visit in
                let departure = min(visit.departureDate ?? now, now)
                return partial + max(departure.timeIntervalSince(visit.arrivalDate), 0)
            }
            return MovesLocationSummary(
                id: key,
                title: sortedVisits.first?.displayTitle ?? "Unknown place",
                visits: sortedVisits,
                totalDuration: totalDuration
            )
        }
        .sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        visits = allVisits
        moves = movesByID.values.sorted { $0.timelineStartDate < $1.timelineStartDate }
    }

    func filteredLocations(matching query: String) -> [MovesLocationSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }
        return locations.filter { location in
            location.title.localizedCaseInsensitiveContains(query)
                || location.visits.contains { Self.visit($0, matches: query) }
        }
    }

    func filteredVisits(matching query: String) -> [VisitPlace] {
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
            guard Self.locationKey(firstMove.startPlace) == originKey else { continue }

            var legs = [firstMove]
            guard let firstDestination = Self.locationKey(firstMove.endPlace) else { continue }
            if firstDestination == destinationKey {
                results.append(MovesConnectionJourney(legs: legs))
                continue
            }
            guard includingIndirect else { continue }

            var currentLocationKey = firstDestination
            var nextIndex = moves.index(after: startIndex)
            while nextIndex < moves.endIndex, legs.count < maximumLegCount {
                let nextMove = moves[nextIndex]
                guard Self.locationKey(nextMove.startPlace) == currentLocationKey else { break }

                let stopDuration = nextMove.timelineStartDate.timeIntervalSince(legs.last?.endDate ?? nextMove.timelineStartDate)
                guard stopDuration >= -60, stopDuration <= maximumIntermediateStop else { break }

                legs.append(nextMove)
                guard let nextDestination = Self.locationKey(nextMove.endPlace) else { break }
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

    private static func visit(_ visit: VisitPlace, matches query: String) -> Bool {
        if visit.displayTitle.localizedCaseInsensitiveContains(query) { return true }
        if visit.comment?.localizedCaseInsensitiveContains(query) == true { return true }

        let dateText = visit.arrivalDate.formatted(date: .long, time: .shortened)
        let numericDateText = visit.arrivalDate.formatted(date: .numeric, time: .shortened)
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
        let arrival = place.arrivalDate.formatted(date: .abbreviated, time: .shortened)
        guard let departure = place.departureDate else { return "Since \(arrival)" }
        return "\(arrival) · \(duration(departure.timeIntervalSince(place.arrivalDate)))"
    }
}
