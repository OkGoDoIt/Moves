import Foundation
import CoreLocation
import MapKit
import SwiftData

enum TransportMode: String, Codable, CaseIterable, Identifiable {
    case stationary
    case walking
    case running
    case swimming
    case cycling
    case automotive
    case train
    case plane
    case boat
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stationary: return "Stationary"
        case .walking: return "Walking"
        case .running: return "Running"
        case .swimming: return "Swimming"
        case .cycling: return "Cycling"
        case .automotive: return "Automotive"
        case .train: return "Train"
        case .plane: return "Plane"
        case .boat: return "Boat"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .stationary: return "pause.circle.fill"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .swimming: return "figure.pool.swim"
        case .cycling: return "figure.outdoor.cycle"
        case .automotive: return "car.fill"
        case .train: return "tram.fill"
        case .plane: return "airplane"
        case .boat: return "ferry.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum LocationSampleSource: String, Codable, CaseIterable {
    case visit
    case significantChange
    case routeTracking
    case watchRouteTracking
    case fileRouteImport
    case watchSignificantChange
    case healthWorkoutRoute
    case launchBackfill
    case authorizationGrant
    /// A short burst of fixes after leaving a vehicle, or setting off on foot.
    case lastMile
}

extension LocationSampleSource {
    var priority: Int {
        switch self {
        case .fileRouteImport: return 7
        case .watchRouteTracking: return 6
        case .healthWorkoutRoute: return 5
        case .routeTracking: return 4
        case .visit: return 3
        case .watchSignificantChange: return 2
        case .significantChange: return 2
        case .authorizationGrant: return 1
        case .launchBackfill: return 0
        case .lastMile: return 4
        }
    }

    var isRouteTrack: Bool {
        switch self {
        case .routeTracking, .watchRouteTracking, .healthWorkoutRoute, .fileRouteImport, .lastMile:
            return true
        case .visit, .significantChange, .watchSignificantChange, .launchBackfill, .authorizationGrant:
            return false
        }
    }

    var preservesRouteResolution: Bool {
        switch self {
        case .healthWorkoutRoute, .watchRouteTracking, .fileRouteImport, .lastMile:
            return true
        case .routeTracking, .visit, .significantChange, .watchSignificantChange, .launchBackfill, .authorizationGrant:
            return false
        }
    }
}

extension Array where Element == LocationSample {
    var preferredRouteDisplaySamples: [LocationSample] {
        let routeTrackingSamples = filter { $0.source.isRouteTrack }
        return routeTrackingSamples.isEmpty ? self : routeTrackingSamples
    }
}

@Model
final class DayTimeline {
    var dayKey: String = ""
    var dayStart: Date = Date.now
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, originalName: "places", inverse: \VisitPlace.dayTimeline)
    var placesStorage: [VisitPlace]? = nil

    @Relationship(deleteRule: .cascade, originalName: "moves", inverse: \MoveSegment.dayTimeline)
    var movesStorage: [MoveSegment]? = nil

    @Relationship(deleteRule: .cascade, originalName: "samples", inverse: \LocationSample.dayTimeline)
    var samplesStorage: [LocationSample]? = nil

    var places: [VisitPlace] {
        get { placesStorage ?? [] }
        set { placesStorage = newValue }
    }

    var moves: [MoveSegment] {
        get { movesStorage ?? [] }
        set { movesStorage = newValue }
    }

    var samples: [LocationSample] {
        get { samplesStorage ?? [] }
        set { samplesStorage = newValue }
    }

    var uniqueLocationCount: Int {
        Set(places.map(\.locationKey)).count
    }

    init(dayStart: Date) {
        let start = Calendar.current.startOfDay(for: dayStart)
        self.dayStart = start
        self.dayKey = DayTimeline.makeDayKey(for: start)
        self.createdAt = .now
    }

    static func makeDayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension DayTimeline {
    var hasRecordedActivity: Bool {
        !places.isEmpty || !moves.isEmpty || !samples.isEmpty
    }

    /// The last known place from an earlier day, used when nothing was recorded on this day
    /// (for example when the user never left home) so the day still shows where they were.
    var carriedOverPlace: VisitPlace? {
        guard !hasRecordedActivity, let modelContext else { return nil }

        let start = dayStart
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < start
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        return try? modelContext.fetch(descriptor).first
    }

    /// Places to render for this day, falling back to the carried over place on quiet days.
    var displayPlaces: [VisitPlace] {
        places.isEmpty ? [carriedOverPlace].compactMap { $0 } : places
    }
}

@Model
final class VisitPlace {
    var id: UUID = UUID()
    var arrivalDate: Date = Date.now
    var departureDate: Date? = nil
    var latitude: Double = 0
    var longitude: Double = 0
    var horizontalAccuracy: Double = 0
    var userLabel: String? = nil
    var autoLabel: String? = nil
    var comment: String? = nil
    var createdAt: Date = Date.now

    var dayTimeline: DayTimeline?

    @Relationship(originalName: "outgoingMoves", inverse: \MoveSegment.startPlace)
    var outgoingMovesStorage: [MoveSegment]? = nil

    @Relationship(originalName: "incomingMoves", inverse: \MoveSegment.endPlace)
    var incomingMovesStorage: [MoveSegment]? = nil

    var outgoingMoves: [MoveSegment] {
        get { outgoingMovesStorage ?? [] }
        set { outgoingMovesStorage = newValue }
    }

    var incomingMoves: [MoveSegment] {
        get { incomingMovesStorage ?? [] }
        set { incomingMovesStorage = newValue }
    }

    init(
        arrivalDate: Date,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        userLabel: String? = nil,
        autoLabel: String? = nil,
        comment: String? = nil
    ) {
        self.id = UUID()
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.userLabel = userLabel
        self.autoLabel = autoLabel
        self.comment = comment
        self.createdAt = .now
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        if let userLabel, !userLabel.isEmpty {
            return userLabel
        }
        if let autoLabel, !autoLabel.isEmpty {
            return autoLabel
        }

        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        return "\(lat), \(lon)"
    }
}

fileprivate extension VisitPlace {
    var locationKey: String {
        // Round into ~10m buckets so repeat visits to the same spot count once.
        let latitudeBucket = Int((latitude * 10_000).rounded())
        let longitudeBucket = Int((longitude * 10_000).rounded())
        return "\(latitudeBucket)|\(longitudeBucket)"
    }
}

@Model
final class MoveSegment {
    var id: UUID = UUID()
    var dedupeKey: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var transportModeRawValue: String = TransportMode.unknown.rawValue
    var distanceMeters: Double = 0
    var stepCount: Int? = nil
    var comment: String? = nil
    var createdAt: Date = Date.now

    var startPlace: VisitPlace?
    var endPlace: VisitPlace?
    var dayTimeline: DayTimeline?
    var routeCacheSignature: String? = nil
    var routeCacheCoordinatesData: Data? = nil
    var manualRouteCoordinatesData: Data? = nil

    @Relationship(deleteRule: .nullify, originalName: "samples", inverse: \LocationSample.moveSegment)
    var samplesStorage: [LocationSample]? = nil

    var samples: [LocationSample] {
        get { samplesStorage ?? [] }
        set { samplesStorage = newValue }
    }

    init(
        dedupeKey: String,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?,
        comment: String? = nil
    ) {
        self.id = UUID()
        self.dedupeKey = dedupeKey
        self.startDate = startDate
        self.endDate = endDate
        self.transportModeRawValue = transportMode.rawValue
        self.distanceMeters = distanceMeters
        self.stepCount = stepCount
        self.comment = comment
        self.createdAt = .now
    }

    var transportMode: TransportMode {
        get { TransportMode(rawValue: transportModeRawValue) ?? .unknown }
        set { transportModeRawValue = newValue.rawValue }
    }

    var timelineStartDate: Date {
        let departureBasedStart = startPlace?.departureDate ?? startDate
        let normalizedStart = max(departureBasedStart, startDate)
        return min(normalizedStart, endDate)
    }

    var timelineDuration: TimeInterval {
        max(endDate.timeIntervalSince(timelineStartDate), 0)
    }

    var usesHighAccuracyRouteTracking: Bool {
        samples.contains { $0.source.isRouteTrack }
    }

    var usesHealthWorkoutRoute: Bool {
        samples.contains { $0.source == .healthWorkoutRoute }
    }

    func cachedRouteCoordinates(for signature: String) -> [CLLocationCoordinate2D]? {
        guard routeCacheSignature == signature, routeCacheCoordinatesData != nil else {
            return nil
        }

        return RouteCoordinateStorage.decode(routeCacheCoordinatesData)
    }

    func storeCachedRouteCoordinates(_ coordinates: [CLLocationCoordinate2D], signature: String) {
        routeCacheSignature = signature
        routeCacheCoordinatesData = RouteCoordinateStorage.encode(coordinates)
    }

    func clearCachedRouteCoordinates() {
        routeCacheSignature = nil
        routeCacheCoordinatesData = nil
    }
}

@Model
final class LocationSample {
    var dedupeKey: String = ""
    var timestamp: Date = Date.now
    var latitude: Double = 0
    var longitude: Double = 0
    var altitude: Double = 0
    var horizontalAccuracy: Double = 0
    var speed: Double = 0
    var sourceRawValue: String = LocationSampleSource.significantChange.rawValue
    var createdAt: Date = Date.now

    var dayTimeline: DayTimeline?
    var moveSegment: MoveSegment?

    init(location: CLLocation, source: LocationSampleSource, dedupeKey: String) {
        self.dedupeKey = dedupeKey
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speed = location.speed
        self.sourceRawValue = source.rawValue
        self.createdAt = .now
    }

    var source: LocationSampleSource {
        get { LocationSampleSource(rawValue: sourceRawValue) ?? .significantChange }
        set { sourceRawValue = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var asLocation: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }
}

/// One trip the stay reconciler could not find an existing move for.
struct SampleStayMoveLeg {
    /// Where the trip started.
    var startPlace: VisitPlace
    /// Where the trip ended.
    var endPlace: VisitPlace
    var startDate: Date
    var endDate: Date
    /// Path length of the reliable fixes between the two stops, in metres.
    var distanceMeters: Double
    /// Fixes the transport classifier should see, including the stop endpoints.
    var locations: [CLLocation]
}

/// What `reconcileSampleStays` changed, so the assembler can name new stops
/// and classify the trips it just opened.
struct SampleStayReconciliationResult {
    var newPlaces: [VisitPlace] = []
    var moveLegs: [SampleStayMoveLeg] = []
}

protocol TimelineRepository {
    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace
    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample]
    func latestPlace(before date: Date, excluding placeID: UUID?) throws -> VisitPlace?
    func samples(from startDate: Date, to endDate: Date) throws -> [LocationSample]
    /// Rebuilds stops and the automatic trips between them from stored fixes.
    ///
    /// Visit monitoring is the only event that used to open and close stays.
    /// Significant-location fixes were kept, but a missed or early visit left
    /// one trip covering every hour until the next visit arrived. This pass
    /// reads those fixes and corrects that.
    func reconcileSampleStays(now: Date) throws -> SampleStayReconciliationResult
    func upsertMove(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?,
        samples: [LocationSample]
    ) throws -> MoveSegment
    func setAutomaticLabel(_ label: String, for placeID: UUID) throws
    func saveIfNeeded() throws
}

struct HistoricalDeduplicationReport {
    let removedPlaceCount: Int
    let removedMoveCount: Int

    var totalRemovedCount: Int {
        removedPlaceCount + removedMoveCount
    }
}

struct TimelineDeduplicationUndoSnapshot: Codable {
    let capturedAt: Date
    let dayTimelines: [DayTimelineSnapshot]
    let places: [VisitPlaceSnapshot]
    let moves: [MoveSegmentSnapshot]
    let samples: [LocationSampleSnapshot]
}

struct DayTimelineSnapshot: Codable {
    let dayKey: String
    let dayStart: Date
    let createdAt: Date
}

struct VisitPlaceSnapshot: Codable {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let userLabel: String?
    let autoLabel: String?
    let comment: String?
    let createdAt: Date
    let dayKey: String?
}

struct MoveSegmentSnapshot: Codable {
    let id: UUID
    let dedupeKey: String
    let startDate: Date
    let endDate: Date
    let transportModeRawValue: String
    let distanceMeters: Double
    let stepCount: Int?
    let comment: String?
    let createdAt: Date
    let startPlaceID: UUID?
    let endPlaceID: UUID?
    let dayKey: String?
    let routeCacheSignature: String?
    let routeCacheCoordinatesData: Data?
    let manualRouteCoordinatesData: Data?
}

struct LocationSampleSnapshot: Codable {
    let dedupeKey: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double
    let sourceRawValue: String
    let createdAt: Date
    let dayKey: String?
    let moveID: UUID?
}

enum TimelineDeduplicationSnapshotStore {
    enum SnapshotError: Error {
        case missingSnapshot
    }

    private static let filename = "timeline-deduplication-undo-snapshot.json"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static var hasSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    static func save(_ snapshot: TimelineDeduplicationUndoSnapshot) throws {
        let data = try encoder.encode(snapshot)
        let directory = snapshotURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: snapshotURL, options: .atomic)
    }

    static func load() throws -> TimelineDeduplicationUndoSnapshot {
        guard hasSnapshot else {
            throw SnapshotError.missingSnapshot
        }

        let data = try Data(contentsOf: snapshotURL)
        return try decoder.decode(TimelineDeduplicationUndoSnapshot.self, from: data)
    }

    static func clear() throws {
        guard hasSnapshot else { return }
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private static var snapshotURL: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let movesDirectory = appSupport.appendingPathComponent("Moves", isDirectory: true)
        return movesDirectory.appendingPathComponent(filename, isDirectory: false)
    }
}

