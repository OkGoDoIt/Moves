import CoreLocation
import Foundation

// MARK: - Points

/// One timestamped fix from a continuous location log (GPX `trkpt`, TCX
/// `Trackpoint`, KML coordinate, …). Plain value type so parsing and
/// segmentation can run off the main actor.
struct LocationLogPoint: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    /// Metres above sea level when the file carried one.
    let altitude: Double?
    /// Horizontal accuracy in metres when the file carried one.
    let horizontalAccuracy: Double?
    let timestamp: Date

    init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    init(location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        self.horizontalAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        self.timestamp = location.timestamp
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// `CLLocation` for `LocationSample` storage. Imported fixes have no
    /// accuracy metadata, so a conservative 15 m is assumed.
    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude ?? 0,
            horizontalAccuracy: horizontalAccuracy ?? 15,
            verticalAccuracy: altitude == nil ? -1 : 5,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
    }

    func distance(to other: LocationLogPoint) -> CLLocationDistance {
        LocationLogGeometry.distance(from: coordinate, to: other.coordinate)
    }
}

// MARK: - Segments

/// A period where the log stayed inside a small radius.
struct LocationLogStay: Sendable {
    let arrivalDate: Date
    let departureDate: Date
    /// Centroid of the clustered fixes.
    let latitude: Double
    let longitude: Double
    /// Largest distance of a clustered fix from the centroid, in metres.
    let radius: CLLocationDistance
    /// Fixes recorded while the device stayed here.
    let points: [LocationLogPoint]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var duration: TimeInterval {
        departureDate.timeIntervalSince(arrivalDate)
    }
}

/// Travel between two stays (or between the log's edges and a stay).
struct LocationLogMove: Sendable {
    /// Fixes in time order. The first and last fixes are shared with the
    /// neighbouring stays so the route connects visually.
    let points: [LocationLogPoint]
    let transportMode: TransportMode
    /// Sum of leg lengths, in metres.
    let distanceMeters: CLLocationDistance
    /// Longest interval between consecutive fixes. Large gaps mean the
    /// logger was off (for example during a flight).
    let longestGap: TimeInterval

    var startDate: Date { points.first?.timestamp ?? .distantPast }
    var endDate: Date { points.last?.timestamp ?? .distantPast }
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    var straightLineDistance: CLLocationDistance {
        guard let first = points.first, let last = points.last else { return 0 }
        return first.distance(to: last)
    }
}

enum LocationLogSegment: Sendable {
    case stay(LocationLogStay)
    case move(LocationLogMove)
}

/// Ordered stays and moves reconstructed from a raw fix stream.
struct LocationLogTimeline: Sendable {
    let segments: [LocationLogSegment]
    /// Distinct fixes that survived cleaning.
    let pointCount: Int

    var stays: [LocationLogStay] {
        segments.compactMap {
            if case .stay(let stay) = $0 { return stay }
            return nil
        }
    }

    var moves: [LocationLogMove] {
        segments.compactMap {
            if case .move(let move) = $0 { return move }
            return nil
        }
    }

    var isEmpty: Bool { segments.isEmpty }
}

// MARK: - Import results

/// Counts produced by `SwiftDataTimelineRepository.importLocationLog`.
struct LocationLogImportReport: Sendable {
    /// Visits created.
    var placeCount = 0
    /// Stays folded into visits that already existed at the same spot and time.
    var mergedPlaceCount = 0
    /// Moves created.
    var moveCount = 0
    /// Moves that enriched an existing trip instead of adding a new one.
    var mergedMoveCount = 0
    /// GPS fixes stored as new `LocationSample` rows.
    var sampleCount = 0
    /// Places created by this import that still need a name.
    var newPlaces: [LocationLogPlaceNamer.Candidate] = []
    /// Places that received an automatic name after the import.
    var namedPlaceCount = 0

