import SwiftData
import SwiftUI

/// Bottom-floating undo pill shown for 5 seconds after a correction.
@MainActor
@Observable
final class UndoToastPresenter {
    private(set) var actionName: String?
    private(set) var isVisible = false

    var onUndo: (() -> Void)?

    @ObservationIgnored
    private var hideTask: Task<Void, Never>?

    /// Shows the pill and auto-hides it after five seconds.
    func show(actionName: String, onUndo: @escaping () -> Void) {
        hideTask?.cancel()
        self.actionName = actionName
        self.onUndo = onUndo
        isVisible = true
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
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

/// Overlays the undo capsule above the tab bar.
struct UndoToastModifier: ViewModifier {
    var presenter: UndoToastPresenter

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
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28), value: presenter.isVisible)
    }
}

extension View {
    func undoToast(_ presenter: UndoToastPresenter) -> some View {
        modifier(UndoToastModifier(presenter: presenter))
    }
}
