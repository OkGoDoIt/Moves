import CoreLocation
import SwiftUI

/// The row of nearby names under a stay's Name field, ending in a More chip that opens
/// Choose a Place. Shows the default guesses, or the matches for `model.fieldQuery`.
///
/// It starts at the content margin and scrolls under a soft fade at whichever edge has
/// more chips. A tap hands the pick to the caller; nothing here writes to the store.
struct PlaceNamingChipRow: View {
    @Environment(\.modelContext) private var modelContext

    let model: PlaceNamingModel
    let coordinate: CLLocationCoordinate2D
    var accuracy: CLLocationDistance
    var selectedID: String?
    var onPick: (NearbyPlaceCandidate) -> Void
    /// Called with the text from Choose a Place's "Use …" row.
    var onUseTyped: (String) -> Void

    @State private var isChoosing = false
    @State private var edges = FadeEdges()

    init(
        model: PlaceNamingModel,
        coordinate: CLLocationCoordinate2D,
        accuracy: CLLocationDistance,
        selectedID: String? = nil,
        onPick: @escaping (NearbyPlaceCandidate) -> Void,
        onUseTyped: @escaping (String) -> Void
    ) {
        self.model = model
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.selectedID = selectedID
        self.onPick = onPick
        self.onUseTyped = onUseTyped
    }

    var body: some View {
        Group {
            if model.chips.isEmpty && model.isLoadingNearby && model.fieldQuery.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                chipScroller
            }
        }
        .task(id: locationKey) {
            await model.prepare(near: coordinate, accuracy: accuracy, modelContext: modelContext)
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $isChoosing) {
            PlaceChoiceSheet(model: model, onPick: onPick, onUseTyped: onUseTyped)
        }
    }

    private var chipScroller: some View {
        ScrollViewReader { proxy in
            chipStrip
                // New matches start from the first chip, never mid-row.
                .onChange(of: model.chips.map(\.id)) { _, _ in
                    proxy.scrollTo(Self.leadingAnchor, anchor: .leading)
                }
        }
    }

    private static let leadingAnchor = "place-naming-chips-start"

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.chips) { chip in
                    PlaceChip(
                        title: chip.name,
                        systemImage: nil,
                        isSelected: selectedID == chip.id
                    ) {
                        onPick(chip)
                    }
                    .accessibilityHint(String(localized: "Names this place"))
                }
                PlaceChip(title: String(localized: "More"), systemImage: "ellipsis", isSelected: false) {
                    isChoosing = true
                }
                .accessibilityLabel(String(localized: "More places"))
                .accessibilityHint(String(localized: "Lists and searches places nearby"))
            }
            .id(Self.leadingAnchor)
        }
        .onScrollGeometryChange(for: FadeEdges.self) { geometry in
            FadeEdges(
                leading: geometry.contentOffset.x > 1,
                trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
            )
        } action: { _, new in
            edges = new
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: edges.leading ? 20 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: edges.trailing ? 28 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: edges)
    }

    private var locationKey: String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }

    private struct FadeEdges: Equatable {
        var leading = false
        var trailing = false
    }
}

/// Choose a Place: everything nearby, the person's own places first, with search.
struct PlaceChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: PlaceNamingModel
    var onPick: (NearbyPlaceCandidate) -> Void
    var onUseTyped: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                PlaceChoiceSections(
                    model: model,
                    query: model.sheetQuery,
                    showsUseTyped: true,
                    onPick: { candidate in
                        onPick(candidate)
                        dismiss()
                    },
                    onUseTyped: { text in
                        onUseTyped(text)
                        dismiss()
                    }
                )
            }
            .searchable(
                text: $model.sheetQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Search places")
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: "Choose a Place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { model.sheetQuery = model.fieldQuery }
    }
}

/// The list body shared by Choose a Place and the rename sheet.
struct PlaceChoiceSections: View {
    let model: PlaceNamingModel
    let query: String
    var showsUseTyped: Bool
    var onPick: (NearbyPlaceCandidate) -> Void
    var onUseTyped: (String) -> Void = { _ in }

    var body: some View {
        let listing = model.listing(for: query)
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = model.isSearching(query)

        if showsUseTyped, !typed.isEmpty {
            Section {
                Button {
                    onUseTyped(typed)
                } label: {
                    HStack(spacing: 12) {
                        PlaceNamingGlyph(systemName: "character.cursor.ibeam")
                        Text(String(localized: "Use “\(typed)”"))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(MovesPalette.place)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        if !listing.known.isEmpty {
            Section(String(localized: "Your places")) {
                ForEach(listing.known) { candidate in
                    row(candidate)
                }
            }
        }

        if !listing.places.isEmpty {
            Section {
                ForEach(listing.places) { candidate in
                    row(candidate)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(typed.isEmpty ? String(localized: "Nearby") : String(localized: "Places"))
                    if searching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
        }

        if listing.isEmpty {
            Section {
                if searching || (model.isLoadingNearby && typed.isEmpty) || model.coordinate == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if typed.isEmpty {
                    Text(String(localized: "No places nearby yet."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "No places match “\(typed)”."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ candidate: NearbyPlaceCandidate) -> some View {
        Button {
            onPick(candidate)
        } label: {
            PlaceChoiceRow(candidate: candidate)
        }
    }
}

/// One place in the list: glyph, name (wrapping, never cut short), address, distance.
struct PlaceChoiceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let candidate: NearbyPlaceCandidate

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PlaceNamingGlyph(systemName: PlaceNamingRanking.symbolName(for: candidate))
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    names
                    distance
                }
                Spacer(minLength: 0)
            } else {
                names
                Spacer(minLength: 8)
                distance
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.name)
                .font(.system(.body, design: .rounded).weight(.medium))
                // Explicit colors: inside a list button, `.primary` would resolve to the tint.
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = candidate.subtitle {
                Text(subtitle)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var distance: some View {
        Text(PlaceNamingRanking.distanceText(candidate.distanceMeters))
            .font(.system(.footnote, design: .rounded).weight(.medium).monospacedDigit())
            .foregroundStyle(Color.secondary)
    }
}

/// The category tile used in place lists, matching `PlacesCategoryGlyph`.
struct PlaceNamingGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(MovesPalette.place)
            .frame(width: 36, height: 36)
            .background(
                MovesPalette.place.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