    var summary: String {
        var parts: [String] = []
        parts.append("\(placeCount) place\(placeCount == 1 ? "" : "s")")
        parts.append("\(moveCount) move\(moveCount == 1 ? "" : "s")")
        parts.append("\(sampleCount) GPS point\(sampleCount == 1 ? "" : "s")")
        var text = "Imported " + parts.joined(separator: ", ") + "."
        if mergedPlaceCount + mergedMoveCount > 0 {
            text += " Matched \(mergedPlaceCount) existing place\(mergedPlaceCount == 1 ? "" : "s") and \(mergedMoveCount) existing move\(mergedMoveCount == 1 ? "" : "s")."
        }
        if namedPlaceCount > 0 {
            text += " Named \(namedPlaceCount) place\(namedPlaceCount == 1 ? "" : "s") from the map."
        }
        return text
    }
}

enum LocationLogImportError: LocalizedError {
    case noTimelineData
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .noTimelineData:
            return "The selected files did not contain any timestamped GPS points."
        case .unsupportedFormat(let name):
            return "Unsupported route format in \(name)."
        }
    }
}

// MARK: - Segmenter

/// Turns a continuous stream of GPS fixes into stays and moves.
///
/// Third-party loggers such as Location Log record a fix every couple of
/// minutes while moving and only occasionally while still, so a single
/// `<trkseg>` can cover a whole year. Importing that as one route is useless;
/// the timeline needs the same visits-and-trips structure the app builds live
/// from `CLVisit`.
///
/// The algorithm is a greedy radius clustering:
///
/// 1. From the current fix, grow a cluster while each fix stays within
///    `stayRadius` of the running centroid. One stray fix is tolerated when
///    the next fix comes back inside the radius within `jitterReturnInterval`.
/// 2. A cluster that spans at least `minimumStayDuration` becomes a stay; the
///    fixes since the previous stay become a move. Gaps in recording count
///    toward the stay when the fix after the gap lands at the same spot.
/// 3. Neighbouring stays split only by a tiny wobble are merged, and moves
///    shorter than `minimumMoveDistance` are dropped.
struct LocationLogSegmenter: Sendable {
    struct Configuration: Sendable {
        /// Cluster radius around the centroid, in metres.
        var stayRadius: CLLocationDistance = 110
        /// Minimum time inside the radius to count as a stay.
        var minimumStayDuration: TimeInterval = 10 * 60
        /// One outlier fix is ignored when the fix after it returns inside the
        /// radius within this interval.
        var jitterReturnInterval: TimeInterval = 5 * 60
        /// Moves shorter than this are noise and are folded into the stays.
        var minimumMoveDistance: CLLocationDistance = 120
        /// Two stays whose centres are closer than this, joined by a move
        /// shorter than `minimumMoveDistance`, are merged into one stay.
        var stayMergeDistance: CLLocationDistance = 160
        /// Fixes reporting worse horizontal accuracy are dropped.
        var maximumHorizontalAccuracy: CLLocationDistance = 200

