import SwiftData
import SwiftUI

/// Two time pickers clamped to neighbouring items.
struct EditTimesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let visit: VisitPlace
    let bounds: EditTimesBounds
    var editController: TimelineEditController

    @State private var arrival: Date
    @State private var departure: Date
    @State private var hasDeparture: Bool

    init(visit: VisitPlace, bounds: EditTimesBounds, editController: TimelineEditController) {
        self.visit = visit
        self.bounds = bounds
        self.editController = editController
        _arrival = State(initialValue: visit.arrivalDate)
        let initialDeparture = visit.departureDate ?? visit.outgoingMoves.map(\.startDate).min() ?? visit.arrivalDate
        _departure = State(initialValue: initialDeparture)
        _hasDeparture = State(initialValue: visit.departureDate != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    String(localized: "Arrived"),
                    selection: $arrival,
                    in: arrivalRange,
                    displayedComponents: [.hourAndMinute, .date]
                )
                Toggle(String(localized: "Has a departure"), isOn: $hasDeparture)
                if hasDeparture {
                    DatePicker(
                        String(localized: "Left"),
                        selection: $departure,
                        in: departureRange,
                        displayedComponents: [.hourAndMinute, .date]
                    )
                }
                Text(String(localized: "Changing departure also starts the next move at that time."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(String(localized: "Edit times"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                }
            }
            .onChange(of: arrival) { _, newValue in
                if hasDeparture, departure < newValue {
                    departure = newValue.addingTimeInterval(60)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var arrivalRange: ClosedRange<Date> {
        let upper = hasDeparture ? min(departure, bounds.latestDeparture) : bounds.latestDeparture
        return bounds.earliestArrival...max(bounds.earliestArrival, upper)
    }

    private var departureRange: ClosedRange<Date> {
        let lower = max(arrival, bounds.earliestArrival)
        return lower...max(lower, bounds.latestDeparture)
    }

    private func save() {
        let clampedArrival = min(max(arrival, bounds.earliestArrival), bounds.latestDeparture)
        var clampedDeparture: Date? = nil
        if hasDeparture {
            clampedDeparture = min(max(departure, clampedArrival), bounds.latestDeparture)
        }
        editController.applyTimes(to: visit, arrival: clampedArrival, departure: clampedDeparture)
        dismiss()
    }
}
