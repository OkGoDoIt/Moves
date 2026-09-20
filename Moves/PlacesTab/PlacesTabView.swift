import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Places tab: learned places grouped by country → city, plus unassigned suggestions.
struct PlacesTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var rootController: MovesRootController

    @Query(sort: \KnownPlace.name)
    private var knownPlaces: [KnownPlace]

    @Query(sort: \VisitPlace.arrivalDate, order: .reverse)
    private var visits: [VisitPlace]

    @State private var index = PlacesIndex()
    @State private var path = NavigationPath()
    @State private var didOpenLaunchPlace = false
    @State private var clusterToConfirm: PlacesSuggestedCluster?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if index.snapshot.isEmpty {
                    emptyState
                } else {
                    placesList
                }
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(String(localized: "Places"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $index.query, prompt: String(localized: "Name, city, or country"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .navigationDestination(for: PlacesRoute.self) { route in
                switch route {
                case .known(let id):
                    PlaceDetailView(placeID: id)
                case .suggested(let clusterID):
                    if let cluster = index.snapshot.suggestedCluster(id: clusterID) {
                        SuggestedPlaceDetailView(cluster: cluster) { placeID in
                            path.removeLast()
                            path.append(PlacesRoute.known(placeID))
                        }
                    }
                }
            }
        }
        .sheet(item: $clusterToConfirm) { cluster in
            PlaceConfirmSheet(cluster: cluster) { place in
                path.append(PlacesRoute.known(place.id))
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: dataSignature) { _, _ in rebuild() }
        .onChange(of: index.sort) { _, _ in rebuild() }
        .onChange(of: index.query) { _, _ in rebuild() }
        .onChange(of: index.snapshot.placeCount) { _, _ in
            openFirstPlaceIfRequested()
        }
        .onChange(of: index.snapshot.suggested.count) { _, _ in
            openConfirmIfRequested()
        }
        .onChange(of: rootController.requestedKnownPlaceID) { _, placeID in
            guard let placeID else { return }
            path.append(PlacesRoute.known(placeID))
            rootController.requestedKnownPlaceID = nil
        }
        .task {
            await clusterLabeledVisitsAfterSeed()
            await PlaceGeocodeBackfill.runForegroundTrickle(in: modelContext.container)
        }
    }

    /// Reloads grouping when places, assignments, or geocoded country/city change.
    private var dataSignature: String {
        let known = knownPlaces.map {
            "\($0.id.uuidString):\($0.name):\($0.countryCode ?? ""):\($0.locality ?? ""):\($0.confirmedVisitCount):\($0.footprintRadius)"
        }
        let assigned = visits.prefix(400).map {
            "\($0.id.uuidString):\($0.knownPlace?.id.uuidString ?? ""):\($0.autoLabel ?? ""):\($0.thoroughfare ?? ""):\($0.formattedAddress ?? ""):\($0.countryCode ?? ""):\($0.locality ?? "")"
        }
        return (known + assigned).joined(separator: ",")
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort"), selection: $index.sort) {
                ForEach(PlacesSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(String(localized: "Sort places"))
    }

    private var placesList: some View {
        List {
            if !index.snapshot.suggested.isEmpty {
                Section {
                    ForEach(index.snapshot.suggested) { cluster in
                        HStack(spacing: 8) {
                            NavigationLink(value: PlacesRoute.suggested(cluster.id)) {
                                SuggestedPlaceRow(cluster: cluster)
                            }
                            Button(String(localized: "Confirm")) {
                                clusterToConfirm = cluster
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Confirm \(cluster.name)"))
                        }
                    }
                } header: {
                    PlacesSectionHeader(
                        title: String(localized: "Suggested"),
                        subtitle: String(localized: "Places you go that aren’t confirmed yet")
                    )
                }
            }

            ForEach(index.snapshot.countries) { country in
                ForEach(country.cities) { city in
                    Section {
                        ForEach(city.places) { place in
                            NavigationLink(value: PlacesRoute.known(place.id)) {
                                KnownPlaceRow(place: place)
                            }
                            .contextMenu {
                                Button(String(localized: "Rename"), systemImage: "pencil") {
                                    path.append(PlacesRoute.known(place.id))
                                }
                            }
                        }
                    } header: {
                        PlacesSectionHeader(
                            title: city.cityName,
                            subtitle: countryTitle(country),
                            flagEmoji: country.flagEmoji
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .movesFloatingTabBarClearance()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Places you actually go"), systemImage: "mappin.and.ellipse")
        } description: {
            Text(String(localized: "Home, work, and the café downstairs will be grouped by country and city after you confirm a visit."))
        }
        .padding(.horizontal, 24)
    }

    private func countryTitle(_ country: PlacesCountrySection) -> String {
        if country.flagEmoji.isEmpty {
            return country.countryName
        }
        return "\(country.flagEmoji)  \(country.countryName)"
    }

    private func rebuild() {
        index.ingest(
            knownPlaces: knownPlaces,
            visits: visits,
            userCoordinate: CLLocationManager().location?.coordinate
        )
    }

    /// Simulator seed and `runIfNeeded` race: labeled visits can land after the
    /// one-shot upgrader has already marked itself done. Wait for rows, then
    /// cluster — `upgrade(in:)` is idempotent.
    private func clusterLabeledVisitsAfterSeed() async {
        for _ in 0..<80 {
            let visitCount = (try? modelContext.fetchCount(FetchDescriptor<VisitPlace>())) ?? 0
            if visitCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? TimelineSchemaUpgrader.upgrade(in: modelContext)
    }

    /// Screenshot-agent flag `MOVES_OPEN_CONFIRM=1` presents the confirm sheet.
    private func openConfirmIfRequested() {
        guard ProcessInfo.processInfo.environment["MOVES_OPEN_CONFIRM"] == "1" else { return }
        guard clusterToConfirm == nil, let first = index.snapshot.suggested.first else { return }
        clusterToConfirm = first
    }
    /// Screenshot-agent flag `MOVES_OPEN_FIRST_PLACE=1` opens the first learned place.
    private func openFirstPlaceIfRequested() {
        guard !didOpenLaunchPlace else { return }
        guard ProcessInfo.processInfo.environment["MOVES_OPEN_FIRST_PLACE"] == "1" else { return }
        guard path.isEmpty, let first = index.snapshot.countries.first?.cities.first?.places.first else { return }
        didOpenLaunchPlace = true
        path.append(PlacesRoute.known(first.id))
    }
}

enum PlacesRoute: Hashable {
    case known(UUID)
    case suggested(String)
}

private struct PlacesSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var flagEmoji: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if !flagEmoji.isEmpty {
                    Text(flagEmoji)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .padding(.bottom, 4)
    }
}

private struct KnownPlaceRow: View {
    let place: PlacesPlaceSummary

    var body: some View {
        HStack(spacing: 12) {
            PlacesCategoryGlyph(category: place.category)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name.isEmpty ? String(localized: "Untitled place") : place.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(place.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(place.name), \(place.subtitle)")
    }
}

private struct SuggestedPlaceRow: View {
    let cluster: PlacesSuggestedCluster

    var body: some View {
        HStack(spacing: 12) {
            if cluster.showsMapThumbnail {
                SuggestedPlaceMapThumb(coordinate: cluster.coordinate)
            } else {
                PlacesCategoryGlyph(category: nil, suggested: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(cluster.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.name), \(cluster.subtitle)")
    }
}

private struct SuggestedPlaceMapThumb: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .region(
            MKCoordinateRegion(center: coordinate, latitudinalMeters: 220, longitudinalMeters: 220)
        )) {
            Marker("", coordinate: coordinate)
                .tint(MovesPalette.place)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .disabled(true)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PlacesCategoryGlyph: View {
    var category: KnownPlaceCategory?
    var suggested: Bool = false

    var body: some View {
        Image(systemName: suggested ? "sparkle.magnifyingglass" : (category?.symbolName ?? "mappin.and.ellipse"))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(suggested ? Color.accentColor : MovesPalette.place)
            .frame(width: 36, height: 36)
            .background(
                (suggested ? Color.accentColor : MovesPalette.place).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
