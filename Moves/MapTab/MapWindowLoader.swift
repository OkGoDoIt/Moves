import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftData

/// One histogram column: moving minutes overlapping that bucket.
struct MapHistogramBucket: Identifiable, Equatable, Sendable {
    let interval: DateInterval
    let movingMinutes: Double

    var id: TimeInterval { interval.start.timeIntervalSinceReferenceDate }
}

/// A move's time span and mode: all the scrubber needs, wherever the focus sits.
struct MapHistogramSpan: Equatable {
    let start: Date
    let end: Date
    let mode: TransportMode
}

/// A route drawn on the Map tab, independent of SwiftData object identity.
struct MapDisplayedRoute: Identifiable, Equatable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let distanceMeters: CLLocationDistance
    let rendered: RenderedRoute

    var transportMode: TransportMode { rendered.transportMode }

    static func == (lhs: MapDisplayedRoute, rhs: MapDisplayedRoute) -> Bool {
        lhs.id == rhs.id
            && lhs.startDate == rhs.startDate
            && lhs.endDate == rhs.endDate
            && lhs.rendered.coordinates.count == rhs.rendered.coordinates.count
    }
}

/// A visit dot on the Map tab.
struct MapVisitMarker: Identifiable, Sendable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String
    let arrivalDate: Date
}

/// Loads routes, visits, and histogram buckets for the current Map window. Heat and Fog draw
/// from `MapCoverageController` instead.
@Observable
@MainActor
final class MapWindowLoader {
    /// Street-level zoom at which month/year windows switch from aggregates to per-move paths.
    static let detailedZoomLatitudeDelta = 0.05
    /// Ranges longer than this use share-card polylines instead of live directions.
    static let detailedDayLimit = 7

    var routes: [MapDisplayedRoute] = []
    var visits: [MapVisitMarker] = []
    var histogram: [MapHistogramBucket] = []
    private(set) var histogramSpans: [MapHistogramSpan] = []
    var presentModes: [TransportMode] = []
    var isLoading = false
    var cameraFitKey = ""

    @ObservationIgnored
    private var loadGeneration = 0
    @ObservationIgnored
    private var histogramSource: HistogramSource?
    @ObservationIgnored
    private var filteredHistogram: (hidden: Set<TransportMode>, buckets: [MapHistogramBucket])?
    /// Moving minutes per scrubber bucket per mode, when the histogram came from month summaries.
    @ObservationIgnored
    private var minutesByBucketAndMode: [[Double]]?
    @ObservationIgnored
    private var histogramSummaries: [MapMonthSummary] = []

    /// What `histogram` was built from. Scrubbing the handles leaves all of this alone.
    private struct HistogramSource: Equatable {
        let interval: DateInterval
        let granularity: MapGranularity
        let moveCount: Int
        /// Changes when the month summaries do; -1 when the histogram reads moves.
        var summaryGeneration = -1
    }

    /// Leaving the app: whatever a load in flight finds afterwards is dropped.
    func suspend() {
        loadGeneration += 1
    }

    func load(
        selection: MapRangeSelection,
        modelContext: ModelContext,
        cameraRegion: MKCoordinateRegion,
        includeRoutes: Bool = true,
        calendar: Calendar = .autoupdatingCurrent,
        summaries: (months: [MapMonthSummary], generation: Int)? = nil
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        refreshHistogram(selection: selection, modelContext: modelContext, calendar: calendar, summaries: summaries)

        guard includeRoutes else {
            // A large range is drawn from the tiles as a bitmap; building a polyline and
            // annotation for each trip and stay on the main thread would only be thrown away.
            let focus = selection.focus
            routes = []
            visits = []
            if minutesByBucketAndMode != nil {
                let present = Self.modesWithMinutes(in: focus, summaries: histogramSummaries, calendar: calendar)
                presentModes = TransportMode.allCases.filter { $0 != .stationary && present.contains($0) }
            } else {
                presentModes = TransportMode.allCases.filter { mode in
                    mode != .stationary && histogramSpans.contains { $0.mode == mode && $0.end > focus.start && $0.start < focus.end }
                }
            }
            cameraFitKey = "\(focus.start.timeIntervalSinceReferenceDate)|\(focus.end.timeIntervalSinceReferenceDate)|index"
            return
        }

        let repository = SwiftDataTimelineRepository(modelContext: modelContext)
        let dayCount = max(
            calendar.dateComponents([.day], from: selection.interval.start, to: selection.interval.end).day ?? 0,
            1
        )
        let allowDirections = dayCount <= Self.detailedDayLimit
        let zoomedIn = cameraRegion.span.latitudeDelta < Self.detailedZoomLatitudeDelta
        let usePerMove = allowDirections || (zoomedIn && dayCount <= 14)

        if usePerMove {
            await loadMoves(
                repository: repository,
                modelContext: modelContext,
                selection: selection,
                allowDirections: allowDirections,
                generation: generation,
                calendar: calendar
            )
        } else {
            await loadAggregates(
                repository: repository,
                selection: selection,
                modelContext: modelContext,
                generation: generation,
                calendar: calendar
            )
        }
    }

