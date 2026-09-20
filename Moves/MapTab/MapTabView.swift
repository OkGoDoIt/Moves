import MapKit
import SwiftData
import SwiftUI

/// Browsable map for any range: range pill, routes/heat/fog, mode chips, and a time scrubber.
struct MapTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var controller: MovesRootController
    @Query(sort: \DayTimeline.dayStart, order: .forward) private var dayTimelines: [DayTimeline]
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true

    @State private var selection = MapRangeSelection.today()
    @State private var loader = MapWindowLoader()
    @State private var layer: MapCoverageLayer = MapTabView.initialLayer()
    @State private var enabledModes: Set<TransportMode> = []
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @State private var selectedRouteID: UUID?
    @State private var isShowingRangeSheet = false
    @State private var isShowingShare = false
    @State private var isShowingSaveTrip = false
    @State private var isShowingTrips = false
    @State private var presentedTripID: UUID?
    @State private var knownModes: Set<TransportMode> = []

    private var calendar: Calendar { .autoupdatingCurrent }

    /// Honors `MOVES_MAP_LAYER` so agents can screenshot Heat / Fog without tapping.
    private static func initialLayer() -> MapCoverageLayer {
        if let raw = ProcessInfo.processInfo.environment["MOVES_MAP_LAYER"],
           let layer = MapCoverageLayer(rawValue: raw) {
            return layer
        }
        return .routes
    }

    private var displayedRoutes: [MapDisplayedRoute] {
        loader.routes.filter { route in
            enabledModes.isEmpty || enabledModes.contains(route.transportMode)
        }
    }

    private var selectedRoute: MapDisplayedRoute? {
        displayedRoutes.first { $0.id == selectedRouteID }
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    MapLayerChips(
                        layer: $layer,
                        enabledModes: $enabledModes,
                        presentModes: loader.presentModes
                    )
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                MapTimeScrubber(buckets: filteredHistogram, selection: $selection)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .task(id: loadKey) {
            await loader.load(
                selection: selection,
                modelContext: modelContext,
                cameraRegion: visibleRegion,
                calendar: calendar
            )
            syncEnabledModes()
        }
        .onChange(of: loader.cameraFitKey) { _, _ in
            fitCamera()
        }
        .onChange(of: layer) { _, _ in
            fitCamera()
            loader.refreshCoverage(selection: selection, cameraRegion: visibleRegion)
        }
        .onChange(of: controller.requestedMapInterval) { _, newValue in
            applyRequestedInterval(newValue)
        }
        .onAppear {
            applyRequestedInterval(controller.requestedMapInterval)
        }
        .task {
            await applyScreenshotLaunchFlags()
        }
        .sheet(isPresented: $isShowingRangeSheet) {
            MapRangeSheet(selection: $selection) {
                isShowingRangeSheet = false
            }
        }
        .sheet(isPresented: $isShowingShare) {
            MovesShareGalleryView(
                dayTimelines: shareTimelines,
                initialDate: selection.focus.start,
                initialPeriod: selection.sharePeriod
            )
        }
        .sheet(isPresented: $isShowingSaveTrip) {
            SaveTripSheet(interval: selection.focus) { trip in
                presentedTripID = trip.id
            }
        }
        .sheet(isPresented: $isShowingTrips) {
            NavigationStack {
                TripListView()
                    .navigationDestination(for: UUID.self) { tripID in
                        TripDetailView(tripID: tripID)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Done")) {
                                isShowingTrips = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: Binding(
            get: { presentedTripID != nil },
            set: { if !$0 { presentedTripID = nil } }
        )) {
            if let presentedTripID {
                NavigationStack {
                    TripDetailView(tripID: presentedTripID)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Done")) {
                                    self.presentedTripID = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private var loadKey: String {
        let zoomBucket = visibleRegion.span.latitudeDelta < MapWindowLoader.detailedZoomLatitudeDelta ? "in" : "out"
        return [
            String(selection.focus.start.timeIntervalSinceReferenceDate),
            String(selection.focus.end.timeIntervalSinceReferenceDate),
            selection.granularity.rawValue,
            zoomBucket,
            String(dayTimelines.count)
        ]
        .joined(separator: "|")
    }

    private var filteredHistogram: [MapHistogramBucket] {
        let routes = displayedRoutes
        guard routes.count != loader.routes.count else { return loader.histogram }
        return MapWindowLoader.makeHistogram(routes: routes, selection: selection, calendar: calendar)
    }

    private var shareTimelines: [DayTimeline] {
        let starts = Set(selection.overlappingDayStarts(calendar: calendar).map { DayTimeline.makeDayKey(for: $0) })
        if selection.granularity == .allTime {
            return Array(dayTimelines)
        }
        return dayTimelines.filter { starts.contains($0.dayKey) }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 40, height: 40)

            MapRangePill(
                selection: selection,
                now: .now,
                calendar: calendar,
                onStep: { delta in
                    selectedRouteID = nil
                    selection = selection.stepped(by: delta, now: .now, calendar: calendar)
                },
                onOpenSheet: { isShowingRangeSheet = true },
                onSaveAsTrip: { isShowingSaveTrip = true },
                onOpenTrips: { isShowingTrips = true }
            )
            .frame(maxWidth: .infinity)

            Button {
                isShowingShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel(String(localized: "Share"))
            .disabled(shareTimelines.isEmpty)
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if layer == .routes {
                    routeContent
                    visitContent
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .overlay {
                if layer != .routes {
                    MapCoverageCanvas(
                        cells: loader.coverageCells,
                        region: visibleRegion,
                        style: layer == .fog ? .fog : .heat
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedRoute, layer == .routes {
                    routeCallout(selectedRoute)
                        .padding(14)
                        .padding(.top, 58)
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
                if layer != .routes {
                    loader.refreshCoverage(selection: selection, cameraRegion: context.region)
                }
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard layer == .routes,
                          let coordinate = proxy.convert(event.location, from: .local) else { return }
                    selectRoute(near: coordinate)
                }
            )
        }
    }

    @MapContentBuilder
    private var routeContent: some MapContent {
        ForEach(displayedRoutes) { item in
            let route = item.rendered
            let isSelected = item.id == selectedRouteID
            let dims = selectedRouteID != nil && !isSelected
            let emphasis = dims ? 0.28 : 1.0
            let width = isSelected ? route.lineWidth + 3.5 : route.lineWidth

            if route.shadowCoordinates.count > 1 {
                MapPolyline(coordinates: route.shadowCoordinates)
                    .stroke(route.shadowTint, lineWidth: route.shadowLineWidth)
            }

            if route.coordinates.count > 1 {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(
                        route.strokeGradient(shadeBySpeed: shadeRoutesBySpeed, emphasis: emphasis),
                        style: RouteStrokeStyle.make(for: route, lineWidth: width)
                    )
                if let overlayTint = route.recordedOverlayTint {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(
                            MovesPalette.opaqueRouteColor(overlayTint, opacity: emphasis),
                            style: RouteStrokeStyle.make(for: route, lineWidth: max(width - 2.25, 1.25))
                        )
                }
            }
        }
    }

    @MapContentBuilder
    private var visitContent: some MapContent {
        ForEach(loader.visits) { visit in
            Annotation(visit.title, coordinate: visit.coordinate, anchor: .center) {
                MapLocationDot(tint: MovesPalette.place, isSelected: false)
            }
        }
    }

    private func routeCallout(_ route: MapDisplayedRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: route.transportMode.symbolName)
                    .foregroundStyle(MovesPalette.transport(route.transportMode))
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(calloutSubtitle(route))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                openInTimeline(route.startDate)
            } label: {
                Text(String(localized: "Open in Timeline"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MovesPalette.border, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
    }

    private func calloutSubtitle(_ route: MapDisplayedRoute) -> String {
        let duration = DurationFormatter.text(for: max(route.endDate.timeIntervalSince(route.startDate), 0))
        let distance = Measurement(value: max(route.distanceMeters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return "\(route.transportMode.title) · \(duration) · \(distance)"
    }

    private func selectRoute(near coordinate: CLLocationCoordinate2D) {
        let threshold = max(visibleRegion.span.latitudeDelta * 111_000 * 0.025, 35)
        let tap = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (UUID, CLLocationDistance)?
        for route in displayedRoutes {
            for point in route.rendered.coordinates {
                let distance = tap.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                if distance < threshold, distance < (best?.1 ?? .greatestFiniteMagnitude) {
                    best = (route.id, distance)
                }
            }
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedRouteID = best?.0
        }
    }

    private func openInTimeline(_ date: Date) {
        if let url = MapDeepLink.timelineURL(at: date) {
            openURL(url)
        } else {
            controller.selectedTab = .timeline
            controller.requestedJumpDate = date
            controller.requestedJumpMoment = date
        }
    }

    private func fitCamera() {
        let coordinates = displayedRoutes.flatMap(\.rendered.coordinates)
            + (layer == .routes ? loader.visits.map(\.coordinate) : loader.coverageCells.map(\.center))
        guard !coordinates.isEmpty else { return }
        camera = .region(MapRegionFactory.region(for: coordinates))
    }

    private func syncEnabledModes() {
        let present = Set(loader.presentModes)
        let added = present.subtracting(knownModes)
        enabledModes.subtract(enabledModes.subtracting(present))
        enabledModes.formUnion(added)
        if enabledModes.isEmpty {
            enabledModes = present
        }
        knownModes = present
    }

    private func applyRequestedInterval(_ interval: DateInterval?) {
        guard let interval else { return }
        selection = .custom(start: interval.start, end: interval.end, calendar: calendar)
        controller.requestedMapInterval = nil
    }

    /// `MOVES_OPEN_SAVE_TRIP` / `MOVES_OPEN_TRIP` wait for the demo seeder, then open the sheet or detail.
    private func applyScreenshotLaunchFlags() async {
        let env = ProcessInfo.processInfo.environment
        let wantsSave = env["MOVES_OPEN_SAVE_TRIP"] == "1"
        let wantsDetail = env["MOVES_OPEN_TRIP"] == "1"
        guard wantsSave || wantsDetail else { return }
        await waitForSeededDays()
        if wantsSave {
            isShowingSaveTrip = true
        }
        if wantsDetail {
            presentedTripID = ensureScreenshotTrip().id
        }
    }

    private func waitForSeededDays() async {
        for _ in 0..<60 {
            if dayTimelines.contains(where: { !$0.places.isEmpty || !$0.moves.isEmpty }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Reuses an existing trip covering the current range, or saves one for screenshots.
    private func ensureScreenshotTrip() -> NamedTrip {
        let interval = selection.focus
        let existing = (try? modelContext.fetch(FetchDescriptor<NamedTrip>())) ?? []
        if let match = existing.first(where: {
            abs($0.startDate.timeIntervalSince(interval.start)) < 2
                && abs($0.endDate.timeIntervalSince(interval.end)) < 2
        }) {
            return match
        }
        let visits = (try? SwiftDataTimelineRepository(modelContext: modelContext).visits(in: interval)) ?? []
        let trip = NamedTrip(
            name: TripRangeStats.defaultName(visits: visits, interval: interval, calendar: calendar),
            startDate: interval.start,
            endDate: interval.end,
            notes: String(localized: "Saved from the Map range.")
        )
        modelContext.insert(trip)
        try? modelContext.save()
        return trip
    }
}

/// Raster overlay for heat (log colour ramp) and adaptive fog (dark mask with punched cells).
struct MapCoverageCanvas: View {
    enum Style {
        case heat
        case fog
    }

    let cells: [VisitedCellStore.DisplayCell]
    let region: MKCoordinateRegion
    let style: Style

    var body: some View {
        Canvas { context, size in
            guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
            switch style {
            case .fog:
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.72)))
                context.blendMode = .destinationOut
                for cell in cells {
                    context.fill(cellPath(cell, size: size), with: .color(.white))
                }
            case .heat:
                let maxCount = max(cells.map(\.sampleCount).max() ?? 1, 1)
                for cell in cells {
                    let t = log(Double(cell.sampleCount) + 1) / log(Double(maxCount) + 1)
                    context.fill(cellPath(cell, size: size), with: .color(Self.heatColor(fraction: t)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func cellPath(_ cell: VisitedCellStore.DisplayCell, size: CGSize) -> Path {
        let origin = cell.origin
        let end = CLLocationCoordinate2D(
            latitude: origin.latitude + cell.sizeDegrees,
            longitude: origin.longitude + cell.sizeDegrees
        )
        let a = point(for: origin, size: size)
        let b = point(for: end, size: size)
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: max(abs(b.x - a.x), 2),
            height: max(abs(b.y - a.y), 2)
        )
        return Path(roundedRect: rect.insetBy(dx: -0.4, dy: -0.4), cornerRadius: 1)
    }

    private func point(for coordinate: CLLocationCoordinate2D, size: CGSize) -> CGPoint {
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let x = (coordinate.longitude - minLon) / region.span.longitudeDelta * size.width
        let y = (maxLat - coordinate.latitude) / region.span.latitudeDelta * size.height
        return CGPoint(x: x, y: y)
    }

    /// Opaque log ramp: indigo → cyan → yellow → red.
    static func heatColor(fraction: Double) -> Color {
        let t = min(max(fraction, 0), 1)
        if t < 0.33 {
            return Color(red: 0.15, green: 0.28, blue: 0.85).mix(with: Color(red: 0.12, green: 0.78, blue: 0.86), by: t / 0.33)
        }
        if t < 0.66 {
            return Color(red: 0.12, green: 0.78, blue: 0.86).mix(with: Color(red: 1.0, green: 0.84, blue: 0.18), by: (t - 0.33) / 0.33)
        }
        return Color(red: 1.0, green: 0.84, blue: 0.18).mix(with: Color(red: 0.95, green: 0.22, blue: 0.12), by: (t - 0.66) / 0.34)
    }
}