final class SwiftDataTimelineRepository: TimelineRepository {
    private let modelContext: ModelContext
    private var archiveImportSampleKeys: Set<String>?
    /// Day timelines keyed by `dayKey`, populated only during bulk imports.
    private var bulkDayTimelineCache: [String: DayTimeline]?
    /// User-labelled places, populated only during bulk imports.
    private var bulkLabeledPlaces: [(label: String, coordinate: CLLocationCoordinate2D)]?
    /// Visits inserted by the running bulk import; never merged into each other.
    private var bulkCreatedPlaceIDs: Set<UUID>?
    private static let logPlaceMatchDistance: CLLocationDistance = 120
    private static let logPlaceMatchSlack: TimeInterval = 15 * 60
    private static let logPlaceExtendLimit: TimeInterval = 12 * 60 * 60
    private static let sampleDedupeTimeWindow: TimeInterval = 5 * 60
    private static let sampleDedupeDistanceThreshold: CLLocationDistance = 120
    private static let placeDedupeArrivalWindow: TimeInterval = 3 * 60
    private static let placeDedupeDepartureWindow: TimeInterval = 3 * 60
    private static let placeDedupeDistanceThreshold: CLLocationDistance = 90
    private static let moveDedupeTimeWindow: TimeInterval = 3 * 60
    private static let moveDedupeDurationWindow: TimeInterval = 4 * 60
    private static let moveDedupeDistanceAbsoluteThreshold: CLLocationDistance = 220
    private static let moveDedupeDistanceRelativeThreshold: Double = 0.14
    private static let moveDedupeEndpointDistanceThreshold: CLLocationDistance = 140
    private static let moveParallelEndpointDistanceThreshold: CLLocationDistance = 320
    private static let moveParallelTimeWindow: TimeInterval = 5 * 60
    private static let moveTransientStayMaximumDuration: TimeInterval = 8 * 60
    private static let synthesizedStayMinimumGap: TimeInterval = 10 * 60
    private static let synthesizedStayTimeTolerance: TimeInterval = 60
    private static let placeNeighborMoveWindow: TimeInterval = 4 * 60 * 60
    private static let placeNeighborMoveInferenceSlack: TimeInterval = 20 * 60
    private static let placeNeighborMoveEndpointDistanceThreshold: CLLocationDistance = 180

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createUndoSnapshot() throws -> TimelineDeduplicationUndoSnapshot {
        let dayTimelines = try modelContext.fetch(
            FetchDescriptor<DayTimeline>(
                sortBy: [SortDescriptor(\DayTimeline.dayStart, order: .forward)]
            )
        )
        let places = try modelContext.fetch(
            FetchDescriptor<VisitPlace>(
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
            )
        )
        let moves = try modelContext.fetch(
            FetchDescriptor<MoveSegment>(
                sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
            )
        )
        let samples = try modelContext.fetch(
            FetchDescriptor<LocationSample>(
                sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
            )
        )

        return TimelineDeduplicationUndoSnapshot(
            capturedAt: .now,
            dayTimelines: dayTimelines.map { timeline in
                DayTimelineSnapshot(
                    dayKey: timeline.dayKey,
                    dayStart: timeline.dayStart,
                    createdAt: timeline.createdAt
                )
            },
            places: places.map { place in
                VisitPlaceSnapshot(
                    id: place.id,
                    arrivalDate: place.arrivalDate,
                    departureDate: place.departureDate,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    horizontalAccuracy: place.horizontalAccuracy,
                    userLabel: place.userLabel,
                    autoLabel: place.autoLabel,
                    comment: place.comment,
                    createdAt: place.createdAt,
                    dayKey: place.dayTimeline?.dayKey
                )
            },
            moves: moves.map { move in
                MoveSegmentSnapshot(
                    id: move.id,
                    dedupeKey: move.dedupeKey,
                    startDate: move.startDate,
                    endDate: move.endDate,
                    transportModeRawValue: move.transportModeRawValue,
                    distanceMeters: move.distanceMeters,
                    stepCount: move.stepCount,
                    comment: move.comment,
                    createdAt: move.createdAt,
                    startPlaceID: move.startPlace?.id,
                    endPlaceID: move.endPlace?.id,
                    dayKey: move.dayTimeline?.dayKey,
                    routeCacheSignature: move.routeCacheSignature,
                    routeCacheCoordinatesData: move.routeCacheCoordinatesData,
                    manualRouteCoordinatesData: move.manualRouteCoordinatesData
                )
            },
            samples: samples.map { sample in
                LocationSampleSnapshot(
                    dedupeKey: sample.dedupeKey,
                    timestamp: sample.timestamp,
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    altitude: sample.altitude,
                    horizontalAccuracy: sample.horizontalAccuracy,
                    speed: sample.speed,
                    sourceRawValue: sample.sourceRawValue,
                    createdAt: sample.createdAt,
                    dayKey: sample.dayTimeline?.dayKey,
                    moveID: sample.moveSegment?.id
                )
            }
        )
    }

