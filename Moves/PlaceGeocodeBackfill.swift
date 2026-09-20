import BackgroundTasks
import CoreLocation
import Foundation
import MapKit
import OSLog
import SwiftData

/// Reverse-geocoded country / city for a ~1 km cell.
struct PlaceGeocodeRegion: Codable, Equatable, Sendable {
    var countryCode: String?
    var locality: String?
    var administrativeArea: String?

    var hasAnyValue: Bool {
        countryCode?.isEmpty == false || locality?.isEmpty == false || administrativeArea?.isEmpty == false
    }
}

/// Looks up `countryCode` / `locality` / `administrativeArea` for a coordinate.
protocol PlaceReverseGeocoding: Sendable {
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> PlaceGeocodeRegion?
}

/// MapKit reverse geocoder with a Core Location fallback for structured ISO fields.
struct MapKitPlaceReverseGeocoder: PlaceReverseGeocoding {
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> PlaceGeocodeRegion? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let request = MKReverseGeocodingRequest(location: location) {
            let items = try await request.mapItems
            if let item = items.first {
                let region = PlaceGeocodeRegion(mapItem: item)
                if region.hasAnyValue {
                    return region
                }
            }
        }

        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let mark = placemarks.first else { return nil }
        return PlaceGeocodeRegion(
            countryCode: Self.normalizedCountry(mark.isoCountryCode),
            locality: Self.normalized(mark.locality),
            administrativeArea: Self.normalized(mark.administrativeArea)
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedCountry(_ value: String?) -> String? {
        normalized(value)?.uppercased()
    }
}

extension PlaceGeocodeRegion {
    /// Reads ISO country from `MKAddressRepresentations.region` and city from `cityName`.
    init(mapItem: MKMapItem) {
        let representations = mapItem.addressRepresentations
        countryCode = PlaceGeocodeRegion.isoCountryCode(from: representations?.region)
        locality = PlaceGeocodeRegion.cleaned(representations?.cityName)
        let regionName = PlaceGeocodeRegion.cleaned(representations?.regionName)
        if let countryCode, let regionName,
           regionName.caseInsensitiveCompare(PlacesGeography.countryName(forCountryCode: countryCode)) == .orderedSame {
            administrativeArea = nil
        } else {
            administrativeArea = regionName
        }
    }

    static func isoCountryCode(from region: Locale.Region?) -> String? {
        guard let region else { return nil }
        let identifier = region.identifier.uppercased()
        let code = identifier.split(separator: "-").first.map(String.init) ?? identifier
        guard code.count == 2, code.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            return nil
        }
        return code
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Disk-backed cache keyed by 0.01° cells (~1 km).
struct PlaceGeocodeCellCache: Sendable {
    var regions: [String: PlaceGeocodeRegion]
    let url: URL

    static func cellKey(for coordinate: CLLocationCoordinate2D) -> String {
        let latitude = Int((coordinate.latitude * 100).rounded(.toNearestOrAwayFromZero))
        let longitude = Int((coordinate.longitude * 100).rounded(.toNearestOrAwayFromZero))
        return "\(latitude)|\(longitude)"
    }

    static func load(from url: URL = defaultURL()) -> PlaceGeocodeCellCache {
        guard let data = try? Data(contentsOf: url),
              let regions = try? JSONDecoder().decode([String: PlaceGeocodeRegion].self, from: data)
        else {
            return PlaceGeocodeCellCache(regions: [:], url: url)
        }
        return PlaceGeocodeCellCache(regions: regions, url: url)
    }

    mutating func store(_ region: PlaceGeocodeRegion, for key: String) {
        regions[key] = region
        persist()
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(regions)
            try data.write(to: url, options: .atomic)
        } catch {
            PlaceGeocodeBackfill.log.error("Could not save geocode cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func defaultURL() -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("Moves", isDirectory: true)
            .appendingPathComponent("PlaceGeocodeCache.json")
    }
}

/// Fills `countryCode` / `locality` / `administrativeArea` on visits and learned places.
///
/// One reverse-geocode per 0.01° cell, rate-limited to 1 request per second. Runs as a
/// foreground trickle and as a `BGProcessingTask`.
enum PlaceGeocodeBackfill {
    /// Must stay in sync with `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
    static let taskIdentifier = "\(MovesAppIdentity.bundleIdentifier).placeGeocodeBackfill"
    static let requestInterval: Duration = .seconds(1)

    static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "PlaceGeocodeBackfill")

    private static let lock = PlaceGeocodeBackfillLock()

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func scheduleNextRun(now: Date = .now) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Starts a single in-process trickle; overlapping callers share the same run.
    static func runForegroundTrickle(
        in container: ModelContainer,
        geocoder: any PlaceReverseGeocoding = MapKitPlaceReverseGeocoder()
    ) async {
        await lock.run {
            await run(in: container, geocoder: geocoder)
        }
    }

