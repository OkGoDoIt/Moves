import CoreLocation
import Foundation
import SwiftData

/// Launch repairs for the day rows themselves. Both run behind the upgrade screen.
///
/// A row used to be filed under the date on the phone's clock when it was written, so
/// history imported or rebuilt abroad sat on the wrong day: a San Francisco evening
/// imported in Vietnam showed on the next morning's page. The rule now is the calendar day
/// where it happened: a stay by its arrival at its own spot, a trip by its start at the
/// stop it left from, a fix by its own time and place, and a photo with the stay it
/// belongs to, or by its own time and place when it has none. A flight day keeps each row
/// once: the flight on the day it left, the first stop after landing on the local day
/// there, so a westbound day can run longer than 24 hours and an eastbound one across the
/// date line can have no rows at all.
enum TimelineDayRepair {
    struct Report: Equatable {
        var staysMoved = 0
        var tripsMoved = 0
        var fixesMoved = 0
        var photosMoved = 0
        var daysCreated = 0
        var dayStartsMoved = 0

        var rowsMoved: Int { staysMoved + tripsMoved + fixesMoved + photosMoved }
    }

    /// Rows per fetch for the two large tables, saved after each, so memory stays flat
    /// and an interrupted run keeps what it finished.
    static let pageSize = 4000