    func restoreFromUndoSnapshot(_ snapshot: TimelineDeduplicationUndoSnapshot) throws {
        try deleteAllTimelineData()

        var timelinesByDayKey: [String: DayTimeline] = [:]
        timelinesByDayKey.reserveCapacity(snapshot.dayTimelines.count)

        for timelineSnapshot in snapshot.dayTimelines {
            let timeline = DayTimeline(dayStart: timelineSnapshot.dayStart)
            timeline.dayKey = timelineSnapshot.dayKey
            timeline.dayStart = timelineSnapshot.dayStart
            timeline.createdAt = timelineSnapshot.createdAt
            modelContext.insert(timeline)

            if timelinesByDayKey[timelineSnapshot.dayKey] == nil {
                timelinesByDayKey[timelineSnapshot.dayKey] = timeline
            }
        }

        var placesByID: [UUID: VisitPlace] = [:]
        placesByID.reserveCapacity(snapshot.places.count)

        for placeSnapshot in snapshot.places {
            let place = VisitPlace(
                arrivalDate: placeSnapshot.arrivalDate,
                departureDate: placeSnapshot.departureDate,
                latitude: placeSnapshot.latitude,
                longitude: placeSnapshot.longitude,
                horizontalAccuracy: placeSnapshot.horizontalAccuracy,
                userLabel: placeSnapshot.userLabel,
                autoLabel: placeSnapshot.autoLabel,
                comment: placeSnapshot.comment
            )
            place.id = placeSnapshot.id
            place.createdAt = placeSnapshot.createdAt
            if let dayKey = placeSnapshot.dayKey {
                place.dayTimeline = timelinesByDayKey[dayKey]
            }
            modelContext.insert(place)
            placesByID[place.id] = place
        }

        var movesByID: [UUID: MoveSegment] = [:]
        movesByID.reserveCapacity(snapshot.moves.count)

        for moveSnapshot in snapshot.moves {
            let move = MoveSegment(
                dedupeKey: moveSnapshot.dedupeKey,
                startDate: moveSnapshot.startDate,
                endDate: moveSnapshot.endDate,
                transportMode: TransportMode(rawValue: moveSnapshot.transportModeRawValue) ?? .unknown,
                distanceMeters: moveSnapshot.distanceMeters,
                stepCount: moveSnapshot.stepCount,
                comment: moveSnapshot.comment
            )
            move.id = moveSnapshot.id
            move.createdAt = moveSnapshot.createdAt
            move.transportModeRawValue = moveSnapshot.transportModeRawValue
            move.routeCacheSignature = moveSnapshot.routeCacheSignature
            move.routeCacheCoordinatesData = moveSnapshot.routeCacheCoordinatesData
            move.manualRouteCoordinatesData = moveSnapshot.manualRouteCoordinatesData
            if let dayKey = moveSnapshot.dayKey {
                move.dayTimeline = timelinesByDayKey[dayKey]
            }
            move.startPlace = moveSnapshot.startPlaceID.flatMap { placesByID[$0] }
            move.endPlace = moveSnapshot.endPlaceID.flatMap { placesByID[$0] }
            modelContext.insert(move)
            movesByID[move.id] = move
        }

        for sampleSnapshot in snapshot.samples {
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: sampleSnapshot.latitude,
                    longitude: sampleSnapshot.longitude
                ),
                altitude: sampleSnapshot.altitude,
                horizontalAccuracy: sampleSnapshot.horizontalAccuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: sampleSnapshot.speed,
                timestamp: sampleSnapshot.timestamp
            )
            let sample = LocationSample(
                location: location,
                source: LocationSampleSource(rawValue: sampleSnapshot.sourceRawValue) ?? .significantChange,
                dedupeKey: sampleSnapshot.dedupeKey
            )
            sample.timestamp = sampleSnapshot.timestamp
            sample.latitude = sampleSnapshot.latitude
            sample.longitude = sampleSnapshot.longitude
            sample.altitude = sampleSnapshot.altitude
            sample.horizontalAccuracy = sampleSnapshot.horizontalAccuracy
            sample.speed = sampleSnapshot.speed
            sample.sourceRawValue = sampleSnapshot.sourceRawValue
            sample.createdAt = sampleSnapshot.createdAt
            if let dayKey = sampleSnapshot.dayKey {
                sample.dayTimeline = timelinesByDayKey[dayKey]
            }
            if let moveID = sampleSnapshot.moveID {
                sample.moveSegment = movesByID[moveID]
            }
            modelContext.insert(sample)
        }

        try saveIfNeeded()
    }

    func runHistoricalDeduplication() throws -> HistoricalDeduplicationReport {
        let placeCountBefore = try modelContext.fetchCount(FetchDescriptor<VisitPlace>())
        let moveCountBefore = try modelContext.fetchCount(FetchDescriptor<MoveSegment>())

        let placeIDs = try modelContext.fetch(
            FetchDescriptor<VisitPlace>(
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
            )
        )
        .map(\.id)

        for placeID in placeIDs {
            guard let place = try findPlace(byID: placeID) else { continue }
            _ = try collapseDuplicatePlaces(around: place)
        }

        let moveIDs = try modelContext.fetch(
            FetchDescriptor<MoveSegment>(
                sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
            )
        )
        .map(\.id)

        for moveID in moveIDs {
            guard let move = try findMove(byID: moveID) else { continue }
            _ = try collapseDuplicateMoves(around: move)
        }

        try repairMissingStaysAroundMoves()
        try saveIfNeeded()

        let placeCountAfter = try modelContext.fetchCount(FetchDescriptor<VisitPlace>())
        let moveCountAfter = try modelContext.fetchCount(FetchDescriptor<MoveSegment>())

        return HistoricalDeduplicationReport(
            removedPlaceCount: max(placeCountBefore - placeCountAfter, 0),
            removedMoveCount: max(moveCountBefore - moveCountAfter, 0)
        )
    }

    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace {
        let arrival = normalizedArrivalDate(for: visit)
        let departure = normalizedDepartureDate(for: visit)

        let existing = try existingVisit(near: arrival, coordinate: visit.coordinate)
        if let existing {
            if let departure {
                existing.departureDate = departure
            }
            existing.horizontalAccuracy = min(existing.horizontalAccuracy, visit.horizontalAccuracy)
            existing.dayTimeline = try timeline(for: arrival)
            let canonical = try collapseDuplicatePlaces(around: existing)
            try saveIfNeeded()
            return canonical
        }

        let inferredUserLabel = try inferredUserLabel(near: visit.coordinate)

        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy,
            userLabel: inferredUserLabel
        )
        place.dayTimeline = try timeline(for: arrival)
        modelContext.insert(place)
        let canonical = try collapseDuplicatePlaces(around: place)
        try saveIfNeeded()
        return canonical
    }

    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample] {
        guard !locations.isEmpty else { return [] }

        var inserted: [LocationSample] = []
        inserted.reserveCapacity(locations.count)

        for location in locations {
            let dedupeKey = Self.makeSampleDedupeKey(for: location)
            if archiveImportSampleKeys != nil {
                if archiveImportSampleKeys?.contains(dedupeKey) == true {
                    continue
                }
                let sample = LocationSample(location: location, source: source, dedupeKey: dedupeKey)
                sample.dayTimeline = try timeline(for: location.timestamp)
                modelContext.insert(sample)
                archiveImportSampleKeys?.insert(dedupeKey)
                inserted.append(sample)
                continue
            }

            let existing = try findSample(byDedupeKey: dedupeKey)
                ?? (source.preservesRouteResolution ? nil : findNearbySample(matching: location))
            if let existing {
                existing.source = Self.preferredSource(existing: existing.source, new: source)
                inserted.append(existing)
                continue
            }

            let sample = LocationSample(location: location, source: source, dedupeKey: dedupeKey)
            sample.dayTimeline = try timeline(for: location.timestamp)
            modelContext.insert(sample)
            inserted.append(sample)
        }

        if archiveImportSampleKeys == nil {
            try saveIfNeeded()
            NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        }
        return inserted
    }

    @discardableResult
    func importRouteTrack(
        locations: [CLLocation],
        source: LocationSampleSource,
        transportMode: TransportMode
    ) throws -> MoveSegment? {
        let orderedLocations = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 200 }
            .sorted(by: { $0.timestamp < $1.timestamp })

        guard let firstLocation = orderedLocations.first,
              let lastLocation = orderedLocations.last,
              lastLocation.timestamp > firstLocation.timestamp else {
            _ = try appendSamples(from: orderedLocations, source: source)
            return nil
        }

        let samples = try appendSamples(from: orderedLocations, source: source)
        let distance = Self.totalDistance(for: orderedLocations)

        let startPlace = try routeEndpointPlace(
            at: firstLocation,
            arrivalDate: firstLocation.timestamp,
            departureDate: firstLocation.timestamp
        )
        let endPlace = try routeEndpointPlace(
            at: lastLocation,
            arrivalDate: lastLocation.timestamp,
            departureDate: nil
        )

        let move = try upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: firstLocation.timestamp,
            endDate: lastLocation.timestamp,
            transportMode: transportMode,
            distanceMeters: distance,
            stepCount: nil,
            samples: samples
        )

        move.storeCachedRouteCoordinates(
            orderedLocations.map(\.coordinate),
            signature: "imported-\(source.rawValue)-\(samples.count)-\(Int(distance.rounded()))"
        )

        try saveIfNeeded()
        return move
    }

    /// Rebuilds visits, moves, and GPS samples from a merged Moves export.
    ///
    /// Places are written first so moves can reconnect to the same stays. Timed
    /// GPX vertices become `LocationSample` values; GeoJSON/CSV supply names,
    /// transport modes, and the original `day_key`.
    @discardableResult
    func importTimelineArchive(
        _ archive: TimelineArchive,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> TimelineArchiveImportReport {
        guard !archive.isEmpty else {
            throw TimelineArchiveImportError.noTimelineData
        }

        let existingSamples = try modelContext.fetch(FetchDescriptor<LocationSample>())
        archiveImportSampleKeys = Set(existingSamples.map(\.dedupeKey))
        defer { archiveImportSampleKeys = nil }

        let places = archive.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
        let moves = archive.moves.sorted(by: { $0.startDate < $1.startDate })
        let total = max(places.count + moves.count, 1)
        var importedPlaceCount = 0
        var importedMoveCount = 0
        var importedSampleCount = 0

        for (index, record) in places.enumerated() {
            progress?(Double(index) / Double(total), "Restoring places…")
            _ = try upsertImportedPlace(record)
            importedPlaceCount += 1
        }
        try saveIfNeeded()

        for (index, record) in moves.enumerated() {
            progress?(Double(places.count + index) / Double(total), "Restoring moves…")
            importedSampleCount += try importArchiveMove(record)
            importedMoveCount += 1
        }

        try fillMissingDeparturesFromMoves()
        try saveIfNeeded()
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        progress?(1, "Done")

        return TimelineArchiveImportReport(
            fileCount: 0,
            parsedFileCount: 0,
            placeCount: importedPlaceCount,
            moveCount: importedMoveCount,
            sampleCount: importedSampleCount,
            formats: archive.formats,
            skippedFileNames: [],
            warnings: []
        )
    }

    /// Writes a segmented location log as visits, moves, and GPS samples.
    ///
    /// Designed for tens of thousands of fixes: existing sample keys, day
    /// timelines, and user-labelled places are loaded once up front, and the
    /// context is saved in batches instead of after every record. Stays that
    /// overlap an existing visit at the same spot extend that visit rather
    /// than duplicating it, and moves that overlap an existing trip between
    /// the same endpoints enrich it (transport mode, route samples) instead
    /// of adding a parallel one. Re-importing the same file is therefore a
    /// no-op.
    ///
    /// - Parameters:
    ///   - log: Output of `LocationLogSegmenter`.
    ///   - source: Sample source recorded on every fix.
    ///   - transportModeOverride: When the file name already says what the
    ///     activity was (for example a "Morning Run" GPX), that mode wins over
    ///     the speed-based inference.
    ///   - progress: Called on the caller's thread with a 0…1 fraction.
    @discardableResult
    func importLocationLog(
        _ log: LocationLogTimeline,
        source: LocationSampleSource,
        transportModeOverride: TransportMode? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> LocationLogImportReport {
        guard !log.isEmpty else {
            throw LocationLogImportError.noTimelineData
        }

        try beginBulkImport()
        defer { endBulkImport() }

        var report = LocationLogImportReport()
        var previousPlace: VisitPlace?
        var pendingMove: LocationLogMove?
        let total = Double(max(log.segments.count, 1))

        for (index, segment) in log.segments.enumerated() {
            progress?(Double(index) / total, "Rebuilding timeline…")

            switch segment {
            case .stay(let stay):
                let (place, isNew) = try upsertLogStay(stay, source: source, report: &report)
                if isNew {
                    report.placeCount += 1
                    report.newPlaces.append(
                        LocationLogPlaceNamer.Candidate(placeID: place.id, coordinate: place.coordinate, dwell: stay.duration)
                    )
                } else {
                    report.mergedPlaceCount += 1
                }

                if let move = pendingMove {
                    let start = try previousPlace ?? logEndpointPlace(at: move.points.first, fallback: place, report: &report)
                    try insertLogMove(
                        move,
                        from: start,
                        to: place,
                        source: source,
                        transportModeOverride: transportModeOverride,
                        report: &report
                    )
                    pendingMove = nil
                }
                previousPlace = place

            case .move(let move):
                if let orphan = pendingMove {
                    // Two moves in a row only happen at the log edges; give the
                    // first one a point-shaped destination so it still renders.
                    let start = try previousPlace ?? logEndpointPlace(at: orphan.points.first, fallback: nil, report: &report)
                    let end = try logEndpointPlace(at: orphan.points.last, fallback: start, report: &report)
                    try insertLogMove(orphan, from: start, to: end, source: source, transportModeOverride: transportModeOverride, report: &report)
                    previousPlace = end
                }
                pendingMove = move
            }

            if index.isMultiple(of: 120) {
                try saveIfNeeded()
            }
        }

        if let move = pendingMove {
            let start = try previousPlace ?? logEndpointPlace(at: move.points.first, fallback: nil, report: &report)
            let end = try logEndpointPlace(at: move.points.last, fallback: start, report: &report)
            try insertLogMove(move, from: start, to: end, source: source, transportModeOverride: transportModeOverride, report: &report)
        }

        progress?(0.98, "Saving…")
        try fillMissingDeparturesFromMoves()
        try saveIfNeeded()
        progress?(1, "Done")
        return report
    }

    /// Loads the lookup tables the bulk importers use to avoid per-record fetches.
    private func beginBulkImport() throws {
        var keyDescriptor = FetchDescriptor<LocationSample>()
        keyDescriptor.propertiesToFetch = [\.dedupeKey]
        archiveImportSampleKeys = Set(try modelContext.fetch(keyDescriptor).map(\.dedupeKey))

        let timelines = try modelContext.fetch(FetchDescriptor<DayTimeline>())
        var cache: [String: DayTimeline] = [:]
        cache.reserveCapacity(timelines.count)
        for timeline in timelines where cache[timeline.dayKey] == nil {
            cache[timeline.dayKey] = timeline
        }
        bulkDayTimelineCache = cache

        let labeled = try modelContext.fetch(
            FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.userLabel != nil })
        )
        bulkLabeledPlaces = labeled.compactMap { place in
            guard let label = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return nil
            }
            return (label, place.coordinate)
        }
        bulkCreatedPlaceIDs = []
    }

    private func endBulkImport() {
        archiveImportSampleKeys = nil
        bulkDayTimelineCache = nil
        bulkLabeledPlaces = nil
        bulkCreatedPlaceIDs = nil
    }

    /// Finds or creates the visit for a stay. Existing visits within
    /// `logPlaceMatchDistance` whose time range touches the stay are reused
    /// and extended.
    private func upsertLogStay(
        _ stay: LocationLogStay,
        source: LocationSampleSource,
        report: inout LocationLogImportReport
    ) throws -> (VisitPlace, isNew: Bool) {
        report.sampleCount += try appendSamples(from: stay.points.map(\.location), source: source).count

        let windowStart = stay.arrivalDate.addingTimeInterval(-36 * 60 * 60)
        let windowEnd = stay.departureDate.addingTimeInterval(Self.logPlaceMatchSlack)
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 96

        // Pick the existing visit sharing the most time with this stay. Places
        // created earlier in this same import are skipped: the segmenter
        // already decided those were separate stays, and folding them back
        // together would swallow the short trip between them.
        let nearby = try modelContext.fetch(descriptor).filter { place in
            guard bulkCreatedPlaceIDs?.contains(place.id) != true else { return false }
            return Self.distanceMeters(from: stay.coordinate, to: place.coordinate) <= Self.logPlaceMatchDistance
        }
        let match = nearby
            .map { place -> (VisitPlace, TimeInterval) in
                let placeEnd = place.departureDate ?? place.arrivalDate.addingTimeInterval(Self.logPlaceMatchSlack)
                let overlap = min(placeEnd, stay.departureDate).timeIntervalSince(max(place.arrivalDate, stay.arrivalDate))
                return (place, overlap)
            }
            .filter { $0.1 >= -Self.logPlaceMatchSlack }
            .max(by: { $0.1 < $1.1 })?
            .0

        if let match {
            // Grow the visit toward the stay's bounds, but never across a
            // neighbouring visit at the same spot (CLVisit often splits one
            // evening at home into several fragments).
            let previousDeparture = nearby
                .filter { $0.id != match.id && $0.arrivalDate < match.arrivalDate }
                .compactMap { $0.departureDate }
                .max()
            let nextArrival = nearby
                .filter { $0.id != match.id && $0.arrivalDate > match.arrivalDate }
                .map(\.arrivalDate)
                .min()

            if stay.arrivalDate < match.arrivalDate,
               match.arrivalDate.timeIntervalSince(stay.arrivalDate) <= Self.logPlaceExtendLimit {
                match.arrivalDate = max(stay.arrivalDate, previousDeparture ?? stay.arrivalDate)
            }
            let wantedDeparture = min(stay.departureDate, nextArrival ?? stay.departureDate)
            if let departure = match.departureDate {
                if wantedDeparture > departure,
                   wantedDeparture.timeIntervalSince(departure) <= Self.logPlaceExtendLimit {
                    match.departureDate = wantedDeparture
                }
            } else {
                match.departureDate = max(wantedDeparture, match.arrivalDate)
            }
            match.horizontalAccuracy = min(match.horizontalAccuracy, Self.logPlaceAccuracy(for: stay))
            if match.dayTimeline == nil {
                match.dayTimeline = try timeline(for: match.arrivalDate)
            }
            return (match, false)
        }

        let place = VisitPlace(
            arrivalDate: stay.arrivalDate,
            departureDate: stay.departureDate,
            latitude: stay.latitude,
            longitude: stay.longitude,
            horizontalAccuracy: Self.logPlaceAccuracy(for: stay),
            userLabel: try inferredUserLabel(near: stay.coordinate)
        )
        place.dayTimeline = try timeline(for: stay.arrivalDate)
        modelContext.insert(place)
        bulkCreatedPlaceIDs?.insert(place.id)
        return (place, true)
    }

    private static func logPlaceAccuracy(for stay: LocationLogStay) -> Double {
        min(max(stay.radius, 20), 150)
    }

    /// Point-shaped visit used when a move starts or ends without a stay
    /// (the log began or ended mid-trip).
    private func logEndpointPlace(
        at point: LocationLogPoint?,
        fallback: VisitPlace?,
        report: inout LocationLogImportReport
    ) throws -> VisitPlace {
        guard let point else {
            if let fallback { return fallback }
            throw LocationLogImportError.noTimelineData
        }
        let existed = try existingVisit(near: point.timestamp, coordinate: point.coordinate) != nil
        let place = try routeEndpointPlace(at: point.location, arrivalDate: point.timestamp, departureDate: point.timestamp)
        if existed {
            report.mergedPlaceCount += 1
        } else {
            report.placeCount += 1
            bulkCreatedPlaceIDs?.insert(place.id)
            report.newPlaces.append(
                LocationLogPlaceNamer.Candidate(placeID: place.id, coordinate: place.coordinate, dwell: 0)
            )
        }
        return place
    }

    /// Adds a move between two visits, or enriches an existing move that
    /// already covers the same trip.
    private func insertLogMove(
        _ move: LocationLogMove,
        from startPlace: VisitPlace,
        to endPlace: VisitPlace,
        source: LocationSampleSource,
        transportModeOverride: TransportMode?,
        report: inout LocationLogImportReport
    ) throws {
        let locations = move.points.map(\.location)
        let samples = try appendSamples(from: locations, source: source)
        report.sampleCount += samples.count

        let startDate = move.startDate
        let endDate = max(move.endDate, startDate.addingTimeInterval(1))
        let mode = transportModeOverride ?? move.transportMode

        if let existing = try existingLogMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: startDate,
            endDate: endDate
        ) {
            if existing.transportMode == .unknown, mode != .unknown {
                existing.transportMode = mode
            }
            if existing.distanceMeters <= 0 {
                existing.distanceMeters = move.distanceMeters
            }
            if existing.startPlace == nil { existing.startPlace = startPlace }
            if existing.endPlace == nil { existing.endPlace = endPlace }
            if existing.samples.count < samples.count {
                for sample in samples where sample.moveSegment == nil || sample.moveSegment === existing {
                    sample.moveSegment = existing
                }
            }
            report.mergedMoveCount += 1
            return
        }

        let segment = MoveSegment(
            dedupeKey: Self.makeMoveDedupeKey(
                startPlaceID: startPlace.id,
                endPlaceID: endPlace.id,
                startDate: startDate,
                endDate: endDate
            ),
            startDate: startDate,
            endDate: endDate,
            transportMode: mode,
            distanceMeters: move.distanceMeters,
            stepCount: nil
        )
        segment.startPlace = startPlace
        segment.endPlace = endPlace
        segment.dayTimeline = try timeline(for: startDate)
        modelContext.insert(segment)
        for sample in samples where sample.moveSegment == nil {
            sample.moveSegment = segment
        }
        report.moveCount += 1
    }

    /// A move already in the store that covers the same trip: same endpoints
    /// (by identity or within `moveDedupeEndpointDistanceThreshold`) and at
    /// least half of the shorter duration in common.
    private func existingLogMove(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date
    ) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startDate <= endDate && move.endDate >= startDate
            },
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
        )
        descriptor.fetchLimit = 64

        let ownDuration = endDate.timeIntervalSince(startDate)
        return try modelContext.fetch(descriptor).first { candidate in
            let overlap = min(candidate.endDate, endDate).timeIntervalSince(max(candidate.startDate, startDate))
            let shorter = max(min(ownDuration, candidate.endDate.timeIntervalSince(candidate.startDate)), 1)
            guard overlap >= shorter * 0.5 else { return false }

            let sameStart = candidate.startPlace?.id == startPlace.id
                || candidate.startPlace.map { Self.distanceMeters(from: $0.coordinate, to: startPlace.coordinate) <= Self.moveDedupeEndpointDistanceThreshold } == true
            let sameEnd = candidate.endPlace?.id == endPlace.id
                || candidate.endPlace.map { Self.distanceMeters(from: $0.coordinate, to: endPlace.coordinate) <= Self.moveDedupeEndpointDistanceThreshold } == true
            return sameStart && sameEnd
        }
    }

    func latestPlace(before date: Date, excluding placeID: UUID?) throws -> VisitPlace? {
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < date
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 24

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            $0.id != placeID && ($0.departureDate ?? $0.arrivalDate) < date
        }
    }

    func samples(from startDate: Date, to endDate: Date) throws -> [LocationSample] {
        guard startDate <= endDate else { return [] }

        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.timestamp >= startDate && sample.timestamp <= endDate
            },
            sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func reconcileSampleStays(now: Date) throws -> SampleStayReconciliationResult {
        let windowStart = try reconciliationWindowStart(through: now)
        let storedSamples = try samples(from: windowStart, to: now.addingTimeInterval(60))
        let points = storedSamples.map { LocationLogPoint(location: $0.asLocation) }
        let inferred = SampleStayInference.stays(from: points, now: now)

        var places = try placesArriving(from: windowStart.addingTimeInterval(-36 * 60 * 60), through: now)
        let clamped = inferred.flatMap { split($0, aroundFarPlaces: places) }
        var newPlaces: [VisitPlace] = []

        for stay in clamped {
            if let match = matchingPlace(for: stay, among: places, samples: storedSamples) {
                try extend(match, toCover: stay, among: places)
            } else {
                let created = try makePlace(for: stay, among: places)
                places.append(created)
                newPlaces.append(created)
            }
        }

        places.sort { $0.arrivalDate < $1.arrivalDate }
        try mergeAdjacentSamePlaceVisits(&places, samples: storedSamples)
        closeOpenPlacesThatHaveASuccessor(places)
        // A visit that ends at the exact moment the next one starts has swallowed
        // the walk between them. Pull the departure back to the last fix that
        // was still there so the gap becomes a trip.
        separateLastBlockWalks(places, samples: storedSamples)

        try deleteInconsistentAutomaticMoves(among: places, from: windowStart, through: now)
        let legs = try moveLegs(among: places, samples: storedSamples, from: windowStart, through: now)
        let survivingNewPlaces = newPlaces.filter { created in
            places.contains { $0.id == created.id }
        }

        try saveIfNeeded()
        return SampleStayReconciliationResult(newPlaces: survivingNewPlaces, moveLegs: legs)
    }

    /// How far back to read fixes. A week covers a missed visit that is still
    /// on screen, without rewriting the whole diary on every launch.
    private func reconciliationWindowStart(through end: Date) throws -> Date {
        end.addingTimeInterval(-7 * 24 * 60 * 60)
    }

    private func placesArriving(from start: Date, through end: Date) throws -> [VisitPlace] {
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= start && place.arrivalDate <= end
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// A comment, a hand-drawn route, or a Health workout is the user's account
    /// of the trip. Automatic repair must leave it alone.
    private func isUserCurated(_ move: MoveSegment) -> Bool {
        if let comment = move.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            return true
        }
        if move.manualRouteCoordinatesData != nil {
            return true
        }
        return move.samples.contains { $0.source == .healthWorkoutRoute }
    }

    private static let stayMatchDistance: CLLocationDistance = 120

    /// Cuts a stop so it does not swallow a visit that fixes put somewhere else.
    private func split(_ stay: SampleStay, aroundFarPlaces places: [VisitPlace]) -> [SampleStay] {
        let stayEnd = stay.presenceEnd
        let blockers = places
            .filter { Self.distanceMeters(from: stay.coordinate, to: $0.coordinate) > Self.stayMatchDistance }
            .filter { place in
                let placeEnd = place.departureDate ?? place.arrivalDate
                return place.arrivalDate < stayEnd && placeEnd > stay.arrivalDate
            }
            .sorted { $0.arrivalDate < $1.arrivalDate }

        guard let blocker = blockers.first else { return [stay] }

        let minimumStay = SampleStayInference.Configuration().minimumStayDuration
        var pieces: [SampleStay] = []
        if blocker.arrivalDate.timeIntervalSince(stay.arrivalDate) >= minimumStay {
            var head = stay
            head.departureDate = blocker.arrivalDate
            head.lastInsideDate = min(stay.lastInsideDate, blocker.arrivalDate)
            pieces.append(head)
        }

        if let blockerEnd = blocker.departureDate,
           stayEnd.timeIntervalSince(blockerEnd) >= minimumStay {
            var tail = stay
            tail.arrivalDate = blockerEnd
            tail.lastInsideDate = max(stay.lastInsideDate, blockerEnd)
            pieces.append(contentsOf: split(tail, aroundFarPlaces: Array(blockers.dropFirst())))
        }
        return pieces
    }

    private func matchingPlace(
        for stay: SampleStay,
        among places: [VisitPlace],
        samples: [LocationSample]
    ) -> VisitPlace? {
        places
            .filter { place in
                Self.distanceMeters(from: stay.coordinate, to: place.coordinate) <= Self.stayMatchDistance
                    && !placeSeparates(place, from: stay, samples: samples)
                    && !anotherPlaceLiesBetween(place, and: stay, among: places)
            }
            .min { lhs, rhs in
                abs(lhs.arrivalDate.timeIntervalSince(stay.arrivalDate))
                    < abs(rhs.arrivalDate.timeIntervalSince(stay.arrivalDate))
            }
    }

    /// True when a same-spot visit and a reconstructed stop are different presences.
    ///
    /// A gap with no fix outside the spot is the same stay: significant-location
    /// delivery goes quiet while the phone is still. A fix that actually left
    /// keeps them apart.
    private func placeSeparates(
        _ place: VisitPlace,
        from stay: SampleStay,
        samples: [LocationSample]
    ) -> Bool {
        let placeEnd = place.departureDate ?? place.arrivalDate
        let stayEnd = stay.presenceEnd
        let gapStart: Date
        let gapEnd: Date
        if placeEnd < stay.arrivalDate {
            gapStart = placeEnd
            gapEnd = stay.arrivalDate
        } else if stayEnd < place.arrivalDate {
            gapStart = stayEnd
            gapEnd = place.arrivalDate
        } else {
            return false
        }

        let gap = gapEnd.timeIntervalSince(gapStart)
        if gap <= 3 * 60 * 60 { return false }
        if gap > 18 * 60 * 60 { return true }

        let centre = stay.coordinate
        let placeCentre = place.coordinate
        let left = samples.contains { sample in
            guard sample.timestamp > gapStart, sample.timestamp < gapEnd else { return false }
            let fromStay = Self.distanceMeters(from: sample.coordinate, to: centre)
            let fromPlace = Self.distanceMeters(from: sample.coordinate, to: placeCentre)
            return fromStay > Self.stayMatchDistance && fromPlace > Self.stayMatchDistance
        }
        return left
    }

    /// A visit somewhere else between this place and this stop means they are
    /// not the same presence, even if both are at home.
    private func anotherPlaceLiesBetween(
        _ place: VisitPlace,
        and stay: SampleStay,
        among places: [VisitPlace]
    ) -> Bool {
        let start = min(place.arrivalDate, stay.arrivalDate)
        let end = max(place.departureDate ?? place.arrivalDate, stay.presenceEnd)
        return places.contains { other in
            other.id != place.id
                && other.arrivalDate > start
                && other.arrivalDate < end
                && Self.distanceMeters(from: other.coordinate, to: place.coordinate) > Self.stayMatchDistance
        }
    }

    private func extend(_ place: VisitPlace, toCover stay: SampleStay, among places: [VisitPlace]) throws {
        let proposedArrival = min(place.arrivalDate, stay.arrivalDate)
        place.arrivalDate = clampedArrival(proposedArrival, for: place, among: places)

        let nextDifferent = nextDifferentPlace(after: place, among: places)
        if let stayEnd = stay.departureDate {
            var capped = stayEnd
            if let next = nextDifferent {
                capped = min(capped, next.arrivalDate)
            }
            if capped > place.arrivalDate {
                if let current = place.departureDate {
                    if capped > current {
                        place.departureDate = capped
                    }
                } else {
                    place.departureDate = capped
                }
            }
        } else if let next = nextDifferent, next.arrivalDate > stay.lastInsideDate {
            if place.departureDate == nil || (place.departureDate ?? .distantFuture) > next.arrivalDate {
                place.departureDate = min(stay.lastInsideDate, next.arrivalDate)
            }
        } else if stay.lastInsideDate > (place.departureDate ?? .distantPast) {
            place.departureDate = nil
        }

        place.horizontalAccuracy = min(place.horizontalAccuracy, stay.horizontalAccuracy)
        place.dayTimeline = try timeline(for: place.arrivalDate)
    }

    private func makePlace(for stay: SampleStay, among places: [VisitPlace]) throws -> VisitPlace {
        var departure = stay.departureDate
        let draft = VisitPlace(
            arrivalDate: stay.arrivalDate,
            departureDate: departure,
            latitude: stay.latitude,
            longitude: stay.longitude,
            horizontalAccuracy: max(stay.horizontalAccuracy, 20),
            userLabel: try inferredUserLabel(near: stay.coordinate)
        )
        if departure == nil, let next = nextDifferentPlace(after: draft, among: places), next.arrivalDate > stay.lastInsideDate {
            departure = min(stay.lastInsideDate, next.arrivalDate)
            draft.departureDate = departure
        }
        draft.dayTimeline = try timeline(for: draft.arrivalDate)
        modelContext.insert(draft)
        return draft
    }

    private func clampedArrival(_ proposed: Date, for place: VisitPlace, among places: [VisitPlace]) -> Date {
        guard let previous = places
            .filter({ $0.id != place.id && $0.arrivalDate < place.arrivalDate })
            .max(by: { $0.arrivalDate < $1.arrivalDate })
        else {
            return proposed
        }

        guard Self.distanceMeters(from: previous.coordinate, to: place.coordinate) > Self.stayMatchDistance else {
            return proposed
        }
        let boundary = previous.departureDate ?? previous.arrivalDate
        return max(proposed, boundary)
    }

    private func nextDifferentPlace(after place: VisitPlace, among places: [VisitPlace]) -> VisitPlace? {
        places
            .filter { candidate in
                candidate.id != place.id
                    && candidate.arrivalDate > place.arrivalDate
                    && Self.distanceMeters(from: candidate.coordinate, to: place.coordinate) > Self.stayMatchDistance
            }
            .min { $0.arrivalDate < $1.arrivalDate }
    }

    /// Joins two visits at the same spot when a fix between them never left.
    /// Visit monitoring likes to close a stay and open another a few minutes
    /// later while the phone has not moved.
    private func mergeAdjacentSamePlaceVisits(
        _ places: inout [VisitPlace],
        samples: [LocationSample]
    ) throws {
        var index = 0
        while index < places.count - 1 {
            let current = places[index]
            let next = places[index + 1]
            let distance = Self.distanceMeters(from: current.coordinate, to: next.coordinate)
            guard distance <= Self.stayMatchDistance else {
                index += 1
                continue
            }

            let currentEnd = current.departureDate ?? current.arrivalDate
            let gap = next.arrivalDate.timeIntervalSince(currentEnd)
            // A clean handoff (one visit ends as the next begins) stays two
            // visits. Merge only when they overlap, or when fixes in the gap
            // show the phone never left and the split was a false departure.
            let overlaps = currentEnd.timeIntervalSince(next.arrivalDate) > 60
            let stayed = gap > 60 && gap <= 12 * 60 * 60 && samplesProvePresence(
                from: currentEnd,
                to: next.arrivalDate,
                around: current.coordinate,
                samples: samples
            )
            guard overlaps || stayed else {
                index += 1
                continue
            }

            if labelsConflict(current, next) {
                index += 1
                continue
            }

            mergePlace(next, into: current)
            if let nextDeparture = next.departureDate, nextDeparture > (current.departureDate ?? current.arrivalDate) {
                current.departureDate = nextDeparture
            } else if next.departureDate == nil {
                current.departureDate = nil
            }
            current.arrivalDate = min(current.arrivalDate, next.arrivalDate)
            modelContext.delete(next)
            places.remove(at: index + 1)
        }
    }

    private func labelsConflict(_ lhs: VisitPlace, _ rhs: VisitPlace) -> Bool {
        let left = lhs.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !left.isEmpty && !right.isEmpty && left != right
    }

    /// True when every fix in the gap is still at `coordinate`. An empty gap
    /// does not count: with no evidence, the visit boundary stands.
    private func samplesProvePresence(
        from start: Date,
        to end: Date,
        around coordinate: CLLocationCoordinate2D,
        samples: [LocationSample]
    ) -> Bool {
        let inside = samples.filter { sample in
            sample.timestamp > start && sample.timestamp < end
        }
        guard !inside.isEmpty else { return false }
        return inside.allSatisfy { sample in
            Self.distanceMeters(from: sample.coordinate, to: coordinate) <= Self.stayMatchDistance
        }
    }

    /// Turns a stay that runs right up to a place a couple of blocks away into
    /// a stay plus a walk. Low-power fixes record the kerb and the door, and
    /// nothing between.
    private func separateLastBlockWalks(_ places: [VisitPlace], samples: [LocationSample]) {
        let ordered = places.sorted { $0.arrivalDate < $1.arrivalDate }
        for index in ordered.indices.dropLast() {
            let current = ordered[index]
            let next = ordered[index + 1]
            let userLabel = current.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !userLabel.isEmpty { continue }

            let separation = Self.distanceMeters(from: current.coordinate, to: next.coordinate)
            guard separation >= LastBlockWalk.minimumDistance,
                  separation <= LastBlockWalk.maximumDistance
            else { continue }

            guard let departure = current.departureDate else { continue }
            let glued = next.arrivalDate.timeIntervalSince(departure) < 90
            guard glued else { continue }

            let lastOnSite = samples
                .filter { sample in
                    sample.timestamp >= current.arrivalDate
                        && sample.timestamp < next.arrivalDate.addingTimeInterval(-LastBlockWalk.minimumDuration)
                        && Self.distanceMeters(from: sample.coordinate, to: current.coordinate) <= Self.stayMatchDistance
                }
                .map(\.timestamp)
                .max()
            guard let lastOnSite else { continue }
            let walkDuration = next.arrivalDate.timeIntervalSince(lastOnSite)
            guard LastBlockWalk.isShape(distance: separation, duration: walkDuration) else { continue }
            current.departureDate = max(lastOnSite, current.arrivalDate)
        }
    }

    private func closeOpenPlacesThatHaveASuccessor(_ places: [VisitPlace]) {
        for (index, place) in places.enumerated() where place.departureDate == nil {
            guard let next = places[(index + 1)...].first else { continue }
            if next.arrivalDate > place.arrivalDate {
                place.departureDate = next.arrivalDate
            }
        }
    }

    private func deleteInconsistentAutomaticMoves(
        among places: [VisitPlace],
        from start: Date,
        through end: Date
    ) throws {
        let moves = try modelContext.fetch(
            FetchDescriptor<MoveSegment>(
                predicate: #Predicate { move in
                    move.endDate >= start && move.startDate <= end
                }
            )
        )

        for move in moves where !isUserCurated(move) {
            guard shouldDeleteAutomaticMove(move, places: places) else { continue }
            modelContext.delete(move)
        }
    }

    private func shouldDeleteAutomaticMove(_ move: MoveSegment, places: [VisitPlace]) -> Bool {
        let interior = places.contains { place in
            guard place.id != move.startPlace?.id, place.id != move.endPlace?.id else { return false }
            let placeEnd = place.departureDate ?? place.arrivalDate
            let overlapsStart = placeEnd > move.startDate.addingTimeInterval(60)
            let overlapsEnd = place.arrivalDate < move.endDate.addingTimeInterval(-60)
            return overlapsStart && overlapsEnd
        }
        if interior { return true }

        if let departure = move.startPlace?.departureDate,
           move.startDate.addingTimeInterval(5 * 60) < departure {
            return true
        }

        if move.endDate.timeIntervalSince(move.endPlace?.arrivalDate ?? move.endDate) > 5 * 60 {
            return true
        }

        // A short slow hop labeled as a ride is the walk off the bus. Drop it
        // so the next pass can classify it from the gap's own steps.
        if let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate {
            let separation = Self.distanceMeters(from: start, to: end)
            let duration = move.endDate.timeIntervalSince(move.startDate)
            let mislabeledRide = LastBlockWalk.isShape(distance: separation, duration: duration)
                && (move.transportMode == .automotive || move.transportMode == .stationary || move.transportMode == .unknown)
            if mislabeledRide { return true }
        }

        return false
    }

    private func moveLegs(
        among places: [VisitPlace],
        samples: [LocationSample],
        from start: Date,
        through end: Date
    ) throws -> [SampleStayMoveLeg] {
        let ordered = places.sorted { $0.arrivalDate < $1.arrivalDate }
        var legs: [SampleStayMoveLeg] = []

        for index in ordered.indices.dropLast() {
            let origin = ordered[index]
            let destination = ordered[index + 1]
            let legStart = origin.departureDate ?? origin.arrivalDate
            let legEnd = destination.arrivalDate
            guard legEnd.timeIntervalSince(legStart) > 60 else { continue }
            guard legEnd >= start, legStart <= end else { continue }
            if try existingConsistentMove(from: origin, to: destination, start: legStart, end: legEnd) != nil {
                continue
            }

            let between = samples
                .filter { $0.timestamp >= legStart && $0.timestamp <= legEnd }
                .map { LocationLogPoint(location: $0.asLocation) }
            let reliable = SampleStayInference.reliablePoints(from: between)
            let originPoint = LocationLogPoint(
                latitude: origin.latitude,
                longitude: origin.longitude,
                horizontalAccuracy: origin.horizontalAccuracy,
                timestamp: legStart
            )
            let destinationPoint = LocationLogPoint(
                latitude: destination.latitude,
                longitude: destination.longitude,
                horizontalAccuracy: destination.horizontalAccuracy,
                timestamp: legEnd
            )
            var routed = reliable
            if routed.first?.timestamp != legStart {
                routed.insert(originPoint, at: 0)
            }
            if routed.last?.timestamp != legEnd {
                routed.append(destinationPoint)
            }

            legs.append(
                SampleStayMoveLeg(
                    startPlace: origin,
                    endPlace: destination,
                    startDate: legStart,
                    endDate: legEnd,
                    distanceMeters: LocationLogGeometry.pathDistance(routed),
                    locations: routed.map(\.location)
                )
            )
        }

        return legs
    }

    private func existingConsistentMove(
        from origin: VisitPlace,
        to destination: VisitPlace,
        start: Date,
        end: Date
    ) throws -> MoveSegment? {
        guard let existing = try findMove(startPlaceID: origin.id, endPlaceID: destination.id) else {
            return nil
        }
        let startDelta = abs(existing.startDate.timeIntervalSince(start))
        let endDelta = abs(existing.endDate.timeIntervalSince(end))
        guard startDelta <= 5 * 60, endDelta <= 5 * 60 else { return nil }
        guard existing.transportMode != .unknown else { return nil }
        return existing
    }

    func upsertMove(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?,
        samples: [LocationSample]
    ) throws -> MoveSegment {
        let dedupeKey = Self.makeMoveDedupeKey(
            startPlaceID: startPlace.id,
            endPlaceID: endPlace.id,
            startDate: startDate,
            endDate: endDate
        )

        let timeline = try timeline(for: startDate)

        let move: MoveSegment
        if let existing = try findMove(byDedupeKey: dedupeKey)
            ?? findMove(startPlaceID: startPlace.id, endPlaceID: endPlace.id)
            ?? findSimilarMove(
                startCoordinate: startPlace.coordinate,
                endCoordinate: endPlace.coordinate,
                startDate: startDate,
                endDate: endDate,
                distanceMeters: distanceMeters,
                transportMode: transportMode
            ) {
            move = existing
            move.dedupeKey = dedupeKey
            move.transportMode = transportMode
            move.distanceMeters = distanceMeters
            move.stepCount = stepCount
            move.startDate = startDate
            move.endDate = endDate
        } else {
            move = MoveSegment(
                dedupeKey: dedupeKey,
                startDate: startDate,
                endDate: endDate,
                transportMode: transportMode,
                distanceMeters: distanceMeters,
                stepCount: stepCount
            )
            modelContext.insert(move)
        }

        move.startPlace = startPlace
        move.endPlace = endPlace
        move.dayTimeline = timeline

        for sample in samples {
            sample.moveSegment = move
        }

        let canonical = try collapseDuplicateMoves(around: move)
        try saveIfNeeded()
        return canonical
    }

    func setAutomaticLabel(_ label: String, for placeID: UUID) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.id == placeID
            }
        )
        descriptor.fetchLimit = 1

        guard let place = try modelContext.fetch(descriptor).first else {
            return
        }

        if let userLabel = place.userLabel, !userLabel.isEmpty {
            return
        }
        if let existingAuto = place.autoLabel, !existingAuto.isEmpty {
            return
        }

        place.autoLabel = trimmed
        try saveIfNeeded()
    }

    func saveIfNeeded() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    private func timeline(for date: Date, exportedDayKey: String?) throws -> DayTimeline {
        let trimmed = exportedDayKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            var descriptor = FetchDescriptor<DayTimeline>(
                predicate: #Predicate { timeline in
                    timeline.dayKey == trimmed
                }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                return existing
            }
            if let dayStart = Self.exportedDayKeyParser.date(from: trimmed) {
                let timeline = DayTimeline(dayStart: dayStart)
                modelContext.insert(timeline)
                return timeline
            }
        }
        return try timeline(for: date)
    }

    private func upsertImportedPlace(_ record: TimelineArchivePlace) throws -> VisitPlace {
        if let existing = try existingPlace(at: record.coordinate, covering: record.arrivalDate) {
            applyArchiveMetadata(record, to: existing)
            existing.dayTimeline = try timeline(for: record.arrivalDate, exportedDayKey: record.dayKey)
            return try collapseDuplicatePlaces(around: existing)
        }

        let place = VisitPlace(
            arrivalDate: record.arrivalDate,
            departureDate: record.departureDate,
            latitude: record.latitude,
            longitude: record.longitude,
            horizontalAccuracy: 20,
            userLabel: record.userLabel,
            autoLabel: record.autoLabel,
            comment: record.comment
        )
        place.dayTimeline = try timeline(for: record.arrivalDate, exportedDayKey: record.dayKey)
        modelContext.insert(place)
        return try collapseDuplicatePlaces(around: place)
    }

    private func importArchiveMove(_ record: TimelineArchiveMove) throws -> Int {
        var locations = record.locations()
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 200 }
            .sorted(by: { $0.timestamp < $1.timestamp })

        let startPlace = try resolveImportedPlace(
            title: record.startPlaceTitle,
            date: record.startDate,
            coordinate: locations.first?.coordinate,
            exportedDayKey: record.dayKey,
            role: .start
        )
        let endPlace = try resolveImportedPlace(
            title: record.endPlaceTitle,
            date: record.endDate,
            coordinate: locations.last?.coordinate,
            exportedDayKey: record.dayKey,
            role: .end
        )

        if locations.count < 2 {
            locations = [
                CLLocation(
                    coordinate: startPlace.coordinate,
                    altitude: 0,
                    horizontalAccuracy: 20,
                    verticalAccuracy: -1,
                    course: -1,
                    speed: -1,
                    timestamp: record.startDate
                ),
                CLLocation(
                    coordinate: endPlace.coordinate,
                    altitude: 0,
                    horizontalAccuracy: 20,
                    verticalAccuracy: -1,
                    course: -1,
                    speed: -1,
                    timestamp: max(record.endDate, record.startDate.addingTimeInterval(1))
                ),
            ]
        }

        guard let firstLocation = locations.first, let lastLocation = locations.last else {
            return 0
        }

        let endDate = lastLocation.timestamp > firstLocation.timestamp
            ? lastLocation.timestamp
            : record.endDate > record.startDate ? record.endDate : record.startDate.addingTimeInterval(1)

        let samples = try appendSamples(from: locations, source: .fileRouteImport)
        let existing = try findSimilarMove(
            startCoordinate: startPlace.coordinate,
            endCoordinate: endPlace.coordinate,
            startDate: record.startDate,
            endDate: endDate,
            distanceMeters: record.distanceMeters ?? Self.totalDistance(for: locations),
            transportMode: record.transportMode
        )
        let transportMode = record.transportMode != .unknown
            ? record.transportMode
            : existing?.transportMode ?? .unknown
        let distance = (record.distanceMeters ?? 0) > 0
            ? record.distanceMeters!
            : max(Self.totalDistance(for: locations), existing?.distanceMeters ?? 0)
        let stepCount = record.stepCount ?? existing?.stepCount

        let move = try upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: record.startDate,
            endDate: endDate,
            transportMode: transportMode,
            distanceMeters: distance,
            stepCount: stepCount,
            samples: samples
        )
        move.dayTimeline = try timeline(for: record.startDate, exportedDayKey: record.dayKey)
        if let comment = record.comment, !comment.isEmpty, move.comment?.isEmpty ?? true {
            move.comment = comment
        }
        move.storeCachedRouteCoordinates(
            locations.map(\.coordinate),
            signature: "imported-archive-\(samples.count)-\(Int(distance.rounded()))"
        )
        return samples.count
    }

    private enum ImportedPlaceRole {
        case start
        case end
    }

    private func resolveImportedPlace(
        title: String?,
        date: Date,
        coordinate: CLLocationCoordinate2D?,
        exportedDayKey: String?,
        role: ImportedPlaceRole
    ) throws -> VisitPlace {
        if let coordinate, let existing = try existingPlace(at: coordinate, covering: date) {
            return existing
        }
        if let title, let named = try existingNamedPlace(title: title, near: date) {
            return named
        }
        if let coordinate {
            return try routeEndpointPlace(
                at: CLLocation(
                    coordinate: coordinate,
                    altitude: 0,
                    horizontalAccuracy: 20,
                    verticalAccuracy: -1,
                    course: -1,
                    speed: -1,
                    timestamp: date
                ),
                arrivalDate: date,
                departureDate: role == .start ? date : nil
            )
        }

        let place = VisitPlace(
            arrivalDate: date,
            departureDate: role == .start ? date : nil,
            latitude: 0,
            longitude: 0,
            horizontalAccuracy: 20,
            userLabel: title,
            autoLabel: nil
        )
        place.dayTimeline = try timeline(for: date, exportedDayKey: exportedDayKey)
        modelContext.insert(place)
        return place
    }

    private func existingPlace(
        at coordinate: CLLocationCoordinate2D,
        covering date: Date
    ) throws -> VisitPlace? {
        if let arrivedThen = try existingVisit(near: date, coordinate: coordinate) {
            return arrivedThen
        }

        let windowStart = date.addingTimeInterval(-48 * 60 * 60)
        let windowEnd = date.addingTimeInterval(Self.placeDedupeArrivalWindow)
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 64
        let candidates = try modelContext.fetch(descriptor)
        return candidates.first { place in
            Self.distanceMeters(from: coordinate, to: place.coordinate) <= Self.moveDedupeEndpointDistanceThreshold
                && placeCovers(place, at: date)
        }
    }

    private func placeCovers(_ place: VisitPlace, at date: Date) -> Bool {
        if let departure = place.departureDate {
            let start = place.arrivalDate.addingTimeInterval(-Self.placeDedupeArrivalWindow)
            let end = departure.addingTimeInterval(Self.placeDedupeDepartureWindow)
            return date >= start && date <= end
        }
        return place.arrivalDate <= date.addingTimeInterval(Self.placeDedupeArrivalWindow)
    }

    private func existingNamedPlace(title: String, near date: Date) throws -> VisitPlace? {
        let windowStart = date.addingTimeInterval(-24 * 60 * 60)
        let windowEnd = date.addingTimeInterval(24 * 60 * 60)
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
        )
        descriptor.fetchLimit = 80
        let candidates = try modelContext.fetch(descriptor)
        return candidates.first { place in
            labelsMatch(place, title: title)
        }
    }

    private func labelsMatch(_ place: VisitPlace, title: String) -> Bool {
        let labels = [place.userLabel, place.autoLabel, place.displayTitle]
        return labels.contains {
            guard let label = $0, !label.isEmpty else { return false }
            return label.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func applyArchiveMetadata(_ record: TimelineArchivePlace, to place: VisitPlace) {
        if place.userLabel?.isEmpty ?? true, let userLabel = record.userLabel, !userLabel.isEmpty {
            place.userLabel = userLabel
        }
        if place.autoLabel?.isEmpty ?? true, let autoLabel = record.autoLabel, !autoLabel.isEmpty {
            place.autoLabel = autoLabel
        }
        if place.comment?.isEmpty ?? true, let comment = record.comment, !comment.isEmpty {
            place.comment = comment
        }
        if let departure = record.departureDate {
            if let current = place.departureDate {
                place.departureDate = max(current, departure)
            } else {
                place.departureDate = departure
            }
        }
    }

    private func fillMissingDeparturesFromMoves() throws {
        let places = try modelContext.fetch(FetchDescriptor<VisitPlace>())
        for place in places where place.departureDate == nil {
            if let leave = place.outgoingMoves.min(by: { $0.startDate < $1.startDate }) {
                place.departureDate = leave.timelineStartDate
            }
        }
    }

    private static let exportedDayKeyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func timeline(for date: Date) throws -> DayTimeline {
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayKey = DayTimeline.makeDayKey(for: dayStart)

        if bulkDayTimelineCache != nil {
            if let cached = bulkDayTimelineCache?[dayKey] {
                return cached
            }
            let timeline = DayTimeline(dayStart: dayStart)
            modelContext.insert(timeline)
            bulkDayTimelineCache?[dayKey] = timeline
            return timeline
        }

        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { timeline in
                timeline.dayKey == dayKey
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let timeline = DayTimeline(dayStart: dayStart)
        modelContext.insert(timeline)
        return timeline
    }

    private func routeEndpointPlace(
        at location: CLLocation,
        arrivalDate: Date,
        departureDate: Date?
    ) throws -> VisitPlace {
        if let existing = try existingVisit(near: arrivalDate, coordinate: location.coordinate) {
            existing.horizontalAccuracy = min(existing.horizontalAccuracy, max(location.horizontalAccuracy, 20))
            if existing.departureDate == nil {
                existing.departureDate = departureDate
            }
            existing.dayTimeline = try timeline(for: arrivalDate)
            return try collapseDuplicatePlaces(around: existing)
        }

        let place = VisitPlace(
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: max(location.horizontalAccuracy, 20),
            userLabel: try inferredUserLabel(near: location.coordinate)
        )
        place.dayTimeline = try timeline(for: arrivalDate)
        modelContext.insert(place)
        return try collapseDuplicatePlaces(around: place)
    }

    private func existingVisit(near arrivalDate: Date, coordinate: CLLocationCoordinate2D) throws -> VisitPlace? {
        let windowStart = arrivalDate.addingTimeInterval(-Self.placeDedupeArrivalWindow)
        let windowEnd = arrivalDate.addingTimeInterval(Self.placeDedupeArrivalWindow)

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 8

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            Self.distanceMeters(
                from: coordinate,
                to: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            ) <= Self.placeDedupeDistanceThreshold
        }
    }

    private func findSample(byDedupeKey dedupeKey: String) throws -> LocationSample? {
        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.dedupeKey == dedupeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findNearbySample(matching location: CLLocation) throws -> LocationSample? {
        let windowStart = location.timestamp.addingTimeInterval(-Self.sampleDedupeTimeWindow)
        let windowEnd = location.timestamp.addingTimeInterval(Self.sampleDedupeTimeWindow)

        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.timestamp >= windowStart && sample.timestamp <= windowEnd
            },
            sortBy: [SortDescriptor(\LocationSample.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 24

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            Self.distanceMeters(
                from: location.coordinate,
                to: $0.coordinate
            ) <= Self.sampleDedupeDistanceThreshold
        }
    }

    private func findMove(byDedupeKey dedupeKey: String) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.dedupeKey == dedupeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findMove(startPlaceID: UUID, endPlaceID: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startPlace?.id == startPlaceID && move.endPlace?.id == endPlaceID
            },
            sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findPlace(byID placeID: UUID) throws -> VisitPlace? {
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.id == placeID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findMove(byID moveID: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.id == moveID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func deleteAllTimelineData() throws {
        let allSamples = try modelContext.fetch(FetchDescriptor<LocationSample>())
        allSamples.forEach(modelContext.delete)

        let allMoves = try modelContext.fetch(FetchDescriptor<MoveSegment>())
        allMoves.forEach(modelContext.delete)

        let allPlaces = try modelContext.fetch(FetchDescriptor<VisitPlace>())
        allPlaces.forEach(modelContext.delete)

        let allTimelines = try modelContext.fetch(FetchDescriptor<DayTimeline>())
        allTimelines.forEach(modelContext.delete)
    }

    private func findSimilarMove(
        startCoordinate: CLLocationCoordinate2D,
        endCoordinate: CLLocationCoordinate2D,
        startDate: Date,
        endDate: Date,
        distanceMeters: CLLocationDistance,
        transportMode: TransportMode
    ) throws -> MoveSegment? {
        let windowStart = startDate.addingTimeInterval(-Self.moveDedupeTimeWindow)
        let windowEnd = startDate.addingTimeInterval(Self.moveDedupeTimeWindow)

        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startDate >= windowStart && move.startDate <= windowEnd
            },
            sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 32

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first { candidate in
            isDuplicateMove(
                candidate,
                comparedToStartCoordinate: startCoordinate,
                endCoordinate: endCoordinate,
                startDate: startDate,
                endDate: endDate,
                distanceMeters: distanceMeters,
                transportMode: transportMode
            )
        }
    }

    private func collapseDuplicatePlaces(around anchor: VisitPlace) throws -> VisitPlace {
        let windowStart = anchor.arrivalDate.addingTimeInterval(-Self.placeDedupeArrivalWindow)
        let windowEnd = anchor.arrivalDate.addingTimeInterval(Self.placeDedupeArrivalWindow)

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            }
        )
        descriptor.fetchLimit = 32

        let candidates = try modelContext.fetch(descriptor)
        let duplicateGroup = candidates.filter { candidate in
            candidate.id == anchor.id || isDuplicatePlace(anchor, comparedTo: candidate)
        }

        guard duplicateGroup.count > 1 else {
            return anchor
        }

        let canonical = try canonicalPlace(from: duplicateGroup)
        for candidate in duplicateGroup where candidate.id != canonical.id {
            mergePlace(candidate, into: canonical)
            modelContext.delete(candidate)
        }

        return canonical
    }

    private func mergePlace(_ source: VisitPlace, into destination: VisitPlace) {
        if destination.departureDate == nil,
           let incoming = source.departureDate {
            destination.departureDate = incoming
        }

        if destination.userLabel?.isEmpty ?? true,
           let userLabel = source.userLabel,
           !userLabel.isEmpty {
            destination.userLabel = userLabel
        }

        if destination.autoLabel?.isEmpty ?? true,
           let autoLabel = source.autoLabel,
           !autoLabel.isEmpty {
            destination.autoLabel = autoLabel
        }

        if destination.comment?.isEmpty ?? true,
           let comment = source.comment,
           !comment.isEmpty {
            destination.comment = comment
        }

        if destination.dayTimeline == nil {
            destination.dayTimeline = source.dayTimeline
        }

        destination.horizontalAccuracy = min(destination.horizontalAccuracy, source.horizontalAccuracy)

        for move in source.outgoingMoves {
            move.startPlace = destination
        }

        for move in source.incomingMoves {
            move.endPlace = destination
        }
    }

    private struct PlaceDedupCandidateScore {
        let id: UUID
        let evidenceCount: Int
        let linkedSideCount: Int
        let fitError: TimeInterval
        let duration: TimeInterval
        let horizontalAccuracy: Double
        let createdAt: Date
    }

    private func canonicalPlace(from duplicates: [VisitPlace]) throws -> VisitPlace {
        guard duplicates.count > 1 else {
            return duplicates[0]
        }

        let nearbyMoves = try nearbyMoves(for: duplicates)
        let scoredCandidates = duplicates.map { place in
            (place, placeDedupScore(for: place, nearbyMoves: nearbyMoves))
        }

        let best = scoredCandidates.min { lhs, rhs in
            let left = lhs.1
            let right = rhs.1

            if left.evidenceCount != right.evidenceCount {
                return left.evidenceCount > right.evidenceCount
            }

            if left.evidenceCount > 0 && abs(left.fitError - right.fitError) > 1 {
                return left.fitError < right.fitError
            }

            if left.linkedSideCount != right.linkedSideCount {
                return left.linkedSideCount > right.linkedSideCount
            }

            if abs(left.duration - right.duration) > 1 {
                return left.duration > right.duration
            }

            if abs(left.horizontalAccuracy - right.horizontalAccuracy) > 0.1 {
                return left.horizontalAccuracy < right.horizontalAccuracy
            }

            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }

            return left.id.uuidString < right.id.uuidString
        }

        return best?.0 ?? duplicates[0]
    }

    private func placeDedupScore(
        for place: VisitPlace,
        nearbyMoves: [MoveSegment]
    ) -> PlaceDedupCandidateScore {
        let arrival = place.arrivalDate
        let departure = place.departureDate ?? place.arrivalDate

        let linkedIncoming = nearestDate(to: arrival, in: place.incomingMoves.map(\.endDate))
        let linkedOutgoing = nearestDate(to: departure, in: place.outgoingMoves.map(\.startDate))

        let inferredIncoming = linkedIncoming ?? nearestIncomingMoveEndDate(for: place, from: nearbyMoves)
        let inferredOutgoing = linkedOutgoing ?? nearestOutgoingMoveStartDate(for: place, from: nearbyMoves)

        var fitError: TimeInterval = 0
        var evidenceCount = 0

        if let incomingDate = inferredIncoming {
            evidenceCount += 1
            fitError += abs(incomingDate.timeIntervalSince(arrival))
        }

        if let outgoingDate = inferredOutgoing {
            evidenceCount += 1
            fitError += abs(outgoingDate.timeIntervalSince(departure))
        }

        if evidenceCount == 0 {
            fitError = .greatestFiniteMagnitude
        }

        let linkedSideCount = (linkedIncoming == nil ? 0 : 1) + (linkedOutgoing == nil ? 0 : 1)
        let duration = max(departure.timeIntervalSince(arrival), 0)

        return PlaceDedupCandidateScore(
            id: place.id,
            evidenceCount: evidenceCount,
            linkedSideCount: linkedSideCount,
            fitError: fitError,
            duration: duration,
            horizontalAccuracy: place.horizontalAccuracy,
            createdAt: place.createdAt
        )
    }

    private func nearbyMoves(for places: [VisitPlace]) throws -> [MoveSegment] {
        let arrivals = places.map(\.arrivalDate)
        let departures = places.map { $0.departureDate ?? $0.arrivalDate }

        guard let minArrival = arrivals.min(),
              let maxDeparture = departures.max() else {
            return []
        }

        let windowStart = minArrival.addingTimeInterval(-Self.placeNeighborMoveWindow)
        let windowEnd = maxDeparture.addingTimeInterval(Self.placeNeighborMoveWindow)

        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.endDate >= windowStart && move.startDate <= windowEnd
            },
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
        )
        descriptor.fetchLimit = 256
        return try modelContext.fetch(descriptor)
    }

    private func nearestIncomingMoveEndDate(
        for place: VisitPlace,
        from nearbyMoves: [MoveSegment]
    ) -> Date? {
        let coordinate = place.coordinate
        let arrival = place.arrivalDate
        let departure = place.departureDate ?? arrival
        let upperBound = departure.addingTimeInterval(Self.placeNeighborMoveInferenceSlack)

        let candidates = nearbyMoves
            .compactMap { move -> Date? in
                guard let endPlace = move.endPlace else { return nil }
                guard Self.distanceMeters(from: endPlace.coordinate, to: coordinate) <= Self.placeNeighborMoveEndpointDistanceThreshold else {
                    return nil
                }
                guard move.endDate <= upperBound else { return nil }
                return move.endDate
            }

        return nearestDate(to: arrival, in: candidates)
    }

    private func nearestOutgoingMoveStartDate(
        for place: VisitPlace,
        from nearbyMoves: [MoveSegment]
    ) -> Date? {
        let coordinate = place.coordinate
        let arrival = place.arrivalDate
        let departure = place.departureDate ?? arrival
        let lowerBound = arrival.addingTimeInterval(-Self.placeNeighborMoveInferenceSlack)

        let candidates = nearbyMoves
            .compactMap { move -> Date? in
                guard let startPlace = move.startPlace else { return nil }
                guard Self.distanceMeters(from: startPlace.coordinate, to: coordinate) <= Self.placeNeighborMoveEndpointDistanceThreshold else {
                    return nil
                }
                guard move.startDate >= lowerBound else { return nil }
                return move.startDate
            }

        return nearestDate(to: departure, in: candidates)
    }

    private func nearestDate(to target: Date, in dates: [Date]) -> Date? {
        dates.min { lhs, rhs in
            abs(lhs.timeIntervalSince(target)) < abs(rhs.timeIntervalSince(target))
        }
    }

    private func isDuplicatePlace(_ lhs: VisitPlace, comparedTo rhs: VisitPlace) -> Bool {
        let coordinateDistance = Self.distanceMeters(from: lhs.coordinate, to: rhs.coordinate)
        guard coordinateDistance <= Self.placeDedupeDistanceThreshold else {
            return false
        }

        let arrivalDelta = abs(lhs.arrivalDate.timeIntervalSince(rhs.arrivalDate))
        guard arrivalDelta <= Self.placeDedupeArrivalWindow else {
            return false
        }

        switch (lhs.departureDate, rhs.departureDate) {
        case (.none, .none):
            return true
        case let (.some(lhsDeparture), .some(rhsDeparture)):
            return abs(lhsDeparture.timeIntervalSince(rhsDeparture)) <= Self.placeDedupeDepartureWindow
        default:
            return false
        }
    }

    private func collapseDuplicateMoves(around anchor: MoveSegment) throws -> MoveSegment {
        let windowStart = anchor.startDate.addingTimeInterval(-Self.moveDedupeTimeWindow)
        let windowEnd = anchor.startDate.addingTimeInterval(Self.moveDedupeTimeWindow)

        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startDate >= windowStart && move.startDate <= windowEnd
            }
        )
        descriptor.fetchLimit = 32

        let candidates = try modelContext.fetch(descriptor)

        var canonical = anchor

        for candidate in candidates where candidate.id != canonical.id {
            guard let canonicalStartCoordinate = canonical.startPlace?.coordinate,
                  let canonicalEndCoordinate = canonical.endPlace?.coordinate else {
                continue
            }

            let isStrictDuplicate = isDuplicateMove(
                candidate,
                comparedToStartCoordinate: canonicalStartCoordinate,
                endCoordinate: canonicalEndCoordinate,
                startDate: canonical.startDate,
                endDate: canonical.endDate,
                distanceMeters: canonical.distanceMeters,
                transportMode: canonical.transportMode
            )
            let isParallelDuplicate = isLikelyParallelDuplicateMove(candidate, comparedTo: canonical)

            guard isStrictDuplicate || isParallelDuplicate else {
                continue
            }

            let preferred = preferredMove(between: canonical, and: candidate)
            if preferred.id == canonical.id {
                mergeMove(candidate, into: canonical)
                modelContext.delete(candidate)
            } else {
                mergeMove(canonical, into: candidate)
                modelContext.delete(canonical)
                canonical = candidate
            }
        }

        return canonical
    }

    private func mergeMove(_ source: MoveSegment, into destination: MoveSegment) {
        destination.startDate = min(destination.startDate, source.startDate)
        destination.endDate = max(destination.endDate, source.endDate)
        destination.distanceMeters = max(destination.distanceMeters, source.distanceMeters)

        if destination.stepCount == nil {
            destination.stepCount = source.stepCount
        } else if let sourceStepCount = source.stepCount, let destinationStepCount = destination.stepCount {
            destination.stepCount = max(destinationStepCount, sourceStepCount)
        }

        if destination.transportMode == .unknown, source.transportMode != .unknown {
            destination.transportMode = source.transportMode
        }

        if destination.comment?.isEmpty ?? true,
           let comment = source.comment,
           !comment.isEmpty {
            destination.comment = comment
        }

        if destination.startPlace == nil {
            destination.startPlace = source.startPlace
        }
        if destination.endPlace == nil {
            destination.endPlace = source.endPlace
        }
        if destination.dayTimeline == nil {
            destination.dayTimeline = source.dayTimeline
        }

        if destination.routeCacheCoordinatesData == nil,
           let sourceCoordinates = source.routeCacheCoordinatesData {
            destination.routeCacheCoordinatesData = sourceCoordinates
            destination.routeCacheSignature = source.routeCacheSignature
        }

        for sample in source.samples {
            sample.moveSegment = destination
        }
    }

    private func repairMissingStaysAroundMoves() throws {
        let places = try modelContext.fetch(
            FetchDescriptor<VisitPlace>(
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
            )
        )

        for place in places {
            guard let latestIncomingEnd = place.incomingMoves.map(\.endDate).max(),
                  let earliestOutgoingStart = place.outgoingMoves.map(\.startDate).min() else {
                continue
            }

            let gap = earliestOutgoingStart.timeIntervalSince(latestIncomingEnd)
            guard gap >= Self.synthesizedStayMinimumGap else {
                continue
            }

            let arrivalNeedsRepair = place.arrivalDate.timeIntervalSince(latestIncomingEnd) > Self.synthesizedStayTimeTolerance
            let currentDeparture = place.departureDate ?? place.arrivalDate
            let departureNeedsRepair = earliestOutgoingStart.timeIntervalSince(currentDeparture) > Self.synthesizedStayTimeTolerance

            guard arrivalNeedsRepair || departureNeedsRepair else {
                continue
            }

            if arrivalNeedsRepair {
                place.arrivalDate = latestIncomingEnd
            }
            if departureNeedsRepair {
                place.departureDate = earliestOutgoingStart
            }

            if place.dayTimeline == nil {
                place.dayTimeline = try timeline(for: place.arrivalDate)
            }
        }
    }

    private func isLikelyParallelDuplicateMove(_ candidate: MoveSegment, comparedTo anchor: MoveSegment) -> Bool {
        guard let anchorStart = anchor.startPlace?.coordinate,
              let anchorEnd = anchor.endPlace?.coordinate,
              let candidateStart = candidate.startPlace?.coordinate,
              let candidateEnd = candidate.endPlace?.coordinate else {
            return false
        }

        let startDelta = abs(candidate.startDate.timeIntervalSince(anchor.startDate))
        guard startDelta <= Self.moveParallelTimeWindow else {
            return false
        }

        let durationDelta = abs(candidate.timelineDuration - anchor.timelineDuration)
        guard durationDelta <= Self.moveParallelTimeWindow else {
            return false
        }

        let startDistance = Self.distanceMeters(from: candidateStart, to: anchorStart)
        let endDistance = Self.distanceMeters(from: candidateEnd, to: anchorEnd)
        guard startDistance <= Self.moveDedupeEndpointDistanceThreshold,
              endDistance <= Self.moveParallelEndpointDistanceThreshold else {
            return false
        }

        let distanceDelta = abs(candidate.distanceMeters - anchor.distanceMeters)
        let normalizedDistance = max(max(candidate.distanceMeters, anchor.distanceMeters), 1)
        let maxDistanceDelta = max(
            Self.moveDedupeDistanceAbsoluteThreshold,
            normalizedDistance * Self.moveDedupeDistanceRelativeThreshold
        )
        guard distanceDelta <= maxDistanceDelta else {
            return false
        }

        return areTransportModesCompatible(candidate.transportMode, anchor.transportMode)
    }

    private func preferredMove(between lhs: MoveSegment, and rhs: MoveSegment) -> MoveSegment {
        let lhsScore = moveRetentionScore(lhs)
        let rhsScore = moveRetentionScore(rhs)

        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? lhs : rhs
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt ? lhs : rhs
        }

        return lhs.id.uuidString < rhs.id.uuidString ? lhs : rhs
    }

    private func moveRetentionScore(_ move: MoveSegment) -> Int {
        guard let endPlace = move.endPlace else { return 0 }
        var score = 0

        if let label = endPlace.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            score += 4
        } else if let label = endPlace.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            score += 2
        }

        let endDuration = max((endPlace.departureDate ?? endPlace.arrivalDate).timeIntervalSince(endPlace.arrivalDate), 0)
        if endDuration > Self.moveTransientStayMaximumDuration {
            score += 3
        }

        if endPlace.outgoingMoves.count > 0 {
            score += 1
        }

        return score
    }

    private func isDuplicateMove(
        _ candidate: MoveSegment,
        comparedToStartCoordinate startCoordinate: CLLocationCoordinate2D,
        endCoordinate: CLLocationCoordinate2D,
        startDate: Date,
        endDate: Date,
        distanceMeters: CLLocationDistance,
        transportMode: TransportMode
    ) -> Bool {
        guard let candidateStart = candidate.startPlace?.coordinate,
              let candidateEnd = candidate.endPlace?.coordinate else {
            return false
        }

        let startDelta = abs(candidate.startDate.timeIntervalSince(startDate))
        guard startDelta <= Self.moveDedupeTimeWindow else {
            return false
        }

        let endDelta = abs(candidate.endDate.timeIntervalSince(endDate))
        guard endDelta <= Self.moveDedupeTimeWindow else {
            return false
        }

        let durationDelta = abs(candidate.timelineDuration - endDate.timeIntervalSince(startDate))
        guard durationDelta <= Self.moveDedupeDurationWindow else {
            return false
        }

        let startDistance = Self.distanceMeters(from: candidateStart, to: startCoordinate)
        let endDistance = Self.distanceMeters(from: candidateEnd, to: endCoordinate)
        guard startDistance <= Self.moveDedupeEndpointDistanceThreshold,
              endDistance <= Self.moveDedupeEndpointDistanceThreshold else {
            return false
        }

        let distanceDelta = abs(candidate.distanceMeters - distanceMeters)
        let normalizedDistance = max(max(candidate.distanceMeters, distanceMeters), 1)
        let maxDistanceDelta = max(
            Self.moveDedupeDistanceAbsoluteThreshold,
            normalizedDistance * Self.moveDedupeDistanceRelativeThreshold
        )
        guard distanceDelta <= maxDistanceDelta else {
            return false
        }

        return areTransportModesCompatible(candidate.transportMode, transportMode)
    }

    private func areTransportModesCompatible(_ lhs: TransportMode, _ rhs: TransportMode) -> Bool {
        if lhs == rhs { return true }
        if lhs == .unknown || rhs == .unknown { return true }

        let walkingSet: Set<TransportMode> = [.walking, .running]
        if walkingSet.contains(lhs) && walkingSet.contains(rhs) {
            return true
        }

        return false
    }

    private func normalizedArrivalDate(for visit: CLVisit) -> Date {
        if visit.arrivalDate == .distantPast {
            if let departure = normalizedDepartureDate(for: visit) {
                return departure.addingTimeInterval(-300)
            }
            return .now
        }
        return visit.arrivalDate
    }

    private func normalizedDepartureDate(for visit: CLVisit) -> Date? {
        if visit.departureDate == .distantFuture {
            return nil
        }
        return visit.departureDate
    }

    private static func makeSampleDedupeKey(for location: CLLocation) -> String {
        let roundedSecond = Int(location.timestamp.timeIntervalSince1970.rounded())
        let roundedLat = roundedCoordinate(location.coordinate.latitude)
        let roundedLon = roundedCoordinate(location.coordinate.longitude)
        return "\(roundedSecond)|\(roundedLat)|\(roundedLon)"
    }

    private static func makeMoveDedupeKey(
        startPlaceID: UUID,
        endPlaceID: UUID,
        startDate: Date,
        endDate: Date
    ) -> String {
        let startSeconds = Int(startDate.timeIntervalSince1970.rounded())
        let endSeconds = Int(endDate.timeIntervalSince1970.rounded())
        return "\(startPlaceID.uuidString)|\(endPlaceID.uuidString)|\(startSeconds)|\(endSeconds)"
    }

    private static func roundedCoordinate(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    private static func preferredSource(
        existing: LocationSampleSource,
        new: LocationSampleSource
    ) -> LocationSampleSource {
        return new.priority > existing.priority ? new : existing
    }

    private static func totalDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard locations.count > 1 else { return 0 }

        return zip(locations, locations.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + pair.0.distance(from: pair.1)
        }
    }

    private func inferredUserLabel(near coordinate: CLLocationCoordinate2D) throws -> String? {
        if let cached = bulkLabeledPlaces {
            return cached
                .map { ($0.label, Self.distanceMeters(from: coordinate, to: $0.coordinate)) }
                .filter { $0.1 <= 120 }
                .min(by: { $0.1 < $1.1 })?
                .0
        }

        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.userLabel != nil
            }
        )

        let labeledPlaces = try modelContext.fetch(descriptor)

        let nearest = labeledPlaces
            .compactMap { place -> (String, CLLocationDistance)? in
                guard let label = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                    return nil
                }

                let distance = Self.distanceMeters(
                    from: coordinate,
                    to: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                )
                return (label, distance)
            }
            .filter { $0.1 <= 120 }
            .min(by: { $0.1 < $1.1 })

        return nearest?.0
    }

    private static func distanceMeters(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right)
    }
}

