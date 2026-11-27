//
//  TimelineDayMap.swift
//  Moves
//
//  The Timeline's one live day map. Tearing a MapKit view down on the main thread can
//  deadlock inside MapKit (`-[VKMapView dealloc]` waits on its tile-decode queue), and when
//  that happens as the app leaves the screen the system kills it. So the Timeline creates
//  one map for as long as it exists and re-points it at whichever day is active. Day pages
//  show a snapshot image where the map goes and tell the host where that is; the host lays
//  the live map over the active page's spot.
//

import Foundation
import MapKit
import QuartzCore
import SwiftData
import SwiftUI
import UIKit

// MARK: - Slot

/// Where the active page wants the live map, in the host's coordinate space.
struct TimelineDayMapSlot: Equatable {
    enum Style: Equatable {
        /// The hero above the storyline in portrait.
        case collapsed
        /// Portrait, filling the page.
        case expanded
        /// The map pane beside the storyline.
        case landscape
    }

    var dayKey: String
    var token: UUID
    var frame: CGRect
    var style: Style
}

// MARK: - Content

/// What the map draws for one day, copied out of the store so no model is held.
struct TimelineDayMapContent {
    var dayKey = ""
    /// The clock the day is read on, for the times in callouts.
    var timeZone: TimeZone = .current
    var routes: [RenderedRoute] = []
    var placeMarkers: [PlaceMarker] = []
    var placeArrivals: [UUID: Date] = [:]
    var moveDurations: [UUID: TimeInterval] = [:]
    var latestSampleCoordinate: CLLocationCoordinate2D?
    var routeKey = ""
    var placeKey = ""
    var latestSampleKey = ""
    /// The moves, in order, for route matching by id.
    var moveIDs: [UUID] = []

    func displayedRoutes(filteredModes: Set<TransportMode>) -> [RenderedRoute] {
        guard !filteredModes.isEmpty else { return routes }
        return routes.filter { filteredModes.contains(ActivityBubbleMetrics.chipMode(for: $0.transportMode)) }
    }

    /// The region that shows the whole day; the snapshot under the map uses the same one.
    func fittedRegion(
        filteredModes: Set<TransportMode>,
        liveRouteCoordinates: [CLLocationCoordinate2D]
    ) -> MKCoordinateRegion? {
        let coordinates = displayedRoutes(filteredModes: filteredModes).flatMap(\.coordinates)
            + liveRouteCoordinates
            + placeMarkers.map(\.coordinate)
        if coordinates.isEmpty {
            return latestSampleCoordinate.map { MapRegionFactory.region(for: [$0]) }
        }
        return MapRegionFactory.region(for: coordinates)
    }

    @MainActor
    static func make(for dayTimeline: DayTimeline) -> TimelineDayMapContent {
        let places = mapPlaces(for: dayTimeline)
        let routeKey = routeRefreshKey(for: dayTimeline)
        var content = TimelineDayMapContent()
        content.dayKey = dayTimeline.dayKey
        content.timeZone = dayTimeline.placeTimeZone
        content.placeMarkers = places.map { place in
            PlaceMarker(id: place.id, title: place.timelineTitle, coordinate: place.coordinate)
        }
        content.placeArrivals = Dictionary(places.map { ($0.id, $0.arrivalDate) }, uniquingKeysWith: { first, _ in first })
        let sortedMoves = dayTimeline.moves.sorted { $0.timelineStartDate < $1.timelineStartDate }
        content.moveDurations = Dictionary(sortedMoves.map { ($0.id, $0.timelineDuration) }, uniquingKeysWith: { first, _ in first })
        content.moveIDs = sortedMoves.map(\.id)
        content.placeKey = places.map { place in
            let arrival = Int(place.arrivalDate.timeIntervalSince1970.rounded())
            let departure = Int((place.departureDate ?? place.arrivalDate).timeIntervalSince1970.rounded())
            let name = content.placeMarkers.first { $0.id == place.id }?.title ?? ""
            return "\(place.id.uuidString)|\(arrival)|\(departure)|\(name)"
        }
        .joined(separator: ",")
        let latestSample = dayTimeline.samples.max { $0.timestamp < $1.timestamp }
        content.latestSampleCoordinate = latestSample?.coordinate
        content.latestSampleKey = latestSample.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        } ?? "none"
        content.routeKey = routeKey
        content.routes = DayMapRouteCache.routes(for: routeKey)?.routes ?? rawRoutes(for: sortedMoves, key: routeKey)
        return content
    }

    /// Stored or cached paths, without matching. Matching happens for the live map only.
    @MainActor
    private static func rawRoutes(for sortedMoves: [MoveSegment], key: String) -> [RenderedRoute] {
        let routes = sortedMoves.map { move in
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            return RenderedRoute.make(
                from: move,
                coordinates: move.manualRouteCoordinates ?? move.cachedRouteCoordinates(for: signature) ?? fallback
            )
        }
        DayMapRouteCache.store(routes, for: key, isFullyMatched: false)
        return routes
    }

    private static func mapPlaces(for dayTimeline: DayTimeline) -> [VisitPlace] {
        let routePlaces = dayTimeline.moves.flatMap { move in
            [move.startPlace, move.endPlace].compactMap { $0 }
        }
        var placesByID: [UUID: VisitPlace] = [:]
        for place in dayTimeline.displayPlaces + routePlaces {
            placesByID[place.id] = place
        }
        return placesByID.values.sorted { $0.arrivalDate < $1.arrivalDate }
    }

    static func routeRefreshKey(for dayTimeline: DayTimeline) -> String {
        dayTimeline.moves
            .sorted { $0.timelineStartDate < $1.timelineStartDate }
            .map { move in
                let start = Int(move.timelineStartDate.timeIntervalSince1970.rounded())
                let end = Int(move.endDate.timeIntervalSince1970.rounded())
                return "\(move.id.uuidString)|\(move.transportMode.rawValue)|\(start)|\(end)|\(move.samples.count)|\(routeStateKey(for: move))"
            }
            .joined(separator: ",")
    }

    private static func routeStateKey(for move: MoveSegment) -> String {
        if let manualData = move.manualRouteCoordinatesData {
            var hasher = Hasher()
            hasher.combine(manualData.count)
            hasher.combine(manualData)
            return "manual:\(hasher.finalize())"
        }
        return "calculated:\(move.routeCacheSignature ?? "none")"
    }
}

