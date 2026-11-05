import CoreLocation
import Foundation
import SwiftData
import SwiftUI

/// Sheet the root view presents for a correction that needs more UI.
enum TimelineEditSheet: Identifiable, Equatable {
    case rename(UUID)
    case pickNearby(UUID)
    case editTimes(UUID)
    case splitVisit(UUID)
    case splitMove(UUID)
    case changeMode(UUID)

    var id: String {
        switch self {
        case .rename(let id): return "rename-\(id.uuidString)"
        case .pickNearby(let id): return "nearby-\(id.uuidString)"
        case .editTimes(let id): return "times-\(id.uuidString)"
        case .splitVisit(let id): return "split-visit-\(id.uuidString)"
        case .splitMove(let id): return "split-move-\(id.uuidString)"
        case .changeMode(let id): return "mode-\(id.uuidString)"
        }
    }
}

/// Owns swipe / context-menu corrections and posts the undo pill.
///
/// Deletes restore from payloads because SwiftData auto-undo of deletes can
/// crash. Property edits go through `TimelineRepository` and `UndoManager`.
@MainActor
@Observable
final class TimelineEditController: TimelineItemActions {
    var presentedSheet: TimelineEditSheet?
    var confirmDeletePlaceID: UUID?
    var errorMessage: String?
    var isShowingError = false

    @ObservationIgnored
    private var modelContext: ModelContext?
    @ObservationIgnored
    private var undoController: AppUndoController?
    @ObservationIgnored
    var toast: UndoToastPresenter?

    func attach(
        modelContext: ModelContext,
        undoController: AppUndoController,
        toast: UndoToastPresenter
    ) {
        self.modelContext = modelContext
        self.undoController = undoController
        self.toast = toast
        modelContext.undoManager = undoController.manager
    }

    // MARK: - Place actions

    func requestRename(_ visit: VisitPlace) {
        presentedSheet = .rename(visit.id)
    }

    func requestPickNearby(_ visit: VisitPlace) {
        presentedSheet = .pickNearby(visit.id)
    }

    func markNotAStop(_ visit: VisitPlace) {
        dissolve(visit, named: String(localized: "Not a stop"))
    }

    func mergeWithPreviousPlace(_ visit: VisitPlace) {
        guard let previous = TimelineNeighbors.previousVisit(for: visit) else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        mergeVisits(previous, visit)
    }

    func mergeWithNextPlace(_ visit: VisitPlace) {
        guard let next = TimelineNeighbors.nextVisit(for: visit) else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        mergeVisits(visit, next)
    }

    func requestSplitVisit(_ visit: VisitPlace) {
        presentedSheet = .splitVisit(visit.id)
    }

    func requestEditTimes(_ visit: VisitPlace) {
        presentedSheet = .editTimes(visit.id)
    }

    func requestDeletePlace(_ visit: VisitPlace) {
        if shouldDissolveOnDelete(visit) {
            dissolve(visit, named: String(localized: "Deleted"))
            return
        }
        let duration = TimelineReviewHeuristics.stayDuration(of: visit) ?? 0
        if duration > TimelineReviewHeuristics.longVisitDeleteConfirmation {
            confirmDeletePlaceID = visit.id
            return
        }
        deletePlace(visit)
    }

    func confirmPendingPlaceDeletion() {
        guard let id = confirmDeletePlaceID, let visit = visit(id: id) else {
            confirmDeletePlaceID = nil
            return
        }
        confirmDeletePlaceID = nil
        deletePlace(visit)
    }

    // MARK: - Move actions

    func requestChangeMode(_ move: MoveSegment) {
        presentedSheet = .changeMode(move.id)
    }

    func setTransportMode(_ mode: TransportMode, for move: MoveSegment) {
        performProperty(named: String(localized: "Changed mode")) { repo in
            try repo.setTransportMode(mode, for: move, source: .user)
            move.reviewState = .confirmed
        }
    }

    func requestSplitMove(_ move: MoveSegment) {
        presentedSheet = .splitMove(move.id)
    }

    func mergeWithPreviousMove(_ move: MoveSegment) {
        guard let startPlace = move.startPlace else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        markNotAStop(startPlace)
    }

    func mergeWithNextMove(_ move: MoveSegment) {
        guard let endPlace = move.endPlace else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        markNotAStop(endPlace)
    }

