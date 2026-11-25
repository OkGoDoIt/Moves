import CoreLocation
import Foundation
import Observation
import SwiftData

/// One stay's naming lookups, shared by its chip row and the Choose a Place sheet.
///
/// It reads learned places once, asks Apple for what is nearby (widening when that is
/// thin), and runs typed searches: debounced, never under two characters, at most one in
/// flight, paced app-wide, and cached per query so backspacing is instant. Results are
/// kept per query, so a slow early answer can only ever fill its own query's slot and
/// never replaces what a newer query shows. It never writes to the store and never
/// changes a name; the views decide what a pick does.
@MainActor
@Observable
final class PlaceNamingModel {
    enum SearchState: Equatable {
        case searching
        case finished
        /// Offline or throttled: local filtering still works, nothing is said about it.
        case unavailable
    }

    static let defaultChipCount = NearbyPlaceSuggester.maximumCandidates
    static let minimumQueryLength = 2

    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var accuracy: CLLocationDistance = 0
    private(set) var known: [NearbyKnownPlace] = []
    private(set) var nearbyHits: [NearbySearchHit] = []
    /// The handful of best guesses. Set when learned places load and once more when Apple's
    /// nearby places arrive (learned places keep their spots), then left alone.
    private(set) var defaultChips: [NearbyPlaceCandidate] = []
    private(set) var isLoadingNearby = false
    private(set) var typedResults: [String: [NearbySearchHit]] = [:]
    private(set) var searchStates: [String: SearchState] = [:]

    /// What the person is typing in the stay's own Name field; narrows the chip row.
    var fieldQuery: String = "" {
        didSet { if fieldQuery != oldValue { scheduleSearch(for: fieldQuery) } }
    }

    /// What the person is typing in Choose a Place (or the rename sheet's field).
    var sheetQuery: String = "" {
        didSet { if sheetQuery != oldValue { scheduleSearch(for: sheetQuery) } }
    }

    @ObservationIgnored private let searcher: any LocalPlaceSearching
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pacer: PlaceSearchPacer
    @ObservationIgnored private let cache: PlaceSearchCache
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadKey: String?
    @ObservationIgnored private var widenTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSearchKey: String?

    init(
        searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher(),
        debounce: Duration = .milliseconds(350),
        pacer: PlaceSearchPacer = .shared,
        cache: PlaceSearchCache? = nil
    ) {
        self.searcher = searcher
        self.debounce = debounce
        self.pacer = pacer
        self.cache = cache ?? .shared
    }

    // MARK: Loading

    /// Reads learned places around `coordinate` from the store, then loads nearby names.
    func prepare(near coordinate: CLLocationCoordinate2D, accuracy: CLLocationDistance, modelContext: ModelContext) async {
        if loadKey == Self.locationKey(coordinate), let loadTask {
            await loadTask.value
            return
        }
        let places = (try? SwiftDataTimelineRepository(modelContext: modelContext)
            .knownPlaces(near: coordinate, within: NearbyPlaceSuggester.listRadius)) ?? []
        await prepare(near: coordinate, accuracy: accuracy, knownPlaces: places)
    }