struct DayMapRouteCacheEntry {
    let routes: [RenderedRoute]
    let isFullyMatched: Bool
}

/// The last few days' drawn routes, so paging back and forth does not rebuild them.
@MainActor
enum DayMapRouteCache {
    private static var entries: [String: DayMapRouteCacheEntry] = [:]
    private static var keysInUseOrder: [String] = []
    private static let maximumEntryCount = 18

    static func routes(for key: String) -> DayMapRouteCacheEntry? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry
    }

    static func store(_ routes: [RenderedRoute], for key: String, isFullyMatched: Bool) {
        if let existing = entries[key], existing.isFullyMatched, !isFullyMatched {
            markRecentlyUsed(key)
            return
        }
        entries[key] = DayMapRouteCacheEntry(routes: routes, isFullyMatched: isFullyMatched)
        markRecentlyUsed(key)
        while keysInUseOrder.count > maximumEntryCount {
            entries.removeValue(forKey: keysInUseOrder.removeFirst())
        }
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }
}

// MARK: - Model

/// State of the one live map: which day it shows, where it sits, and what is selected.
@MainActor
@Observable
final class TimelineDayMapModel {
    static let coordinateSpaceName = "timelineDayMapHost"
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// The day whose content the map holds.
    private(set) var dayKey: String?
    /// Bumped when `content` changes; the map reads this, never diffs the arrays.
    private(set) var contentVersion = 0
    @ObservationIgnored private(set) var content = TimelineDayMapContent()
    private(set) var liveVersion = 0
    @ObservationIgnored private(set) var liveRoute: LiveRouteTrackingSnapshot?
    /// Bumped when matched routes land, so the active page redraws its snapshot from them.
    private(set) var routesRevision = 0

    private(set) var selection: TimelineMapSelection?
    private(set) var filteredModes: Set<TransportMode> = []
    private(set) var isExpanded = false
    struct CameraRequest {
        let region: MKCoordinateRegion
        let animated: Bool
    }

    /// Where the map was last asked to look; applied when `cameraRevision` changes.
    @ObservationIgnored private(set) var cameraRequest: CameraRequest?
    private(set) var cameraRevision = 0
    /// The person panned or zoomed since the map last framed the day.
    private(set) var userMovedCamera = false

    private(set) var slot: TimelineDayMapSlot?
    private(set) var slotStyle: TimelineDayMapSlot.Style = .collapsed
    /// The map has drawn the active day, so it can show over the page's snapshot.
    private(set) var isRevealed = false

    @ObservationIgnored private(set) var lastFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private(set) var isSceneActive = true
    /// A day asked for while the app was away, shown once it is back.
    @ObservationIgnored private var pendingDayKey: String?
    @ObservationIgnored private var expandChangedAt: CFTimeInterval = 0
    @ObservationIgnored private var hasSeenScenePhase = false
    @ObservationIgnored private var revealGeneration = 0

    var hasMovedCamera: Bool {
        userMovedCamera || selection != nil
    }

    func noteUserMovedCamera() {
        if !userMovedCamera { userMovedCamera = true }
    }

    func attach(_ context: ModelContext) {
        modelContext = context
    }

    // MARK: Day

    /// The active page calls this when it becomes active. The same map is re-pointed:
    /// hidden under the page's snapshot, given the new day, then faded back in.
    func show(_ dayTimeline: DayTimeline, filteredModes: Set<TransportMode>, liveRoute: LiveRouteTrackingSnapshot?) {
        guard isSceneActive else {
            pendingDayKey = dayTimeline.dayKey
            return
        }
        pendingDayKey = nil
        let isNewDay = dayKey != dayTimeline.dayKey
        if isNewDay {
            MapPerformanceProbe.shared.activity("timeline day change")
            revealTask?.cancel()
            revealTask = nil
            revealGeneration += 1
            routeTask?.cancel()
            isRevealed = false
            selection = nil
            if isExpanded { isExpanded = false }
            dayKey = dayTimeline.dayKey
        }
        self.filteredModes = filteredModes
        self.liveRoute = liveRoute
        liveVersion += 1
        content = TimelineDayMapContent.make(for: dayTimeline)
        contentVersion += 1
        if isNewDay {
            // The camera moves only once the day has stayed put (see the reveal), so paging
            // quickly through days loads no map tiles for the days passed over.
            if userMovedCamera { userMovedCamera = false }
        } else if !userMovedCamera {
            fitCamera()
        }
        matchRoutes()
        scheduleRevealIfReady()
    }

    /// Stays, trips, names, or modes of the shown day changed.
    func refresh(_ dayTimeline: DayTimeline) {
        guard isSceneActive, dayTimeline.dayKey == dayKey else { return }
        let updated = TimelineDayMapContent.make(for: dayTimeline)
        guard updated.routeKey != content.routeKey || updated.placeKey != content.placeKey
            || updated.latestSampleKey != content.latestSampleKey else { return }
        content = updated
        contentVersion += 1
        if case .place(let id) = selection, !content.placeMarkers.contains(where: { $0.id == id }) {
            selection = nil
        }
        if case .move(let id) = selection, !content.moveIDs.contains(id) {
            selection = nil
        }
        if !hasMovedCamera { fitCamera() }
        matchRoutes()
    }

