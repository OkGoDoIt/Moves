//
//  MovesTimelineViews.swift
//  Raul
//
//  Timeline, map strip, and row rendering extracted from ContentView.
//

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
    }

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
        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { timeline in
                timeline.dayKey == dayKey
            },
            sortBy: [SortDescriptor(\DayTimeline.dayStart, order: .forward)]
        )

        do {
            descriptor.fetchLimit = 1
            dayTimeline = try modelContext.fetch(descriptor).first
            if dayTimeline == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                if let date = formatter.date(from: dayKey) { dayTimeline = DayTimeline(dayStart: date) }
            }
            loadErrorMessage = dayTimeline == nil ? "Day not found" : nil
        } catch {
            dayTimeline = nil
            loadErrorMessage = "Could not load day"
        }
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
    @State private var presentationCache: DayTimelinePresentationCache
    @State private var mapSelection: TimelineMapSelection?
    @State private var filteredModes: Set<TransportMode> = []
    @State private var expandedHiddenStopIDs: Set<String> = []
    @State private var highlightedEntryID: String?
    @State private var isMapExpanded = false

    init(dayTimeline: DayTimeline, isActive: Bool) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _presentationCache = State(initialValue: Self.makePresentationCache(for: dayTimeline))
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
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
        .onChange(of: dayTimeline.dayKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
            mapSelection = nil
            filteredModes = []
            expandedHiddenStopIDs = []
            highlightedEntryID = nil
            isMapExpanded = false
        }
        .onChange(of: transportSummaryRefreshKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
            // A corrected move can remove the last of a mode, and its chip with it.
            filteredModes.formIntersection(presentationCache.activityBubbleMetrics.map(\.mode))
        }
        .onChange(of: photoStripRefreshKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
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
        .onAppear {
            applyScreenshotAgentFlagsIfNeeded()
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
            isMapExpanded = true
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
                        selection: $mapSelection,
                        collapsedMapHeight: heroHeight,
                        filteredModes: filteredModes,
                        isExpanded: $isMapExpanded
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
                    selection: $mapSelection,
                    fillsAvailableSpace: true,
                    collapsedMapHeight: heroHeight,
                    filteredModes: filteredModes,
                    showsCollapseControl: true,
                    isExpanded: $isMapExpanded
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
                selection: $mapSelection,
                fillsAvailableSpace: true,
                filteredModes: filteredModes,
                isExpanded: .constant(true)
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
            } label: {
                row
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(place.appearsAsShortStop ? .hidden : .automatic)
            .timelinePlaceActions(place)

        case .move(let segment):
            NavigationLink {
                MoveMapDetailView(segment: segment)
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
            } label: {
                detailChevron
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

        case .move(let move):
            NavigationLink {
                MoveMapDetailView(segment: move)
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
            mapSelection = entry.mapSelection
            highlightedEntryID = entry.id
        }
    }

    private func applyMomentJumpIfNeeded() {
        guard isActive, let moment = rootController.requestedJumpMoment else { return }
        let calendar = Calendar.autoupdatingCurrent
        guard calendar.isDate(moment, inSameDayAs: dayTimeline.dayStart) else { return }

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

        mapSelection = target.mapSelection
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

private struct DayTimelinePresentationCache {
    let timelineEntries: [TimelineEntry]
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

private struct DayMapPresentationCache {
    let placeMarkers: [PlaceMarker]
    let latestSampleCoordinate: CLLocationCoordinate2D?
    let routeRefreshKey: String
    let placeRefreshKey: String
    let latestSampleKey: String
}

private struct DayMapRouteCacheEntry {
    let routes: [RenderedRoute]
    let isFullyMatched: Bool
}

@MainActor
private enum DayMapRouteCache {
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
        trimIfNeeded()
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }

    private static func trimIfNeeded() {
        while keysInUseOrder.count > maximumEntryCount {
            let oldest = keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

struct DayMapStrip: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true
    let dayTimeline: DayTimeline
    let isActive: Bool
    @Binding var selection: TimelineMapSelection?
    let fillsAvailableSpace: Bool
    let collapsedMapHeight: CGFloat
    let filteredModes: Set<TransportMode>
    let showsCollapseControl: Bool
    @Binding var isExpanded: Bool
    private static let collapsedMapCornerRadius: CGFloat = 20
    private static let fullScreenMapAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)

    @State private var camera: MapCameraPosition
    @State private var mapRegion: MKCoordinateRegion
    @State private var historicalRoutes: [RenderedRoute]
    @State private var presentationCache: DayMapPresentationCache
    @State private var collapsedSnapshotImage: UIImage?
    /// The live map has had a moment to draw after the page became active, so the
    /// snapshot that stood in for it can fade away.
    @State private var isLiveMapSettled: Bool
    /// Whether the live map is in the hierarchy. Creating and tearing down a map is the
    /// costliest part of changing pages, so it happens a beat after a page settles rather
    /// than in the same frame, which keeps the next swipe responsive.
    @State private var isLiveMapInserted: Bool

    private var placeMarkers: [PlaceMarker] {
        presentationCache.placeMarkers
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var latestSampleCoordinate: CLLocationCoordinate2D? {
        presentationCache.latestSampleCoordinate
    }

    private var displayedRoutes: [RenderedRoute] {
        guard !filteredModes.isEmpty else { return historicalRoutes }
        return historicalRoutes.filter { filteredModes.contains(ActivityBubbleMetrics.chipMode(for: $0.transportMode)) }
    }

    private var historicalRouteCoordinates: [CLLocationCoordinate2D] {
        displayedRoutes.flatMap { $0.coordinates }
    }

    /// Only the active page hosts a live map; neighbouring pages show a snapshot of the
    /// same region, which keeps swiping between days cheap.
    private var showsLiveMap: Bool {
        isLiveMapInserted
    }

    /// The snapshot stands in while the page is inactive, and stays on top of the live map
    /// for a moment after activation so the swap is a cross-fade rather than a flash.
    private var showsSnapshot: Bool {
        !isActive || !isLiveMapInserted || (!isLiveMapSettled && collapsedSnapshotImage != nil)
    }

    /// Expanded / landscape live map may shade by speed when the Map setting
    /// is on. The collapsed hero stays solid mode color, matching its snapshot.
    private var allowsSpeedShading: Bool {
        (fillsAvailableSpace || isExpanded) && shadeRoutesBySpeed
    }

    /// The camera no longer shows the whole day: the person moved it, or it zoomed to a
    /// selected stay or trip.
    private var hasMovedCamera: Bool {
        isActive && (camera.positionedByUser || selection != nil)
    }

    private var historicalRouteRefreshKey: String {
        presentationCache.routeRefreshKey
    }

    private var cameraRefreshKey: String {
        let liveKey = liveRouteSnapshot?.id ?? "none"
        return [presentationCache.routeRefreshKey, presentationCache.placeRefreshKey, liveKey, presentationCache.latestSampleKey].joined(separator: "|")
    }

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        selection: Binding<TimelineMapSelection?> = .constant(nil),
        fillsAvailableSpace: Bool = false,
        collapsedMapHeight: CGFloat = 260,
        filteredModes: Set<TransportMode> = [],
        showsCollapseControl: Bool = false,
        isExpanded: Binding<Bool> = .constant(false)
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _selection = selection
        self.fillsAvailableSpace = fillsAvailableSpace
        self.collapsedMapHeight = collapsedMapHeight
        self.filteredModes = filteredModes
        self.showsCollapseControl = showsCollapseControl
        _isExpanded = isExpanded

        let cache = Self.makePresentationCache(for: dayTimeline)
        let cachedRoutes = DayMapRouteCache.routes(for: cache.routeRefreshKey)
        let renderedRoutes = cachedRoutes?.routes ?? Self.renderedRoutes(for: dayTimeline)
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: renderedRoutes.flatMap { $0.coordinates },
            liveRouteCoordinates: []
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? cache.latestSampleCoordinate.map { [$0] } ?? []
            : allCoordinates
        let initialRegion = MapRegionFactory.region(for: cameraCoordinates)
        _camera = State(initialValue: .region(initialRegion))
        _mapRegion = State(initialValue: initialRegion)
        _historicalRoutes = State(initialValue: renderedRoutes)
        _presentationCache = State(initialValue: cache)
        _isLiveMapSettled = State(initialValue: isActive)
        _isLiveMapInserted = State(initialValue: isActive)
    }

    var body: some View {
        activeMapView
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsAvailableSpace ? .infinity : nil
            )
            .frame(height: fillsAvailableSpace ? nil : collapsedMapHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.collapsedMapCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.collapsedMapCornerRadius, style: .continuous)
                    .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if let callout {
                    TimelineMapCallout(title: callout.title, subtitle: callout.subtitle, tint: callout.tint)
                        .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                mapControls
                    .padding(showsCollapseControl ? 16 : 10)
            }
            .shadow(color: .black.opacity(fillsAvailableSpace && showsCollapseControl ? 0.12 : 0), radius: 18, x: 0, y: 8)
            .animation(Self.fullScreenMapAnimation, value: isExpanded)
            .animation(.easeInOut(duration: 0.2), value: hasMovedCamera)
            .task(id: isActive) {
                await settleLiveMapAfterActivation()
            }
            .task(id: "\(historicalRouteRefreshKey)|\(isActive ? 1 : 0)") {
                guard isActive else { return }
                await refreshHistoricalRouteCoordinates()
            }
            .task(id: cameraRefreshKey) {
                refreshCamera()
            }
            .onChange(of: selection) { _, newSelection in
                refreshCamera(for: newSelection)
            }
            .onChange(of: dayTimeline.dayKey) { _, _ in
                presentationCache = Self.makePresentationCache(for: dayTimeline)
            }
            .onChange(of: moveModesKey) { _, _ in
                presentationCache = Self.makePresentationCache(for: dayTimeline)
            }
            .onChange(of: placeNamesKey) { _, _ in
                presentationCache = Self.makePresentationCache(for: dayTimeline)
            }
    }

    /// Changes when a stay is named, so its marker shows the new name.
    private var placeNamesKey: String {
        dayTimeline.places
            .map { "\($0.id.uuidString)|\($0.userLabel ?? "")|\($0.knownPlace?.name ?? "")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Changes when a move's mode is corrected, so the map redraws it in the new color.
    private var moveModesKey: String {
        dayTimeline.moves
            .map { "\($0.id.uuidString)|\($0.transportModeRawValue)" }
            .sorted()
            .joined(separator: ",")
    }

    private var activeMapView: some View {
        ZStack {
            if showsLiveMap {
                mapView
            }
            if showsSnapshot {
                collapsedMapSnapshotView
                    .allowsHitTesting(!isActive)
                    .transition(.opacity)
            }
        }
    }

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                mapContent
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .onTapGesture(coordinateSpace: .local) { point in
                selectRoute(near: point, proxy: proxy)
            }
        }
        .accessibilityLabel(String(localized: "Day map"))
        .accessibilityHint(String(localized: "Shows the day’s places and how you moved"))
    }

    /// Bottom-trailing map buttons: refit the day once the camera has moved, and
    /// expand or shrink the map.
    @ViewBuilder
    private var mapControls: some View {
        if isActive {
            HStack(spacing: 10) {
                if hasMovedCamera {
                    recentreButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if !fillsAvailableSpace || showsCollapseControl {
                    fullScreenToggleButton(isFullScreen: showsCollapseControl)
                }
            }
        }
    }

    private var recentreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                if selection != nil {
                    selection = nil
                } else {
                    refreshCamera(for: nil)
                }
            }
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
    }

    /// Lets the live map draw under the snapshot before the snapshot fades out.
    @MainActor
    private func settleLiveMapAfterActivation() async {
        guard isActive else {
            isLiveMapSettled = false
            // A neighbour's snapshot shows the fitted day, so the live map starts there too.
            if camera.positionedByUser {
                refreshCamera(for: selection)
            }
            guard isLiveMapInserted else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isLiveMapInserted = false
            return
        }
        guard !isLiveMapSettled else { return }
        if !isLiveMapInserted {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isLiveMapInserted = true
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            isLiveMapSettled = true
        }
    }

    /// A tap on a drawn route selects that trip, the way a tap on a marker selects a stay.
    private func selectRoute(near point: CGPoint, proxy: MapProxy) {
        let tolerance: CGFloat = 22
        // Markers handle their own taps.
        for marker in placeMarkers {
            if let markerPoint = proxy.convert(marker.coordinate, to: .local),
               hypot(markerPoint.x - point.x, markerPoint.y - point.y) < 16 {
                return
            }
        }

        var best: (id: String, distance: CGFloat)?
        for route in displayedRoutes where route.coordinates.count > 1 {
            let points = route.coordinates.compactMap { proxy.convert($0, to: .local) }
            guard points.count > 1 else { continue }
            for (start, end) in zip(points, points.dropFirst()) {
                let distance = Self.distance(from: point, toSegment: start, end)
                if distance < tolerance, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (route.id, distance)
                }
            }
        }

        guard let best, let id = UUID(uuidString: best.id) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .move(id)
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

    private var collapsedMapSnapshotView: some View {
        GeometryReader { proxy in
            let size = CGSize(
                width: max(proxy.size.width, 1),
                height: max(proxy.size.height, 1)
            )

            ZStack {
                if let collapsedSnapshotImage {
                    Image(uiImage: collapsedSnapshotImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(MovesPalette.card.opacity(0.72))
                }
            }
            .task(id: collapsedSnapshotRefreshKey(for: size)) {
                await refreshCollapsedSnapshot(size: size)
            }
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        ForEach(displayedRoutes) { route in
            let isSelected = isSelectedRoute(route)
            let dimsForOtherSelection = selection != nil && !isSelected

            if route.shadowCoordinates.count > 1 {
                ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.shadowCoordinates).enumerated()), id: \.offset) { _, coordinates in
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            route.shadowTint,
                            lineWidth: isSelected ? route.shadowLineWidth + 4 : route.shadowLineWidth
                        )
                }
            }

            if route.coordinates.count > 1 {
                let emphasis = dimsForOtherSelection ? 0.28 : 1.0
                let width = isSelected ? route.lineWidth + 4 : route.lineWidth
                ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.coordinates).enumerated()), id: \.offset) { _, coordinates in
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            route.strokeGradient(shadeBySpeed: allowsSpeedShading, emphasis: emphasis),
                            style: RouteStrokeStyle.make(for: route, lineWidth: width)
                        )
                }
                if let overlayTint = route.recordedOverlayTint {
                    ForEach(Array(RouteCoordinateOps.mapPolylineSegments(route.coordinates).enumerated()), id: \.offset) { _, coordinates in
                        MapPolyline(coordinates: coordinates)
                            .stroke(
                                MovesPalette.opaqueRouteColor(overlayTint, opacity: emphasis),
                                style: RouteStrokeStyle.make(
                                    for: route,
                                    lineWidth: max(width - 2.25, 1.25)
                                )
                            )
                    }
                }
            }
        }

        if let liveRouteSnapshot,
           liveRouteSnapshot.coordinates.count > 1 {
            ForEach(Array(RouteCoordinateOps.mapPolylineSegments(liveRouteSnapshot.coordinates).enumerated()), id: \.offset) { _, coordinates in
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        MovesPalette.opaqueRouteColor(
                            MovesPalette.routeTracking,
                            opacity: selection != nil && !isLiveRouteSelected ? 0.28 : 1
                        ),
                        lineWidth: isLiveRouteSelected ? 9 : 5
                    )
            }
        }

        ForEach(placeMarkers) { marker in
            let isSelected = selection == .place(marker.id)

            if showsBigMarkers && !isSelected {
                Marker(marker.title, coordinate: marker.coordinate)
                    .tint(MovesPalette.place)
            } else {
                Annotation(marker.title, coordinate: marker.coordinate, anchor: .center) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = .place(marker.id)
                        }
                    } label: {
                        MapLocationDot(tint: MovesPalette.place, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(marker.title)
                }
            }
        }

        // Where the person is now, for orientation. It is never part of the fitted camera,
        // so a past day abroad stays framed on that day.
        UserAnnotation()

        if placeMarkers.isEmpty,
           historicalRouteCoordinates.isEmpty,
           (liveRouteSnapshot?.coordinates.isEmpty ?? true),
           let latestSampleCoordinate {
            if showsBigMarkers {
                Marker("Captured location", coordinate: latestSampleCoordinate)
                    .tint(liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking)
            } else {
                Annotation("Captured location", coordinate: latestSampleCoordinate, anchor: .center) {
                    MapLocationDot(
                        tint: liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking,
                        isSelected: isSampleSelected
                    )
                    .accessibilityLabel(String(localized: "Captured location"))
                }
            }
        }
    }

    private var callout: (title: String, subtitle: String, tint: Color)? {
        switch selection {
        case .place(let id):
            guard let marker = placeMarkers.first(where: { $0.id == id }) else { return nil }
            let place = dayTimeline.places.first(where: { $0.id == id })
            let subtitle = place.map { Self.timeString(from: $0.arrivalDate) } ?? marker.title
            return (marker.title, subtitle, MovesPalette.place)
        case .move(let id):
            guard let route = displayedRoutes.first(where: { $0.id == id.uuidString }) else { return nil }
            let move = dayTimeline.moves.first(where: { $0.id == id })
            let subtitle = move.map { DurationFormatter.text(for: $0.timelineDuration) } ?? route.transportMode.title
            return (route.transportMode.title, subtitle, route.tint)
        case .liveRoute:
            return (String(localized: "Live route tracking"), String(localized: "Now"), MovesPalette.routeTracking)
        case .sample:
            return (String(localized: "Captured location"), String(localized: "Now"), MovesPalette.start)
        case nil:
            return nil
        }
    }

    private static func timeString(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private func isSelectedRoute(_ route: RenderedRoute) -> Bool {
        guard case .move(let id) = selection else { return false }
        return route.id == id.uuidString
    }

    private var isLiveRouteSelected: Bool {
        guard case .liveRoute = selection else { return false }
        return true
    }

    private var isSampleSelected: Bool {
        guard case .sample = selection else { return false }
        return true
    }

    private func fullScreenToggleButton(isFullScreen: Bool) -> some View {
        Button {
            withAnimation(Self.fullScreenMapAnimation) {
                isExpanded = !isFullScreen
            }
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

    private var collapsedSnapshotRouteKey: String {
        displayedRoutes.map { route in
            let first = route.coordinates.first
            let last = route.coordinates.last
            let firstKey = first.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"
            let lastKey = last.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"

            return "\(route.id)|\(route.transportMode.rawValue)|\(route.coordinates.count)|\(route.shadowCoordinates.count)|\(firstKey)|\(lastKey)"
        }
        .joined(separator: ",")
    }

    private func collapsedSnapshotRefreshKey(for size: CGSize) -> String {
        [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int(Self.screenScale.rounded()))",
            presentationCache.routeRefreshKey,
            presentationCache.placeRefreshKey,
            presentationCache.latestSampleKey,
            liveRouteSnapshot?.id ?? "none",
            showsBigMarkers ? "big" : "small",
            filteredModes.map(\.rawValue).sorted().joined(separator: ","),
            collapsedSnapshotRouteKey
        ]
        .joined(separator: "|")
    }

    @MainActor
    private func refreshCollapsedSnapshot(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }

        do {
            let image = try await Self.makeCollapsedSnapshot(
                region: mapRegion,
                size: size,
                scale: Self.screenScale,
                routes: displayedRoutes,
                liveRouteSnapshot: liveRouteSnapshot,
                placeMarkers: placeMarkers,
                latestSampleCoordinate: latestSampleCoordinate,
                showsBigMarkers: showsBigMarkers
            )

            guard !Task.isCancelled else { return }
            collapsedSnapshotImage = image
        } catch {
            guard !Task.isCancelled else { return }
            collapsedSnapshotImage = nil
        }
    }

    private static func makeCollapsedSnapshot(
        region: MKCoordinateRegion,
        size: CGSize,
        scale: CGFloat,
        routes: [RenderedRoute],
        liveRouteSnapshot: LiveRouteTrackingSnapshot?,
        placeMarkers: [PlaceMarker],
        latestSampleCoordinate: CLLocationCoordinate2D?,
        showsBigMarkers: Bool
    ) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        // `setRegion:` raises NSException (not a Swift Error) for NaN, Inf,
        // zero span, or a center latitude outside ±90. Always sanitize first.
        options.region = MapRegionFactory.snapshotSafe(region)
        options.size = size
        options.scale = scale

        let snapshot = try await TimelineMapSnapshotPool.shared.snapshot(options: options)

        return renderCollapsedSnapshotOverlay(
            snapshot: snapshot,
            routes: routes,
            liveRouteSnapshot: liveRouteSnapshot,
            placeMarkers: placeMarkers,
            latestSampleCoordinate: latestSampleCoordinate,
            showsBigMarkers: showsBigMarkers
        )
    }

    private static func renderCollapsedSnapshotOverlay(
        snapshot: MKMapSnapshotter.Snapshot,
        routes: [RenderedRoute],
        liveRouteSnapshot: LiveRouteTrackingSnapshot?,
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

            if let liveRouteSnapshot {
                RouteSnapshotStroke.strokePath(
                    coordinates: liveRouteSnapshot.coordinates,
                    in: snapshot,
                    color: UIColor(MovesPalette.routeTracking),
                    lineWidth: 5,
                    dash: []
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
               (liveRouteSnapshot?.coordinates.isEmpty ?? true),
               let latestSampleCoordinate {
                drawMarker(
                    at: snapshot.point(for: latestSampleCoordinate),
                    in: snapshot.image.size,
                    tint: UIColor(liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking),
                    isLarge: showsBigMarkers
                )
            }
        }
    }

    private static func drawMarker(
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

    private static var screenBounds: CGRect {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.screen.bounds
        }

        return windowScenes.first?.screen.bounds ?? CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    private static var screenScale: CGFloat {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.screen.scale
        }

        return windowScenes.first?.screen.scale ?? 2
    }

    @MainActor
    private func refreshHistoricalRouteCoordinates() async {
        if let cached = DayMapRouteCache.routes(for: historicalRouteRefreshKey), cached.isFullyMatched {
            historicalRoutes = cached.routes
            refreshCamera(for: selection)
            return
        }

        let sortedMoves = dayTimeline.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        var renderedRoutes: [RenderedRoute] = []
        renderedRoutes.reserveCapacity(sortedMoves.count)

        for move in sortedMoves {
            let matched = await RoadRouteMatcher.matchedCoordinates(for: move)
            let fractions = await SpeedProfileBuilder.buildAndCache(for: move, coordinates: matched)
            renderedRoutes.append(
                RenderedRoute.make(from: move, coordinates: matched, speedFractions: fractions)
            )
        }

        historicalRoutes = renderedRoutes
        DayMapRouteCache.store(renderedRoutes, for: historicalRouteRefreshKey, isFullyMatched: true)
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to persist matched route cache: \(error.localizedDescription)")
            }
        }
        refreshCamera(for: selection)
    }

    @MainActor
    private func refreshCamera() {
        let liveCoordinates = liveRouteSnapshot?.coordinates ?? []
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: historicalRouteCoordinates,
            liveRouteCoordinates: liveCoordinates
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? presentationCache.latestSampleCoordinate.map { [$0] } ?? []
            : allCoordinates

        if !cameraCoordinates.isEmpty {
            let region = MapRegionFactory.region(for: cameraCoordinates)
            mapRegion = region
            camera = .region(region)
        }
    }

    @MainActor
    private func refreshCamera(for selection: TimelineMapSelection?) {
        let coordinates: [CLLocationCoordinate2D]

        switch selection {
        case .place(let id):
            coordinates = placeMarkers.first(where: { $0.id == id }).map { [$0.coordinate] } ?? []
        case .move(let id):
            coordinates = historicalRoutes.first(where: { $0.id == id.uuidString })?.coordinates ?? []
        case .liveRoute:
            coordinates = liveRouteSnapshot?.coordinates ?? []
        case .sample:
            coordinates = latestSampleCoordinate.map { [$0] } ?? []
        case nil:
            refreshCamera()
            return
        }

        guard !coordinates.isEmpty else { return }
        let region = MapRegionFactory.region(for: coordinates)
        mapRegion = region
        camera = .region(region)
    }

    private static func renderedRoutes(for dayTimeline: DayTimeline) -> [RenderedRoute] {
        let renderedRoutes = dayTimeline.moves
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            .map { move in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)

                return RenderedRoute.make(
                    from: move,
                    coordinates: move.manualRouteCoordinates ?? move.cachedRouteCoordinates(for: signature) ?? fallback
                )
            }
        DayMapRouteCache.store(
            renderedRoutes,
            for: routeRefreshKey(for: dayTimeline),
            isFullyMatched: false
        )
        return renderedRoutes
    }

    private static func allCoordinates(
        for dayTimeline: DayTimeline,
        routeCoordinates: [CLLocationCoordinate2D],
        liveRouteCoordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        let placeCoordinates = mapPlaces(for: dayTimeline).map(\.coordinate)
        return routeCoordinates + liveRouteCoordinates + placeCoordinates
    }

    private static func latestSampleCoordinate(for dayTimeline: DayTimeline) -> CLLocationCoordinate2D? {
        dayTimeline.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .last?
            .coordinate
    }

    private static func makePresentationCache(for dayTimeline: DayTimeline) -> DayMapPresentationCache {
        let sortedPlaces = mapPlaces(for: dayTimeline)
        let placeMarkers = sortedPlaces.map { place in
            let knownName = place.knownPlace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = knownName.isEmpty ? place.displayTitle : knownName
            return PlaceMarker(id: place.id, title: title, coordinate: place.coordinate)
        }
        let placeRefreshKey = sortedPlaces.map { place in
            let arrival = Int(place.arrivalDate.timeIntervalSince1970.rounded())
            let departure = Int((place.departureDate ?? place.arrivalDate).timeIntervalSince1970.rounded())
            return "\(place.id.uuidString)|\(arrival)|\(departure)"
        }
        .joined(separator: ",")

        let sortedSamples = dayTimeline.samples.sorted(by: { $0.timestamp < $1.timestamp })
        let latestSample = sortedSamples.last
        let latestSampleKey = latestSample.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        } ?? "none"

        return DayMapPresentationCache(
            placeMarkers: placeMarkers,
            latestSampleCoordinate: latestSample?.coordinate,
            routeRefreshKey: routeRefreshKey(for: dayTimeline),
            placeRefreshKey: placeRefreshKey,
            latestSampleKey: latestSampleKey
        )
    }

    private static func mapPlaces(for dayTimeline: DayTimeline) -> [VisitPlace] {
        let routePlaces = dayTimeline.moves.flatMap { move in
            [move.startPlace, move.endPlace].compactMap { $0 }
        }
        var placesByID: [UUID: VisitPlace] = [:]

        for place in dayTimeline.displayPlaces + routePlaces {
            placesByID[place.id] = place
        }

        return placesByID.values.sorted(by: { $0.arrivalDate < $1.arrivalDate })
    }

    private static func routeRefreshKey(for dayTimeline: DayTimeline) -> String {
        let sortedMoves = dayTimeline.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        return sortedMoves.map { move in
            let start = Int(move.timelineStartDate.timeIntervalSince1970.rounded())
            let end = Int(move.endDate.timeIntervalSince1970.rounded())
            let sampleKey = Self.refreshSampleKey(for: move.samples)

            return "\(move.id.uuidString)|\(move.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)|\(routeStateKey(for: move))"
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

    private static func refreshSampleKey(for samples: [LocationSample]) -> String {
        samples
            .sorted(by: { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                if lhs.dedupeKey != rhs.dedupeKey { return lhs.dedupeKey < rhs.dedupeKey }
                if lhs.sourceRawValue != rhs.sourceRawValue { return lhs.sourceRawValue < rhs.sourceRawValue }
                if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
                return lhs.longitude < rhs.longitude
            })
            .map { sample in
                "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
            }
            .joined(separator: ",")
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

    var body: some View {
        let period = isCompact ? nil : StorylineClock.periodText(from: date)

        VStack(alignment: .trailing, spacing: 1) {
            Text(StorylineClock.hourMinuteText(from: date))
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
        .accessibilityLabel(Text(date, format: .dateTime.hour().minute()))
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
    @EnvironmentObject private var health: HealthSummaryStore

    /// "Stayed 3h 12m · walked 0.4 mi" when Apple Health shows a real walk inside the stay.
    private var subtitleText: String {
        guard case .place(let place) = entry,
              let meters = health.walkedHereMeters(stayID: place.id) else {
            return entry.subtitleText
        }
        return "\(entry.subtitleText) · \(HealthSummaryText.walkedHere(meters))"
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
            return "live-\(snapshot.id)"
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
            return .liveRoute(snapshot.id)
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
            return snapshot.latestDate
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
            return Self.timeString(from: snapshot.latestDate)
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
        case .liveRoute:
            return "location.fill.viewfinder"
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
        case .liveRoute:
            return MovesPalette.routeTracking
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
        case .liveRoute:
            return String(localized: "Live route tracking")
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

/// Shares bounded base-map snapshots across views. Route overlays are drawn fresh, so an edit
/// cannot return a stale route. The last cancelled consumer stops MapKit's outstanding work.
@MainActor
private final class TimelineMapSnapshotPool {
    static let shared = TimelineMapSnapshotPool()
    private struct Pending {
        let task: Task<MKMapSnapshotter.Snapshot, Error>
        var consumers: Set<UUID>
    }
    private var pending: [String: Pending] = [:]
    private let cache = NSCache<NSString, MKMapSnapshotter.Snapshot>()
    private init() { cache.countLimit = 16; cache.totalCostLimit = 40 * 1024 * 1024 }
    func snapshot(options: MKMapSnapshotter.Options) async throws -> MKMapSnapshotter.Snapshot {
        let r = options.region
        let style = UITraitCollection.current.userInterfaceStyle.rawValue
        let key = "\(r.center.latitude)|\(r.center.longitude)|\(r.span.latitudeDelta)|\(r.span.longitudeDelta)|\(options.size.width)|\(options.size.height)|\(options.scale)|\(style)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let consumer = UUID()
        let task: Task<MKMapSnapshotter.Snapshot, Error>
        if var work = pending[key] {
            work.consumers.insert(consumer)
            pending[key] = work
            task = work.task
        } else {
            task = Task {
                try Task.checkCancellation()
                let snapshotter = MKMapSnapshotter(options: options)
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await snapshotter.start()
                } onCancel: { snapshotter.cancel() }
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
    private func release(_ key: String, _ consumer: UUID) {
        guard var work = pending[key], work.consumers.remove(consumer) != nil else { return }
        if work.consumers.isEmpty { pending[key] = nil; work.task.cancel() }
        else { pending[key] = work }
    }
}
