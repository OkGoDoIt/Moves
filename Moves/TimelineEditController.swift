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
        guard isLive(visit) else { return }
        dissolve(visit, named: String(localized: "Not a stop"))
    }

    func mergeWithPreviousPlace(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
        guard let previous = TimelineNeighbors.previousVisit(for: visit) else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        guard isLive(previous) else { return }
        mergeVisits(previous, visit)
    }

    func mergeWithNextPlace(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
        guard let next = TimelineNeighbors.nextVisit(for: visit) else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        guard isLive(next) else { return }
        mergeVisits(visit, next)
    }

    func requestSplitVisit(_ visit: VisitPlace) {
        presentedSheet = .splitVisit(visit.id)
    }

    func requestEditTimes(_ visit: VisitPlace) {
        presentedSheet = .editTimes(visit.id)
    }

    func requestDeletePlace(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
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
        guard isLive(move) else { return }
        // Restored from a payload: the map rematches this move right away, and that cache
        // write would otherwise leave SwiftData's own undo unable to bring the mode back.
        let payload = TimelineModeChangePayload(move: move)
        performStructural(named: String(localized: "Changed mode")) { repo, context in
            try repo.setTransportMode(mode, for: move, source: .user)
            move.reviewState = .confirmed
            registerRestore(payload, on: context)
        }
    }

    func requestSplitMove(_ move: MoveSegment) {
        presentedSheet = .splitMove(move.id)
    }

    func mergeWithPreviousMove(_ move: MoveSegment) {
        guard isLive(move) else { return }
        guard let startPlace = move.startPlace else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        markNotAStop(startPlace)
    }

    func mergeWithNextMove(_ move: MoveSegment) {
        guard isLive(move) else { return }
        guard let endPlace = move.endPlace else {
            presentError(TimelineEditingError.missingNeighbors)
            return
        }
        markNotAStop(endPlace)
    }

    func requestDeleteMove(_ move: MoveSegment) {
        guard isLive(move) else { return }
        deleteMove(move)
    }

    // MARK: - Sheet completions

    func applyRename(to visit: VisitPlace, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isLive(visit) else { presentedSheet = nil; return }
        performProperty(named: String(localized: "Renamed"), around: visit) { repo in
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
        guard isLive(visit) else { presentedSheet = nil; return }
        performProperty(named: String(localized: "Renamed"), around: visit) { repo in
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

    // Times and splits are put back from a copy taken first: SwiftData's own undo was seen
    // undoing an unrelated background write instead, or leaving the change in place.
    func applyTimes(to visit: VisitPlace, arrival: Date, departure: Date?) {
        guard isLive(visit) else { presentedSheet = nil; return }
        let payload = TimelineRowsPayload(
            visits: [visit],
            moves: visit.incomingMoves + visit.outgoingMoves
        )
        performStructural(named: String(localized: "Edited times")) { repo, context in
            try repo.updateTimes(of: visit, arrival: arrival, departure: departure)
            registerRestore(payload, on: context)
        }
        presentedSheet = nil
    }

    func applySplitVisit(_ visit: VisitPlace, at date: Date) {
        guard isLive(visit) else { presentedSheet = nil; return }
        var payload = TimelineRowsPayload(visits: [visit], moves: visit.outgoingMoves)
        performStructural(named: String(localized: "Split")) { repo, context in
            let (_, second) = try repo.splitVisit(visit, at: date)
            payload.createdVisitIDs = [second.id]
            registerRestore(payload, on: context)
        }
        presentedSheet = nil
    }

    func applySplitMove(_ move: MoveSegment, at date: Date) {
        guard isLive(move) else { presentedSheet = nil; return }
        var payload = TimelineRowsPayload(visits: [], moves: [move])
        performStructural(named: String(localized: "Split")) { repo, context in
            let (_, stop, second) = try repo.splitMove(move, at: date)
            payload.createdVisitIDs = [stop.id]
            payload.createdMoveIDs = [second.id]
            registerRestore(payload, on: context)
        }
        presentedSheet = nil
    }

    // Review answers are restored from payloads: SwiftData's own undo is not a reliable
    // step to hand the Undo pill (see `AppUndoStep`).
    func dismissReview(_ visit: VisitPlace) {
        dismissReviews(visitIDs: [visit.id], moveIDs: [])
    }

    func dismissReview(_ move: MoveSegment) {
        dismissReviews(visitIDs: [], moveIDs: [move.id])
    }

    func confirmReview(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
        let payload = ReviewStatesPayload(visits: [(visit.id, visit.reviewStateRaw)], moves: [])
        performStructural(named: String(localized: "Confirmed")) { _, context in
            visit.reviewState = .confirmed
            registerRestore(payload, on: context)
        }
    }

    /// Accepts the place a stay was matched to, so later stays there match it too.
    func confirmPlace(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
        guard let place = visit.knownPlace else {
            confirmReview(visit)
            return
        }
        // Restored from a payload so Undo reliably brings the question back.
        let payload = ConfirmedPlacePayload(visit: visit)
        performStructural(named: String(localized: "Confirmed")) { repo, context in
            let eventsBefore = Set(try context.fetch(FetchDescriptor<PlaceCorrectionEvent>()).map(\.id))
            try assign(visit, to: place, using: repo)
            let added = try context.fetch(FetchDescriptor<PlaceCorrectionEvent>())
                .map(\.id).filter { !eventsBefore.contains($0) }
            registerRestore(payload.removingEvents(added), on: context)
        }
    }

    /// Keeps a brief stay as a stop.
    func keepStop(_ visit: VisitPlace) {
        guard isLive(visit) else { return }
        let payload = ReviewStatesPayload(visits: [(visit.id, visit.reviewStateRaw)], moves: [])
        performStructural(named: String(localized: "Kept stop")) { _, context in
            visit.reviewState = .confirmed
            registerRestore(payload, on: context)
        }
    }

    /// Dismisses every listed question as one Undo step. Rows are looked up by id here,
    /// so a list built a moment ago never writes to a row that has since gone.
    func dismissReviews(visitIDs: [UUID], moveIDs: [UUID]) {
        guard let context = modelContext, !(visitIDs.isEmpty && moveIDs.isEmpty) else { return }
        let count = visitIDs.count + moveIDs.count
        let name = count == 1
            ? String(localized: "Dismissed")
            : String(localized: "Dismissed \(count)")
        // Restored from a payload, so a bulk change is exactly one step on the Undo pill.
        performStructural(named: name) { _, context in
            let visits = visitIDs.isEmpty ? [] : try context.fetch(FetchDescriptor<VisitPlace>(
                predicate: #Predicate { visitIDs.contains($0.id) && $0.dayTimeline != nil }
            ))
            let moves = moveIDs.isEmpty ? [] : try context.fetch(FetchDescriptor<MoveSegment>(
                predicate: #Predicate { moveIDs.contains($0.id) && $0.dayTimeline != nil }
            ))
            let payload = ReviewStatesPayload(
                visits: visits.map { ($0.id, $0.reviewStateRaw) },
                moves: moves.map { ($0.id, $0.reviewStateRaw) }
            )
            for visit in visits { visit.reviewState = .dismissed }
            for move in moves { move.reviewState = .dismissed }
            registerRestore(payload, on: context)
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

    /// The live stay with this id; nil once the rebuild retired it.
    func visit(id: UUID) -> VisitPlace? {
        guard let context = modelContext else { return nil }
        return LiveTimelineRows.visit(id, in: context)
    }

    /// The live trip with this id; nil once the rebuild retired it.
    func move(id: UUID) -> MoveSegment? {
        guard let context = modelContext else { return nil }
        return LiveTimelineRows.move(id, in: context)
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

    /// A view can still show a row the rebuild retired on another context a moment ago.
    /// Editing it would attach it to a place or day again, so the edit says it is gone.
    private func isLive(_ visit: VisitPlace) -> Bool {
        guard !visit.isDeleted, !TimelineRetirement.isRetired(visit) else {
            presentError(TimelineEditingError.visitNotFound)
            return false
        }
        return true
    }

    private func isLive(_ move: MoveSegment) -> Bool {
        guard !move.isDeleted, !TimelineRetirement.isRetired(move) else {
            presentError(TimelineEditingError.moveNotFound)
            return false
        }
        return true
    }

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
            // Ids, not rows: each match awaits, and a trip can be undone, deleted, or
            // retired before the next one starts.
            let moveIDs = result.movesNeedingRouteRefresh.map(\.id)
            Task { @MainActor in
                for id in moveIDs {
                    _ = await RoadRouteMatcher.matchedCoordinates(moveID: id, in: context)
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

    /// Naming edits: the stays and learned places near that stay are copied first and put
    /// back by the Undo step, because SwiftData's own undo of these edits was seen restoring
    /// nothing in the running app (a rename stayed after Undo).
    private func performProperty(
        named name: String,
        around visit: VisitPlace,
        _ work: (SwiftDataTimelineRepository) throws -> Void
    ) {
        guard let context = modelContext else { return }
        let payload = NamingAreaPayload(around: visit, in: context)
        performStructural(named: name) { repo, context in
            try work(repo)
            registerRestore(payload, on: context)
        }
    }

    /// Structural edits put back a payload that `work` registers with `registerRestore`.
    private func performStructural(
        named name: String,
        _ work: (SwiftDataTimelineRepository, ModelContext) throws -> Void
    ) {
        guard let context = modelContext, undoController != nil, let repo = repository() else { return }
        let previous = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = previous }
        registeredStep = nil
        registeringName = name
        do {
            try work(repo, context)
            if context.hasChanges {
                try context.save()
            }
            if let step = registeredStep {
                presentToast(step)
            }
        } catch {
            if let step = registeredStep {
                // The change did not happen, so there is nothing for its step to undo.
                undoController?.manager.removeAllActions(withTarget: step)
            }
            context.rollback()
            presentError(error)
        }
        registeredStep = nil
    }

    @ObservationIgnored
    private var registeredStep: AppUndoStep?
    @ObservationIgnored
    private var registeringName = ""

    private func registerRestore<Payload: TimelineUndoRestoring>(_ payload: Payload, on context: ModelContext) {
        guard let undoController else { return }
        registeredStep = AppUndoStep.register(
            named: registeringName,
            on: undoController.manager
        ) { [weak self] in
            guard let targetContext = self?.modelContext else { return }
            targetContext.restoreWithoutUndo(payload)
        }
    }

    /// The pill undoes exactly this step, whatever has been written to the store since.
    private func presentToast(_ step: AppUndoStep) {
        let manager = undoController?.manager
        toast?.show(actionName: step.name) {
            step.undo(removingFrom: manager)
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
protocol TimelineUndoRestoring {
    func restore(in context: ModelContext)
}

extension ModelContext {
    /// Restores a deleted item with the undo manager detached, so the restore itself
    /// doesn't become a step on the person's undo stack.
    @MainActor
    func restoreWithoutUndo(_ payload: some TimelineUndoRestoring) {
        let manager = undoManager
        undoManager = nil
        payload.restore(in: self)
        if hasChanges {
            try? save()
        }
        undoManager = manager
    }
}

/// Undo payloads outlive the rows they describe, so they keep IDs and find the live row
/// when they run. A reference they held could be a deleted instance by then.
private enum LiveTimelineRows {
    // Fetched by id, not by loading every row: the phone holds thousands of them.
    // A row the rebuild retired since is gone too: putting it back would revive it.
    static func visit(_ id: UUID?, in context: ModelContext) -> VisitPlace? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == id && $0.dayTimeline != nil })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
    }

    static func move(_ id: UUID?, in context: ModelContext) -> MoveSegment? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id && $0.dayTimeline != nil })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first.flatMap { TimelineRetirement.isRetired($0) ? nil : $0 }
    }

    static func moves(_ ids: [UUID], in context: ModelContext) -> [MoveSegment] {
        guard !ids.isEmpty else { return [] }
        return ((try? context.fetch(FetchDescriptor<MoveSegment>(
            predicate: #Predicate { ids.contains($0.id) && $0.dayTimeline != nil }
        ))) ?? []).filter { !TimelineRetirement.isRetired($0) }
    }

    /// Whether any row with this id is still in the store, retired or not, so a restore
    /// never makes a second row with the same id.
    static func visitExists(_ id: UUID, in context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == id }))) ?? 0) > 0
    }

    static func moveExists(_ id: UUID, in context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id }))) ?? 0) > 0
    }

    static func knownPlace(_ id: UUID?, in context: ModelContext) -> KnownPlace? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<KnownPlace>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func day(_ key: String?, in context: ModelContext) -> DayTimeline? {
        guard let key else { return nil }
        var descriptor = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The fixes with these keys that are still in the store.
    static func samples(_ keys: [String], in context: ModelContext) -> [LocationSample] {
        guard !keys.isEmpty else { return [] }
        let wanted = Array(Set(keys))
        return (try? context.fetch(FetchDescriptor<LocationSample>(
            predicate: #Predicate { wanted.contains($0.dedupeKey) }
        ))) ?? []
    }

    /// Only the stay's own photos: the library can hold tens of thousands, and this runs
    /// on the main context when a delete is undone.
    static func photos(_ identifiers: [String], in context: ModelContext) -> [PhotoAttachment] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Array(Set(identifiers))
        return (try? context.fetch(FetchDescriptor<PhotoAttachment>(
            predicate: #Predicate { wanted.contains($0.assetLocalIdentifier) }
        ))) ?? []
    }
}