    /// Loads nearby names once per spot; a second caller for the same spot waits for the first.
    func prepare(near coordinate: CLLocationCoordinate2D, accuracy: CLLocationDistance, knownPlaces: [KnownPlace]) async {
        let key = Self.locationKey(coordinate)
        if loadKey == key, let loadTask {
            await loadTask.value
            return
        }
        loadTask?.cancel()
        widenTask?.cancel()
        if self.coordinate.map(Self.locationKey) != key {
            nearbyHits = []
            typedResults = [:]
            searchStates = [:]
        }
        self.coordinate = coordinate
        self.accuracy = accuracy
        known = knownPlaces.map(NearbyKnownPlace.init)
        // Learned places show at once; nothing here needs the network.
        defaultChips = NearbyPlaceSuggester.merge(
            visitCoordinate: coordinate,
            known: known,
            searchHits: nearbyHits,
            query: nil,
            accuracy: accuracy
        )
        loadKey = key
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadNearby(around: coordinate)
        }
        loadTask = task
        await task.value
        // A query typed before the spot was known is searched now.
        for query in [fieldQuery, sheetQuery] where !query.isEmpty {
            scheduleSearch(for: query)
        }
    }

    /// Stops lookups when the naming surface goes away. A later `prepare` starts over.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        widenTask?.cancel()
        widenTask = nil
        loadKey = nil
        cancelSearch()
    }

    private func loadNearby(around coordinate: CLLocationCoordinate2D) async {
        isLoadingNearby = true
        defer { isLoadingNearby = false }
        guard let first = await fetch(query: nil, radius: NearbyPlaceSuggester.listRadius, around: coordinate),
              !Task.isCancelled
        else { return }
        nearbyHits = first
        defaultChips = NearbyPlaceSuggester.merge(
            visitCoordinate: coordinate,
            known: known,
            searchHits: first,
            query: nil,
            accuracy: accuracy
        )
        guard first.count < NearbyPlaceSuggester.listTarget else { return }
        // The wider pass only feeds Choose a Place, so callers waiting on the guesses don't wait for it.
        widenTask?.cancel()
        widenTask = Task { [weak self] in
            guard let self,
                  let wider = await self.fetch(query: nil, radius: NearbyPlaceSuggester.widenedListRadius, around: coordinate),
                  !Task.isCancelled
            else { return }
            self.nearbyHits = first + wider
        }
    }

    // MARK: Typed search

    /// Folded, trimmed text: "Café " and "cafe" share one search.
    static func queryKey(_ text: String) -> String {
        PlaceNamingRanking.folded(text)
    }

    private func scheduleSearch(for text: String) {
        cancelSearch()
        let key = Self.queryKey(text)
        guard key.count >= Self.minimumQueryLength, let coordinate else { return }
        if typedResults[key] != nil { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache.hits(for: PlaceSearchCache.key(coordinate, query: key, radius: NearbyPlaceSuggester.typedSearchRadius)) {
            typedResults[key] = cached
            searchStates[key] = .finished
            return
        }
        searchStates[key] = .searching
        pendingSearchKey = key
        let debounce = debounce
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self else { return }
            let hits = await self.fetch(
                query: trimmed,
                radius: NearbyPlaceSuggester.typedSearchRadius,
                around: coordinate,
                cacheQuery: key
            )
            // A superseded request leaves no trace; its slot is reset by `cancelSearch`.
            guard !Task.isCancelled, self.pendingSearchKey == key else { return }
            self.pendingSearchKey = nil
            if let hits {
                self.typedResults[key] = hits
                self.searchStates[key] = .finished
            } else {
                self.searchStates[key] = .unavailable
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        if let pending = pendingSearchKey, searchStates[pending] == .searching {
            searchStates[pending] = nil
        }
        pendingSearchKey = nil
    }

    /// One paced, cached request. `nil` when it failed or was cancelled.
    private func fetch(
        query: String?,
        radius: CLLocationDistance,
        around coordinate: CLLocationCoordinate2D,
        cacheQuery: String? = nil
    ) async -> [NearbySearchHit]? {
        let cacheKey = PlaceSearchCache.key(coordinate, query: cacheQuery ?? query ?? "", radius: radius)
        if let cached = cache.hits(for: cacheKey) { return cached }
        do {
            try await pacer.waitForTurn()
            let hits = try await searcher.search(near: coordinate, query: query, radius: radius)
            try Task.checkCancellation()
            cache.store(hits, for: cacheKey)
            return hits
        } catch {
            return nil
        }
    }

    // MARK: What the views show

    func listing(for text: String) -> PlaceChoiceListing {
        guard let coordinate else { return .empty }
        let key = Self.queryKey(text)
        let typed = key.count >= Self.minimumQueryLength ? typedResults[key] ?? [] : []
        return PlaceChoiceListing.build(
            origin: coordinate,
            query: text,
            known: known,
            nearbyHits: nearbyHits,
            typedHits: typed
        )
    }

    /// The default guesses, or the matches for what is typed in the Name field.
    var chips: [NearbyPlaceCandidate] {
        guard !Self.queryKey(fieldQuery).isEmpty else { return defaultChips }
        return listing(for: fieldQuery).narrowedChips(query: fieldQuery, limit: Self.defaultChipCount)
    }

    func isSearching(_ text: String) -> Bool {
        searchStates[Self.queryKey(text)] == .searching
    }

    private static func locationKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }
}

/// Keeps MapKit requests from naming at least `interval` apart across the app, the same
/// one-per-second pace `PlaceGeocodeBackfill` keeps. Callers reserve a slot, then wait.
actor PlaceSearchPacer {
    static let shared = PlaceSearchPacer(interval: .seconds(1))

    private let interval: Duration
    private let clock = ContinuousClock()
    private var nextSlot: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    func waitForTurn() async throws {
        let now = clock.now
        let slot = max(nextSlot ?? now, now)
        nextSlot = slot.advanced(by: interval)
        if slot > now {
            try await clock.sleep(until: slot)
        }
        try Task.checkCancellation()
    }
}

/// Recent naming lookups, so reopening a stay or backspacing does not ask MapKit again.
@MainActor
final class PlaceSearchCache {
    static let shared = PlaceSearchCache()

    private struct Entry {
        var hits: [NearbySearchHit]
        var storedAt: Date
    }

    private let lifetime: TimeInterval
    private let capacity: Int
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 15 * 60, capacity: Int = 80) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    static func key(_ coordinate: CLLocationCoordinate2D, query: String, radius: CLLocationDistance) -> String {
        String(format: "%.4f,%.4f|%.0f|", coordinate.latitude, coordinate.longitude, radius) + query
    }

    func hits(for key: String, now: Date = .now) -> [NearbySearchHit]? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.hits
    }

    func store(_ hits: [NearbySearchHit], for key: String, now: Date = .now) {
        entries[key] = Entry(hits: hits, storedAt: now)
        guard entries.count > capacity else { return }
        if let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries[oldest] = nil
        }
    }
}
