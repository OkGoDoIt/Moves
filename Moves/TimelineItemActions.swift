import SwiftData
import SwiftUI

/// Correction actions for a storyline row.
///
/// WS1 should wrap `StorylineRow` with swipe and a context menu using this
/// environment value:
///
/// ```
/// .environment(\.timelineItemActions, editController)
/// StorylineRow(...)
///     .timelinePlaceActions(visit)   // or .timelineMoveActions(move)
/// ```
///
/// Leading swipe: Rename (place) / Mode (move). Trailing swipe: Delete.
/// Context menu: place = Rename, Pick nearby, Not a stop, Merge prev/next,
/// Split, Edit times, Delete. Move = Change mode, Split, Merge prev/next,
/// Delete. Path is WS4 — omitted here so WS1 does not need a no-op menu.
@MainActor
protocol TimelineItemActions: AnyObject {
    func requestRename(_ visit: VisitPlace)
    func requestPickNearby(_ visit: VisitPlace)
    func markNotAStop(_ visit: VisitPlace)
    func mergeWithPreviousPlace(_ visit: VisitPlace)
    func mergeWithNextPlace(_ visit: VisitPlace)
    func requestSplitVisit(_ visit: VisitPlace)
    func requestEditTimes(_ visit: VisitPlace)
    func requestDeletePlace(_ visit: VisitPlace)

    func requestChangeMode(_ move: MoveSegment)
    func setTransportMode(_ mode: TransportMode, for move: MoveSegment)
    func requestSplitMove(_ move: MoveSegment)
    func mergeWithPreviousMove(_ move: MoveSegment)
    func mergeWithNextMove(_ move: MoveSegment)
    func requestDeleteMove(_ move: MoveSegment)
}

extension EnvironmentValues {
    @Entry var timelineItemActions: (any TimelineItemActions)? = nil
    @Entry var timelineEditController: TimelineEditController? = nil
}

extension View {
    /// WS1: apply to a place `StorylineRow` (works in a `List`).
    func timelinePlaceActions(_ visit: VisitPlace) -> some View {
        modifier(TimelinePlaceActionsModifier(visit: visit))
    }

    /// WS1: apply to a move `StorylineRow` (works in a `List`).
    func timelineMoveActions(_ move: MoveSegment) -> some View {
        modifier(TimelineMoveActionsModifier(move: move))
    }
}

private struct TimelinePlaceActionsModifier: ViewModifier {
    let visit: VisitPlace
    @Environment(\.timelineItemActions) private var actions

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let actions {
                    Button(String(localized: "Rename")) {
                        actions.requestRename(visit)
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let actions {
                    Button(String(localized: "Delete"), role: .destructive) {
                        actions.requestDeletePlace(visit)
                    }
                }
            }
            .contextMenu {
                if let actions {
                    TimelinePlaceContextMenu(visit: visit, actions: actions)
                }
            }
    }
}

private struct TimelineMoveActionsModifier: ViewModifier {
    let move: MoveSegment
    @Environment(\.timelineItemActions) private var actions

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let actions {
                    Button(String(localized: "Mode")) {
                        actions.requestChangeMode(move)
                    }
                    .tint(.indigo)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let actions {
                    Button(String(localized: "Delete"), role: .destructive) {
                        actions.requestDeleteMove(move)
                    }
                }
            }
            .contextMenu {
                if let actions {
                    TimelineMoveContextMenu(move: move, actions: actions)
                }
            }
    }
}

/// Context menu for a place row. WS1 can also embed this directly.
struct TimelinePlaceContextMenu: View {
    let visit: VisitPlace
    let actions: any TimelineItemActions

    var body: some View {
        Button(String(localized: "Rename…"), systemImage: "pencil") {
            actions.requestRename(visit)
        }
        Button(String(localized: "Pick nearby place…"), systemImage: "mappin.and.ellipse") {
            actions.requestPickNearby(visit)
        }
        Button(String(localized: "Not a stop"), systemImage: "arrow.triangle.merge") {
            actions.markNotAStop(visit)
        }
        if TimelineNeighbors.previousVisit(for: visit) != nil {
            Button(String(localized: "Merge with previous"), systemImage: "arrow.left.to.line") {
                actions.mergeWithPreviousPlace(visit)
            }
        }
        if TimelineNeighbors.nextVisit(for: visit) != nil {
            Button(String(localized: "Merge with next"), systemImage: "arrow.right.to.line") {
                actions.mergeWithNextPlace(visit)
            }
        }
        Button(String(localized: "Split…"), systemImage: "scissors") {
            actions.requestSplitVisit(visit)
        }
        Button(String(localized: "Edit times…"), systemImage: "clock") {
            actions.requestEditTimes(visit)
        }
        Divider()
        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
            actions.requestDeletePlace(visit)
        }
    }
}

/// Context menu for a move row. Path is WS4 and is omitted.
struct TimelineMoveContextMenu: View {
    let move: MoveSegment
    let actions: any TimelineItemActions

    var body: some View {
        Menu(String(localized: "Change mode"), systemImage: "figure.walk") {
            ForEach(TransportMode.correctionChoices, id: \.self) { mode in
                Button {
                    actions.setTransportMode(mode, for: move)
                } label: {
                    Label(mode.title, systemImage: mode.symbolName)
                }
            }
        }
        Button(String(localized: "Split here…"), systemImage: "scissors") {
            actions.requestSplitMove(move)
        }
        if TimelineNeighbors.previousMove(for: move) != nil {
            Button(String(localized: "Merge with previous"), systemImage: "arrow.left.to.line") {
                actions.mergeWithPreviousMove(move)
            }
        }
        if TimelineNeighbors.nextMove(for: move) != nil {
            Button(String(localized: "Merge with next"), systemImage: "arrow.right.to.line") {
                actions.mergeWithNextMove(move)
            }
        }
        Divider()
        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
            actions.requestDeleteMove(move)
        }
    }
}

extension TransportMode {
    /// The modes a person can pick when correcting a move, in menu order.
    static let correctionChoices: [TransportMode] = [
        .walking, .running, .cycling, .automotive, .train, .plane, .boat, .swimming, .unknown,
    ]
}

/// The mode shown on a move row. Tapping it opens the list of modes, so a wrong
/// guess is fixed from the row itself.
struct TransportModeMenu: View {
    let move: MoveSegment
    let actions: any TimelineItemActions

    private var selection: Binding<TransportMode> {
        Binding(
            get: { move.transportMode },
            set: { mode in
                guard mode != move.transportMode else { return }
                actions.setTransportMode(mode, for: move)
            }
        )
    }

    var body: some View {
        let tint = MovesPalette.transport(move.transportMode)

        Menu {
            Picker(String(localized: "Mode"), selection: selection) {
                ForEach(TransportMode.correctionChoices, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(move.transportMode.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            // A taller touch target that doesn't change the row's height.
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
    }
}