    /// New fixes extend the live line. The camera follows only if nobody moved it.
    func updateLiveRoute(_ snapshot: LiveRouteTrackingSnapshot?, for dayKey: String) {
        guard isSceneActive, dayKey == self.dayKey else { return }
        liveRoute = snapshot
        liveVersion += 1
        if snapshot == nil, case .liveRoute = selection { selection = nil }
        if !hasMovedCamera { fitCamera(animated: true) }
    }

    func setFilteredModes(_ modes: Set<TransportMode>, for dayKey: String) {
        guard dayKey == self.dayKey, modes != filteredModes else { return }
        filteredModes = modes
        if !hasMovedCamera { fitCamera(animated: true) }
    }

    // MARK: Selection and camera

    func select(_ newSelection: TimelineMapSelection?) {
        guard newSelection != selection else { return }
        selection = newSelection
        if let newSelection {
            zoom(to: newSelection, animated: true)
        } else {
            fitCamera(animated: true)
        }
    }

    /// Shows the whole day again.
    func recentre() {
        withAnimation(.easeInOut(duration: 0.35)) {
            if selection != nil {
                selection = nil
            }
        }
        fitCamera(animated: true)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        expandChangedAt = CACurrentMediaTime()
        withAnimation(Self.expandAnimation) {
            isExpanded = expanded
        }
    }

    func fittedRegion() -> MKCoordinateRegion? {
        content.fittedRegion(filteredModes: filteredModes, liveRouteCoordinates: liveRoute?.coordinates ?? [])
    }

    private func fitCamera(animated: Bool = false) {
        guard let region = fittedRegion() else { return }
        cameraRequest = CameraRequest(region: region, animated: animated)
        cameraRevision += 1
        if userMovedCamera { userMovedCamera = false }
    }

    private func zoom(to selection: TimelineMapSelection, animated: Bool = false) {
        let coordinates: [CLLocationCoordinate2D]
        switch selection {
        case .place(let id):
            coordinates = content.placeMarkers.first { $0.id == id }.map { [$0.coordinate] } ?? []
        case .move(let id):
            coordinates = content.routes.first { $0.id == id.uuidString }?.coordinates ?? []
        case .liveRoute:
            coordinates = liveRoute?.coordinates ?? []
        case .sample:
            coordinates = content.latestSampleCoordinate.map { [$0] } ?? []
        }
        guard !coordinates.isEmpty else { return }
        cameraRequest = CameraRequest(region: MapRegionFactory.region(for: coordinates), animated: animated)
        cameraRevision += 1
        if userMovedCamera { userMovedCamera = false }
    }

    // MARK: Placement

    func reportSlot(_ newSlot: TimelineDayMapSlot) {
        guard newSlot != slot else { return }
        let previous = slot
        if let previous, previous.dayKey == newSlot.dayKey, previous.frame.minX != newSlot.frame.minX,
           previous.frame.size == newSlot.frame.size {
            MapPerformanceProbe.shared.activity("timeline swipe")
        }
        let resizesForExpand = previous?.dayKey == newSlot.dayKey
            && previous?.frame.size != newSlot.frame.size
            && CACurrentMediaTime() - expandChangedAt < 0.6
        if resizesForExpand {
            withAnimation(Self.expandAnimation) { slot = newSlot }
        } else {
            slot = newSlot
        }
        lastFrame = newSlot.frame
        if slotStyle != newSlot.style { slotStyle = newSlot.style }
        // Expanded, shrunk, or rotated: frame the day again once the map has its new size,
        // unless the person has moved it.
        if let previous, previous.dayKey == newSlot.dayKey, previous.frame.size != newSlot.frame.size {
            refitAfterResize()
        }
        scheduleRevealIfReady()
    }