    /// Reverse-geocodes missing cells until the store is complete or cancelled.
    @discardableResult
    static func run(
        in container: ModelContainer,
        geocoder: any PlaceReverseGeocoding = MapKitPlaceReverseGeocoder(),
        cache: PlaceGeocodeCellCache? = nil,
        limit: Int = Int.max
    ) async -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var cache = cache ?? PlaceGeocodeCellCache.load()
        var completed = 0

        do {
            while completed < limit, !Task.isCancelled {
                let work = try pendingWork(in: context)
                guard let next = work.first(where: { cache.regions[$0.cellKey] == nil }) ?? work.first else {
                    break
                }

                let region: PlaceGeocodeRegion
                if let cached = cache.regions[next.cellKey] {
                    region = cached
                } else {
                    if completed > 0 {
                        try await Task.sleep(for: requestInterval)
                    }
                    guard let resolved = try await geocoder.reverseGeocode(next.coordinate) else {
                        cache.store(PlaceGeocodeRegion(), for: next.cellKey)
                        completed += 1
                        continue
                    }
                    cache.store(resolved, for: next.cellKey)
                    region = resolved
                }

                let applied = try apply(region, cellKey: next.cellKey, in: context)
                if applied > 0 {
                    try context.save()
                }
                completed += 1
            }
        } catch is CancellationError {
            return completed
        } catch {
            log.error("Geocode backfill failed: \(error.localizedDescription, privacy: .public)")
        }

        return completed
    }

    /// Visits and learned places still missing country or city, grouped by cache cell.
    static func pendingWork(in context: ModelContext) throws -> [PlaceGeocodeWorkItem] {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        var items: [String: PlaceGeocodeWorkItem] = [:]

        func enqueue(coordinate: CLLocationCoordinate2D, needsFill: Bool) {
            guard needsFill, CLLocationCoordinate2DIsValid(coordinate) else { return }
            let key = PlaceGeocodeCellCache.cellKey(for: coordinate)
            if items[key] == nil {
                items[key] = PlaceGeocodeWorkItem(cellKey: key, coordinate: coordinate)
            }
        }

        for visit in visits {
            enqueue(
                coordinate: visit.coordinate,
                needsFill: visit.countryCode == nil || visit.locality == nil
            )
        }
        for place in places {
            enqueue(
                coordinate: place.coordinate,
                needsFill: place.countryCode == nil || place.locality == nil
            )
        }

        return items.values.sorted { $0.cellKey < $1.cellKey }
    }

    /// Writes cached region fields onto every visit / known place in the cell that still needs them.
    @discardableResult
    static func apply(
        _ region: PlaceGeocodeRegion,
        cellKey: String,
        in context: ModelContext
    ) throws -> Int {
        guard region.hasAnyValue else { return 0 }
        var changed = 0

        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        for visit in visits {
            let key = PlaceGeocodeCellCache.cellKey(for: visit.coordinate)
            guard key == cellKey else { continue }
            if fill(visitCountry: visit, with: region) { changed += 1 }
        }

        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        for place in places {
            let key = PlaceGeocodeCellCache.cellKey(for: place.coordinate)
            let visitsShareCell = place.visits.contains {
                PlaceGeocodeCellCache.cellKey(for: $0.coordinate) == cellKey
            }
            guard key == cellKey || visitsShareCell else { continue }
            if fill(place: place, with: region) { changed += 1 }
        }

        return changed
    }

    private static func fill(visitCountry visit: VisitPlace, with region: PlaceGeocodeRegion) -> Bool {
        var changed = false
        if visit.countryCode == nil, let countryCode = region.countryCode {
            visit.countryCode = countryCode
            changed = true
        }
        if visit.locality == nil, let locality = region.locality {
            visit.locality = locality
            changed = true
        }
        if visit.administrativeArea == nil, let administrativeArea = region.administrativeArea {
            visit.administrativeArea = administrativeArea
            changed = true
        }
        return changed
    }

    private static func fill(place: KnownPlace, with region: PlaceGeocodeRegion) -> Bool {
        var changed = false
        if place.countryCode == nil, let countryCode = region.countryCode {
            place.countryCode = countryCode
            changed = true
        }
        if place.locality == nil, let locality = region.locality {
            place.locality = locality
            changed = true
        }
        if place.administrativeArea == nil, let administrativeArea = region.administrativeArea {
            place.administrativeArea = administrativeArea
            changed = true
        }
        return changed
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNextRun()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                _ = await run(in: container)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}

struct PlaceGeocodeWorkItem: Sendable {
    var cellKey: String
    var coordinate: CLLocationCoordinate2D
}

/// Ensures only one foreground trickle runs at a time.
private actor PlaceGeocodeBackfillLock {
    private var isRunning = false

    func run(_ work: @Sendable () async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await work()
    }
}
