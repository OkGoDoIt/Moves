import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Rename a visit: typed name plus nearby learned places and Apple POIs.
struct PlaceRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let visit: VisitPlace
    var focusesNearby: Bool
    var editController: TimelineEditController
    var searcher: any LocalPlaceSearching

    @State private var draftName: String
    @State private var candidates: [NearbyPlaceCandidate] = []
    @State private var isSearching = false

    init(
        visit: VisitPlace,
        focusesNearby: Bool = false,
        editController: TimelineEditController,
        searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()
    ) {
        self.visit = visit
        self.focusesNearby = focusesNearby
        self.editController = editController
        self.searcher = searcher
        _draftName = State(initialValue: visit.userLabel ?? visit.autoLabel ?? visit.knownPlace?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(String(localized: "Name"), text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveTypedName)
                }

                Section(String(localized: "Nearby")) {
                    if candidates.isEmpty && !isSearching {
                        Text(String(localized: "No nearby places yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        Button {
                            editController.applyCandidate(candidate, to: visit)
                            dismiss()
                        } label: {
                            candidateRow(candidate)
                        }
                    }
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(focusesNearby ? String(localized: "Nearby places") : String(localized: "Rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { saveTypedName() }
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task(id: suggestionKey) {
                await loadSuggestions()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var suggestionKey: String {
        "\(visit.id.uuidString)|\(draftName)"
    }

    @ViewBuilder
    private func candidateRow(_ candidate: NearbyPlaceCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .foregroundStyle(.primary)
                if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(distanceText(candidate.distanceMeters))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        if meters < 10 {
            return String(localized: "Here")
        }
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    private func saveTypedName() {
        editController.applyRename(to: visit, name: draftName)
        dismiss()
    }

    private func loadSuggestions() async {
        isSearching = true
        defer { isSearching = false }
        let repository = SwiftDataTimelineRepository(modelContext: modelContext)
        let known = (try? repository.knownPlaces(
            near: visit.coordinate,
            within: NearbyPlaceSuggester.searchRadius
        )) ?? []
        let query = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryOrNil = query.isEmpty ? nil : query

        candidates = NearbyPlaceSuggester.merge(
            visitCoordinate: visit.coordinate,
            knownPlaces: known,
            searchHits: [],
            query: queryOrNil
        )

        let suggester = NearbyPlaceSuggester(searcher: searcher)
        let merged = await suggester.suggestions(for: visit, knownPlaces: known, query: queryOrNil)
        guard !Task.isCancelled else { return }
        candidates = merged
    }
}