/// A stay's place match as it was before "Yes", the place's learned footprint and visit
/// count, plus the answer it recorded.
private struct ConfirmedPlacePayload: TimelineUndoRestoring {
    let id: UUID
    let knownPlaceID: UUID?
    let assignmentSourceRaw: String
    let assignmentConfidence: Double
    let reviewStateRaw: String
    let userLabel: String?
    /// What "Yes" teaches the place (center, radius, count, histograms) is put back too.
    let place: KnownPlaceUndoPayload?
    var eventIDs: [UUID] = []

    init(visit: VisitPlace) {
        id = visit.id
        knownPlaceID = visit.knownPlace?.id
        assignmentSourceRaw = visit.assignmentSourceRaw
        assignmentConfidence = visit.assignmentConfidence
        reviewStateRaw = visit.reviewStateRaw
        userLabel = visit.userLabel
        place = visit.knownPlace.map(KnownPlaceUndoPayload.init)
    }

    func removingEvents(_ ids: [UUID]) -> ConfirmedPlacePayload {
        var copy = self
        copy.eventIDs = ids
        return copy
    }

    func restore(in context: ModelContext) {
        if let visit = LiveTimelineRows.visit(id, in: context) {
            visit.knownPlace = LiveTimelineRows.knownPlace(knownPlaceID, in: context)
            visit.assignmentSourceRaw = assignmentSourceRaw
            visit.assignmentConfidence = assignmentConfidence
            visit.reviewStateRaw = reviewStateRaw
            visit.userLabel = userLabel
        }
        place?.overwriteExisting(in: context)
        guard !eventIDs.isEmpty else { return }
        let ids = eventIDs
        let events = (try? context.fetch(FetchDescriptor<PlaceCorrectionEvent>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for event in events { context.delete(event) }
    }
}

/// Everything naming a stay can change, as it was: the stays and learned places around it
/// (naming can assign a place's earlier stays too), which places and answers existed.
/// Undo puts those back, removes places and answers the naming added, and nothing else.
private struct NamingAreaPayload: TimelineUndoRestoring {
    /// Wide enough for a learned place's largest footprint around the stay.
    static let reach: CLLocationDistance = 1_000

    let visits: VisitAssignmentSnapshot
    let places: [KnownPlaceUndoPayload]
    let placeIDs: Set<UUID>
    let eventIDs: Set<UUID>

    init(around visit: VisitPlace, in context: ModelContext) {
        let latitudeDelta = Self.reach / 111_000
        let longitudeDelta = latitudeDelta / max(cos(visit.latitude * .pi / 180), 0.01)
        let minLat = visit.latitude - latitudeDelta, maxLat = visit.latitude + latitudeDelta
        let minLon = visit.longitude - longitudeDelta, maxLon = visit.longitude + longitudeDelta
        let nearbyVisits = (try? context.fetch(FetchDescriptor<VisitPlace>(predicate: #Predicate {
            $0.latitude >= minLat && $0.latitude <= maxLat && $0.longitude >= minLon && $0.longitude <= maxLon
                && $0.dayTimeline != nil
        }))) ?? []
        let allPlaces = (try? context.fetch(FetchDescriptor<KnownPlace>())) ?? []
        let nearbyPlaces = allPlaces.filter {
            $0.centerLatitude >= minLat && $0.centerLatitude <= maxLat
                && $0.centerLongitude >= minLon && $0.centerLongitude <= maxLon
        }
        // Stays already matched to a nearby place, wherever they are, can be reassigned too.
        let placedVisits = nearbyPlaces.flatMap(\.visits)
        var seen = Set<UUID>()
        let touched = ([visit] + nearbyVisits + placedVisits).filter { seen.insert($0.id).inserted }
        visits = VisitAssignmentSnapshot(touched)
        places = nearbyPlaces.map(KnownPlaceUndoPayload.init)
        placeIDs = Set(allPlaces.map(\.id))
        eventIDs = Set(((try? context.fetch(FetchDescriptor<PlaceCorrectionEvent>())) ?? []).map(\.id))
    }

    func restore(in context: ModelContext) {
        let knownIDs = placeIDs
        for place in (try? context.fetch(FetchDescriptor<KnownPlace>())) ?? [] where !knownIDs.contains(place.id) {
            for visit in place.visits { visit.knownPlace = nil }
            context.delete(place)
        }
        for payload in places {
            payload.overwriteExisting(in: context)
        }
        visits.restore(in: context)
        let oldEvents = eventIDs
        for event in (try? context.fetch(FetchDescriptor<PlaceCorrectionEvent>())) ?? [] where !oldEvents.contains(event.id) {
            context.delete(event)
        }
    }
}

/// Review answers as they were before a Dismiss, found by id when Undo runs.
private struct ReviewStatesPayload: TimelineUndoRestoring {
    let visits: [(UUID, String)]
    let moves: [(UUID, String)]

