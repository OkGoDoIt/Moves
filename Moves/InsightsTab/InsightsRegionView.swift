import MapKit
import SwiftUI

/// One country: where in it, how long, and when.
struct InsightsCountryView: View {
    let country: InsightsGeography.Country
    @State private var outline: [[CLLocationCoordinate2D]] = []
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        List {
            Section {
                map
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            InsightsRegionSummary(title: country.name, flag: country.flagEmoji, stays: country.stays, extra: cityMetric)
            if !country.cities.isEmpty {
                Section(String(localized: "Cities")) {
                    ForEach(country.cities) { city in
                        NavigationLink(value: InsightsRoute.city(city.id)) {
                            InsightsCityRow(city: city)
                        }
                    }
                }
            }
            InsightsStaySections(stays: country.stays)
        }
        .insightsRegionList()
        .task(id: country.code) {
            let code = country.code
            let shape = await Task.detached { InsightsRegionShape.country(code) }.value
            outline = shape.rings
            camera = .rect(shape.frame(including: country.cities.compactMap(\.center)))
        }
    }

    private var cityMetric: (title: String, value: String)? {
        country.cities.count > 1 ? (String(localized: "Cities"), country.cities.count.formatted()) : nil
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(outline.indices, id: \.self) { index in
                MapPolygon(coordinates: outline[index])
                    .foregroundStyle(MovesPalette.place.opacity(0.18))
                    .stroke(MovesPalette.place.opacity(0.85), lineWidth: 1.5)
            }
            ForEach(country.cities) { city in
                if let center = city.center {
                    Annotation(city.name, coordinate: center.coordinate, anchor: .center) {
                        InsightsMapDot(diameter: diameter(for: city))
                    }
                }
            }
        }
        .insightsRegionMap()
        .accessibilityLabel(String(localized: "Map of \(country.name)"))
    }

    private func diameter(for city: InsightsGeography.City) -> CGFloat {
        let most = log(Double((country.cities.map(\.dayCount).max() ?? 1) + 1))
        return 9 + 9 * log(Double(city.dayCount + 1)) / most
    }
}

/// One city: where in it, how long, and when.
struct InsightsCityView: View {
    let city: InsightsGeography.City

