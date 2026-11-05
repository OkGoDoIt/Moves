import SwiftUI

/// Presets plus custom start/end pickers for the Map tab range.
struct MapRangeSheet: View {
    @Binding var selection: MapRangeSelection
    var now: Date = .now
    var calendar: Calendar = .autoupdatingCurrent
    var firstRecorded: Date? = nil
    var onDismiss: () -> Void

    @State private var customStart: Date
    @State private var customEnd: Date

    init(
        selection: Binding<MapRangeSelection>,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        firstRecorded: Date? = nil,
        onDismiss: @escaping () -> Void
    ) {
        _selection = selection
        self.now = now
        self.calendar = calendar
        self.firstRecorded = firstRecorded
        self.onDismiss = onDismiss
        let pickerDates = selection.wrappedValue.customPickerDates(now: now)
        _customStart = State(initialValue: pickerDates.start)
        _customEnd = State(initialValue: pickerDates.end)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Presets")) {
                    ForEach(MapRangePreset.allCases) { preset in
                        Button {
                            selection = .preset(preset, now: now, calendar: calendar, firstRecorded: firstRecorded)
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
                        in: MapRangeSelection.customEndRange(start: customStart, now: now),
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
