import BackgroundTasks
import Contacts
import CoreLocation
import Foundation
import MapKit
import OSLog
import SwiftData
import UIKit

/// Reverse-geocoded country / city / street for a coordinate.
struct PlaceGeocodeRegion: Codable, Equatable, Sendable {
    var countryCode: String?
    var locality: String?
    var administrativeArea: String?
    /// POI or street name suitable for `VisitPlace.autoLabel`.
    var name: String?
    var thoroughfare: String?
    var formattedAddress: String?

    var hasAnyValue: Bool {
        countryCode?.isEmpty == false
            || locality?.isEmpty == false
            || administrativeArea?.isEmpty == false
            || name?.isEmpty == false
            || thoroughfare?.isEmpty == false
            || formattedAddress?.isEmpty == false
    }

    /// Prefers a POI, then a street, then a formatted address.
    var bestPlaceName: String? {
        PlaceDisplayNamer.meaningful(name)
            ?? PlaceDisplayNamer.meaningful(thoroughfare)
            ?? PlaceDisplayNamer.meaningful(formattedAddress)
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
        var region = PlaceGeocodeRegion()

        if let request = MKReverseGeocodingRequest(location: location) {
            let items = try await request.mapItems
            if let item = items.first {
                region = PlaceGeocodeRegion(mapItem: item)
            }
        }

        // Core Location only fills what MapKit left out. Asking both for every cell
        // doubled the requests and ran into Apple's rate limit within a minute.
        if region.countryCode == nil || region.locality == nil {
            do {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                if let mark = placemarks.first {
                    region.merge(placemark: mark)
                }
            } catch {
                // MapKit's answer stands on its own; with none, the error is the answer.
                guard region.hasAnyValue else { throw error }
            }
        }

        region = region.withoutCountryAsCity()
        return region.hasAnyValue ? region : nil
    }
}

extension PlaceGeocodeRegion {
    /// Reads ISO country from `MKAddressRepresentations.region` and city from `cityName`.
    init(mapItem: MKMapItem) {
        let representations = mapItem.addressRepresentations
        countryCode = PlaceGeocodeRegion.isoCountryCode(from: representations?.region)
        locality = PlaceGeocodeRegion.cleaned(representations?.cityName)
        if PlaceGeocodeRegion.isCountryName(locality, countryCode: countryCode) {
            // No city here; let the placemark's locality fill it, or leave it empty.
            locality = nil
        }
        let regionName = PlaceGeocodeRegion.cleaned(representations?.regionName)
        if let countryCode, let regionName,
           regionName.caseInsensitiveCompare(PlacesGeography.countryName(forCountryCode: countryCode)) == .orderedSame {
            administrativeArea = nil
        } else {
            administrativeArea = regionName
        }
        name = PlaceGeocodeRegion.cleaned(mapItem.name)
        formattedAddress = PlaceGeocodeRegion.cleaned(mapItem.address?.fullAddress)
            ?? PlaceGeocodeRegion.cleaned(mapItem.address?.shortAddress)
        if let short = PlaceGeocodeRegion.cleaned(mapItem.address?.shortAddress),
           name == nil || name?.caseInsensitiveCompare(short) == .orderedSame {
            thoroughfare = short
        }
        if let name, let formattedAddress, name.caseInsensitiveCompare(formattedAddress) == .orderedSame {
            self.name = nil
        }
    }

    mutating func merge(placemark mark: CLPlacemark) {
        if countryCode == nil {
            countryCode = Self.cleaned(mark.isoCountryCode)?.uppercased()
        }
        if locality == nil {
            locality = Self.cleaned(mark.locality)
        }
        if administrativeArea == nil {
            administrativeArea = Self.cleaned(mark.administrativeArea)
        }
        let street = [Self.cleaned(mark.subThoroughfare), Self.cleaned(mark.thoroughfare)]
            .compactMap { $0 }
            .joined(separator: " ")
        let streetOrNil = street.isEmpty ? nil : street
        if thoroughfare == nil {
            thoroughfare = streetOrNil
        }
        if formattedAddress == nil, let postal = mark.postalAddress {
            let formatted = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                .split(whereSeparator: \.isNewline)
                .joined(separator: ", ")
            formattedAddress = Self.cleaned(formatted)
        }
        if name == nil {
            let candidate = Self.cleaned(mark.name)
            if let candidate, candidate.caseInsensitiveCompare(streetOrNil ?? "") != .orderedSame {
                name = candidate
            }
        }
    }

