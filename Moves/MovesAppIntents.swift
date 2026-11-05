import AppIntents
import CoreLocation
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum MovesRouteTrackingDuration: String, AppEnum {
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case endOfDay

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tracking Duration")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .thirtyMinutes: "30 minutes",
        .oneHour: "1 hour",
        .twoHours: "2 hours",
        .fourHours: "4 hours",
        .endOfDay: "Until end of day",
    ]

    var trackingDuration: TemporaryRouteTrackingDuration {
        switch self {
        case .thirtyMinutes: .thirtyMinutes
        case .oneHour: .oneHour
        case .twoHours: .twoHours
        case .fourHours: .fourHours
        case .endOfDay: .endOfDay
        }
    }
}

enum MovesTimelinePeriod: String, AppEnum {
    case today
    case yesterday
    case lastSevenDays
    case thisMonth
    case allTime

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Timeline Period")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "Today",
        .yesterday: "Yesterday",
        .lastSevenDays: "Last 7 days",
        .thisMonth: "This month",
        .allTime: "All time",
    ]

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "The last 7 days"
        case .thisMonth: "This month"
        case .allTime: "All time"
        }
    }

    var fileStem: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .lastSevenDays: "last-7-days"
        case .thisMonth: "this-month"
        case .allTime: "all-time"
        }
    }

    func dateInterval(
        containing now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(24 * 60 * 60)

        switch self {
        case .today:
            return DateInterval(start: today, end: tomorrow)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: today)
                ?? today.addingTimeInterval(-24 * 60 * 60)
            return DateInterval(start: start, end: today)
        case .lastSevenDays:
            let start = calendar.date(byAdding: .day, value: -6, to: today)
                ?? today.addingTimeInterval(-6 * 24 * 60 * 60)
            return DateInterval(start: start, end: tomorrow)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .allTime:
            return nil
        }
    }
}

extension DateInterval {
    /// Start-inclusive and end-exclusive. `contains` includes the end, so a day's interval
    /// would also claim the next day's midnight.
    func holds(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

enum MovesIntentExportFormat: String, AppEnum {
    case gpx
    case geoJSON
    case csv

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Export Format")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .gpx: "GPX",
        .geoJSON: "GeoJSON",
        .csv: "CSV",
    ]

    var timelineExportFormat: TimelineExportFormat {
        switch self {
        case .gpx: .gpx
        case .geoJSON: .geoJSON
        case .csv: .csv
        }
    }
}

enum MovesIntentError: LocalizedError {
    case runtimeUnavailable
    case noTimelineData(String)
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Moves is not ready yet. Please open the app once and try again."
        case .noTimelineData(let period):
            "Moves has no timeline activity for \(period.lowercased())."
        case .exportFailed:
            "Moves could not create the export file."
        }
    }
}

@MainActor
final class MovesIntentRuntime {
    static let shared = MovesIntentRuntime()

    private weak var captureManager: MovesLocationCaptureManager?
    private var modelContainer: ModelContainer?

    private init() {}

    func configure(
        modelContainer: ModelContainer,
        captureManager: MovesLocationCaptureManager
    ) {
        self.modelContainer = modelContainer
        self.captureManager = captureManager
    }

    var needsForegroundTrackingAuthorization: Bool {
        guard let captureManager else { return false }
        return !captureManager.isDemoMode && captureManager.authorizationStatus == .notDetermined
    }

    func startRouteTracking(duration: TemporaryRouteTrackingDuration) throws -> String {
        guard let captureManager else { throw MovesIntentError.runtimeUnavailable }

        if captureManager.isDemoMode {
            return "Moves is using simulator demo data, so real route tracking was not started."
        }

        switch captureManager.authorizationStatus {
        case .denied:
            return "Location access is denied. Allow location access for Moves in Settings before starting real route tracking."
        case .restricted:
            return "Location access is restricted on this device, so Moves cannot start real route tracking."
        case .notDetermined:
            captureManager.enableTemporaryRouteTracking(duration: duration)
            return "Moves is requesting location access. Real route tracking will start after you allow access."
        case .authorizedAlways, .authorizedWhenInUse:
            captureManager.enableTemporaryRouteTracking(duration: duration)
            let backgroundNote = captureManager.authorizationStatus == .authorizedWhenInUse
                ? " It will only continue while Moves is open until Always location access is enabled."
                : ""
            return "Real route tracking is on \(duration.availabilityText).\(backgroundNote)"
        @unknown default:
            return "Moves could not determine the current location permission."
        }
    }