    private func refitAfterResize() {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, self.isSceneActive else { return }
            if let selection = self.selection {
                self.zoom(to: selection, animated: true)
            } else if !self.userMovedCamera {
                self.fitCamera(animated: true)
            }
        }
    }

    func clearSlot(token: UUID) {
        guard slot?.token == token else { return }
        slot = nil
    }

    private func scheduleRevealIfReady() {
        guard isSceneActive, !isRevealed, revealTask == nil,
              let dayKey, slot?.dayKey == dayKey else { return }
        revealGeneration += 1
        let generation = revealGeneration
        revealTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.revealGeneration == generation { self.revealTask = nil }
            }
            // The day has to stay put a moment before the map is pointed at it.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.isSceneActive, self.dayKey == dayKey else { return }
            if let selection = self.selection {
                self.zoom(to: selection)
            } else {
                self.fitCamera()
            }
            // Time for MapKit to draw the new region under the snapshot.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.isSceneActive, self.dayKey == dayKey else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.isRevealed = true
            }
        }
    }

    // MARK: Scene

    /// Leaving the foreground stops all work and leaves the view tree alone: the map is
    /// never hidden, removed, or re-pointed on the way out.
    func sceneDidChange(isActive: Bool) {
        let isFirstReport = !hasSeenScenePhase
        hasSeenScenePhase = true
        guard isActive != isSceneActive else { return }
        isSceneActive = isActive
        if isFirstReport, !isActive { return }
        if isActive {
            TimelineMapSnapshotPool.shared.resume()
            if let pendingDayKey, pendingDayKey != dayKey, let day = fetchDay(pendingDayKey) {
                show(day, filteredModes: [], liveRoute: nil)
            } else {
                if let dayKey, let day = fetchDay(dayKey) { refresh(day) }
                matchRoutes()
                scheduleRevealIfReady()
            }
        } else {
            MapPerformanceProbe.shared.watchMainThread("timeline leaving the app")
            revealTask?.cancel()
            revealTask = nil
            revealGeneration += 1
            routeTask?.cancel()
            routeTask = nil
            resizeTask?.cancel()
            resizeTask = nil
            TimelineMapSnapshotPool.shared.suspend()
        }
    }

    // MARK: Route matching

    /// Matches the shown day's routes to roads in the background of the main actor. Moves
    /// are looked up by id after every await, so a trip deleted meanwhile is skipped.
    private func matchRoutes() {
        routeTask?.cancel()
        routeTask = nil
        let routeKey = content.routeKey
        let moveIDs = content.moveIDs
        guard isSceneActive, let dayKey, !moveIDs.isEmpty else { return }
        if DayMapRouteCache.routes(for: routeKey)?.isFullyMatched == true { return }
        routeTask = Task { @MainActor [weak self] in
            // Paging through days starts no matching until a day stays put for a moment.
            try? await Task.sleep(for: .milliseconds(600))
            var rendered: [RenderedRoute] = []
            for id in moveIDs {
                guard !Task.isCancelled, let self, let move = self.fetchMove(id) else { return }
                let matched = await RoadRouteMatcher.matchedCoordinates(for: move)
                guard !Task.isCancelled, let current = self.fetchMove(id) else { return }
                let fractions = await SpeedProfileBuilder.buildAndCache(for: current, coordinates: matched)
                guard !Task.isCancelled, let latest = self.fetchMove(id) else { return }
                rendered.append(RenderedRoute.make(from: latest, coordinates: matched, speedFractions: fractions))
            }
            guard let self, !Task.isCancelled, self.dayKey == dayKey, self.content.routeKey == routeKey else { return }
            DayMapRouteCache.store(rendered, for: routeKey, isFullyMatched: true)
            if let context = self.modelContext, context.hasChanges {
                try? context.save()
            }
            self.content.routes = rendered
            self.contentVersion += 1
            self.routesRevision += 1
            if let selection = self.selection {
                self.zoom(to: selection)
            } else if !self.userMovedCamera {
                self.fitCamera()
            }
            self.routeTask = nil
        }
    }

    private func fetchMove(_ id: UUID) -> MoveSegment? {
        guard let modelContext else { return nil }
        // A trip the rebuild retired meanwhile is gone too.
        var descriptor = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == id && $0.dayTimeline != nil })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchDay(_ key: String) -> DayTimeline? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

// MARK: - Host

private struct TimelineDayMapHostModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var rootController: MovesRootController
    @State private var model = TimelineDayMapModel()
    @State private var sideInsets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .environment(model)
            .environment(\.timelinePageSideInsets, sideInsets)
            // The pager spans the full width (pages are as wide as the screen), so pages
            // pad themselves by the side safe areas it no longer applies.
            .background {
                Color.clear
                    .ignoresSafeArea()
                    .onGeometryChange(for: EdgeInsets.self) { proxy in
                        proxy.safeAreaInsets
                    } action: { insets in
                        sideInsets = EdgeInsets(top: 0, leading: insets.leading, bottom: 0, trailing: insets.trailing)
                    }
            }
            .coordinateSpace(.named(TimelineDayMapModel.coordinateSpaceName))
            .overlay(alignment: .topLeading) {
                TimelineLiveDayMapLayer(model: model)
            }
            .onAppear { model.attach(modelContext) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.sceneDidChange(isActive: phase == .active)
            }
            #if DEBUG
            .task { await TimelinePagingSoak.runIfRequested(rootController) }
            #endif
    }
}

#if DEBUG
/// Debug only: `MOVES_TIMELINE_PAGING_SOAK=<days>` steps back that many days and forward
/// again, a day every 250 ms, and logs frame times and memory under the `Map` category.
@MainActor
enum TimelinePagingSoak {
    private static var didRun = false

    static func runIfRequested(_ rootController: MovesRootController) async {
        guard !didRun, let value = ProcessInfo.processInfo.environment["MOVES_TIMELINE_PAGING_SOAK"],
              let days = Int(value), days > 0 else { return }
        didRun = true
        try? await Task.sleep(for: .seconds(5))
        let start = Date.now
        MapPerformanceProbe.shared.mark("paging soak start", since: CACurrentMediaTime())
        for step in Array(1...days) + Array((0..<days).reversed()) {
            guard !Task.isCancelled else { return }
            let date = Calendar.current.date(byAdding: .day, value: -step, to: start) ?? start
            MapPerformanceProbe.shared.activity("paging soak")
            rootController.requestedJumpDate = date
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        MapPerformanceProbe.shared.mark("paging soak end", since: CACurrentMediaTime())
    }
}
#endif

extension EnvironmentValues {
    /// Side safe areas of the screen, which full-width day pages pad themselves by.
    @Entry var timelinePageSideInsets = EdgeInsets()
}

extension View {
    /// Hosts the Timeline's single live day map over the day pager.
    func timelineDayMapHost() -> some View {
        modifier(TimelineDayMapHostModifier())
    }
}

/// Places the map over the active page's spot. Only this view reads the spot, so a swipe
/// moves the map without re-evaluating its content.
private struct TimelineLiveDayMapLayer: View {
    let model: TimelineDayMapModel

