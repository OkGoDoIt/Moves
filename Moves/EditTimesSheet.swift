import SwiftData
import SwiftUI

/// Decides whether a visit may be left without a departure.
enum EditTimesRules {
    /// When the next timeline item starts, or nil when nothing starts after `visit`.
    ///
    /// Only a visit with nothing after it could still be in progress.
    static func nextItemStart(after visit: VisitPlace, in context: ModelContext?) -> Date? {
        let outgoing = visit.outgoingMoves.map(\.startDate).min()
        guard let context else { return outgoing }

        let arrival = visit.arrivalDate
        var visits = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { $0.arrivalDate > arrival },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .forward)]
        )
        visits.fetchLimit = 1
        var moves = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { $0.startDate > arrival },
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
        )
        moves.fetchLimit = 1

        let nextVisit = (try? context.fetch(visits))?.first?.arrivalDate
        let nextMove = (try? context.fetch(moves))?.first?.startDate
        return [outgoing, nextVisit, nextMove].compactMap { $0 }.min()
    }
}

/// Two time pickers clamped to neighbouring items.
struct EditTimesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let visit: VisitPlace
    let bounds: EditTimesBounds
    var editController: TimelineEditController

    @State private var arrival: Date
    @State private var departure: Date
    @State private var hasDeparture: Bool
    @State private var canStayOpen: Bool

    init(visit: VisitPlace, bounds: EditTimesBounds, editController: TimelineEditController) {
        self.visit = visit
        self.bounds = bounds
        self.editController = editController
        _arrival = State(initialValue: visit.arrivalDate)
        let nextStart = EditTimesRules.nextItemStart(after: visit, in: visit.modelContext)
        _departure = State(initialValue: visit.departureDate ?? nextStart ?? visit.arrivalDate)
        _hasDeparture = State(initialValue: visit.departureDate != nil || nextStart != nil)
        _canStayOpen = State(initialValue: nextStart == nil)
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
                if canStayOpen {
                    Toggle(String(localized: "Has a departure"), isOn: $hasDeparture)
                }
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