    func stopRouteTracking() throws -> String {
        guard let captureManager else { throw MovesIntentError.runtimeUnavailable }

        guard captureManager.isTemporaryRouteTrackingActive else {
            return "Real route tracking is already off."
        }

        captureManager.disableTemporaryRouteTracking()
        if captureManager.isBackgroundLocationListeningEnabled {
            return "Real route tracking is off. Moves has returned to low-energy background tracking."
        }
        return "Real route tracking is off. Low-energy background tracking is also disabled."
    }

    func toggleRouteTracking(defaultDuration: TemporaryRouteTrackingDuration) throws -> String {
        guard let captureManager else { throw MovesIntentError.runtimeUnavailable }
        if captureManager.isTemporaryRouteTrackingActive {
            return try stopRouteTracking()
        }
        return try startRouteTracking(duration: defaultDuration)
    }

    func trackingStatus() throws -> String {
        guard let captureManager else { throw MovesIntentError.runtimeUnavailable }

        if captureManager.isTemporaryRouteTrackingActive,
           let endsAt = captureManager.temporaryRouteTrackingEndsAt {
            let endTime = endsAt.formatted(date: .omitted, time: .shortened)
            return "Real route tracking is on until \(endTime). \(captureManager.trackingStatusText)."
        }

        return "Real route tracking is off. \(captureManager.trackingStatusText)."
    }

    func setBackgroundTracking(enabled: Bool) throws -> String {
        guard let captureManager else { throw MovesIntentError.runtimeUnavailable }
        captureManager.setBackgroundLocationListeningEnabled(enabled)

        if enabled {
            return "Low-energy background tracking is enabled."
        }
        return "Low-energy background tracking is disabled. Real route tracking can still be started separately."
    }

    func timelineSummary(for period: MovesTimelinePeriod, now: Date = .now) throws -> String {
        let days = try timelines(for: period, now: now).filter(\.hasRecordedActivity)
        guard !days.isEmpty else { throw MovesIntentError.noTimelineData(period.title) }

        let places = days.reduce(0) { $0 + $1.places.count }
        let moves = days.flatMap(\.moves)
        let distance = moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let movingTime = moves.reduce(0) { $0 + max($1.timelineDuration, 0) }
        let steps = moves.compactMap(\.stepCount).reduce(0, +)
        let topMode = Dictionary(grouping: moves, by: \.transportMode)
            .mapValues { segments in segments.reduce(0) { $0 + max($1.distanceMeters, 0) } }
            .max(by: { $0.value < $1.value })
            .map(\.key)

        var parts = [
            "\(places) \(places == 1 ? "place" : "places")",
            "\(moves.count) \(moves.count == 1 ? "move" : "moves")",
            "\(Self.distanceText(distance)) traveled",
            "\(DurationFormatter.text(for: movingTime)) moving",
        ]
        if steps > 0 {
            parts.append("\(steps.formatted()) steps")
        }

        var summary = "\(period.title): \(Self.joinForSpeech(parts))."
        if let topMode, distance > 0 {
            summary += " Most distance was by \(topMode.title.lowercased())."
        }
        return summary
    }

    func export(period: MovesTimelinePeriod, format: TimelineExportFormat) throws -> IntentFile {
        let days = try timelines(for: period).filter(\.hasRecordedActivity)
        guard !days.isEmpty else { throw MovesIntentError.noTimelineData(period.title) }
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }
        let context = ModelContext(modelContainer)
        let places = (try? context.fetch(FetchDescriptor<KnownPlace>())) ?? []
        guard let payload = TimelineExporter.makePayload(
            days: days,
            format: format,
            fileStem: "moves-\(period.fileStem)",
            privacyZones: PrivacyZoneResolver.exportZones(from: places)
        ) else {
            throw MovesIntentError.exportFailed
        }