    func restore(in context: ModelContext) {
        let visitStates = Dictionary(visits, uniquingKeysWith: { first, _ in first })
        let moveStates = Dictionary(moves, uniquingKeysWith: { first, _ in first })
        let visitIDs = Array(visitStates.keys)
        let moveIDs = Array(moveStates.keys)
        // Live rows only: a retired stay's review field carries its retirement mark.
        if !visitIDs.isEmpty {
            let rows = (try? context.fetch(FetchDescriptor<VisitPlace>(
                predicate: #Predicate { visitIDs.contains($0.id) && $0.dayTimeline != nil }
            ))) ?? []
            for row in rows where !TimelineRetirement.isRetired(row) {
                row.reviewStateRaw = visitStates[row.id] ?? row.reviewStateRaw
            }
        }
        if !moveIDs.isEmpty {
            let rows = (try? context.fetch(FetchDescriptor<MoveSegment>(
                predicate: #Predicate { moveIDs.contains($0.id) && $0.dayTimeline != nil }
            ))) ?? []
            for row in rows where !TimelineRetirement.isRetired(row) {
                row.reviewStateRaw = moveStates[row.id] ?? row.reviewStateRaw
            }
        }
    }
}

private struct TimelineModeChangePayload: TimelineUndoRestoring {
    let id: UUID
    let mode: TransportMode
    let source: TransportModeSource
    let reviewState: ReviewState