    /// The scrubber's bars cover the whole interval, so they read moves for all of it rather
    /// than the focused routes. Keeps the last result while only the handles move.
    func refreshHistogram(
        selection: MapRangeSelection,
        modelContext: ModelContext,
        calendar: Calendar,
        summaries: (months: [MapMonthSummary], generation: Int)? = nil
    ) {
        // A day's bars are hours, finer than the summaries; longer ranges add up whole days, so
        // years of history cost the same as one month and nothing is fetched on the main thread.
        if let summaries, selection.granularity != .day {
            let source = HistogramSource(interval: selection.interval, granularity: selection.granularity,
                                         moveCount: 0, summaryGeneration: summaries.generation)
            guard source != histogramSource else { return }
            histogramSource = source
            filteredHistogram = nil
            histogramSpans = []
            histogramSummaries = summaries.months
            let buckets = selection.scrubberBuckets(calendar: calendar)
            let perMode = Self.minutes(in: buckets, summaries: summaries.months, calendar: calendar)
            minutesByBucketAndMode = perMode
            histogram = zip(buckets, perMode).map { MapHistogramBucket(interval: $0, movingMinutes: $1.reduce(0, +)) }
            return
        }
        minutesByBucketAndMode = nil
        histogramSummaries = []
        let source = HistogramSource(
            interval: selection.interval,
            granularity: selection.granularity,
            moveCount: (try? modelContext.fetchCount(FetchDescriptor<MoveSegment>.live())) ?? 0
        )
        guard source != histogramSource else { return }
        histogramSource = source
        filteredHistogram = nil

        let moves = (try? SwiftDataTimelineRepository(modelContext: modelContext)
            .moves(in: selection.interval, modes: nil)) ?? []
        histogramSpans = moves.map { move in
            MapHistogramSpan(start: move.startDate, end: move.endDate, mode: move.transportMode)
        }
        histogram = Self.makeHistogram(spans: histogramSpans, selection: selection, calendar: calendar)
    }

    /// Forces the next load to reread moves, for edits made while the Map was off screen.
    func invalidateHistogram() {
        histogramSource = nil
    }

    /// `histogram` without the modes switched off on the chips.
    func filteredBuckets(
        hiding hidden: Set<TransportMode>,
        selection: MapRangeSelection,
        calendar: Calendar
    ) -> [MapHistogramBucket] {
        guard !hidden.isEmpty else { return histogram }
        if let filteredHistogram, filteredHistogram.hidden == hidden {
            return filteredHistogram.buckets
        }
        if let perMode = minutesByBucketAndMode {
            let shown = TransportMode.allCases.map { !hidden.contains($0) }
            let buckets = zip(histogram, perMode).map { bucket, minutes in
                MapHistogramBucket(interval: bucket.interval,
                                   movingMinutes: minutes.enumerated().reduce(0) { $0 + (shown[$1.offset] ? $1.element : 0) })
            }
            filteredHistogram = (hidden, buckets)
            return buckets
        }
        let buckets = Self.makeHistogram(
            spans: histogramSpans.filter { !hidden.contains($0.mode) },
            selection: selection,
            calendar: calendar
        )
        filteredHistogram = (hidden, buckets)
        return buckets
    }

    private func loadMoves(
        repository: SwiftDataTimelineRepository,
        modelContext: ModelContext,
        selection: MapRangeSelection,
        allowDirections: Bool,
        generation: Int,
        calendar: Calendar
    ) async {
        let interval = selection.focus
        let moves: [MoveSegment]
        let markers: [MapVisitMarker]
        do {
            moves = try repository.moves(in: interval, modes: nil)
            markers = Self.markers(for: try repository.visits(in: interval))
        } catch {
            return
        }

        let immediate = moves.compactMap { move -> MapDisplayedRoute? in
            displayedRoute(from: move, coordinates: cachedOrRawCoordinates(for: move))
        }
        guard generation == loadGeneration else { return }
        apply(routes: immediate, markers: markers, selection: selection)

        guard allowDirections else { return }

        // Route matching suspends, and in that time a trip can be deleted or retired. No row
        // is held across the wait: each is looked up by id on either side of it.
        let moveIDs = moves.map(\.id)
        var refined: [MapDisplayedRoute] = []
        refined.reserveCapacity(moveIDs.count)
        for id in moveIDs {
            guard let move = Self.liveMove(id, in: modelContext) else { continue }
            let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
            if generation != loadGeneration { return }
            guard let current = Self.liveMove(id, in: modelContext) else { continue }
            if let route = displayedRoute(from: current, coordinates: coordinates) {
                refined.append(route)
            }
        }
        // Stays can go the same way during the wait; their markers are plain values.
        let markerIDs = markers.map(\.id)
        let liveVisitIDs = Set(((try? modelContext.fetch(FetchDescriptor<VisitPlace>(
            predicate: #Predicate { markerIDs.contains($0.id) && $0.dayTimeline != nil }
        ))) ?? []).map(\.id))
        apply(routes: refined, markers: markers.filter { liveVisitIDs.contains($0.id) }, selection: selection)
    }