    func requestDeleteMove(_ move: MoveSegment) {
        deleteMove(move)
    }

    // MARK: - Sheet completions

    func applyRename(to visit: VisitPlace, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performProperty(named: String(localized: "Renamed")) { repo in
            let nearby = try repo.knownPlaces(near: visit.coordinate, within: NearbyPlaceSuggester.searchRadius)
            if let existing = nearby.first(where: {
                $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                try assign(visit, to: existing, using: repo)
            } else {
                let fromKnown = visit.knownPlace?.id
                let fromAuto = visit.autoLabel
                let created = try repo.createKnownPlace(from: visit, name: trimmed)
                try repo.recordCorrection(Self.correctionEvent(
                    visit: visit,
                    fromKnownPlaceID: fromKnown,
                    fromAutoLabel: fromAuto,
                    to: created
                ))
                visit.reviewState = .confirmed
            }
        }
        presentedSheet = nil
    }

    func applyCandidate(_ candidate: NearbyPlaceCandidate, to visit: VisitPlace) {
        performProperty(named: String(localized: "Renamed")) { repo in
            switch candidate.source {
            case .knownPlace(let id):
                guard let place = knownPlace(id: id) else {
                    throw TimelineEditingError.visitNotFound
                }
                try assign(visit, to: place, using: repo)
            case .search:
                let nearby = try repo.knownPlaces(near: visit.coordinate, within: NearbyPlaceSuggester.searchRadius)
                if let existing = nearby.first(where: {
                    $0.name.compare(candidate.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    try assign(visit, to: existing, using: repo)
                } else {
                    let fromKnown = visit.knownPlace?.id
                    let fromAuto = visit.autoLabel
                    let created = try repo.createKnownPlace(from: visit, name: candidate.name)
                    try repo.recordCorrection(Self.correctionEvent(
                        visit: visit,
                        fromKnownPlaceID: fromKnown,
                        fromAutoLabel: fromAuto,
                        to: created
                    ))
                    visit.reviewState = .confirmed
                }
            }
        }
        presentedSheet = nil
    }

    func applyTimes(to visit: VisitPlace, arrival: Date, departure: Date?) {
        performProperty(named: String(localized: "Edited times")) { repo in
            try repo.updateTimes(of: visit, arrival: arrival, departure: departure)
        }
        presentedSheet = nil
    }

    func applySplitVisit(_ visit: VisitPlace, at date: Date) {
        performProperty(named: String(localized: "Split")) { repo in
            _ = try repo.splitVisit(visit, at: date)
        }
        presentedSheet = nil
    }

    func applySplitMove(_ move: MoveSegment, at date: Date) {
        performProperty(named: String(localized: "Split")) { repo in
            _ = try repo.splitMove(move, at: date)
        }
        presentedSheet = nil
    }

    func dismissReview(_ visit: VisitPlace) {
        performProperty(named: String(localized: "Dismissed")) { _ in
            visit.reviewState = .dismissed
        }
    }

    func dismissReview(_ move: MoveSegment) {
        performProperty(named: String(localized: "Dismissed")) { _ in
            move.reviewState = .dismissed
        }
    }

    func confirmReview(_ visit: VisitPlace) {
        performProperty(named: String(localized: "Confirmed")) { _ in
            visit.reviewState = .confirmed
        }
    }

    func undoLastChange() {
        guard let context = modelContext, let undoController else { return }
        context.undoManager = undoController.manager
        guard undoController.manager.canUndo else { return }
        undoController.manager.undo()
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("Failed to save undo changes: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lookups

    func visit(id: UUID) -> VisitPlace? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func move(id: UUID) -> MoveSegment? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func knownPlace(id: UUID) -> KnownPlace? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<KnownPlace>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func timeBounds(for visit: VisitPlace) -> EditTimesBounds {
        let incoming = visit.incomingMoves.sorted { $0.endDate < $1.endDate }
        let outgoing = visit.outgoingMoves.sorted { $0.startDate < $1.startDate }
        let earliestArrival = incoming.last.map { $0.startDate.addingTimeInterval(1) } ?? visit.arrivalDate.addingTimeInterval(-12 * 60 * 60)
        let latestDeparture = outgoing.first.map { $0.endDate.addingTimeInterval(-1) } ?? (visit.departureDate ?? visit.arrivalDate).addingTimeInterval(12 * 60 * 60)
        return EditTimesBounds(
            earliestArrival: earliestArrival,
            latestDeparture: latestDeparture
        )
    }

    // MARK: - Private

    private func dissolve(_ visit: VisitPlace, named name: String) {
        guard let incoming = visit.incomingMoves.sorted(by: { $0.endDate < $1.endDate }).last,
              let outgoing = visit.outgoingMoves.sorted(by: { $0.startDate < $1.startDate }).first,
              incoming.id != outgoing.id
        else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }

        let willMergeLegs = incoming.transportMode == outgoing.transportMode
        let payload = DissolvedVisitUndoPayload(
            visit: visit,
            incoming: incoming,
            outgoing: outgoing,
            didDeleteOutgoing: willMergeLegs
        )
        performStructural(named: name) { repo, context in
            let result = try repo.dissolveVisit(visit)
            for move in result.movesNeedingRouteRefresh {
                move.clearCachedRouteCoordinates()
            }
            registerRestore(payload, on: context)
            let moves = result.movesNeedingRouteRefresh
            Task { @MainActor in
                for move in moves {
                    _ = await RoadRouteMatcher.matchedCoordinates(for: move)
                }
            }
        }
    }

    private func shouldDissolveOnDelete(_ visit: VisitPlace) -> Bool {
        let incoming = visit.incomingMoves.sorted { $0.endDate < $1.endDate }.last
        let outgoing = visit.outgoingMoves.sorted { $0.startDate < $1.startDate }.first
        guard let incoming, let outgoing, incoming.id != outgoing.id else {
            return false
        }
        return visit.appearsAsShortStop || TimelineReviewHeuristics.isShortTransitStop(visit)
    }

    private func mergeVisits(_ a: VisitPlace, _ b: VisitPlace) {
        let first = a.arrivalDate <= b.arrivalDate ? a : b
        let second = first.id == a.id ? b : a
        let payload = MergedVisitsUndoPayload(keeper: first, removed: second)
        performStructural(named: String(localized: "Merged")) { repo, context in
            _ = try repo.mergeVisits(first, second)
            registerRestore(payload, on: context)
        }
    }

    private func deletePlace(_ visit: VisitPlace) {
        guard let context = modelContext else { return }
        let payload = TimelineDeletedPlacePayload(place: visit)
        performStructural(named: String(localized: "Deleted")) { repo, context in
            repo.recordRemoval(of: visit)
            visit.keepPhotosOnDay()
            context.delete(visit)
            try context.save()
            registerRestore(payload, on: context)
        }
    }

    private func deleteMove(_ move: MoveSegment) {
        guard let context = modelContext else { return }
        let payload = TimelineDeletedMovePayload(segment: move)
        performStructural(named: String(localized: "Deleted")) { repo, context in
            repo.recordRemoval(of: move)
            context.delete(move)
            try context.save()
            registerRestore(payload, on: context)
        }
    }

    private func assign(_ visit: VisitPlace, to place: KnownPlace, using repo: SwiftDataTimelineRepository) throws {
        let fromKnown = visit.knownPlace?.id
        let fromAuto = visit.autoLabel
        try repo.assign(visit, to: place, source: .user, confidence: 1)
        try repo.recordCorrection(Self.correctionEvent(
            visit: visit,
            fromKnownPlaceID: fromKnown,
            fromAutoLabel: fromAuto,
            to: place
        ))
        visit.reviewState = .confirmed
    }

    private static func correctionEvent(
        visit: VisitPlace,
        fromKnownPlaceID: UUID?,
        fromAutoLabel: String?,
        to place: KnownPlace
    ) -> PlaceCorrectionEvent {
        let calendar = Calendar.current
        let weekday = min(max(calendar.component(.weekday, from: visit.arrivalDate) - 1, 0), 6)
        return PlaceCorrectionEvent(
            visitPlaceID: visit.id,
            fromKnownPlaceID: fromKnownPlaceID,
            fromAutoLabel: fromAutoLabel,
            toKnownPlaceID: place.id,
            latitude: visit.latitude,
            longitude: visit.longitude,
            arrivalHour: calendar.component(.hour, from: visit.arrivalDate),
            weekday: weekday,
            stayDuration: TimelineReviewHeuristics.stayDuration(of: visit) ?? 0
        )
    }

    private func repository() -> SwiftDataTimelineRepository? {
        modelContext.map(SwiftDataTimelineRepository.init(modelContext:))
    }

    private func performProperty(named name: String, _ work: (SwiftDataTimelineRepository) throws -> Void) {
        guard let context = modelContext, let undoController, let repo = repository() else { return }
        context.undoManager = undoController.manager
        undoController.manager.beginUndoGrouping()
        undoController.manager.setActionName(name)
        defer { undoController.manager.endUndoGrouping() }
        do {
            try work(repo)
            if context.hasChanges {
                try context.save()
            }
            presentToast(name)
        } catch {
            context.rollback()
            presentError(error)
        }
    }

    private func performStructural(
        named name: String,
        _ work: (SwiftDataTimelineRepository, ModelContext) throws -> Void
    ) {
        guard let context = modelContext, let undoController, let repo = repository() else { return }
        let previous = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = previous }
        do {
            try work(repo, context)
            if context.hasChanges {
                try context.save()
            }
            undoController.manager.setActionName(name)
            presentToast(name)
        } catch {
            context.rollback()
            presentError(error)
        }
    }

    private func registerRestore<Payload: TimelineUndoRestoring>(_ payload: Payload, on context: ModelContext) {
        guard let undoController else { return }
        let manager = undoController.manager
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { editor in
            guard let targetContext = editor.modelContext else { return }
            let previous = targetContext.undoManager
            targetContext.undoManager = nil
            payload.restore(in: targetContext)
            if targetContext.hasChanges {
                try? targetContext.save()
            }
            targetContext.undoManager = previous
        }
        manager.endUndoGrouping()
    }

    private func presentToast(_ name: String) {
        toast?.show(actionName: name) { [weak self] in
            self?.undoLastChange()
        }
    }

    private func presentError(_ error: Error) {
        if let editing = error as? TimelineEditingError {
            switch editing {
            case .missingNeighbors:
                errorMessage = String(localized: "This item needs a visit before and after it.")
            case .invalidSplitTime:
                errorMessage = String(localized: "Pick a time between the start and end.")
            case .invalidTimeRange:
                errorMessage = String(localized: "Arrival needs to be before departure.")
            case .cannotMergeSameVisit:
                errorMessage = String(localized: "Those are the same place.")
            case .visitNotFound, .moveNotFound:
                errorMessage = String(localized: "That timeline item is no longer here.")
            }
        } else {
            errorMessage = error.localizedDescription
        }
        isShowingError = true
    }
}

/// Neighbor-clamped range for the edit-times sheet.
struct EditTimesBounds {
    var earliestArrival: Date
    var latestDeparture: Date
}

@MainActor
private protocol TimelineUndoRestoring {
    func restore(in context: ModelContext)
}

/// Undo payloads outlive the rows they describe, so they keep IDs and find the live row
/// when they run. A reference they held could be a deleted instance by then.
private enum LiveTimelineRows {
    static func visit(_ id: UUID?, in context: ModelContext) -> VisitPlace? {
        guard let id else { return nil }
        return (try? context.fetch(FetchDescriptor<VisitPlace>()))?.first { $0.id == id }
    }

    static func move(_ id: UUID?, in context: ModelContext) -> MoveSegment? {
        guard let id else { return nil }
        return (try? context.fetch(FetchDescriptor<MoveSegment>()))?.first { $0.id == id }
    }

    static func moves(_ ids: [UUID], in context: ModelContext) -> [MoveSegment] {
        guard !ids.isEmpty else { return [] }
        return ((try? context.fetch(FetchDescriptor<MoveSegment>())) ?? []).filter { ids.contains($0.id) }
    }

    static func knownPlace(_ id: UUID?, in context: ModelContext) -> KnownPlace? {
        guard let id else { return nil }
        return (try? context.fetch(FetchDescriptor<KnownPlace>()))?.first { $0.id == id }
    }

    static func photos(_ identifiers: [String], in context: ModelContext) -> [PhotoAttachment] {
        guard !identifiers.isEmpty else { return [] }
        return ((try? context.fetch(FetchDescriptor<PhotoAttachment>())) ?? [])
            .filter { identifiers.contains($0.assetLocalIdentifier) }
    }
}

private struct TimelineDeletedPlacePayload: TimelineUndoRestoring {
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
    let assignmentSourceRaw: String
    let assignmentConfidence: Double
    let originRaw: String
    let isHiddenAsShortStop: Bool
    let countryCode: String?
    let locality: String?
    let administrativeArea: String?
    let thoroughfare: String?
    let formattedAddress: String?
    let reviewStateRaw: String
    let dayTimeline: DayTimeline?
    let knownPlaceID: UUID?
    let outgoingMoveIDs: [UUID]
    let incomingMoveIDs: [UUID]
    let photoIdentifiers: [String]

    init(place: VisitPlace) {
        id = place.id
        arrivalDate = place.arrivalDate
        departureDate = place.departureDate
        latitude = place.latitude
        longitude = place.longitude
        horizontalAccuracy = place.horizontalAccuracy
        userLabel = place.userLabel
        autoLabel = place.autoLabel
        comment = place.comment
        createdAt = place.createdAt
        assignmentSourceRaw = place.assignmentSourceRaw
        assignmentConfidence = place.assignmentConfidence
        originRaw = place.originRaw
        isHiddenAsShortStop = place.isHiddenAsShortStop
        countryCode = place.countryCode
        locality = place.locality
        administrativeArea = place.administrativeArea
        thoroughfare = place.thoroughfare
        formattedAddress = place.formattedAddress
        reviewStateRaw = place.reviewStateRaw
        dayTimeline = place.dayTimeline
        knownPlaceID = place.knownPlace?.id
        outgoingMoveIDs = place.outgoingMoves.map(\.id)
        incomingMoveIDs = place.incomingMoves.map(\.id)
        photoIdentifiers = place.photoAttachments.map(\.assetLocalIdentifier)
    }

    /// Re-creates the visit and points its surviving moves and photos back at it.
    func restore(in context: ModelContext) {
        guard LiveTimelineRows.visit(id, in: context) == nil else { return }
        let restored = VisitPlace(
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            userLabel: userLabel,
            autoLabel: autoLabel,
            comment: comment
        )
        restored.id = id
        restored.createdAt = createdAt
        restored.assignmentSourceRaw = assignmentSourceRaw
        restored.assignmentConfidence = assignmentConfidence
        restored.originRaw = originRaw
        restored.isHiddenAsShortStop = isHiddenAsShortStop
        restored.countryCode = countryCode
        restored.locality = locality
        restored.administrativeArea = administrativeArea
        restored.thoroughfare = thoroughfare
        restored.formattedAddress = formattedAddress
        restored.reviewStateRaw = reviewStateRaw
        restored.dayTimeline = dayTimeline
        restored.knownPlace = LiveTimelineRows.knownPlace(knownPlaceID, in: context)
        if knownPlaceID != nil, restored.knownPlace == nil {
            restored.assignmentSource = .none
            restored.assignmentConfidence = 0
        }
        context.insert(restored)
        for move in LiveTimelineRows.moves(outgoingMoveIDs, in: context) {
            move.startPlace = restored
        }
        for move in LiveTimelineRows.moves(incomingMoveIDs, in: context) {
            move.endPlace = restored
        }
        for photo in LiveTimelineRows.photos(photoIdentifiers, in: context) {
            photo.visitPlace = restored
        }
    }
}

private struct TimelineDeletedMovePayload: TimelineUndoRestoring {
    let id: UUID
    let dedupeKey: String
    let startDate: Date
    let endDate: Date
    let transportMode: TransportMode
    let distanceMeters: Double
    let stepCount: Int?
    let comment: String?
    let createdAt: Date
    let startPlaceID: UUID?
    let endPlaceID: UUID?
    let dayTimeline: DayTimeline?
    let routeCacheSignature: String?
    let routeCacheCoordinatesData: Data?
    let manualRouteCoordinatesData: Data?
    let speedProfileData: Data?
    let transportModeSourceRaw: String
    let originRaw: String
    let routeMatchPolicyRaw: String
    let routeMatchConfidenceRaw: String
    let routeMatchSummary: String?
    let reviewStateRaw: String
    let samples: [LocationSample]

    init(segment: MoveSegment) {
        id = segment.id
        dedupeKey = segment.dedupeKey
        startDate = segment.startDate
        endDate = segment.endDate
        transportMode = segment.transportMode
        distanceMeters = segment.distanceMeters
        stepCount = segment.stepCount
        comment = segment.comment
        createdAt = segment.createdAt
        startPlaceID = segment.startPlace?.id
        endPlaceID = segment.endPlace?.id
        dayTimeline = segment.dayTimeline
        routeCacheSignature = segment.routeCacheSignature
        routeCacheCoordinatesData = segment.routeCacheCoordinatesData
        manualRouteCoordinatesData = segment.manualRouteCoordinatesData
        speedProfileData = segment.speedProfileData
        transportModeSourceRaw = segment.transportModeSourceRaw
        originRaw = segment.originRaw
        routeMatchPolicyRaw = segment.routeMatchPolicyRaw
        routeMatchConfidenceRaw = segment.routeMatchConfidenceRaw
        routeMatchSummary = segment.routeMatchSummary
        reviewStateRaw = segment.reviewStateRaw
        samples = segment.samples
    }

    func restore(in context: ModelContext) {
        guard LiveTimelineRows.move(id, in: context) == nil else { return }
        let restored = MoveSegment(
            dedupeKey: dedupeKey,
            startDate: startDate,
            endDate: endDate,
            transportMode: transportMode,
            distanceMeters: distanceMeters,
            stepCount: stepCount,
            comment: comment
        )
        restored.id = id
        restored.createdAt = createdAt
        restored.startPlace = LiveTimelineRows.visit(startPlaceID, in: context)
        restored.endPlace = LiveTimelineRows.visit(endPlaceID, in: context)
        restored.dayTimeline = dayTimeline
        restored.routeCacheSignature = routeCacheSignature
        restored.routeCacheCoordinatesData = routeCacheCoordinatesData
        restored.manualRouteCoordinatesData = manualRouteCoordinatesData
        restored.speedProfileData = speedProfileData
        restored.transportModeSourceRaw = transportModeSourceRaw
        restored.originRaw = originRaw
        restored.routeMatchPolicyRaw = routeMatchPolicyRaw
        restored.routeMatchConfidenceRaw = routeMatchConfidenceRaw
        restored.routeMatchSummary = routeMatchSummary
        restored.reviewStateRaw = reviewStateRaw
        context.insert(restored)
        for sample in samples {
            sample.moveSegment = restored
        }
    }
}

private struct DissolvedVisitUndoPayload: TimelineUndoRestoring {
    let visit: TimelineDeletedPlacePayload
    let outgoing: TimelineDeletedMovePayload
    let didDeleteOutgoing: Bool
    let incomingID: UUID
    let incomingEndDate: Date
    let incomingDistance: Double
    let incomingMode: TransportMode
    let incomingStepCount: Int?
    let incomingComment: String?
    let incomingCacheSignature: String?
    let incomingCacheData: Data?
    let incomingManualData: Data?
    let incomingPolicyRaw: String
    let incomingConfidenceRaw: String
    let incomingSummary: String?
    let incomingSpeedProfile: Data?
    let outgoingStartDate: Date
    let outgoingCacheSignature: String?
    let outgoingCacheData: Data?
    let outgoingManualData: Data?

    init(
        visit: VisitPlace,
        incoming: MoveSegment,
        outgoing: MoveSegment,
        didDeleteOutgoing: Bool
    ) {
        self.visit = TimelineDeletedPlacePayload(place: visit)
        self.outgoing = TimelineDeletedMovePayload(segment: outgoing)
        self.didDeleteOutgoing = didDeleteOutgoing
        incomingID = incoming.id
        incomingEndDate = incoming.endDate
        incomingDistance = incoming.distanceMeters
        incomingMode = incoming.transportMode
        incomingStepCount = incoming.stepCount
        incomingComment = incoming.comment
        incomingCacheSignature = incoming.routeCacheSignature
        incomingCacheData = incoming.routeCacheCoordinatesData
        incomingManualData = incoming.manualRouteCoordinatesData
        incomingPolicyRaw = incoming.routeMatchPolicyRaw
        incomingConfidenceRaw = incoming.routeMatchConfidenceRaw
        incomingSummary = incoming.routeMatchSummary
        incomingSpeedProfile = incoming.speedProfileData
        outgoingStartDate = outgoing.startDate
        outgoingCacheSignature = outgoing.routeCacheSignature
        outgoingCacheData = outgoing.routeCacheCoordinatesData
        outgoingManualData = outgoing.manualRouteCoordinatesData
    }

    func restore(in context: ModelContext) {
        visit.restore(in: context)
        if didDeleteOutgoing {
            outgoing.restore(in: context)
        } else {
            let liveOutgoing = LiveTimelineRows.move(outgoing.id, in: context)
            liveOutgoing?.startDate = outgoingStartDate
            liveOutgoing?.routeCacheSignature = outgoingCacheSignature
            liveOutgoing?.routeCacheCoordinatesData = outgoingCacheData
            liveOutgoing?.manualRouteCoordinatesData = outgoingManualData
            liveOutgoing?.routeMatchPolicyRaw = outgoing.routeMatchPolicyRaw
            liveOutgoing?.routeMatchConfidenceRaw = outgoing.routeMatchConfidenceRaw
            liveOutgoing?.routeMatchSummary = outgoing.routeMatchSummary
            liveOutgoing?.speedProfileData = outgoing.speedProfileData
        }
        let incoming = LiveTimelineRows.move(incomingID, in: context)
        incoming?.endDate = incomingEndDate
        incoming?.distanceMeters = incomingDistance
        incoming?.transportMode = incomingMode
        incoming?.stepCount = incomingStepCount
        incoming?.comment = incomingComment
        incoming?.routeCacheSignature = incomingCacheSignature
        incoming?.routeCacheCoordinatesData = incomingCacheData
        incoming?.manualRouteCoordinatesData = incomingManualData
        incoming?.routeMatchPolicyRaw = incomingPolicyRaw
        incoming?.routeMatchConfidenceRaw = incomingConfidenceRaw
        incoming?.routeMatchSummary = incomingSummary
        incoming?.speedProfileData = incomingSpeedProfile
    }
}

private struct MergedVisitsUndoPayload: TimelineUndoRestoring {
    let keeperID: UUID
    let keeperDeparture: Date?
    let keeperLatitude: Double
    let keeperLongitude: Double
    let keeperAccuracy: Double
    let keeperUserLabel: String?
    let keeperAutoLabel: String?
    let keeperComment: String?
    let keeperKnownPlaceID: UUID?
    let keeperAssignmentSourceRaw: String
    let keeperAssignmentConfidence: Double
    let removed: TimelineDeletedPlacePayload
    let connectingMoves: [TimelineDeletedMovePayload]

    init(keeper: VisitPlace, removed: VisitPlace) {
        keeperID = keeper.id
        keeperDeparture = keeper.departureDate
        keeperLatitude = keeper.latitude
        keeperLongitude = keeper.longitude
        keeperAccuracy = keeper.horizontalAccuracy
        keeperUserLabel = keeper.userLabel
        keeperAutoLabel = keeper.autoLabel
        keeperComment = keeper.comment
        keeperKnownPlaceID = keeper.knownPlace?.id
        keeperAssignmentSourceRaw = keeper.assignmentSourceRaw
        keeperAssignmentConfidence = keeper.assignmentConfidence
        self.removed = TimelineDeletedPlacePayload(place: removed)
        let connecting = (keeper.outgoingMoves + removed.incomingMoves).filter { move in
            (move.startPlace?.id == keeper.id && move.endPlace?.id == removed.id)
                || (move.startPlace?.id == removed.id && move.endPlace?.id == keeper.id)
        }
        connectingMoves = connecting.map(TimelineDeletedMovePayload.init)
    }

    func restore(in context: ModelContext) {
        removed.restore(in: context)
        for payload in connectingMoves {
            payload.restore(in: context)
        }
        let keeper = LiveTimelineRows.visit(keeperID, in: context)
        keeper?.departureDate = keeperDeparture
        keeper?.latitude = keeperLatitude
        keeper?.longitude = keeperLongitude
        keeper?.horizontalAccuracy = keeperAccuracy
        keeper?.userLabel = keeperUserLabel
        keeper?.autoLabel = keeperAutoLabel
        keeper?.comment = keeperComment
        keeper?.knownPlace = LiveTimelineRows.knownPlace(keeperKnownPlaceID, in: context)
        keeper?.assignmentSourceRaw = keeperAssignmentSourceRaw
        keeper?.assignmentConfidence = keeperAssignmentConfidence
    }
}