    var body: some View {
        let slot = model.slot
        let frame = slot?.frame ?? model.lastFrame
        let isShown = slot != nil && slot?.dayKey == model.dayKey && model.isRevealed
        TimelineLiveDayMapView(model: model)
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .offset(x: frame.minX, y: frame.minY)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

private struct TimelineLiveDayMapView: View {
    @Bindable var model: TimelineDayMapModel
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true

    static let cornerRadius: CGFloat = 20

    var body: some View {
        let style = model.slotStyle
        TimelineDayMapCanvas(
            model: model,
            state: TimelineDayMapCanvas.Inputs(
                contentVersion: model.contentVersion,
                liveVersion: model.liveVersion,
                cameraRevision: model.cameraRevision,
                selection: model.selection,
                filteredModes: model.filteredModes,
                showsBigMarkers: showsBigMarkers,
                shadesBySpeed: style != .collapsed && shadeRoutesBySpeed
            )
        )
        .accessibilityLabel(String(localized: "Day map"))
        .accessibilityHint(String(localized: "Shows the day’s places and how you moved"))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            TimelineDayMapCalloutOverlay(model: model)
        }
        .overlay(alignment: .bottomTrailing) {
            TimelineDayMapControls(model: model, style: style)
                .padding(style == .expanded ? 16 : 10)
        }
        .shadow(color: .black.opacity(style == .expanded ? 0.12 : 0), radius: 18, x: 0, y: 8)
    }
}

/// The map itself: one `MKMapView` for the life of the Timeline. SwiftUI's `Map` was
/// measured keeping every content list it was given (about 0.75 MB per day shown), so a
/// long-lived one grew without bound; here overlays and annotations are replaced in place.
private struct TimelineDayMapCanvas: UIViewRepresentable {
    struct Inputs: Equatable {
        var contentVersion: Int
        var liveVersion: Int
        var cameraRevision: Int
        var selection: TimelineMapSelection?
        var filteredModes: Set<TransportMode>
        var showsBigMarkers: Bool
        var shadesBySpeed: Bool
    }

    let model: TimelineDayMapModel
    let state: Inputs

    func makeCoordinator() -> TimelineDayMapCoordinator {
        TimelineDayMapCoordinator(model: model)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsUserLocation = true
        mapView.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(TimelineDayMapCoordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        context.coordinator.apply(state, to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.apply(state, to: mapView)
    }
}

/// A day's path piece with how to draw it.
private final class TimelineRouteOverlay: MKPolyline {
    var routeID: String?
    var strokeColor: UIColor = .systemBlue
    var gradient: (colors: [UIColor], locations: [CGFloat])?
    var width: CGFloat = 4
    var dash: [NSNumber]?
}

private final class TimelinePlaceAnnotation: MKPointAnnotation {
    var placeID: UUID?
    var tint: UIColor = .systemGreen
    var isEmphasized = false
    var usesMarker = false
    var isTappable = true
}

/// The small dot the Timeline uses for stays, the live position, and a lone fix.
private final class TimelineDotAnnotationView: MKAnnotationView {
    private let ring = CALayer()
    private let dot = CALayer()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        backgroundColor = .clear
        layer.addSublayer(ring)
        layer.addSublayer(dot)
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(tint: UIColor, emphasized: Bool) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringSize: CGFloat = emphasized ? 24 : 0
        ring.frame = CGRect(x: center.x - ringSize / 2, y: center.y - ringSize / 2, width: ringSize, height: ringSize)
        ring.cornerRadius = ringSize / 2
        ring.backgroundColor = UIColor.white.cgColor
        ring.borderColor = tint.cgColor
        ring.borderWidth = emphasized ? 3 : 0
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = emphasized ? 0.24 : 0
        ring.shadowRadius = 3
        ring.shadowOffset = CGSize(width: 0, height: 1)
        let dotSize: CGFloat = emphasized ? 12 : 8
        dot.frame = CGRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = tint.cgColor
        dot.borderColor = UIColor.white.cgColor
        dot.borderWidth = 1.5
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.18
        dot.shadowRadius = 1
        dot.shadowOffset = CGSize(width: 0, height: 1)
    }
}

@MainActor
private final class TimelineDayMapCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    let model: TimelineDayMapModel
    private var applied: TimelineDayMapCanvas.Inputs?
    private var dayOverlays: [MKOverlay] = []
    private var liveOverlays: [MKOverlay] = []
    private var dayAnnotations: [MKAnnotation] = []
    private var liveAnnotations: [MKAnnotation] = []
    private var displayedRoutes: [RenderedRoute] = []
    private var isUserGesture = false

    init(model: TimelineDayMapModel) {
        self.model = model
    }

    func apply(_ state: TimelineDayMapCanvas.Inputs, to mapView: MKMapView) {
        let previous = applied
        applied = state
        let dayChanged = previous == nil
            || previous?.contentVersion != state.contentVersion
            || previous?.selection != state.selection
            || previous?.filteredModes != state.filteredModes
            || previous?.showsBigMarkers != state.showsBigMarkers
            || previous?.shadesBySpeed != state.shadesBySpeed
        if dayChanged {
            rebuildDay(on: mapView, state: state)
        }
        if dayChanged || previous?.liveVersion != state.liveVersion {
            rebuildLive(on: mapView, state: state)
        }
        if previous?.cameraRevision != state.cameraRevision, let request = model.cameraRequest {
            mapView.setRegion(MapRegionFactory.snapshotSafe(request.region), animated: request.animated && previous != nil)
        }
    }

