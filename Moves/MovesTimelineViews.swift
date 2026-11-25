//
//  MovesTimelineViews.swift
//  Raul
//
//  Timeline, map strip, and row rendering extracted from ContentView.
//

import Combine
import Foundation
import MapKit
import SwiftData
import SwiftUI
import UIKit

enum MapMarkerDisplaySettings {
    static let showsBigMarkersKey = "showBigMapMarkers"
}

struct MapLocationDot: View {
    let tint: Color
    var isSelected = false

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle()
                            .stroke(tint, lineWidth: 3)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 1)
            }

            Circle()
                .fill(tint)
                .frame(width: isSelected ? 12 : 8, height: isSelected ? 12 : 8)
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
        }
    }
}

enum TimelineMapSelection: Equatable {
    case place(UUID)
    case move(UUID)
    case liveRoute(String)
    case sample(String)
}

struct DayTimelinePage: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @Environment(\.timelinePageSideInsets) private var sideInsets
    let dayKey: String
    let isActive: Bool

    @State private var dayTimeline: DayTimeline?
    @State private var loadErrorMessage: String?

    var body: some View {
        Group {
            if let dayTimeline {
                // Neighbouring pages render too, so a swipe shows the next day rather than
                // a blank page. Only the active page hosts a live map.
                DayTimelinePageContent(dayTimeline: dayTimeline, isActive: isActive)
                    // Every time on the page, and on the screens it pushes, reads on the
                    // clock where the day happened.
                    .timelineClock(dayTimeline.placeTimeZone)
                    // The stored record replacing a stand-in starts the page afresh. The
                    // page holds no map, only its snapshot spot, so this is cheap.
                    .id(ObjectIdentifier(dayTimeline))
                    .padding(.leading, sideInsets.leading)
                    .padding(.trailing, sideInsets.trailing)
            } else if isActive {
                loadingState
            } else {
                inactiveState
            }
        }
        .task(id: pageLoadKey) {
            await loadDayTimeline()
        }
        .onDisappear {
            releaseLoadedDay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .movesPhotoLibraryDidChange)) { _ in
            guard isActive else { return }
            Task { await loadDayTimeline() }
        }
        // A day shown before it had a record (demo data still seeding, an import, the day's
        // first fix) picks the record up once a save lands, from any context.
        .onReceive(Self.storeChanges) { _ in
            guard isPlaceholder else { return }
            Task { await loadDayTimeline() }
        }
    }

    private static var storeChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    @State private var isPlaceholder = false

    private var pageLoadKey: String {
        "\(dayKey)|\(isActive ? "active" : "inactive")"
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(MovesPalette.routeTracking)

            Text(loadErrorMessage ?? "Loading day")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inactiveState: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func releaseLoadedDay() {
        dayTimeline = nil
        loadErrorMessage = nil
    }

    @MainActor
    private func loadDayTimeline() async {
        do {
            let loaded = try DayTimelinePageLoader.load(dayKey: dayKey, in: modelContext)
            dayTimeline = loaded?.day
            isPlaceholder = loaded?.isPlaceholder ?? false
            loadErrorMessage = dayTimeline == nil ? "Day not found" : nil
        } catch {
            dayTimeline = nil
            isPlaceholder = false
            loadErrorMessage = "Could not load day"
        }
    }
}

/// The stored day for a page, or an unsaved stand-in while the day has no record yet.
enum DayTimelinePageLoader {
    @MainActor
    static func load(dayKey: String, in context: ModelContext) throws -> (day: DayTimeline, isPlaceholder: Bool)? {
        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\DayTimeline.dayStart, order: .forward)]
        )
        descriptor.fetchLimit = 1
        if let stored = try context.fetch(descriptor).first {
            return (stored, false)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayKey) else { return nil }
        return (DayTimeline(dayStart: date), true)
    }
}

/// The Timeline map hero in portrait: about a third of the page with a 200pt minimum, so
/// the day's list gets most of the room. The storyline keeps room for about two rows and the
/// activity chips, and a short display keeps the map within 45% of the page.
enum TimelineHeroLayout {
    static let storylineRoom: CGFloat = 220
    static let pageFraction: CGFloat = 0.36
    static let minimumHeight: CGFloat = 200

    static func collapsedHeight(pageHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let wanted = max(minimumHeight, pageHeight * pageFraction)
        return min(wanted, max(pageHeight * 0.45, pageHeight - storylineRoom))
    }
}

extension EnvironmentValues {
    /// Height of the window the Timeline tab sits in, safe areas included.
    @Entry var timelineScreenHeight: CGFloat = 0
}

struct DayTimelinePageContent: View {
    @Environment(\.timelineScreenHeight) private var screenHeight
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var rootController: MovesRootController
    let dayTimeline: DayTimeline
    let isActive: Bool
    private static let provisionalPlaceNameResolver = CLGeocoderPlaceNameResolver()

    @State private var provisionalSampleResolvedTitle: String?
    @State private var provisionalSampleResolvedKey: String?
    @Environment(TimelineDayMapModel.self) private var dayMap: TimelineDayMapModel?
    #if DEBUG
    @ObservedObject private var followedTripPreview = TimelineFollowedTripPreview.shared
    #endif
    /// Built on first use rather than in `init`, which runs on every parent redraw.
    @State private var cacheBox = DayTimelinePresentationCacheBox()
    @State private var cacheRevision = 0
    @State private var filteredModes: Set<TransportMode> = []
    @State private var expandedHiddenStopIDs: Set<String> = []
    @State private var highlightedEntryID: String?