#if targetEnvironment(simulator)
enum SimulatorDemoDataSeeder {
    private static var roadCoordinatesCache: [String: [CLLocationCoordinate2D]] = [:]
    private static var roadCoordinatesRequestCount = 0
    private static let roadCoordinatesRequestLimit = 20

    static func seedIfNeeded(in container: ModelContainer) {
        do {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<DayTimeline>()

            guard try context.fetch(descriptor).isEmpty else {
                return
            }

            Task { @MainActor in
                do {
                    let context = ModelContext(container)
                    try await seed(in: context)
                } catch {
                    print("Failed to seed simulator demo data: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Failed to seed simulator demo data: \(error.localizedDescription)")
        }
    }

    private static func seed(in context: ModelContext) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for (index, route) in demoRoutes.enumerated() {
            let dayOffset = demoRoutes.count - index - 1
            guard let dayStart = calendar.date(byAdding: .day, value: -dayOffset, to: today) else {
                continue
            }

            try await seed(route: route, routeIndex: index, dayStart: dayStart, calendar: calendar, context: context)
        }

        try context.save()
    }

    private static func seed(
        route: RouteBlueprint,
        routeIndex: Int,
        dayStart: Date,
        calendar: Calendar,
        context: ModelContext
    ) async throws {
        let timeline = DayTimeline(dayStart: dayStart)
        context.insert(timeline)

        let plannedStops = plannedStops(for: route)
        guard let firstMode = plannedStops.first?.transportMode else {
            return
        }

        guard let routeStart = calendar.date(
            byAdding: .minute,
            value: startOffsetMinutes(for: firstMode, routeIndex: routeIndex),
            to: dayStart
        ) else {
            return
        }

        var currentTime = routeStart
        var places: [VisitPlace] = []
        var pendingMoves: [PendingMove] = []

        for (stopIndex, plannedStop) in plannedStops.enumerated() {
            let dwellMinutes = dwellMinutes(for: routeIndex, stopIndex: stopIndex)
            let arrival = currentTime
            let departure = arrival.addingTimeInterval(TimeInterval(dwellMinutes * 60))

            let place = VisitPlace(
                arrivalDate: arrival,
                departureDate: departure,
                latitude: plannedStop.stop.coordinate.latitude,
                longitude: plannedStop.stop.coordinate.longitude,
                horizontalAccuracy: horizontalAccuracy(for: plannedStop.transportMode),
                userLabel: plannedStop.stop.label
            )
            place.dayTimeline = timeline
            context.insert(place)
            places.append(place)

            currentTime = departure

            guard stopIndex < plannedStops.count - 1 else {
                continue
            }

            let nextStop = plannedStops[stopIndex + 1]
            let legGeometry = await makeLegGeometry(
                from: plannedStop.stop.coordinate,
                to: nextStop.stop.coordinate,
                routeIndex: routeIndex,
                legIndex: stopIndex,
                mode: nextStop.transportMode
            )
            let travelDurationMinutes = travelDurationMinutes(
                for: legGeometry.distanceMeters,
                mode: nextStop.transportMode
            )
            let moveStart = departure
            let moveEnd = departure.addingTimeInterval(TimeInterval(travelDurationMinutes * 60))
            let samples = makeSamples(
                from: legGeometry.coordinates,
                moveStart: moveStart,
                moveEnd: moveEnd,
                routeIndex: routeIndex,
                legIndex: stopIndex,
                mode: nextStop.transportMode
            )

            pendingMoves.append(
                PendingMove(
                    startIndex: stopIndex,
                    endIndex: stopIndex + 1,
                    startDate: moveStart,
                    endDate: moveEnd,
                    transportMode: nextStop.transportMode,
                    distanceMeters: legGeometry.distanceMeters,
                    stepCount: stepCount(for: legGeometry.distanceMeters, mode: nextStop.transportMode),
                    samples: samples
                )
            )

            currentTime = moveEnd
        }

        for (moveIndex, pendingMove) in pendingMoves.enumerated() {
            let move = MoveSegment(
                dedupeKey: moveDedupeKey(
                    routeIndex: routeIndex,
                    moveIndex: moveIndex,
                    startDate: pendingMove.startDate,
                    endDate: pendingMove.endDate
                ),
                startDate: pendingMove.startDate,
                endDate: pendingMove.endDate,
                transportMode: pendingMove.transportMode,
                distanceMeters: pendingMove.distanceMeters,
                stepCount: pendingMove.stepCount
            )
            move.startPlace = places[pendingMove.startIndex]
            move.endPlace = places[pendingMove.endIndex]
            move.dayTimeline = timeline
            context.insert(move)

            for sample in pendingMove.samples {
                sample.dayTimeline = timeline
                sample.moveSegment = move
                context.insert(sample)
            }
        }
    }

    private static func makeLegGeometry(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        routeIndex: Int,
        legIndex: Int,
        mode: TransportMode
    ) async -> LegGeometry {
        let directDistance = distanceMeters(from: start, to: end)
        let sampleCount = max(4, min(7, Int(directDistance / 850) + 4))
        let bendDirection = ((routeIndex + legIndex) % 2 == 0) ? 1.0 : -1.0
        let bendStrength = 0.10 + Double((routeIndex + legIndex) % 3) * 0.03

        let pathCoordinates = await roadCoordinates(
            from: start,
            to: end,
            mode: mode
        ) ?? curvedPoints(
            from: start,
            to: end,
            count: sampleCount,
            bendDirection: bendDirection,
            bendStrength: bendStrength
        )

        let coordinates = sampleCoordinates(
            from: pathCoordinates,
            maximumCount: sampleCount
        )
        let distanceMeters = pathDistance(for: [start] + pathCoordinates + [end])

        return LegGeometry(coordinates: coordinates, distanceMeters: distanceMeters)
    }

    private static func makeSamples(
        from coordinates: [CLLocationCoordinate2D],
        moveStart: Date,
        moveEnd: Date,
        routeIndex: Int,
        legIndex: Int,
        mode: TransportMode
    ) -> [LocationSample] {
        guard !coordinates.isEmpty else { return [] }

        let duration = moveEnd.timeIntervalSince(moveStart)
        let sampleSpeed = speedMetersPerSecond(for: mode)

        return coordinates.enumerated().map { index, coordinate in
            let fraction = Double(index + 1) / Double(coordinates.count + 1)
            let timestamp = moveStart.addingTimeInterval(duration * fraction)
            let location = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: horizontalAccuracy(for: mode),
                verticalAccuracy: -1,
                course: -1,
                speed: sampleSpeed,
                timestamp: timestamp
            )

            return LocationSample(
                location: location,
                source: .significantChange,
                dedupeKey: "demo-leg-\(routeIndex)-\(legIndex)-\(index)"
            )
        }
    }

