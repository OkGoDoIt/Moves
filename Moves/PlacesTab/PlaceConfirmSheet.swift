import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Confirm form for an unconfirmed cluster: map, name, one-tap labels, nearby suggestions.
///
/// The caller owns `name` so the navigation title always shows what the place will be called.
/// Used on the suggested detail page and in `PlaceConfirmSheet`.
struct PlaceConfirmForm: View {
    let cluster: PlacesSuggestedCluster
    @Binding var name: String
    var onConfirmed: (KnownPlace) -> Void
    var onNameFocusChange: (Bool) -> Void = { _ in }
    var searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoToastPresenter) private var undoToast

    @State private var address: String
    @State private var camera: MapCameraPosition
    @State private var namingModel: PlaceNamingModel
    @State private var chipCategories: [String: String] = [:]
    @State private var existingPlaceID: UUID?
    @State private var nameSource: NameSource = .guess
    @State private var guessedName: String
    @State private var extraCategories: [String] = []
    @State private var confirmCount = 0
    @FocusState private var isNameFocused: Bool

    /// Where the current name came from. Only a guess may be replaced without asking.
    private enum NameSource: Equatable {
        case guess
        case chip(String)
        case typed
    }

    init(
        cluster: PlacesSuggestedCluster,
        name: Binding<String>,
        onConfirmed: @escaping (KnownPlace) -> Void,
        onNameFocusChange: @escaping (Bool) -> Void = { _ in },
        searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()
    ) {
        self.cluster = cluster
        _name = name
        self.onConfirmed = onConfirmed
        self.onNameFocusChange = onNameFocusChange
        self.searcher = searcher
        _namingModel = State(initialValue: PlaceNamingModel(searcher: searcher))
        _guessedName = State(initialValue: name.wrappedValue)
        _address = State(initialValue: cluster.formattedAddress ?? cluster.address ?? "")
        let meters = max(cluster.spreadRadius * 6, 280)
        _camera = State(
            initialValue: .region(
                MKCoordinateRegion(center: cluster.coordinate, latitudinalMeters: meters, longitudinalMeters: meters)
            )
        )
    }

    /// Seeds the editable name for a cluster: its list title, or empty while still naming.
    static func initialName(for cluster: PlacesSuggestedCluster) -> String {
        cluster.isNaming ? "" : cluster.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            map
            nameField
            labelChips
            nearbyChips
            confirmButton
        }
        .sensoryFeedback(.success, trigger: confirmCount)
        .onChange(of: isNameFocused) { _, focused in onNameFocusChange(focused) }
        // Scroll again once the keyboard has taken its space, so Confirm lands above it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if isNameFocused { onNameFocusChange(true) }
        }
        .task {
            await refreshLookup()
        }
    }

    // MARK: Sections

    private var map: some View {
        Map(position: $camera) {
            MapCircle(center: cluster.coordinate, radius: cluster.spreadRadius)
                .foregroundStyle(MovesPalette.place.opacity(0.16))
                .stroke(MovesPalette.place.opacity(0.85), lineWidth: 2)
            Annotation(PlaceDisplayNamer.meaningful(name) ?? "", coordinate: cluster.coordinate, anchor: .center) {
                PlacesCategoryGlyph(category: selectedPreset)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(String(localized: "Map of this place"))
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Name"))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            // Wraps instead of cutting a long name off, at large text sizes especially.
            TextField(String(localized: "Name this place"), text: typedName, axis: .vertical)
                .lineLimit(1...4)
                // Without this the List row keeps the first line's height and a name that
                // already wraps when the form opens shows only its first line.
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(.body, design: .rounded))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isNameFocused)
                .onSubmit { isNameFocused = false }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MovesPalette.textFieldBackground.opacity(0.92))
                )
            if let line = addressLine {
                Text(line)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var labelChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "This is"))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labelOptions, id: \.self) { option in
                        PlaceChip(
                            title: option,
                            systemImage: KnownPlaceCategory(title: option)?.symbolName,
                            isSelected: false
                        ) {
                            confirm(label: option)
                        }
                        .accessibilityHint(String(localized: "Confirms this place"))
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var nearbyChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Nearby"))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            PlaceNamingChipRow(
                model: namingModel,
                coordinate: cluster.coordinate,
                accuracy: cluster.spreadRadius,
                selectedID: { if case .chip(let id) = nameSource { return id } else { return nil } }(),
                onPick: applyChip,
                onUseTyped: useTypedName
            )
        }
    }

    private var confirmButton: some View {
        Button {
            confirm(label: nil)
        } label: {
            Text(String(localized: "Confirm place"))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(MovesPalette.place)
        .disabled(!canConfirm)
    }

    // MARK: State

    /// The text field's binding: anything typed is the person's own name.
    private var typedName: Binding<String> {
        Binding(
            get: { name },
            set: { typed in
                // A name is one line: Return in the wrapping field ends editing.
                if typed.contains("\n") { isNameFocused = false }
                let newValue = typed.replacingOccurrences(of: "\n", with: "")
                guard newValue != name else { return }
                name = newValue
                nameSource = .typed
                existingPlaceID = nil
                namingModel.fieldQuery = newValue
            }
        )
    }

    /// The address under the name, without repeating the name itself.
    private var addressLine: String? {
        guard let full = PlacesIndexBuilder.consistentAddress(
            title: name,
            address: PlaceDisplayNamer.meaningful(address),
            locality: cluster.locality
        ) else { return nil }
        let typed = PlaceDisplayNamer.folded(name)
        let parts = full.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if PlaceDisplayNamer.folded(full) == typed { return nil }
        if let first = parts.first, PlaceDisplayNamer.folded(first) == typed {
            let rest = parts.dropFirst().joined(separator: ", ")
            return rest.isEmpty ? nil : rest
        }
        return full
    }

    private var canConfirm: Bool {
        PlaceDisplayNamer.meaningful(name) != nil
    }

    private var selectedPreset: KnownPlaceCategory? {
        KnownPlaceCategory(title: name)
    }

    private var labelOptions: [String] {
        let presets = [KnownPlaceCategory.home.title, KnownPlaceCategory.work.title, KnownPlaceCategory.gym.title]
        let extras = extraCategories.filter { extra in
            !presets.contains { $0.caseInsensitiveCompare(extra) == .orderedSame }
        }
        return presets + extras
    }

    private func applyChip(_ chip: NearbyPlaceCandidate) {
        name = chip.name
        nameSource = .chip(chip.id)
        isNameFocused = false
        if let subtitle = PlaceDisplayNamer.meaningful(chip.subtitle) {
            address = subtitle
        }
        if case .knownPlace(let id) = chip.source {
            existingPlaceID = id
        } else {
            existingPlaceID = nil
        }
    }

    /// "Use “…”" in Choose a Place: the text exactly as typed is the person's own name.
    private func useTypedName(_ text: String) {
        name = text
        nameSource = .typed
        existingPlaceID = nil
        isNameFocused = false
    }

    private func refreshLookup() async {
        let coordinate = cluster.coordinate
        let known = (try? SwiftDataTimelineRepository(modelContext: modelContext)
            .knownPlaces(near: coordinate, within: NearbyPlaceSuggester.listRadius)) ?? []
        // Copy what the chips need now; the rows may change while the lookups run.
        var categories: [String: String] = [:]
        var extras = Set<String>()
        for place in known {
            guard let raw = PlaceDisplayNamer.meaningful(place.category) else { continue }
            let title = KnownPlaceCategory(stored: raw)?.title ?? raw.capitalized
            categories[place.id.uuidString] = title
            if KnownPlaceCategory(stored: raw) == nil { extras.insert(title) }
        }
        chipCategories = categories
        extraCategories = extras.sorted()

        if let region = try? await MapKitPlaceReverseGeocoder().reverseGeocode(coordinate) {
            if let formatted = region.formattedAddress ?? region.thoroughfare,
               PlaceDisplayNamer.meaningful(address) == nil {
                address = formatted
            }
            if nameSource == .guess, PlaceDisplayNamer.meaningful(name) == nil, let best = region.bestPlaceName {
                name = best
                guessedName = best
            }
        }

        await namingModel.prepare(near: coordinate, accuracy: cluster.spreadRadius, modelContext: modelContext)
        guard !Task.isCancelled else { return }
        if nameSource == .guess, PlaceDisplayNamer.meaningful(name) == nil, let first = namingModel.defaultChips.first {
            applyChip(first)
            nameSource = .guess
            guessedName = first.name
        }
    }

    /// Confirms with the current name, or with a one-tap label such as Home.
    /// A label names the place only when the name is still a guess.
    private func confirm(label: String?) {
        var finalName = name
        var category: String?
        if let label {
            category = label
            if nameSource == .guess || PlaceDisplayNamer.meaningful(name) == nil {
                finalName = label
                existingPlaceID = nil
            }
        } else if case .chip(let id) = nameSource, let known = chipCategories[existingPlaceID?.uuidString ?? id] {
            category = known
        } else {
            category = KnownPlaceCategory(title: finalName)?.title
        }
        guard PlaceDisplayNamer.meaningful(finalName) != nil else { return }
        isNameFocused = false
        do {
            var step: AppUndoStep?
            let created = try PlacesLibrary.confirmSuggested(
                visitIDs: cluster.visitIDs,
                name: finalName,
                in: modelContext,
                formattedAddress: PlaceDisplayNamer.meaningful(address),
                thoroughfare: cluster.thoroughfare,
                category: category,
                existingPlaceID: existingPlaceID,
                undoStep: { step = $0 }
            )
            name = created.name
            confirmCount += 1
            let manager = modelContext.undoManager
            undoToast?.show(actionName: String(localized: "Confirmed \(created.name)")) {
                step?.undo(removingFrom: manager)
            }
            onConfirmed(created)
        } catch {}
    }
}