    init(dayTimeline: DayTimeline, isActive: Bool) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
    }

    private var presentationCache: DayTimelinePresentationCache {
        let _ = cacheRevision
        if let cache = cacheBox.cache { return cache }
        let cache = Self.makePresentationCache(for: dayTimeline)
        cacheBox.cache = cache
        return cache
    }

    private func rebuildPresentationCache() {
        cacheBox.cache = Self.makePresentationCache(for: dayTimeline)
        cacheRevision += 1
    }

    /// The live map's selection belongs to the active page only.
    private var mapSelection: TimelineMapSelection? {
        isActive ? dayMap?.selection : nil
    }

    private func setMapSelection(_ selection: TimelineMapSelection?) {
        guard isActive else { return }
        dayMap?.select(selection)
    }

    private var isMapExpanded: Bool {
        isActive && dayMap?.isExpanded == true
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        timelineLiveRouteSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var followedTripStart: Date? {
        timelineFollowedTripStart(for: dayTimeline, captureManager: captureManager)
    }

    /// Changes as fixes arrive on a trip in progress.
    private var liveRouteKey: String {
        guard let snapshot = liveRouteSnapshot else { return "none" }
        return "\(Int(snapshot.startDate.timeIntervalSince1970))|\(snapshot.coordinates.count)|\(Int(snapshot.latestDate.timeIntervalSince1970))"
    }

    private var liveRouteEntryID: String? {
        liveRouteSnapshot.map { TimelineEntry.liveRoute($0).id }
    }

    /// What the map shows: trips (times, modes, distances), stay names, and photos.
    private var mapContentKey: String {
        "\(transportSummaryRefreshKey)|\(placeNamesKey)|\(photoStripRefreshKey)"
    }

    private var placeNamesKey: String {
        dayTimeline.places
            .map { "\($0.id.uuidString)|\($0.userLabel ?? "")|\($0.knownPlace?.name ?? "")|\(Int($0.arrivalDate.timeIntervalSince1970))|\(Int(($0.departureDate ?? $0.arrivalDate).timeIntervalSince1970))" }
            .sorted()
            .joined(separator: ",")
    }

    private var timelineEntries: [TimelineEntry] {
        var entries = presentationCache.timelineEntries

        if entries.isEmpty, let latestSample = presentationCache.latestSample {
            entries.append(
                .sample(
                    location: latestSample,
                    sampleCount: presentationCache.sortedSamples.count,
                    resolvedName: provisionalSampleTitle(for: latestSample)
                )
            )
        }

        if let liveRouteSnapshot {
            entries.append(.liveRoute(liveRouteSnapshot))
        }

        return entries
    }

    private static func makePresentationCache(for dayTimeline: DayTimeline) -> DayTimelinePresentationCache {
        let places = dayTimeline.places.map(TimelineEntry.place)
        let moves = dayTimeline.moves.map(TimelineEntry.move)
        let samples = dayTimeline.samples.sorted(by: { $0.timestamp < $1.timestamp })
        var entries = (places + moves).sorted { $0.startDate < $1.startDate }
        let repeats = TimelineRepeatedStays.fold(&entries)
        entries = collapseHiddenStops(in: entries)

        if let firstMove = dayTimeline.moves.min(by: { $0.timelineStartDate < $1.timelineStartDate }),
           let startPlace = firstMove.startPlace {
            let hasDayStartPlaceAlready = dayTimeline.places.contains(where: { $0.id == startPlace.id })

            if !hasDayStartPlaceAlready {
                let startEntry = TimelineEntry.start(
                    place: startPlace,
                    timestamp: firstMove.timelineStartDate.addingTimeInterval(-1)
                )

                if let firstMoveIndex = entries.firstIndex(where: { entry in
                    if case .move(let move) = entry {
                        return move.id == firstMove.id
                    }
                    return false
                }) {
                    entries.insert(startEntry, at: firstMoveIndex)
                } else {
                    entries.insert(startEntry, at: 0)
                }
            }
        }

        if entries.isEmpty, let carriedOverPlace = dayTimeline.carriedOverPlace {
            entries.append(.start(place: carriedOverPlace, timestamp: dayTimeline.dayStart))
        }

        return DayTimelinePresentationCache(
            timelineEntries: entries,
            repeatedStays: repeats,
            transportSummaryMetrics: transportSummaryMetrics(for: dayTimeline),
            activityBubbleMetrics: ActivityBubbleMetrics.make(from: dayTimeline),
            sortedSamples: samples
        )
    }

    /// Consecutive short stops become one expander row so the storyline stays readable.
    private static func collapseHiddenStops(in entries: [TimelineEntry]) -> [TimelineEntry] {
        var result: [TimelineEntry] = []
        var pending: [VisitPlace] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            result.append(.hiddenStops(HiddenStopsCluster(places: pending)))
            pending.removeAll(keepingCapacity: true)
        }

        for entry in entries {
            if case .place(let place) = entry, shouldHidePlaceFromTimeline(place) {
                pending.append(place)
            } else {
                flushPending()
                result.append(entry)
            }
        }
        flushPending()
        return result
    }

    private static func shouldHidePlaceFromTimeline(_ place: VisitPlace) -> Bool {
        if place.isHiddenAsShortStop {
            return true
        }
        guard let dayTimeline = place.dayTimeline else { return false }
        return place.matchesShortStopHeuristic(in: dayTimeline)
    }

    private var transportSummaryMetrics: [DayTransportSummaryMetric] {
        presentationCache.transportSummaryMetrics
    }

    private var transportSummaryRefreshKey: String {
        dayTimeline.moves
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { move in
                let start = move.timelineStartDate.timeIntervalSinceReferenceDate
                let end = move.endDate.timeIntervalSinceReferenceDate
                return "\(move.id.uuidString)|\(move.transportModeRawValue)|\(start)|\(end)|\(move.distanceMeters)"
            }
            .joined(separator: ",")
    }

    /// Place origins and photo counts, so inferred visits and thumbnails refresh.
    private var photoStripRefreshKey: String {
        let places = dayTimeline.places
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { place in
                "\(place.id.uuidString)|\(place.originRaw)|\(place.photoAttachments.count)"
            }
            .joined(separator: ",")
        return "\(places)|\(dayTimeline.photos.count)"
    }

    /// Shared with activity bubbles and Insights. Bucketed walking+running stays
    /// available; the bubble row uses per-mode `ActivityBubbleMetrics` instead.
    static func transportSummaryMetrics(for dayTimeline: DayTimeline) -> [DayTransportSummaryMetric] {
        var durationByBucket: [DayTransportBucket: TimeInterval] = [:]
        var distanceByBucket: [DayTransportBucket: CLLocationDistance] = [:]

        for move in dayTimeline.moves {
            guard let bucket = DayTransportBucket(move.transportMode) else { continue }

            durationByBucket[bucket, default: 0] += move.timelineDuration
            distanceByBucket[bucket, default: 0] += max(move.distanceMeters, 0)
        }

        return DayTransportBucket.allCases.compactMap { bucket in
            let distance = distanceByBucket[bucket, default: 0]
            guard distance > 0 else { return nil }

            return DayTransportSummaryMetric(
                id: bucket.rawValue,
                title: bucket.title,
                symbolName: bucket.symbolName,
                tint: bucket.tint,
                duration: durationByBucket[bucket, default: 0],
                distanceMeters: distance
            )
        }
    }

    private var activityBubbleMetrics: [ActivityBubbleMetric] {
        presentationCache.activityBubbleMetrics
    }

    /// Storyline rows including expanded short-stop children.
    /// An expanded cluster is replaced in place so a one-stop expander does
    /// not sit above a second bulky disclosure row.
    private var displayedTimelineEntries: [TimelineEntry] {
        var items: [TimelineEntry] = []
        items.reserveCapacity(timelineEntries.count)
        for entry in timelineEntries {
            if case .hiddenStops(let cluster) = entry,
               expandedHiddenStopIDs.contains(cluster.id) {
                items.append(contentsOf: cluster.places.map(TimelineEntry.place))
            } else {
                items.append(entry)
            }
        }
        return items
    }

    var body: some View {
        GeometryReader { proxy in
            if usesSplitTimeline(proxy) {
                landscapeContent(isShort: proxy.size.height < 300)
            } else {
                portraitContent(pageSize: proxy.size)
            }
        }
        .task(id: provisionalSampleLookupKey) {
            await resolveProvisionalSampleTitle()
        }
        .task(id: momentJumpTaskID) {
            applyMomentJumpIfNeeded()
        }
        .environment(\.timelineFollowedTripStart, followedTripStart)
        .environment(\.timelineRepeatedStays, presentationCache.repeatedStays)
        .onChange(of: dayTimeline.dayKey) { _, _ in
            rebuildPresentationCache()
            filteredModes = []
            expandedHiddenStopIDs = []
            highlightedEntryID = nil
        }
        .onChange(of: transportSummaryRefreshKey) { _, _ in
            rebuildPresentationCache()
            // A corrected move can remove the last of a mode, and its chip with it.
            filteredModes.formIntersection(presentationCache.activityBubbleMetrics.map(\.mode))
        }
        .onChange(of: photoStripRefreshKey) { _, _ in
            rebuildPresentationCache()
        }
        .onChange(of: placeNamesKey) { _, _ in
            rebuildPresentationCache()
        }
        // The one live map follows whichever page is active.
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { return }
            dayMap?.show(dayTimeline, filteredModes: filteredModes, liveRoute: liveRouteSnapshot)
            applyScreenshotAgentFlagsIfNeeded()
        }
        .onChange(of: mapContentKey) { _, _ in
            guard isActive else { return }
            dayMap?.refresh(dayTimeline)
        }
        .onChange(of: filteredModes) { _, modes in
            guard isActive else { return }
            dayMap?.setFilteredModes(modes, for: dayTimeline.dayKey)
        }
        .onChange(of: liveRouteKey) { _, _ in
            guard isActive else { return }
            dayMap?.updateLiveRoute(liveRouteSnapshot, for: dayTimeline.dayKey)
        }
        .onChange(of: mapSelection) { _, selection in
            guard let selection else {
                highlightedEntryID = nil
                return
            }
            if let match = displayedTimelineEntries.first(where: { $0.mapSelection == selection }) {
                highlightedEntryID = match.id
            }
        }
    }

    private func usesSplitTimeline(_ proxy: GeometryProxy) -> Bool {
        if #available(iOS 27.1, *), !proxy.reservedRegions(kind: .division).isEmpty { return true }
        return LandscapeLayoutSettings.usesSplitLayout(proxy.size)
    }

    /// Expands the map for visual review. ContentView owns the one-shot move-detail flag
    /// so adjacent pages cannot repeatedly present competing navigation destinations.
    private func applyScreenshotAgentFlagsIfNeeded() {
        guard isActive else { return }
        let env = ProcessInfo.processInfo.environment
        if env["MOVES_EXPAND_MAP"] == "1" {
            dayMap?.setExpanded(true)
        }

    }

    private var momentJumpTaskID: String {
        let moment = rootController.requestedJumpMoment?.timeIntervalSinceReferenceDate ?? 0
        return "\(dayTimeline.dayKey)|\(isActive ? 1 : 0)|\(moment)"
    }

    private func portraitContent(pageSize: CGSize) -> some View {
        let heroHeight = TimelineHeroLayout.collapsedHeight(
            pageHeight: pageSize.height,
            screenHeight: screenHeight
        )

        return ZStack {
            VStack(spacing: 8) {
                if !isMapExpanded {
                    DayMapStrip(
                        dayTimeline: dayTimeline,
                        isActive: isActive,
                        style: .collapsed,
                        collapsedMapHeight: heroHeight,
                        filteredModes: filteredModes,
                        contentKey: mapContentKey
                    )
                    .padding(.horizontal, 14)

                    storylineList(usesSelection: false)
                        .frame(maxHeight: .infinity, alignment: .top)

                    if !activityBubbleMetrics.isEmpty {
                        ActivityBubblesView(
                            metrics: activityBubbleMetrics,
                            filteredModes: $filteredModes
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, MovesChromeMetrics.timelineTabBarBreathingRoom)
                    }
                }
            }

            if isMapExpanded {
                DayMapStrip(
                    dayTimeline: dayTimeline,
                    isActive: isActive,
                    style: .expanded,
                    collapsedMapHeight: heroHeight,
                    filteredModes: filteredModes,
                    contentKey: mapContentKey
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .safeAreaPadding(.bottom)
    }

    private func landscapeContent(isShort: Bool) -> some View {
        LandscapeSplitView {
            DayMapStrip(
                dayTimeline: dayTimeline,
                isActive: isActive,
                style: .landscape,
                filteredModes: filteredModes,
                contentKey: mapContentKey
            )
        } controlPane: {
            VStack(spacing: 8) {
                if !isShort {
                    HStack {
                        Text("Places & Moves")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Spacer()
                        LandscapePaneSideButton()
                    }
                    .padding(.horizontal, 4)
                }

                storylineList(usesSelection: true)

                HStack(spacing: 4) {
                    if !activityBubbleMetrics.isEmpty {
                        ActivityBubblesView(
                            metrics: activityBubbleMetrics,
                            filteredModes: $filteredModes
                        )
                    }
                    if isShort {
                        Spacer(minLength: 0)
                        LandscapePaneSideButton()
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .safeAreaPadding(.horizontal, 14)
        .safeAreaPadding(.bottom)
    }

    private func storylineList(usesSelection: Bool) -> some View {
        ScrollViewReader { proxy in
            List {
                if displayedTimelineEntries.isEmpty {
                    emptyTimelinePanel
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(displayedTimelineEntries.enumerated()), id: \.element.id) { index, entry in
                        storylineListRow(
                            for: entry,
                            isFirst: index == 0,
                            isLast: index == displayedTimelineEntries.count - 1,
                            usesSelection: usesSelection
                        )
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowBackground(rowBackground(for: entry))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .contentMargins(
                .bottom,
                usesSelection ? 12 : 8,
                for: .scrollContent
            )
            .onChange(of: highlightedEntryID) { _, entryID in
                guard let entryID else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(entryID, anchor: .center)
                }
            }
            // A trip that has just set off is the newest row: bring it into view once.
            .onChange(of: liveRouteEntryID, initial: true) { _, entryID in
                guard let entryID, highlightedEntryID == nil else { return }
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(entryID, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowBackground(for entry: TimelineEntry) -> some View {
        if highlightedEntryID == entry.id || mapSelection == entry.mapSelection {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(entry.iconTint.opacity(0.12))
        } else {
            Color.clear
        }
    }

    private var emptyTimelinePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing recorded yet")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if dayTimeline.samples.count > 0 {
                Text("Waiting for the next visit or move.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Visits and moves will appear as you go.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func storylineListRow(
        for entry: TimelineEntry,
        isFirst: Bool,
        isLast: Bool,
        usesSelection: Bool
    ) -> some View {
        // A row that opens a detail screen must not also carry a tap gesture: SwiftUI hands
        // the tap to the gesture and the enclosing NavigationLink never fires. Those rows
        // select on the map from the map itself; the others still select on tap.
        let opensDetail = !usesSelection && entry.hasDetailScreen
        let row = StorylineRow(
            entry: entry,
            isFirst: isFirst,
            isLast: isLast,
            isHighlighted: highlightedEntryID == entry.id,
            onSelect: opensDetail ? nil : {
                select(entry)
            },
            onCollapseShortStops: collapseHandler(for: entry)
        )

        Group {
            if usesSelection {
                HStack(spacing: 0) {
                    row
                        .frame(maxWidth: .infinity, alignment: .leading)
                    timelineDetailLink(for: entry)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .applyTimelineItemActions(for: entry)
            } else {
                timelineNavigationRow(entry: entry, row: row)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func timelineNavigationRow(entry: TimelineEntry, row: StorylineRow) -> some View {
        switch entry {
        case .place(let place):
            NavigationLink {
                PlaceMapDetailView(place: place)
                    .timelineClock(place.placeTimeZone)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(place.appearsAsShortStop ? .hidden : .automatic)
            .timelinePlaceActions(place)

        case .move(let segment):
            NavigationLink {
                MoveMapDetailView(segment: segment)
                    .timelineClock(segment.placeTimeZone)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .timelineMoveActions(segment)

        case .hiddenStops(let cluster):
            if cluster.places.count == 1, let visit = cluster.places.first {
                row
                    .timelinePlaceActions(visit)
            } else {
                row
            }
        case .liveRoute, .start, .sample:
            row
        }
    }

    @ViewBuilder
    private func timelineDetailLink(for entry: TimelineEntry) -> some View {
        switch entry {
        case .place(let place) where place.appearsAsShortStop:
            EmptyView()
        case .place(let place):
            NavigationLink {
                PlaceMapDetailView(place: place)
                    .timelineClock(place.placeTimeZone)
            } label: {
                detailChevron
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

        case .move(let move):
            NavigationLink {
                MoveMapDetailView(segment: move)
                    .timelineClock(move.placeTimeZone)
            } label: {
                detailChevron
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

        case .hiddenStops, .liveRoute, .start, .sample:
            EmptyView()
        }
    }

    private var detailChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 40)
            .contentShape(Rectangle())
            .accessibilityLabel("Open details")
    }

    private func select(_ entry: TimelineEntry) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if case .hiddenStops(let cluster) = entry {
                if expandedHiddenStopIDs.contains(cluster.id) {
                    expandedHiddenStopIDs.remove(cluster.id)
                } else {
                    expandedHiddenStopIDs.insert(cluster.id)
                }
                return
            }
            setMapSelection(entry.mapSelection)
            highlightedEntryID = entry.id
        }
    }

    private func applyMomentJumpIfNeeded() {
        guard isActive, let moment = rootController.requestedJumpMoment else { return }
        // The moment belongs to this day when it falls on the day's date on the day's clock.
        guard DayTimeline.makeDayKey(for: moment, in: dayTimeline.placeTimeZone) == dayTimeline.dayKey else { return }

        let result = TimelineLocator.locate(
            at: moment,
            visits: dayTimeline.places,
            moves: dayTimeline.moves
        )
        guard let target = TimelineMomentJump.target(from: result) else {
            rootController.requestedJumpMoment = nil
            return
        }

        if let visitID = target.visitID {
            for entry in timelineEntries {
                if case .hiddenStops(let cluster) = entry,
                   cluster.places.contains(where: { $0.id == visitID }) {
                    expandedHiddenStopIDs.insert(cluster.id)
                }
            }
        }

        setMapSelection(target.mapSelection)
        highlightedEntryID = target.entryID
        rootController.requestedJumpMoment = nil
    }

    private var provisionalSampleLookupKey: String {
        guard let latestSample = presentationCache.latestSample else { return "none" }
        return Self.sampleLookupKey(for: latestSample, sampleCount: presentationCache.sortedSamples.count)
    }

    private func provisionalSampleTitle(for sample: LocationSample) -> String? {
        let key = Self.sampleLookupKey(for: sample, sampleCount: presentationCache.sortedSamples.count)
        guard provisionalSampleResolvedKey == key else { return nil }
        return provisionalSampleResolvedTitle
    }

    @MainActor
    private func resolveProvisionalSampleTitle() async {
        let samples = presentationCache.sortedSamples
        guard let latestSample = presentationCache.latestSample else {
            provisionalSampleResolvedKey = nil
            provisionalSampleResolvedTitle = nil
            return
        }

        let key = Self.sampleLookupKey(for: latestSample, sampleCount: samples.count)
        provisionalSampleResolvedKey = key
        provisionalSampleResolvedTitle = nil

        guard latestSample.horizontalAccuracy > 0, latestSample.horizontalAccuracy <= 250 else {
            return
        }

        let resolved = await Self.provisionalPlaceNameResolver.resolveName(for: latestSample.coordinate)
        guard provisionalSampleResolvedKey == key else { return }
        provisionalSampleResolvedTitle = resolved?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sampleLookupKey(for sample: LocationSample, sampleCount: Int) -> String {
        let timestamp = Int(sample.timestamp.timeIntervalSince1970.rounded())
        return "\(sample.dedupeKey)|\(timestamp)|\(sampleCount)"
    }
}

private final class DayTimelinePresentationCacheBox {
    var cache: DayTimelinePresentationCache?
}

private struct DayTimelinePresentationCache {
    let timelineEntries: [TimelineEntry]
    let repeatedStays: [UUID: TimelineRepeatedStay]
    let transportSummaryMetrics: [DayTransportSummaryMetric]
    let activityBubbleMetrics: [ActivityBubbleMetric]
    let sortedSamples: [LocationSample]

    var latestSample: LocationSample? {
        sortedSamples.last
    }
}

struct DayTransportSummaryMetric: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let tint: Color
    let duration: TimeInterval
    let distanceMeters: CLLocationDistance
}

enum DayTransportBucket: String, CaseIterable {
    case walking
    case swimming
    case cycling
    case automotive
    case train
    case plane
    case boat

    init?(_ mode: TransportMode) {
        switch mode {
        case .walking, .running:
            self = .walking
        case .swimming:
            self = .swimming
        case .cycling:
            self = .cycling
        case .automotive:
            self = .automotive
        case .train:
            self = .train
        case .plane:
            self = .plane
        case .boat:
            self = .boat
        case .stationary, .unknown:
            return nil
        }
    }

    var title: String {
        switch self {
        case .walking:
            return "Walking"
        case .swimming:
            return "Swimming"
        case .cycling:
            return "Bike"
        case .automotive:
            return "Car"
        case .train:
            return "Train"
        case .plane:
            return "Plane"
        case .boat:
            return "Boat"
        }
    }

    var symbolName: String {
        switch self {
        case .walking:
            return "figure.walk"
        case .swimming:
            return "figure.pool.swim"
        case .cycling:
            return "figure.outdoor.cycle"
        case .automotive:
            return "car.fill"
        case .train:
            return "tram.fill"
        case .plane:
            return "airplane"
        case .boat:
            return "sailboat.fill"
        }
    }

    var transportMode: TransportMode {
        switch self {
        case .walking:
            return .walking
        case .swimming:
            return .swimming
        case .cycling:
            return .cycling
        case .automotive:
            return .automotive
        case .train:
            return .train
        case .plane:
            return .plane
        case .boat:
            return .boat
        }
    }

    var tint: Color {
        MovesPalette.transport(transportMode)
    }
}

struct DayTransportSummaryView: View {
    let metrics: [DayTransportSummaryMetric]
    let hasData: Bool

    private var totalDuration: TimeInterval {
        metrics.reduce(0) { $0 + $1.duration }
    }

    private var totalDistance: CLLocationDistance {
        metrics.reduce(0) { $0 + $1.distanceMeters }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Day Summary")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            if !hasData {
                Text("No movement summary available yet.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metrics) { metric in
                    summaryRow(metric)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Total")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(DurationFormatter.text(for: totalDuration))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.85))

                    Text(
                        Measurement(value: max(totalDistance, 0), unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road))
                    )
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ metric: DayTransportSummaryMetric) -> some View {
        HStack(spacing: 10) {
            Image(systemName: metric.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18)

            Text(metric.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(DurationFormatter.text(for: metric.duration))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.82))

            Text(
                Measurement(value: max(metric.distanceMeters, 0), unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.82))
        }
        .opacity(metric.duration > 0 || metric.distanceMeters > 0 ? 1 : 0.45)
    }
}

/// Last measured spot of a page's map, kept outside view state so a swipe does not
/// re-evaluate the page.
private final class DayMapSlotFrameBox {
    var frame: CGRect?
}

/// A day page's map spot: a snapshot of the day, and on the active page the place where
/// the Timeline's one live map (`TimelineDayMapModel`) is laid over it.
struct DayMapStrip: View {
    @Environment(TimelineDayMapModel.self) private var liveMap: TimelineDayMapModel?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    let dayTimeline: DayTimeline
    let isActive: Bool
    let style: TimelineDayMapSlot.Style
    let collapsedMapHeight: CGFloat
    let filteredModes: Set<TransportMode>
    /// Changes when the day's stays, trips, names, or modes change.
    let contentKey: String
    private static let cornerRadius: CGFloat = 20

    @State private var content: TimelineDayMapContent?
    @State private var snapshotImage: UIImage?
    @State private var token = UUID()
    @State private var frameBox = DayMapSlotFrameBox()

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        style: TimelineDayMapSlot.Style,
        collapsedMapHeight: CGFloat = 260,
        filteredModes: Set<TransportMode> = [],
        contentKey: String = ""
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        self.style = style
        self.collapsedMapHeight = collapsedMapHeight
        self.filteredModes = filteredModes
        self.contentKey = contentKey
    }

    private var fillsAvailableSpace: Bool { style != .collapsed }

    var body: some View {
        snapshotView
            .frame(maxWidth: .infinity, maxHeight: fillsAvailableSpace ? .infinity : nil)
            .frame(height: fillsAvailableSpace ? nil : collapsedMapHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
            }
            .accessibilityHidden(isActive)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(TimelineDayMapModel.coordinateSpaceName))
            } action: { frame in
                frameBox.frame = frame
                reportSlot()
            }
            .onAppear {
                if content == nil { content = TimelineDayMapContent.make(for: dayTimeline) }
                reportSlot()
            }
            .onDisappear { liveMap?.clearSlot(token: token) }
            .onChange(of: isActive) { _, active in
                if active { reportSlot() } else { liveMap?.clearSlot(token: token) }
            }
            .onChange(of: style) { _, _ in reportSlot() }
            .onChange(of: contentKey) { _, _ in
                content = TimelineDayMapContent.make(for: dayTimeline)
            }
            .onChange(of: liveMap?.routesRevision ?? 0) { _, _ in
                // Matched routes for this day landed in the shared cache.
                guard isActive else { return }
                content = TimelineDayMapContent.make(for: dayTimeline)
            }
    }

    private func reportSlot() {
        guard isActive, let liveMap, let frame = frameBox.frame, frame.width > 1, frame.height > 1 else { return }
        liveMap.reportSlot(TimelineDayMapSlot(dayKey: dayTimeline.dayKey, token: token, frame: frame, style: style))
    }
}

private extension DayMapStrip {
    var snapshotView: some View {
        GeometryReader { proxy in
            let size = CGSize(
                width: max(proxy.size.width, 1),
                height: max(proxy.size.height, 1)
            )

            ZStack {
                if let snapshotImage {
                    Image(uiImage: snapshotImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(MovesPalette.card.opacity(0.72))
                }
            }
            .task(id: snapshotKey(for: size)) {
                await refreshSnapshot(size: size)
            }
        }
    }

    func routeSignature(_ routes: [RenderedRoute]) -> String {
        routes.map { route in
            let first = route.coordinates.first
            let last = route.coordinates.last
            let firstKey = first.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"
            let lastKey = last.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"

            return "\(route.id)|\(route.transportMode.rawValue)|\(route.coordinates.count)|\(route.shadowCoordinates.count)|\(firstKey)|\(lastKey)"
        }
        .joined(separator: ",")
    }

    func snapshotKey(for size: CGSize) -> String {
        guard let content else { return "pending" }
        return [
            content.dayKey,
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int(Self.screenScale.rounded()))",
            colorScheme == .dark ? "dark" : "light",
            content.placeKey,
            content.latestSampleKey,
            showsBigMarkers ? "big" : "small",
            filteredModes.map(\.rawValue).sorted().joined(separator: ","),
            routeSignature(content.displayedRoutes(filteredModes: filteredModes)),
            scenePhase == .active ? "on" : "away"
        ]
        .joined(separator: "|")
    }

    /// Cached per day, size, and content. Never runs while the app is away: leaving the
    /// foreground changes the key, which cancels the request in flight.
    @MainActor
    func refreshSnapshot(size: CGSize) async {
        guard scenePhase == .active, let content, size.width > 1, size.height > 1 else { return }
        let key = snapshotKey(for: size)
        if let cached = TimelineMapSnapshotPool.shared.image(forKey: key) {
            snapshotImage = cached
            return
        }
        guard let region = content.fittedRegion(filteredModes: filteredModes, liveRouteCoordinates: []) else { return }

        let options = MKMapSnapshotter.Options()
        // `setRegion:` raises NSException (not a Swift Error) for NaN, Inf,
        // zero span, or a center latitude outside ±90. Always sanitize first.
        options.region = MapRegionFactory.snapshotSafe(region)
        options.size = size
        options.scale = Self.screenScale
        options.traitCollection = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)

        do {
            let base = try await TimelineMapSnapshotPool.shared.snapshot(
                options: options,
                styleKey: colorScheme == .dark ? 2 : 1
            )
            guard !Task.isCancelled else { return }
            let routes = content.displayedRoutes(filteredModes: filteredModes)
            let markers = content.placeMarkers
            let latest = content.latestSampleCoordinate
            let big = showsBigMarkers
            // Drawing the routes over the base map stays off the main thread.
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderOverlay(
                    snapshot: base,
                    routes: routes,
                    placeMarkers: markers,
                    latestSampleCoordinate: latest,
                    showsBigMarkers: big
                )
            }.value
            guard !Task.isCancelled else { return }
            TimelineMapSnapshotPool.shared.store(image, forKey: key)
            snapshotImage = image
        } catch {
            // Keep the last image; a cancelled request is asked again when the key changes.
        }
    }

    nonisolated static func renderOverlay(
        snapshot: MKMapSnapshotter.Snapshot,
        routes: [RenderedRoute],
        placeMarkers: [PlaceMarker],
        latestSampleCoordinate: CLLocationCoordinate2D?,
        showsBigMarkers: Bool
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)

            for route in routes {
                RouteSnapshotStroke.draw(
                    route,
                    in: snapshot,
                    shadeBySpeed: false,
                    emphasis: 1
                )
            }

            for marker in placeMarkers {
                drawMarker(
                    at: snapshot.point(for: marker.coordinate),
                    in: snapshot.image.size,
                    tint: UIColor(MovesPalette.place),
                    isLarge: showsBigMarkers
                )
            }

            if placeMarkers.isEmpty,
               routes.flatMap(\.coordinates).isEmpty,
               let latestSampleCoordinate {
                drawMarker(
                    at: snapshot.point(for: latestSampleCoordinate),
                    in: snapshot.image.size,
                    tint: UIColor(MovesPalette.start),
                    isLarge: showsBigMarkers
                )
            }
        }
    }

    nonisolated static func drawMarker(
        at point: CGPoint,
        in size: CGSize,
        tint: UIColor,
        isLarge: Bool
    ) {
        let diameter: CGFloat = isLarge ? 14 : 8
        let radius = diameter / 2
        let drawingBounds = CGRect(
            x: -diameter,
            y: -diameter,
            width: size.width + diameter * 2,
            height: size.height + diameter * 2
        )
        guard drawingBounds.contains(point) else { return }

        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: diameter,
            height: diameter
        )
        let path = UIBezierPath(ovalIn: rect)
        tint.setFill()
        path.fill()

        UIColor.white.setStroke()
        path.lineWidth = isLarge ? 2 : 1.5
        path.stroke()
    }

    static var screenScale: CGFloat {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.screen.scale
        }

        return windowScenes.first?.screen.scale ?? 2
    }
}

private extension View {
    /// Swipe / context menu on the list wrapper around `StorylineRow`.
    @ViewBuilder
    func applyTimelineItemActions(for entry: TimelineEntry) -> some View {
        switch entry {
        case .place(let visit):
            timelinePlaceActions(visit)
        case .move(let move):
            timelineMoveActions(move)
        case .hiddenStops(let cluster):
            if cluster.places.count == 1, let visit = cluster.places.first {
                timelinePlaceActions(visit)
            } else {
                self
            }
        default:
            self
        }
    }
}

private extension DayTimelinePageContent {
    func collapseHandler(for entry: TimelineEntry) -> (() -> Void)? {
        guard case .place(let place) = entry,
              let cluster = shortStopCluster(containing: place),
              expandedHiddenStopIDs.contains(cluster.id),
              cluster.places.first?.id == place.id
        else {
            return nil
        }
        return {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedHiddenStopIDs.remove(cluster.id)
            }
        }
    }

    func shortStopCluster(containing place: VisitPlace) -> HiddenStopsCluster? {
        for entry in timelineEntries {
            if case .hiddenStops(let cluster) = entry,
               cluster.places.contains(where: { $0.id == place.id }) {
                return cluster
            }
        }
        return nil
    }
}

/// Compact storyline measurements. Hidden stops must stay shorter than a place row.
enum StorylineCompactMetrics {
    static let hiddenStopRowHeight: CGFloat = 26
    static let shortStopRowHeight: CGFloat = 28
}

/// Visual variant of a storyline row. WS2 keys swipe/menu off this plus the entry.
enum TimelineRowStyle: Equatable {
    case place
    case shortStop
    case move
    case hiddenStops
    case carryOver
    case live
    case sample
}

/// Consecutive short stops collapsed into one expander.
struct HiddenStopsCluster: Identifiable {
    let places: [VisitPlace]

    var id: String {
        places.map(\.id.uuidString).joined(separator: "-")
    }

    var startDate: Date {
        places.map(\.arrivalDate).min() ?? .now
    }

    var totalStayDuration: TimeInterval {
        places.reduce(0) { partial, place in
            let end = place.departureDate ?? place.arrivalDate
            return partial + max(end.timeIntervalSince(place.arrivalDate), 0)
        }
    }

    /// One-line caption such as `· 2m` or `· 2 · 4m`.
    var collapsedCaption: String {
        let durationText = DurationFormatter.compactText(for: totalStayDuration)
        if places.count == 1 {
            return "· \(durationText)"
        }
        return String(localized: "· \(places.count) · \(durationText)")
    }
}

/// One storyline item. Layout lives here; swipe/menu chrome is applied by
/// `.timelinePlaceActions` / `.timelineMoveActions` on the list wrapper so WS2
/// does not rewrite rows.
struct StorylineRow: View {
    let entry: TimelineEntry
    let isFirst: Bool
    let isLast: Bool
    var isHighlighted: Bool = false
    var onSelect: (() -> Void)? = nil
    var onCollapseShortStops: (() -> Void)? = nil

    @EnvironmentObject private var health: HealthSummaryStore

    var style: TimelineRowStyle { entry.rowStyle }

    private var isHealthEstimatedDistance: Bool {
        guard case .move(let segment) = entry else { return false }
        return health.isHealthEstimatedDistance(moveID: segment.id)
    }

    var body: some View {
        Group {
            switch style {
            case .hiddenStops:
                compactHiddenStopRow
            case .shortStop:
                compactShortStopRow
            default:
                standardRow
            }
        }
        .contentShape(Rectangle())
        .modifier(StorylineRowSelectGesture(onSelect: onSelect))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 0) {
            StorylineTimeColumn(date: entry.startDate)
            StorylineRail(
                tint: entry.iconTint,
                iconName: entry.iconName,
                isFirst: isFirst,
                isLast: isLast,
                showsHealthBadge: entry.showsHealthSourceBadge,
                showsEstimatedGlyph: entry.showsEstimatedGlyph || isHealthEstimatedDistance
            )
            StorylineRowBody(entry: entry)
        }
        .padding(.vertical, 2)
    }

    private var compactHiddenStopRow: some View {
        HStack(alignment: .center, spacing: 0) {
            StorylineTimeColumn(date: entry.startDate, isCompact: true)
            compactRail(chevron: "chevron.down", action: nil)
            Text(entry.titleText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .frame(height: StorylineCompactMetrics.hiddenStopRowHeight)
        .accessibilityLabel(entry.accessibilityCaption)
        .accessibilityHint(String(localized: "Shows the short stop"))
        .accessibilityAddTraits(.isButton)
    }

    private var compactShortStopRow: some View {
        HStack(alignment: .center, spacing: 0) {
            StorylineTimeColumn(date: entry.startDate, isCompact: true)
            compactRail(
                chevron: onCollapseShortStops == nil ? nil : "chevron.up",
                action: onCollapseShortStops
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.titleText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let caption = entry.compactStayCaption {
                    Text(caption)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24, maxHeight: StorylineCompactMetrics.shortStopRowHeight)
        .modifier(ShortStopCollapseHint(isEnabled: onCollapseShortStops != nil))
    }

    @ViewBuilder
    private func compactRail(chevron: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : MovesPalette.rail)
                .frame(width: 2, height: 6)
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            action?()
                        }
                    )
                    .accessibilityLabel(
                        chevron == "chevron.up"
                            ? String(localized: "Hide short stop")
                            : String(localized: "Show short stop")
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(action == nil)
            } else {
                Capsule()
                    .fill(MovesPalette.rail)
                    .frame(width: 2, height: 8)
            }
            Rectangle()
                .fill(isLast ? Color.clear : MovesPalette.rail)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 24, height: StorylineCompactMetrics.hiddenStopRowHeight)
    }
}

/// Adds the select-on-tap gesture only for rows that don't open a detail screen.
private struct StorylineRowSelectGesture: ViewModifier {
    let onSelect: (() -> Void)?

    func body(content: Content) -> some View {
        if let onSelect {
            content.onTapGesture(perform: onSelect)
        } else {
            content
        }
    }
}

private struct ShortStopCollapseHint: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityHint(String(localized: "Hides the short stop"))
        } else {
            content
        }
    }
}

