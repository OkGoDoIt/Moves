import SwiftData
import SwiftUI

/// A single row in the Review inbox, computed on demand from stored flags.
struct ReviewInboxItem: Identifiable {
    enum Kind {
        case visit(VisitPlace)
        case move(MoveSegment)
    }

    enum Section: String, CaseIterable, Identifiable {
        case ambiguousPlaces
        case possibleFalseStops
        case uncertainModes
        case approximateImports

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ambiguousPlaces: return String(localized: "Ambiguous places")
            case .possibleFalseStops: return String(localized: "Possible false stops")
            case .uncertainModes: return String(localized: "Uncertain modes")
            case .approximateImports: return String(localized: "Approximate imports")
            }
        }
    }

    var id: String
    var kind: Kind
    var section: Section
    var title: String
    var subtitle: String
}

/// Builds inbox rows from visits and moves. Never a separate queue.
enum ReviewInboxBuilder {
    static func items(visits: [VisitPlace], moves: [MoveSegment]) -> [ReviewInboxItem] {
        var items: [ReviewInboxItem] = []
        var usedVisitIDs = Set<UUID>()
        var usedMoveIDs = Set<UUID>()

        for visit in visits where visit.reviewState != .dismissed && visit.reviewState != .confirmed {
            if visit.assignmentSource == .autoAmbiguous {
                items.append(
                    ReviewInboxItem(
                        id: "ambiguous-\(visit.id.uuidString)",
                        kind: .visit(visit),
                        section: .ambiguousPlaces,
                        title: visit.displayTitle,
                        subtitle: String(localized: "Choose the right place")
                    )
                )
                usedVisitIDs.insert(visit.id)
            }
        }

        for visit in visits where visit.reviewState != .dismissed && visit.reviewState != .confirmed {
            guard !usedVisitIDs.contains(visit.id) else { continue }
            let short = TimelineReviewHeuristics.isShortTransitStop(visit)
            let aligned = TimelineReviewHeuristics.isPossibleFalseStop(visit)
            if short && (visit.reviewState == .pending || aligned) {
                items.append(
                    ReviewInboxItem(
                        id: "false-stop-\(visit.id.uuidString)",
                        kind: .visit(visit),
                        section: .possibleFalseStops,
                        title: visit.displayTitle,
                        subtitle: aligned
                            ? String(localized: "Short stop on a straight path")
                            : String(localized: "Short stop")
                    )
                )
                usedVisitIDs.insert(visit.id)
            }
        }

        for move in moves where move.reviewState != .dismissed && move.reviewState != .confirmed {
            if move.reviewState == .pending && move.transportModeSource == .auto {
                items.append(
                    ReviewInboxItem(
                        id: "mode-\(move.id.uuidString)",
                        kind: .move(move),
                        section: .uncertainModes,
                        title: move.transportMode.title,
                        subtitle: moveSubtitle(move)
                    )
                )
                usedMoveIDs.insert(move.id)
            }
        }

        for visit in visits where visit.origin == .imported && visit.reviewState == .pending {
            guard !usedVisitIDs.contains(visit.id) else { continue }
            items.append(
                ReviewInboxItem(
                    id: "import-visit-\(visit.id.uuidString)",
                    kind: .visit(visit),
                    section: .approximateImports,
                    title: visit.displayTitle,
                    subtitle: String(localized: "Imported visit")
                )
            )
            usedVisitIDs.insert(visit.id)
        }

        for move in moves where move.origin == .imported && !usedMoveIDs.contains(move.id) {
            let estimated = move.routeMatchConfidence == .estimated || move.routeMatchConfidence == .unknown
            guard move.reviewState == .pending || estimated else { continue }
            guard move.reviewState != .dismissed && move.reviewState != .confirmed else { continue }
            items.append(
                ReviewInboxItem(
                    id: "import-move-\(move.id.uuidString)",
                    kind: .move(move),
                    section: .approximateImports,
                    title: move.transportMode.title,
                    subtitle: String(localized: "Imported path")
                )
            )
        }

        return items
    }

    private static func moveSubtitle(_ move: MoveSegment) -> String {
        let start = move.startPlace?.displayTitle
        let end = move.endPlace?.displayTitle
        switch (start, end) {
        case let (start?, end?):
            return "\(start) → \(end)"
        default:
            return move.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
}

/// Inbox of timeline items that need a look, opened from the Timeline badge or `moves://review`.
struct ReviewInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timelineEditController) private var editController

    @Query(filter: #Predicate<VisitPlace> { visit in
        visit.reviewStateRaw == "pending" || visit.assignmentSourceRaw == "autoAmbiguous"
    }, sort: \VisitPlace.arrivalDate, order: .reverse)
    private var flaggedVisits: [VisitPlace]

    @Query(filter: #Predicate<MoveSegment> { move in
        move.reviewStateRaw == "pending" || move.originRaw == "imported"
    }, sort: \MoveSegment.startDate, order: .reverse)
    private var flaggedMoves: [MoveSegment]

    private var items: [ReviewInboxItem] {
        ReviewInboxBuilder.items(visits: flaggedVisits, moves: flaggedMoves)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "All clear"),
                        systemImage: "checkmark.circle",
                        description: Text(String(localized: "Nothing needs a review right now."))
                    )
                } else {
                    List {
                        ForEach(ReviewInboxItem.Section.allCases) { section in
                            let rows = items.filter { $0.section == section }
                            if !rows.isEmpty {
                                Section(section.title) {
                                    ForEach(rows) { item in
                                        reviewRow(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func reviewRow(_ item: ReviewInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.system(.body, design: .rounded).weight(.semibold))
            Text(item.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                switch item.kind {
                case .visit(let visit):
                    visitActions(visit, section: item.section)
                case .move(let move):
                    moveActions(move, section: item.section)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func visitActions(_ visit: VisitPlace, section: ReviewInboxItem.Section) -> some View {
        if let editor = editController {
            if section == .possibleFalseStops {
                Button(String(localized: "Not a stop")) {
                    editor.markNotAStop(visit)
                }
            }
            if section == .ambiguousPlaces {
                Button(String(localized: "Pick place")) {
                    editor.requestPickNearby(visit)
                }
            }
            Button(String(localized: "Dismiss")) {
                editor.dismissReview(visit)
            }
        }
    }

    @ViewBuilder
    private func moveActions(_ move: MoveSegment, section: ReviewInboxItem.Section) -> some View {
        if let editor = editController {
            if section == .uncertainModes {
                Button(String(localized: "Mode")) {
                    editor.requestChangeMode(move)
                }
            }
            Button(String(localized: "Dismiss")) {
                editor.dismissReview(move)
            }
        }
    }
}

/// Change the inferred transport mode for a move.
struct TransportModePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let move: MoveSegment
    var editController: TimelineEditController

    var body: some View {
        NavigationStack {
            List {
                ForEach(TransportMode.correctionChoices, id: \.self) { mode in
                    Button {
                        editController.setTransportMode(mode, for: move)
                        dismiss()
                    } label: {
                        Label(mode.title, systemImage: mode.symbolName)
                    }
                }
            }
            .navigationTitle(String(localized: "Change mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
