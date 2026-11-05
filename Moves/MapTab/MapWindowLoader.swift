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

/// Loads routes, visits, histogram buckets, and coverage cells for the current Map window.
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
    var coverageCells: [VisitedCellStore.DisplayCell] = []
    var presentModes: [TransportMode] = []
    var isLoading = false
    var cameraFitKey = ""

    @ObservationIgnored
    private var loadGeneration = 0
    @ObservationIgnored
    private var storedCells: [VisitedCell] = []
    @ObservationIgnored
    private var histogramSource: HistogramSource?
    @ObservationIgnored
    private var filteredHistogram: (hidden: Set<TransportMode>, buckets: [MapHistogramBucket])?

    /// What `histogram` was built from. Scrubbing the handles leaves all of this alone.
    private struct HistogramSource: Equatable {
        let interval: DateInterval
        let granularity: MapGranularity
        let moveCount: Int
    }

    func load(
        selection: MapRangeSelection,
        modelContext: ModelContext,
        cameraRegion: MKCoordinateRegion,
        includeCoverage: Bool = false,
        calendar: Calendar = .autoupdatingCurrent
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        if includeCoverage {
            await loadStoredCells(modelContext: modelContext)
            guard generation == loadGeneration else { return }
        }

        refreshHistogram(selection: selection, modelContext: modelContext, calendar: calendar)

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

        guard generation == loadGeneration, includeCoverage else { return }
        refreshCoverage(selection: selection, cameraRegion: cameraRegion)
    }

    /// Readies Heat and Fog when one is first shown, without reloading routes.
    func loadCoverage(
        selection: MapRangeSelection,
        modelContext: ModelContext,
        cameraRegion: MKCoordinateRegion
    ) async {
        await loadStoredCells(modelContext: modelContext)
        refreshCoverage(selection: selection, cameraRegion: cameraRegion)
    }

    private func loadStoredCells(modelContext: ModelContext) async {
        do {
            try await VisitedCellStore.ensureBuilt(container: modelContext.container)
            let count = try modelContext.fetchCount(FetchDescriptor<VisitedCell>())
            if count != storedCells.count {
                storedCells = try VisitedCellStore.fetchAll(in: modelContext)
            }
        } catch {
            storedCells = []
        }
    }

    func refreshCoverage(selection: MapRangeSelection, cameraRegion: MKCoordinateRegion) {
        coverageCells = VisitedCellStore.displayCells(
            from: storedCells,
            latitudeSpan: cameraRegion.span.latitudeDelta,
            region: cameraRegion,
            overlapping: selection.focus
        )
    }

    /// The scrubber's bars cover the whole interval, so they read moves for all of it rather
    /// than the focused routes. Keeps the last result while only the handles move.
    func refreshHistogram(
        selection: MapRangeSelection,
        modelContext: ModelContext,
        calendar: Calendar
    ) {
        let source = HistogramSource(
            interval: selection.interval,
            granularity: selection.granularity,
            moveCount: (try? modelContext.fetchCount(FetchDescriptor<MoveSegment>())) ?? 0
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
        selection: MapRangeSelection,
        allowDirections: Bool,
        generation: Int,
        calendar: Calendar
    ) async {
        let interval = selection.focus
        let moves: [MoveSegment]
        let visits: [VisitPlace]
        do {
            moves = try repository.moves(in: interval, modes: nil)
            visits = try repository.visits(in: interval)
        } catch {
            return
        }

        let immediate = moves.compactMap { move -> MapDisplayedRoute? in
            displayedRoute(from: move, coordinates: cachedOrRawCoordinates(for: move))
        }
        guard generation == loadGeneration else { return }
        apply(routes: immediate, visits: visits, selection: selection)

        guard allowDirections else { return }

        // Route matching suspends, and a move can be deleted while it waits. A deleted model
        // traps when read, so check before touching each one on either side of the wait.
        var refined: [MapDisplayedRoute] = []
        refined.reserveCapacity(moves.count)
        for move in moves {
            guard Self.isLive(move) else { continue }
            let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
            if generation != loadGeneration { return }
            guard Self.isLive(move) else { continue }
            if let route = displayedRoute(from: move, coordinates: coordinates) {
                refined.append(route)
            }
        }
        // `visits` went stale the same way during the wait.
        apply(routes: refined, visits: visits.filter { Self.isLive($0) }, selection: selection)
    }

    private static func isLive<Model: PersistentModel>(_ model: Model) -> Bool {
        model.modelContext != nil && !model.isDeleted
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
        let timelines = ((try? modelContext.fetch(FetchDescriptor<DayTimeline>())) ?? [])
            .filter { $0.hasRecordedActivity && $0.dayStart < interval.end && $0.dayStart.addingTimeInterval(86_400) > interval.start }

        var tracks: [ShareMapAggregateTrack] = []
        if period == .year, selection.granularity == .allTime {
            let years = Set(timelines.map { calendar.component(.year, from: $0.dayStart) })
            for year in years.sorted() {
                guard let yearDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
                if let cached = ShareMapAggregateStore.cachedTracks(
                    for: .year,
                    periodStart: yearDate,
                    timelines: timelines.filter { calendar.component(.year, from: $0.dayStart) == year },
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
                    dayStart: calendar.startOfDay(for: move.startDate),
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
        apply(routes: routes, visits: visitRows, selection: selection)

        let container = modelContext.container
        let periodStart = interval.start
        Task.detached(priority: .utility) {
            await ShareMapAggregateBuilder.refresh(period: period, periodStart: periodStart, in: container)
        }
    }

    private func apply(
        routes: [MapDisplayedRoute],
        visits: [VisitPlace],
        selection: MapRangeSelection
    ) {
        self.routes = routes
        self.visits = visits.map { place in
            MapVisitMarker(
                id: place.id,
                coordinate: place.coordinate,
                title: place.displayTitle,
                arrivalDate: place.arrivalDate
            )
        }
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