    private func rebuildDay(on mapView: MKMapView, state: TimelineDayMapCanvas.Inputs) {
        mapView.removeOverlays(dayOverlays)
        mapView.removeAnnotations(dayAnnotations)
        let content = model.content
        let routes = content.displayedRoutes(filteredModes: state.filteredModes)
        displayedRoutes = routes
        var shadows: [MKOverlay] = []
        var lines: [MKOverlay] = []
        var recorded: [MKOverlay] = []
        for route in routes {
            let isSelected: Bool = {
                guard case .move(let id) = state.selection else { return false }
                return route.id == id.uuidString
            }()
            let emphasis = state.selection != nil && !isSelected ? 0.28 : 1.0
            let width = isSelected ? route.lineWidth + 4 : route.lineWidth
            let dash = RouteStrokeStyle.make(for: route, lineWidth: width).dash
            if route.shadowCoordinates.count > 1 {
                for piece in RouteCoordinateOps.mapPolylineSegments(route.shadowCoordinates) {
                    let overlay = Self.overlay(piece)
                    overlay.strokeColor = UIColor(route.shadowTint)
                    overlay.width = isSelected ? route.shadowLineWidth + 4 : route.shadowLineWidth
                    shadows.append(overlay)
                }
            }
            guard route.coordinates.count > 1 else { continue }
            let stops = route.strokeGradient(shadeBySpeed: state.shadesBySpeed, emphasis: emphasis).stops
            for piece in RouteCoordinateOps.mapPolylineSegments(route.coordinates) {
                let overlay = Self.overlay(piece)
                overlay.routeID = route.id
                overlay.width = width
                overlay.dash = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
                overlay.strokeColor = UIColor(stops.first?.color ?? route.tint)
                if Set(stops.map { UIColor($0.color) }).count > 1 {
                    overlay.gradient = (stops.map { UIColor($0.color) }, stops.map { CGFloat($0.location) })
                }
                lines.append(overlay)
                if let overlayTint = route.recordedOverlayTint {
                    let top = Self.overlay(piece)
                    top.routeID = route.id
                    top.width = max(width - 2.25, 1.25)
                    top.dash = overlay.dash
                    top.strokeColor = UIColor(MovesPalette.opaqueRouteColor(overlayTint, opacity: emphasis))
                    recorded.append(top)
                }
            }
        }
        dayOverlays = shadows + lines + recorded
        mapView.addOverlays(dayOverlays, level: .aboveRoads)

        var annotations: [MKAnnotation] = content.placeMarkers.map { marker in
            let annotation = TimelinePlaceAnnotation()
            annotation.placeID = marker.id
            annotation.title = marker.title
            annotation.coordinate = marker.coordinate
            annotation.tint = UIColor(MovesPalette.place)
            annotation.isEmphasized = state.selection == .place(marker.id)
            annotation.usesMarker = state.showsBigMarkers && !annotation.isEmphasized
            return annotation
        }
        if content.placeMarkers.isEmpty, routes.isEmpty, model.liveRoute?.coordinates.isEmpty ?? true,
           let latest = content.latestSampleCoordinate {
            let annotation = TimelinePlaceAnnotation()
            annotation.title = String(localized: "Captured location")
            annotation.coordinate = latest
            annotation.tint = UIColor(MovesPalette.start)
            annotation.isTappable = false
            if case .sample = state.selection { annotation.isEmphasized = true }
            annotations.append(annotation)
        }
        dayAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// The path so far on a trip in progress, ending at a dot where the latest fix is.
    private func rebuildLive(on mapView: MKMapView, state: TimelineDayMapCanvas.Inputs) {
        mapView.removeOverlays(liveOverlays)
        mapView.removeAnnotations(liveAnnotations)
        liveOverlays = []
        liveAnnotations = []
        guard let live = model.liveRoute, live.coordinates.count > 1 else { return }
        let isSelected: Bool = { if case .liveRoute = state.selection { return true } else { return false } }()
        let tint = TimelineLiveTrip.tint(for: live)
        for piece in RouteCoordinateOps.mapPolylineSegments(live.coordinates) {
            let overlay = Self.overlay(piece)
            overlay.strokeColor = UIColor(MovesPalette.opaqueRouteColor(tint, opacity: state.selection != nil && !isSelected ? 0.28 : 1))
            overlay.width = isSelected ? 9 : 5
            liveOverlays.append(overlay)
        }
        mapView.addOverlays(liveOverlays, level: .aboveRoads)
        if let last = live.coordinates.last {
            let dot = TimelinePlaceAnnotation()
            dot.title = String(localized: "Now")
            dot.coordinate = last
            dot.tint = UIColor(tint)
            dot.isEmphasized = true
            dot.isTappable = false
            liveAnnotations = [dot]
            mapView.addAnnotation(dot)
        }
    }

    private static func overlay(_ coordinates: [CLLocationCoordinate2D]) -> TimelineRouteOverlay {
        var points = coordinates
        return TimelineRouteOverlay(coordinates: &points, count: points.count)
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let route = overlay as? TimelineRouteOverlay else { return MKOverlayRenderer(overlay: overlay) }
        let renderer: MKPolylineRenderer
        if let gradient = route.gradient {
            let gradientRenderer = MKGradientPolylineRenderer(polyline: route)
            gradientRenderer.setColors(gradient.colors, locations: gradient.locations)
            renderer = gradientRenderer
        } else {
            renderer = MKPolylineRenderer(polyline: route)
            renderer.strokeColor = route.strokeColor
        }
        renderer.lineWidth = route.width
        renderer.lineCap = .round
        renderer.lineJoin = .round
        renderer.lineDashPattern = route.dash
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let place = annotation as? TimelinePlaceAnnotation else { return nil }
        if place.usesMarker {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "marker") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: place, reuseIdentifier: "marker")
            view.annotation = place
            view.markerTintColor = place.tint
            view.titleVisibility = .adaptive
            return view
        }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "dot") as? TimelineDotAnnotationView
            ?? TimelineDotAnnotationView(annotation: place, reuseIdentifier: "dot")
        view.annotation = place
        view.configure(tint: place.tint, emphasized: place.isEmphasized)
        view.isAccessibilityElement = true
        view.accessibilityLabel = place.title
        view.displayPriority = .required
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
        mapView.deselectAnnotation(annotation, animated: false)
        guard let place = annotation as? TimelinePlaceAnnotation, place.isTappable, let id = place.placeID else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.select(.place(id))
        }
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // A change the person makes runs while one of the map's own gestures is active.
        isUserGesture = mapView.subviews.first?.gestureRecognizers?.contains { recognizer in
            recognizer.state == .began || recognizer.state == .changed
        } ?? false
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard isUserGesture else { return }
        isUserGesture = false
        model.noteUserMovedCamera()
    }

    // MARK: Taps on routes

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// A tap on a drawn route selects that trip, the way a tap on a marker selects a stay.
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        for annotation in dayAnnotations {
            let markerPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
            if hypot(markerPoint.x - point.x, markerPoint.y - point.y) < 16 { return }
        }
        var best: (id: String, distance: CGFloat)?
        for route in displayedRoutes where route.coordinates.count > 1 {
            let points = route.coordinates.map { mapView.convert($0, toPointTo: mapView) }
            for (start, end) in zip(points, points.dropFirst()) {
                let distance = Self.distance(from: point, toSegment: start, end)
                if distance < 22, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (route.id, distance)
                }
            }
        }
        guard let best, let id = UUID(uuidString: best.id) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.select(.move(id))
        }
    }

    private static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}


