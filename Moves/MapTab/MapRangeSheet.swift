import SwiftUI

/// Presets plus custom start/end pickers for the Map tab range.
struct MapRangeSheet: View {
    @Binding var selection: MapRangeSelection
    var now: Date = .now
    var calendar: Calendar = .autoupdatingCurrent
    var onDismiss: () -> Void

    @State private var customStart: Date
    @State private var customEnd: Date

    init(
        selection: Binding<MapRangeSelection>,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        onDismiss: @escaping () -> Void
    ) {
        _selection = selection
        self.now = now
        self.calendar = calendar
        self.onDismiss = onDismiss
        _customStart = State(initialValue: selection.wrappedValue.focus.start)
        _customEnd = State(initialValue: selection.wrappedValue.focus.end.addingTimeInterval(-1))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Presets")) {
                    ForEach(MapRangePreset.allCases) { preset in
                        Button {
                            selection = .preset(preset, now: now, calendar: calendar)
                            onDismiss()
                        } label: {
                            HStack {
                                Text(preset.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection.matchingPreset(now: now, calendar: calendar) == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(MovesPalette.routeTracking)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }

                Section(String(localized: "Custom")) {
                    DatePicker(
                        String(localized: "Start"),
                        selection: $customStart,
                        in: ...now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        String(localized: "End"),
                        selection: $customEnd,
                        in: customStart...now.addingTimeInterval(60),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Button(String(localized: "Apply")) {
                        let end = customEnd > customStart ? customEnd : customStart.addingTimeInterval(3_600)
                        selection = .custom(start: customStart, end: end, calendar: calendar)
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle(String(localized: "Map range"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