        init() {}
    }

    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func segment(_ input: [LocationLogPoint]) -> LocationLogTimeline {
        let points = Self.cleaned(input, configuration: configuration)
        guard points.count >= 2 else {
            return LocationLogTimeline(segments: [], pointCount: points.count)
        }

        var raw: [RawSegment] = []
        var moveStart = 0
        var index = 0

        while index < points.count {
            if let cluster = stayCluster(in: points, startingAt: index) {
                if index > moveStart {
                    // The move ends on the first fix of the stay so the route joins up.
                    raw.append(.move(moveStart...index))
                }
                raw.append(.stay(cluster))
                moveStart = cluster.range.upperBound
                index = cluster.range.upperBound + 1
            } else {
                index += 1
            }
        }

        if moveStart < points.count - 1 {
            raw.append(.move(moveStart...(points.count - 1)))
        }

        let merged = mergeWobbles(raw, points: points)
        let segments = merged.enumerated().compactMap { index, segment -> LocationLogSegment? in
            switch segment {
            case .stay(let cluster):
                return .stay(Self.makeStay(from: cluster, points: points))
            case .move(let range):
                let movePoints = Array(points[range])
                let distance = LocationLogGeometry.pathDistance(movePoints)
                guard movePoints.count >= 2 else { return nil }
                // A move between two stays is kept however short it is so the
                // timeline stays connected; only dangling edge moves are noise.
                let isEdge = index == 0 || index == merged.count - 1
                guard !isEdge || distance >= configuration.minimumMoveDistance else {
                    return nil
                }
                return .move(
                    LocationLogMove(
                        points: movePoints,
                        transportMode: LocationLogTransportClassifier.classify(movePoints),
                        distanceMeters: distance,
                        longestGap: LocationLogGeometry.longestGap(movePoints)
                    )
                )
            }
        }

        return LocationLogTimeline(segments: segments, pointCount: points.count)
    }

    // MARK: Internals

    private struct StayCluster {
        var range: ClosedRange<Int>
        var latitude: Double
        var longitude: Double
        var radius: CLLocationDistance
    }

    private enum RawSegment {
        case stay(StayCluster)
        case move(ClosedRange<Int>)
    }

    /// Sorts by time, drops invalid or inaccurate fixes, and collapses
    /// duplicate timestamps.
    private static func cleaned(_ input: [LocationLogPoint], configuration: Configuration) -> [LocationLogPoint] {
        var points = input.filter { point in
            CLLocationCoordinate2DIsValid(point.coordinate)
                && !(point.latitude == 0 && point.longitude == 0)
                && (point.horizontalAccuracy ?? 0) <= configuration.maximumHorizontalAccuracy
        }
        points.sort { $0.timestamp < $1.timestamp }

        var deduped: [LocationLogPoint] = []
        deduped.reserveCapacity(points.count)
        for point in points {
            if let last = deduped.last, point.timestamp.timeIntervalSince(last.timestamp) < 1 {
                continue
            }
            deduped.append(point)
        }
        return deduped
    }

    /// Grows a stay cluster from `start`. Returns nil when the fixes leave the
    /// radius before `minimumStayDuration` has elapsed.
    private func stayCluster(in points: [LocationLogPoint], startingAt start: Int) -> StayCluster? {
        var sumLatitude = 0.0
        var sumLongitude = 0.0
        var count = 0
        var centre = points[start].coordinate
        var radius: CLLocationDistance = 0
        var end = start - 1
        var index = start

        while index < points.count {
            let point = points[index]
            let distance = LocationLogGeometry.distance(from: centre, to: point.coordinate)

            if distance > configuration.stayRadius {
                // Tolerate one stray fix if the next one comes straight back.
                let nextIndex = index + 1
                if count > 0,
                   nextIndex < points.count,
                   points[nextIndex].timestamp.timeIntervalSince(point.timestamp) <= configuration.jitterReturnInterval,
                   LocationLogGeometry.distance(from: centre, to: points[nextIndex].coordinate) <= configuration.stayRadius {
                    index += 1
                    continue
                }
                break
            }

            sumLatitude += point.latitude
            sumLongitude += point.longitude
            count += 1
            centre = CLLocationCoordinate2D(
                latitude: sumLatitude / Double(count),
                longitude: sumLongitude / Double(count)
            )
            radius = max(radius, distance)
            end = index
            index += 1
        }

        guard end > start else { return nil }
        let duration = points[end].timestamp.timeIntervalSince(points[start].timestamp)
        guard duration >= configuration.minimumStayDuration else { return nil }

        return StayCluster(
            range: start...end,
            latitude: centre.latitude,
            longitude: centre.longitude,
            radius: radius
        )
    }