    init(move: MoveSegment) {
        id = move.id
        mode = move.transportMode
        source = move.transportModeSource
        reviewState = move.reviewState
    }

    func restore(in context: ModelContext) {
        guard let move = LiveTimelineRows.move(id, in: context) else { return }
        move.transportMode = mode
        move.transportModeSource = source
        move.reviewState = reviewState
        move.clearCachedRouteCoordinates()
    }
}

/// The stays and trips an Edit Times or Split changes, as they were, plus the rows it made.
/// Undo puts the fields and links back, returns moved fixes to their trip, and removes what
/// the edit added. Rows are found by id when it runs.
struct TimelineRowsPayload: TimelineUndoRestoring {
    struct VisitFields {
        let id: UUID
        let arrivalDate: Date
        let departureDate: Date?
        let originRaw: String
        let dayKey: String?
    }

    struct MoveFields {
        let id: UUID
        let startDate: Date
        let endDate: Date
        let distanceMeters: Double
        let startPlaceID: UUID?
        let endPlaceID: UUID?
        let dayKey: String?
        let routeCacheSignature: String?
        let routeCacheCoordinatesData: Data?
        let manualRouteCoordinatesData: Data?
        let speedProfileData: Data?
        let routeMatchPolicyRaw: String
        let routeMatchConfidenceRaw: String
        let routeMatchSummary: String?
        /// Fix keys, not rows: a fix can be deleted on another context before Undo runs.
        let sampleKeys: [String]
    }