private struct StorylineTimeColumn: View {
    let date: Date
    var isCompact: Bool = false
    @ScaledMetric(relativeTo: .caption2) private var columnWidth: CGFloat = 50
    @Environment(\.timeZone) private var timeZone

    private var spoken: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        return style
    }

    var body: some View {
        let period = isCompact ? nil : StorylineClock.periodText(from: date, timeZone: timeZone)

        VStack(alignment: .trailing, spacing: 1) {
            Text(StorylineClock.hourMinuteText(from: date, timeZone: timeZone))
                .font(.system(size: isCompact ? 11 : 12, weight: .semibold, design: .rounded).width(.condensed))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let period {
                Text(period)
                    .font(.system(size: 10, weight: .bold, design: .rounded).width(.condensed))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(isCompact ? Color.secondary.opacity(0.8) : Color.secondary)
        .frame(width: columnWidth, alignment: .trailing)
        .padding(.trailing, 4)
        .padding(.top, isCompact ? 0 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(date, format: spoken))
    }
}

private struct StorylineRail: View {
    let tint: Color
    let iconName: String
    let isFirst: Bool
    let isLast: Bool
    let showsHealthBadge: Bool
    let showsEstimatedGlyph: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : MovesPalette.rail)
                .frame(width: 2, height: 10)

            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                if showsHealthBadge {
                    Circle()
                        .fill(MovesPalette.healthRoute)
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle()
                                .stroke(MovesPalette.card, lineWidth: 1)
                        }
                        .offset(x: 8, y: -8)
                }
                if showsEstimatedGlyph {
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: 8, y: 8)
                }
            }

            Rectangle()
                .fill(isLast ? Color.clear : MovesPalette.rail)
                .frame(width: 2)
                .frame(minHeight: 22, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct StorylineRowBody: View {
    let entry: TimelineEntry
    @Environment(\.timelineItemActions) private var actions
    @Environment(\.timelineFollowedTripStart) private var followedTripStart
    @Environment(\.timelineRepeatedStays) private var repeatedStays
    @EnvironmentObject private var health: HealthSummaryStore

    /// "Stayed 3h 12m · walked 0.4 mi" when Apple Health shows a real walk inside the stay.
    private var subtitleText: String {
        guard case .place(let place) = entry else { return entry.subtitleText }
        let stayed = TimelineStayPresentation.subtitle(
            arrival: place.arrivalDate,
            departure: place.departureDate,
            followedTripStart: followedTripStart,
            repeated: repeatedStays[place.id]
        )
        guard let meters = health.walkedHereMeters(stayID: place.id) else { return stayed }
        return "\(stayed) · \(HealthSummaryText.walkedHere(meters))"
    }

    private var isHealthEstimatedDistance: Bool {
        guard case .move(let segment) = entry else { return false }
        return health.isHealthEstimatedDistance(moveID: segment.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.titleText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(2)

                if entry.showsAutoAssignmentMark {
                    Text("Auto")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(MovesPalette.place)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MovesPalette.place.opacity(0.14)))
                }

                if entry.showsAmbiguousChooser {
                    Text("Choose")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(MovesPalette.start)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MovesPalette.start.opacity(0.14)))
                }
            }

            if case .move(let segment) = entry, let actions {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TransportModeMenu(move: segment, actions: actions)
                        moveDetails
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        TransportModeMenu(move: segment, actions: actions)
                        moveDetails
                    }
                }
            } else if case .place(let place) = entry, let actions, TimelinePlaceNaming.needsName(place) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.68))
                    NameThisPlaceChip {
                        actions.requestRename(place)
                    }
                }
            } else if case .liveRoute(let snapshot) = entry, snapshot.isFollowedTrip, snapshot.sampleCount > 0 {
                // Keeps counting between fixes; only this text redraws.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TimelineLiveTrip.progressText(for: snapshot, now: context.date))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.68))
                        .monospacedDigit()
                }
            } else {
                Text(subtitleText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.68))
            }

            if let tertiary = entry.tertiaryText {
                Text(tertiary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if case .place(let place) = entry, !place.appearsAsShortStop {
                VisitPhotoThumbnailStrip(attachments: place.photoAttachments)
            }
        }
        .padding(.leading, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moveDetails: some View {
        Text(entry.moveDetailsText(healthEstimatedDistance: isHealthEstimatedDistance))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.68))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A later stay at the same place with nothing in between, shown as part of the first row.
struct TimelineRepeatedStay: Equatable {
    /// How many stored stays the row stands for, the first included.
    var count: Int
    /// The last of them; nil while it is still open.
    var departure: Date?
    var lastArrival: Date
}

enum TimelineRepeatedStays {
    /// Folds a stay that directly follows a stay at the same place (no trip between) into
    /// the first one's row, and returns what each kept row stands for. Nothing is deleted:
    /// the row says how many stays it covers.
    static func fold(_ entries: inout [TimelineEntry]) -> [UUID: TimelineRepeatedStay] {
        var result: [TimelineEntry] = []
        var repeats: [UUID: TimelineRepeatedStay] = [:]
        for entry in entries {
            if case .place(let next) = entry,
               case .place(let kept)? = result.last,
               isSamePlace(kept, next) {
                var repeated = repeats[kept.id] ?? TimelineRepeatedStay(count: 1, departure: kept.departureDate, lastArrival: kept.arrivalDate)
                repeated.count += 1
                repeated.departure = next.departureDate
                repeated.lastArrival = next.arrivalDate
                repeats[kept.id] = repeated
                continue
            }
            result.append(entry)
        }
        entries = result
        return repeats
    }

    static func isSamePlace(_ a: VisitPlace, _ b: VisitPlace) -> Bool {
        guard !a.appearsAsShortStop, !b.appearsAsShortStop else { return false }
        // A stay the person split, or made, stays two rows.
        guard a.origin != .manual, b.origin != .manual else { return false }
        if let left = a.knownPlace?.id, let right = b.knownPlace?.id { return left == right }
        // Same name on the row, and close enough that the name is not a coincidence.
        let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        return distance < 500 && rowTitle(a) == rowTitle(b)
    }

    private static func rowTitle(_ place: VisitPlace) -> String {
        let known = place.knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return known.isEmpty ? place.displayTitle : known
    }
}

/// How a stay row reads its length.
enum TimelineStayPresentation {
    /// "Stayed 2h 2m", or "In progress" for an open stay. While a trip is being followed,
    /// an open stay that began before it reads as ended when the trip set off.
    static func subtitle(
        arrival: Date,
        departure: Date?,
        followedTripStart: Date?,
        repeated: TimelineRepeatedStay?
    ) -> String {
        let end = repeated.map { $0.departure } ?? departure
        let closedAt = end ?? followedTripStart.flatMap { $0 > arrival ? $0 : nil }
        guard let closedAt else { return String(localized: "In progress") }
        let stayed = String(localized: "Stayed \(DurationFormatter.text(for: closedAt.timeIntervalSince(arrival)))")
        guard let repeated, repeated.count > 1 else { return stayed }
        return String(localized: "\(stayed) · \(repeated.count) stays recorded")
    }
}

extension EnvironmentValues {
    /// When today's followed trip began, while one is under way.
    @Entry var timelineFollowedTripStart: Date? = nil
    /// Rows that stand for several back-to-back stays at one place.
    @Entry var timelineRepeatedStays: [UUID: TimelineRepeatedStay] = [:]
}

/// When a stay still goes by a street address or coordinates.
enum TimelinePlaceNaming {
    /// A stay with no name of the person's own and no learned place behind it. Short stops
    /// stay quiet; they are usually traffic lights and doorways.
    static func needsName(_ place: VisitPlace) -> Bool {
        let userLabel = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard userLabel.isEmpty else { return false }
        let knownName = place.knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard knownName.isEmpty else { return false }
        return !place.isHiddenAsShortStop
    }
}

/// The row's way into naming a stay. Same capsule as the mode chip on a trip row.
struct NameThisPlaceChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .bold))
                Text(String(localized: "Name this place"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(MovesPalette.place)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(MovesPalette.place.opacity(0.14)))
            // A taller touch target that doesn't change the row's height.
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
        }
        .buttonStyle(.plain)
    }
}

