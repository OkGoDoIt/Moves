import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Rename a visit: typed name plus nearby learned places and Apple POIs.
///
/// A stay that still goes by its street address opens as "Name this place": the field
/// starts empty so the nearby list shows everything around, and one tap on a suggestion
/// names the stay.
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
    private let isNaming: Bool

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
        let isNaming = TimelinePlaceNaming.needsName(visit)
        self.isNaming = isNaming
        _draftName = State(initialValue: isNaming ? "" : (visit.userLabel ?? visit.knownPlace?.name ?? visit.autoLabel ?? ""))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(isNaming ? visit.displayTitle : String(localized: "Name"), text: $draftName)
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
            .navigationTitle(title)
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

    private var title: String {
        if isNaming { return String(localized: "Name this place") }
        return focusesNearby ? String(localized: "Nearby places") : String(localized: "Rename")
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
            Text(PlaceNamingSuggestions.distanceText(candidate.distanceMeters))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func saveTypedName() {
        editController.applyRename(to: visit, name: draftName)
        dismiss()
    }

    private func loadSuggestions() async {
        isSearching = true
        defer { isSearching = false }
        let query = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        await PlaceNamingSuggestions.load(
            for: visit,
            query: query.isEmpty ? nil : query,
            modelContext: modelContext,
            searcher: searcher
        ) { candidates = $0 }
    }
}

/// Nearby names for a stay as one row of chips. A tap names the stay straight away;
/// the Undo pill takes it back. Used at the top of a stay's detail screen.
struct PlaceNamingSuggestions: View {
    @Environment(\.modelContext) private var modelContext

    let visit: VisitPlace
    let onPick: (NearbyPlaceCandidate) -> Void
    var searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()

    @State private var candidates: [NearbyPlaceCandidate] = []
    @State private var isSearching = true

    var body: some View {
        Group {
            if candidates.isEmpty && isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 32)
            } else if candidates.isEmpty {
                Text(String(localized: "No nearby places yet."))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(candidates) { candidate in
                            Button {
                                onPick(candidate)
                            } label: {
                                Text(candidate.name)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(.primary)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.name)
                            .accessibilityHint(String(localized: "Names this place"))
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task(id: visit.id) {
            isSearching = true
            defer { isSearching = false }
            await Self.load(for: visit, query: nil, modelContext: modelContext, searcher: searcher) {
                candidates = $0
            }
        }
    }

    /// Learned places first (no network), then Apple's nearby places merged in.
    @MainActor
    static func load(
        for visit: VisitPlace,
        query: String?,
        modelContext: ModelContext,
        searcher: any LocalPlaceSearching,
        update: ([NearbyPlaceCandidate]) -> Void
    ) async {
        let coordinate = visit.coordinate
        let repository = SwiftDataTimelineRepository(modelContext: modelContext)
        let known = (try? repository.knownPlaces(
            near: coordinate,
            within: NearbyPlaceSuggester.searchRadius
        )) ?? []

        update(NearbyPlaceSuggester.merge(
            visitCoordinate: coordinate,
            knownPlaces: known,
            searchHits: [],
            query: query
        ))

        let suggester = NearbyPlaceSuggester(searcher: searcher)
        let merged = await suggester.suggestions(near: coordinate, knownPlaces: known, query: query)
        guard !Task.isCancelled else { return }
        update(merged)
    }

    static func distanceText(_ meters: CLLocationDistance) -> String {
        if meters < 10 {
            return String(localized: "Here")
        }
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