    let visits: [VisitFields]
    let moves: [MoveFields]
    var createdVisitIDs: [UUID] = []
    var createdMoveIDs: [UUID] = []

    init(visits: [VisitPlace], moves: [MoveSegment]) {
        var seenVisits = Set<UUID>()
        self.visits = visits.filter { seenVisits.insert($0.id).inserted }.map { visit in
            VisitFields(
                id: visit.id,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate,
                originRaw: visit.originRaw,
                dayKey: visit.dayTimeline?.dayKey
            )
        }
        var seenMoves = Set<UUID>()
        self.moves = moves.filter { seenMoves.insert($0.id).inserted }.map { move in
            MoveFields(
                id: move.id,
                startDate: move.startDate,
                endDate: move.endDate,
                distanceMeters: move.distanceMeters,
                startPlaceID: move.startPlace?.id,
                endPlaceID: move.endPlace?.id,
                dayKey: move.dayTimeline?.dayKey,
                routeCacheSignature: move.routeCacheSignature,
                routeCacheCoordinatesData: move.routeCacheCoordinatesData,
                manualRouteCoordinatesData: move.manualRouteCoordinatesData,
                speedProfileData: move.speedProfileData,
                routeMatchPolicyRaw: move.routeMatchPolicyRaw,
                routeMatchConfidenceRaw: move.routeMatchConfidenceRaw,
                routeMatchSummary: move.routeMatchSummary,
                sampleKeys: move.samples.map(\.dedupeKey)
            )
        }
    }

