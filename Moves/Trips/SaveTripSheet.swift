import SwiftData
import SwiftUI

/// Names a Map range and stores it as a `NamedTrip` lens — no timeline copy.
struct SaveTripSheet: View {
    let interval: DateInterval
    var onSaved: ((NamedTrip) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""
    @State private var didFillDefaultName = false

    private var calendar: Calendar { .autoupdatingCurrent }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Name"), text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel(String(localized: "Name"))
                }
                Section {
                    TextField(String(localized: "Notes"), text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(String(localized: "Notes"))
                } footer: {
                    Text(TripRangeStats.dateSpanTitle(for: interval, calendar: calendar))
                }
            }
            .navigationTitle(String(localized: "Save as trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        save()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear(perform: fillDefaultNameIfNeeded)
        }
        .presentationDetents([.medium, .large])
    }

    private func fillDefaultNameIfNeeded() {
        guard !didFillDefaultName else { return }
        didFillDefaultName = true
        let repository = SwiftDataTimelineRepository(modelContext: modelContext)
        let visits = (try? repository.visits(in: interval)) ?? []
        name = TripRangeStats.defaultName(visits: visits, interval: interval, calendar: calendar)
    }

    private func save() {
        let trip = NamedTrip(
            name: trimmedName,
            startDate: interval.start,
            endDate: interval.end,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.undoManager?.setActionName(String(localized: "Save trip"))
        modelContext.insert(trip)
        do {
            try modelContext.save()
            onSaved?(trip)
            dismiss()
        } catch {
            modelContext.delete(trip)
        }
    }
}