    /// Collapses `stay – tiny move – stay` runs at the same place into one stay.
    private func mergeWobbles(_ input: [RawSegment], points: [LocationLogPoint]) -> [RawSegment] {
        var result: [RawSegment] = []
        result.reserveCapacity(input.count)

        for segment in input {
            guard case .stay(let incoming) = segment,
                  result.count >= 2,
                  case .move(let bridge) = result[result.count - 1],
                  case .stay(let previous) = result[result.count - 2]
            else {
                result.append(segment)
                continue
            }

            let bridgeDistance = LocationLogGeometry.pathDistance(Array(points[bridge]))
            let centreDistance = LocationLogGeometry.distance(
                from: CLLocationCoordinate2D(latitude: previous.latitude, longitude: previous.longitude),
                to: CLLocationCoordinate2D(latitude: incoming.latitude, longitude: incoming.longitude)
            )

            guard bridgeDistance < configuration.minimumMoveDistance,
                  centreDistance <= configuration.stayMergeDistance else {
                result.append(segment)
                continue
            }

            result.removeLast(2)
            result.append(.stay(Self.merged(previous, incoming, points: points)))
        }

        return result
    }

    private static func merged(_ lhs: StayCluster, _ rhs: StayCluster, points: [LocationLogPoint]) -> StayCluster {
        let range = lhs.range.lowerBound...rhs.range.upperBound
        let slice = points[range]
        let count = Double(slice.count)
        let latitude = slice.reduce(0.0) { $0 + $1.latitude } / count
        let longitude = slice.reduce(0.0) { $0 + $1.longitude } / count
        let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let radius = slice.reduce(0.0) { max($0, LocationLogGeometry.distance(from: centre, to: $1.coordinate)) }
        return StayCluster(range: range, latitude: latitude, longitude: longitude, radius: radius)
    }

    private static func makeStay(from cluster: StayCluster, points: [LocationLogPoint]) -> LocationLogStay {
        let slice = Array(points[cluster.range])
        return LocationLogStay(
            arrivalDate: slice.first?.timestamp ?? .distantPast,
            departureDate: slice.last?.timestamp ?? .distantPast,
            latitude: cluster.latitude,
            longitude: cluster.longitude,
            radius: cluster.radius,
            points: slice
        )
    }
}

// MARK: - Transport classification

/// Infers a transport mode from sparse GPS fixes alone.
///
/// Speeds are computed per leg and summarised by *distance-weighted*
/// percentiles, so the leg that covers most of the trip decides the mode and
/// a walk to the car does not drag a drive down to "cycling". Long legs at
/// aircraft speed (including recording gaps across a flight) win outright.
enum LocationLogTransportClassifier {
    /// Metres per second.
    private enum Speed {
        static let plane: Double = 55            // ~200 km/h sustained
        static let train: Double = 45            // ~160 km/h sustained
        static let automotive: Double = 8        // ~29 km/h median
        static let automotivePeak: Double = 14   // ~50 km/h peak rules out cycling
        static let trafficMedian: Double = 5     // ~18 km/h median plus…
        static let trafficPeak: Double = 8.3     // …~30 km/h peaks is a car in traffic
        static let cycling: Double = 3.3         // ~12 km/h
        static let running: Double = 2.3         // ~8 km/h
        static let stopAndGoPeak: Double = 6     // ~22 km/h peaks: a bus, not a runner
        static let slowVehiclePeak: Double = 4   // ~14 km/h peaks at jogging median: a bike
        static let walking: Double = 0.35
    }

    private static let planeMinimumDistance: CLLocationDistance = 150_000
    private static let trainMinimumDistance: CLLocationDistance = 40_000
    private static let runningMinimumDistance: CLLocationDistance = 800
    /// Creeping between two nearby stays is still a walk; anything longer at
    /// that pace is a recording gap we cannot explain.
    private static let creepingWalkMaximumDistance: CLLocationDistance = 1_500