        return IntentFile(
            data: payload.data,
            filename: payload.filename,
            type: payload.contentType
        )
    }

    func visitedPlaceEntities(identifiedBy identifiers: [String]? = nil) throws -> [VisitedPlaceEntity] {
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<VisitPlace>(
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        let places = try context.fetch(descriptor)
        let identifierSet = identifiers.map(Set.init)

        return places.compactMap { place in
            let identifier = place.id.uuidString
            guard identifierSet?.contains(identifier) ?? true else { return nil }
            return VisitedPlaceEntity(place: place)
        }
    }

    private func timelines(for period: MovesTimelinePeriod, now: Date = .now) throws -> [DayTimeline] {
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DayTimeline>(
            sortBy: [SortDescriptor(\DayTimeline.dayStart)]
        )
        let days = try context.fetch(descriptor)
        guard let interval = period.dateInterval(containing: now) else { return days }
        return days.filter { interval.holds($0.dayStart) }
    }

    func visitEntities(
        in interval: DateInterval? = nil,
        identifiedBy identifiers: [String]? = nil
    ) throws -> [VisitEntity] {
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }
        let context = ModelContext(modelContainer)
        let start = interval?.start ?? .distantPast
        let end = interval?.end ?? .distantFuture
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { visit in visit.arrivalDate >= start && visit.arrivalDate < end },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        let visits = try context.fetch(descriptor)
        guard let identifiers else {
            return visits.prefix(Self.entityListLimit).map { VisitEntity(visit: $0) }
        }
        let identifierSet = Set(identifiers)
        return visits
            .filter { identifierSet.contains($0.id.uuidString) }
            .map { VisitEntity(visit: $0) }
    }

    func moveEntities(
        in interval: DateInterval? = nil,
        identifiedBy identifiers: [String]? = nil
    ) throws -> [MoveEntity] {
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }
        let context = ModelContext(modelContainer)
        let start = interval?.start ?? .distantPast
        let end = interval?.end ?? .distantFuture
        // `timelineStartDate` is computed, so fetch every move touching the period and check it here.
        let descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in move.endDate >= start && move.startDate < end },
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .reverse)]
        )
        let moves = try context.fetch(descriptor).filter { move in
            interval?.holds(move.timelineStartDate) ?? true
        }
        guard let identifiers else {
            return moves.prefix(Self.entityListLimit).map { MoveEntity(move: $0) }
        }
        let identifierSet = Set(identifiers)
        return moves
            .filter { identifierSet.contains($0.id.uuidString) }
            .map { MoveEntity(move: $0) }
    }

    func whereWasI(at date: Date, includeCoordinates: Bool) throws -> String {
        guard let modelContainer else { throw MovesIntentError.runtimeUnavailable }
        let context = ModelContext(modelContainer)
        let visits = try context.fetch(FetchDescriptor<VisitPlace>())
        let moves = try context.fetch(FetchDescriptor<MoveSegment>())
        let result = TimelineLocator.locate(at: date, visits: visits, moves: moves)
        return TimelineMomentSummary.text(
            result: result,
            at: date,
            includeCoordinates: includeCoordinates
        )
    }

    /// The most visits or moves a period listing returns. Lookups by id are not capped.
    private static let entityListLimit = 200

    private static func distanceText(_ meters: CLLocationDistance) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .medium
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: max(meters, 0), unit: UnitLength.meters))
    }

    private static func joinForSpeech(_ values: [String]) -> String {
        guard values.count > 1 else { return values.first ?? "" }
        return values.dropLast().joined(separator: ", ") + ", and " + values.last!
    }
}

