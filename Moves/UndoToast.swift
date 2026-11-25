import SwiftData
import SwiftUI

/// Bottom-floating undo pill shown for a few seconds after a correction.
@MainActor
@Observable
final class UndoToastPresenter {
    private(set) var actionName: String?
    private(set) var isVisible = false

    var onUndo: (() -> Void)?

    @ObservationIgnored
    private var hideTask: Task<Void, Never>?

    /// Long enough to notice the change, read the pill, and reach it with a thumb; longer
    /// with VoiceOver, which has to reach the pill first.
    static var visibleDuration: Duration {
        #if DEBUG
        // Debug builds only: lets a slow test driver reach the pill (`MOVES_UNDO_PILL_SECONDS=30`).
        if let raw = ProcessInfo.processInfo.environment["MOVES_UNDO_PILL_SECONDS"], let seconds = Int(raw) {
            return .seconds(seconds)
        }
        #endif
        return UIAccessibility.isVoiceOverRunning ? .seconds(15) : .seconds(8)
    }

    /// Shows the pill and auto-hides it after `visibleDuration`.
    func show(actionName: String, onUndo: @escaping () -> Void) {
        hideTask?.cancel()
        self.actionName = actionName
        self.onUndo = onUndo
        isVisible = true
        let duration = Self.visibleDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func undo() {
        let action = onUndo
        dismiss()
        action?()
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
        onUndo = nil
        actionName = nil
    }
}

extension EnvironmentValues {
    @Entry var undoToastPresenter: UndoToastPresenter? = nil
}

/// One change a person made: one step on the Undo pill and on shake-to-undo.
///
/// The step owns its restore, so the pill undoes exactly the change it names. The view
/// context's undo manager also collects writes nobody asked to undo (a route rematch, a
/// geocode, a launch repair), and popping the top of that stack used to undo one of those
/// instead of the person's change.
@MainActor
final class AppUndoStep {
    let name: String
    private var restore: (() -> Void)?

    private init(name: String, restore: @escaping () -> Void) {
        self.name = name
        self.restore = restore
    }

    /// Whether the change is still waiting to be undone.
    var isPending: Bool { restore != nil }

    /// Registers `restore` on `manager` as a group of its own.
    @discardableResult
    static func register(named name: String, on manager: UndoManager?, restore: @escaping () -> Void) -> AppUndoStep {
        let step = AppUndoStep(name: name, restore: restore)
        guard let manager else { return step }
        manager.beginUndoGrouping()
        // The undo manager does not retain its targets; the handler holds the step instead,
        // or a step nobody else kept would be gone (and crash) by the time Undo runs.
        manager.registerUndo(withTarget: step) { [step] _ in step.undo() }
        manager.setActionName(name)
        manager.endUndoGrouping()
        return step
    }

    /// Puts the change back. Runs once; later calls do nothing.
    func undo() {
        guard let restore else { return }
        self.restore = nil
        restore()
    }

    /// From the Undo pill: undoes this step and takes it off the shared stack, wherever it
    /// sits there now.
    func undo(removingFrom manager: UndoManager?) {
        undo()
        manager?.removeAllActions(withTarget: self)
    }
}

/// Overlays the undo capsule above the tab bar.
struct UndoToastModifier: ViewModifier {
    var presenter: UndoToastPresenter
    /// Space kept free under the pill: the floating tab bar on the tab shell, a little
    /// breathing room in a sheet.
    var bottomClearance: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if presenter.isVisible, let actionName = presenter.actionName {
                Button {
                    presenter.undo()
                } label: {
                    HStack(spacing: 10) {
                        Text(actionName)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text(String(localized: "Undo"))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(actionName), Undo")
                .padding(.bottom, bottomClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28), value: presenter.isVisible)
    }
}

extension View {
    /// `bottomClearance`: `UndoToastPlacement.aboveTabBar` on the tab shell,
    /// `UndoToastPlacement.inSheet` in a sheet with no tab bar.
    func undoToast(_ presenter: UndoToastPresenter, bottomClearance: CGFloat = UndoToastPlacement.inSheet) -> some View {
        modifier(UndoToastModifier(presenter: presenter, bottomClearance: bottomClearance))
    }
}

enum UndoToastPlacement {
    /// Clears the floating tab bar, which the tab shell's bottom safe area does not include.
    static let aboveTabBar: CGFloat = 64
    static let inSheet: CGFloat = 12
}
