import SwiftUI

/// Countries and cities on one screen: the world on top, the list under it.
struct InsightsWorldView: View {
    enum Mode: Hashable {
        case countries
        case cities
    }

    let store: InsightsStore
    @State private var mode: Mode
    /// Only this continent, or the whole world.
    @State private var continent: WorldContinent?
    @State private var geometry: WorldMapGeometry?
    @State private var viewport = WorldMapGeometry.bounds
    @State private var selectedCountry: String?
    @State private var expandedCountries: Set<String> = []

    private static let collapsedCityCount = 6

    init(store: InsightsStore, mode: Mode) {
        self.store = store
        _mode = State(initialValue: mode)
    }

    private var geography: InsightsGeography { store.snapshot.geography }
    private var everywhere: InsightsGeography { store.snapshot.allTimeGeography }

    private var isZoomed: Bool { viewport.width < WorldMapGeometry.bounds.width * 0.98 }

    private var groups: [InsightsGeography.ContinentGroup] {
        geography.continents.filter { continent == nil || $0.continent == continent }
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height
            let layout = isWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 10) {
                    map
                    chips
                }
                .padding(.bottom, 8)
                .frame(width: isWide ? proxy.size.width * 0.5 : nil)
                list
            }
        }
        .background(MovesPalette.backgroundTop.ignoresSafeArea())
        .navigationTitle(mode == .countries ? String(localized: "Countries") : String(localized: "Cities"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            let loaded = await WorldMapGeometry.load()
            withAnimation(.easeOut(duration: 0.25)) { geometry = loaded }
        }
        .onChange(of: continent) { _, _ in focusMap() }
        .onChange(of: store.snapshot.period) { _, _ in
            selectedCountry = nil
            if let continent, !geography.continents.contains(where: { $0.continent == continent }) {
                self.continent = nil
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(String(localized: "Show"), selection: $mode) {
                Text(String(localized: "Countries")).tag(Mode.countries)
                Text(String(localized: "Cities")).tag(Mode.cities)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(String(localized: "Year"), selection: Binding(get: { store.period }, set: { store.period = $0 })) {
                    Text(InsightsPeriod.all.title).tag(InsightsPeriod.all)
                    ForEach(store.snapshot.availableYears.sorted(by: >), id: \.self) { year in
                        Text(String(year)).tag(InsightsPeriod.year(year))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.period.title)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .menuOrder(.fixed)
            .accessibilityLabel(String(localized: "Year"))
            .accessibilityValue(store.period.title)
        }
    }

    // MARK: - Map

    private var mapContent: WorldMapContent {
        let visited = geography.countryCodes
        return WorldMapContent(
            visited: visited,
            visitedBefore: everywhere.countryCodes.subtracting(visited),
            selected: selectedCountry,
            dots: mode == .cities ? InsightsWorldDots.dots(for: geography) : []
        )
    }

    private var map: some View {
        ZStack {
            Color.clear.aspectRatio(WorldMapGeometry.aspectRatio, contentMode: .fit)
            if let geometry {
                WorldMapView(geometry: geometry, content: mapContent, viewport: $viewport) { code in
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedCountry = code == selectedCountry ? nil : code
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let selectedCountry { callout(for: selectedCountry) } else { legend }
        }
        .overlay(alignment: .topTrailing) {
            if isZoomed, continent == nil {
                Button(String(localized: "Show the whole world"), systemImage: "arrow.down.right.and.arrow.up.left") {
                    withAnimation(.smooth(duration: 0.4)) { viewport = WorldMapGeometry.bounds }
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "World map"))
        .accessibilityValue(Text("^[\(geography.countries.count) country](inflect: true)"))
    }

    /// What the two greens mean, once one year is picked out of several.
    @ViewBuilder
    private var legend: some View {
        if case .year(let year) = store.snapshot.period, !isZoomed, !mapContent.visitedBefore.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                legendItem(String(year), opacity: 1)
                legendItem(String(localized: "Other years"), opacity: 0.42)
            }
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
            // It sits in the ocean beside South America; any larger and it covers land.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func legendItem(_ title: String, opacity: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(MovesPalette.place.opacity(opacity))
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    /// Names the tapped country and leads to its page when there is one.
    @ViewBuilder
    private func callout(for code: String) -> some View {
        let visited = geography.country(code)
        let label = HStack(spacing: 8) {
            Text(PlacesGeography.flagEmoji(forCountryCode: code))
            Text(PlacesGeography.countryName(forCountryCode: code))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            Group {
                if let visited {
                    Text("^[\(visited.dayCount) day](inflect: true)")
                } else if everywhere.country(code) != nil {
                    Text(String(localized: "Other years"))
                } else {
                    Text(String(localized: "Not visited"))
                }
            }
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
            if everywhere.country(code) != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(MovesPalette.border, lineWidth: 1) }
        .contentShape(Capsule())

        Group {
            if everywhere.country(code) != nil {
                NavigationLink(value: InsightsRoute.country(code)) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private func focusMap() {
        selectedCountry = nil
        let target: CGRect
        if let geometry, let group = groups.first, continent != nil {
            // Where the person went there; a whole continent would be mostly Russia.
            target = geometry.viewport(around: Set(group.countries.map(\.code)))
        } else {
            target = WorldMapGeometry.bounds
        }
        withAnimation(.smooth(duration: 0.5)) { viewport = target }
    }

    // MARK: - Continents

    /// Continents filter the list and bring the map to them. Pointless with only one.
    @ViewBuilder
    private var chips: some View {
        let continents = geography.continents
        if continents.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(String(localized: "World"), count: count(in: continents), selects: nil)
                    ForEach(continents) { group in
                        chip(group.continent.name, count: count(in: [group]), selects: group.continent)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func count(in groups: [InsightsGeography.ContinentGroup]) -> Int {
        groups.reduce(0) { $0 + (mode == .countries ? $1.countries.count : $1.cities.count) }
    }

    private func chip(_ title: String, count: Int, selects value: WorldContinent?) -> some View {
        let selected = continent == value
        return Button {
            continent = value
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text(count, format: .number)
                    .opacity(0.65)
                    .monospacedDigit()
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(selected ? MovesPalette.place : Color(uiColor: .tertiarySystemFill), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(groups) { group in
                switch mode {
                case .countries: countrySection(group)
                case .cities: citySections(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        .movesFloatingTabBarClearance()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "globe")
            }
        }
    }

    private var emptyTitle: String {
        if case .year(let year) = store.period { return String(localized: "No places in \(String(year))") }
        return String(localized: "No places yet")
    }

    private func countrySection(_ group: InsightsGeography.ContinentGroup) -> some View {
        Section {
            ForEach(group.countries) { country in
                NavigationLink(value: InsightsRoute.country(country.code)) {
                    InsightsCountryRow(country: country)
                }
            }
        } header: {
            continentHeader(group)
        }
    }

    @ViewBuilder
    private func citySections(_ group: InsightsGeography.ContinentGroup) -> some View {
        let countries = group.countries.filter { !$0.cities.isEmpty }
        ForEach(countries) { country in
            let isExpanded = expandedCountries.contains(country.code)
            // One more row than the limit is shown outright rather than hidden behind a button.
            let limit = isExpanded || country.cities.count <= Self.collapsedCityCount + 1
                ? country.cities.count
                : Self.collapsedCityCount
            Section {
                ForEach(country.cities.prefix(limit)) { city in
                    NavigationLink(value: InsightsRoute.city(city.id)) {
                        InsightsCityRow(city: city)
                    }
                }
                if limit < country.cities.count {
                    Button(String(localized: "Show all \(country.cities.count)")) {
                        withAnimation { _ = expandedCountries.insert(country.code) }
                    }
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    if country.id == countries.first?.id, continent == nil { continentHeader(group) }
                    HStack(spacing: 8) {
                        Text(country.flagEmoji)
                        Text(country.name)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 8)
                        Text("^[\(country.cities.count) city](inflect: true)")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                .textCase(nil)
            }
        }
    }

    private func continentHeader(_ group: InsightsGeography.ContinentGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.continent.name)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Group {
                if mode == .countries {
                    Text("^[\(group.countries.count) country](inflect: true)")
                } else {
                    Text("^[\(group.cities.count) city](inflect: true)")
                }
            }
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(Color.secondary)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// City dots for the world map, bigger for more days.
enum InsightsWorldDots {
    static func dots(for geography: InsightsGeography) -> [WorldMapContent.Dot] {
        let cities = geography.countries.flatMap(\.cities)
        let most = log(Double((cities.map(\.dayCount).max() ?? 1) + 1))
        return cities
            // The biggest go on last, over the towns around them.
            .sorted { $0.dayCount < $1.dayCount }
            .compactMap { city in
                city.center.map {
                    WorldMapContent.Dot(
                        point: WorldMapGeometry.projectWrapping(longitude: $0.longitude, latitude: $0.latitude),
                        weight: log(Double(city.dayCount + 1)) / most
                    )
                }
            }
    }
}

private extension InsightsPeriod {
    var title: String {
        switch self {
        case .year(let year): return String(year)
        case .all: return String(localized: "All years")
        }
    }
}

struct InsightsCountryRow: View {
    let country: InsightsGeography.Country
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Text(country.flagEmoji)
                .font(.title2)
                .accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                    if !citySummaries.isEmpty {
                        // The fullest line that fits; at large text it wraps instead.
                        ViewThatFits(in: .horizontal) {
                            ForEach(citySummaries, id: \.self) { summary in
                                Text(summary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            }
                        }
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                InsightsDayCount(days: country.dayCount)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Da Lat, Hanoi, and 12 more", then shorter ways to say it.
    private var citySummaries: [String] {
        let names = country.cities.map(\.name)
        guard let first = names.first else { return [] }
        // A city-state needs no second line saying its own name.
        if names.count == 1, WorldCityIndex.key(first) == WorldCityIndex.key(country.name) { return [] }
        return (1...min(3, names.count)).reversed().map { shown in
            let rest = names.count - shown
            let more = rest > 0 ? [String(localized: "\(rest) more")] : []
            return (Array(names.prefix(shown)) + more).formatted(.list(type: .and))
        }
    }
}

struct InsightsCityRow: View {
    let city: InsightsGeography.City
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Text(city.name)
                .font(.system(.callout, design: .rounded, weight: .semibold))
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            InsightsDayCount(days: city.dayCount)
        }
        .accessibilityElement(children: .combine)
    }
}

struct InsightsDayCount: View {
    let days: Int

    var body: some View {
        Text("^[\(days) day](inflect: true)")
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
    }
}