    /// True when `value` is the country's own name ("Türkiye" for TR). A geocode with no
    /// city can hand that back as the city, and a country must never be listed as one.
    static func isCountryName(_ value: String?, countryCode: String?) -> Bool {
        guard let value = cleaned(value) else { return false }
        let key = PlaceDisplayNamer.folded(value)
        guard let code = cleaned(countryCode)?.uppercased() else { return false }
        if key == PlaceDisplayNamer.folded(code) { return true }
        let locales = [Locale.current, Locale(identifier: "en_US"), Locale(identifier: "en_GB")]
        return locales.contains { locale in
            locale.localizedString(forRegionCode: code).map(PlaceDisplayNamer.folded) == key
        }
    }

    /// The same region with a country-named city dropped. The Places list already falls
    /// back to the administrative area when a stay has no city.
    func withoutCountryAsCity() -> PlaceGeocodeRegion {
        var region = self
        if Self.isCountryName(region.locality, countryCode: region.countryCode) {
            region.locality = nil
        }
        return region
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

    /// ~100 m cell used for POI / street names (too coarse at 0.01°).
    static func nameCellKey(for coordinate: CLLocationCoordinate2D) -> String {
        let latitude = Int((coordinate.latitude * 1_000).rounded(.toNearestOrAwayFromZero))
        let longitude = Int((coordinate.longitude * 1_000).rounded(.toNearestOrAwayFromZero))
        return "n:\(latitude)|\(longitude)"
    }

    /// The latitudes and longitudes a key of either kind covers, a hair wider so a
    /// coordinate on the edge is never left out. Nil for a key in another form.
    static func bounds(forKey key: String) -> (latitude: ClosedRange<Double>, longitude: ClosedRange<Double>)? {
        let isNameCell = key.hasPrefix("n:")
        let scale = isNameCell ? 1_000.0 : 100.0
        let parts = (isNameCell ? key.dropFirst(2) : Substring(key)).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let latitude = Int(parts[0]), let longitude = Int(parts[1]) else { return nil }
        let half = 0.501 / scale
        return (
            (Double(latitude) / scale - half)...(Double(latitude) / scale + half),
            (Double(longitude) / scale - half)...(Double(longitude) / scale + half)
        )
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
/// One reverse-geocode per 0.01° cell, one cell every two seconds. Runs as a foreground
/// trickle and as a `BGProcessingTask`.
enum PlaceGeocodeBackfill {
    /// Must stay in sync with `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
    static let taskIdentifier = "\(MovesAppIdentity.bundleIdentifier).placeGeocodeBackfill"
    /// A name cell also asks MapKit for nearby points of interest, so two requests a cell
    /// at this pace stays under Apple's limit of about fifty a minute.
    static let requestInterval: Duration = .seconds(2)
    /// How long to wait when Apple's geocoder says the app has asked too often. Its limit
    /// counts requests over about a minute.
    static let busyWait: Duration = .seconds(60)
    /// Waits for one cell before the run gives up until the next one.
    static let maximumBusyWaits = 3

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
        geocoder: any PlaceReverseGeocoding = MapKitPlaceReverseGeocoder(),
        searcher: (any LocalPlaceSearching)? = MapKitLocalPlaceSearcher()
    ) async {
        // A tab that first appears while the app is off screen must not start what
        // leaving the screen stops.
        guard await MainActor.run(body: { UIApplication.shared.applicationState != .background }) else { return }
        await lock.run {
            _ = await fillMissingNames(in: container, geocoder: geocoder, searcher: searcher)
            guard !Task.isCancelled else { return }
            await run(in: container, geocoder: geocoder)
        }
    }

    /// Ends the trickle when the app leaves the screen. Capture keeps the app running in
    /// the background, and a name a second for hours there is battery spent unseen; the
    /// next return to the app, or the overnight task, carries on from the cache.
    static func stopForegroundTrickle() async {
        await lock.cancel()
    }

    /// Reverse-geocodes unlabeled suggested visits (~100 m cells) so the list can show streets / POIs.
    @discardableResult
    static func fillMissingNames(
        in container: ModelContainer,
        geocoder: any PlaceReverseGeocoding = MapKitPlaceReverseGeocoder(),
        searcher: (any LocalPlaceSearching)? = nil,
        cache: PlaceGeocodeCellCache? = nil,
        limit: Int = Int.max,
        busyWait: Duration = PlaceGeocodeBackfill.busyWait
    ) async -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var cache = cache ?? PlaceGeocodeCellCache.load()
        var completed = 0

        do {
            // Stays at a spot that already has a name take it before anything is geocoded.
            if try reuseNearbyLabels(in: context) > 0 {
                try context.save()
            }
            // Each cell is visited once per run. A cell the geocoder had nothing for stays
            // cached as empty and is not asked again, so the trickle cannot spin.
            var requested = 0
            for next in try pendingNameWork(in: context) {
                guard completed < limit, !Task.isCancelled else { break }
                var region: PlaceGeocodeRegion
                if let cached = cache.regions[next.cellKey] {
                    guard cached.hasAnyValue else { continue }
                    region = cached
                } else {
                    if requested > 0 {
                        try await Task.sleep(for: requestInterval)
                    }
                    requested += 1
                    guard var resolved = try await lookUp(next.coordinate, with: geocoder, busyWait: busyWait) else {
                        cache.store(PlaceGeocodeRegion(), for: next.cellKey)
                        completed += 1
                        continue
                    }
                    if let searcher {
                        resolved = await preferringNearbyPOI(resolved, at: next.coordinate, searcher: searcher)
                    }
                    cache.store(resolved, for: next.cellKey)
                    region = resolved
                }

                // A context of its own per cell: rows read before the geocoder's wait could be
                // gone by now, and one that outlived the wait would still hold them.
                let cellContext = ModelContext(container)
                cellContext.autosaveEnabled = false
                let applied = try applyName(region, cellKey: next.cellKey, in: cellContext)
                if applied > 0 {
                    try cellContext.save()
                }
                completed += 1
            }
        } catch is CancellationError {
            return completed
        } catch let error where trouble(error) != nil {
            log.notice("Place-name backfill stopped for now after \(completed) cells: \(error.localizedDescription, privacy: .public)")
        } catch {
            log.error("Place-name backfill failed: \(error.localizedDescription, privacy: .public)")
        }

        return completed
    }

    /// Reverse-geocodes missing cells until the store is complete or cancelled.
    @discardableResult
    static func run(
        in container: ModelContainer,
        geocoder: any PlaceReverseGeocoding = MapKitPlaceReverseGeocoder(),
        cache: PlaceGeocodeCellCache? = nil,
        limit: Int = Int.max,
        busyWait: Duration = PlaceGeocodeBackfill.busyWait
    ) async -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var cache = cache ?? PlaceGeocodeCellCache.load()
        var completed = 0

        do {
            // One pass over the cells: a cell whose answer has no city would otherwise be
            // picked again forever.
            var requested = 0
            for next in try pendingWork(in: context) {
                guard completed < limit, !Task.isCancelled else { break }
                let region: PlaceGeocodeRegion
                if let cached = cache.regions[next.cellKey] {
                    region = cached
                } else {
                    if requested > 0 {
                        try await Task.sleep(for: requestInterval)
                    }
                    requested += 1
                    guard let resolved = try await lookUp(next.coordinate, with: geocoder, busyWait: busyWait) else {
                        cache.store(PlaceGeocodeRegion(), for: next.cellKey)
                        completed += 1
                        continue
                    }
                    cache.store(resolved, for: next.cellKey)
                    region = resolved
                }

                // A context of its own per cell, as in `fillMissingNames`.
                let cellContext = ModelContext(container)
                cellContext.autosaveEnabled = false
                let applied = try apply(region, cellKey: next.cellKey, in: cellContext)
                if applied > 0 {
                    try cellContext.save()
                }
                completed += 1
            }
        } catch is CancellationError {
            return completed
        } catch let error where trouble(error) != nil {
            log.notice("Geocode backfill stopped for now after \(completed) cells: \(error.localizedDescription, privacy: .public)")
        } catch {
            log.error("Geocode backfill failed: \(error.localizedDescription, privacy: .public)")
        }

        return completed
    }