struct VisitedPlaceEntity: IndexedEntity, URLRepresentableEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Visited Place")
    static let defaultQuery = VisitedPlaceEntityQuery()
    static let urlRepresentation: EntityURLRepresentation<Self> = "moves://place/\(.id)"

    let id: String
    let name: String
    let visitedAt: Date
    let dayKey: String

    init(place: VisitPlace) {
        id = place.id.uuidString
        // `displayTitle` falls back to coordinates, which Spotlight must never receive.
        name = PlaceDisplayNamer.meaningful(place.userLabel)
            ?? PlaceDisplayNamer.meaningful(place.autoLabel)
            ?? PlaceDisplayNamer.meaningful(place.knownPlace?.name)
            ?? "Visited place"
        visitedAt = place.arrivalDate
        dayKey = place.dayTimeline?.dayKey ?? DayTimeline.makeDayKey(for: place.arrivalDate)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Visited \(visitedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.displayName = name
        attributes.contentDescription = "A place visited on \(visitedAt.formatted(date: .long, time: .shortened))."
        attributes.contentCreationDate = visitedAt
        attributes.keywords = ["Moves", "visited place", dayKey]
        return attributes
    }
}

struct VisitedPlaceEntityQuery: EntityQuery {
    func entities(for identifiers: [VisitedPlaceEntity.ID]) async throws -> [VisitedPlaceEntity] {
        try await MovesIntentRuntime.shared.visitedPlaceEntities(identifiedBy: identifiers)
    }
}

@available(iOS 27.0, *)
extension VisitedPlaceEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [VisitedPlaceEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await MovesIntentRuntime.shared.visitedPlaceEntities(identifiedBy: identifiers)
        try await CSSearchableIndex(name: VisitedPlaceSpotlightIndexer.indexName)
            .indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await MovesIntentRuntime.shared.visitedPlaceEntities()
        try await VisitedPlaceSpotlightIndexer.replaceIndex(with: entities)
    }
}

enum VisitedPlaceSpotlightIndexer {
    static let indexName = "MovesVisitedPlaces"

    static func replaceIndex(with entities: [VisitedPlaceEntity]) async throws {
        let index = CSSearchableIndex(name: indexName)
        try await index.deleteAppEntities(ofType: VisitedPlaceEntity.self)

        for start in stride(from: 0, to: entities.count, by: 250) {
            let end = min(start + 250, entities.count)
            try await index.indexAppEntities(Array(entities[start..<end]))
        }
    }
}

struct OpenVisitedPlaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Visited Place"

    @Parameter(title: "Place")
    var target: VisitedPlaceEntity
}