    /// Re-files every stay, trip, fix, and photo on the local day where it happened, and
    /// moves each day's start to local midnight where its first row happened. Moves rows
    /// between days and creates days; deletes nothing. Running it again changes nothing.
    @discardableResult
    static func fileDaysByLocalTime(
        in context: ModelContext,
        fallbackTimeZone: TimeZone = Calendar.current.timeZone,
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> Report {
        var report = Report()
        let total = try context.fetchCount(FetchDescriptor<LocationSample>())
            + context.fetchCount(FetchDescriptor<VisitPlace>.live())
            + context.fetchCount(FetchDescriptor<MoveSegment>.live())
            + context.fetchCount(FetchDescriptor<PhotoAttachment>())
        var done = 0
        progress?(0, total)
        var days = Days(context: context, existing: try context.fetch(
            FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.dayStart)])
        ))

        // Fixes first: each carries its own place, and together they place the rest.
        var history: [(date: Date, coordinate: CLLocationCoordinate2D)] = []
        var offset = 0
        while true {
            // A second key keeps pages stable when fixes share a timestamp.
            var descriptor = FetchDescriptor<LocationSample>(
                sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.dedupeKey)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            descriptor.relationshipKeyPathsForPrefetching = [\.dayTimeline]
            let page = try context.fetch(descriptor)
            if page.isEmpty { break }
            for sample in page {
                let coordinate = CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude)
                history.append((sample.timestamp, coordinate))
                // A fix with no real position stays where it is.
                guard let zone = PlaceTimeZone.timeZone(at: coordinate) else { continue }
                let day = days.day(for: sample.timestamp, in: zone, report: &report)
                if sample.dayTimeline !== day {
                    sample.dayTimeline = day
                    report.fixesMoved += 1
                }
            }
            try saveIfNeeded(context)
            offset += page.count
            done += page.count
            progress?(done, total)
            if page.count < pageSize { break }
        }
        let recorded = RecordedTimeZones(fixes: history)
        history = []

        func zone(for date: Date, at coordinate: CLLocationCoordinate2D?) -> TimeZone {
            coordinate.flatMap(PlaceTimeZone.timeZone(at:))
                ?? recorded.timeZone(near: date)
                ?? fallbackTimeZone
        }

        var visitDescriptor = FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\.arrivalDate)])
        visitDescriptor.relationshipKeyPathsForPrefetching = [\.dayTimeline]
        let visits = try context.fetch(visitDescriptor)
        for visit in visits {
            // No day is the rebuild's mark for a retired stop; filing it would revive it.
            guard visit.dayTimeline != nil else { continue }
            let day = days.day(for: visit.arrivalDate, in: zone(for: visit.arrivalDate, at: visit.coordinate), report: &report)
            if visit.dayTimeline !== day {
                visit.dayTimeline = day
                report.staysMoved += 1
            }
        }
        try saveIfNeeded(context)
        done += visits.count
        progress?(done, total)

        var moveDescriptor = FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\.startDate)])
        moveDescriptor.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.startPlace]
        let moves = try context.fetch(moveDescriptor)
        for move in moves {
            guard move.dayTimeline != nil else { continue }
            // The stop it left from says where it started; without one, the nearest fix.
            let start = move.startPlace.map(\.coordinate).flatMap { PlaceTimeZone.isUsable($0) ? $0 : nil }
            let day = days.day(for: move.startDate, in: zone(for: move.startDate, at: start), report: &report)
            if move.dayTimeline !== day {
                move.dayTimeline = day
                report.tripsMoved += 1
            }
        }
        try saveIfNeeded(context)
        done += moves.count
        progress?(done, total)

        offset = 0
        while true {
            var descriptor = FetchDescriptor<PhotoAttachment>(
                sortBy: [SortDescriptor(\.capturedAt), SortDescriptor(\.assetLocalIdentifier)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            descriptor.relationshipKeyPathsForPrefetching = [\.dayTimeline, \.visitPlace]
            let page = try context.fetch(descriptor)
            if page.isEmpty { break }
            for photo in page {
                let day: DayTimeline
                if let stayDay = photo.visitPlace?.dayTimeline {
                    day = stayDay
                } else {
                    let coordinate = photo.latitude.flatMap { latitude in
                        photo.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
                    }
                    day = days.day(for: photo.capturedAt, in: zone(for: photo.capturedAt, at: coordinate), report: &report)
                }
                if photo.dayTimeline !== day {
                    photo.dayTimeline = day
                    report.photosMoved += 1
                }
            }
            try saveIfNeeded(context)
            offset += page.count
            done += page.count
            progress?(min(done, total), total)
            if page.count < pageSize { break }
        }

        report.dayStartsMoved = days.settleDayStarts()
        try saveIfNeeded(context)
        return report
    }

    /// Days with no stay, trip, fix, or photo. Older builds made one for every date between
    /// the first recording and today so paging could reach them; paging walks the calendar
    /// itself now, and re-filing empties a few more. Today's row is left for the timeline.
    /// Returns how many were deleted.
    @discardableResult
    static func removeEmptyDays(in context: ModelContext, now: Date = .now) throws -> Int {
        let today = DayTimeline.makeDayKey(for: now)
        var removed = 0
        for day in try context.fetch(FetchDescriptor<DayTimeline>()) where day.dayKey < today {
            // A day's relationships cascade: one still holding a photo must stay.
            guard (day.placesStorage ?? []).isEmpty,
                  (day.movesStorage ?? []).isEmpty,
                  (day.samplesStorage ?? []).isEmpty,
                  (day.photosStorage ?? []).isEmpty
            else { continue }
            context.delete(day)
            removed += 1
        }
        try saveIfNeeded(context)
        return removed
    }

    private static func saveIfNeeded(_ context: ModelContext) throws {
        if context.hasChanges { try context.save() }
    }

    /// One row per key: the earliest created keeps it, and twins empty out into it.
    private struct Days {
        let context: ModelContext
        private var byKey: [String: DayTimeline] = [:]
        /// The earliest moment filed on each day and the zone it happened in.
        private var firstMoment: [String: (date: Date, zone: TimeZone)] = [:]

        init(context: ModelContext, existing: [DayTimeline]) {
            self.context = context
            for day in existing where byKey[day.dayKey] == nil {
                byKey[day.dayKey] = day
            }
        }

        mutating func day(for date: Date, in zone: TimeZone, report: inout Report) -> DayTimeline {
            let key = DayTimeline.makeDayKey(for: date, in: zone)
            if let first = firstMoment[key], first.date <= date {
                // Keep the earlier moment.
            } else {
                firstMoment[key] = (date, zone)
            }
            if let day = byKey[key] { return day }
            let day = DayTimeline(containing: date, in: zone)
            context.insert(day)
            byKey[key] = day
            report.daysCreated += 1
            return day
        }

        /// Puts each day's start at local midnight where its first row happened.
        func settleDayStarts() -> Int {
            var moved = 0
            for (key, first) in firstMoment {
                guard let day = byKey[key],
                      let start = TimelineDayFiling.startOfDay(forKey: key, in: first.zone),
                      abs(day.dayStart.timeIntervalSince(start)) >= 1
                else { continue }
                day.dayStart = start
                moved += 1
            }
            return moved
        }
    }
}