    /// Why a lookup failed in a way the next run can get past on its own.
    enum GeocodeTrouble: Equatable {
        /// Apple's rate limit, or a server that did not answer in time.
        case busy
        /// No network at all.
        case offline
    }

    static func trouble(_ error: any Error) -> GeocodeTrouble? {
        let error = error as NSError
        switch error.domain {
        case MKErrorDomain:
            let code = UInt(clamping: error.code)
            return code == MKError.Code.loadingThrottled.rawValue || code == MKError.Code.serverFailure.rawValue
                ? .busy : nil
        case kCLErrorDomain:
            // Core Location's geocoder reports its rate limit as a network error.
            return error.code == CLError.Code.network.rawValue ? .busy : nil
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost:
                return .busy
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return .offline
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Asks the geocoder about one cell, waiting out Apple's rate limit. A geocoder that
    /// is still busy after a few waits, or a phone that is offline, ends the run, and the
    /// next one carries on from the cache.
    private static func lookUp(
        _ coordinate: CLLocationCoordinate2D,
        with geocoder: any PlaceReverseGeocoding,
        busyWait: Duration
    ) async throws -> PlaceGeocodeRegion? {
        var waits = 0
        while true {
            do {
                return try await geocoder.reverseGeocode(coordinate)
            } catch {
                guard trouble(error) == .busy, waits < maximumBusyWaits, !Task.isCancelled else { throw error }
                waits += 1
                log.notice("Geocoder busy, waiting \(busyWait.components.seconds) s: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(for: busyWait)
            }
        }
    }

    /// Visits and learned places still missing country or city, grouped by cache cell.
    static func pendingWork(in context: ModelContext) throws -> [PlaceGeocodeWorkItem] {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>.live())
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

    /// Unassigned visits still missing a POI or street name, and any visit or learned place
    /// still missing its street address, grouped by ~100 m cells.
    static func pendingNameWork(in context: ModelContext) throws -> [PlaceGeocodeWorkItem] {
        let visits = try context.fetch(FetchDescriptor<VisitPlace>.live())
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        var items: [String: PlaceGeocodeWorkItem] = [:]
        func enqueue(_ coordinate: CLLocationCoordinate2D) {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            let key = PlaceGeocodeCellCache.nameCellKey(for: coordinate)
            if items[key] == nil {
                items[key] = PlaceGeocodeWorkItem(cellKey: key, coordinate: coordinate)
            }
        }
        for visit in visits {
            let needsName = visit.knownPlace == nil && visit.needsPlaceNameGeocode
            guard needsName || visit.formattedAddress == nil else { continue }
            enqueue(visit.coordinate)
        }
        for place in places where place.formattedAddress == nil {
            enqueue(place.coordinate)
        }
        return items.values.sorted { $0.cellKey < $1.cellKey }
    }

    /// Writes street / POI fields onto visits in a ~100 m cell, and the street address
    /// onto learned places centred there. A cell this small is one block, so its address
    /// is the stay's own.
    @discardableResult
    static func applyName(
        _ region: PlaceGeocodeRegion,
        cellKey: String,
        in context: ModelContext
    ) throws -> Int {
        guard region.hasAnyValue else { return 0 }
        var changed = 0
        let visits = try stays(inCell: cellKey, in: context)
        for visit in visits {
            let key = PlaceGeocodeCellCache.nameCellKey(for: visit.coordinate)
            guard key == cellKey else { continue }
            if fill(visitCountry: visit, with: region, includeAddress: true, includePlaceName: true) { changed += 1 }
        }
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        for place in places where PlaceGeocodeCellCache.nameCellKey(for: place.coordinate) == cellKey {
            if fill(place: place, with: region, includeAddress: true) { changed += 1 }
        }
        return changed
    }

    /// The stays whose coordinate can fall in a cell, read by latitude and longitude.
    ///
    /// The backfill fills one cell a second for as long as cells are missing. Reading
    /// every stay for each cell kept a phone with years of history busy for hours.
    private static func stays(inCell cellKey: String, in context: ModelContext) throws -> [VisitPlace] {
        guard let bounds = PlaceGeocodeCellCache.bounds(forKey: cellKey) else {
            return try context.fetch(FetchDescriptor<VisitPlace>.live())
        }
        let minLatitude = bounds.latitude.lowerBound, maxLatitude = bounds.latitude.upperBound
        let minLongitude = bounds.longitude.lowerBound, maxLongitude = bounds.longitude.upperBound
        // Stays off the timeline are left out in code, as `PlacesIndex` does for its own box.
        let inBox = try context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate {
            $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                && $0.longitude >= minLongitude && $0.longitude <= maxLongitude
        }))
        return inBox.filter { $0.dayTimeline != nil }
    }

    /// Gives unnamed, unassigned stays the label earlier stays at the same spot carry,
    /// so they need no geocode of their own.
    @discardableResult
    static func reuseNearbyLabels(in context: ModelContext) throws -> Int {
        let unassigned = try context.fetch(FetchDescriptor<VisitPlace>.live()).filter { visit in
            visit.knownPlace == nil && visit.assignmentSource == .none
        }
        let needing = unassigned.filter(\.needsPlaceNameGeocode)
        guard !needing.isEmpty else { return 0 }
        let labeled = unassigned.compactMap { visit -> PlaceLearningEngine.StaySnapshot? in
            guard PlaceDisplayNamer.meaningful(visit.userLabel) == nil,
                  let label = PlaceDisplayNamer.meaningful(visit.autoLabel)
            else { return nil }
            return PlaceLearningEngine.StaySnapshot(visit, label: label)
        }
        guard !labeled.isEmpty else { return 0 }
        // Only a stay at the same spot can lend its name, so each unnamed stay is held
        // against its neighbors. Against all of history this was 25 million comparisons
        // on a phone with a photo library's worth of stays, on every return to the app.
        let buckets = CoordinateBuckets(
            labeled.map(\.coordinate),
            reach: PlaceLearningEngine.sameSpotMaximumDistance
        )
        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        var changed = 0
        for visit in needing {
            let neighbors = buckets.indices(near: visit.coordinate).map { labeled[$0] }
            guard !neighbors.isEmpty else { continue }
            let nearbyPlaces = places.filter {
                PlaceLearningEngine.distance(from: $0.coordinate, to: visit.coordinate)
                    <= PlaceLearningEngine.rejectedLabelSearchRadius
            }
            guard let label = PlaceLearningEngine.reusableLabel(
                for: PlaceLearningEngine.StaySnapshot(visit, label: nil),
                among: neighbors,
                isSuppressed: { PlaceLearningEngine.shouldSuppress($0, nearbyPlaces: nearbyPlaces) }
            ) else { continue }
            visit.autoLabel = label
            changed += 1
        }
        return changed
    }

    /// Writes cached region fields onto every visit / known place in the cell that still needs them.
    ///
    /// The cell is a kilometre across, so only country, city, and area hold for all of
    /// it. Streets and addresses come from `applyName`'s ~100 m cells.
    @discardableResult
    static func apply(
        _ region: PlaceGeocodeRegion,
        cellKey: String,
        in context: ModelContext
    ) throws -> Int {
        guard region.hasAnyValue else { return 0 }
        var changed = 0

        let visits = try stays(inCell: cellKey, in: context)
        // Places with a stay in this cell, from the stays just read: walking every
        // place's own stays loaded all of them again for each cell.
        var placesWithStayHere = Set<UUID>()
        for visit in visits {
            let key = PlaceGeocodeCellCache.cellKey(for: visit.coordinate)
            guard key == cellKey else { continue }
            if let place = visit.knownPlace { placesWithStayHere.insert(place.id) }
            if fill(visitCountry: visit, with: region) { changed += 1 }
        }

        let places = try context.fetch(FetchDescriptor<KnownPlace>())
        for place in places {
            let key = PlaceGeocodeCellCache.cellKey(for: place.coordinate)
            let visitsShareCell = placesWithStayHere.contains(place.id)
            guard key == cellKey || visitsShareCell else { continue }
            if fill(place: place, with: region) { changed += 1 }
        }

        return changed
    }

    private static func fill(
        visitCountry visit: VisitPlace,
        with region: PlaceGeocodeRegion,
        includeAddress: Bool = false,
        includePlaceName: Bool = false
    ) -> Bool {
        // Regions cached before this rule may still name the country as the city.
        let region = region.withoutCountryAsCity()
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
        if includeAddress, visit.thoroughfare == nil, let thoroughfare = region.thoroughfare {
            visit.thoroughfare = thoroughfare
            changed = true
        }
        if includeAddress, visit.formattedAddress == nil, let formattedAddress = region.formattedAddress {
            visit.formattedAddress = formattedAddress
            changed = true
        }
        if includePlaceName,
           visit.knownPlace == nil,
           PlaceDisplayNamer.meaningful(visit.userLabel) == nil,
           PlaceDisplayNamer.meaningful(visit.autoLabel) == nil,
           let name = region.bestPlaceName {
            visit.autoLabel = PlaceDisplayNamer.normalizedAutomaticLabel(name)
            changed = true
        }
        return changed
    }

    private static func fill(place: KnownPlace, with region: PlaceGeocodeRegion, includeAddress: Bool = false) -> Bool {
        let region = region.withoutCountryAsCity()
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
        if includeAddress, place.thoroughfare == nil, let thoroughfare = region.thoroughfare {
            place.thoroughfare = thoroughfare
            changed = true
        }
        if includeAddress, place.formattedAddress == nil, let formattedAddress = region.formattedAddress {
            place.formattedAddress = formattedAddress
            changed = true
        }
        return changed
    }

    /// Prefers a POI within 40 m over a street-only reverse geocode.
    private static func preferringNearbyPOI(
        _ region: PlaceGeocodeRegion,
        at coordinate: CLLocationCoordinate2D,
        searcher: any LocalPlaceSearching
    ) async -> PlaceGeocodeRegion {
        let hits: [NearbySearchHit]
        do {
            hits = try await searcher.search(near: coordinate, query: nil)
        } catch {
            return region
        }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let nearest = hits.min(by: { lhs, rhs in
            origin.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude))
                < origin.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
        }) else {
            return region
        }
        let distance = origin.distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))
        guard distance <= 40 else { return region }
        var updated = region
        updated.name = nearest.name
        if updated.formattedAddress == nil {
            updated.formattedAddress = nearest.subtitle
        }
        return updated
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNextRun()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.sharedContainer() }
                await TimelineSchemaUpgrader.waitUntilFinished()
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
    private var running: Task<Void, Never>?

    /// Runs `work` unless a run is under way; a caller that overlaps returns at once.
    func run(_ work: @escaping @Sendable () async -> Void) async {
        // A run that was told to stop is on its way out; coming straight back to the
        // app waits for it instead of finding the trickle taken.
        if let stopping = running, stopping.isCancelled {
            await stopping.value
            if running == stopping { running = nil }
        }
        guard running == nil else { return }
        let task = Task(priority: .utility) { await work() }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// Ends the run under way at its next cell.
    func cancel() {
        running?.cancel()
    }
}
