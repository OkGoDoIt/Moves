import CoreLocation
import Foundation
import SwiftData

/// Lightweight visit fields used to name a trip and summarise countries.
struct TripVisitSnapshot: Equatable, Sendable {
    var locality: String?
    var countryCode: String?
}

/// Distance, countries, default name, and photos for a trip’s date range.
///
/// A trip is a lens: these helpers read existing visits, moves, and
/// `PhotoAttachment`s and never copy or delete them.
enum TripRangeStats {
    /// One city wins when it is a strict majority of visits that have a locality.
    static let majorityThreshold = 0.5

    /// Builds a snapshot from a live visit, preferring the visit’s geocode then the known place.
    static func snapshot(from visit: VisitPlace) -> TripVisitSnapshot {
        TripVisitSnapshot(
            locality: firstNonEmpty(visit.locality, visit.knownPlace?.locality),
            countryCode: firstNonEmpty(visit.countryCode, visit.knownPlace?.countryCode)
        )
    }

    /// Default trip name: dominating locality, otherwise the date span.
    static func defaultName(
        visits: [TripVisitSnapshot],
        interval: DateInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        if let city = majorityLocality(from: visits) {
            return city
        }
        return dateSpanTitle(for: interval, calendar: calendar)
    }

    static func defaultName(
        visits: [VisitPlace],
        interval: DateInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        defaultName(visits: visits.map(Self.snapshot(from:)), interval: interval, calendar: calendar)
    }

    /// Returns the locality that covers more than half of labelled visits, if any.
    static func majorityLocality(from visits: [TripVisitSnapshot]) -> String? {
        let labelled = visits.compactMap { trimmed($0.locality) }
        guard !labelled.isEmpty else { return nil }
        let grouped = Dictionary(grouping: labelled) { $0.lowercased() }
        guard let winner = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        let share = Double(winner.value.count) / Double(labelled.count)
        guard share > majorityThreshold || grouped.count == 1 else { return nil }
        return winner.value.first
    }

    static func distanceMeters(moves: [MoveSegment]) -> CLLocationDistance {
        moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
    }

    /// Unique ISO country codes in visit order, skipping empties.
    static func countryCodes(from visits: [TripVisitSnapshot]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for visit in visits {
            guard let code = trimmed(visit.countryCode)?.uppercased(), seen.insert(code).inserted else {
                continue
            }
            ordered.append(code)
        }
        return ordered
    }

    static func countryCodes(from visits: [VisitPlace]) -> [String] {
        countryCodes(from: visits.map(Self.snapshot(from:)))
    }

    /// Medium date span; includes times only for intra-day custom ranges.
    static func dateSpanTitle(
        for interval: DateInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = includesTime(for: interval, calendar: calendar) ? .short : .none
        let lastIncluded = interval.end.addingTimeInterval(-1)
        return formatter.string(from: interval.start, to: max(lastIncluded, interval.start))
    }

    /// Full calendar days omit the clock; a five-hour afternoon keeps it.
    static func includesTime(for interval: DateInterval, calendar: Calendar) -> Bool {
        guard interval.duration <= 36 * 3_600 else { return false }
        let startMidnight = calendar.startOfDay(for: interval.start)
        let endMidnight = calendar.startOfDay(for: interval.end)
        let startsAtMidnight = abs(interval.start.timeIntervalSince(startMidnight)) < 60
        let endsAtMidnight = abs(interval.end.timeIntervalSince(endMidnight)) < 60
        return !(startsAtMidnight && endsAtMidnight)
    }

    static func photos(
        in range: DateInterval,
        context: ModelContext
    ) throws -> [PhotoAttachment] {
        let start = range.start
        let end = range.end
        let descriptor = FetchDescriptor<PhotoAttachment>(
            predicate: #Predicate { photo in
                photo.capturedAt >= start && photo.capturedAt < end
            },
            sortBy: [SortDescriptor(\PhotoAttachment.capturedAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// First geotagged photo in range, else the earliest attachment.
    static func coverPhoto(from photos: [PhotoAttachment]) -> PhotoAttachment? {
        photos.first { $0.latitude != nil && $0.longitude != nil } ?? photos.first
    }

    static func summary(
        for trip: NamedTrip,
        in context: ModelContext
    ) -> TripListSummary {
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let visits = (try? repository.visits(in: trip.interval)) ?? []
        let moves = (try? repository.moves(in: trip.interval, modes: nil)) ?? []
        let photos = (try? photos(in: trip.interval, context: context)) ?? []
        return TripListSummary(
            distanceMeters: distanceMeters(moves: moves),
            countryCodes: countryCodes(from: visits),
            photoCount: photos.count,
            coverAssetLocalIdentifier: coverPhoto(from: photos)?.assetLocalIdentifier,
            visitCount: visits.count,
            moveCount: moves.count
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap(trimmed).first
    }
}

/// Row metrics for the trip list, computed from the live timeline.
struct TripListSummary: Equatable, Sendable {
    var distanceMeters: CLLocationDistance
    var countryCodes: [String]
    var photoCount: Int
    var coverAssetLocalIdentifier: String?
    var visitCount: Int
    var moveCount: Int

    static let empty = TripListSummary(
        distanceMeters: 0,
        countryCodes: [],
        photoCount: 0,
        coverAssetLocalIdentifier: nil,
        visitCount: 0,
        moveCount: 0
    )
}

/// Parses `moves://trip/{uuid}`.
enum TripDeepLink {
    static func tripID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "moves" else { return nil }
        guard url.host?.lowercased() == "trip" else { return nil }
        return url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
    }

    static func url(for tripID: UUID) -> URL? {
        URL(string: "moves://trip/\(tripID.uuidString)")
    }
}