    private static func roadCoordinates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TransportMode
    ) async -> [CLLocationCoordinate2D]? {
        let cacheKey = roadCoordinatesCacheKey(from: start, to: end, mode: mode)
        if let cached = roadCoordinatesCache[cacheKey] {
            return cached
        }

        guard roadCoordinatesRequestCount < roadCoordinatesRequestLimit else {
            return nil
        }

        let transportTypes = mapTransportTypes(for: mode)
        guard !transportTypes.isEmpty else {
            return nil
        }

        roadCoordinatesRequestCount += 1

        for transportType in transportTypes {
            guard await DirectionsRequestLimiter.shared.reserveSlot() else {
                return nil
            }

            let request = MKDirections.Request()
            request.source = mapItem(for: start)
            request.destination = mapItem(for: end)
            request.transportType = transportType
            request.requestsAlternateRoutes = false

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else {
                    continue
                }

                let coordinates = polylineCoordinates(route.polyline)
                guard coordinates.count > 1 else {
                    continue
                }

                roadCoordinatesCache[cacheKey] = coordinates
                return coordinates
            } catch {
                let throttled = await DirectionsRequestLimiter.shared.registerFailure(error)
                if throttled {
                    return nil
                }
                continue
            }
        }

        return nil
    }

    private static func roadCoordinatesCacheKey(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TransportMode
    ) -> String {
        [
            mode.rawValue,
            String(format: "%.4f", start.latitude),
            String(format: "%.4f", start.longitude),
            String(format: "%.4f", end.latitude),
            String(format: "%.4f", end.longitude)
        ]
        .joined(separator: "|")
    }

    private static func curvedPoints(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        count: Int,
        bendDirection: Double,
        bendStrength: Double
    ) -> [CLLocationCoordinate2D] {
        guard count > 0 else { return [] }

        let latDelta = end.latitude - start.latitude
        let lonDelta = end.longitude - start.longitude
        let scale = max(abs(latDelta), abs(lonDelta))
        let perpendicularLat = -lonDelta
        let perpendicularLon = latDelta

        return (1...count).map { index in
            let t = Double(index) / Double(count + 1)
            let wave = sin(.pi * t)
            let offset = scale * bendStrength * wave * bendDirection

            return CLLocationCoordinate2D(
                latitude: start.latitude + (latDelta * t) + (perpendicularLat * offset),
                longitude: start.longitude + (lonDelta * t) + (perpendicularLon * offset)
            )
        }
    }

    private static func sampleCoordinates(
        from coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else {
            return coordinates
        }

        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            let rawIndex = Int((Double(index) * step).rounded(.toNearestOrAwayFromZero))
            return coordinates[min(rawIndex, coordinates.count - 1)]
        }
    }

    private static func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }

        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    private static func pathDistance(for coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }

        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + distanceMeters(from: pair.0, to: pair.1)
        }
    }

    private static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right)
    }

    private static func travelDurationMinutes(
        for distanceMeters: CLLocationDistance,
        mode: TransportMode
    ) -> Int {
        let metersPerMinute: Double
        let minimumMinutes: Int

        switch mode {
        case .walking:
            metersPerMinute = 85
            minimumMinutes = 12
        case .running:
            metersPerMinute = 180
            minimumMinutes = 8
        case .cycling:
            metersPerMinute = 260
            minimumMinutes = 10
        case .swimming:
            metersPerMinute = 55
            minimumMinutes = 12
        case .automotive:
            metersPerMinute = 700
            minimumMinutes = 12
        case .train:
            metersPerMinute = 1_200
            minimumMinutes = 14
        case .plane:
            metersPerMinute = 6_000
            minimumMinutes = 25
        case .boat, .stationary, .unknown:
            metersPerMinute = 85
            minimumMinutes = 12
        }

        let estimatedMinutes = Int((distanceMeters / metersPerMinute).rounded(.up))
        return max(estimatedMinutes, minimumMinutes)
    }

    private static func stepCount(
        for distanceMeters: CLLocationDistance,
        mode: TransportMode
    ) -> Int? {
        switch mode {
        case .walking:
            return max(Int((distanceMeters / 0.76).rounded()), 0)
        case .running:
            return max(Int((distanceMeters / 1.02).rounded()), 0)
        case .swimming, .cycling, .automotive, .train, .plane, .boat, .stationary, .unknown:
            return nil
        }
    }

    private static func speedMetersPerSecond(for mode: TransportMode) -> Double {
        switch mode {
        case .walking:
            return 1.4
        case .running:
            return 3.0
        case .swimming:
            return 1.2
        case .cycling:
            return 4.6
        case .automotive:
            return 11.5
        case .train:
            return 28
        case .plane:
            return 140
        case .boat, .stationary, .unknown:
            return 1.0
        }
    }

    private static func horizontalAccuracy(for mode: TransportMode) -> Double {
        switch mode {
        case .walking, .running:
            return 16
        case .swimming:
            return 22
        case .cycling:
            return 20
        case .automotive:
            return 24
        case .train:
            return 28
        case .plane:
            return 40
        case .boat, .stationary, .unknown:
            return 18
        }
    }

    private static func startOffsetMinutes(
        for mode: TransportMode,
        routeIndex: Int
    ) -> Int {
        let baseMinutes: Int

        switch mode {
        case .running:
            baseMinutes = 6 * 60 + 40
        case .walking:
            baseMinutes = 8 * 60 + 15
        case .cycling:
            baseMinutes = 9 * 60 + 5
        case .swimming:
            baseMinutes = 12 * 60 + 25
        case .automotive:
            baseMinutes = 10 * 60 + 20
        case .train:
            baseMinutes = 7 * 60 + 50
        case .plane:
            baseMinutes = 11 * 60 + 10
        case .boat, .stationary, .unknown:
            baseMinutes = 8 * 60
        }

        return baseMinutes + ((routeIndex % 3) * 14)
    }

    private static func dwellMinutes(
        for routeIndex: Int,
        stopIndex: Int
    ) -> Int {
        let pattern = [24, 36, 28, 42]
        return pattern[(routeIndex + stopIndex) % pattern.count]
    }

    private static func moveDedupeKey(
        routeIndex: Int,
        moveIndex: Int,
        startDate: Date,
        endDate: Date
    ) -> String {
        let startSeconds = Int(startDate.timeIntervalSince1970.rounded())
        let endSeconds = Int(endDate.timeIntervalSince1970.rounded())
        return "demo|\(routeIndex)|\(moveIndex)|\(startSeconds)|\(endSeconds)"
    }

    private static func route(
        _ title: String,
        mode: TransportMode,
        _ stops: [RouteStop]
    ) -> RouteBlueprint {
        RouteBlueprint(title: title, stages: [stage(mode, stops)])
    }

    private static func route(
        _ title: String,
        stages: [RouteStage]
    ) -> RouteBlueprint {
        RouteBlueprint(title: title, stages: stages)
    }

    private static func stage(
        _ mode: TransportMode,
        _ stops: [RouteStop]
    ) -> RouteStage {
        RouteStage(transportMode: mode, stops: stops)
    }

    private static func plannedStops(for route: RouteBlueprint) -> [PlannedStop] {
        route.stages.flatMap { stage in
            stage.stops.map { stop in
                PlannedStop(stop: stop, transportMode: stage.transportMode)
            }
        }
    }

    private static func stop(
        _ label: String,
        _ latitude: Double,
        _ longitude: Double
    ) -> RouteStop {
        RouteStop(
            label: label,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private static let demoRoutes: [RouteBlueprint] = [
        route(
            "Amsterdam Canal Ring Cycle",
            mode: .cycling,
            [
                stop("Rijksmuseum", 52.359997, 4.885218),
                stop("Vondelpark", 52.358400, 4.868500),
                stop("De Hallen", 52.367200, 4.873300),
                stop("NDSM Wharf", 52.408400, 4.894900)
            ]
        ),
        route(
            "Paris Left Bank Drift",
            mode: .walking,
            [
                stop("Jardin du Luxembourg", 48.846200, 2.337200),
                stop("Shakespeare and Company", 48.852800, 2.347000),
                stop("Musee d'Orsay", 48.860000, 2.326600),
                stop("Eiffel Tower", 48.858400, 2.294500)
            ]
        ),
        route(
            "London South Bank Loop",
            mode: .walking,
            [
                stop("Tower Bridge", 51.505500, -0.075400),
                stop("Tate Modern", 51.507600, -0.099400),
                stop("Covent Garden", 51.512900, -0.124800),
                stop("Regent's Park", 51.531300, -0.156900)
            ]
        ),
        route(
            "Barcelona Coast and Crest",
            mode: .cycling,
            [
                stop("Sagrada Familia", 41.403600, 2.174400),
                stop("Gothic Quarter", 41.383900, 2.176000),
                stop("Barceloneta", 41.378500, 2.192900),
                stop("Park Guell", 41.414500, 2.152700)
            ]
        ),
        route(
            "Rome Ancient-to-River Walk",
            mode: .walking,
            [
                stop("Colosseum", 41.890200, 12.492200),
                stop("Piazza Venezia", 41.895500, 12.482300),
                stop("Trastevere", 41.889500, 12.470800),
                stop("Vatican Museums", 41.906500, 12.453600)
            ]
        ),
        route(
            "Copenhagen Harbor Hop",
            mode: .cycling,
            [
                stop("Nyhavn", 55.679800, 12.589200),
                stop("Christianshavn", 55.673600, 12.599900),
                stop("Designmuseum Danmark", 55.692900, 12.581900),
                stop("CopenHill", 55.696000, 12.589400)
            ]
        ),
        route(
            "New York High Line Circuit",
            mode: .walking,
            [
                stop("Hudson Yards", 40.754000, -74.001800),
                stop("Chelsea Market", 40.742300, -74.006000),
                stop("The Met", 40.779400, -73.963200),
                stop("Central Park South", 40.766100, -73.977600)
            ]
        ),
        route(
            "Tokyo Neon Loop",
            mode: .walking,
            [
                stop("Shibuya Crossing", 35.659500, 139.700500),
                stop("Meiji Jingu", 35.676400, 139.699300),
                stop("Akihabara", 35.698400, 139.773000),
                stop("Asakusa Senso-ji", 35.714800, 139.796700)
            ]
        ),
        route(
            "Kyoto Temple Run",
            mode: .running,
            [
                stop("Arashiyama Bamboo Grove", 35.009400, 135.671800),
                stop("Tenryu-ji", 35.016900, 135.670400),
                stop("Kinkaku-ji", 35.039400, 135.729200),
                stop("Fushimi Inari", 34.967100, 135.772700)
            ]
        ),
        route(
            "Singapore Bay Orbit",
            mode: .walking,
            [
                stop("Gardens by the Bay", 1.281600, 103.863600),
                stop("Marina Bay Sands", 1.283400, 103.860000),
                stop("Chinatown", 1.283700, 103.843100),
                stop("Little India", 1.306600, 103.849500)
            ]
        ),
        route(
            "San Francisco Hills Tour",
            mode: .cycling,
            [
                stop("Ferry Building", 37.795500, -122.393700),
                stop("Coit Tower", 37.802400, -122.405800),
                stop("Lombard Street", 37.802100, -122.418700),
                stop("Golden Gate Bridge Vista", 37.819900, -122.478300)
            ]
        ),
        route(
            "Kona Ironman Bike + Marathon",
            stages: [
                stage(
                    .cycling,
                    [
                        stop("Kailua Pier", 19.639400, -155.996000),
                        stop("Queen K Highway", 19.623500, -155.972000),
                        stop("Keauhou Bay", 19.558000, -155.964800),
                        stop("Waikoloa Beach", 19.938600, -155.859000),
                        stop("Hawi Turnaround", 20.239600, -155.822200),
                        stop("T2 / Kailua Pier", 19.639400, -155.996000)
                    ]
                ),
                stage(
                    .running,
                    [
                        stop("Alii Drive Sunrise", 19.637900, -155.989300),
                        stop("Natural Energy Lab", 19.615200, -155.987400),
                        stop("Palani Road Climb", 19.643300, -155.980900),
                        stop("Kailua Pier Finish", 19.639400, -155.996000)
                    ]
                )
            ]
        ),
        route(
            "Las Vegas Heist Escape",
            mode: .automotive,
            [
                stop("Bellagio", 36.112600, -115.177100),
                stop("Caesars Palace", 36.116300, -115.174500),
                stop("The Venetian", 36.121100, -115.171300),
                stop("Fremont Street", 36.170900, -115.140900),
                stop("Harry Reid Airport", 36.084000, -115.153700)
            ]
        ),
        route(
            "Istanbul Bosphorus Crossing",
            mode: .walking,
            [
                stop("Hagia Sophia", 41.008600, 28.980200),
                stop("Grand Bazaar", 41.010500, 28.968000),
                stop("Galata Bridge", 41.019800, 28.973500),
                stop("Kadikoy Pier", 40.990900, 29.026200)
            ]
        ),
        route(
            "Mexico City Culture Arc",
            mode: .cycling,
            [
                stop("Zocalo", 19.432600, -99.133200),
                stop("Alameda Central", 19.435200, -99.141500),
                stop("Chapultepec", 19.420400, -99.181200),
                stop("Coyoacan", 19.349900, -99.162100)
            ]
        ),
        route(
            "Rio Skyline Loop",
            mode: .automotive,
            [
                stop("Copacabana", -22.971100, -43.182200),
                stop("Sugarloaf", -22.948600, -43.158300),
                stop("Santa Teresa", -22.917700, -43.189700),
                stop("Christ the Redeemer", -22.951900, -43.210500)
            ]
        ),
        route(
            "Monaco Grand Prix Circuit",
            mode: .automotive,
            [
                stop("Casino Square", 43.739700, 7.428900),
                stop("Fairmont Hairpin", 43.737000, 7.430600),
                stop("Tunnel", 43.734500, 7.426900),
                stop("Port Hercule", 43.733000, 7.421000),
                stop("Tabac Corner", 43.732000, 7.423300),
                stop("La Rascasse", 43.731300, 7.424900)
            ]
        ),
        route(
            "Boston Marathon Finish Push",
            mode: .running,
            [
                stop("Hopkinton Center", 42.215000, -71.515000),
                stop("Wellesley College", 42.295000, -71.292000),
                stop("Heartbreak Hill", 42.333300, -71.212000),
                stop("Boston College", 42.335200, -71.168000),
                stop("Kenmore Square", 42.348000, -71.095000),
                stop("Copley Square", 42.350600, -71.076000)
            ]
        ),
        route(
            "Seoul Palace-to-River Loop",
            mode: .walking,
            [
                stop("Gyeongbokgung", 37.579600, 126.977000),
                stop("Insadong", 37.574000, 126.986400),
                stop("Dongdaemun Design Plaza", 37.566400, 127.009600),
                stop("Banpo Bridge", 37.516500, 126.996300)
            ]
        ),
        route(
            "Sydney Harbour Sweep",
            mode: .running,
            [
                stop("Circular Quay", -33.861100, 151.210900),
                stop("Opera House", -33.856800, 151.215300),
                stop("Royal Botanic Garden", -33.864700, 151.216800),
                stop("Bondi Beach", -33.890800, 151.274300)
            ]
        )
    ]

    private struct RouteBlueprint {
        let title: String
        let stages: [RouteStage]
    }

    private struct RouteStage {
        let transportMode: TransportMode
        let stops: [RouteStop]
    }

    private struct RouteStop {
        let label: String
        let coordinate: CLLocationCoordinate2D
    }

    private struct PlannedStop {
        let stop: RouteStop
        let transportMode: TransportMode
    }

    private struct PendingMove {
        let startIndex: Int
        let endIndex: Int
        let startDate: Date
        let endDate: Date
        let transportMode: TransportMode
        let distanceMeters: CLLocationDistance
        let stepCount: Int?
        let samples: [LocationSample]
    }

    private struct LegGeometry {
        let coordinates: [CLLocationCoordinate2D]
        let distanceMeters: CLLocationDistance
    }

    private static func mapItem(for coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #unavailable(iOS 26.0) {
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return MKMapItem(location: location, address: nil)
    }

    private static func mapTransportTypes(for mode: TransportMode) -> [MKDirectionsTransportType] {
        switch mode {
        case .automotive:
            // Some POI points are inside buildings, so walking fallback improves route seeding.
            return [.automobile, .walking]
        case .walking, .running:
            return [.walking]
        case .cycling:
            return [.cycling, .walking]
        case .swimming:
            return []
        case .train:
            return [.transit, .automobile]
        case .plane:
            return []
        case .boat, .stationary, .unknown:
            return []
        }
    }
}
#endif