enum TimelineEntry: Identifiable {
    case place(VisitPlace)
    case move(MoveSegment)
    case liveRoute(LiveRouteTrackingSnapshot)
    case start(place: VisitPlace, timestamp: Date)
    case sample(location: LocationSample, sampleCount: Int, resolvedName: String?)
    case hiddenStops(HiddenStopsCluster)

    var id: String {
        switch self {
        case .place(let place):
            return "place-\(place.id.uuidString)"
        case .move(let segment):
            return "move-\(segment.id.uuidString)"
        case .liveRoute(let snapshot):
            // Stable while fixes arrive, so the row and its selection survive each one.
            return "live-\(Int(snapshot.startDate.timeIntervalSince1970))"
        case .start(let place, let timestamp):
            return "start-\(place.id.uuidString)-\(timestamp.timeIntervalSince1970)"
        case .sample(let location, _, _):
            return "sample-\(location.dedupeKey)-\(location.timestamp.timeIntervalSince1970)"
        case .hiddenStops(let cluster):
            return "hidden-\(cluster.id)"
        }
    }

    var rowStyle: TimelineRowStyle {
        switch self {
        case .place(let place):
            return place.appearsAsShortStop ? .shortStop : .place
        case .move: return .move
        case .hiddenStops: return .hiddenStops
        case .start: return .carryOver
        case .liveRoute: return .live
        case .sample: return .sample
        }
    }