    static func classify(_ points: [LocationLogPoint]) -> TransportMode {
        let legs = Self.legs(for: points)
        let total = legs.reduce(0.0) { $0 + $1.distance }
        guard total > 0, let first = points.first, let last = points.last else { return .unknown }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let average = duration > 0 ? total / duration : 0
        let direct = first.distance(to: last)
        let median = weightedSpeed(legs, fraction: 0.5, total: total)
        let peak = weightedSpeed(legs, fraction: 0.9, total: total)
        let longestLeg = legs.max(by: { $0.distance < $1.distance })

        if (direct >= planeMinimumDistance && average >= 40)
            || median >= Speed.plane
            || (longestLeg.map { $0.distance >= planeMinimumDistance && $0.speed >= 40 } ?? false) {
            return .plane
        }
        if median >= Speed.train && direct >= trainMinimumDistance {
            return .train
        }
        if median >= Speed.automotive
            || peak >= Speed.automotivePeak
            || (median >= Speed.trafficMedian && peak >= Speed.trafficPeak) {
            return .automotive
        }
        if median >= Speed.cycling {
            return .cycling
        }
        if median >= Speed.running {
            // Jogging pace as a median with vehicle-only peaks is stop-and-go
            // transit, not a run.
            if peak >= Speed.stopAndGoPeak { return .automotive }
            if peak >= Speed.slowVehiclePeak { return .cycling }
            return total >= runningMinimumDistance ? .running : .walking
        }
        if median >= Speed.walking || total <= creepingWalkMaximumDistance {
            return .walking
        }
        return .unknown
    }

    private struct Leg {
        let distance: CLLocationDistance
        let speed: Double
    }

    private static func legs(for points: [LocationLogPoint]) -> [Leg] {
        zip(points, points.dropFirst()).compactMap { start, end in
            let interval = end.timestamp.timeIntervalSince(start.timestamp)
            guard interval > 0 else { return nil }
            let distance = start.distance(to: end)
            return Leg(distance: distance, speed: distance / interval)
        }
    }

    /// Speed below which `fraction` of the travelled distance was covered.
    private static func weightedSpeed(_ legs: [Leg], fraction: Double, total: CLLocationDistance) -> Double {
        guard total > 0 else { return 0 }
        var covered: CLLocationDistance = 0
        for leg in legs.sorted(by: { $0.speed < $1.speed }) {
            covered += leg.distance
            if covered >= total * fraction {
                return leg.speed
            }
        }
        return legs.last?.speed ?? 0
    }
}

// MARK: - Geometry

enum LocationLogGeometry {
    private static let earthRadius: Double = 6_371_000

    /// Haversine distance. Cheaper than allocating `CLLocation` pairs for tens
    /// of thousands of fixes.
    static func distance(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    static func pathDistance(_ points: [LocationLogPoint]) -> CLLocationDistance {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func longestGap(_ points: [LocationLogPoint]) -> TimeInterval {
        zip(points, points.dropFirst()).reduce(0) { max($0, $1.1.timestamp.timeIntervalSince($1.0.timestamp)) }
    }
}

// MARK: - GPX parsing

/// Streams `<trkpt>` and `<wpt>` fixes out of a GPX file without building an
/// intermediate object graph. Handles offsets such as `-07:00` and fractional
/// seconds; fixes without a `<time>` are skipped because the segmenter needs
/// real timestamps.
final class LocationLogGPXParser: NSObject, XMLParserDelegate {
    struct Result {
        var points: [LocationLogPoint]
        /// Number of `trkpt` elements dropped for missing or unparsable time.
        var untimedCount: Int
    }

    private var points: [LocationLogPoint] = []
    private var untimedCount = 0
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double?
    private var currentTime: Date?
    private var isInsidePoint = false
    private var text = ""

    static func parse(data: Data) throws -> Result {
        let parser = XMLParser(data: data)
        let delegate = LocationLogGPXParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            if let error = parser.parserError, delegate.points.isEmpty {
                throw error
            }
            return Result(points: delegate.points, untimedCount: delegate.untimedCount)
        }
        return Result(points: delegate.points, untimedCount: delegate.untimedCount)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "trkpt", "rtept", "wpt":
            isInsidePoint = true
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentElevation = nil
            currentTime = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsidePoint else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { text = "" }
        guard isInsidePoint else { return }

        switch elementName {
        case "ele":
            currentElevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "time":
            currentTime = LocationLogDateParser.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "trkpt", "rtept", "wpt":
            isInsidePoint = false
            guard let latitude = currentLatitude, let longitude = currentLongitude else { return }
            guard let time = currentTime else {
                untimedCount += 1
                return
            }
            points.append(
                LocationLogPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: currentElevation,
                    timestamp: time
                )
            )
        default:
            break
        }
    }
}

