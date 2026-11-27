import Combine
import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Places tab: learned places grouped by country → city, plus unassigned suggestions.
struct PlacesTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var rootController: MovesRootController

    @State private var index = PlacesIndex()
    /// One for the tab's life: only its last known fix is read, for distances.
    @State private var locationManager = CLLocationManager()
    @State private var path = NavigationPath()
    @State private var didOpenLaunchPlace = false
    @State private var clusterToConfirm: PlacesSuggestedCluster?

    #if targetEnvironment(simulator)
    /// The demo seed lands once per launch, while this tab appears many times.
    @MainActor private static var didClusterSeededVisits = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !index.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if index.snapshot.isEmpty && index.query.isEmpty {
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
                case .suggested(let cluster):
                    // The route carries the cluster, so a rebuild cannot blank this page mid-edit.
                    SuggestedPlaceDetailView(cluster: cluster) { placeID in
                        path.removeLast()
                        path.append(PlacesRoute.known(placeID))
                    }
                case .allSuggested:
                    AllSuggestedPlacesView(clusters: index.snapshot.suggested)
                }
            }
        }
        .sheet(item: $clusterToConfirm) { cluster in
            PlaceConfirmSheet(cluster: cluster) { place in
                path.append(PlacesRoute.known(place.id))
            }
        }
        .onAppear {
            rebuild()
            openRequestedPlace()
        }
        .onReceive(placeChanges) { _ in rebuild() }
        .onChange(of: index.sort) { _, _ in index.refilter() }
        .onChange(of: index.query) { _, _ in index.refilter() }
        .onChange(of: index.snapshot.placeCount) { _, _ in
            openFirstPlaceIfRequested()
        }
        .onChange(of: index.snapshot.suggested.count) { _, _ in
            openConfirmIfRequested()
        }
        .onChange(of: rootController.requestedKnownPlaceID) { _, _ in
            openRequestedPlace()
        }
        .task {
            await clusterLabeledVisitsAfterSeed()
            await PlaceGeocodeBackfill.runForegroundTrickle(in: modelContext.container)
        }
    }

    /// A save that touched places or stays, on any context, read after it committed. The
    /// first one shows at once (a rename coming back from a place page); after it, the
    /// stay rebuild and the name backfill reload the tab at most every few seconds.
    private var placeChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter(PlaceSaveFilter.touchesPlaces)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange))
            .throttle(for: .seconds(3), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
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
                    ForEach(visibleSuggestions) { cluster in
                        NavigationLink(value: PlacesRoute.suggested(cluster)) {
                            SuggestedPlaceRow(cluster: cluster)
                        }
                    }
                    if hiddenSuggestionCount > 0 {
                        NavigationLink(value: PlacesRoute.allSuggested) {
                            Text(String(localized: "Show all \(index.snapshot.suggested.count)"))
                                .font(.system(.body, design: .rounded).weight(.medium))
                        }
                    }
                } header: {
                    PlacesSectionHeader(title: String(localized: "To name"))
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
                            subtitle: country.countryName,
                            flagEmoji: country.flagEmoji
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .movesFloatingTabBarClearance()
        .overlay {
            if index.snapshot.isEmpty, !index.query.isEmpty {
                ContentUnavailableView.search(text: index.query)
            }
        }
    }

    /// The few places most worth naming; a search shows every match.
    private static let suggestionPreviewCount = 5

    private var visibleSuggestions: [PlacesSuggestedCluster] {
        let all = index.snapshot.suggested
        guard index.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return all }
        return Array(all.prefix(Self.suggestionPreviewCount))
    }

    private var hiddenSuggestionCount: Int {
        index.snapshot.suggested.count - visibleSuggestions.count
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No places yet"), systemImage: "mappin.and.ellipse")
        } description: {
            Text(String(localized: "Places where you stay a while will show up here."))
        }
        .padding(.horizontal, 24)
    }

    private func rebuild() {
        index.reload(container: modelContext.container, userCoordinate: locationManager.location?.coordinate)
    }

    /// A deep link or search result can name a place before this tab has ever appeared,
    /// when `onChange` has nothing to compare against. Clearing the ID lets a repeat fire.
    private func openRequestedPlace() {
        guard let placeID = rootController.requestedKnownPlaceID else { return }
        rootController.requestedKnownPlaceID = nil
        path.append(PlacesRoute.known(placeID))
    }

    /// Simulator seed and `runIfNeeded` race: labeled visits can land after the
    /// one-shot upgrader has already marked itself done. Wait for rows, then
    /// cluster once. Never runs on a real store: the upgrade rewrites route policies,
    /// recreates deleted places from visit labels, and repairs duplicate stops.
    private func clusterLabeledVisitsAfterSeed() async {
        #if targetEnvironment(simulator)
        // A copy of a real store opened for a look is real history, not the demo seed.
        guard ProcessInfo.processInfo.environment["MOVES_SIMULATOR_STORE"] == nil else { return }
        guard !Self.didClusterSeededVisits else { return }
        Self.didClusterSeededVisits = true
        for _ in 0..<80 {
            let visitCount = (try? modelContext.fetchCount(FetchDescriptor<VisitPlace>.live())) ?? 0
            if visitCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await TimelineSchemaUpgrader.waitUntilFinished()
        try? TimelineSchemaUpgrader.upgrade(in: modelContext)
        #endif
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
    case suggested(PlacesSuggestedCluster)
    case allSuggested
}

/// Every place still to name, longest stays first.
private struct AllSuggestedPlacesView: View {
    let clusters: [PlacesSuggestedCluster]

    var body: some View {
        List(clusters) { cluster in
            NavigationLink(value: PlacesRoute.suggested(cluster)) {
                SuggestedPlaceRow(cluster: cluster)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .movesFloatingTabBarClearance()
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(String(localized: "To name"))
        .navigationBarTitleDisplayMode(.inline)
    }
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
        PlacesListRow(
            glyph: PlacesCategoryGlyph(category: place.category),
            title: place.name.isEmpty ? String(localized: "Untitled place") : place.name,
            subtitle: place.subtitle
        )
    }
}

private struct SuggestedPlaceRow: View {
    let cluster: PlacesSuggestedCluster

    var body: some View {
        PlacesListRow(
            glyph: PlacesCategoryGlyph(category: nil, suggested: true),
            title: cluster.name,
            subtitle: cluster.subtitle
        )
    }
}

/// Glyph, name, and one secondary line. At accessibility sizes the glyph steps aside
/// so names keep their width instead of breaking mid-word.
private struct PlacesListRow: View {
    let glyph: PlacesCategoryGlyph
    let title: String
    let subtitle: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                glyph
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
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
