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

    /// Short sentence-case label for compact filter chips (`Walk 5h 35m`).
    var chipTitle: String {
        switch self {
        case .stationary: return String(localized: "Still")
        case .walking: return String(localized: "Walk")
        case .running: return String(localized: "Run")
        case .swimming: return String(localized: "Swim")
        case .cycling: return String(localized: "Bike")
        case .automotive: return String(localized: "Drive")
        case .train: return String(localized: "Train")
        case .plane: return String(localized: "Fly")
        case .boat: return String(localized: "Boat")
        case .unknown: return String(localized: "Move")
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
    /// A geotagged photo from the user's library. Not a route track.
    case photoLibrary
    /// A photo taken with this phone's camera, checked against the phone's own fixes.
    /// Unlike `.photoLibrary` history, it counts toward stops and trips.
    case cameraPhoto
    /// Imported from Google Timeline (Records, Semantic Location History, or on-device JSON).
    case googleTimelineImport
    /// Reserved for a future Arc Timeline importer; stored as a string so existing rows stay valid.
    case arcImport
    /// Fixes recorded automatically while following a trip (Balanced or Detailed capture).
    case continuous
}

extension LocationSampleSource {
    /// History brought in from a file rather than recorded here. New visits and moves made
    /// from it are marked `.imported`, which keeps them out of automatic uploads and repair.
    var isHistoryImport: Bool {
        switch self {
        case .fileRouteImport, .googleTimelineImport, .arcImport:
            return true
        case .visit, .significantChange, .routeTracking, .watchRouteTracking, .watchSignificantChange,
             .healthWorkoutRoute, .launchBackfill, .authorizationGrant, .lastMile, .photoLibrary, .cameraPhoto,
             .continuous:
            return false
        }
    }

    var priority: Int {
        switch self {
        case .fileRouteImport, .googleTimelineImport, .arcImport: return 7
        case .watchRouteTracking: return 6
        case .healthWorkoutRoute: return 5
        case .routeTracking: return 4
        case .visit: return 3
        case .watchSignificantChange: return 2
        case .significantChange, .cameraPhoto: return 2
        case .authorizationGrant, .photoLibrary: return 1
        case .launchBackfill: return 0
        case .lastMile: return 4
        case .continuous: return 4
        }
    }

    var isRouteTrack: Bool {
        switch self {
        case .routeTracking, .watchRouteTracking, .healthWorkoutRoute, .fileRouteImport, .lastMile, .continuous, .googleTimelineImport, .arcImport:
            return true
        case .visit, .significantChange, .watchSignificantChange, .launchBackfill, .authorizationGrant, .photoLibrary, .cameraPhoto:
            return false
        }
    }

    var preservesRouteResolution: Bool {
        switch self {
        case .healthWorkoutRoute, .watchRouteTracking, .fileRouteImport, .lastMile, .continuous, .googleTimelineImport, .arcImport:
            return true
        case .routeTracking, .visit, .significantChange, .watchSignificantChange, .launchBackfill, .authorizationGrant, .photoLibrary, .cameraPhoto:
            return false
        }
    }
}

/// How a visit was attached to a `KnownPlace`.
enum PlaceAssignmentSource: String, Codable, CaseIterable {
    case none
    case user
    case auto
    case autoAmbiguous
}

/// Where a visit or move originally came from.
enum TimelineItemOrigin: String, Codable, CaseIterable {
    case sensor
    case imported
    case photoInferred
    case manual
}

/// Whether a timeline item is waiting for the user to confirm or dismiss it.
enum ReviewState: String, Codable, CaseIterable {
    case none
    case pending
    case confirmed
    case dismissed
}

/// How a move's path should be drawn and matched.
enum RouteMatchPolicy: String, Codable, CaseIterable {
    case auto
    case recorded
    case roads
    case manual
}

/// Honesty of the displayed path, independent of how the user asked to draw it.
enum RouteMatchConfidence: String, Codable, CaseIterable {
    case recorded
    case high
    case medium
    case estimated
    case unknown
}

/// Who chose the transport mode on a move.
enum TransportModeSource: String, Codable, CaseIterable {
    case auto
    case user
    case imported
}

/// Failures from timeline edits that the UI can present without exposing store details.
enum TimelineEditingError: Error, Equatable {
    case missingNeighbors
    case invalidSplitTime
    case invalidTimeRange
    case cannotMergeSameVisit
    case visitNotFound
    case moveNotFound
}

/// Outcome of removing a visit that sat between two moves.
enum DissolveVisitResult {
    /// Same-mode legs became one move that includes the stop’s duration.
    case merged(MoveSegment)
    /// Different-mode legs stay separate and meet at the join time.
    case connected(incoming: MoveSegment, outgoing: MoveSegment)

    /// Moves whose polylines should be rematched after the visit is gone.
    var movesNeedingRouteRefresh: [MoveSegment] {
        switch self {
        case .merged(let move):
            return [move]
        case .connected(let incoming, let outgoing):
            return [incoming, outgoing]
        }
    }
}

/// Models in the CloudKit-backed (or local fallback) timeline store.
enum MovesTimelineSchema {
    static let models: [any PersistentModel.Type] = [
        DayTimeline.self,
        VisitPlace.self,
        MoveSegment.self,
        LocationSample.self,
        KnownPlace.self,
        PhotoAttachment.self,
        PlaceCorrectionEvent.self,
        VisitedCell.self,
        NamedTrip.self,
        RemovedTimelineSpan.self,
    ]
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

    @Relationship(deleteRule: .cascade, inverse: \PhotoAttachment.dayTimeline)
    var photosStorage: [PhotoAttachment]? = nil

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

    var photos: [PhotoAttachment] {
        get { photosStorage ?? [] }
        set { photosStorage = newValue }
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

    /// The day `date` falls on where it happened: its key and midnight in `timeZone`.
    init(containing date: Date, in timeZone: TimeZone) {
        self.dayStart = TimelineDayFiling.startOfDay(for: date, in: timeZone)
        self.dayKey = TimelineDayFiling.dayKey(for: date, in: timeZone)
        self.createdAt = .now
    }

    /// Reads the time zone on every call: a formatter would keep the zone the process
    /// launched in, and after a flight would file today under yesterday.
    static func makeDayKey(for date: Date) -> String {
        TimelineDayFiling.dayKey(for: date, in: Calendar.current.timeZone)
    }

    /// The key of the day `date` falls on in `timeZone`.
    static func makeDayKey(for date: Date, in timeZone: TimeZone) -> String {
        TimelineDayFiling.dayKey(for: date, in: timeZone)
    }
}

extension DayTimeline {
    /// This day's date on `calendar`: midnight of `dayKey` in the calendar's zone.
    ///
    /// `dayStart` is midnight where the day happened, so a day east of the phone's zone
    /// starts on the phone's previous date. Anything that groups, labels, or compares
    /// days by date reads this, never `dayStart` converted on the phone's clock.
    func calendarDate(in calendar: Calendar = .current) -> Date {
        TimelineDayFiling.startOfDay(forKey: dayKey, in: calendar.timeZone) ?? calendar.startOfDay(for: dayStart)
    }

    var hasRecordedActivity: Bool {
        !places.isEmpty || !moves.isEmpty || !samples.isEmpty
    }

    /// The clock a day is read on: the zone where its first stay, trip, or fix happened.
    /// Today, and a day with nothing on it, read on the phone's own clock.
    var placeTimeZone: TimeZone {
        guard dayKey != DayTimeline.makeDayKey(for: .now) else { return Calendar.current.timeZone }
        let firstPlace = places.min { $0.arrivalDate < $1.arrivalDate }
        let firstMove = moves.min { $0.startDate < $1.startDate }
        return DayTimeline.clock(
            dayKey: dayKey,
            firstStay: firstPlace.map { ($0.arrivalDate, $0.coordinate) },
            firstTripStart: firstMove.flatMap { move in move.startPlace.map { (move.startDate, $0.coordinate) } },
            firstFix: {
                guard let fix = samples.min(by: { $0.timestamp < $1.timestamp }) else { return nil }
                return CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            }
        )
    }

    /// `placeTimeZone` from values already copied off the store, for readers that walk
    /// every day at once: the first stay or trip start that day, else its first fix.
    static func clock(
        dayKey: String,
        firstStay: (Date, CLLocationCoordinate2D)?,
        firstTripStart: (Date, CLLocationCoordinate2D)?,
        firstFix: () -> CLLocationCoordinate2D? = { nil }
    ) -> TimeZone {
        let phone = Calendar.current.timeZone
        guard dayKey != DayTimeline.makeDayKey(for: .now) else { return phone }
        let candidates = [firstStay, firstTripStart].compactMap { $0 }
        if let first = candidates.min(by: { $0.0 < $1.0 }), let zone = PlaceTimeZone.timeZone(at: first.1) {
            return zone
        }
        if let fix = firstFix(), let zone = PlaceTimeZone.timeZone(at: fix) {
            return zone
        }
        return phone
    }

    /// The zone's short name ("PDT") when this day's clock is not the phone's, else nil.
    var foreignTimeZoneAbbreviation: String? {
        PlaceClock.foreignAbbreviation(of: placeTimeZone, at: dayStart.addingTimeInterval(12 * 3600))
    }

    /// The last known place from an earlier day, used when nothing was recorded on this day
    /// (for example when the user never left home) so the day still shows where they were.
    var carriedOverPlace: VisitPlace? {
        guard !hasRecordedActivity, let modelContext else { return nil }

        let start = dayStart
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < start && place.dayTimeline != nil
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
    var assignmentSourceRaw: String = PlaceAssignmentSource.none.rawValue
    var assignmentConfidence: Double = 0
    var originRaw: String = TimelineItemOrigin.sensor.rawValue
    var isHiddenAsShortStop: Bool = false
    var countryCode: String? = nil
    var locality: String? = nil
    var administrativeArea: String? = nil
    /// Street name from reverse geocode, used by Places suggestions.
    var thoroughfare: String? = nil
    /// Formatted mailing address from reverse geocode.
    var formattedAddress: String? = nil
    var reviewStateRaw: String = ReviewState.none.rawValue

    var dayTimeline: DayTimeline?
    var knownPlace: KnownPlace?

    @Relationship(deleteRule: .cascade, inverse: \PhotoAttachment.visitPlace)
    var photoAttachmentsStorage: [PhotoAttachment]? = nil

    @Relationship(originalName: "outgoingMoves", inverse: \MoveSegment.startPlace)
    var outgoingMovesStorage: [MoveSegment]? = nil

    @Relationship(originalName: "incomingMoves", inverse: \MoveSegment.endPlace)
    var incomingMovesStorage: [MoveSegment]? = nil

    /// Trips on the timeline that leave this stay. Retiring a trip detaches it already;
    /// this also leaves out one a stale edit attached again.
    var outgoingMoves: [MoveSegment] {
        get { (outgoingMovesStorage ?? []).filter { !TimelineRetirement.isRetired($0) } }
        set { outgoingMovesStorage = newValue }
    }

    var incomingMoves: [MoveSegment] {
        get { (incomingMovesStorage ?? []).filter { !TimelineRetirement.isRetired($0) } }
        set { incomingMovesStorage = newValue }
    }

    var photoAttachments: [PhotoAttachment] {
        get { photoAttachmentsStorage ?? [] }
        set { photoAttachmentsStorage = newValue }
    }

    var assignmentSource: PlaceAssignmentSource {
        get { PlaceAssignmentSource(rawValue: assignmentSourceRaw) ?? .none }
        set { assignmentSourceRaw = newValue.rawValue }
    }

    var origin: TimelineItemOrigin {
        get { TimelineItemOrigin(rawValue: originRaw) ?? .sensor }
        set { originRaw = newValue.rawValue }
    }

    var reviewState: ReviewState {
        get { ReviewState(rawValue: reviewStateRaw) ?? .none }
        set { reviewStateRaw = newValue.rawValue }
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

    /// The stay's name on the timeline, its day map, and the trips to and from it: the
    /// learned place first, then `displayTitle`, so coordinates show only when nothing is known.
    var timelineTitle: String {
        let known = knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return known.isEmpty ? displayTitle : known
    }

    /// Inclusive stay interval used by time-of-day lookup. Open-ended visits
    /// cover from arrival until the next outgoing move (or indefinitely).
    func covers(_ date: Date) -> Bool {
        guard date >= arrivalDate else { return false }
        if let departureDate {
            if departureDate <= arrivalDate {
                return abs(date.timeIntervalSince(arrivalDate)) < 0.5
            }
            return date <= departureDate
        }
        if let outgoingStart = outgoingMoves.map(\.startDate).min(), date >= outgoingStart {
            return false
        }
        return true
    }

    /// True when the storyline should render this visit as a compact short stop.
    var appearsAsShortStop: Bool {
        if isHiddenAsShortStop {
            return true
        }
        guard let dayTimeline else { return false }
        return matchesShortStopHeuristic(in: dayTimeline)
    }

    /// The current storyline short-stop heuristic, copied so upgrades and the
    /// day list stay aligned until WS1 reads `isHiddenAsShortStop` directly.
    func matchesShortStopHeuristic(in dayTimeline: DayTimeline) -> Bool {
        let trimmedLabel = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLabel.isEmpty {
            return false
        }

        let hasIncomingMove = dayTimeline.moves.contains { $0.endPlace?.id == id }
        let hasOutgoingMove = dayTimeline.moves.contains { $0.startPlace?.id == id }

        if departureDate == nil {
            return hasOutgoingMove
        }

        guard let departureDate else { return false }
        let duration = departureDate.timeIntervalSince(arrivalDate)
        let isShortTransitStop = duration < VisitPlace.transientStopMaximumDuration
        return isShortTransitStop && hasIncomingMove && hasOutgoingMove
    }

    static let transientStopMaximumDuration: TimeInterval = 5 * 60
}

extension VisitPlace {
    /// Call before deleting this visit: photos cascade with it, but they still belong to the day.
    func keepPhotosOnDay() {
        for photo in photoAttachments {
            if photo.dayTimeline == nil {
                photo.dayTimeline = dayTimeline
            }
            photo.visitPlace = nil
        }
    }
}

extension VisitPlace {
    fileprivate var locationKey: String {
        Self.locationKey(latitude: latitude, longitude: longitude)
    }

    static func locationKey(latitude: Double, longitude: Double) -> String {
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
    var routeMatchPolicyRaw: String = RouteMatchPolicy.auto.rawValue
    var routeMatchConfidenceRaw: String = RouteMatchConfidence.unknown.rawValue
    var routeMatchSummary: String? = nil
    var transportModeSourceRaw: String = TransportModeSource.auto.rawValue
    var originRaw: String = TimelineItemOrigin.sensor.rawValue
    var speedProfileData: Data? = nil
    var reviewStateRaw: String = ReviewState.none.rawValue

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

    /// "Home to Corner café": the trip row and the trip's detail screen both read this.
    var timelineTitle: String {
        let start = startPlace?.timelineTitle ?? String(localized: "Unknown start")
        let end = endPlace?.timelineTitle ?? String(localized: "Unknown destination")
        return "\(start) to \(end)"
    }

    var transportMode: TransportMode {
        get { TransportMode(rawValue: transportModeRawValue) ?? .unknown }
        set { transportModeRawValue = newValue.rawValue }
    }

    var routeMatchPolicy: RouteMatchPolicy {
        get { RouteMatchPolicy(rawValue: routeMatchPolicyRaw) ?? .auto }
        set { routeMatchPolicyRaw = newValue.rawValue }
    }

    var routeMatchConfidence: RouteMatchConfidence {
        get { RouteMatchConfidence(rawValue: routeMatchConfidenceRaw) ?? .unknown }
        set { routeMatchConfidenceRaw = newValue.rawValue }
    }

    var transportModeSource: TransportModeSource {
        get { TransportModeSource(rawValue: transportModeSourceRaw) ?? .auto }
        set { transportModeSourceRaw = newValue.rawValue }
    }

    var origin: TimelineItemOrigin {
        get { TimelineItemOrigin(rawValue: originRaw) ?? .sensor }
        set { originRaw = newValue.rawValue }
    }

    var reviewState: ReviewState {
        get { ReviewState(rawValue: reviewStateRaw) ?? .none }
        set { reviewStateRaw = newValue.rawValue }
    }

    func covers(_ date: Date) -> Bool {
        if endDate <= startDate {
            return abs(date.timeIntervalSince(startDate)) < 0.5
        }
        return date >= startDate && date <= endDate
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

    /// True once this row has left the store, which a long await can outlast.
    var hasLeftStore: Bool {
        isDeleted || (modelContext == nil && persistentModelID.storeIdentifier != nil)
    }

    /// Route caches and match labels are derived data. With the undo manager attached they
    /// land on the undo stack above the person's own edit, and the next Undo reverts a cache
    /// instead of that edit. Saves inside the window because SwiftData registers pending
    /// changes with whichever manager is attached when it processes them.
    @MainActor
    func writeDerivedRouteData(_ write: () -> Void) {
        guard !hasLeftStore else { return }
        guard let context = modelContext, let undoManager = context.undoManager else {
            write()
            return
        }
        context.undoManager = nil
        write()
        if context.hasChanges {
            try? context.save()
        }
        context.undoManager = undoManager
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
    /// Straight line between the two stops' centres.
    var straightLineMeters: Double = 0
    /// Reliable fixes strictly between the stops (the endpoints are not counted).
    var interiorFixCount: Int = 0
    /// The trip already stored between these two stops, if any.
    var existingMoveID: UUID? = nil
    /// Set when only the trip's fixes, times, or distance changed: its mode stays.
    var keptMode: TransportMode? = nil
    /// Set when nothing about the trip changed (an unknown mode is being retried):
    /// a distance a route match or Health refined is kept, not recomputed.
    var keptDistance: Double? = nil
}

/// How the stay rebuild removes trips and stops while views may hold them.
///
/// Deleting a row another context still holds aborts the process on the deleted fault,
/// so the rebuild never deletes: it retires. A retired row is kept, detached from
/// everything that reaches it, and has no `dayTimeline` (no live trip or stop lacks
/// one). Readers leave out rows with no day (`FetchDescriptor.live`); the launch purge
/// (`SwiftDataTimelineRepository.purgeRetiredRows(in:)`) deletes them before any view
/// exists.
///
/// The purge also needs the row's own mark (`dedupeKeyPrefix` on a trip,
/// `visitReviewStateRaw` on a stop), because a row iCloud is still bringing in can have
/// no day for a while: its day may not have arrived yet. Deleting that row would delete
/// it on every device.
enum TimelineRetirement {
    static let dedupeKeyPrefix = "retired-"

    /// Written to a retired stop's `reviewStateRaw`. Reads as `ReviewState.none`.
    static let visitReviewStateRaw = "retired"

    static func dedupeKey(for id: UUID) -> String { dedupeKeyPrefix + id.uuidString }

    /// True for a row no reader should show: the rebuild retired it, or it is not on a day.
    static func isRetired(_ move: MoveSegment) -> Bool {
        move.dayTimeline == nil
    }

    static func isRetired(_ visit: VisitPlace) -> Bool {
        visit.dayTimeline == nil
    }
}

extension FetchDescriptor where T == VisitPlace {
    /// Every stay on the timeline, without the retired ones. Add `$0.dayTimeline != nil`
    /// to a predicate of your own instead.
    static func live(sortBy: [SortDescriptor<VisitPlace>] = []) -> FetchDescriptor<VisitPlace> {
        FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.dayTimeline != nil }, sortBy: sortBy)
    }
}

extension FetchDescriptor where T == MoveSegment {
    /// Every trip on the timeline, without the retired ones. Add `$0.dayTimeline != nil`
    /// to a predicate of your own instead.
    static func live(sortBy: [SortDescriptor<MoveSegment>] = []) -> FetchDescriptor<MoveSegment> {
        FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.dayTimeline != nil }, sortBy: sortBy)
    }
}

/// What `reconcileSampleStays` changed, so the assembler can name new stops
/// and classify the trips it just opened.
struct SampleStayReconciliationResult {
    var newPlaces: [VisitPlace] = []
    var moveLegs: [SampleStayMoveLeg] = []
}

/// A real-world place the user has confirmed at least once. Visits point at it.
@Model
final class KnownPlace {
    var id: UUID = UUID()
    var name: String = ""
    var centerLatitude: Double = 0
    var centerLongitude: Double = 0
    /// Learned radius in meters; grows only from confirmed visits. 25…150.
    var footprintRadius: Double = 40
    var confirmedVisitCount: Int = 0
    var category: String? = nil
    var countryCode: String? = nil
    var locality: String? = nil
    var administrativeArea: String? = nil
    /// Street name copied from a confirmed visit's reverse geocode.
    var thoroughfare: String? = nil
    /// Formatted mailing address shown on the place detail and confirm form.
    var formattedAddress: String? = nil
    /// Reverse-geocoded names the user has explicitly rejected here.
    var rejectedAutoLabels: [String] = []
    /// 24-bin histogram of confirmed arrival hours.
    var arrivalHourHistogram: [Int] = Array(repeating: 0, count: 24)
    /// 7-bin weekday histogram of confirmed visits.
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)
    /// Stay durations in seconds; keep the last 50.
    var stayDurationSamples: [Double] = []
    var createdAt: Date = Date.now
    var lastVisitAt: Date? = nil
    @Relationship(inverse: \VisitPlace.knownPlace) var visitsStorage: [VisitPlace]? = nil

    /// The place's stays on the timeline. Retiring a stay detaches it from its place;
    /// this also leaves out one an edit on a stale view attached again.
    var visits: [VisitPlace] {
        get { (visitsStorage ?? []).filter { !TimelineRetirement.isRetired($0) } }
        set { visitsStorage = newValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        footprintRadius: Double = 40
    ) {
        self.id = UUID()
        self.name = name
        self.centerLatitude = latitude
        self.centerLongitude = longitude
        self.footprintRadius = footprintRadius
        self.createdAt = .now
    }
}

/// A photo from the user's library associated with a visit (thumbnail shown inline).
@Model
final class PhotoAttachment {
    var assetLocalIdentifier: String = ""
    var capturedAt: Date = Date.now
    var latitude: Double? = nil
    var longitude: Double? = nil
    var visitPlace: VisitPlace? = nil
    var dayTimeline: DayTimeline? = nil
    var createdAt: Date = Date.now

    init(
        assetLocalIdentifier: String,
        capturedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = .now
    }
}

/// Immutable log of user corrections; the learning input. Never edited, only appended.
@Model
final class PlaceCorrectionEvent {
    var id: UUID = UUID()
    var timestamp: Date = Date.now
    var visitPlaceID: UUID = UUID()
    var fromKnownPlaceID: UUID? = nil
    var fromAutoLabel: String? = nil
    var toKnownPlaceID: UUID? = nil
    var latitude: Double = 0
    var longitude: Double = 0
    var arrivalHour: Int = 0
    var weekday: Int = 0
    var stayDuration: Double = 0

    init(
        visitPlaceID: UUID,
        fromKnownPlaceID: UUID? = nil,
        fromAutoLabel: String? = nil,
        toKnownPlaceID: UUID? = nil,
        latitude: Double,
        longitude: Double,
        arrivalHour: Int,
        weekday: Int,
        stayDuration: Double,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.visitPlaceID = visitPlaceID
        self.fromKnownPlaceID = fromKnownPlaceID
        self.fromAutoLabel = fromAutoLabel
        self.toKnownPlaceID = toKnownPlaceID
        self.latitude = latitude
        self.longitude = longitude
        self.arrivalHour = arrivalHour
        self.weekday = weekday
        self.stayDuration = stayDuration
    }
}

/// Cache of visited 100 m grid cells for the fog / heat layers. Rebuilt incrementally.
@Model
final class VisitedCell {
    var cellKey: String = ""
    var firstVisitedAt: Date = Date.now
    var lastVisitedAt: Date = Date.now
    var sampleCount: Int = 0

    init(cellKey: String, visitedAt: Date, sampleCount: Int = 1) {
        self.cellKey = cellKey
        self.firstVisitedAt = visitedAt
        self.lastVisitedAt = visitedAt
        self.sampleCount = sampleCount
    }
}

/// A stop or trip the person removed.
///
/// The fixes that described it are still stored, so the stay reconciler reads these
/// before it rebuilds anything from them.
@Model
final class RemovedTimelineSpan {
    enum Kind: String {
        case stop
        case trip
    }

    var kindRaw: String = Kind.stop.rawValue
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var latitude: Double = 0
    var longitude: Double = 0
    var createdAt: Date = Date.now

    var kind: Kind {
        Kind(rawValue: kindRaw) ?? .stop
    }

    init(kind: Kind, startDate: Date, endDate: Date, latitude: Double, longitude: Double) {
        self.kindRaw = kind.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = .now
    }
}

/// A named date range that lenses existing visits, moves, and photos.
///
/// Trips do not copy timeline points. Deleting a trip leaves days intact.
@Model
final class NamedTrip {
    var id: UUID = UUID()
    var name: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var notes: String = ""
    var createdAt: Date = Date.now

    /// Exclusive-ended interval used for range queries.
    var interval: DateInterval {
        DateInterval(start: startDate, end: max(endDate, startDate.addingTimeInterval(60)))
    }

    init(
        name: String,
        startDate: Date,
        endDate: Date,
        notes: String = "",
        id: UUID = UUID(),
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        let orderedStart = min(startDate, endDate)
        var orderedEnd = max(startDate, endDate)
        if orderedEnd.timeIntervalSince(orderedStart) < 60 {
            orderedEnd = orderedStart.addingTimeInterval(60)
        }
        self.startDate = orderedStart
        self.endDate = orderedEnd
        self.notes = notes
        self.createdAt = createdAt
    }
}

protocol TimelineRepository {
    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace
    /// True when iOS is reporting a stop the person already removed. Its departure report
    /// can arrive after the removal.
    func visitWasRemoved(_ visit: CLVisit) throws -> Bool
    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample]
    func latestPlace(before date: Date, excluding placeID: UUID?) throws -> VisitPlace?
    /// The live stop with this id, or nil once it is deleted or retired.
    func livePlace(id: UUID) throws -> VisitPlace?
    func samples(from startDate: Date, to endDate: Date) throws -> [LocationSample]
    /// Rebuilds stops and the automatic trips between them from stored fixes.
    ///
    /// Visit monitoring is the only event that used to open and close stays.
    /// Significant-location fixes were kept, but a missed or early visit left
    /// one trip covering every hour until the next visit arrived. This pass
    /// reads those fixes and corrects that.
    func reconcileSampleStays(now: Date) throws -> SampleStayReconciliationResult
    /// The same rebuild, reading pedometer answers from `steps`. Intervals it has no
    /// answer for read as unknown and are listed in `steps.wanted`.
    func reconcileSampleStays(now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult
    /// Relabels foot trips of any age whose pace rules out feet.
    @MainActor func applyPaceRulesToHistory(now: Date) throws -> AutomaticModeHistory.PaceReport
    /// Trips too long and too slow to be one journey, usually a stop that was never closed.
    func implausiblyLongTrips() throws -> [DateInterval]
    /// Corrects labels the rules would no longer give, leaving corrected trips alone.
    func repairTripLabels() throws
    /// Ends stops that run straight past an outing somewhere else, resuming them afterward.
    /// Returns the stretches whose trips now need rebuilding.
    func splitStopsAroundContainedOnes() throws -> [DateInterval]
    /// Rebuilds stops and trips across one older stretch, allowing for nights of silence.
    func reconcileSampleStays(covering trip: DateInterval) throws -> SampleStayReconciliationResult
    /// The rebuild during a trip: the week's rules over the trip's stretch only.
    func reconcileRecentTrip(since: Date, now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult
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
    /// The label earlier stays at the same spot already carry, so a new stay there does
    /// not get a fresh geocode with another house number.
    func reusableAutomaticLabel(for placeID: UUID) throws -> String?
    func saveIfNeeded() throws

    func dissolveVisit(_ visit: VisitPlace) throws -> DissolveVisitResult
    func mergeVisits(_ a: VisitPlace, _ b: VisitPlace) throws -> VisitPlace
    func splitMove(_ move: MoveSegment, at date: Date) throws -> (MoveSegment, VisitPlace, MoveSegment)
    func splitVisit(_ visit: VisitPlace, at date: Date) throws -> (VisitPlace, VisitPlace)
    func updateTimes(of visit: VisitPlace, arrival: Date, departure: Date?) throws
    func setTransportMode(_ mode: TransportMode, for move: MoveSegment, source: TransportModeSource) throws
    func setRouteMatchPolicy(_ policy: RouteMatchPolicy, for move: MoveSegment) throws
    func assign(_ visit: VisitPlace, to place: KnownPlace, source: PlaceAssignmentSource, confidence: Double) throws
    func createKnownPlace(from visit: VisitPlace, name: String) throws -> KnownPlace
    func knownPlaces(near coordinate: CLLocationCoordinate2D, within meters: CLLocationDistance) throws -> [KnownPlace]
    func recordCorrection(_ event: PlaceCorrectionEvent) throws
    func applyPlaceLearning(to visit: VisitPlace) throws
    func timelineItem(at date: Date) throws -> TimelineLocator.Result
    func moves(in range: DateInterval, modes: Set<TransportMode>?) throws -> [MoveSegment]
    func visits(in range: DateInterval) throws -> [VisitPlace]
}

extension TimelineRepository {
    func reconcileSampleStays(now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult {
        try reconcileSampleStays(now: now)
    }

    func reconcileRecentTrip(since: Date, now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult {
        try reconcileSampleStays(covering: DateInterval(start: min(since, now), end: now))
    }

    /// Relabels foot trips of any age whose pace rules out feet. See `AutomaticModeHistory.applyPaceRules`.
    @MainActor func applyPaceRulesToHistory(now: Date) throws -> AutomaticModeHistory.PaceReport {
        AutomaticModeHistory.PaceReport()
    }
}

extension SwiftDataTimelineRepository {
    @MainActor
    func applyPaceRulesToHistory(now: Date) throws -> AutomaticModeHistory.PaceReport {
        try AutomaticModeHistory.applyPaceRules(in: modelContext, now: now)
    }
}

struct HistoricalDeduplicationReport {
    let removedPlaceCount: Int
    let removedMoveCount: Int

    var totalRemovedCount: Int {
        removedPlaceCount + removedMoveCount
    }
}

/// What Undo needs to reverse a deduplication run.
///
/// The fields added after the first release are optional so snapshot files saved
/// earlier still load.
struct TimelineDeduplicationUndoSnapshot: Codable {
    let capturedAt: Date
    let dayTimelines: [DayTimelineSnapshot]
    let places: [VisitPlaceSnapshot]
    let moves: [MoveSegmentSnapshot]
    let samples: [LocationSampleSnapshot]
    let photos: [PhotoLinkSnapshot]?
    /// Rows the run deleted. Only these come back as new rows; a changed row the person
    /// has since deleted stays deleted. Nil in a full snapshot, where any row may return.
    let removedPlaceIDs: [UUID]?
    let removedMoveIDs: [UUID]?

    /// This snapshot cut down to what `after` no longer has, or has with different values.
    func changes(comparedTo after: TimelineDeduplicationUndoSnapshot) -> TimelineDeduplicationUndoSnapshot {
        let placesAfter = Dictionary(after.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let movesAfter = Dictionary(after.moves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let samplesAfter = Dictionary(after.samples.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { first, _ in first })
        let photosAfter = Dictionary(
            (after.photos ?? []).map { ($0.assetLocalIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return TimelineDeduplicationUndoSnapshot(
            capturedAt: capturedAt,
            dayTimelines: dayTimelines,
            places: places.filter { placesAfter[$0.id] != $0 },
            moves: moves.filter { movesAfter[$0.id] != $0 },
            samples: samples.filter { samplesAfter[$0.dedupeKey] != $0 },
            photos: (photos ?? []).filter { photosAfter[$0.assetLocalIdentifier] != $0 },
            removedPlaceIDs: places.map(\.id).filter { placesAfter[$0] == nil },
            removedMoveIDs: moves.map(\.id).filter { movesAfter[$0] == nil }
        )
    }
}

struct DayTimelineSnapshot: Codable {
    let dayKey: String
    let dayStart: Date
    let createdAt: Date
}

struct VisitPlaceSnapshot: Codable, Equatable {
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
    let knownPlaceID: UUID?
    let assignmentSourceRaw: String?
    let assignmentConfidence: Double?
    let originRaw: String?
    let isHiddenAsShortStop: Bool?
    let countryCode: String?
    let locality: String?
    let administrativeArea: String?
    let thoroughfare: String?
    let formattedAddress: String?
    let reviewStateRaw: String?
}

struct MoveSegmentSnapshot: Codable, Equatable {
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
    let routeMatchPolicyRaw: String?
    let routeMatchConfidenceRaw: String?
    let routeMatchSummary: String?
    let transportModeSourceRaw: String?
    let originRaw: String?
    let speedProfileData: Data?
    let reviewStateRaw: String?
}

struct LocationSampleSnapshot: Codable, Equatable {
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

/// Which visit a photo sat on. Deduplication moves photos but never deletes them.
struct PhotoLinkSnapshot: Codable, Equatable {
    let assetLocalIdentifier: String
    let visitPlaceID: UUID?
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
    /// Fixes around the last day lookup that had no coordinate, so the day can still be
    /// the one where the person was. Short-lived: other contexts add fixes too.
    private var dayZoneFixes: (window: DateInterval, loadedAt: Date, fixes: RecordedTimeZones)?
    /// User-labelled places, populated only during bulk imports.
    private var bulkLabeledPlaces: [(label: String, coordinate: CLLocationCoordinate2D)]?
    /// Learned places, populated only during bulk imports.
    private var bulkKnownPlaces: [KnownPlace]?
    /// Visits inserted by the running bulk import; never merged into each other.
    private var bulkCreatedPlaceIDs: Set<UUID>?
    /// What a visit or move created right now came from. A row an import matches keeps its own.
    private var newRowOrigin: TimelineItemOrigin = .sensor
    private static let logPlaceMatchDistance: CLLocationDistance = 120
    private static let logPlaceMatchSlack: TimeInterval = 15 * 60
    private static let logPlaceExtendLimit: TimeInterval = 12 * 60 * 60
    private static let maximumReportedMoveDistance: CLLocationDistance = 100_000_000
    private static let sampleDedupeTimeWindow: TimeInterval = 5 * 60
    private static let sampleDedupeDistanceThreshold: CLLocationDistance = 120
    private static let placeDedupeArrivalWindow: TimeInterval = 3 * 60
    private static let placeDedupeDepartureWindow: TimeInterval = 3 * 60
    private static let placeDedupeDistanceThreshold: CLLocationDistance = 90
    /// iOS reports a visit on arrival and again on departure: the same arrival time,
    /// with a refined centre that can land a few hundred metres from the first.
    private static let sameVisitArrivalTolerance: TimeInterval = 1
    private static let sameVisitMaximumDistance: CLLocationDistance = 500
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
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
        )
        let moves = try modelContext.fetch(
            FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)])
        )
        let samples = try modelContext.fetch(
            FetchDescriptor<LocationSample>(
                sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
            )
        )
        let photos = try modelContext.fetch(FetchDescriptor<PhotoAttachment>())

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
                    dayKey: place.dayTimeline?.dayKey,
                    knownPlaceID: place.knownPlace?.id,
                    assignmentSourceRaw: place.assignmentSourceRaw,
                    assignmentConfidence: place.assignmentConfidence,
                    originRaw: place.originRaw,
                    isHiddenAsShortStop: place.isHiddenAsShortStop,
                    countryCode: place.countryCode,
                    locality: place.locality,
                    administrativeArea: place.administrativeArea,
                    thoroughfare: place.thoroughfare,
                    formattedAddress: place.formattedAddress,
                    reviewStateRaw: place.reviewStateRaw
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
                    manualRouteCoordinatesData: move.manualRouteCoordinatesData,
                    routeMatchPolicyRaw: move.routeMatchPolicyRaw,
                    routeMatchConfidenceRaw: move.routeMatchConfidenceRaw,
                    routeMatchSummary: move.routeMatchSummary,
                    transportModeSourceRaw: move.transportModeSourceRaw,
                    originRaw: move.originRaw,
                    speedProfileData: move.speedProfileData,
                    reviewStateRaw: move.reviewStateRaw
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
            },
            photos: photos.map { photo in
                PhotoLinkSnapshot(
                    assetLocalIdentifier: photo.assetLocalIdentifier,
                    visitPlaceID: photo.visitPlace?.id
                )
            },
            removedPlaceIDs: nil,
            removedMoveIDs: nil
        )
    }

    /// Puts back what a deduplication run changed, and nothing else.
    ///
    /// Rows the run removed return, rows it altered go back to their earlier values,
    /// and fixes and photos are re-linked. Nothing is deleted, so learned places,
    /// corrections, and whatever was recorded since the run are all still there.
    func restoreFromUndoSnapshot(_ snapshot: TimelineDeduplicationUndoSnapshot) throws {
        var timelinesByDayKey: [String: DayTimeline] = [:]
        for timeline in try modelContext.fetch(FetchDescriptor<DayTimeline>())
        where timelinesByDayKey[timeline.dayKey] == nil {
            timelinesByDayKey[timeline.dayKey] = timeline
        }

        for timelineSnapshot in snapshot.dayTimelines where timelinesByDayKey[timelineSnapshot.dayKey] == nil {
            let timeline = DayTimeline(dayStart: timelineSnapshot.dayStart)
            timeline.dayKey = timelineSnapshot.dayKey
            timeline.dayStart = timelineSnapshot.dayStart
            timeline.createdAt = timelineSnapshot.createdAt
            modelContext.insert(timeline)
            timelinesByDayKey[timelineSnapshot.dayKey] = timeline
        }

        let knownPlacesByID = Dictionary(
            try modelContext.fetch(FetchDescriptor<KnownPlace>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // The run retired the rows it removed, and undo brings those back. Any other row
        // retired since was retired by the rebuild: undo neither revives it nor makes a
        // second row with its id.
        let removedPlaceIDs = snapshot.removedPlaceIDs.map { Set($0) }
        let allPlaces = try modelContext.fetch(FetchDescriptor<VisitPlace>())
        let retiredPlaceIDs = Set(allPlaces.filter(TimelineRetirement.isRetired).map(\.id))
            .subtracting(removedPlaceIDs ?? [])
        var placesByID = Dictionary(
            allPlaces.filter { !retiredPlaceIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for placeSnapshot in snapshot.places where !retiredPlaceIDs.contains(placeSnapshot.id) {
            let place: VisitPlace
            if let live = placesByID[placeSnapshot.id] {
                place = live
            } else if removedPlaceIDs?.contains(placeSnapshot.id) ?? true {
                place = VisitPlace(
                    arrivalDate: placeSnapshot.arrivalDate,
                    departureDate: placeSnapshot.departureDate,
                    latitude: placeSnapshot.latitude,
                    longitude: placeSnapshot.longitude,
                    horizontalAccuracy: placeSnapshot.horizontalAccuracy
                )
                place.id = placeSnapshot.id
                place.createdAt = placeSnapshot.createdAt
                modelContext.insert(place)
                placesByID[place.id] = place
            } else {
                continue
            }
            apply(placeSnapshot, to: place, timelinesByDayKey: timelinesByDayKey, knownPlacesByID: knownPlacesByID)
        }

        let removedMoveIDs = snapshot.removedMoveIDs.map { Set($0) }
        let allMoves = try modelContext.fetch(FetchDescriptor<MoveSegment>())
        let retiredMoveIDs = Set(allMoves.filter(TimelineRetirement.isRetired).map(\.id))
            .subtracting(removedMoveIDs ?? [])
        var movesByID = Dictionary(
            allMoves.filter { !retiredMoveIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for moveSnapshot in snapshot.moves where !retiredMoveIDs.contains(moveSnapshot.id) {
            let move: MoveSegment
            if let live = movesByID[moveSnapshot.id] {
                move = live
            } else if removedMoveIDs?.contains(moveSnapshot.id) ?? true {
                move = MoveSegment(
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
                modelContext.insert(move)
                movesByID[move.id] = move
            } else {
                continue
            }
            apply(moveSnapshot, to: move, timelinesByDayKey: timelinesByDayKey, placesByID: placesByID)
        }

        // Deduplication only re-links fixes and photos, so the rows themselves are still here.
        if !snapshot.samples.isEmpty {
            let samplesByKey = Dictionary(
                try modelContext.fetch(FetchDescriptor<LocationSample>()).map { ($0.dedupeKey, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for sampleSnapshot in snapshot.samples {
                samplesByKey[sampleSnapshot.dedupeKey]?.moveSegment = sampleSnapshot.moveID.flatMap { movesByID[$0] }
            }
        }

        if let photoLinks = snapshot.photos, !photoLinks.isEmpty {
            let photosByIdentifier = Dictionary(
                try modelContext.fetch(FetchDescriptor<PhotoAttachment>()).map { ($0.assetLocalIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for link in photoLinks {
                guard let place = link.visitPlaceID.flatMap({ placesByID[$0] }) else { continue }
                photosByIdentifier[link.assetLocalIdentifier]?.visitPlace = place
            }
        }

        try saveIfNeeded()
    }

    private func apply(
        _ snapshot: VisitPlaceSnapshot,
        to place: VisitPlace,
        timelinesByDayKey: [String: DayTimeline],
        knownPlacesByID: [UUID: KnownPlace]
    ) {
        place.arrivalDate = snapshot.arrivalDate
        place.departureDate = snapshot.departureDate
        place.latitude = snapshot.latitude
        place.longitude = snapshot.longitude
        place.horizontalAccuracy = snapshot.horizontalAccuracy
        place.userLabel = snapshot.userLabel
        place.autoLabel = snapshot.autoLabel
        place.comment = snapshot.comment
        if let dayKey = snapshot.dayKey {
            place.dayTimeline = timelinesByDayKey[dayKey]
        }
        place.originRaw = snapshot.originRaw ?? place.originRaw
        place.isHiddenAsShortStop = snapshot.isHiddenAsShortStop ?? place.isHiddenAsShortStop
        place.countryCode = snapshot.countryCode ?? place.countryCode
        place.locality = snapshot.locality ?? place.locality
        place.administrativeArea = snapshot.administrativeArea ?? place.administrativeArea
        place.thoroughfare = snapshot.thoroughfare ?? place.thoroughfare
        place.formattedAddress = snapshot.formattedAddress ?? place.formattedAddress
        place.reviewStateRaw = snapshot.reviewStateRaw ?? place.reviewStateRaw
        if place.reviewStateRaw == TimelineRetirement.visitReviewStateRaw {
            place.reviewState = .none
        }

        // A snapshot saved before these fields existed says nothing about the assignment.
        guard let assignmentSourceRaw = snapshot.assignmentSourceRaw else { return }
        let knownPlace = snapshot.knownPlaceID.flatMap { knownPlacesByID[$0] }
        let knownPlaceIsGone = snapshot.knownPlaceID != nil && knownPlace == nil
        place.knownPlace = knownPlace
        place.assignmentSourceRaw = knownPlaceIsGone ? PlaceAssignmentSource.none.rawValue : assignmentSourceRaw
        place.assignmentConfidence = knownPlaceIsGone ? 0 : snapshot.assignmentConfidence ?? 0
    }

    private func apply(
        _ snapshot: MoveSegmentSnapshot,
        to move: MoveSegment,
        timelinesByDayKey: [String: DayTimeline],
        placesByID: [UUID: VisitPlace]
    ) {
        // A trip the run retired comes back under its own key.
        if move.dedupeKey.hasPrefix(TimelineRetirement.dedupeKeyPrefix) {
            move.dedupeKey = snapshot.dedupeKey
        }
        move.startDate = snapshot.startDate
        move.endDate = snapshot.endDate
        move.transportModeRawValue = snapshot.transportModeRawValue
        move.distanceMeters = snapshot.distanceMeters
        move.stepCount = snapshot.stepCount
        move.comment = snapshot.comment
        move.routeCacheSignature = snapshot.routeCacheSignature
        move.routeCacheCoordinatesData = snapshot.routeCacheCoordinatesData
        move.manualRouteCoordinatesData = snapshot.manualRouteCoordinatesData
        move.routeMatchPolicyRaw = snapshot.routeMatchPolicyRaw ?? move.routeMatchPolicyRaw
        move.routeMatchConfidenceRaw = snapshot.routeMatchConfidenceRaw ?? move.routeMatchConfidenceRaw
        move.routeMatchSummary = snapshot.routeMatchSummary ?? move.routeMatchSummary
        move.transportModeSourceRaw = snapshot.transportModeSourceRaw ?? move.transportModeSourceRaw
        move.originRaw = snapshot.originRaw ?? move.originRaw
        move.speedProfileData = snapshot.speedProfileData ?? move.speedProfileData
        move.reviewStateRaw = snapshot.reviewStateRaw ?? move.reviewStateRaw
        if let dayKey = snapshot.dayKey {
            move.dayTimeline = timelinesByDayKey[dayKey]
        }
        move.startPlace = snapshot.startPlaceID.flatMap { placesByID[$0] }
        move.endPlace = snapshot.endPlaceID.flatMap { placesByID[$0] }
    }

    func runHistoricalDeduplication() throws -> HistoricalDeduplicationReport {
        // Duplicate trips are retired, not deleted: count live rows.
        func liveCounts() throws -> (places: Int, moves: Int) {
            (try modelContext.fetchCount(FetchDescriptor<VisitPlace>.live()),
             try modelContext.fetchCount(FetchDescriptor<MoveSegment>.live()))
        }
        let (placeCountBefore, moveCountBefore) = try liveCounts()

        let placeIDs = try modelContext.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
        )
        .map(\.id)

        for placeID in placeIDs {
            guard let place = try findPlace(byID: placeID) else { continue }
            _ = try collapseDuplicatePlaces(around: place)
        }

        let moveIDs = try modelContext.fetch(
            FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)])
        )
        .map(\.id)

        for moveID in moveIDs {
            guard let move = try findMove(byID: moveID) else { continue }
            _ = try collapseDuplicateMoves(around: move)
        }

        try repairMissingStaysAroundMoves()
        try saveIfNeeded()

        let (placeCountAfter, moveCountAfter) = try liveCounts()

        return HistoricalDeduplicationReport(
            removedPlaceCount: max(placeCountBefore - placeCountAfter, 0),
            removedMoveCount: max(moveCountBefore - moveCountAfter, 0)
        )
    }

    /// One-time clean-up of stops recorded before duplicates were caught on the way in.
    ///
    /// Only merges records of one presence: visit reports of the same arrival, stops
    /// overlapping in time, and the trips those merges leave behind. Fixes are never
    /// touched, and stops the person named differently stay separate.
    func repairDuplicateStays() throws {
        let sortedPlaces = try modelContext.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
        )
        // Collapsing only ever finds stops arriving within the dedupe window of each other,
        // and it never moves an arrival, so a stop with no neighbour that close is left as
        // it is without the two fetches per stop that used to make this take most of a minute.
        let arrivals = sortedPlaces.map(\.arrivalDate)
        let placeIDs = sortedPlaces.indices.compactMap { index -> UUID? in
            let hasNeighbor = (index > 0
                && arrivals[index].timeIntervalSince(arrivals[index - 1]) <= Self.placeDedupeArrivalWindow)
                || (index + 1 < arrivals.count
                    && arrivals[index + 1].timeIntervalSince(arrivals[index]) <= Self.placeDedupeArrivalWindow)
            return hasNeighbor ? sortedPlaces[index].id : nil
        }
        for placeID in placeIDs {
            guard let place = try findPlace(byID: placeID) else { continue }
            _ = try collapseDuplicatePlaces(around: place)
        }
        try saveIfNeeded()

        var places = try modelContext.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
        )
        let samples = try modelContext.fetch(
            FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)])
        )
        try mergeAdjacentSamePlaceVisits(&places, samples: samples)
        closeOpenPlacesThatHaveASuccessor(places)
        trimOverlappingStops(places)
        try saveIfNeeded()

        for move in try modelContext.fetch(FetchDescriptor<MoveSegment>.live()) where !isUserCurated(move) {
            if let start = move.startPlace?.id, start == move.endPlace?.id {
                modelContext.delete(move)
            }
        }
        try saveIfNeeded()

        let moveIDs = try modelContext.fetch(
            FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)])
        ).map(\.id)
        for moveID in moveIDs {
            guard let move = try findMove(byID: moveID) else { continue }
            _ = try collapseDuplicateMoves(around: move)
        }
        try saveIfNeeded()
    }

    /// One-time correction of labels the rules would no longer give: rides read as walks,
    /// and short hops still marked stationary or unknown. Corrected trips stay as they are.
    func repairTripLabels() throws {
        for move in try modelContext.fetch(FetchDescriptor<MoveSegment>.live()) where !isUserCurated(move) {
            guard let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate else { continue }
            let straightLine = Self.distanceMeters(from: start, to: end)
            let duration = move.endDate.timeIntervalSince(move.startDate)
            let proposedMode = StepModeRules.refinedMode(
                proposed: move.transportMode,
                straightLine: straightLine,
                distance: move.distanceMeters,
                duration: duration,
                stepCount: move.knownStepCount,
                locations: move.samples.map(\.asLocation)
            )
            // A preference change alone is not permission to rewrite old labels.
            // Only constrain a new guess this repair would already have made.
            guard proposedMode != move.transportMode else { continue }
            let mode = AutomaticTransportModes.load().allowedMode(proposedMode)
            if mode != move.transportMode {
                move.transportMode = mode
                move.clearCachedRouteCoordinates()
            }
        }
        try saveIfNeeded()
    }

    func visitWasRemoved(_ visit: CLVisit) throws -> Bool {
        let arrival = normalizedArrivalDate(for: visit)
        guard try existingVisit(near: arrival, coordinate: visit.coordinate) == nil else { return false }
        return try modelContext.fetch(FetchDescriptor<RemovedTimelineSpan>()).contains { span in
            span.kind == .stop
                && abs(span.startDate.timeIntervalSince(arrival)) <= Self.placeDedupeArrivalWindow
                && Self.distanceMeters(
                    from: visit.coordinate,
                    to: CLLocationCoordinate2D(latitude: span.latitude, longitude: span.longitude)
                ) <= Self.removedStopMatchDistance
        }
    }

    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace {
        let arrival = normalizedArrivalDate(for: visit)
        let departure = normalizedDepartureDate(for: visit)

        let existing = try existingVisit(near: arrival, coordinate: visit.coordinate)
        if let existing {
            if let departure, existing.origin == .sensor {
                existing.departureDate = departure
                if let center = try robustStayCenter(from: existing.arrivalDate, to: departure) {
                    existing.latitude = center.latitude
                    existing.longitude = center.longitude
                } else if visit.horizontalAccuracy <= existing.horizontalAccuracy {
                    existing.latitude = visit.coordinate.latitude
                    existing.longitude = visit.coordinate.longitude
                }
            }
            existing.horizontalAccuracy = min(existing.horizontalAccuracy, visit.horizontalAccuracy)
            existing.dayTimeline = try timeline(for: arrival, at: existing.coordinate)
            let canonical = try collapseDuplicatePlaces(around: existing)
            try applyPlaceLearning(to: canonical)
            try saveIfNeeded()
            return canonical
        }

        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy
        )
        if let departure, let center = try robustStayCenter(from: arrival, to: departure) {
            place.latitude = center.latitude
            place.longitude = center.longitude
        }
        place.dayTimeline = try timeline(for: arrival, at: place.coordinate)
        modelContext.insert(place)
        let canonical = try collapseDuplicatePlaces(around: place)
        try applyPlaceLearning(to: canonical)
        try saveIfNeeded()
        return canonical
    }

    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample] {
        guard !locations.isEmpty else { return [] }

        var inserted: [LocationSample] = []
        var newlyInserted: [LocationSample] = []
        inserted.reserveCapacity(locations.count)

        for location in locations {
            let dedupeKey = Self.makeSampleDedupeKey(for: location)
            if archiveImportSampleKeys != nil {
                if archiveImportSampleKeys?.contains(dedupeKey) == true {
                    continue
                }
                let sample = LocationSample(location: location, source: source, dedupeKey: dedupeKey)
                sample.dayTimeline = try timeline(for: location.timestamp, at: location.coordinate)
                modelContext.insert(sample)
                noteStoredFix(location)
                archiveImportSampleKeys?.insert(dedupeKey)
                inserted.append(sample)
                newlyInserted.append(sample)
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
            sample.dayTimeline = try timeline(for: location.timestamp, at: location.coordinate)
            modelContext.insert(sample)
            noteStoredFix(location)
            inserted.append(sample)
            newlyInserted.append(sample)
        }

        if archiveImportSampleKeys == nil {
            try saveIfNeeded()
            NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        }
        // Live capture no longer writes visited cells: nothing reads them since the Map tab
        // moved to `MapActivityIndex`, and every few seconds of a trip was another write to
        // the CloudKit mirror. Imports still keep them, as their tests expect.
        if !source.isLiveCapture {
            VisitedCellStore.ingest(newlyInserted, in: modelContext)
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

        if source.isHistoryImport,
           wasRemoved(tripFrom: firstLocation.timestamp, to: lastLocation.timestamp,
                      spans: try modelContext.fetch(FetchDescriptor<RemovedTimelineSpan>())) { return nil }
        let samples = try appendSamples(from: orderedLocations, source: source)
        let distance = Self.totalDistance(for: orderedLocations)

        newRowOrigin = source.isHistoryImport ? .imported : .sensor
        defer { newRowOrigin = .sensor }

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
        newRowOrigin = .imported
        defer {
            archiveImportSampleKeys = nil
            newRowOrigin = .sensor
        }

        let removed = try modelContext.fetch(FetchDescriptor<RemovedTimelineSpan>())
        let places = archive.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
        let moves = archive.moves.sorted(by: { $0.startDate < $1.startDate })
        let total = max(places.count + moves.count, 1)
        var importedPlaceCount = 0
        var importedMoveCount = 0
        var importedSampleCount = 0

        for (index, record) in places.enumerated() {
            if Task.isCancelled { modelContext.rollback(); throw CancellationError() }
            if importStopWasRemoved(start: record.arrivalDate, end: record.departureDate ?? record.arrivalDate.addingTimeInterval(1), coordinate: record.coordinate, spans: removed) { continue }
            progress?(Double(index) / Double(total), "Restoring places…")
            _ = try upsertImportedPlace(record)
            importedPlaceCount += 1
        }
        try saveIfNeeded()

        for (index, record) in moves.enumerated() {
            if Task.isCancelled { modelContext.rollback(); throw CancellationError() }
            if wasRemoved(tripFrom: record.startDate, to: record.endDate, spans: removed) { continue }
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

        let removed = try modelContext.fetch(FetchDescriptor<RemovedTimelineSpan>())
        var report = LocationLogImportReport()
        var previousPlace: VisitPlace?
        var pendingMove: LocationLogMove?
        let total = Double(max(log.segments.count, 1))

        for (index, segment) in log.segments.enumerated() {
            if Task.isCancelled { modelContext.rollback(); throw CancellationError() }
            progress?(Double(index) / total, "Rebuilding timeline…")

            switch segment {
            case .stay(let stay):
                if importStopWasRemoved(start: stay.arrivalDate, end: stay.departureDate, coordinate: stay.coordinate, spans: removed) {
                    previousPlace = nil; pendingMove = nil; continue
                }
                let (place, isNew) = try upsertLogStay(stay, source: source, report: &report)
                if isNew {
                    report.placeCount += 1
                    if stay.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        report.newPlaces.append(
                            LocationLogPlaceNamer.Candidate(placeID: place.id, coordinate: place.coordinate, dwell: stay.duration)
                        )
                    }
                } else {
                    report.mergedPlaceCount += 1
                }

                if let move = pendingMove {
                    let start = try previousPlace ?? logEndpointPlace(
                        at: move.points.first,
                        fallback: place,
                        source: source,
                        report: &report
                    )
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
                if wasRemoved(tripFrom: move.startDate, to: move.endDate, spans: removed) {
                    previousPlace = nil; pendingMove = nil; continue
                }
                if let orphan = pendingMove {
                    // Two moves in a row only happen at the log edges; give the
                    // first one a point-shaped destination so it still renders.
                    let start = try previousPlace ?? logEndpointPlace(
                        at: orphan.points.first,
                        fallback: nil,
                        source: source,
                        report: &report
                    )
                    let end = try logEndpointPlace(
                        at: orphan.points.last,
                        fallback: start,
                        source: source,
                        report: &report
                    )
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
            let start = try previousPlace ?? logEndpointPlace(
                at: move.points.first,
                fallback: nil,
                source: source,
                report: &report
            )
            let end = try logEndpointPlace(
                at: move.points.last,
                fallback: start,
                source: source,
                report: &report
            )
            try insertLogMove(move, from: start, to: end, source: source, transportModeOverride: transportModeOverride, report: &report)
        }

        progress?(0.98, "Saving…")
        try fillMissingDeparturesFromMoves()
        try saveIfNeeded()
        progress?(1, "Done")
        return report
    }

    /// Runs one saved step of a long import. The lookup tables cover only `range`, so
    /// a step costs the same however much history is already stored, and nothing is
    /// held between steps. Every date `body` writes must fall inside `range`.
    func performBulkImportStep<T>(covering range: DateInterval, _ body: () throws -> T) throws -> T {
        try beginBulkImport(covering: range)
        defer { endBulkImport() }
        return try body()
    }

    /// The day a date is filed under, shared with samples written in the same step.
    func dayTimeline(for date: Date) throws -> DayTimeline {
        try timeline(for: date)
    }

    /// The day a moment at `coordinate` is filed under: the calendar day there.
    func dayTimeline(for date: Date, at coordinate: CLLocationCoordinate2D?) throws -> DayTimeline {
        try timeline(for: date, at: coordinate)
    }

    /// Loads the lookup tables the bulk importers use to avoid per-record fetches.
    private func beginBulkImport(covering range: DateInterval? = nil) throws {
        var keyDescriptor = FetchDescriptor<LocationSample>()
        var timelineDescriptor = FetchDescriptor<DayTimeline>()
        if let range {
            // A day starts up to a day before its last fix, in whichever time zone filed it.
            let start = range.start.addingTimeInterval(-2 * 24 * 60 * 60)
            let end = range.end.addingTimeInterval(2 * 24 * 60 * 60)
            keyDescriptor.predicate = #Predicate { $0.timestamp >= start && $0.timestamp <= end }
            timelineDescriptor.predicate = #Predicate { $0.dayStart >= start && $0.dayStart <= end }
        }
        keyDescriptor.propertiesToFetch = [\.dedupeKey]
        archiveImportSampleKeys = Set(try modelContext.fetch(keyDescriptor).map(\.dedupeKey))

        let timelines = try modelContext.fetch(timelineDescriptor)
        var cache: [String: DayTimeline] = [:]
        cache.reserveCapacity(timelines.count)
        for timeline in timelines where cache[timeline.dayKey] == nil {
            cache[timeline.dayKey] = timeline
        }
        bulkDayTimelineCache = cache

        let labeled = try modelContext.fetch(
            FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.userLabel != nil && $0.dayTimeline != nil })
        )
        bulkLabeledPlaces = labeled.compactMap { place in
            guard let label = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return nil
            }
            return (label, place.coordinate)
        }
        bulkKnownPlaces = try modelContext.fetch(FetchDescriptor<KnownPlace>())
        bulkCreatedPlaceIDs = []
    }

    private func endBulkImport() {
        archiveImportSampleKeys = nil
        bulkDayTimelineCache = nil
        bulkLabeledPlaces = nil
        bulkKnownPlaces = nil
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
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd && place.dayTimeline != nil
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
            // Resuming a staged import may revisit already committed segments. Never
            // stretch a corrected/reviewed/imported stay back to the source file's times.
            if match.origin != .sensor || match.reviewState == .confirmed || match.reviewState == .dismissed {
                return (match, false)
            }
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
            // The arrival may have moved to another local day; the lookup is cached in bulk.
            let day = try timeline(for: match.arrivalDate, at: match.coordinate)
            if match.dayTimeline !== day {
                match.dayTimeline = day
            }
            try applyGoogleStayMetadata(stay, to: match, source: source)
            return (match, false)
        }

        let place = VisitPlace(
            arrivalDate: stay.arrivalDate,
            departureDate: stay.departureDate,
            latitude: stay.latitude,
            longitude: stay.longitude,
            horizontalAccuracy: Self.logPlaceAccuracy(for: stay)
        )
        place.dayTimeline = try timeline(for: stay.arrivalDate, at: stay.coordinate)
        modelContext.insert(place)
        try applyPlaceLearning(to: place)
        applyImportedOrigin(to: place, source: source)
        try applyGoogleStayMetadata(stay, to: place, source: source)
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
        source: LocationSampleSource,
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
            applyImportedOrigin(to: place, source: source)
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
            if existing.transportModeSource == .auto, source == .googleTimelineImport, mode != .unknown {
                existing.transportModeSource = .imported
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
        segment.dayTimeline = try timeline(for: startDate, at: startPlace.coordinate)
        applyImportedMoveProvenance(
            to: segment,
            source: source,
            pointCount: move.points.count,
            distanceMeters: move.distanceMeters
        )
        modelContext.insert(segment)
        for sample in samples where sample.moveSegment == nil {
            sample.moveSegment = segment
        }
        report.moveCount += 1
    }

    /// Marks a Google Timeline visit as imported and copies its semantic name.
    private func applyGoogleStayMetadata(
        _ stay: LocationLogStay,
        to place: VisitPlace,
        source: LocationSampleSource
    ) throws {
        guard source == .googleTimelineImport else { return }
        applyImportedOrigin(to: place, source: source)
        guard let name = stay.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return
        }
        let radius = PlaceLearningEngine.rejectedLabelSearchRadius
        let nearby = try bulkKnownPlaces?.filter { known in
            Self.distanceMeters(from: place.coordinate, to: known.coordinate) <= radius
        } ?? knownPlaces(near: place.coordinate, within: radius)
        if !PlaceLearningEngine.shouldSuppress(name, nearbyPlaces: nearby) {
            place.autoLabel = name
        }
    }

    private func applyImportedOrigin(to place: VisitPlace, source: LocationSampleSource) {
        guard source.isHistoryImport else { return }
        if place.origin == .sensor {
            place.origin = .imported
        }
    }

    /// Tags a move from a file as imported. Google Timeline's mode and path are its own
    /// guesses, so those moves also get `.imported` modes and path honesty from density.
    private func applyImportedMoveProvenance(
        to move: MoveSegment,
        source: LocationSampleSource,
        pointCount: Int,
        distanceMeters: Double
    ) {
        guard source.isHistoryImport else { return }
        move.origin = .imported
        guard source == .googleTimelineImport else { return }
        move.transportModeSource = .imported
        move.routeMatchConfidence = Self.importedRouteConfidence(
            pointCount: pointCount,
            distanceMeters: distanceMeters
        )
    }

    /// WS4 density gate applied to imported paths: ≥5 fixes/km is high, 1–5 medium, otherwise estimated.
    private static func importedRouteConfidence(
        pointCount: Int,
        distanceMeters: Double
    ) -> RouteMatchConfidence {
        let intermediates = max(pointCount - 2, 0)
        let kilometres = max(distanceMeters, 1) / 1_000
        let density = Double(intermediates) / kilometres
        if density >= 5 { return .high }
        if density >= 1 { return .medium }
        return .estimated
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
                move.startDate <= endDate && move.endDate >= startDate && move.dayTimeline != nil
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
                place.arrivalDate < date && place.dayTimeline != nil
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
        try reconcileSampleStays(now: now, steps: ReconcileStepEvidence())
    }

    func reconcileSampleStays(now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult {
        try reconcileSampleStays(
            from: try reconciliationWindowStart(through: now),
            through: now,
            placesThrough: now,
            configuration: SampleStayInference.Configuration(),
            steps: steps
        )
    }

    /// The live trip's part of the week, read exactly as the full week reads it: the same
    /// stay rules, the same "now", and the same pedometer answers. Only the window is shorter,
    /// so it never decides a shared stop differently and the full pass has nothing to undo.
    func reconcileRecentTrip(since: Date, now: Date, steps: ReconcileStepEvidence) throws -> SampleStayReconciliationResult {
        let start = max(min(since, now).addingTimeInterval(-60 * 60), try reconciliationWindowStart(through: now))
        return try reconcileSampleStays(
            from: start,
            through: now,
            placesThrough: now,
            configuration: SampleStayInference.Configuration(),
            steps: steps
        )
    }

    func reconcileSampleStays(covering trip: DateInterval) throws -> SampleStayReconciliationResult {
        var configuration = SampleStayInference.Configuration()
        configuration.maximumStillGap = 30 * 60 * 60
        let end = trip.end.addingTimeInterval(60 * 60)
        return try reconcileSampleStays(
            from: trip.start.addingTimeInterval(-60 * 60),
            through: end,
            placesThrough: end.addingTimeInterval(36 * 60 * 60),
            configuration: configuration,
            steps: ReconcileStepEvidence()
        )
    }

    func splitStopsAroundContainedOnes() throws -> [DateInterval] {
        let places = try modelContext.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
        )
        var stretches: [DateInterval] = []

        for (index, stop) in places.enumerated() {
            guard stop.origin == .sensor, let departure = stop.departureDate else { continue }
            let outings = places[(index + 1)...]
                .prefix { $0.arrivalDate < departure }
                .filter { other in
                    guard let otherEnd = other.departureDate else { return false }
                    return otherEnd <= departure
                        && departure.timeIntervalSince(other.arrivalDate) > 60
                        && Self.distanceMeters(from: stop.coordinate, to: other.coordinate) > Self.overlappingStayMatchDistance
                }
            guard let first = outings.first,
                  let last = outings.last,
                  let backAt = last.departureDate
            else { continue }

            // A few minutes left over isn't a return, just a stray fix at the end.
            let leavesFrom: VisitPlace
            if departure.timeIntervalSince(backAt) >= SampleStayInference.Configuration().minimumStayDuration {
                let resumed = VisitPlace(
                    arrivalDate: backAt,
                    departureDate: departure,
                    latitude: stop.latitude,
                    longitude: stop.longitude,
                    horizontalAccuracy: stop.horizontalAccuracy,
                    userLabel: stop.userLabel,
                    autoLabel: stop.autoLabel,
                    comment: stop.comment
                )
                resumed.knownPlace = stop.knownPlace
                resumed.assignmentSource = stop.assignmentSource
                resumed.assignmentConfidence = stop.assignmentConfidence
                resumed.countryCode = stop.countryCode
                resumed.locality = stop.locality
                resumed.administrativeArea = stop.administrativeArea
                resumed.thoroughfare = stop.thoroughfare
                resumed.formattedAddress = stop.formattedAddress
                resumed.dayTimeline = try timeline(for: backAt, at: resumed.coordinate)
                modelContext.insert(resumed)
                leavesFrom = resumed
            } else {
                leavesFrom = last
            }
            for move in stop.outgoingMoves {
                move.startPlace = leavesFrom
            }
            stop.departureDate = first.arrivalDate
            stretches.append(DateInterval(start: first.arrivalDate, end: max(departure, first.arrivalDate)))
        }

        try saveIfNeeded()
        return stretches
    }

    func implausiblyLongTrips() throws -> [DateInterval] {
        try modelContext.fetch(
            FetchDescriptor<MoveSegment>.live(sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)])
        )
        .compactMap { move -> DateInterval? in
            let duration = move.endDate.timeIntervalSince(move.startDate)
            guard duration >= 3 * 60 * 60,
                  move.transportMode != .plane,
                  !isUserCurated(move),
                  let start = move.startPlace?.coordinate,
                  let end = move.endPlace?.coordinate
            else { return nil }
            // A long real trip covers ground. This only finds candidates: the rebuild adds
            // a stop only where fixes hold still, so a hike that ends where it began stays.
            let speed = Self.distanceMeters(from: start, to: end) / duration
            guard speed < (duration >= 6 * 60 * 60 ? 4 : 1) else { return nil }
            return DateInterval(start: move.startDate, end: move.endDate)
        }
    }

    private func reconcileSampleStays(
        from windowStart: Date,
        through now: Date,
        placesThrough: Date,
        configuration: SampleStayInference.Configuration,
        steps: ReconcileStepEvidence
    ) throws -> SampleStayReconciliationResult {
        // A photo's location says where it was taken, which may not be where the person
        // was: photos arrive from other people with their original place and time.
        let storedSamples = try samples(from: windowStart, to: now.addingTimeInterval(60))
            .filter { $0.source != .photoLibrary }
        let removedSpans = try removedSpans(since: windowStart.addingTimeInterval(-36 * 60 * 60))
        let points = storedSamples.map { LocationLogPoint(location: $0.asLocation) }
        let inferred = SampleStayInference.stays(from: points, now: now, configuration: configuration)
        // The boundary rules read every fix since the earliest stop this pass can touch,
        // not just the window's: a shorter window (the live trip's) must reach the same
        // answer about a stop as the full week, or the next full pass would undo it.
        let placesFrom = windowStart.addingTimeInterval(-36 * 60 * 60)
        let evidenceSamples = try samples(from: placesFrom, to: now.addingTimeInterval(60))
            .filter { $0.source != .photoLibrary }
        let evidence = StopRebuildEvidence(
            samples: evidenceSamples,
            inferred: SampleStayInference.stays(
                from: evidenceSamples.map { LocationLogPoint(location: $0.asLocation) },
                now: now,
                configuration: configuration
            ),
            windowStart: windowStart,
            steps: steps
        )

        var places: [VisitPlace] = []
        var newPlaces: [VisitPlace] = []
        // A dissolved stop no longer caps or splits the stays around it, so those are
        // matched again in the same pass; otherwise the next pass would find them.
        for _ in 0..<3 {
            places = try placesArriving(from: windowStart.addingTimeInterval(-36 * 60 * 60), through: placesThrough)
            let clamped = inferred.flatMap { split($0, aroundFarPlaces: places) }

            for stay in clamped {
                if let match = matchingPlace(for: stay, among: places, samples: evidence.samples) {
                    try extend(match, toCover: stay, among: places, evidence: evidence)
                } else if !wasRemoved(stay, spans: removedSpans) {
                    let created = try makePlace(for: stay, among: places)
                    places.append(created)
                    newPlaces.append(created)
                }
            }

            places.sort { $0.arrivalDate < $1.arrivalDate }
            // Every fix the pass can see, so a merged stop gets the same centre from either entry point.
            try mergeAdjacentSamePlaceVisits(&places, samples: evidence.samples, stays: evidence.inferred)
            closeOpenPlacesThatHaveASuccessor(places)
            trimOverlappingStops(places)
            // Stop boundaries follow the fixes: trimmed to where the person was last and
            // first seen, a trip opened between stops that touch, stops that were never
            // stops dissolved, and nothing left overlapping.
            guard try settleStopBoundaries(&places, evidence: evidence) else { break }
        }

        try deleteInconsistentAutomaticMoves(among: places, from: windowStart, through: now)
        try deleteConflictingAutomaticMoves(among: places, from: windowStart, through: now)
        let legs = try moveLegs(
            among: places,
            samples: storedSamples,
            removedSpans: removedSpans,
            from: windowStart,
            through: now
        )
        let survivingNewPlaces = newPlaces.filter { created in
            places.contains { $0.id == created.id }
        }

        try saveIfNeeded()
        return SampleStayReconciliationResult(newPlaces: survivingNewPlaces, moveLegs: legs)
    }

    // MARK: Retiring rows during the rebuild

    /// The one way the rebuild removes a trip. The row stays, detached from everything
    /// that reaches it, so a view on another context that still holds it reads a stale
    /// but valid object instead of aborting on a deleted fault.
    func retire(_ move: MoveSegment) {
        guard !move.isDeleted else { return }
        guard !move.dedupeKey.hasPrefix(TimelineRetirement.dedupeKeyPrefix) || move.dayTimeline != nil else { return }
        // Fixes go back to no trip, as the delete rule (nullify) does.
        for sample in move.samples where sample.moveSegment?.persistentModelID == move.persistentModelID {
            sample.moveSegment = nil
        }
        move.startPlace = nil
        move.endPlace = nil
        move.dayTimeline = nil
        move.dedupeKey = TimelineRetirement.dedupeKey(for: move.id)
        move.reviewStateRaw = ReviewState.none.rawValue
    }

    /// The one way the rebuild removes a stop. See `retire(_:)` for trips.
    func retire(_ visit: VisitPlace) {
        guard !visit.isDeleted else { return }
        guard visit.reviewStateRaw != TimelineRetirement.visitReviewStateRaw || visit.dayTimeline != nil else { return }
        // Trips lose this end, as the delete rule (nullify) does.
        for move in visit.incomingMovesStorage ?? [] where move.endPlace?.persistentModelID == visit.persistentModelID {
            move.endPlace = nil
        }
        for move in visit.outgoingMovesStorage ?? [] where move.startPlace?.persistentModelID == visit.persistentModelID {
            move.startPlace = nil
        }
        // Deleting would cascade any photo still attached; retiring keeps it on the day.
        // The rebuild and merges move photos before removing a stop, so this is a safety
        // net, and it leaves alone a photo already moved to the stop that took over.
        for photo in visit.photoAttachments where photo.visitPlace?.persistentModelID == visit.persistentModelID {
            if photo.dayTimeline == nil { photo.dayTimeline = visit.dayTimeline }
            photo.visitPlace = nil
        }
        visit.knownPlace = nil
        visit.dayTimeline = nil
        visit.reviewStateRaw = TimelineRetirement.visitReviewStateRaw
    }

    private static var retiredMoves: FetchDescriptor<MoveSegment> {
        let prefix = TimelineRetirement.dedupeKeyPrefix
        return FetchDescriptor<MoveSegment>(predicate: #Predicate {
            $0.dayTimeline == nil && $0.dedupeKey.starts(with: prefix)
        })
    }

    private static var retiredVisits: FetchDescriptor<VisitPlace> {
        let marker = TimelineRetirement.visitReviewStateRaw
        return FetchDescriptor<VisitPlace>(predicate: #Predicate {
            $0.dayTimeline == nil && $0.reviewStateRaw == marker
        })
    }

    /// How many retired rows are waiting for the purge. Two indexed counts.
    static func retiredRowCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(retiredMoves) + context.fetchCount(retiredVisits)
    }

    /// Hard-deletes every retired trip and stop: no day and the rebuild's mark. Run where
    /// no view holds timeline rows (at launch, while the timeline is held back). Saves
    /// every `batchSize` rows, so a purge cut short leaves only retired rows behind and
    /// the next launch finishes it. Returns the number of rows removed.
    /// `shouldStop` is asked after each saved batch; the rest waits for the next launch.
    @discardableResult
    static func purgeRetiredRows(
        in context: ModelContext,
        batchSize: Int = 500,
        shouldStop: () -> Bool = { false }
    ) throws -> Int {
        var removed = 0
        var stopped = false
        func countOne() throws {
            removed += 1
            guard removed.isMultiple(of: max(batchSize, 1)) else { return }
            if context.hasChanges { try context.save() }
            stopped = shouldStop()
        }
        for move in try context.fetch(retiredMoves) {
            context.delete(move)
            try countOne()
            if stopped { return removed }
        }
        for visit in try context.fetch(retiredVisits) {
            // Retiring moved its photos to the day already; nothing may cascade with it.
            for photo in visit.photoAttachmentsStorage ?? [] { photo.visitPlace = nil }
            context.delete(visit)
            try countOne()
            if stopped { return removed }
        }
        if context.hasChanges { try context.save() }
        return removed
    }

    /// What the boundary rules read during one rebuild.
    private struct StopRebuildEvidence {
        /// All stored fixes in the window, for the last-block rule.
        let samples: [LocationSample]
        /// Real position fixes, sorted. Visit reports are left out: their coordinate is
        /// the visit's centre, not where the phone was at that moment.
        let fixes: [StopBoundaryEvidence.Fix]
        let inferred: [SampleStay]
        let windowStart: Date
        let steps: ReconcileStepEvidence
        /// Times of high-accuracy route-tracking fixes, sorted.
        let routeTrackTimes: [Date]

        init(samples: [LocationSample], inferred: [SampleStay], windowStart: Date, steps: ReconcileStepEvidence) {
            self.samples = samples
            // Routes someone chose to record (or brought in), whose ends are stops by
            // construction. Following trips (`.continuous`) is ordinary capture, not that.
            self.routeTrackTimes = samples.filter {
                switch $0.source {
                case .routeTracking, .watchRouteTracking, .healthWorkoutRoute, .fileRouteImport,
                     .googleTimelineImport, .arcImport:
                    return true
                case .visit, .significantChange, .watchSignificantChange, .launchBackfill, .authorizationGrant,
                     .lastMile, .photoLibrary, .cameraPhoto, .continuous:
                    return false
                }
            }.map(\.timestamp).sorted()
            self.fixes = samples
                .filter { $0.source != .visit }
                .map {
                    StopBoundaryEvidence.Fix(
                        timestamp: $0.timestamp,
                        coordinate: $0.coordinate,
                        horizontalAccuracy: $0.horizontalAccuracy
                    )
                }
                .sorted { $0.timestamp < $1.timestamp }
            self.inferred = inferred
            self.windowStart = windowStart
            self.steps = steps
        }

        func stepLookup(_ start: Date, _ end: Date) -> Int? {
            steps.steps(from: start, to: end)
        }

        /// Fixes with `start <= timestamp <= end`, by binary search.
        func fixes(from start: Date, through end: Date) -> [StopBoundaryEvidence.Fix] {
            guard start <= end else { return [] }
            var low = 0
            var high = fixes.count
            while low < high {
                let mid = (low + high) / 2
                if fixes[mid].timestamp < start { low = mid + 1 } else { high = mid }
            }
            var result: [StopBoundaryEvidence.Fix] = []
            var index = low
            while index < fixes.count, fixes[index].timestamp <= end {
                result.append(fixes[index])
                index += 1
            }
            return result
        }

        func hasRouteTrack(from start: Date, through end: Date) -> Bool {
            var low = 0
            var high = routeTrackTimes.count
            while low < high {
                let mid = (low + high) / 2
                if routeTrackTimes[mid] < start { low = mid + 1 } else { high = mid }
            }
            return low < routeTrackTimes.count && routeTrackTimes[low] <= end
        }

        /// True when the fixes over the interval are dense and keep moving.
        func showsTravel(from start: Date, to end: Date) -> Bool {
            let inside = fixes(from: start, through: end)
            return TravelEvidence.isTravel(inside.map { ($0.timestamp, $0.coordinate) }, from: start, to: end)
        }

        /// True when a stop reconstructed from clustered fixes covers this stop.
        func isSupportedByFixes(_ place: VisitPlace) -> Bool {
            let end = place.departureDate ?? place.arrivalDate
            return inferred.contains { stay in
                stay.arrivalDate <= end && stay.presenceEnd >= place.arrivalDate
                    && SwiftDataTimelineRepository.distanceMeters(from: stay.coordinate, to: place.coordinate)
                        <= SwiftDataTimelineRepository.overlappingStayMatchDistance
            }
        }
    }

    /// Times the system set and nobody has looked at. The person's edits, imports,
    /// and reviewed stops keep their times.
    private func isAutomaticStop(_ place: VisitPlace) -> Bool {
        place.origin == .sensor && place.reviewState != .confirmed && place.reviewState != .dismissed
    }

    private func hasName(_ place: VisitPlace) -> Bool {
        !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// A stop only visit monitoring reported, that nothing the person did or named
    /// anchors. Such a stop may be dissolved when it is too short to be one.
    private func isDissolvable(_ place: VisitPlace, evidence: StopRebuildEvidence, allowsOpen: Bool = false) -> Bool {
        guard isAutomaticStop(place),
              place.reviewState == .none || place.reviewState == .pending,
              allowsOpen || place.departureDate != nil,
              place.arrivalDate >= evidence.windowStart,
              !hasName(place),
              place.knownPlace == nil,
              place.photoAttachments.isEmpty,
              place.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        else { return false }
        let trips = place.incomingMoves + place.outgoingMoves
        guard !trips.contains(where: isUserCurated) else { return false }
        // A recorded route ends where it ends; its endpoint is not a guess to remove. Read
        // from the fixes at the stop, not from which trip holds them: a fix on the boundary
        // of a stop with no length can belong to the trip on either side.
        let end = place.departureDate ?? place.arrivalDate
        guard !evidence.hasRouteTrack(from: place.arrivalDate.addingTimeInterval(-60), through: end.addingTimeInterval(60))
        else { return false }
        return !evidence.isSupportedByFixes(place)
    }

    /// The arrival the fixes support for `place`, starting from `proposed`.
    private func settledArrival(for place: VisitPlace, proposed: Date, evidence: StopRebuildEvidence) -> Date {
        guard isAutomaticStop(place) else { return proposed }
        let end = place.departureDate ?? .distantFuture
        let fixes = evidence.fixes(from: proposed, through: min(end, Date.distantFuture))
        let arrival = StopBoundaryEvidence.trimmedArrival(
            centre: place.coordinate,
            arrival: proposed,
            departure: place.departureDate,
            fixes: fixes,
            steps: evidence.stepLookup
        ) ?? proposed
        // A visit report can date the arrival to when the person first came by, then walked
        // on and came back. Where no stay the fixes show covers that stretch and the fixes
        // there keep moving, the stop begins with the stay the fixes do show.
        let firstStay = evidence.inferred
            .filter { stay in
                stay.arrivalDate < end && stay.presenceEnd > arrival
                    && Self.distanceMeters(from: stay.coordinate, to: place.coordinate) <= Self.overlappingStayMatchDistance
            }
            .min { $0.arrivalDate < $1.arrivalDate }
        if let firstStay, firstStay.arrivalDate > arrival,
           evidence.showsTravel(from: arrival, to: firstStay.arrivalDate) {
            return firstStay.arrivalDate
        }
        return arrival
    }

    /// The departure the fixes support for `place`, starting from `proposed`. Only ever
    /// earlier than `proposed`; applying it to its own answer returns the same answer.
    private func settledDeparture(
        for place: VisitPlace,
        proposed: Date,
        among places: [VisitPlace],
        evidence: StopRebuildEvidence
    ) -> Date {
        guard isAutomaticStop(place) else { return proposed }
        let successor = places
            .filter { $0.id != place.id && $0.arrivalDate > place.arrivalDate }
            .min { $0.arrivalDate < $1.arrivalDate }
        var departure = proposed
        for _ in 0..<4 {
            var next = departure
            // Fixes after the last one at the stop show the person had already left.
            if let trimmed = StopBoundaryEvidence.trimmedDeparture(
                centre: place.coordinate,
                arrival: place.arrivalDate,
                departure: next,
                fixes: evidence.fixes(from: place.arrivalDate, through: next),
                steps: evidence.stepLookup
            ) {
                next = trimmed
            }
            if let successor {
                // Nobody is in two places at once.
                if next > successor.arrivalDate, (successor.departureDate ?? .distantFuture) >= next,
                   successor.arrivalDate > place.arrivalDate {
                    next = successor.arrivalDate
                }
                next = min(next, separatedFromSuccessor(place, departure: next, successor: successor, evidence: evidence))
            }
            next = max(min(next, departure), place.arrivalDate)
            if next == departure { break }
            departure = next
        }
        return departure
    }

    /// A stop that ends right as one some distance away begins has swallowed the trip.
    ///
    /// A couple of blocks keeps the last-block rule: the trip starts at the last fix
    /// still at the stop. Farther than that, the trip gets the time a walk would take
    /// (`StopBoundaryEvidence.jumpTripStart`). Neither ever leaves a stop with no
    /// length unless that stop is one to dissolve.
    private func separatedFromSuccessor(
        _ place: VisitPlace,
        departure: Date,
        successor: VisitPlace,
        evidence: StopRebuildEvidence
    ) -> Date {
        let gap = successor.arrivalDate.timeIntervalSince(departure)
        let separation = Self.distanceMeters(from: place.coordinate, to: successor.coordinate)

        if gap < 90, !hasName(place),
           separation >= LastBlockWalk.minimumDistance, separation <= LastBlockWalk.maximumDistance {
            let lastOnSite = evidence.samples
                .filter { sample in
                    sample.timestamp >= place.arrivalDate
                        && sample.timestamp < successor.arrivalDate.addingTimeInterval(-LastBlockWalk.minimumDuration)
                        && Self.distanceMeters(from: sample.coordinate, to: place.coordinate) <= Self.stayMatchDistance
                }
                .map(\.timestamp)
                .max()
            if let lastOnSite,
               LastBlockWalk.isShape(distance: separation, duration: successor.arrivalDate.timeIntervalSince(lastOnSite)) {
                let walkStart = max(lastOnSite, place.arrivalDate)
                if walkStart > place.arrivalDate || isDissolvable(place, evidence: evidence) {
                    return walkStart
                }
            }
        }

        // A stay inferred from photos has no fixes of its own: its arrival is when a photo
        // was taken, not evidence of when anyone left the stop before it.
        guard gap <= StopBoundaryEvidence.jumpMaximumGap,
              separation > StopBoundaryEvidence.jumpMinimumDistance,
              successor.origin != .photoInferred
        else { return departure }
        let lastOnSite = evidence.fixes(from: place.arrivalDate, through: successor.arrivalDate)
            .last { StopBoundaryEvidence.isInside($0, centre: place.coordinate) }?
            .timestamp
        let start = StopBoundaryEvidence.jumpTripStart(
            firstArrival: place.arrivalDate,
            nextArrival: successor.arrivalDate,
            distance: separation,
            lastOnSite: lastOnSite
        )
        if start <= place.arrivalDate, !isDissolvable(place, evidence: evidence) {
            return departure
        }
        // A short hop with few steps between ends this close is GPS wander around a door:
        // the same-place merge joins such a pair on the next pass, which would undo this trip.
        if separation <= Self.phantomTripMaximumSeparation,
           (evidence.stepLookup(start, successor.arrivalDate) ?? 0) < Self.phantomTripMaximumSteps {
            return departure
        }
        return min(start, departure)
    }

    /// Runs the boundary rules until nothing changes, so the next rebuild finds nothing to do.
    /// Returns true when a stop was dissolved.
    @discardableResult
    private func settleStopBoundaries(_ places: inout [VisitPlace], evidence: StopRebuildEvidence) throws -> Bool {
        var dissolvedAny = false
        for _ in 0..<4 {
            places.sort { $0.arrivalDate < $1.arrivalDate }
            var changed = false

            for place in places where isAutomaticStop(place) {
                let arrival = settledArrival(for: place, proposed: place.arrivalDate, evidence: evidence)
                // At least a second: sub-second differences between entry points are not news.
                if arrival.timeIntervalSince(place.arrivalDate) >= 1 {
                    place.arrivalDate = arrival
                    changed = true
                }
            }
            places.sort { $0.arrivalDate < $1.arrivalDate }

            for place in places where isAutomaticStop(place) {
                guard let departure = place.departureDate else {
                    // An open stop the fixes since show was left: it ends at the last fix
                    // there, and the walk under way is a trip, not more of the stay.
                    let after = evidence.fixes(from: place.arrivalDate, through: .distantFuture)
                    if let latest = after.last?.timestamp,
                       let left = StopBoundaryEvidence.trimmedDeparture(
                           centre: place.coordinate,
                           arrival: place.arrivalDate,
                           departure: latest,
                           fixes: after,
                           steps: evidence.stepLookup
                       ) {
                        place.departureDate = left
                        changed = true
                    }
                    continue
                }
                let settled = settledDeparture(for: place, proposed: departure, among: places, evidence: evidence)
                if departure.timeIntervalSince(settled) >= 1 {
                    place.departureDate = settled
                    changed = true
                }
            }

            // A stop never ends before it begins.
            for place in places where isAutomaticStop(place) {
                if let departure = place.departureDate, departure < place.arrivalDate {
                    place.departureDate = place.arrivalDate
                    changed = true
                }
            }

            if joinTouchingSamePlaceStops(&places) { changed = true }
            if try dissolveNonStops(&places, evidence: evidence) {
                changed = true
                dissolvedAny = true
            }
            if try separateOverlappingStops(&places) { changed = true }
            if !changed { break }
        }
        return dissolvedAny
    }

    /// Removes stops only visit monitoring saw that were too short to be stops, or that
    /// the pedometer shows the person walked straight through, and joins the trips on
    /// either side into one.
    private func dissolveNonStops(_ places: inout [VisitPlace], evidence: StopRebuildEvidence) throws -> Bool {
        var changed = false
        var index = 1
        while index < places.count - 1 {
            let stop = places[index]
            guard isDissolvable(stop, evidence: evidence), let departure = stop.departureDate else {
                index += 1
                continue
            }
            let duration = departure.timeIntervalSince(stop.arrivalDate)
            var notAStop = duration < Self.shortestStop
            if !notAStop, duration < Self.shortestWalkedThroughStop,
               let steps = evidence.stepLookup(stop.arrivalDate, departure) {
                notAStop = Double(steps) / (duration / 60) >= StopBoundaryEvidence.walkingStepsPerMinute
            }
            // Dense fixes that kept moving the whole time: walked (or driven) straight through.
            if !notAStop, duration < Self.longestTravelledThroughStop {
                notAStop = evidence.showsTravel(from: stop.arrivalDate, to: departure)
            }
            guard notAStop else {
                index += 1
                continue
            }

            let previous = places[index - 1]
            let next = places[index + 1]
            let joined = try findMove(startPlaceID: previous.id, endPlaceID: next.id)
            var kept = joined
            for move in Array(stop.incomingMoves) {
                if kept == nil, move.startPlace?.id == previous.id {
                    // The trip into the stop becomes the whole trip; the next rebuild
                    // gives it the joined times, path, and mode in place.
                    move.endPlace = next
                    if move.endDate != next.arrivalDate { move.endDate = next.arrivalDate }
                    kept = move
                } else {
                    retire(move)
                }
            }
            for move in Array(stop.outgoingMoves) where move.id != kept?.id {
                retire(move)
            }
            retire(stop)
            places.remove(at: index)
            changed = true
        }

        // The newest stop, while the fixes after it keep moving, is a trip still under way:
        // the day ends with the last real stop, and the live row shows the walk.
        if places.count >= 2, let last = places.last,
           isDissolvable(last, evidence: evidence, allowsOpen: true),
           let latest = evidence.fixes(from: last.arrivalDate, through: last.departureDate ?? .distantFuture).last?.timestamp,
           latest.timeIntervalSince(last.arrivalDate) >= 2 * 60,
           (last.departureDate ?? latest).timeIntervalSince(last.arrivalDate) < Self.longestTravelledThroughStop,
           evidence.showsTravel(from: last.arrivalDate, to: last.departureDate ?? latest) {
            for move in Array(last.incomingMoves) { retire(move) }
            for move in Array(last.outgoingMoves) { retire(move) }
            retire(last)
            places.removeLast()
            changed = true
        }
        return changed
    }

    /// Two automatic stops at the same spot, one ending as the other begins, are one stay:
    /// a launch fix or a visit report split it. The later joins the earlier (whose centre
    /// stands); the trip between them, which went nowhere, is retired.
    private func joinTouchingSamePlaceStops(_ places: inout [VisitPlace]) -> Bool {
        var changed = false
        var index = 0
        while index < places.count - 1 {
            let current = places[index]
            let next = places[index + 1]
            // After a stop the person confirmed, a touching stop the system itself assigned
            // to the same known place is that stay reported twice. The confirmed stop keeps
            // its times; the duplicate goes, and the trip after it starts from the stop.
            if !isAutomaticStop(current), current.origin != .photoInferred, isAutomaticStop(next),
               let currentEnd = current.departureDate,
               abs(next.arrivalDate.timeIntervalSince(currentEnd)) <= StopBoundaryEvidence.jumpMaximumGap,
               let known = current.knownPlace?.id, next.knownPlace?.id == known,
               next.assignmentSource == .auto, !hasName(next),
               next.photoAttachments.isEmpty,
               next.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
               Self.distanceMeters(from: current.coordinate, to: next.coordinate) <= Self.overlappingStayMatchDistance,
               !(next.incomingMoves + next.outgoingMoves).contains(where: isUserCurated) {
                for move in Array(next.incomingMoves) { retire(move) }
                for move in Array(next.outgoingMoves) { move.startPlace = current }
                retire(next)
                places.remove(at: index + 1)
                changed = true
                continue
            }
            guard isAutomaticStop(current), isAutomaticStop(next),
                  let currentEnd = current.departureDate,
                  next.arrivalDate.timeIntervalSince(currentEnd) <= StopBoundaryEvidence.jumpMaximumGap,
                  !labelsConflict(current, next)
            else {
                index += 1
                continue
            }
            let apart = Self.distanceMeters(from: current.coordinate, to: next.coordinate)
            let sameName = current.autoLabel != nil && current.autoLabel == next.autoLabel
            let samePlace = current.knownPlace != nil && current.knownPlace?.id == next.knownPlace?.id
            let between = current.outgoingMoves.filter { $0.endPlace?.id == next.id }
            guard apart <= LastBlockWalk.minimumDistance || (apart <= Self.stayMatchDistance && (sameName || samePlace)),
                  !between.contains(where: isUserCurated)
            else {
                index += 1
                continue
            }
            for move in between { retire(move) }
            mergePlace(next, into: current)
            if let nextEnd = next.departureDate {
                if nextEnd > currentEnd { current.departureDate = nextEnd }
            } else {
                current.departureDate = nil
            }
            retire(next)
            places.remove(at: index + 1)
            changed = true
        }
        return changed
    }

    /// Shorter than this, a stop the fixes show was travelled through is dissolved.
    static let longestTravelledThroughStop: TimeInterval = 30 * 60

    /// Shorter than this, a stop only visit monitoring reported was not a stop.
    static let shortestStop: TimeInterval = 3 * 60
    /// Shorter than this, a visit-only stop with a walking step rate was walked through.
    static let shortestWalkedThroughStop: TimeInterval = 8 * 60

    /// Nobody is in two places at once. An automatic stop that runs into the next one
    /// ends where it begins; one that runs straight past a stop far away ends there and
    /// resumes after it.
    private func separateOverlappingStops(_ places: inout [VisitPlace]) throws -> Bool {
        var changed = false
        places.sort { $0.arrivalDate < $1.arrivalDate }
        var index = 0
        while index < places.count - 1 {
            let current = places[index]
            let next = places[index + 1]
            defer { index += 1 }
            guard let currentEnd = current.departureDate, currentEnd > next.arrivalDate,
                  next.arrivalDate > current.arrivalDate
            else { continue }
            let nextEnd = next.departureDate ?? .distantFuture

            if isAutomaticStop(current) {
                if nextEnd >= currentEnd {
                    current.departureDate = next.arrivalDate
                    changed = true
                    continue
                }
                // Contained. Only a stop clearly elsewhere splits this one; a nearby one
                // with a different name trims it when little time is left after.
                let far = Self.distanceMeters(from: current.coordinate, to: next.coordinate) > Self.overlappingStayMatchDistance
                let remaining = currentEnd.timeIntervalSince(nextEnd)
                if far, remaining >= SampleStayInference.Configuration().minimumStayDuration {
                    let resumed = VisitPlace(
                        arrivalDate: nextEnd,
                        departureDate: currentEnd,
                        latitude: current.latitude,
                        longitude: current.longitude,
                        horizontalAccuracy: current.horizontalAccuracy,
                        userLabel: current.userLabel,
                        autoLabel: current.autoLabel,
                        comment: current.comment
                    )
                    resumed.knownPlace = current.knownPlace
                    resumed.assignmentSource = current.assignmentSource
                    resumed.assignmentConfidence = current.assignmentConfidence
                    resumed.countryCode = current.countryCode
                    resumed.locality = current.locality
                    resumed.administrativeArea = current.administrativeArea
                    resumed.thoroughfare = current.thoroughfare
                    resumed.formattedAddress = current.formattedAddress
                    resumed.dayTimeline = try timeline(for: nextEnd, at: resumed.coordinate)
                    modelContext.insert(resumed)
                    for move in Array(current.outgoingMoves) where !isUserCurated(move) && move.startDate >= nextEnd {
                        move.startPlace = resumed
                    }
                    current.departureDate = next.arrivalDate
                    places.append(resumed)
                    places.sort { $0.arrivalDate < $1.arrivalDate }
                    changed = true
                } else if remaining < SampleStayInference.Configuration().minimumStayDuration {
                    current.departureDate = next.arrivalDate
                    changed = true
                }
            } else if isAutomaticStop(next), nextEnd > currentEnd {
                next.arrivalDate = currentEnd
                changed = true
            }
        }
        return changed
    }

    /// Trips that cannot both be true: two automatic trips at once, or a trip whose
    /// stops are gone. The one between neighbouring stops stays; the person's trips always do.
    private func deleteConflictingAutomaticMoves(
        among places: [VisitPlace],
        from start: Date,
        through end: Date
    ) throws {
        let moves = try modelContext.fetch(
            FetchDescriptor<MoveSegment>(
                predicate: #Predicate { move in
                    move.endDate >= start && move.startDate <= end && move.dayTimeline != nil
                },
                sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
            )
        )
        // Also in code: a row retired earlier in this pass is not saved yet.
        .filter { !$0.isDeleted && !TimelineRetirement.isRetired($0) }
        let ordered = places.sorted { $0.arrivalDate < $1.arrivalDate }
        var position: [UUID: Int] = [:]
        for (index, place) in ordered.enumerated() { position[place.id] = index }
        func joinsNeighbours(_ move: MoveSegment) -> Bool {
            guard let from = move.startPlace.flatMap({ position[$0.id] }),
                  let to = move.endPlace.flatMap({ position[$0.id] }) else { return false }
            return to == from + 1
        }

        var deleted = Set<UUID>()
        for move in moves where !isUserCurated(move) && move.origin == .sensor {
            // A trip of a minute or less between stops is not one the rebuild would build
            // (`moveLegs` needs more), so it is a leftover; with fixes spanning minutes it
            // showed as a walk at hundreds of miles an hour.
            if move.endDate.timeIntervalSince(move.startDate) <= 60,
               !move.samples.contains(where: { $0.source == .routeTracking || $0.source == .watchRouteTracking }) {
                retire(move)
                deleted.insert(move.id)
                continue
            }
            if move.startPlace == nil || move.endPlace == nil || move.startPlace?.isDeleted == true || move.endPlace?.isDeleted == true
                || move.startPlace.map(TimelineRetirement.isRetired) == true
                || move.endPlace.map(TimelineRetirement.isRetired) == true {
                retire(move)
                deleted.insert(move.id)
            }
        }
        let live = moves.filter { !deleted.contains($0.id) }
        for (index, move) in live.enumerated() {
            guard !deleted.contains(move.id) else { continue }
            for other in live[(index + 1)...] {
                guard other.startDate < move.endDate else { break }
                guard !deleted.contains(other.id) else { continue }
                let overlap = min(move.endDate, other.endDate).timeIntervalSince(max(move.startDate, other.startDate))
                let sameSpan = move.startDate == other.startDate && move.endDate == other.endDate
                guard overlap > 1 || sameSpan else { continue }
                let moveFixed = isUserCurated(move) || move.origin != .sensor
                let otherFixed = isUserCurated(other) || other.origin != .sensor
                if moveFixed && otherFixed { continue }
                let loser: MoveSegment
                if moveFixed {
                    loser = other
                } else if otherFixed {
                    loser = move
                } else if joinsNeighbours(move) != joinsNeighbours(other) {
                    loser = joinsNeighbours(move) ? other : move
                } else {
                    loser = move.createdAt <= other.createdAt ? other : move
                }
                retire(loser)
                deleted.insert(loser.id)
                if loser.id == move.id { break }
            }
        }
    }

    /// How far back to read fixes. A week covers a missed visit that is still
    /// on screen, without rewriting the whole diary on every launch.
    private func reconciliationWindowStart(through end: Date) throws -> Date {
        end.addingTimeInterval(-7 * 24 * 60 * 60)
    }

    private func placesArriving(from start: Date, through end: Date) throws -> [VisitPlace] {
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= start && place.arrivalDate <= end && place.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
        )
        // Retired stops are not evidence and must never be matched, extended, or revived.
        // Also in code: a stop retired earlier in this pass is not saved yet.
        return try modelContext.fetch(descriptor).filter { !$0.isDeleted && !TimelineRetirement.isRetired($0) }
    }

    /// A correction, an import, a comment, a hand-drawn route, a Health workout, or a
    /// reviewed trip is the person's account of it. Automatic repair must leave it alone.
    private func isUserCurated(_ move: MoveSegment) -> Bool {
        !move.permitsAutomaticModeChanges
    }

    private static let stayMatchDistance: CLLocationDistance = 120
    /// A person cannot be in two places at once, so stops that overlap in time are one
    /// presence unless they are clearly apart. City fixes wander this far around a door.
    private static let overlappingStayMatchDistance: CLLocationDistance = 300
    /// Wider than `stayMatchDistance`: a reconstruction's centre drifts from the visit.
    private static let removedStopMatchDistance: CLLocationDistance = 200

    /// Cuts a stop so it does not swallow a visit that fixes put somewhere else.
    private func split(_ stay: SampleStay, aroundFarPlaces places: [VisitPlace]) -> [SampleStay] {
        let stayEnd = stay.presenceEnd
        let blockers = places
            .filter { Self.distanceMeters(from: stay.coordinate, to: $0.coordinate) > Self.overlappingStayMatchDistance }
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
                let placeEnd = place.departureDate ?? place.arrivalDate
                let overlaps = place.arrivalDate < stay.presenceEnd && placeEnd > stay.arrivalDate
                let reach = overlaps ? Self.overlappingStayMatchDistance : Self.stayMatchDistance
                return Self.distanceMeters(from: stay.coordinate, to: place.coordinate) <= reach
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

    private func extend(
        _ place: VisitPlace,
        toCover stay: SampleStay,
        among places: [VisitPlace],
        evidence: StopRebuildEvidence
    ) throws {
        // Times the person set, and history they brought in, are not reconstructions.
        guard place.origin == .sensor else { return }

        // Never past what the fixes support: the boundary rules after matching would
        // only trim it back, and the write would repeat on every pass.
        // Earlier only as far as the first fix actually at this stop: a cluster's first
        // members can be the walk in, and taking them pulled the arrival back into the
        // trip on every pass.
        var earliest = stay.arrivalDate
        if stay.arrivalDate < place.arrivalDate, isAutomaticStop(place) {
            // A good fix only: a 200 m fix is "inside" anything within 400 m.
            earliest = evidence.fixes(from: stay.arrivalDate, through: place.arrivalDate)
                .first {
                    $0.horizontalAccuracy <= StopBoundaryEvidence.maximumOutsideAccuracy
                        && StopBoundaryEvidence.isInside($0, centre: place.coordinate)
                }?
                .timestamp ?? place.arrivalDate
        }
        let proposedArrival = settledArrival(
            for: place,
            proposed: clampedArrival(min(place.arrivalDate, earliest), for: place, among: places),
            evidence: evidence
        )
        if proposedArrival != place.arrivalDate {
            place.arrivalDate = proposedArrival
        }

        let nextDifferent = nextDifferentPlace(after: place, among: places)
        if let stayEnd = stay.departureDate {
            var capped = stayEnd
            if let next = nextDifferent {
                capped = min(capped, next.arrivalDate)
            }
            if capped > place.arrivalDate {
                capped = settledDeparture(for: place, proposed: capped, among: places, evidence: evidence)
                if let current = place.departureDate {
                    if capped.timeIntervalSince(current) >= 1 {
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
        } else if let current = place.departureDate, stay.lastInsideDate > current,
                  settledDeparture(for: place, proposed: stay.lastInsideDate, among: places, evidence: evidence)
                    >= stay.lastInsideDate {
            // Reopened only when the fixes do not show it ended. Guarded: writing nil over
            // nil still dirties the row and saved every pass.
            place.departureDate = nil
        }

        if stay.horizontalAccuracy < place.horizontalAccuracy {
            place.horizontalAccuracy = stay.horizontalAccuracy
        }
        let day = try timeline(for: place.arrivalDate, at: place.coordinate)
        if place.dayTimeline?.persistentModelID != day.persistentModelID {
            place.dayTimeline = day
        }
    }

    /// Removal is user intent, including when an old staged import is resumed later.
    /// Keep tombstones; filtering a repair window must not erase older decisions.
    private func removedSpans(since start: Date) throws -> [RemovedTimelineSpan] {
        try modelContext.fetch(FetchDescriptor<RemovedTimelineSpan>(predicate: #Predicate { $0.endDate >= start }))
    }

    private func importStopWasRemoved(start: Date, end: Date, coordinate: CLLocationCoordinate2D,
                                      spans: [RemovedTimelineSpan]) -> Bool {
        spans.contains { span in
            span.kind == .stop && span.startDate < end && span.endDate > start
                && Self.distanceMeters(from: coordinate, to: .init(latitude: span.latitude, longitude: span.longitude)) <= Self.removedStopMatchDistance
        }
    }

    private func wasRemoved(_ stay: SampleStay, spans: [RemovedTimelineSpan]) -> Bool {
        spans.contains { span in
            span.kind == .stop
                && span.startDate < stay.presenceEnd
                && span.endDate > stay.arrivalDate
                && Self.distanceMeters(
                    from: stay.coordinate,
                    to: CLLocationCoordinate2D(latitude: span.latitude, longitude: span.longitude)
                ) <= Self.removedStopMatchDistance
        }
    }

    /// A trip counts as removed when most of the gap it would fill was removed.
    private func wasRemoved(tripFrom start: Date, to end: Date, spans: [RemovedTimelineSpan]) -> Bool {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return false }
        return spans.contains { span in
            guard span.kind == .trip else { return false }
            let overlap = min(end, span.endDate).timeIntervalSince(max(start, span.startDate))
            return overlap >= duration / 2
        }
    }

    func recordRemoval(of visit: VisitPlace) {
        modelContext.insert(
            RemovedTimelineSpan(
                kind: .stop,
                startDate: visit.arrivalDate,
                endDate: visit.departureDate ?? max(visit.arrivalDate, .now),
                latitude: visit.latitude,
                longitude: visit.longitude
            )
        )
    }

    func recordRemoval(of move: MoveSegment) {
        modelContext.insert(
            RemovedTimelineSpan(
                kind: .trip,
                startDate: move.startDate,
                endDate: move.endDate,
                latitude: move.startPlace?.latitude ?? 0,
                longitude: move.startPlace?.longitude ?? 0
            )
        )
    }

    private func makePlace(for stay: SampleStay, among places: [VisitPlace]) throws -> VisitPlace {
        var departure = stay.departureDate
        let draft = VisitPlace(
            arrivalDate: stay.arrivalDate,
            departureDate: departure,
            latitude: stay.latitude,
            longitude: stay.longitude,
            horizontalAccuracy: max(stay.horizontalAccuracy, 20),
            userLabel: try nearbyUserLabel(near: stay.coordinate)
        )
        if departure == nil, let next = nextDifferentPlace(after: draft, among: places), next.arrivalDate > stay.lastInsideDate {
            departure = min(stay.lastInsideDate, next.arrivalDate)
            draft.departureDate = departure
        }
        draft.dayTimeline = try timeline(for: draft.arrivalDate, at: draft.coordinate)
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
        // Moving the arrival forward must not carry it past the departure: that made
        // stops of negative length.
        var clamped = max(proposed, boundary)
        // Reaching back toward a stop elsewhere leaves at least the shortest trip between
        // them: touching it again would only reopen the jump rule, pass after pass.
        if proposed < place.arrivalDate {
            clamped = max(clamped, min(place.arrivalDate, boundary.addingTimeInterval(StopBoundaryEvidence.jumpMinimumTrip)))
        }
        if let departure = place.departureDate, clamped > departure {
            return max(proposed, min(clamped, departure))
        }
        return clamped
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
        samples: [LocationSample],
        stays: [SampleStay] = []
    ) throws {
        var index = 0
        while index < places.count - 1 {
            let current = places[index]
            let next = places[index + 1]
            let distance = Self.distanceMeters(from: current.coordinate, to: next.coordinate)
            let currentEnd = current.departureDate ?? current.arrivalDate
            let gap = next.arrivalDate.timeIntervalSince(currentEnd)
            // A clean handoff (one visit ends as the next begins) stays two
            // visits. Merge only when they overlap, or when fixes in the gap
            // show the phone never left and the split was a false departure.
            let overlaps = currentEnd.timeIntervalSince(next.arrivalDate) > 60
            // The exception is the same named place, where fixes wander but the place does not.
            let currentName = current.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sameNamedHandoff = abs(gap) <= 60
                && !currentName.isEmpty
                && currentName == next.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Wander around a door stays inside one stay the fixes show. A stay of its own
            // there, begun after this stop ended, is a short walk to a real second stop.
            let nextStayedApart = stays.contains { stay in
                stay.arrivalDate >= currentEnd.addingTimeInterval(-60)
                    && stay.arrivalDate < (next.departureDate ?? .distantFuture)
                    && Self.distanceMeters(from: stay.coordinate, to: next.coordinate) <= Self.stayMatchDistance
            }
            let phantom = !nextStayedApart && hasPhantomTrip(from: current, to: next, separation: distance)
            let reach = overlaps || sameNamedHandoff || phantom
                ? Self.overlappingStayMatchDistance
                : Self.stayMatchDistance
            guard current.origin == .sensor, next.origin == .sensor, distance <= reach else {
                index += 1
                continue
            }

            let stayed = gap > 60 && gap <= 12 * 60 * 60 && samplesProvePresence(
                from: currentEnd,
                to: next.arrivalDate,
                around: current.coordinate,
                samples: samples
            )
            guard overlaps || stayed || sameNamedHandoff || phantom else {
                index += 1
                continue
            }

            if labelsConflict(current, next) {
                index += 1
                continue
            }

            // The centre comes from the joined stay's own fixes, so one indoor fix that
            // claims to be precise cannot drag it down the street. Without enough good
            // fixes, keep whichever centre the system was surer of. The name follows the
            // surer report either way.
            let joinedStart = min(current.arrivalDate, next.arrivalDate)
            let joinedEnd = max(
                current.departureDate ?? current.arrivalDate,
                next.departureDate ?? next.arrivalDate
            )
            let robust = Self.joinedStayCenter(in: samples, stays: stays, from: joinedStart, to: joinedEnd)
            if let robust {
                current.latitude = robust.latitude
                current.longitude = robust.longitude
            }
            if next.horizontalAccuracy < current.horizontalAccuracy {
                if robust == nil {
                    current.latitude = next.latitude
                    current.longitude = next.longitude
                }
                if let label = next.autoLabel, !label.isEmpty {
                    current.autoLabel = label
                }
            }
            mergePlace(next, into: current)
            // The trip between them, if any, now goes nowhere.
            for move in Array(current.outgoingMoves) where move.endPlace?.id == current.id && !isUserCurated(move) {
                retire(move)
            }
            if let nextDeparture = next.departureDate, nextDeparture > (current.departureDate ?? current.arrivalDate) {
                current.departureDate = nextDeparture
            } else if next.departureDate == nil {
                current.departureDate = nil
            }
            current.arrivalDate = min(current.arrivalDate, next.arrivalDate)
            retire(next)
            places.remove(at: index + 1)
        }
    }

    /// A short hop between two ends that barely differ, with almost no steps, is GPS
    /// wandering around a door rather than a departure.
    private func hasPhantomTrip(from current: VisitPlace, to next: VisitPlace, separation: CLLocationDistance) -> Bool {
        guard separation <= Self.phantomTripMaximumSeparation else { return false }
        return current.outgoingMoves.contains { move in
            move.endPlace?.id == next.id
                && !isUserCurated(move)
                && move.endDate.timeIntervalSince(move.startDate) <= 5 * 60
                && (move.stepCount ?? 0) < Self.phantomTripMaximumSteps
        }
    }

    static let phantomTripMaximumSeparation: CLLocationDistance = 150
    static let phantomTripMaximumSteps = 60

    private func labelsConflict(_ lhs: VisitPlace, _ rhs: VisitPlace) -> Bool {
        let left = lhs.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !left.isEmpty, !right.isEmpty, left != right { return true }
        if let leftPlace = lhs.knownPlace?.id, let rightPlace = rhs.knownPlace?.id, leftPlace != rightPlace {
            return true
        }
        return false
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

    /// Nobody is in two places at once. When stops clearly apart still overlap, a stray
    /// fix stretched the earlier one, so it ends as the later one begins. A stop wholly
    /// inside a longer one is left alone here: cutting there would drop the time after it.
    /// Two stops that end together are not that case; the earlier one ends as the later begins.
    private func trimOverlappingStops(_ places: [VisitPlace]) {
        let ordered = places.sorted { $0.arrivalDate < $1.arrivalDate }
        for (current, next) in zip(ordered, ordered.dropFirst()) {
            guard current.origin == .sensor,
                  let departure = current.departureDate,
                  departure.timeIntervalSince(next.arrivalDate) > 60,
                  let nextDeparture = next.departureDate,
                  nextDeparture >= departure,
                  next.arrivalDate > current.arrivalDate
            else { continue }
            current.departureDate = next.arrivalDate
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
                    move.endDate >= start && move.startDate <= end && move.dayTimeline != nil
                }
            )
        )

        for move in moves where !isUserCurated(move) && !move.isDeleted && !TimelineRetirement.isRetired(move) {
            guard shouldDeleteAutomaticMove(move, places: places) else { continue }
            retire(move)
        }
    }

    private func shouldDeleteAutomaticMove(_ move: MoveSegment, places: [VisitPlace]) -> Bool {
        // Merging two stops leaves the trip between them going nowhere.
        if let start = move.startPlace?.id, start == move.endPlace?.id { return true }

        if anotherPlaceOverlaps(
            from: move.startDate,
            to: move.endDate,
            startPlaceID: move.startPlace?.id,
            endPlaceID: move.endPlace?.id,
            among: places
        ) { return true }

        if let departure = move.startPlace?.departureDate,
           move.startDate.addingTimeInterval(5 * 60) < departure {
            return true
        }

        if move.endDate.timeIntervalSince(move.endPlace?.arrivalDate ?? move.endDate) > 5 * 60 {
            return true
        }

        // A short slow hop labeled as a ride is the walk off the bus. Drop it so the
        // next pass can classify it from the gap's own steps, but only if that would
        // change the answer: a crawling bus keeps its label, and deleting it here would
        // rebuild the same trip on every pass.
        // The same rule chain new trips go through, so the rebuilt trip is not deleted again.
        if let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate,
           move.transportMode == .automotive || move.transportMode == .stationary || move.transportMode == .unknown {
            let straightLine = Self.distanceMeters(from: start, to: end)
            let duration = move.endDate.timeIntervalSince(move.startDate)
            if LastBlockWalk.isShape(distance: straightLine, duration: duration) {
                let relabeled = AutomaticTransportModes.load().allowedMode(StepModeRules.refinedMode(
                    proposed: move.transportMode,
                    straightLine: straightLine,
                    duration: duration,
                    stepCount: move.knownStepCount,
                    locations: []
                ))
                if relabeled != move.transportMode { return true }
            }
        }

        return false
    }

    /// True when a stop other than the trip's own ends covers part of the trip's middle.
    /// Shared by the cleanup above and `moveLegs`, so a pass never builds a trip that the
    /// next pass would delete: that loop deleted and recreated the same trip on every batch.
    private func anotherPlaceOverlaps(
        from start: Date,
        to end: Date,
        startPlaceID: UUID?,
        endPlaceID: UUID?,
        among places: [VisitPlace]
    ) -> Bool {
        places.contains { place in
            guard place.id != startPlaceID, place.id != endPlaceID else { return false }
            let placeEnd = place.departureDate ?? place.arrivalDate
            let overlapsStart = placeEnd > start.addingTimeInterval(60)
            let overlapsEnd = place.arrivalDate < end.addingTimeInterval(-60)
            return overlapsStart && overlapsEnd
        }
    }

    /// How long after a trip ends a pass may still retry an unknown mode. Motion history
    /// for a trip settles within minutes; past this, retrying only rewrote the same rows
    /// on every batch (a mode the person turned off reads as unknown forever).
    static let unknownModeRetryWindow: TimeInterval = 24 * 60 * 60

    private func moveLegs(
        among places: [VisitPlace],
        samples: [LocationSample],
        removedSpans: [RemovedTimelineSpan],
        from start: Date,
        through end: Date
    ) throws -> [SampleStayMoveLeg] {
        let ordered = places.sorted { $0.arrivalDate < $1.arrivalDate }
        var legs: [SampleStayMoveLeg] = []

        for index in ordered.indices.dropLast() {
            let origin = ordered[index]
            let destination = ordered[index + 1]
            // A stop whose arrival was clamped past its departure has not left before it
            // arrived: the trip starts no earlier than the arrival.
            let legStart = max(origin.departureDate ?? origin.arrivalDate, origin.arrivalDate)
            let legEnd = destination.arrivalDate
            guard legEnd.timeIntervalSince(legStart) > 60 else { continue }
            guard legEnd >= start, legStart <= end else { continue }
            let straightLine = Self.distanceMeters(from: origin.coordinate, to: destination.coordinate)
            var keptMode: TransportMode?
            var keptDistance: Double?
            let stored = try findMove(startPlaceID: origin.id, endPlaceID: destination.id)
            if let existing = try existingConsistentMove(from: origin, to: destination, start: legStart, end: legEnd, now: end) {
                guard !isUserCurated(existing) else { continue }
                // A trip's times are its stops' times, which follow the fixes. A stale start
                // or end (kept within the old five-minute tolerance) is how a trip came to
                // show no duration at all once its stop was trimmed past it.
                let timesMoved = abs(existing.startDate.timeIntervalSince(legStart)) >= 1
                    || abs(existing.endDate.timeIntervalSince(legEnd)) >= 1
                switch storedTripRefresh(existing, straightLine: straightLine, samples: samples) {
                case .none where timesMoved:
                    keptMode = existing.transportMode
                case .none:
                    continue
                case .fixesOrDistance:
                    // Same trip, new evidence: times, fixes, and distance follow; the mode stays.
                    keptMode = existing.transportMode
                case .mode:
                    break
                }
            } else if let stored, !isUserCurated(stored),
                      abs(stored.startDate.timeIntervalSince(legStart)) < 1,
                      abs(stored.endDate.timeIntervalSince(legEnd)) < 1,
                      storedTripRefresh(stored, straightLine: straightLine, samples: samples) == .none {
                // Only the mode is being retried. A distance a route match or Health refined stays.
                keptDistance = stored.distanceMeters
            }
            if anotherPlaceOverlaps(
                from: legStart,
                to: legEnd,
                startPlaceID: origin.id,
                endPlaceID: destination.id,
                among: ordered
            ) {
                continue
            }
            if wasRemoved(tripFrom: legStart, to: legEnd, spans: removedSpans) {
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

            let interior = reliable.filter { $0.timestamp > legStart && $0.timestamp < legEnd }.count
            legs.append(
                SampleStayMoveLeg(
                    startPlace: origin,
                    endPlace: destination,
                    startDate: legStart,
                    endDate: legEnd,
                    // Never shorter than the line between its own ends.
                    distanceMeters: max(LocationLogGeometry.pathDistance(routed), straightLine),
                    locations: routed.map(\.location),
                    straightLineMeters: straightLine,
                    interiorFixCount: interior,
                    existingMoveID: stored?.id,
                    keptMode: keptMode,
                    keptDistance: keptDistance
                )
            )
        }

        return legs
    }

    private enum StoredTripRefresh: Equatable {
        case none
        /// Its fixes or ends changed under it.
        case fixesOrDistance
        /// Step evidence rules out the mode it has.
        case mode
    }

    /// Whether an automatic trip the rebuild would keep has gone stale.
    ///
    /// Each condition is one the rebuilt trip no longer meets, so a refresh happens once:
    /// a distance under the straight line between its ends (an end moved), a fix inside
    /// it that is not part of it (a fix arrived late), or a walk or run its own measured
    /// steps rule out.
    private func storedTripRefresh(
        _ move: MoveSegment,
        straightLine: CLLocationDistance,
        samples: [LocationSample]
    ) -> StoredTripRefresh {
        let duration = move.endDate.timeIntervalSince(move.startDate)
        if move.transportMode == .walking || move.transportMode == .running,
           move.permitsAutomaticModeChanges,
           let proposed = ImplausibleWalk.stepEvidenceMode(
               proposed: move.transportMode,
               straightLine: straightLine,
               duration: duration,
               stepCount: move.knownStepCount
           ) ?? ImplausibleFootPace.mode(
               proposed: move.transportMode,
               distance: max(move.distanceMeters, straightLine),
               duration: duration,
               stepCount: move.knownStepCount
           ),
           AutomaticTransportModes.load().allowedMode(proposed) != move.transportMode {
            return .mode
        }
        if move.distanceMeters < straightLine * 0.9 - 1 { return .fixesOrDistance }
        let start = move.startDate
        let end = move.endDate
        // Strictly inside: a fix at a stop boundary may belong to the trip on either side.
        // `samples` is sorted by time.
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp <= start { low = mid + 1 } else { high = mid }
        }
        let unattached = samples[low...].prefix { $0.timestamp < end }.contains { sample in
            sample.moveSegment?.persistentModelID != move.persistentModelID
                && !(sample.moveSegment.map(isUserCurated) ?? false)
        }
        return unattached ? .fixesOrDistance : .none
    }

    private func existingConsistentMove(
        from origin: VisitPlace,
        to destination: VisitPlace,
        start: Date,
        end: Date,
        now: Date
    ) throws -> MoveSegment? {
        guard let existing = try findMove(startPlaceID: origin.id, endPlaceID: destination.id) else {
            return nil
        }
        if isUserCurated(existing) { return existing }
        let startDelta = abs(existing.startDate.timeIntervalSince(start))
        let endDelta = abs(existing.endDate.timeIntervalSince(end))
        guard startDelta <= 5 * 60, endDelta <= 5 * 60 else { return nil }
        if existing.transportMode == .unknown,
           now.timeIntervalSince(existing.endDate) < Self.unknownModeRetryWindow {
            return nil
        }
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

        // The local day where the trip starts, at the stop it leaves from.
        let timeline = try timeline(for: startDate, at: startPlace.coordinate)

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
            if newRowOrigin == .imported, isUserCurated(existing) {
                return existing
            }
            move = existing
            // Writes only what differs, so re-applying the same trip leaves nothing to save.
            if move.dedupeKey != dedupeKey { move.dedupeKey = dedupeKey }
            if move.permitsAutomaticModeChanges, move.transportMode != transportMode {
                move.transportMode = transportMode
            }
            if move.distanceMeters != distanceMeters { move.distanceMeters = distanceMeters }
            // A later source without pedometer data must not erase recorded steps.
            if let stepCount, move.stepCount != stepCount { move.stepCount = stepCount }
            if move.startDate != startDate { move.startDate = startDate }
            if move.endDate != endDate { move.endDate = endDate }
        } else {
            move = MoveSegment(
                dedupeKey: dedupeKey,
                startDate: startDate,
                endDate: endDate,
                transportMode: transportMode,
                distanceMeters: distanceMeters,
                stepCount: stepCount
            )
            move.origin = newRowOrigin
            modelContext.insert(move)
        }

        if move.startPlace?.persistentModelID != startPlace.persistentModelID { move.startPlace = startPlace }
        if move.endPlace?.persistentModelID != endPlace.persistentModelID { move.endPlace = endPlace }
        if move.dayTimeline?.persistentModelID != timeline.persistentModelID { move.dayTimeline = timeline }

        for sample in samples where sample.moveSegment?.persistentModelID != move.persistentModelID {
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
                place.id == placeID && place.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 1

        guard let place = try modelContext.fetch(descriptor).first, !TimelineRetirement.isRetired(place) else {
            return
        }

        if let userLabel = place.userLabel, !userLabel.isEmpty {
            return
        }
        if let existingAuto = place.autoLabel, !existingAuto.isEmpty {
            return
        }
        if place.assignmentSource != .none || place.knownPlace != nil {
            return
        }

        let nearby = try knownPlaces(
            near: place.coordinate,
            within: PlaceLearningEngine.rejectedLabelSearchRadius
        )
        let readable = PlaceDisplayNamer.normalizedAutomaticLabel(trimmed)
        if PlaceLearningEngine.shouldSuppress(trimmed, nearbyPlaces: nearby)
            || PlaceLearningEngine.shouldSuppress(readable, nearbyPlaces: nearby) {
            return
        }

        place.autoLabel = readable
        try saveIfNeeded()
    }

    func saveIfNeeded() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    func dissolveVisit(_ visit: VisitPlace) throws -> DissolveVisitResult {
        try performingUndoableChange(named: "Not a Stop") {
            let incoming = visit.incomingMoves.sorted { $0.endDate < $1.endDate }.last
            let outgoing = visit.outgoingMoves.sorted { $0.startDate < $1.startDate }.first
            guard let incoming, let outgoing, incoming.id != outgoing.id else {
                throw TimelineEditingError.missingNeighbors
            }

            recordRemoval(of: visit)
            visit.keepPhotosOnDay()

            // Earlier dissolves can leave several legs meeting here. Those join the same
            // neighbours as the kept legs instead of losing their endpoint with the visit.
            for move in visit.incomingMoves where move.id != incoming.id {
                move.endPlace = outgoing.endPlace
            }
            for move in visit.outgoingMoves where move.id != outgoing.id {
                move.startPlace = incoming.startPlace
            }

            if incoming.transportMode == outgoing.transportMode {
                return .merged(mergeSameModeLegs(incoming: incoming, outgoing: outgoing, visit: visit))
            }
            let connected = connectDifferentModeLegs(incoming: incoming, outgoing: outgoing, visit: visit)
            return .connected(incoming: connected.incoming, outgoing: connected.outgoing)
        }
    }

    func mergeVisits(_ a: VisitPlace, _ b: VisitPlace) throws -> VisitPlace {
        try performingUndoableChange(named: "Merge Places") {
            guard a.id != b.id else { throw TimelineEditingError.cannotMergeSameVisit }

            let first = a.arrivalDate <= b.arrivalDate ? a : b
            let second = first.id == a.id ? b : a

            first.departureDate = maxDeparture(first.departureDate, second.departureDate)
            if first.horizontalAccuracy <= 0 || (second.horizontalAccuracy > 0 && second.horizontalAccuracy < first.horizontalAccuracy) {
                first.latitude = second.latitude
                first.longitude = second.longitude
                first.horizontalAccuracy = second.horizontalAccuracy
            } else {
                first.latitude = (first.latitude + second.latitude) / 2
                first.longitude = (first.longitude + second.longitude) / 2
            }

            if (first.userLabel?.isEmpty ?? true), let label = second.userLabel, !label.isEmpty {
                first.userLabel = label
            }
            if (first.autoLabel?.isEmpty ?? true), let label = second.autoLabel, !label.isEmpty {
                first.autoLabel = label
            }
            if (first.comment?.isEmpty ?? true) {
                first.comment = second.comment
            }
            if first.knownPlace == nil {
                first.knownPlace = second.knownPlace
                first.assignmentSource = second.assignmentSource
                first.assignmentConfidence = second.assignmentConfidence
            }

            let connecting = (first.outgoingMoves + second.incomingMoves).filter { move in
                (move.startPlace?.id == first.id && move.endPlace?.id == second.id)
                    || (move.startPlace?.id == second.id && move.endPlace?.id == first.id)
            }
            for move in connecting {
                for sample in move.samples {
                    sample.moveSegment = nil
                }
                modelContext.delete(move)
            }

            for move in second.incomingMoves where move.endPlace?.id == second.id {
                move.endPlace = first
            }
            for move in second.outgoingMoves where move.startPlace?.id == second.id {
                move.startPlace = first
            }

            for photo in second.photoAttachments {
                photo.visitPlace = first
            }

            modelContext.delete(second)
            return first
        }
    }

    func splitMove(_ move: MoveSegment, at date: Date) throws -> (MoveSegment, VisitPlace, MoveSegment) {
        try performingUndoableChange(named: "Split Move") {
            guard date > move.startDate, date < move.endDate else {
                throw TimelineEditingError.invalidSplitTime
            }
            guard let startPlace = move.startPlace, let endPlace = move.endPlace else {
                throw TimelineEditingError.missingNeighbors
            }

            let originalEndDate = move.endDate
            let originalDistance = move.distanceMeters
            let hadManualRoute = move.manualRouteCoordinatesData != nil
            let progress = TimelineLocator.progress(of: date, on: move)
            let coordinates = TimelineLocator.displayedCoordinates(for: move)
            let splitCoordinate = TimelineLocator.interpolate(along: coordinates, progress: progress)
                ?? startPlace.coordinate
            let (firstCoordinates, secondCoordinates) = TimelineLocator.split(coordinates, at: progress)

            let visit = VisitPlace(
                arrivalDate: date,
                departureDate: date,
                latitude: splitCoordinate.latitude,
                longitude: splitCoordinate.longitude,
                horizontalAccuracy: max(startPlace.horizontalAccuracy, 15)
            )
            visit.origin = .manual
            visit.dayTimeline = try timeline(for: date)
            modelContext.insert(visit)

            let lateSamples = move.samples.filter { $0.timestamp > date }

            move.endPlace = visit
            move.endDate = date
            move.distanceMeters = distanceMeters(
                along: firstCoordinates,
                fallback: originalDistance * progress
            )
            applySplitCoordinates(
                firstCoordinates,
                to: move,
                tag: "split-a-\(move.id.uuidString)",
                preferManual: hadManualRoute
            )

            let secondEnd = max(originalEndDate, date.addingTimeInterval(1))
            let second = MoveSegment(
                dedupeKey: Self.makeMoveDedupeKey(
                    startPlaceID: visit.id,
                    endPlaceID: endPlace.id,
                    startDate: date,
                    endDate: secondEnd
                ),
                startDate: date,
                endDate: secondEnd,
                transportMode: move.transportMode,
                distanceMeters: distanceMeters(
                    along: secondCoordinates,
                    fallback: originalDistance * (1 - progress)
                ),
                stepCount: nil,
                comment: move.comment
            )
            second.startPlace = visit
            second.endPlace = endPlace
            second.dayTimeline = try timeline(for: date)
            second.origin = move.origin
            second.transportModeSource = move.transportModeSource
            second.routeMatchPolicy = move.routeMatchPolicy
            second.routeMatchConfidence = move.routeMatchConfidence
            second.routeMatchSummary = move.routeMatchSummary
            modelContext.insert(second)

            for sample in lateSamples {
                sample.moveSegment = second
            }
            applySplitCoordinates(
                secondCoordinates,
                to: second,
                tag: "split-b-\(second.id.uuidString)",
                preferManual: hadManualRoute
            )

            return (move, visit, second)
        }
    }

    func splitVisit(_ visit: VisitPlace, at date: Date) throws -> (VisitPlace, VisitPlace) {
        try performingUndoableChange(named: "Split Place") {
            let originalDeparture = visit.departureDate
            let latest: Date
            if let originalDeparture, originalDeparture > visit.arrivalDate {
                latest = originalDeparture
            } else {
                latest = visit.outgoingMoves.map(\.startDate).min() ?? date.addingTimeInterval(1)
            }
            guard date > visit.arrivalDate, date < latest else {
                throw TimelineEditingError.invalidSplitTime
            }

            visit.departureDate = date
            if visit.origin == .sensor {
                visit.origin = .manual
            }

            let second = VisitPlace(
                arrivalDate: date,
                departureDate: originalDeparture,
                latitude: visit.latitude,
                longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                userLabel: visit.userLabel,
                autoLabel: visit.autoLabel,
                comment: visit.comment
            )
            second.origin = .manual
            second.knownPlace = visit.knownPlace
            second.assignmentSource = visit.assignmentSource
            second.assignmentConfidence = visit.assignmentConfidence
            second.countryCode = visit.countryCode
            second.locality = visit.locality
            second.administrativeArea = visit.administrativeArea
            second.dayTimeline = try timeline(for: date)
            modelContext.insert(second)

            for move in visit.outgoingMoves {
                move.startPlace = second
            }

            return (visit, second)
        }
    }

    func updateTimes(of visit: VisitPlace, arrival: Date, departure: Date?) throws {
        try performingUndoableChange(named: "Edit Times") {
            if let departure, arrival > departure {
                throw TimelineEditingError.invalidTimeRange
            }

            visit.arrivalDate = arrival
            visit.departureDate = departure
            if visit.origin == .sensor {
                visit.origin = .manual
            }

            // The local day where the new arrival falls, not the phone's date for it.
            let day = try timeline(for: arrival, at: visit.coordinate)
            if visit.dayTimeline !== day {
                visit.dayTimeline = day
            }

            for move in visit.incomingMoves {
                let previousStart = move.startDate
                move.endDate = arrival
                if move.endDate < move.startDate {
                    move.startDate = arrival.addingTimeInterval(-max(move.timelineDuration, 1))
                }
                try refileIfStartChangedDay(move, previousStart: previousStart)
            }

            if let departure {
                for move in visit.outgoingMoves {
                    let previousStart = move.startDate
                    move.startDate = departure
                    if move.endDate < move.startDate {
                        move.endDate = departure.addingTimeInterval(max(move.timelineDuration, 1))
                    }
                    try refileIfStartChangedDay(move, previousStart: previousStart)
                }
            }
        }
    }

    /// Moves are filed under the local day they start where they start, and the day's stats
    /// read that list.
    private func refileIfStartChangedDay(_ move: MoveSegment, previousStart: Date) throws {
        guard move.startDate != previousStart || move.dayTimeline == nil else { return }
        let start = move.startPlace.map(\.coordinate).flatMap { PlaceTimeZone.isUsable($0) ? $0 : nil }
        let day = try timeline(for: move.startDate, at: start)
        if move.dayTimeline !== day {
            move.dayTimeline = day
        }
    }

    func setTransportMode(_ mode: TransportMode, for move: MoveSegment, source: TransportModeSource) throws {
        try performingUndoableChange(named: "Change Mode") {
            move.transportMode = mode
            move.transportModeSource = source
            move.clearCachedRouteCoordinates()
        }
    }

    func setRouteMatchPolicy(_ policy: RouteMatchPolicy, for move: MoveSegment) throws {
        try performingUndoableChange(named: "Change Path") {
            move.routeMatchPolicy = policy
            if policy != .manual {
                move.clearManualRouteCoordinates()
                move.clearCachedRouteCoordinates()
                move.routeMatchSummary = nil
                move.routeMatchConfidence = .unknown
            }
        }
    }

    func assign(
        _ visit: VisitPlace,
        to place: KnownPlace,
        source: PlaceAssignmentSource,
        confidence: Double
    ) throws {
        try performingUndoableChange(named: "Name Place") {
            visit.knownPlace = place
            visit.assignmentSource = source
            visit.assignmentConfidence = min(max(confidence, 0), 1)
            if source == .user {
                let trimmed = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    visit.userLabel = trimmed
                }
                PlaceLearningEngine.learn(from: visit, onto: place)
                try adoptPastVisits(into: place, around: visit, seedsFootprint: false)
            }
        }
    }

    /// The person's own answer for many stays at once, as `assign(_:to:source: .user, ...)`
    /// gives each one, in one pass and one save. Confirming a place with a thousand stays
    /// used to learn, adopt, and save a thousand times.
    func assignConfirmed(_ visits: [VisitPlace], to place: KnownPlace) throws {
        guard !visits.isEmpty else { return }
        try performingUndoableChange(named: "Name Place") {
            let trimmed = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for visit in visits {
                visit.knownPlace = place
                visit.assignmentSource = .user
                visit.assignmentConfidence = 1
                if !trimmed.isEmpty {
                    visit.userLabel = trimmed
                }
            }
            PlaceLearningEngine.learn(fromBatch: visits, onto: place)
            try adoptPastVisits(into: place, around: visits, seedsFootprint: false)
        }
    }

    func createKnownPlace(from visit: VisitPlace, name: String) throws -> KnownPlace {
        try performingUndoableChange(named: "Add Place") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A place with this name already here is the same place: naming it twice
            // must not make a twin the Review inbox then calls ambiguous.
            if !trimmed.isEmpty, let existing = try sameNamedKnownPlace(trimmed, near: visit.coordinate) {
                try assign(visit, to: existing, source: .user, confidence: 1)
                return existing
            }
            let place = KnownPlace(
                name: trimmed.isEmpty ? visit.displayTitle : trimmed,
                latitude: visit.latitude,
                longitude: visit.longitude,
                footprintRadius: 40
            )
            place.countryCode = visit.countryCode
            place.locality = visit.locality
            place.administrativeArea = visit.administrativeArea
            place.thoroughfare = visit.thoroughfare
            place.formattedAddress = visit.formattedAddress
            place.confirmedVisitCount = 1
            place.lastVisitAt = visit.arrivalDate
            modelContext.insert(place)
            visit.knownPlace = place
            visit.assignmentSource = .user
            visit.assignmentConfidence = 1
            if !trimmed.isEmpty {
                visit.userLabel = trimmed
            }
            PlaceLearningEngine.learn(from: visit, onto: place)
            try adoptPastVisits(into: place, around: visit, seedsFootprint: true)
            return place
        }
    }

    // MARK: Name once, fixed everywhere

    /// Assigns the earlier stays at the spot the person just named to that place, in the
    /// same Undo step as the naming.
    ///
    /// Only stays nobody placed are taken: no `KnownPlace`, no assignment, and no name of
    /// the person's own unless it is this one. A stay the person once moved away from
    /// this place stays where they put it. The cluster grows stay by stay with the
    /// same-spot rule and never past 150 m from the named stay. Adopted stays are
    /// automatic assignments, so they never count as confirmations.
    ///
    /// A new place takes its footprint from the whole cluster; an existing place keeps
    /// its centre and only grows enough to hold what joined.
    @discardableResult
    func adoptPastVisits(
        into place: KnownPlace,
        around seed: VisitPlace,
        seedsFootprint: Bool
    ) throws -> [VisitPlace] {
        try adoptPastVisits(into: place, around: [seed], seedsFootprint: seedsFootprint)
    }

    /// `adoptPastVisits(into:around:seedsFootprint:)` grown from several named stays at
    /// once: one fetch and one cluster for all of them.
    @discardableResult
    func adoptPastVisits(
        into place: KnownPlace,
        around seeds: [VisitPlace],
        seedsFootprint: Bool
    ) throws -> [VisitPlace] {
        guard !seeds.isEmpty else { return [] }
        let placeID = place.id
        let nameKey = PlaceDisplayNamer.labelComparisonKey(place.name)
        let movedAway = Set(
            try modelContext.fetch(FetchDescriptor<PlaceCorrectionEvent>(
                predicate: #Predicate { $0.fromKnownPlaceID == placeID }
            ))
            .map(\.visitPlaceID)
        )
        let seedIDs = Set(seeds.map(\.id))
        let reach = PlaceLearningEngine.clusterRadius + PlaceLearningEngine.sameSpotMaximumDistance
        let candidates = try visitsInBox(around: seeds.map(\.coordinate), meters: reach).filter { visit in
            guard !seedIDs.contains(visit.id),
                  visit.knownPlace == nil,
                  visit.assignmentSource == .none,
                  !movedAway.contains(visit.id)
            else { return false }
            guard let own = PlaceDisplayNamer.meaningful(visit.userLabel) else { return true }
            return PlaceDisplayNamer.labelComparisonKey(own) == nameKey
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members = PlaceLearningEngine.cluster(
            around: seeds.map { PlaceLearningEngine.StaySnapshot($0, label: nil) },
            among: candidates.map { PlaceLearningEngine.StaySnapshot($0, label: nil) }
        )
        .compactMap { byID[$0.id] }
        guard !members.isEmpty else { return [] }

        for visit in members {
            visit.knownPlace = place
            visit.assignmentSource = .auto
            visit.assignmentConfidence = 1
        }

        let adopted = members.map { PlaceLearningEngine.VisitSnapshot($0) }
        if seedsFootprint {
            let confirmed = place.visits
                .filter { $0.assignmentSource == .user }
                .map(PlaceLearningEngine.VisitSnapshot.init)
            let footprint = PlaceLearningEngine.learnedFootprint(from: confirmed + adopted)
            let confirmedCount = place.confirmedVisitCount
            PlaceLearningEngine.apply(footprint, to: place)
            place.confirmedVisitCount = confirmedCount
        } else {
            let farthest = adopted
                .map { PlaceLearningEngine.distance(from: place.coordinate, to: $0.coordinate) }
                .max() ?? 0
            place.footprintRadius = PlaceLearningEngine.clampRadius(
                max(place.footprintRadius, farthest * PlaceLearningEngine.radiusGrowthFactor)
            )
            if let latest = members.map(\.arrivalDate).max(), latest > (place.lastVisitAt ?? .distantPast) {
                place.lastVisitAt = latest
            }
        }
        return members
    }

    /// A learned place with this name, folded, whose centre is within the naming search
    /// radius of `coordinate`.
    func sameNamedKnownPlace(_ name: String, near coordinate: CLLocationCoordinate2D) throws -> KnownPlace? {
        let key = PlaceDisplayNamer.labelComparisonKey(name)
        guard !key.isEmpty else { return nil }
        return try knownPlaces(near: coordinate, within: NearbyPlaceSuggester.searchRadius)
            .first { PlaceDisplayNamer.labelComparisonKey($0.name) == key }
    }

    func reusableAutomaticLabel(for placeID: UUID) throws -> String? {
        guard let place = try findPlace(byID: placeID) else { return nil }
        let reach = PlaceLearningEngine.sameSpotMaximumDistance
        let others = try visitsInBox(around: place.coordinate, meters: reach)
            .filter { $0.id != placeID && $0.knownPlace == nil && $0.assignmentSource == .none }
            .compactMap { visit -> PlaceLearningEngine.StaySnapshot? in
                guard PlaceDisplayNamer.meaningful(visit.userLabel) == nil,
                      let label = PlaceDisplayNamer.meaningful(visit.autoLabel)
                else { return nil }
                return PlaceLearningEngine.StaySnapshot(visit, label: label)
            }
        guard !others.isEmpty else { return nil }
        let nearbyPlaces = try knownPlaces(
            near: place.coordinate,
            within: PlaceLearningEngine.rejectedLabelSearchRadius
        )
        return PlaceLearningEngine.reusableLabel(
            for: PlaceLearningEngine.StaySnapshot(place, label: nil),
            among: others,
            isSuppressed: { PlaceLearningEngine.shouldSuppress($0, nearbyPlaces: nearbyPlaces) }
        )
    }

    /// Visits whose centre falls in a square `meters` either side of `coordinate`.
    private func visitsInBox(around coordinate: CLLocationCoordinate2D, meters: CLLocationDistance) throws -> [VisitPlace] {
        try visitsInBox(around: [coordinate], meters: meters)
    }

    /// Visits in the box around all of `coordinates`, `meters` past the outermost.
    private func visitsInBox(around coordinates: [CLLocationCoordinate2D], meters: CLLocationDistance) throws -> [VisitPlace] {
        guard let first = coordinates.first else { return [] }
        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let latitudeSpan = meters / 111_320
        let widestLatitude = max(abs(minLatitude), abs(maxLatitude))
        let longitudeSpan = meters / max(111_320 * cos(widestLatitude * .pi / 180), 1)
        minLatitude -= latitudeSpan
        maxLatitude += latitudeSpan
        minLongitude -= longitudeSpan
        maxLongitude += longitudeSpan
        return try modelContext.fetch(FetchDescriptor<VisitPlace>(
            predicate: #Predicate { visit in
                visit.latitude >= minLatitude && visit.latitude <= maxLatitude
                    && visit.longitude >= minLongitude && visit.longitude <= maxLongitude
                    && visit.dayTimeline != nil
            }
        ))
    }

    /// Robust centre of a CLVisit stay from the fixes stored while it lasted.
    private func robustStayCenter(from start: Date, to end: Date) throws -> CLLocationCoordinate2D? {
        guard end > start else { return nil }
        let fixes = try samples(from: start, to: end)
            .filter { $0.source != .photoLibrary && $0.moveSegment == nil }
            .map { (latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.horizontalAccuracy) }
        return PlaceLearningEngine.robustCenter(of: fixes)
    }

    /// The centre of two reports of one stay joined into one, from `samples` sorted by time.
    ///
    /// Only the stretches the fixes show as a stay count. A visit report can claim the walk
    /// up to the door as time there, and capture follows a walk with a fix every few seconds
    /// but a stop with almost none, so the walk's fixes would put the centre on the street
    /// walked, and the stop's boundaries, trimmed to that centre, would leave it minutes long.
    private static func joinedStayCenter(
        in samples: [LocationSample],
        stays: [SampleStay],
        from start: Date,
        to end: Date
    ) -> CLLocationCoordinate2D? {
        let overlapping = stays.compactMap { stay -> (stay: SampleStay, interval: DateInterval)? in
            let from = max(stay.arrivalDate, start)
            let to = min(stay.departureDate ?? end, end)
            return to > from ? (stay, DateInterval(start: from, end: to)) : nil
        }
        guard let longest = overlapping.max(by: { $0.interval.duration < $1.interval.duration }) else {
            return robustStayCenter(in: samples, during: [DateInterval(start: start, end: max(start, end))])
        }
        return robustStayCenter(in: samples, during: overlapping.map(\.interval)) ?? longest.stay.coordinate
    }

    /// Robust centre of the fixes in `intervals`, from `samples` sorted by time.
    private static func robustStayCenter(
        in samples: [LocationSample],
        during intervals: [DateInterval]
    ) -> CLLocationCoordinate2D? {
        guard !samples.isEmpty else { return nil }
        var fixes: [(latitude: Double, longitude: Double, accuracy: Double)] = []
        for interval in intervals where interval.end > interval.start {
            var low = 0
            var high = samples.count
            while low < high {
                let middle = (low + high) / 2
                if samples[middle].timestamp < interval.start { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < samples.count, samples[index].timestamp <= interval.end {
                let sample = samples[index]
                if sample.source != .photoLibrary {
                    fixes.append((sample.latitude, sample.longitude, sample.horizontalAccuracy))
                }
                index += 1
            }
        }
        return PlaceLearningEngine.robustCenter(of: fixes)
    }

    func knownPlaces(
        near coordinate: CLLocationCoordinate2D,
        within meters: CLLocationDistance
    ) throws -> [KnownPlace] {
        let places = try modelContext.fetch(FetchDescriptor<KnownPlace>())
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places
            .map { place -> (KnownPlace, CLLocationDistance) in
                let distance = origin.distance(
                    from: CLLocation(latitude: place.centerLatitude, longitude: place.centerLongitude)
                )
                return (place, distance)
            }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    func recordCorrection(_ event: PlaceCorrectionEvent) throws {
        try performingUndoableChange(named: "Remember Correction") {
            modelContext.insert(event)
            let fromPlace = try knownPlace(id: event.fromKnownPlaceID)
            let toPlace = try knownPlace(id: event.toKnownPlaceID)
            let eventID = event.id
            let fromID = event.fromKnownPlaceID
            let prior = try modelContext.fetch(FetchDescriptor<PlaceCorrectionEvent>()).filter { prior in
                prior.id != eventID && prior.fromKnownPlaceID == fromID
            }
            PlaceLearningEngine.applyNegatives(
                event: event,
                fromPlace: fromPlace,
                toPlace: toPlace,
                priorEventsFromPlace: prior
            )
        }
    }

    func applyPlaceLearning(to visit: VisitPlace) throws {
        guard visit.assignmentSource != .user else { return }

        let knownPlaces: [KnownPlace]
        if let cached = bulkKnownPlaces {
            knownPlaces = cached
        } else {
            knownPlaces = try modelContext.fetch(FetchDescriptor<KnownPlace>())
        }

        let resolution = PlaceLearningEngine.resolve(visit: visit, knownPlaces: knownPlaces)
        PlaceLearningEngine.apply(resolution, to: visit, knownPlaces: knownPlaces)

        if visit.assignmentSource == .none,
           visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            visit.userLabel = try nearbyUserLabel(near: visit.coordinate)
        }
    }

    func timelineItem(at date: Date) throws -> TimelineLocator.Result {
        let visits = try visitsPossiblyCovering(date)
        let moves = try movesPossiblyCovering(date)
        return TimelineLocator.locate(at: date, visits: visits, moves: moves)
    }

    func moves(in range: DateInterval, modes: Set<TransportMode>?) throws -> [MoveSegment] {
        let rangeStart = range.start
        let rangeEnd = range.end
        let descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startDate < rangeEnd && move.endDate > rangeStart && move.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
        )
        let fetched = try modelContext.fetch(descriptor)
        guard let modes, !modes.isEmpty else { return fetched }
        return fetched.filter { modes.contains($0.transportMode) }
    }

    func visits(in range: DateInterval) throws -> [VisitPlace] {
        let rangeStart = range.start
        let rangeEnd = range.end
        // Every map scrub lands here, so don't load all of history to find what overlaps.
        // Two months is longer than any stay that isn't simply still open.
        let earliestArrival = rangeStart.addingTimeInterval(-60 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < rangeEnd
                    && (place.arrivalDate >= earliestArrival || place.departureDate == nil)
                    && place.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
        )
        return try modelContext.fetch(descriptor).filter { place in
            let end = place.departureDate ?? place.arrivalDate
            return end > rangeStart || place.covers(rangeStart)
        }
    }

    private func performingUndoableChange<T>(named name: String, _ body: () throws -> T) throws -> T {
        let undoManager = modelContext.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(name)
        defer { undoManager?.endUndoGrouping() }
        let result = try body()
        try saveIfNeeded()
        return result
    }

    /// Walk 10m → stop 2m → walk 20m becomes one 32-minute walk, including the stop.
    private func mergeSameModeLegs(
        incoming: MoveSegment,
        outgoing: MoveSegment,
        visit: VisitPlace
    ) -> MoveSegment {
        let firstCoordinates = TimelineLocator.displayedCoordinates(for: incoming)
        let secondCoordinates = TimelineLocator.displayedCoordinates(for: outgoing)

        incoming.endPlace = outgoing.endPlace
        var endDate = max(outgoing.endDate, incoming.endDate)
        if let departure = visit.departureDate {
            endDate = max(endDate, departure)
        }
        incoming.endDate = endDate
        if incoming.endDate <= incoming.startDate {
            incoming.endDate = incoming.startDate.addingTimeInterval(1)
        }

        let incomingSamples = incoming.samples
        let outgoingSamples = outgoing.samples
        for sample in outgoingSamples where sample.moveSegment?.id != incoming.id {
            sample.moveSegment = incoming
        }

        let combinedLocations = (incomingSamples + outgoingSamples)
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.asLocation)
        if combinedLocations.count > 1 {
            incoming.distanceMeters = Self.totalDistance(for: combinedLocations)
        } else {
            incoming.distanceMeters += outgoing.distanceMeters
        }

        incoming.stepCount = Self.combinedStepCount(incoming.stepCount, outgoing.stepCount)
        incoming.speedProfileData = nil

        let mergedCoordinates = TimelineLocator.concatenating(firstCoordinates, secondCoordinates)
        incoming.clearCachedRouteCoordinates()
        if incoming.manualRouteCoordinatesData != nil || outgoing.manualRouteCoordinatesData != nil {
            incoming.storeManualRouteCoordinates(mergedCoordinates)
            incoming.routeMatchPolicy = .manual
        }
        if incoming.usesHighAccuracyRouteTracking || outgoing.usesHighAccuracyRouteTracking {
            if incoming.routeMatchPolicy == .auto {
                incoming.routeMatchPolicy = .recorded
            }
            if incoming.routeMatchConfidence == .unknown {
                incoming.routeMatchConfidence = .recorded
            }
        }

        incoming.comment = [incoming.comment, outgoing.comment]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        modelContext.delete(outgoing)
        modelContext.delete(visit)
        return incoming
    }

    /// Different modes keep two rows that meet when the stop ended.
    private func connectDifferentModeLegs(
        incoming: MoveSegment,
        outgoing: MoveSegment,
        visit: VisitPlace
    ) -> (incoming: MoveSegment, outgoing: MoveSegment) {
        let destination = outgoing.endPlace
        let origin = incoming.startPlace
        var joinTime = visit.departureDate ?? outgoing.startDate
        joinTime = max(joinTime, incoming.startDate.addingTimeInterval(1))
        if joinTime >= outgoing.endDate {
            joinTime = outgoing.endDate.addingTimeInterval(-1)
        }

        incoming.endPlace = destination
        incoming.endDate = joinTime
        outgoing.startPlace = origin
        outgoing.startDate = joinTime
        incoming.clearCachedRouteCoordinates()
        outgoing.clearCachedRouteCoordinates()
        incoming.speedProfileData = nil
        outgoing.speedProfileData = nil

        modelContext.delete(visit)
        return (incoming, outgoing)
    }

    private static func combinedStepCount(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func visitsPossiblyCovering(_ date: Date) throws -> [VisitPlace] {
        let lookback = date.addingTimeInterval(-8 * 24 * 60 * 60)
        let nearby = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate <= date && place.arrivalDate >= lookback && place.dayTimeline != nil
            }
        )
        var results = try modelContext.fetch(nearby)
        var older = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < lookback && place.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        older.fetchLimit = 4
        results.append(contentsOf: try modelContext.fetch(older))
        return results
    }

    private func movesPossiblyCovering(_ date: Date) throws -> [MoveSegment] {
        let windowStart = date.addingTimeInterval(-36 * 60 * 60)
        let windowEnd = date.addingTimeInterval(36 * 60 * 60)
        let descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startDate <= windowEnd && move.endDate >= windowStart && move.dayTimeline != nil
            }
        )
        return try modelContext.fetch(descriptor)
    }

    /// The departure of a merged stay. When the later stay has none the person is still
    /// there, so the merged stay stays open.
    private func maxDeparture(_ earlier: Date?, _ later: Date?) -> Date? {
        switch (earlier, later) {
        case let (a?, b?): return max(a, b)
        case (_?, nil): return nil
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private func distanceMeters(
        along coordinates: [CLLocationCoordinate2D],
        fallback: CLLocationDistance
    ) -> CLLocationDistance {
        guard coordinates.count > 1 else { return max(fallback, 0) }
        let locations = coordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        return max(Self.totalDistance(for: locations), 0)
    }

    private func applySplitCoordinates(
        _ coordinates: [CLLocationCoordinate2D],
        to move: MoveSegment,
        tag: String,
        preferManual: Bool
    ) {
        move.clearCachedRouteCoordinates()
        if preferManual {
            move.storeManualRouteCoordinates(coordinates)
            move.routeMatchPolicy = .manual
        } else if coordinates.count > 1 {
            move.storeCachedRouteCoordinates(coordinates, signature: tag)
        }
    }

    /// An archive's `day_key` was worked out in whatever zone the exporting phone was in,
    /// so a row with a real position is filed by where it happened; the key only places
    /// rows that have none.
    private func timeline(
        for date: Date,
        at coordinate: CLLocationCoordinate2D?,
        exportedDayKey: String?
    ) throws -> DayTimeline {
        if let coordinate, let zone = PlaceTimeZone.timeZone(at: coordinate) {
            return try timeline(for: date, in: zone)
        }
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
            if existing.origin != .sensor || existing.reviewState == .confirmed || existing.reviewState == .dismissed {
                return existing
            }
            applyArchiveMetadata(record, to: existing)
            existing.dayTimeline = try timeline(for: record.arrivalDate, at: existing.coordinate, exportedDayKey: record.dayKey)
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
        place.origin = newRowOrigin
        place.dayTimeline = try timeline(for: record.arrivalDate, at: place.coordinate, exportedDayKey: record.dayKey)
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

        // A figure no trip can reach (or NaN) counts as the file not reporting a distance.
        let reportedDistance = record.distanceMeters.flatMap { reported in
            reported > 0 && reported < Self.maximumReportedMoveDistance ? reported : nil
        }
        let samples = try appendSamples(from: locations, source: .fileRouteImport)
        let existing = try findSimilarMove(
            startCoordinate: startPlace.coordinate,
            endCoordinate: endPlace.coordinate,
            startDate: record.startDate,
            endDate: endDate,
            distanceMeters: reportedDistance ?? Self.totalDistance(for: locations),
            transportMode: record.transportMode
        )
        let transportMode = record.transportMode != .unknown
            ? record.transportMode
            : existing?.transportMode ?? .unknown
        let distance = reportedDistance
            ?? max(Self.totalDistance(for: locations), existing?.distanceMeters ?? 0)
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
        if let existing, isUserCurated(existing) { return samples.count }
        move.dayTimeline = try timeline(
            for: record.startDate,
            at: PlaceTimeZone.isUsable(startPlace.coordinate) ? startPlace.coordinate : locations.first?.coordinate,
            exportedDayKey: record.dayKey
        )
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
        place.dayTimeline = try timeline(for: date, at: nil, exportedDayKey: exportedDayKey)
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
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd && place.dayTimeline != nil
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
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd && place.dayTimeline != nil
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
        let places = try modelContext.fetch(FetchDescriptor<VisitPlace>.live())
        for place in places where place.departureDate == nil {
            if let leave = place.outgoingMoves.min(by: { $0.startDate < $1.startDate }) {
                place.departureDate = leave.timelineStartDate
            }
        }
    }

    /// Built per use so it reads today's time zone; only runs when a day is new to the store.
    private static var exportedDayKeyParser: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The day `date` is filed under: the calendar day where the person was then. With no
    /// coordinate to go on, the nearest stored fix says where that was; with none of those
    /// either, the phone's own zone does.
    private func timeline(for date: Date) throws -> DayTimeline {
        try timeline(for: date, in: try recordedTimeZone(near: date) ?? Calendar.current.timeZone)
    }

    /// The day `date` is filed under when it happened at `coordinate`.
    private func timeline(for date: Date, at coordinate: CLLocationCoordinate2D?) throws -> DayTimeline {
        if let coordinate, let zone = PlaceTimeZone.timeZone(at: coordinate) {
            return try timeline(for: date, in: zone)
        }
        return try timeline(for: date)
    }

    private func timeline(for date: Date, in zone: TimeZone) throws -> DayTimeline {
        let dayKey = DayTimeline.makeDayKey(for: date, in: zone)

        if bulkDayTimelineCache != nil {
            if let cached = bulkDayTimelineCache?[dayKey] {
                return cached
            }
            let timeline = DayTimeline(containing: date, in: zone)
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

        let timeline = DayTimeline(containing: date, in: zone)
        modelContext.insert(timeline)
        return timeline
    }

    /// The zone of the stored fix nearest `date`. Fixes two days either side are read
    /// once and kept for a minute, so a rebuild filing a week of rows reads them once.
    private func recordedTimeZone(near date: Date) throws -> TimeZone? {
        let now = Date.now
        if let cached = dayZoneFixes,
           cached.window.contains(date),
           now.timeIntervalSince(cached.loadedAt) < Self.dayZoneFixLifetime {
            return cached.fixes.timeZone(near: date)
        }
        let start = date.addingTimeInterval(-Self.dayZoneFixWindow)
        let end = date.addingTimeInterval(Self.dayZoneFixWindow)
        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        descriptor.propertiesToFetch = [\.timestamp, \.latitude, \.longitude]
        let fixes = RecordedTimeZones(fixes: try modelContext.fetch(descriptor).map {
            (date: $0.timestamp, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        })
        dayZoneFixes = (DateInterval(start: start, end: end), now, fixes)
        return fixes.timeZone(near: date)
    }

    /// Keeps the fix cache in step with fixes this repository writes itself.
    private func noteStoredFix(_ location: CLLocation) {
        guard dayZoneFixes?.window.contains(location.timestamp) == true else { return }
        dayZoneFixes?.fixes.insert(location.timestamp, location.coordinate)
    }

    private static let dayZoneFixWindow: TimeInterval = 2 * 24 * 60 * 60
    private static let dayZoneFixLifetime: TimeInterval = 60

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
            existing.dayTimeline = try timeline(for: arrivalDate, at: existing.coordinate)
            let canonical = try collapseDuplicatePlaces(around: existing)
            try applyPlaceLearning(to: canonical)
            return canonical
        }

        let place = VisitPlace(
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: max(location.horizontalAccuracy, 20)
        )
        place.origin = newRowOrigin
        place.dayTimeline = try timeline(for: arrivalDate, at: location.coordinate)
        modelContext.insert(place)
        let canonical = try collapseDuplicatePlaces(around: place)
        try applyPlaceLearning(to: canonical)
        return canonical
    }

    private func existingVisit(near arrivalDate: Date, coordinate: CLLocationCoordinate2D) throws -> VisitPlace? {
        let windowStart = arrivalDate.addingTimeInterval(-Self.placeDedupeArrivalWindow)
        let windowEnd = arrivalDate.addingTimeInterval(Self.placeDedupeArrivalWindow)

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd && place.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 32

        // A stop the rebuild retired is gone: a late report of the same visit makes a new
        // stop (which the rebuild judges again), never brings the retired row back.
        let candidates = try modelContext.fetch(descriptor)
            .filter { !TimelineRetirement.isRetired($0) }
            .prefix(8)
        func distance(to place: VisitPlace) -> CLLocationDistance {
            Self.distanceMeters(from: coordinate, to: place.coordinate)
        }

        let reportedAgain = candidates
            .filter {
                abs($0.arrivalDate.timeIntervalSince(arrivalDate)) <= Self.sameVisitArrivalTolerance
                    && distance(to: $0) <= Self.sameVisitMaximumDistance
            }
            .min { distance(to: $0) < distance(to: $1) }
        return reportedAgain ?? candidates.first { distance(to: $0) <= Self.placeDedupeDistanceThreshold }
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
                move.dedupeKey == dedupeKey && move.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
    }

    private func findMove(startPlaceID: UUID, endPlaceID: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startPlace?.id == startPlaceID && move.endPlace?.id == endPlaceID && move.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
    }

    /// The live stop with this id on this repository's context, or nil once it is deleted
    /// or retired. Work that awaits looks its stops up again with this afterwards.
    func livePlace(id placeID: UUID) throws -> VisitPlace? {
        try findPlace(byID: placeID).flatMap { $0.isDeleted ? nil : $0 }
    }

    /// A retired stop reads as gone, so nothing reuses or merges into it.
    private func findPlace(byID placeID: UUID) throws -> VisitPlace? {
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.id == placeID && place.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
    }

    /// A retired trip reads as gone, so nothing reuses or merges into it.
    private func findMove(byID moveID: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.id == moveID && move.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
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
                move.startDate >= windowStart && move.startDate <= windowEnd && move.dayTimeline != nil
            },
            sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 32

        let candidates = try modelContext.fetch(descriptor).filter { !TimelineRetirement.isRetired($0) }
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
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd && place.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 32

        // Retired stops are not duplicates of anything: merging one would revive it.
        let candidates = try modelContext.fetch(descriptor).filter { !TimelineRetirement.isRetired($0) }
        let duplicateGroup = candidates.filter { candidate in
            candidate.id == anchor.id || isDuplicatePlace(anchor, comparedTo: candidate)
        }

        guard duplicateGroup.count > 1 else {
            return anchor
        }

        let canonical = try canonicalPlace(from: duplicateGroup)
        for candidate in duplicateGroup where candidate.id != canonical.id {
            mergePlace(candidate, into: canonical)
            // Capture and imports land here while the timeline is on screen: retire, never delete.
            retire(candidate)
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

        if destination.knownPlace == nil, let known = source.knownPlace {
            destination.knownPlace = known
            destination.assignmentSource = source.assignmentSource
            destination.assignmentConfidence = source.assignmentConfidence
        }
        if destination.reviewState == .none {
            destination.reviewState = source.reviewState
        }
        destination.countryCode = destination.countryCode ?? source.countryCode
        destination.locality = destination.locality ?? source.locality
        destination.administrativeArea = destination.administrativeArea ?? source.administrativeArea
        destination.thoroughfare = destination.thoroughfare ?? source.thoroughfare
        destination.formattedAddress = destination.formattedAddress ?? source.formattedAddress

        // Photos cascade-delete with their visit.
        for photo in source.photoAttachments {
            photo.visitPlace = destination
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
                move.endDate >= windowStart && move.startDate <= windowEnd && move.dayTimeline != nil
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
        if abs(lhs.arrivalDate.timeIntervalSince(rhs.arrivalDate)) <= Self.sameVisitArrivalTolerance,
           coordinateDistance <= Self.sameVisitMaximumDistance,
           lhs.origin == .sensor, rhs.origin == .sensor {
            return !labelsConflict(lhs, rhs)
        }

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
                move.startDate >= windowStart && move.startDate <= windowEnd && move.dayTimeline != nil
            }
        )
        descriptor.fetchLimit = 32

        let candidates = try modelContext.fetch(descriptor).filter { !TimelineRetirement.isRetired($0) }

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
                retire(candidate)
            } else {
                mergeMove(canonical, into: candidate)
                retire(canonical)
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
        // Live stays only: giving a retired stay a day below would revive it.
        let places = try modelContext.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)])
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
                place.dayTimeline = try timeline(for: place.arrivalDate, at: place.coordinate)
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

    private func knownPlace(id: UUID?) throws -> KnownPlace? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<KnownPlace>(
            predicate: #Predicate { place in
                place.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Copies a nearby confirmed name when no `KnownPlace` matched. Display
    /// only — this does not assign a place or teach a footprint.
    private func nearbyUserLabel(near coordinate: CLLocationCoordinate2D) throws -> String? {
        if let cached = bulkLabeledPlaces {
            return cached
                .map { ($0.label, Self.distanceMeters(from: coordinate, to: $0.coordinate)) }
                .filter { $0.1 <= 120 }
                .min(by: { $0.1 < $1.1 })?
                .0
        }

        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.userLabel != nil && place.dayTimeline != nil
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

            let existing = try context.fetch(descriptor)
            // `ContentView.openCurrentDay()` can insert an empty "today" before this
            // Task runs. Treat empty shells as unseeded so demo days still appear.
            if existing.contains(where: { !$0.places.isEmpty || !$0.moves.isEmpty }) {
                return
            }
            for day in existing {
                context.delete(day)
            }
            if !existing.isEmpty {
                try context.save()
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

    /// Main actor, like the context it is handed, and so are the helpers it passes the
    /// context to: a nonisolated async function runs on the global executor, and SwiftData
    /// warns when a main-queue context is used off it.
    @MainActor
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

        try await seedUnconfirmedSuggestions(dayStart: today, calendar: calendar, context: context)
        try context.save()
    }

    /// Unlabeled repeats so the Places tab can show Confirm with distinct street names.
    /// Left off any `DayTimeline` so they do not clutter the storyline.
    @MainActor
    private static func seedUnconfirmedSuggestions(
        dayStart: Date,
        calendar: Calendar,
        context: ModelContext
    ) async throws {
        func stay(
            autoLabel: String?,
            thoroughfare: String,
            formattedAddress: String,
            latitude: Double,
            longitude: Double,
            daysAgo: [Int],
            hours: Int,
            minutes: Int
        ) {
            for (index, day) in daysAgo.enumerated() {
                guard let arrival = calendar.date(byAdding: .day, value: -day, to: dayStart)
                    .flatMap({ calendar.date(byAdding: .hour, value: hours, to: $0) })
                    .flatMap({ calendar.date(byAdding: .minute, value: minutes + index, to: $0) })
                else { continue }
                let visit = VisitPlace(
                    arrivalDate: arrival,
                    departureDate: arrival.addingTimeInterval(TimeInterval((3 + index) * 3600)),
                    latitude: latitude,
                    longitude: longitude,
                    horizontalAccuracy: 18
                )
                visit.autoLabel = autoLabel
                visit.thoroughfare = thoroughfare
                visit.formattedAddress = formattedAddress
                visit.locality = "Amsterdam"
                visit.countryCode = "NL"
                context.insert(visit)
            }
        }

        stay(
            autoLabel: "Rijksmuseum Garden",
            thoroughfare: "Museumstraat",
            formattedAddress: "Museumstraat, Amsterdam",
            latitude: 52.35970,
            longitude: 4.88540,
            daysAgo: [2, 9, 16, 23],
            hours: 16,
            minutes: 10
        )
        stay(
            autoLabel: nil,
            thoroughfare: "Hobbemakade",
            formattedAddress: "Hobbemakade 120, Amsterdam",
            latitude: 52.35580,
            longitude: 4.89120,
            daysAgo: [3, 10, 18],
            hours: 19,
            minutes: 40
        )
        stay(
            autoLabel: nil,
            thoroughfare: "Hobbemakade",
            formattedAddress: "Hobbemakade 40, Amsterdam",
            latitude: 52.35390,
            longitude: 4.89380,
            daysAgo: [1, 8, 15, 22, 29],
            hours: 8,
            minutes: 5
        )
    }

    @MainActor
    private static func seed(
        route: RouteBlueprint,
        routeIndex: Int,
        dayStart: Date,
        calendar: Calendar,
        context: ModelContext
    ) async throws {
        let plannedStops = plannedStops(for: route)
        guard let firstMode = plannedStops.first?.transportMode else {
            return
        }

        // Each demo city keeps its own clock: the intended date, on the wall where the route
        // runs, so the day is filed where a real one would be whatever zone the simulator uses.
        let zone = plannedStops.first.flatMap { PlaceTimeZone.timeZone(at: $0.stop.coordinate) } ?? calendar.timeZone
        let localCalendar = TimelineDayFiling.calendar(in: zone)
        let localDayStart = TimelineDayFiling.startOfDay(
            forKey: DayTimeline.makeDayKey(for: dayStart, in: calendar.timeZone),
            in: zone
        ) ?? dayStart
        let timeline = DayTimeline(containing: localDayStart, in: zone)
        context.insert(timeline)

        guard let routeStart = localCalendar.date(
            byAdding: .minute,
            value: startOffsetMinutes(for: firstMode, routeIndex: routeIndex),
            to: localDayStart
        ) else {
            return
        }

        var currentTime = routeStart
        var places: [VisitPlace] = []
        var pendingMoves: [PendingMove] = []

        for (stopIndex, plannedStop) in plannedStops.enumerated() {
            let unlabeled = plannedStop.stop.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let stayMinutes = unlabeled ? 2 : dwellMinutes(for: routeIndex, stopIndex: stopIndex)
            let arrival = currentTime
            let departure = arrival.addingTimeInterval(TimeInterval(stayMinutes * 60))

            let place = VisitPlace(
                arrivalDate: arrival,
                departureDate: departure,
                latitude: plannedStop.stop.coordinate.latitude,
                longitude: plannedStop.stop.coordinate.longitude,
                horizontalAccuracy: horizontalAccuracy(for: plannedStop.transportMode),
                userLabel: unlabeled ? nil : plannedStop.stop.label
            )
            place.isHiddenAsShortStop = unlabeled
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
                stop("", -33.860800, 151.216000),
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