struct StartRealRouteTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Real Route Tracking"
    static let description = IntentDescription("Starts frequent GPS tracking for a limited time.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Duration", default: .endOfDay)
    var duration: MovesRouteTrackingDuration

    static var parameterSummary: some ParameterSummary {
        Summary("Start real route tracking for \(\.$duration)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if await MovesIntentRuntime.shared.needsForegroundTrackingAuthorization {
            try await continueInForeground(
                "Moves needs to ask for location access before GPS tracking can start.",
                alwaysConfirm: false
            )
        }

        let message = try await MovesIntentRuntime.shared.startRouteTracking(
            duration: duration.trackingDuration
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct ToggleRealRouteTrackingIntent: LiveActivityIntent, PredictableIntent {
    static let title: LocalizedStringResource = "Toggle Real Route Tracking"
    static let description = IntentDescription("Starts real-route GPS tracking when it is off, or stops it when it is on.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(
            displayRepresentation: {
                DisplayRepresentation(
                    title: "Toggle route tracking",
                    subtitle: "Start or stop high-accuracy GPS tracking"
                )
            }
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if await MovesIntentRuntime.shared.needsForegroundTrackingAuthorization {
            try await continueInForeground(
                "Moves needs to ask for location access before GPS tracking can start.",
                alwaysConfirm: false
            )
        }

        let message = try await MovesIntentRuntime.shared.toggleRouteTracking(
            defaultDuration: .endOfDay
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct StopRealRouteTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Real Route Tracking"
    static let description = IntentDescription("Stops frequent GPS tracking and returns to low-energy tracking.")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await MovesIntentRuntime.shared.stopRouteTracking()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetMovesTrackingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tracking Status"
    static let description = IntentDescription("Reports whether real route and background tracking are active.")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await MovesIntentRuntime.shared.trackingStatus()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct SetMovesBackgroundTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Background Tracking"
    static let description = IntentDescription("Turns low-energy visit and significant-location tracking on or off.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enabled", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set background tracking to \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await MovesIntentRuntime.shared.setBackgroundTracking(enabled: enabled)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetMovesTimelineSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Timeline Summary"
    static let description = IntentDescription("Summarizes places, moves, distance, moving time, and steps.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Period", default: .today)
    var period: MovesTimelinePeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = try await MovesIntentRuntime.shared.timelineSummary(for: period)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ExportMovesTimelineIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Timeline"
    static let description = IntentDescription("Exports timeline data as a GPX, GeoJSON, or CSV file.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Period", default: .today)
    var period: MovesTimelinePeriod

    @Parameter(title: "Format", default: .gpx)
    var format: MovesIntentExportFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$period) as \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let file = try await MovesIntentRuntime.shared.export(
            period: period,
            format: format.timelineExportFormat
        )
        let message = "Exported \(period.title.lowercased()) as \(format.rawValue)."
        return .result(value: file, dialog: IntentDialog(stringLiteral: message))
    }
}

/// Shortcuts-facing visit. Coordinates are omitted; use Where Was I At with Include Coordinates to opt in.
struct VisitEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Visit")
    static let defaultQuery = VisitEntityQuery()

    let id: String
    let name: String
    let arrival: Date
    let departure: Date?

    init(visit: VisitPlace) {
        id = visit.id.uuidString
        let label = WebhookPlaceName.name(for: visit)
        name = label
        arrival = visit.arrivalDate
        departure = visit.departureDate
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Arrived \(arrival.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

struct VisitEntityQuery: EntityQuery {
    func entities(for identifiers: [VisitEntity.ID]) async throws -> [VisitEntity] {
        try await MovesIntentRuntime.shared.visitEntities(identifiedBy: identifiers)
    }

    func suggestedEntities() async throws -> [VisitEntity] {
        try await MovesIntentRuntime.shared.visitEntities(
            in: MovesTimelinePeriod.today.dateInterval()
        )
    }
}

/// Shortcuts-facing move. Route coordinates are omitted unless a later intent opts in.
struct MoveEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Move")
    static let defaultQuery = MoveEntityQuery()

    let id: String
    let mode: String
    let startName: String
    let endName: String
    let start: Date
    let end: Date
    let distanceMeters: Double

    init(move: MoveSegment) {
        id = move.id.uuidString
        mode = move.transportMode.title
        startName = WebhookPlaceName.name(for: move.startPlace)
        endName = WebhookPlaceName.name(for: move.endPlace)
        start = move.timelineStartDate
        end = move.endDate
        distanceMeters = move.distanceMeters
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(startName) to \(endName)",
            subtitle: "\(mode) · \(start.formatted(date: .omitted, time: .shortened))"
        )
    }
}

struct MoveEntityQuery: EntityQuery {
    func entities(for identifiers: [MoveEntity.ID]) async throws -> [MoveEntity] {
        try await MovesIntentRuntime.shared.moveEntities(identifiedBy: identifiers)
    }

    func suggestedEntities() async throws -> [MoveEntity] {
        try await MovesIntentRuntime.shared.moveEntities(
            in: MovesTimelinePeriod.today.dateInterval()
        )
    }
}

/// Spoken/Shortcuts sentence for a moment on the timeline.
enum TimelineMomentSummary {
    static func text(
        result: TimelineLocator.Result,
        at date: Date,
        includeCoordinates: Bool
    ) -> String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        switch result {
        case .visit(let visit):
            var sentence = "You were at \(WebhookPlaceName.name(for: visit)) at \(time)."
            if includeCoordinates {
                sentence += " \(coordinateText(latitude: visit.latitude, longitude: visit.longitude))."
            }
            return sentence
        case .move(let move, let coordinate, _):
            var sentence = "You were \(move.transportMode.title.lowercased()) from \(WebhookPlaceName.name(for: move.startPlace)) to \(WebhookPlaceName.name(for: move.endPlace)) at \(time)."
            if includeCoordinates {
                sentence += " \(coordinateText(latitude: coordinate.latitude, longitude: coordinate.longitude))."
            }
            return sentence
        case .gap:
            return "Moves has no recorded activity at \(time)."
        }
    }

    private static func coordinateText(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}

struct GetVisitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Visits"
    static let description = IntentDescription("Returns visits for a period. Place names and times only — never coordinates.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Period", default: .today)
    var period: MovesTimelinePeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Get visits for \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[VisitEntity]> & ProvidesDialog {
        let visits = try await MovesIntentRuntime.shared.visitEntities(in: period.dateInterval())
        let message = visits.isEmpty
            ? "Moves has no visits for \(period.title.lowercased())."
            : "Found \(visits.count) visit\(visits.count == 1 ? "" : "s") for \(period.title.lowercased())."
        return .result(value: visits, dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetMovesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Moves"
    static let description = IntentDescription("Returns moves for a period. Place names, mode, and times only — never coordinates.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Period", default: .today)
    var period: MovesTimelinePeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Get moves for \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[MoveEntity]> & ProvidesDialog {
        let moves = try await MovesIntentRuntime.shared.moveEntities(in: period.dateInterval())
        let message = moves.isEmpty
            ? "Moves has no moves for \(period.title.lowercased())."
            : "Found \(moves.count) move\(moves.count == 1 ? "" : "s") for \(period.title.lowercased())."
        return .result(value: moves, dialog: IntentDialog(stringLiteral: message))
    }
}

struct WhereWasIAtIntent: AppIntent {
    static let title: LocalizedStringResource = "Where Was I At"
    static let description = IntentDescription("Reports the place or move covering a time. Coordinates are omitted unless you turn them on.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Time")
    var time: Date

    @Parameter(title: "Include Coordinates", default: false)
    var includeCoordinates: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Where was I at \(\.$time)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await MovesIntentRuntime.shared.whereWasI(
            at: time,
            includeCoordinates: includeCoordinates
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct MovesAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRealRouteTrackingIntent(),
            phrases: [
                "Start route tracking with \(.applicationName)",
                "Start route tracking with \(.applicationName) for \(\.$duration)",
                "Track my real route with \(.applicationName)",
                "Start GPS tracking in \(.applicationName)",
            ],
            shortTitle: "Start Route Tracking",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopRealRouteTrackingIntent(),
            phrases: [
                "Stop route tracking with \(.applicationName)",
                "Stop GPS tracking in \(.applicationName)",
            ],
            shortTitle: "Stop Route Tracking",
            systemImageName: "location.slash.fill"
        )
        AppShortcut(
            intent: ToggleRealRouteTrackingIntent(),
            phrases: [
                "Toggle route tracking with \(.applicationName)",
                "Toggle GPS tracking in \(.applicationName)",
            ],
            shortTitle: "Toggle Route Tracking",
            systemImageName: "location.circle.fill"
        )
        AppShortcut(
            intent: GetMovesTimelineSummaryIntent(),
            phrases: [
                "Summarize my day with \(.applicationName)",
                "Summarize \(\.$period) with \(.applicationName)",
                "Get my \(.applicationName) summary",
                "What did I do in \(.applicationName)",
            ],
            shortTitle: "Timeline Summary",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: ExportMovesTimelineIntent(),
            phrases: [
                "Export my timeline with \(.applicationName)",
                "Export \(\.$period) from \(.applicationName)",
                "Export my \(.applicationName) data",
            ],
            shortTitle: "Export Timeline",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: GetVisitsIntent(),
            phrases: [
                "Get my visits with \(.applicationName)",
                "Get visits for \(\.$period) with \(.applicationName)",
            ],
            shortTitle: "Get Visits",
            systemImageName: "mappin.and.ellipse"
        )
        AppShortcut(
            intent: GetMovesIntent(),
            phrases: [
                "Get my moves with \(.applicationName)",
                "Get moves for \(\.$period) with \(.applicationName)",
            ],
            shortTitle: "Get Moves",
            systemImageName: "point.topleft.down.to.point.bottomright.curvepath"
        )
        AppShortcut(
            intent: WhereWasIAtIntent(),
            phrases: [
                "Where was I with \(.applicationName)",
                "Where was I in \(.applicationName)",
            ],
            shortTitle: "Where Was I",
            systemImageName: "clock"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