    var body: some View {
        List {
            if !city.points.isEmpty {
                Section {
                    map
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            InsightsRegionSummary(
                title: city.name,
                subtitle: PlacesGeography.countryName(forCountryCode: city.countryCode),
                flag: PlacesGeography.flagEmoji(forCountryCode: city.countryCode),
                stays: city.stays,
                extra: (String(localized: "Visits"), city.visitCount.formatted())
            )
            InsightsStaySections(stays: city.stays)
        }
        .insightsRegionList()
    }

    private var map: some View {
        Map(initialPosition: .rect(InsightsRegionShape.frame(of: city.points))) {
            ForEach(city.points, id: \.self) { point in
                Annotation("", coordinate: point.coordinate, anchor: .center) {
                    InsightsMapDot(diameter: 7, border: 0.75)
                }
            }
        }
        .insightsRegionMap()
        .accessibilityLabel(String(localized: "Map of \(city.name)"))
    }
}

private struct InsightsMapDot: View {
    let diameter: CGFloat
    var border: CGFloat = 1.5

    var body: some View {
        Circle()
            .fill(MovesPalette.place)
            .stroke(.white, lineWidth: border)
            .frame(width: diameter, height: diameter)
    }
}

/// The name, days, and first and last dates.
private struct InsightsRegionSummary: View {
    let title: String
    var subtitle: String?
    let flag: String
    let stays: [InsightsGeography.Stay]
    var extra: (title: String, value: String)?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text(flag)
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    InsightsMetric(title: String(localized: "Days"), value: days.formatted())
                    if let extra { InsightsMetric(title: extra.title, value: extra.value) }
                }
                GridRow {
                    InsightsMetric(title: String(localized: "First day"), value: text(stays.first?.start))
                    InsightsMetric(title: String(localized: "Last day"), value: text(stays.last?.end))
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var days: Int { stays.reduce(0) { $0 + $1.dayCount } }

    private func text(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "—"
    }
}

/// When the person was there, newest first, by year. A row opens that day on the timeline.
private struct InsightsStaySections: View {
    let stays: [InsightsGeography.Stay]
    @EnvironmentObject private var rootController: MovesRootController
    @State private var visibleCount = 40

    var body: some View {
        let shown = Array(stays.reversed().prefix(visibleCount))
        let years = Dictionary(grouping: shown) { Calendar.autoupdatingCurrent.component(.year, from: $0.start) }
        ForEach(years.keys.sorted(by: >), id: \.self) { year in
            Section(String(year)) {
                ForEach(years[year] ?? [], id: \.self) { stay in
                    Button {
                        rootController.selectedTab = .timeline
                        rootController.requestedJumpDate = stay.start
                    } label: {
                        HStack(spacing: 8) {
                            Text(dates(of: stay))
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                            Spacer(minLength: 8)
                            InsightsDayCount(days: stay.dayCount)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Opens the day on the timeline"))
                }
            }
        }
        if visibleCount < stays.count {
            Section {
                Button(String(localized: "Show earlier dates")) { visibleCount += 100 }
                    .font(.system(.callout, design: .rounded, weight: .semibold))
            }
        }
    }

    /// The year is in the section header, unless the stay runs into another one.
    private func dates(of stay: InsightsGeography.Stay) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let day = Date.FormatStyle().month(.abbreviated).day()
        guard stay.start != stay.end else { return stay.start.formatted(day) }
        let sameYear = calendar.isDate(stay.start, equalTo: stay.end, toGranularity: .year)
        let style = Date.IntervalFormatStyle().month(.abbreviated).day()
        return (stay.start..<stay.end).formatted(sameYear ? style : style.year())
    }
}

/// Country borders as coordinates, and the part of the map worth opening on.
private struct InsightsRegionShape: Sendable {
    let rings: [[CLLocationCoordinate2D]]
    private let mainFrame: MKMapRect

    /// A piece this large next to the biggest one is part of the country's picture. Alaska is
    /// not; Sumatra and both islands of New Zealand are.
    private static let partOfPicture = 0.3
    private static let ringLimit = 60

    static func country(_ code: String) -> InsightsRegionShape {
        let polygons = OfflineVisitGeography.resolver?.polygonsByCountry()[code] ?? []
        let sized = polygons
            .compactMap { $0.first }
            .map { ring -> (ring: [CLLocationCoordinate2D], frame: MKMapRect, area: Double) in
                let coordinates = ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let frame = mapRect(of: coordinates)
                // Mercator swells toward the poles; compare true sizes.
                let squash = pow(cos(MKMapPoint(x: frame.midX, y: frame.midY).coordinate.latitude * .pi / 180), 2)
                return (coordinates, frame, frame.width * frame.height * squash)
            }
            .sorted { $0.area > $1.area }
        let main = sized.filter { $0.area >= (sized.first?.area ?? 0) * partOfPicture }
        return InsightsRegionShape(
            rings: sized.prefix(ringLimit).map(\.ring),
            mainFrame: main.reduce(MKMapRect.null) { $0.union($1.frame) }
        )
    }

    /// The main land plus everywhere the person went, with a margin.
    func frame(including points: [InsightsGeography.Point]) -> MKMapRect {
        let all = points.reduce(mainFrame) { frame, point in
            frame.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        return all.isNull ? .world : all.insetBy(dx: -all.width * 0.12, dy: -all.height * 0.12)
    }

    static func frame(of points: [InsightsGeography.Point]) -> MKMapRect {
        let frame = mapRect(of: points.map(\.coordinate))
        guard let first = points.first else { return .world }
        let least = MKMapPointsPerMeterAtLatitude(first.latitude) * 3_000
        let width = max(frame.width * 1.3, least), height = max(frame.height * 1.3, least)
        return MKMapRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private static func mapRect(of coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        coordinates.reduce(MKMapRect.null) {
            $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize(width: 1, height: 1)))
        }
    }
}

private extension InsightsGeography.Point {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private extension View {
    func insightsRegionMap() -> some View {
        mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    func insightsRegionList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MovesPalette.backgroundTop.ignoresSafeArea())
            .listSectionSpacing(.compact)
            .movesFloatingTabBarClearance()
            .navigationBarTitleDisplayMode(.inline)
    }
}
