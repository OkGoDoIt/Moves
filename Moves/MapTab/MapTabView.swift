import Combine
import CoreData
import MapKit
import SwiftData
import SwiftUI

/// Browsable map for any range: range pill, routes/heat/fog, mode chips, and a time scrubber.
struct MapTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var controller: MovesRootController
    @Query(sort: \DayTimeline.dayStart, order: .forward) private var dayTimelines: [DayTimeline]
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true

    @State private var selection = MapRangeSelection.allTime()
    @State private var loader = MapWindowLoader()
    @State private var coverage = MapCoverageController()
    @State private var layer: MapCoverageLayer = MapTabView.initialLayer()
    @State private var enabledModes: Set<TransportMode> = []
    @State private var camera: MapCameraPosition = .region(MapCameraDefaults.launchRegion)
    @State private var visibleRegion = MapCameraDefaults.launchRegion
    /// The camera as it moves, for keeping Heat and Fog pinned to the map.
    @State private var cameraRect: MercatorRect?
    /// The camera once it settles, which is when Heat and Fog redraw.
    @State private var restingCameraRect: MercatorRect?
    @State private var mapSize: CGSize = .zero
    @State private var userLocation: CLLocationCoordinate2D?
    /// All Time opens on where you are rather than fitting years of travel, once per visit to it.
    @State private var hasFramedAllTime = false
    @State private var selectedRouteID: UUID?
    @State private var isShowingRangeSheet = false
    @State private var isShowingShare = false
    @State private var isShowingSaveTrip = false
    @State private var isShowingTrips = false
    @State private var presentedTripID: UUID?
    @State private var knownModes: Set<TransportMode> = []
    @State private var coverageRevision = 0

    private var calendar: Calendar { .autoupdatingCurrent }
    /// Store changes that Heat and Fog redraw for. One shared publisher: one built in `body`
    /// would be replaced, and its debounce restarted, on every camera frame.
    private static let coverageChanges: AnyPublisher<Notification, Never> =
        Publishers.Merge3(NotificationCenter.default.publisher(for: .movesLocationSamplesDidChange),
                          NotificationCenter.default.publisher(for: ModelContext.didSave),
                          NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .share()
            .eraseToAnyPublisher()

    /// Where All Time starts.
    private var firstRecordedDate: Date? {
        dayTimelines.first(where: \.hasRecordedActivity)?.dayStart
    }

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
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if coverage.loadFailed, layer != .routes {
                    Text(String(localized: "Coverage couldn’t be loaded."))
                        .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                }
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

                MapTimeScrubber(buckets: filteredHistogram, selection: $selection, firstRecorded: firstRecordedDate)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .task(id: loadKey) {
            // Every scrubber tick changes the key. This task is cancelled by the next one,
            // so a drag only loads once it pauses.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await loader.load(
                selection: selection,
                modelContext: modelContext,
                cameraRegion: visibleRegion,
                calendar: calendar
            )
            syncEnabledModes()
        }
        .onChange(of: coverageKey, initial: true) { _, _ in
            requestCoverage()
        }
        .task(id: layer == .routes) {
            await followUserLocation()
        }
        .onReceive(Self.coverageChanges) { _ in coverageRevision += 1 }
        .onAppear { coverageRevision += 1 }
        .onChange(of: loader.cameraFitKey) { _, _ in
            fitCamera()
        }
        .onChange(of: coverage.latestActivity?.latitude) { _, _ in
            fitCamera()
        }
        .onChange(of: selection.granularity) { _, granularity in
            if granularity != .allTime { hasFramedAllTime = false }
        }
        .onChange(of: controller.requestedMapInterval) { _, newValue in
            applyRequestedInterval(newValue)
        }
        .onChange(of: firstRecordedDate, initial: true) { _, newValue in
            guard selection.granularity == .allTime, !selection.isCustom else { return }
            selection = .preset(.allTime, now: .now, calendar: calendar, firstRecorded: newValue)
        }
        .onAppear {
            loader.invalidateHistogram()
            applyRequestedInterval(controller.requestedMapInterval)
        }
        .task {
            await applyScreenshotLaunchFlags()
        }
        .sheet(isPresented: $isShowingRangeSheet) {
            MapRangeSheet(selection: $selection, firstRecorded: firstRecordedDate) {
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
                        TripDetailView(tripID: tripID, onLeave: { isShowingTrips = false })
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
                    TripDetailView(tripID: presentedTripID, onLeave: { self.presentedTripID = nil })
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
        let hidden: Set<TransportMode> = enabledModes.isEmpty ? [] : Set(loader.presentModes).subtracting(enabledModes)
        return loader.filteredBuckets(hiding: hidden, selection: selection, calendar: calendar)
    }

    private var shareTimelines: [DayTimeline] {
        if selection.granularity == .allTime {
            return Array(dayTimelines)
        }
        let starts = Set(selection.overlappingDayStarts(calendar: calendar).map { DayTimeline.makeDayKey(for: $0) })
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

    /// Everything a Heat or Fog bitmap depends on. Camera motion only counts once it settles.
    private var coverageKey: String {
        [
            layer.rawValue,
            String(selection.focus.start.timeIntervalSinceReferenceDate),
            String(selection.focus.end.timeIntervalSinceReferenceDate),
            enabledModes.map(\.rawValue).sorted().joined(separator: ","),
            String(coverageRevision),
            colorScheme == .dark ? "dark" : "light",
            restingCameraRect.map { "\($0.minX),\($0.minY),\($0.maxX),\($0.maxY)" } ?? "-",
            "\(mapSize.width)x\(mapSize.height)"
        ]
        .joined(separator: "|")
    }

    private func requestCoverage() {
        guard layer != .routes, let viewport = restingCameraRect ?? cameraRect, mapSize.width > 1 else { return }
        let present = Set(loader.presentModes)
        let modes: Set<TransportMode>? = enabledModes.isEmpty || present.isSubset(of: enabledModes) ? nil : enabledModes
        coverage.update(MapCoverageController.Update(
            container: modelContext.container,
            revision: coverageRevision,
            request: MapCoverageRenderRequest(
                layer: layer,
                viewport: viewport,
                viewSize: mapSize,
                isDark: colorScheme == .dark
            ),
            interval: selection.focus,
            modes: modes,
            includeUndated: selection.granularity == .allTime
        ))
    }

    /// Feeds the clearing around the location dot. Only runs while Heat or Fog is up, and never
    /// asks for permission.
    private func followUserLocation() async {
        guard layer != .routes else { return }
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location {
                    userLocation = location.coordinate
                }
            }
        } catch {}
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if layer == .routes {
                    routeContent
                    visitContent
                }
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .overlay {
                if layer != .routes {
                    MapCoverageOverlay(
                        raster: coverage.raster,
                        layer: layer,
                        camera: cameraRect,
                        userLocation: userLocation,
                        isDark: colorScheme == .dark
                    )
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
            .overlay(alignment: .topLeading) {
                if let selectedRoute, layer == .routes {
                    routeCallout(selectedRoute)
                        .padding(14)
                        .padding(.top, 58)
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
                cameraRect = MercatorRect(context.rect)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraRect = MercatorRect(context.rect)
                restingCameraRect = cameraRect
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
        // The selected route can scrub out of the window. Nothing dims while it is gone.
        let visibleSelection = selectedRoute?.id
        ForEach(displayedRoutes) { item in
            let route = item.rendered
            let isSelected = item.id == visibleSelection
            let dims = visibleSelection != nil && !isSelected
            let emphasis = dims ? 0.28 : 1.0
            let width = isSelected ? route.lineWidth + 3.5 : route.lineWidth

            if route.shadowCoordinates.count > 1 {
                ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.shadowCoordinates).enumerated()), id: \.offset) { _, coordinates in
                    MapPolyline(coordinates: coordinates)
                        .stroke(route.shadowTint, lineWidth: route.shadowLineWidth)
                }
            }

            if route.coordinates.count > 1 {
                ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.coordinates).enumerated()), id: \.offset) { _, coordinates in
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            route.strokeGradient(shadeBySpeed: shadeRoutesBySpeed, emphasis: emphasis),
                            style: RouteStrokeStyle.make(for: route, lineWidth: width)
                        )
                }
                if let overlayTint = route.recordedOverlayTint {
                    ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.coordinates).enumerated()), id: \.offset) { _, coordinates in
                        MapPolyline(coordinates: coordinates)
                            .stroke(
                                MovesPalette.opaqueRouteColor(overlayTint, opacity: emphasis),
                                style: RouteStrokeStyle.make(for: route, lineWidth: max(width - 2.25, 1.25))
                            )
                    }
                }
            }
        }
    }

    @MapContentBuilder
    private var visitContent: some MapContent {
        ForEach(loader.visits) { visit in
            Annotation(visit.title, coordinate: visit.coordinate, anchor: .center) {
                MapLocationDot(tint: MovesPalette.place, isSelected: false)
                    .accessibilityLabel(visit.title)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(calloutSubtitle(route))
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
        if selection.granularity == .allTime, !selection.isCustom {
            // Years of travel span countries. Open at city scale on where you are, or failing
            // that where you last were, and leave the camera alone after that.
            guard !hasFramedAllTime else { return }
            let latest = loader.visits.max { $0.arrivalDate < $1.arrivalDate }?.coordinate
                ?? coverage.latestActivity
            guard let region = MapCameraDefaults.cityRegion(
                userLocation: MapCameraDefaults.currentLocation(),
                latestActivity: latest
            ) else { return }
            hasFramedAllTime = true
            camera = .region(region)
            return
        }
        let coordinates = displayedRoutes.flatMap(\.rendered.coordinates) + loader.visits.map(\.coordinate)
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
        TripRangeStats.ensureScreenshotTrip(
            covering: selection.focus,
            in: modelContext,
            calendar: calendar
        )
    }
}

/// Where the Map opens: city scale, centred on you if the system knows where you are,
/// otherwise on the most recent activity.
enum MapCameraDefaults {
    /// About 13 km tall: a city, not a country.
    static let citySpan = MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)

    /// Shown for the instant before data loads.
    static var launchRegion: MKCoordinateRegion {
        cityRegion(userLocation: currentLocation(), latestActivity: nil) ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21),
            span: citySpan
        )
    }

    static func cityRegion(
        userLocation: CLLocationCoordinate2D?,
        latestActivity: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion? {
        let center = [userLocation, latestActivity]
            .compactMap { $0 }
            .first(where: MapRegionFactory.isUsableCoordinate)
        guard let center else { return nil }
        return MapRegionFactory.snapshotSafe(MKCoordinateRegion(center: center, span: citySpan))
    }

    /// The system's last fix, without starting updates or asking for permission.
    static func currentLocation() -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse,
              let location = manager.location,
              abs(location.timestamp.timeIntervalSinceNow) < 7 * 86_400 else { return nil }
        return location.coordinate
    }
}
