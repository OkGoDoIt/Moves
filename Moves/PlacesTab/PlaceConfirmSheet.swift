import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Confirm form for an unconfirmed cluster: name, address, label, nearby POI chips.
///
/// Used as a sheet from the Places list and as the hero on the suggested detail page.
struct PlaceConfirmForm: View {
    let cluster: PlacesSuggestedCluster
    var onConfirmed: (KnownPlace) -> Void
    var showsConfirmButton: Bool = true
    var searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoToastPresenter) private var undoToast

    @State private var name: String
    @State private var address: String
    @State private var category: String
    @State private var camera: MapCameraPosition
    @State private var pinCoordinate: CLLocationCoordinate2D
    @State private var chips: [NearbyPlaceCandidate] = []
    @State private var existingPlaceID: UUID?
    @State private var nameTouched = false
    @State private var isGeocoding = false
    @State private var extraCategories: [String] = []

    init(
        cluster: PlacesSuggestedCluster,
        onConfirmed: @escaping (KnownPlace) -> Void,
        showsConfirmButton: Bool = true,
        searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()
    ) {
        self.cluster = cluster
        self.onConfirmed = onConfirmed
        self.showsConfirmButton = showsConfirmButton
        self.searcher = searcher
        let seedName = cluster.isNaming ? "" : cluster.name
        _name = State(initialValue: seedName)
        _address = State(initialValue: cluster.formattedAddress ?? cluster.address ?? cluster.thoroughfare ?? "")
        _category = State(initialValue: "")
        _pinCoordinate = State(initialValue: cluster.coordinate)
        _camera = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: cluster.coordinate,
                    latitudinalMeters: 280,
                    longitudinalMeters: 280
                )
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pinMap
            nameField
            nearbyChips
            addressField
            labelChips
            if showsConfirmButton {
                confirmButton
            }
        }
        .task {
            await refreshLookup()
        }
    }

    private var pinMap: some View {
        ZStack {
            Map(position: $camera)
                .mapStyle(.standard(elevation: .flat))
                .onMapCameraChange(frequency: .onEnd) { context in
                    handleCameraMove(context.region.center)
                }
            Image(systemName: "mappin")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(MovesPalette.place)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .offset(y: -14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(String(localized: "Map pin. Drag the map to set the address."))
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Name"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Name"), text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onChange(of: name) { _, _ in
                    nameTouched = true
                    existingPlaceID = nil
                }
        }
    }

    @ViewBuilder
    private var nearbyChips: some View {
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Nearby"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            Button {
                                applyChip(chip)
                            } label: {
                                Text(chip.name)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(.primary)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(name == chip.name ? 0.22 : 0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(chip.name)
                        }
                    }
                }
            }
        } else if isGeocoding {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Address"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Address"), text: $address, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.words)
        }
    }

    private var labelChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Label"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labelOptions, id: \.self) { option in
                        let selected = category.caseInsensitiveCompare(option) == .orderedSame
                        Button {
                            category = selected ? "" : option
                        } label: {
                            Text(option)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(
                                    Capsule().fill(selected ? MovesPalette.place : Color.accentColor.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField(String(localized: "Custom label"), text: $category)
                .textInputAutocapitalization(.words)
        }
    }

    private var confirmButton: some View {
        Button(action: confirm) {
            Text(String(localized: "Confirm place"))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(MovesPalette.place)
        .disabled(!canConfirm)
        .padding(.top, 4)
    }

    private var canConfirm: Bool {
        PlaceDisplayNamer.meaningful(name) != nil
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
        nameTouched = true
        if let subtitle = chip.subtitle, !subtitle.isEmpty {
            address = subtitle
        }
        if case .knownPlace(let id) = chip.source {
            existingPlaceID = id
        } else {
            existingPlaceID = nil
        }
    }

    private func handleCameraMove(_ center: CLLocationCoordinate2D) {
        let moved = CLLocation(latitude: pinCoordinate.latitude, longitude: pinCoordinate.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        guard moved > 8 else { return }
        pinCoordinate = center
        Task { await refreshLookup() }
    }

    private func refreshLookup() async {
        isGeocoding = true
        defer { isGeocoding = false }
        let known = (try? SwiftDataTimelineRepository(modelContext: modelContext)
            .knownPlaces(near: pinCoordinate, within: NearbyPlaceSuggester.searchRadius)) ?? []
        extraCategories = Array(
            Set(known.compactMap { place -> String? in
                guard let raw = place.category?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                return KnownPlaceCategory(stored: raw)?.title ?? raw.capitalized
            })
        ).sorted()

        if let region = try? await MapKitPlaceReverseGeocoder().reverseGeocode(pinCoordinate) {
            if !nameTouched, let best = region.bestPlaceName {
                name = best
            }
            if let formatted = region.formattedAddress ?? region.thoroughfare {
                address = formatted
            }
        }

        let suggester = NearbyPlaceSuggester(searcher: searcher)
        let merged = await suggester.suggestions(
            near: pinCoordinate,
            knownPlaces: known,
            query: nil,
            limit: 8
        )
        guard !Task.isCancelled else { return }
        chips = merged
        if !nameTouched, name.isEmpty, let first = merged.first {
            name = first.name
            if let subtitle = first.subtitle { address = subtitle }
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        do {
            let created = try PlacesLibrary.confirmSuggested(
                visitIDs: cluster.visitIDs,
                name: name,
                in: modelContext,
                formattedAddress: PlaceDisplayNamer.meaningful(address),
                thoroughfare: cluster.thoroughfare,
                category: PlaceDisplayNamer.meaningful(category),
                existingPlaceID: existingPlaceID,
                center: pinCoordinate
            )
            undoToast?.show(actionName: String(localized: "Confirmed")) {
                modelContext.undoManager?.undo()
            }
            onConfirmed(created)
        } catch {}
    }
}

/// Modal wrapper around `PlaceConfirmForm`.
struct PlaceConfirmSheet: View {
    let cluster: PlacesSuggestedCluster
    var onConfirmed: (KnownPlace) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PlaceConfirmForm(cluster: cluster) { place in
                    onConfirmed(place)
                    dismiss()
                }
                .padding(20)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(String(localized: "Confirm place"))
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