    /// Whether tapping the row opens a detail screen. Only those rows show a chevron.
    var hasDetailScreen: Bool {
        switch self {
        case .place, .move:
            return true
        case .hiddenStops, .liveRoute, .start, .sample:
            return false
        }
    }

    var mapSelection: TimelineMapSelection {
        switch self {
        case .place(let place):
            return .place(place.id)
        case .move(let segment):
            return .move(segment.id)
        case .liveRoute(let snapshot):
            return .liveRoute("live-\(Int(snapshot.startDate.timeIntervalSince1970))")
        case .start(let place, _):
            return .place(place.id)
        case .sample(let location, _, _):
            return .sample(location.dedupeKey)
        case .hiddenStops(let cluster):
            if let first = cluster.places.first {
                return .place(first.id)
            }
            return .sample(cluster.id)
        }
    }

    var startDate: Date {
        switch self {
        case .place(let place):
            return place.arrivalDate
        case .move(let segment):
            return segment.timelineStartDate
        case .liveRoute(let snapshot):
            return snapshot.startDate
        case .start(_, let timestamp):
            return timestamp
        case .sample(let location, _, _):
            return location.timestamp
        case .hiddenStops(let cluster):
            return cluster.startDate
        }
    }

    var clockText: String {
        switch self {
        case .place(let place):
            return Self.timeString(from: place.arrivalDate)
        case .move(let segment):
            return Self.timeString(from: segment.timelineStartDate)
        case .liveRoute(let snapshot):
            return Self.timeString(from: snapshot.startDate)
        case .start(_, let timestamp):
            return Self.timeString(from: timestamp)
        case .sample(let location, _, _):
            return Self.timeString(from: location.timestamp)
        case .hiddenStops(let cluster):
            return Self.timeString(from: cluster.startDate)
        }
    }