private struct TimelineDayMapCalloutOverlay: View {
    let model: TimelineDayMapModel

    var body: some View {
        if let callout {
            TimelineMapCallout(title: callout.title, subtitle: callout.subtitle, tint: callout.tint)
                .padding(12)
        }
    }

    private var callout: (title: String, subtitle: String, tint: Color)? {
        let _ = model.contentVersion
        let content = model.content
        var clock = Date.FormatStyle.dateTime.hour().minute()
        clock.timeZone = content.timeZone
        switch model.selection {
        case .place(let id):
            guard let marker = content.placeMarkers.first(where: { $0.id == id }) else { return nil }
            let subtitle = content.placeArrivals[id].map { $0.formatted(clock) } ?? marker.title
            return (marker.title, subtitle, MovesPalette.place)
        case .move(let id):
            guard let route = content.routes.first(where: { $0.id == id.uuidString }) else { return nil }
            let subtitle = content.moveDurations[id].map { DurationFormatter.text(for: $0) } ?? route.transportMode.title
            return (route.transportMode.title, subtitle, route.tint)
        case .liveRoute:
            let _ = model.liveVersion
            guard let live = model.liveRoute else { return nil }
            let title = live.isFollowedTrip
                ? String(localized: "Trip in progress")
                : String(localized: "Route tracking")
            let distance = Measurement(value: max(live.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            return (title, String(localized: "Since \(live.startDate.formatted(clock)) · \(distance)"), TimelineLiveTrip.tint(for: live))
        case .sample:
            return (String(localized: "Captured location"), String(localized: "Now"), MovesPalette.start)
        case nil:
            return nil
        }
    }
}

/// Recentre once the camera has moved, and expand or shrink the map.
private struct TimelineDayMapControls: View {
    let model: TimelineDayMapModel
    let style: TimelineDayMapSlot.Style

    var body: some View {
        HStack(spacing: 10) {
            if model.hasMovedCamera {
                Button {
                    model.recentre()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frostedCircle(enabled: true)
                .accessibilityLabel(String(localized: "Show the whole day"))
                .help(String(localized: "Show the whole day"))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if style != .landscape {
                let isFullScreen = style == .expanded
                Button {
                    model.setExpanded(!isFullScreen)
                } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frostedCircle(enabled: true)
                .accessibilityLabel(isFullScreen ? "Shrink map" : "Expand map")
                .help(isFullScreen ? "Shrink map" : "Expand map")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.hasMovedCamera)
    }
}

// MARK: - Trip in progress

/// How the Timeline presents a trip that is still under way.
enum TimelineLiveTrip {
    /// A mode guess from the speed so far, for the row's icon and the line's color.
    static func mode(for snapshot: LiveRouteTrackingSnapshot) -> TransportMode? {
        guard snapshot.isFollowedTrip else { return nil }
        let elapsed = snapshot.latestDate.timeIntervalSince(snapshot.startDate)
        guard elapsed > 60, snapshot.distanceMeters > 50 else { return .walking }
        let speed = snapshot.distanceMeters / elapsed
        switch speed {
        case ..<2.5: return .walking
        case ..<7: return .cycling
        default: return .automotive
        }
    }

    static func tint(for snapshot: LiveRouteTrackingSnapshot) -> Color {
        mode(for: snapshot).map(MovesPalette.transport) ?? MovesPalette.routeTracking
    }

    static func iconName(for snapshot: LiveRouteTrackingSnapshot) -> String {
        mode(for: snapshot)?.symbolName ?? "location.fill.viewfinder"
    }

    /// "12m   0.6 mi", counted to `now` so it keeps going between fixes.
    static func progressText(for snapshot: LiveRouteTrackingSnapshot, now: Date) -> String {
        let elapsed = max(now.timeIntervalSince(snapshot.startDate), snapshot.duration)
        let distance = Measurement(value: max(snapshot.distanceMeters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        if let mode = mode(for: snapshot) {
            return "\(mode.title)   \(DurationFormatter.text(for: elapsed))   \(distance)"
        }
        return "\(DurationFormatter.text(for: elapsed))   \(distance)"
    }
}

/// The live-route snapshot for a day, or in debug builds the fake trip
/// `MOVES_FOLLOWED_TRIP_PREVIEW=1` sets up.
@MainActor
func timelineLiveRouteSnapshot(
    for dayTimeline: DayTimeline,
    captureManager: MovesLocationCaptureManager
) -> LiveRouteTrackingSnapshot? {
    #if DEBUG
    if let preview = TimelineFollowedTripPreview.shared.snapshot(for: dayTimeline) {
        return preview
    }
    #endif
    return liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
}

/// When the trip being followed began, for presenting the stay before it as ended.
@MainActor
func timelineFollowedTripStart(
    for dayTimeline: DayTimeline,
    captureManager: MovesLocationCaptureManager
) -> Date? {
    guard Calendar.autoupdatingCurrent.isDateInToday(dayTimeline.dayStart) else { return nil }
    #if DEBUG
    if let started = TimelineFollowedTripPreview.shared.startedAt { return started }
    #endif
    return captureManager.followedTripStartedAt
}

#if DEBUG
/// Debug only: a trip in progress for the simulator, where real capture is off. Starts six
/// minutes ago at today's last stay and adds a fix every five seconds.
@MainActor
final class TimelineFollowedTripPreview: ObservableObject {
    static let shared = TimelineFollowedTripPreview()

    @Published private(set) var startedAt: Date?
    @Published private(set) var fixes: [(date: Date, coordinate: CLLocationCoordinate2D)] = []
    private var timer: Timer?
    private var origin: CLLocationCoordinate2D?

    private init() {
        guard ProcessInfo.processInfo.environment["MOVES_FOLLOWED_TRIP_PREVIEW"] == "1" else { return }
        startedAt = Date.now.addingTimeInterval(-6 * 60)
    }

    func snapshot(for dayTimeline: DayTimeline) -> LiveRouteTrackingSnapshot? {
        guard let startedAt, Calendar.autoupdatingCurrent.isDateInToday(dayTimeline.dayStart) else { return nil }
        if origin == nil {
            let lastPlace = dayTimeline.places.max { $0.arrivalDate < $1.arrivalDate }
            origin = lastPlace?.coordinate ?? CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
            seedFixes()
        }
        guard let origin else { return nil }
        let coordinates = [origin] + fixes.map(\.coordinate)
        return LiveRouteTrackingSnapshot(
            startDate: startedAt,
            latestDate: fixes.last?.date ?? startedAt,
            sampleCount: fixes.count,
            distanceMeters: routeDistance(for: coordinates),
            coordinates: coordinates,
            isFollowedTrip: true
        )
    }

    private func seedFixes() {
        guard let startedAt else { return }
        var date = startedAt
        while date < .now {
            date = date.addingTimeInterval(20)
            appendFix(at: min(date, .now))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in TimelineFollowedTripPreview.shared.appendFix(at: .now) }
        }
    }

    /// A walk at about 1.4 m/s heading north-east with a gentle curve.
    private func appendFix(at date: Date) {
        guard let origin, let startedAt else { return }
        let seconds = date.timeIntervalSince(startedAt)
        let meters = seconds * 1.4
        let bearing = 0.7 + sin(seconds / 120) * 0.4
        let north = cos(bearing) * meters / 111_000
        let east = sin(bearing) * meters / (111_000 * max(cos(origin.latitude * .pi / 180), 0.01))
        fixes.append((date, CLLocationCoordinate2D(latitude: origin.latitude + north, longitude: origin.longitude + east)))
    }
}
#endif

// MARK: - Snapshots

/// Base-map snapshots for the day pages: at most two run at once, the most recently asked
/// for goes first, finished ones are cached, and nothing runs while the app is away.
/// Route overlays are drawn off the main thread on top of the cached base.
@MainActor
final class TimelineMapSnapshotPool {
    static let shared = TimelineMapSnapshotPool()
    private static let maximumRunning = 2

    private struct Pending {
        let task: Task<MKMapSnapshotter.Snapshot, Error>
        var consumers: Set<UUID>
    }

    private var pending: [String: Pending] = [:]
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var isSuspended = false
    private let cache = NSCache<NSString, MKMapSnapshotter.Snapshot>()
    /// Finished page images (base map plus routes), by day, size, and content.
    private let images = NSCache<NSString, UIImage>()

    private init() {
        // Finished images are what paging reuses; base maps only bridge an overlay redraw.
        cache.countLimit = 4
        cache.totalCostLimit = 12 * 1024 * 1024
        images.countLimit = 10
        images.totalCostLimit = 24 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(image, forKey: key as NSString, cost: cost)
    }

    func suspend() {
        isSuspended = true
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: CancellationError()) }
    }

    func resume() {
        isSuspended = false
    }

    func snapshot(options: MKMapSnapshotter.Options, styleKey: Int) async throws -> MKMapSnapshotter.Snapshot {
        guard !isSuspended else { throw CancellationError() }
        let r = options.region
        let key = "\(r.center.latitude)|\(r.center.longitude)|\(r.span.latitudeDelta)|\(r.span.longitudeDelta)|\(options.size.width)|\(options.size.height)|\(options.scale)|\(styleKey)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let consumer = UUID()
        let task: Task<MKMapSnapshotter.Snapshot, Error>
        if var work = pending[key] {
            work.consumers.insert(consumer)
            pending[key] = work
            task = work.task
        } else {
            task = Task { @MainActor in
                try await self.acquireSlot()
                defer { self.releaseSlot() }
                try Task.checkCancellation()
                let snapshotter = MKMapSnapshotter(options: options)
                return try await withTaskCancellationHandler {
                    try await snapshotter.start()
                } onCancel: {
                    snapshotter.cancel()
                }
            }
            pending[key] = Pending(task: task, consumers: [consumer])
        }
        defer { release(key, consumer) }
        return try await withTaskCancellationHandler {
            let snapshot = try await task.value
            try Task.checkCancellation()
            let cost = Int(snapshot.image.size.width * snapshot.image.size.height * snapshot.image.scale * snapshot.image.scale * 4)
            cache.setObject(snapshot, forKey: key as NSString, cost: cost)
            return snapshot
        } onCancel: {
            Task { @MainActor in self.release(key, consumer) }
        }
    }

    private func acquireSlot() async throws {
        if running < Self.maximumRunning {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || isSuspended {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    /// Hands the freed slot to the newest waiter: the page most recently scrolled to.
    private func releaseSlot() {
        if let next = waiters.popLast() {
            next.continuation.resume()
        } else {
            running = max(running - 1, 0)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String, _ consumer: UUID) {
        guard var work = pending[key], work.consumers.remove(consumer) != nil else { return }
        if work.consumers.isEmpty {
            pending[key] = nil
            work.task.cancel()
        } else {
            pending[key] = work
        }
    }
}