/// Capsule chip shared by the confirm form and place detail.
struct PlaceChip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                }
                Text(title)
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                }
            }
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? MovesPalette.place : Color.accentColor.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension KnownPlaceCategory {
    /// Matches a typed or chip title ("Home", "home") to a preset.
    init?(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = KnownPlaceCategory.allCases.first(where: {
            $0 != .other && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        self = match
    }
}

/// Modal wrapper around `PlaceConfirmForm`.
struct PlaceConfirmSheet: View {
    let cluster: PlacesSuggestedCluster
    var onConfirmed: (KnownPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(cluster: PlacesSuggestedCluster, onConfirmed: @escaping (KnownPlace) -> Void) {
        self.cluster = cluster
        self.onConfirmed = onConfirmed
        _name = State(initialValue: PlaceConfirmForm.initialName(for: cluster))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    PlaceConfirmForm(
                        cluster: cluster,
                        name: $name,
                        onConfirmed: { place in
                            onConfirmed(place)
                            dismiss()
                        },
                        onNameFocusChange: { focused in
                            guard focused else { return }
                            withAnimation { proxy.scrollTo(PlaceConfirmFormAnchor.id, anchor: .bottom) }
                        }
                    )
                    .padding(20)
                    .id(PlaceConfirmFormAnchor.id)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(PlaceDisplayNamer.meaningful(name) ?? String(localized: "New place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Scroll target that brings the whole form, through Confirm, above the keyboard.
enum PlaceConfirmFormAnchor {
    static let id = "place-confirm-form"
}
