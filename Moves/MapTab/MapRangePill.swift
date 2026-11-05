import SwiftUI

/// Glass range control: title plus chevrons that step the current grain.
///
/// The title tap still chooses a range. The menu (long-press / indicator)
/// saves the current range as a trip or opens the trip list.
struct MapRangePill: View {
    let selection: MapRangeSelection
    let now: Date
    let calendar: Calendar
    let onStep: (Int) -> Void
    let onOpenSheet: () -> Void
    var onSaveAsTrip: (() -> Void)? = nil
    var onOpenTrips: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            chevron(delta: -1, systemImage: "chevron.left", label: String(localized: "Previous range"))
            rangeTitle
            chevron(delta: 1, systemImage: "chevron.right", label: String(localized: "Next range"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private var rangeTitle: some View {
        if onSaveAsTrip != nil || onOpenTrips != nil {
            Menu {
                Button(String(localized: "Save as trip…"), systemImage: "suitcase") {
                    onSaveAsTrip?()
                }
                Button(String(localized: "Trips"), systemImage: "suitcase.fill") {
                    onOpenTrips?()
                }
            } label: {
                titleLabel
            } primaryAction: {
                onOpenSheet()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Map range"))
            .accessibilityValue(selection.title(now: now, calendar: calendar))
            .accessibilityHint(String(localized: "Choose a day, week, month, or year. Menu saves the range as a trip."))
        } else {
            Button(action: onOpenSheet) {
                titleLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Map range"))
            .accessibilityValue(selection.title(now: now, calendar: calendar))
            .accessibilityHint(String(localized: "Choose a day, week, month, or year"))
        }
    }

    private var titleLabel: some View {
        Text(selection.title(now: now, calendar: calendar))
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .frame(minWidth: 88)
    }

    private func chevron(delta: Int, systemImage: String, label: String) -> some View {
        let enabled = selection.canStep(by: delta, now: now, calendar: calendar)
        return Button {
            onStep(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
