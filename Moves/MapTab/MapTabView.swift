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
    /// The camera once it settles. Nothing in `body` reads the camera while it moves.
    @State private var visibleRegion = MapCameraDefaults.launchRegion
    /// The camera as it moves, read only by the bitmap overlay.
    @State private var cameraState = MapCameraState()
    /// The trip picked on the Routes bitmap, found through the activity index.
    @State private var selectedTrack: MapActivityTrack?
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
            .filter(MapTabView.changesWhatTheMapDraws)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .share()
            .eraseToAnyPublisher()

    /// Entities the activity index is built from.
    nonisolated static let drawnEntityNames: Set<String> = ["MoveSegment", "VisitPlace", "LocationSample"]

    /// Whether a save or remote change touches trips, stays, or fixes. Other saves (share-card
    /// caches, visited cells, settings) would otherwise rebuild the index every few seconds.
    nonisolated static func changesWhatTheMapDraws(_ notification: Notification) -> Bool {
        if notification.name == ModelContext.didSave {
            guard let info = notification.userInfo else { return true }
            let keys = [
                ModelContext.NotificationKey.insertedIdentifiers.rawValue,
                ModelContext.NotificationKey.updatedIdentifiers.rawValue,
                ModelContext.NotificationKey.deletedIdentifiers.rawValue
            ]
            var sawIdentifiers = false
            for key in keys {
                guard let identifiers = info[key] as? [PersistentIdentifier] else { continue }
                sawIdentifiers = true
                if identifiers.contains(where: { drawnEntityNames.contains($0.entityName) }) {
                    #if DEBUG
                    let names = Dictionary(grouping: identifiers, by: \.entityName).mapValues(\.count)
                    MapPerformanceProbe.log.notice("store change \(key, privacy: .public): \(names.description, privacy: .public)")
                    #endif
                    return true
                }
            }
            return !sawIdentifiers
        }
        if notification.name == .NSPersistentStoreRemoteChange,
           let url = notification.userInfo?[NSPersistentStoreURLKey] as? URL {
            return !url.lastPathComponent.hasPrefix("ShareMapCache")
        }
        return true
    }

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
        if routesAsBitmap {
            return selectedTrack.map(Self.displayedRoute(from:))
        }
        return displayedRoutes.first { $0.id == selectedRouteID }
    }

    /// With hundreds of trips or stays in the range, Routes draws them into one bitmap instead of
    /// a polyline or annotation each; only the selected trip is drawn on its own.
    private var routesAsBitmap: Bool {
        layer == .routes && rangeIsLarge
    }

    /// The mode filter Heat, Fog, and the Routes bitmap draw with; nil is every mode.
    private var modeFilter: Set<TransportMode>? {
        let present = Set(loader.presentModes)
        return enabledModes.isEmpty || present.isSubset(of: enabledModes) ? nil : enabledModes
    }

    /// More trips or stays in the range than polylines and annotations can carry smoothly.
    /// Counted from the activity index once it is ready, from the last load before that.
    private var rangeIsLarge: Bool {
        let threshold = MapCoverageRenderer.routeRasterThreshold
        _ = coverage.indexGeneration
        if let counts = coverage.counts(interval: selection.focus, modes: modeFilter) {
            return counts.tracks > threshold || counts.stays > threshold
        }
        return displayedRoutes.count > threshold || loader.visits.count > threshold
    }

    private static func displayedRoute(from track: MapActivityTrack) -> MapDisplayedRoute {
        let coordinates = track.chunks.enumerated().flatMap { offset, chunk in
            (offset == 0 ? chunk.points : Array(chunk.points.dropFirst())).map(\.coordinate)
        }
        return MapDisplayedRoute(
            id: track.id,
            startDate: track.start,
            endDate: track.end,
            distanceMeters: track.distanceMeters,
            rendered: RenderedRoute(
                id: track.id.uuidString,
                coordinates: coordinates,
                usesHighAccuracyRouteTracking: false,
                usesHealthWorkoutRoute: false,
                transportMode: track.mode,
                speedFractions: nil,
                confidence: .medium,
                origin: .sensor
            )
        )
    }

    var body: some View {
        let _ = MapPerformanceProbe.shared.bodyEvaluated()
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
            // Know the range's size before choosing between polylines and the bitmap.
            await coverage.prepare(container: modelContext.container)
            guard !Task.isCancelled else { return }
            let started = CACurrentMediaTime()
            await loader.load(
                selection: selection,
                modelContext: modelContext,
                cameraRegion: visibleRegion,
                includeRoutes: !rangeIsLarge,
                calendar: calendar
            )
            MapPerformanceProbe.shared.mark("routes load (\(loader.routes.count) routes, \(loader.visits.count) stays)", since: started)
            syncEnabledModes()
        }
        .onChange(of: coverageKey, initial: true) { _, _ in
            requestCoverage()
        }
        .task {
            await followUserLocation()
        }
        .onReceive(Self.coverageChanges) { _ in coverageRevision += 1 }
        .onAppear { coverageRevision += 1 }
        .onChange(of: loader.cameraFitKey) { _, _ in
            fitCamera()
            if layer == .routes, !routesAsBitmap, let opened = MapPerformanceProbe.shared.openedAt {
                MapPerformanceProbe.shared.mark("open to routes ready", since: opened)
                MapPerformanceProbe.shared.openedAt = nil
            }
        }
        .onChange(of: selection) { _, _ in
            MapPerformanceProbe.shared.activity("range")
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
            MapPerformanceProbe.shared.openedAt = CACurrentMediaTime()
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
            rangeIsLarge ? "large" : "small",
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
                    selectedTrack = nil
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
            routesAsBitmap ? "bitmap" : "-",
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
        guard layer != .routes || routesAsBitmap, let viewport = restingCameraRect ?? cameraState.rect, mapSize.width > 1 else { return }
        let modes = modeFilter
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
                if layer == .routes, !routesAsBitmap {
                    routeContent
                    visitContent
                }
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .overlay {
                if layer != .routes || routesAsBitmap {
                    MapCoverageOverlay(
                        controller: coverage,
                        layer: layer,
                        cameraState: cameraState,
                        userLocation: userLocation,
                        isDark: colorScheme == .dark,
                        highlight: routesAsBitmap ? selectedTrack : nil
                    )
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
            .overlay(alignment: .topLeading) {
                if let selectedRoute, layer == .routes {
                    routeCallout(selectedRoute)
                        .padding(14)
                        .padding(.top, 104)
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                let started = CACurrentMediaTime()
                MapPerformanceProbe.shared.activity("camera")
                cameraState.rect = MercatorRect(context.rect)
                MapPerformanceProbe.shared.cameraCallback(took: CACurrentMediaTime() - started)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                MapPerformanceProbe.shared.settledAt = CACurrentMediaTime()
                let rect = MercatorRect(context.rect)
                cameraState.rect = rect
                restingCameraRect = rect
                visibleRegion = context.region
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard layer == .routes,
                          let coordinate = proxy.convert(event.location, from: .local) else { return }
                    if routesAsBitmap {
                        selectTrack(near: coordinate)
                    } else {
                        selectRoute(near: coordinate)
                    }
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

    /// Bitmap mode: hit-test the tap against the activity index, within about 22 points.
    private func selectTrack(near coordinate: CLLocationCoordinate2D) {
        guard let rect = cameraState.rect, mapSize.width > 0 else { return }
        let tolerance = 22 * rect.width / Double(mapSize.width)
        let found = coverage.track(near: MercatorPoint(coordinate), tolerance: tolerance)
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTrack = found
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
        if loader.routes.isEmpty, loader.visits.isEmpty, let region = coverage.region(interval: selection.focus, modes: modeFilter) {
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
    /// About 13 km tall: a city, not a country. `MOVES_MAP_SPAN_KM` overrides it so agents can
    /// screenshot Heat and Fog at a set zoom.
    static let citySpan: MKCoordinateSpan = {
        if let raw = ProcessInfo.processInfo.environment["MOVES_MAP_SPAN_KM"], let km = Double(raw), km > 0 {
            let degrees = min(km / 111, 170)
            return MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        }
        return MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    }()

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