    func restore(in context: ModelContext) {
        // Links first, so removing the added rows leaves nothing pointing at them.
        for fields in moves {
            guard let move = LiveTimelineRows.move(fields.id, in: context) else { continue }
            move.startDate = fields.startDate
            move.endDate = fields.endDate
            move.distanceMeters = fields.distanceMeters
            move.startPlace = LiveTimelineRows.visit(fields.startPlaceID, in: context)
            move.endPlace = LiveTimelineRows.visit(fields.endPlaceID, in: context)
            if let day = LiveTimelineRows.day(fields.dayKey, in: context) { move.dayTimeline = day }
            move.routeCacheSignature = fields.routeCacheSignature
            move.routeCacheCoordinatesData = fields.routeCacheCoordinatesData
            move.manualRouteCoordinatesData = fields.manualRouteCoordinatesData
            move.speedProfileData = fields.speedProfileData
            move.routeMatchPolicyRaw = fields.routeMatchPolicyRaw
            move.routeMatchConfidenceRaw = fields.routeMatchConfidenceRaw
            move.routeMatchSummary = fields.routeMatchSummary
            for sample in LiveTimelineRows.samples(fields.sampleKeys, in: context) {
                sample.moveSegment = move
            }
        }
        for fields in visits {
            guard let visit = LiveTimelineRows.visit(fields.id, in: context) else { continue }
            visit.arrivalDate = fields.arrivalDate
            visit.departureDate = fields.departureDate
            visit.originRaw = fields.originRaw
            if let day = LiveTimelineRows.day(fields.dayKey, in: context) { visit.dayTimeline = day }
        }
        for id in createdMoveIDs {
            guard let move = LiveTimelineRows.move(id, in: context) else { continue }
            for sample in move.samples where sample.moveSegment?.id == id { sample.moveSegment = nil }
            context.delete(move)
        }
        for id in createdVisitIDs {
            guard let visit = LiveTimelineRows.visit(id, in: context) else { continue }
            for move in visit.incomingMoves + visit.outgoingMoves {
                if move.startPlace?.id == id { move.startPlace = nil }
                if move.endPlace?.id == id { move.endPlace = nil }
            }
            context.delete(visit)
        }
    }
}

struct TimelineDeletedPlacePayload: TimelineUndoRestoring {
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
    /// The day's key, not the row: Undo can run after the day was replaced.
    let dayKey: String?
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
        dayKey = place.dayTimeline?.dayKey
        knownPlaceID = place.knownPlace?.id
        outgoingMoveIDs = place.outgoingMoves.map(\.id)
        incomingMoveIDs = place.incomingMoves.map(\.id)
        photoIdentifiers = place.photoAttachments.map(\.assetLocalIdentifier)
    }

    /// Re-creates the visit and points its surviving moves and photos back at it.
    func restore(in context: ModelContext) {
        // A retired row with this id stays retired; a second row with its id is never made.
        guard !LiveTimelineRows.visitExists(id, in: context),
              let day = LiveTimelineRows.day(dayKey, in: context) else { return }
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
        restored.dayTimeline = day
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

struct TimelineDeletedMovePayload: TimelineUndoRestoring {
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
    /// Keys, not rows: the day or a fix can be gone from the store by the time Undo runs.
    let dayKey: String?
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
    let sampleKeys: [String]

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
        dayKey = segment.dayTimeline?.dayKey
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
        sampleKeys = segment.samples.map(\.dedupeKey)
    }

    func restore(in context: ModelContext) {
        // A retired row with this id stays retired; a second row with its id is never made.
        guard !LiveTimelineRows.moveExists(id, in: context),
              let day = LiveTimelineRows.day(dayKey, in: context) else { return }
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
        restored.dayTimeline = day
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
        for sample in LiveTimelineRows.samples(sampleKeys, in: context) {
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