    var iconName: String {
        switch self {
        case .place(let place):
            return place.origin == .photoInferred ? "camera.fill" : "mappin.circle.fill"
        case .move(let segment):
            return segment.transportMode.symbolName
        case .liveRoute(let snapshot):
            return TimelineLiveTrip.iconName(for: snapshot)
        case .start:
            return "sunrise.fill"
        case .sample:
            return "mappin.circle.fill"
        case .hiddenStops:
            return "minus"
        }
    }

    var iconTint: Color {
        switch self {
        case .place:
            return MovesPalette.place
        case .move(let segment):
            return segment.routeDisplayTint
        case .liveRoute(let snapshot):
            return TimelineLiveTrip.tint(for: snapshot)
        case .start:
            return MovesPalette.start
        case .sample:
            return MovesPalette.place
        case .hiddenStops:
            return MovesPalette.rail
        }
    }

    var showsHealthSourceBadge: Bool {
        switch self {
        case .move(let segment):
            return segment.usesHealthWorkoutRoute
        default:
            return false
        }
    }

    var showsEstimatedGlyph: Bool {
        switch self {
        case .move(let segment):
            return segment.routeMatchConfidence == .estimated
        default:
            return false
        }
    }

    var showsAutoAssignmentMark: Bool {
        switch self {
        case .place(let place):
            return place.assignmentSource == .auto
        default:
            return false
        }
    }