    private static func liveMove(_ id: UUID, in context: ModelContext) -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id && $0.dayTimeline != nil })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func markers(for visits: [VisitPlace]) -> [MapVisitMarker] {
        visits.map { place in
            MapVisitMarker(
                id: place.id,
                coordinate: place.coordinate,
                title: place.displayTitle,
                arrivalDate: place.arrivalDate
            )
        }
    }

    private func loadAggregates(
        repository: SwiftDataTimelineRepository,
        selection: MapRangeSelection,
        modelContext: ModelContext,
        generation: Int,
        calendar: Calendar
    ) async {
        let interval = selection.focus
        let period: MovesSharePeriod = selection.granularity == .year || selection.granularity == .allTime
            ? .year
            : .month
        // A day belongs to the range by its own date, read on the range's calendar.
        let dated = ((try? modelContext.fetch(FetchDescriptor<DayTimeline>())) ?? [])
            .map { (day: $0, date: $0.calendarDate(in: calendar)) }
            .filter { $0.day.hasRecordedActivity && $0.date < interval.end && $0.date.addingTimeInterval(86_400) > interval.start }
        let timelines = dated.map(\.day)

        var tracks: [ShareMapAggregateTrack] = []
        if period == .year, selection.granularity == .allTime {
            let years = Set(dated.map { calendar.component(.year, from: $0.date) })
            for year in years.sorted() {
                guard let yearDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
                if let cached = ShareMapAggregateStore.cachedTracks(
                    for: .year,
                    periodStart: yearDate,
                    timelines: dated.filter { calendar.component(.year, from: $0.date) == year }.map(\.day),
                    in: modelContext
                ) {
                    tracks.append(contentsOf: cached)
                }
            }
        } else if let cached = ShareMapAggregateStore.cachedTracks(
            for: period,
            periodStart: interval.start,
            timelines: timelines,
            in: modelContext
        ) {
            tracks = cached
        }

        if tracks.isEmpty {
            let moves = (try? repository.moves(in: interval, modes: nil)) ?? []
            tracks = moves.compactMap { move in
                let coordinates = cachedOrRawCoordinates(for: move)
                guard coordinates.count > 1 else { return nil }
                return ShareMapAggregateTrack(
                    id: move.id,
                    transportMode: move.transportMode,
                    coordinates: Self.downsampled(coordinates, maximumCount: period == .year ? 80 : 120),
                    dayStart: move.dayTimeline?.calendarDate(in: calendar) ?? calendar.startOfDay(for: move.startDate),
                    startDate: move.startDate,
                    endDate: move.endDate,
                    distanceMeters: move.distanceMeters
                )
            }
        }

        let routes = tracks.compactMap { track -> MapDisplayedRoute? in
            guard track.coordinates.count > 1 else { return nil }
            if track.endDate <= interval.start || track.startDate >= interval.end,
               track.dayStart != .distantPast {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: track.dayStart) ?? track.dayStart
                if dayEnd <= interval.start || track.dayStart >= interval.end {
                    return nil
                }
            }
            return MapDisplayedRoute(
                id: track.id,
                startDate: track.startDate == .distantPast ? track.dayStart : track.startDate,
                endDate: track.endDate == .distantPast
                    ? calendar.date(byAdding: .day, value: 1, to: track.dayStart) ?? track.dayStart
                    : track.endDate,
                distanceMeters: track.distanceMeters,
                rendered: RenderedRoute(
                    id: track.id.uuidString,
                    coordinates: track.coordinates,
                    usesHighAccuracyRouteTracking: false,
                    usesHealthWorkoutRoute: false,
                    transportMode: track.transportMode,
                    speedFractions: nil,
                    confidence: .medium,
                    origin: .sensor
                )
            )
        }

        let visitRows = (try? repository.visits(in: interval)) ?? []
        guard generation == loadGeneration else { return }
        apply(routes: routes, markers: Self.markers(for: visitRows), selection: selection)

        let container = modelContext.container
        let periodStart = interval.start
        Task.detached(priority: .utility) {
            await ShareMapAggregateBuilder.refresh(period: period, periodStart: periodStart, in: container)
        }
    }

    private func apply(
        routes: [MapDisplayedRoute],
        markers: [MapVisitMarker],
        selection: MapRangeSelection
    ) {
        self.routes = routes
        self.visits = markers
        presentModes = TransportMode.allCases.filter { mode in
            mode != .stationary && routes.contains { $0.transportMode == mode }
        }
        cameraFitKey = [
            selection.focus.start.timeIntervalSinceReferenceDate,
            selection.focus.end.timeIntervalSinceReferenceDate,
            routes.count,
            visits.count
        ]
        .map { "\($0)" }
        .joined(separator: "|")
    }

    static func makeHistogram(
        spans: [MapHistogramSpan],
        selection: MapRangeSelection,
        calendar: Calendar
    ) -> [MapHistogramBucket] {
        let buckets = selection.scrubberBuckets(calendar: calendar)
        return buckets.map { bucket in
            let seconds = spans.reduce(0.0) { partial, span in
                partial + overlap(bucket, DateInterval(start: span.start, end: max(span.end, span.start.addingTimeInterval(1))))
            }
            return MapHistogramBucket(interval: bucket, movingMinutes: seconds / 60)
        }
    }

    /// Moving minutes per bucket per mode from month summaries, each move counted on its start day.
    static func minutes(in buckets: [DateInterval], summaries: [MapMonthSummary], calendar: Calendar) -> [[Double]] {
        let modeCount = TransportMode.allCases.count
        var result = buckets.map { _ in [Double](repeating: 0, count: modeCount) }
        guard !buckets.isEmpty else { return result }
        for summary in summaries {
            let span = MapTileBucket.interval(ofMonth: summary.bucket, calendar: calendar)
            guard span.end > buckets[0].start, span.start < buckets[buckets.count - 1].end else { continue }
            // Year and all-time bars hold whole months: no day arithmetic.
            if let whole = buckets.firstIndex(where: { $0.start <= span.start && $0.end >= span.end }) {
                for mode in 0..<modeCount {
                    result[whole][mode] += summary.dayMinutesByMode[mode].reduce(0, +)
                }
                continue
            }
            for day in 0..<31 {
                guard let start = calendar.date(byAdding: .day, value: day, to: span.start), start < span.end else { break }
                // Buckets are sorted; find the one holding this day.
                var low = 0, high = buckets.count - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if buckets[mid].start <= start { low = mid } else { high = mid - 1 }
                }
                guard buckets[low].start <= start, start < buckets[low].end else { continue }
                for mode in 0..<modeCount {
                    result[low][mode] += summary.dayMinutesByMode[mode][day]
                }
            }
        }
        return result
    }

    /// Modes with any moving time in `interval`, by day, from month summaries.
    static func modesWithMinutes(in interval: DateInterval, summaries: [MapMonthSummary], calendar: Calendar) -> Set<TransportMode> {
        var present = Set<TransportMode>()
        for summary in summaries {
            let span = MapTileBucket.interval(ofMonth: summary.bucket, calendar: calendar)
            guard span.end > interval.start, span.start < interval.end else { continue }
            if interval.start <= span.start, interval.end >= span.end {
                for (index, mode) in TransportMode.allCases.enumerated() where summary.dayMinutesByMode[index].contains(where: { $0 > 0 }) {
                    present.insert(mode)
                }
                continue
            }
            for day in 0..<31 {
                guard let start = calendar.date(byAdding: .day, value: day, to: span.start), start < span.end else { break }
                guard start < interval.end, start.addingTimeInterval(86_400) > interval.start else { continue }
                for (index, mode) in TransportMode.allCases.enumerated() where summary.dayMinutesByMode[index][day] > 0 {
                    present.insert(mode)
                }
            }
        }
        return present
    }

    static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        let start = max(a.start, b.start)
        let end = min(a.end, b.end)
        return max(end.timeIntervalSince(start), 0)
    }

    private func displayedRoute(from move: MoveSegment, coordinates: [CLLocationCoordinate2D]) -> MapDisplayedRoute? {
        guard coordinates.count > 1 else { return nil }
        return MapDisplayedRoute(
            id: move.id,
            startDate: move.startDate,
            endDate: move.endDate,
            distanceMeters: move.distanceMeters,
            rendered: RenderedRoute.make(from: move, coordinates: coordinates)
        )
    }

    private func cachedOrRawCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        return move.manualRouteCoordinates
            ?? move.cachedRouteCoordinates(for: signature)
            ?? fallback
    }

    private static func downsampled(
        _ coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[min(Int((Double(index) * step).rounded()), coordinates.count - 1)]
        }
    }
}