/// ISO 8601 parsing shared by the log importers. Formatter instances are
/// expensive, so they are created once.
enum LocationLogDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        plain.date(from: value) ?? fractional.date(from: value)
    }
}

// MARK: - Place naming

/// Groups imported stays by location and reverse-geocodes one representative
/// per group, most-visited first. Apple's geocoder is rate limited, so lookups
/// are paced and the pass stops early after repeated failures rather than
/// blocking the import.
struct LocationLogPlaceNamer: Sendable {
    struct Candidate: Sendable {
        let placeID: UUID
        let coordinate: CLLocationCoordinate2D
        let dwell: TimeInterval
    }

    struct Cluster: Sendable {
        var placeIDs: [UUID]
        var coordinate: CLLocationCoordinate2D
        var dwell: TimeInterval
    }

    /// Metres within which stays share a name lookup.
    var clusterRadius: CLLocationDistance = 100
    /// Pause between geocoder requests.
    var pacing: Duration = .milliseconds(450)
    /// Give up after this many consecutive failed lookups (usually throttling).
    var maximumConsecutiveFailures = 6
    /// Hard cap on lookups per import so a year of data cannot run for an hour.
    var maximumLookups = 600

    /// Greedy clustering ordered by total dwell so the places that matter most
    /// are named first if the pass has to stop early.
    static func clusters(for candidates: [Candidate], radius: CLLocationDistance) -> [Cluster] {
        var clusters: [Cluster] = []
        for candidate in candidates.sorted(by: { $0.dwell > $1.dwell }) {
            if let index = clusters.firstIndex(where: {
                LocationLogGeometry.distance(from: $0.coordinate, to: candidate.coordinate) <= radius
            }) {
                clusters[index].placeIDs.append(candidate.placeID)
                clusters[index].dwell += candidate.dwell
            } else {
                clusters.append(Cluster(placeIDs: [candidate.placeID], coordinate: candidate.coordinate, dwell: candidate.dwell))
            }
        }
        return clusters.sorted { $0.dwell > $1.dwell }
    }

    /// Resolves names for `candidates` and hands each one to `apply`.
    /// Returns the number of places that received a name.
    func nameClusters(
        _ candidates: [Candidate],
        resolver: PlaceNameResolver,
        progress: @Sendable (Int, Int) -> Void,
        apply: @Sendable (String, [UUID]) throws -> Void
    ) async -> Int {
        let clusters = Self.clusters(for: candidates, radius: clusterRadius).prefix(maximumLookups)
        var named = 0
        var consecutiveFailures = 0

        for (index, cluster) in clusters.enumerated() {
            if Task.isCancelled { break }
            progress(index, clusters.count)

            if let name = await resolver.resolveName(for: cluster.coordinate) {
                consecutiveFailures = 0
                do {
                    try apply(name, cluster.placeIDs)
                    named += cluster.placeIDs.count
                } catch {
                    break
                }
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= maximumConsecutiveFailures {
                    break
                }
            }

            try? await Task.sleep(for: pacing)
        }

        progress(clusters.count, clusters.count)
        return named
    }
}