    var showsAmbiguousChooser: Bool {
        switch self {
        case .place(let place):
            return place.assignmentSource == .autoAmbiguous
        default:
            return false
        }
    }

    var titleText: String {
        switch self {
        case .start(let place, _):
            return "Start at \(Self.placeTitle(place))"
        case .place(let place):
            return Self.placeTitle(place)
        case .move(let segment):
            let start = segment.startPlace.map(Self.placeTitle) ?? String(localized: "Unknown start")
            let end = segment.endPlace.map(Self.placeTitle) ?? String(localized: "Unknown destination")
            return "\(start) to \(end)"
        case .liveRoute(let snapshot):
            return snapshot.isFollowedTrip
                ? String(localized: "Trip in progress")
                : String(localized: "Route tracking")
        case .sample(let location, _, let resolvedName):
            if let resolvedName,
               !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resolvedName
            }
            return Self.coordinateString(
                latitude: location.latitude,
                longitude: location.longitude
            )
        case .hiddenStops(let cluster):
            return cluster.collapsedCaption
        }
    }

    /// Spoken description for the collapsed short-stop hairline.
    var accessibilityCaption: String {
        switch self {
        case .hiddenStops(let cluster):
            let duration = DurationFormatter.compactText(for: cluster.totalStayDuration)
            if cluster.places.count == 1 {
                return String(localized: "Short stop, \(duration)")
            }
            return String(localized: "\(cluster.places.count) short stops, \(duration)")
        default:
            return titleText
        }
    }

    /// Stay caption for a compact short-stop row. Sub-minute stays are omitted.
    var compactStayCaption: String? {
        guard case .place(let place) = self else { return nil }
        guard let departure = place.departureDate else { return nil }
        let duration = departure.timeIntervalSince(place.arrivalDate)
        guard duration >= 60 else { return nil }
        return DurationFormatter.compactText(for: duration)
    }

    var subtitleText: String {
        switch self {
        case .start:
            return String(localized: "Carried over from previous day")

        case .place(let place):
            guard let departure = place.departureDate else {
                return String(localized: "In progress")
            }
            return String(localized: "Stayed \(DurationFormatter.text(for: departure.timeIntervalSince(place.arrivalDate)))")

        case .move(let segment):
            return "\(segment.transportMode.title)   \(moveDetailsText)"
        case .liveRoute(let snapshot):
            let duration = DurationFormatter.text(for: snapshot.duration)
            let distance = Measurement(value: max(snapshot.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))

            if snapshot.isFollowedTrip {
                return snapshot.sampleCount == 0
                    ? String(localized: "Just set off")
                    : TimelineLiveTrip.progressText(for: snapshot, now: snapshot.latestDate)
            }

            if snapshot.sampleCount == 0 {
                return String(localized: "Waiting for the first live GPS fix")
            }

            return "\(snapshot.sampleCount) live fixes   \(duration)   \(distance)"
        case .sample:
            return String(localized: "In progress")
        case .hiddenStops:
            return ""
        }
    }

    /// A move's time, distance, and route notes, without its mode.
    var moveDetailsText: String { moveDetailsText(healthEstimatedDistance: false) }

    /// `healthEstimatedDistance`: the distance came from Apple Health rather than the path.
    /// It reads "Estimated" like an estimated path, once, so there is one treatment.
    func moveDetailsText(healthEstimatedDistance: Bool) -> String {
        guard case .move(let segment) = self else { return "" }
        let duration = DurationFormatter.text(for: segment.timelineDuration)
        let distance = Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        var details = [duration, distance]
        if segment.usesHealthWorkoutRoute {
            details.append(String(localized: "Apple Health"))
        }
        if segment.routeMatchConfidence == .estimated || healthEstimatedDistance {
            details.append(String(localized: "Estimated"))
        }
        return details.joined(separator: "   ")
    }

    var tertiaryText: String? {
        switch self {
        case .place(let place) where place.origin == .photoInferred:
            return String(localized: "From photos")
        case .move(let segment):
            var details: [String] = []

            if let stepCount = segment.stepCount, stepCount > 0 {
                details.append("\(stepCount.formatted(.number)) steps")
            }

            if let averageSpeed = Self.averageSpeedText(for: segment) {
                details.append(averageSpeed)
            }

            return details.isEmpty ? nil : details.joined(separator: "   ")
        case .liveRoute(let snapshot):
            if snapshot.isFollowedTrip { return nil }
            if snapshot.sampleCount == 0 {
                return String(localized: "Tracking will start as soon as GPS provides the first fix.")
            }
            return String(localized: "Last update \(snapshot.latestDate.formatted(date: .omitted, time: .shortened))")
        case .sample(_, let sampleCount, _):
            if sampleCount == 1 {
                return String(localized: "1 location sample captured")
            }
            return String(localized: "\(sampleCount) location samples captured")
        default:
            return nil
        }
    }

    private static func placeTitle(_ place: VisitPlace) -> String {
        let known = place.knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !known.isEmpty {
            return known
        }
        return place.displayTitle
    }

    private static func averageSpeedText(for segment: MoveSegment) -> String? {
        guard segment.timelineDuration > 0 else { return nil }

        let speed = Measurement(value: max(segment.distanceMeters, 0) / segment.timelineDuration, unit: UnitSpeed.metersPerSecond)
        let unit: UnitSpeed = Locale.autoupdatingCurrent.measurementSystem == .metric ? .kilometersPerHour : .milesPerHour
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: speed.converted(to: unit))
    }

    private static func timeString(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private static func coordinateString(latitude: Double, longitude: Double) -> String {
        let latitudeText = String(format: "%.5f", latitude)
        let longitudeText = String(format: "%.5f", longitude)
        return "\(latitudeText), \(longitudeText)"
    }
}

struct PlaceMarker: Identifiable {
    let id: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
}

