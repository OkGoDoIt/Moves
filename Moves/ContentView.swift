import Combine
import CoreData
import CoreLocation
import CoreTransferable
import Foundation
import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum TrackingPromptAction {
    case requestAuthorization
    case openSettings
}

private struct TrackingPermissionPrompt {
    let title: String
    let message: String
    let buttonTitle: String?
    let action: TrackingPromptAction?
}

enum TrackingStatusBannerContext {
    case timeline
    case settings
}

enum LandscapeLayoutSettings {
    static let controlsOnLeftKey = "landscapeControlsOnLeft"

    static func usesSplitLayout(_ size: CGSize) -> Bool {
        size.width >= 600
    }

    static func controlPaneWidth(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.42, 280), min(420, size.width * 0.5))
    }
}

struct LandscapeSplitView<MapPane: View, ControlPane: View>: View {
    @AppStorage(LandscapeLayoutSettings.controlsOnLeftKey) private var controlsOnLeft = false
    @Environment(\.layoutDirection) private var direction

    let spacing: CGFloat
    @ViewBuilder let mapPane: () -> MapPane
    @ViewBuilder let controlPane: () -> ControlPane

    init(
        spacing: CGFloat = 10,
        @ViewBuilder mapPane: @escaping () -> MapPane,
        @ViewBuilder controlPane: @escaping () -> ControlPane
    ) {
        self.spacing = spacing
        self.mapPane = mapPane
        self.controlPane = controlPane
    }

    var body: some View {
        GeometryReader { proxy in
            if #available(iOS 27.1, *) {
                ArrangementView {
                    mapPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.layoutDirection, direction)
                } secondary: {
                    controlPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.layoutDirection, direction)
                }
                .arrangementViewStyle(.split)
                .environment(\.layoutDirection, controlsOnLeft && proxy.size.width > proxy.size.height ? .rightToLeft : direction)
            } else {
                let horizontal = proxy.size.width > proxy.size.height
                let layout = horizontal
                    ? AnyLayout(HStackLayout(spacing: spacing))
                    : AnyLayout(VStackLayout(spacing: spacing))
                layout {
                    mapPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.layoutDirection, direction)
                    controlPane()
                        .frame(width: horizontal ? LandscapeLayoutSettings.controlPaneWidth(for: proxy.size) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.layoutDirection, direction)
                }
                .environment(\.layoutDirection, horizontal && controlsOnLeft ? .rightToLeft : direction)
            }
        }
    }
}

/// The system moves detail controls below or beside the map when the display folds.
/// The controls and map keep their identity as the arrangement changes.
@available(iOS 27.1, *)
struct MovesDetailArrangement<MapPane: View, Controls: View>: View {
    @ViewBuilder var map: () -> MapPane
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        ArrangementView {
            MovesArrangementControls(content: controls)
        } secondary: {
            map()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .arrangementViewStyle(.overlay)
    }
}

@available(iOS 27.1, *)
private struct MovesArrangementControls<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 460)
            .frame(height: min(320, max(proxy.size.height - 24, 0)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct LandscapePaneSideButton: View {
    @AppStorage(LandscapeLayoutSettings.controlsOnLeftKey) private var controlsOnLeft = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                controlsOnLeft.toggle()
            }
        } label: {
            Label(
                controlsOnLeft ? "Put controls on right" : "Put controls on left",
                systemImage: controlsOnLeft
                    ? "rectangle.righthalf.inset.filled"
                    : "rectangle.lefthalf.inset.filled"
            )
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frostedCircle(enabled: true)
        .accessibilityLabel(controlsOnLeft ? "Put controls on right" : "Put controls on left")
        .help(controlsOnLeft ? "Put controls on right" : "Put controls on left")
    }
}

struct TrackingStatusBannerData {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    let buttonTitle: String?
    let buttonRole: ButtonRole?

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        buttonTitle: String? = nil,
        buttonRole: ButtonRole? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.buttonRole = buttonRole
    }
}

struct TrackingStatusBanner: View {
    let data: TrackingStatusBannerData
    let buttonAction: (() -> Void)?

    init(
        data: TrackingStatusBannerData,
        buttonAction: (() -> Void)? = nil
    ) {
        self.data = data
        self.buttonAction = buttonAction
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.systemImage)
                .foregroundStyle(data.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(data.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = data.buttonTitle,
               let buttonAction {
                Button(buttonTitle, role: data.buttonRole) {
                    buttonAction()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

@MainActor
func trackingStatusBannerData(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
    let routeTracking = RouteTrackingControl(captureManager: captureManager)
    // The debug Route Tracking preview stands in for capture in the simulator's demo mode.
    if routeTracking.preview.isActive, routeTracking.isRunning() {
        return routeTrackingBanner(routeTracking, context: context)
    }

    if captureManager.isDemoMode {
        return nil
    }

    if let lastErrorMessage = captureManager.lastErrorMessage {
        return TrackingStatusBannerData(
            title: "Location tracking error",
            message: lastErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    if routeTracking.isRunning() {
        return routeTrackingBanner(routeTracking, context: context)
    }

    if !captureManager.isBackgroundLocationListeningEnabled {
        switch captureManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Location tracking is turned off",
                message: "Moves is not listening for visits or significant location changes. Turn it back on in Route Tracking settings.",
                systemImage: "location.slash",
                tint: .secondary
            )
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    guard context == .settings else {
        return nil
    }

    switch captureManager.authorizationStatus {
    case .authorizedAlways:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Background tracking is enabled.",
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Moves can read location while open. Grant Always to keep recording in the background.",
            systemImage: "location.fill",
            tint: MovesPalette.start
        )
    case .notDetermined:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Open Moves to allow location access and start recording.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .denied:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Enable location in Settings if you want Moves to record visits and movement.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .restricted:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "This device does not allow location access for Moves.",
            systemImage: "lock.fill",
            tint: .secondary
        )
    @unknown default:
        return TrackingStatusBannerData(
            title: "Unknown location state",
            message: "Moves could not determine the current location permission state.",
            systemImage: "questionmark.circle",
            tint: .secondary
        )
    }
}

/// "Route Tracking is on" / "On until 6:00 PM", with Stop on the timeline.
@MainActor
private func routeTrackingBanner(
    _ routeTracking: RouteTrackingControl,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData {
    var message = routeTracking.statusText()
    if routeTracking.authorization == .authorizedWhenInUse {
        message += String(localized: " while Moves is open")
    }
    return TrackingStatusBannerData(
        title: String(localized: "Route Tracking is on"),
        message: message,
        systemImage: "location.fill.viewfinder",
        tint: MovesPalette.routeTracking,
        buttonTitle: context == .timeline ? String(localized: "Stop") : nil,
        buttonRole: context == .timeline ? .destructive : nil
    )
}

struct ContentView: View {
    @State private var screenHeight: CGFloat = 0
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @EnvironmentObject private var rootController: MovesRootController
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var dayTimelines: [TimelineBrowsingDay] = []
    /// The time zone `dayTimelines` was laid out in.
    @State private var dayIndexTimeZone: TimeZone?
    @State private var spotlightRefreshTask: Task<Void, Never>?
    @State private var lastSpotlightSignature: [String] = []
    @State private var didOpenScreenshotMove = false
    @State private var didOpenInitialDay = false
    @ObservedObject private var routeTrackingPreview = RouteTrackingPreview.shared

    private var routeTracking: RouteTrackingControl {
        RouteTrackingControl(captureManager: captureManager, preview: routeTrackingPreview)
    }
    /// Set when the app goes to the background; coming back from there opens today again.
    @State private var wentToBackground = false

    @State private var selectedDayKey = ""
    @State private var selectedPageIndex = 0

    @State private var selectedDay: DayTimeline?
    @State private var todayTimeline: DayTimeline?

    /// The page the horizontal pager is showing or scrolling towards. It follows the finger;
    /// `selectedPageIndex` only changes once the pager comes to rest, so a page never
    /// activates (or swaps in its live map) halfway through a swipe.
    @State private var pagerDayKey: String?
    @State private var isPagerMoving = false
    /// Today was tapped while a swipe was still moving.
    @State private var returnsToTodayOnceSettled = false
    /// Set once the pager has been placed on the selected day, so the scroll view's first
    /// report (its leading page) is not mistaken for a swipe.
    @State private var isPagerPositioned = false
    /// The page width is changing (rotation, a resize); positions reported meanwhile are not swipes.
    @State private var isPagerResizing = false
    @State private var pagerWidth = 0
    @State private var pagerRest = PagerRest()

    /// Every calendar day, keyed by its stable day key. The set of pages never changes
    /// while a swipe is in flight, so the pager always settles on exactly one page.
    private var dayPager: some View {
        ScrollViewReader { proxy in
            dayPagerScrollView
                .onScrollPhaseChange { _, phase in
                    isPagerMoving = phase != .idle
                    if phase == .idle {
                        // A swipe interrupted part-way (a redraw landing mid-swipe) can leave
                        // the pager resting between two days. It never stays there.
                        if settlePagerIfBetweenPages(proxy) { return }
                        commitPagerPosition()
                        returnToTodayIfRequested()
                    }
                }
        }
    }

    /// Where the pager rests. A plain object, so following the scroll redraws nothing.
    private final class PagerRest {
        var offset: CGFloat = 0
        var pageWidth: CGFloat = 0
    }

    private struct PagerOffset: Equatable {
        var offset: CGFloat
        var pageWidth: CGFloat
    }

    /// Scrolls to the nearest day when the pager has stopped between two. Returns whether it did.
    private func settlePagerIfBetweenPages(_ proxy: ScrollViewProxy) -> Bool {
        let width = pagerRest.pageWidth
        guard isPagerPositioned, !isPagerResizing, width > 0 else { return false }
        let position = pagerRest.offset / width
        let nearest = position.rounded()
        guard abs(position - nearest) > 0.02 else { return false }
        let index = Int(nearest)
        guard dayTimelines.indices.contains(index) else { return false }
        Self.pagerLog.notice("Pager rested between days at \(position, format: .fixed(precision: 2)); settling on the nearest")
        let key = dayTimelines[index].dayKey
        withAnimation(.snappy(duration: 0.25)) {
            proxy.scrollTo(key, anchor: .center)
        }
        return true
    }

    private static let pagerLog = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Timeline")

    private var dayPagerScrollView: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(dayTimelines, id: \.dayKey) { day in
                    DayTimelinePage(
                        dayKey: day.dayKey,
                        isActive: day.dayKey == selectedDayKey
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(day.dayKey)
                }
            }
            .scrollTargetLayout()
        }
        .onScrollGeometryChange(for: PagerOffset.self) { geometry in
            PagerOffset(
                offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                pageWidth: geometry.containerSize.width
            )
        } action: { _, rest in
            pagerRest.offset = rest.offset
            pagerRest.pageWidth = rest.pageWidth
        }
        // In landscape the side safe areas made each page narrower than the pager, so the
        // next day showed in the margins. Pages span the full width; each page pads its own
        // content inside the safe area.
        .ignoresSafeArea(.container, edges: .horizontal)
        // Days added before the first one (demo seeding, an import) would leave the scroll
        // view unable to page back to them, so it is rebuilt on the selected day instead.
        // A new width (rotation) rebuilds it too: the old offset would leave it between
        // pages, and the rebuilt pager starts on the selected day.
        .id("\(dayTimelines.first?.dayKey ?? "")|\(pagerWidth)")
        .onAppear { syncPagerToSelection(animated: false) }
        // Aligned to pages rather than paging by the scroll view's width: in landscape the
        // pages are narrower than the scroll view by the side safe areas, so paging by
        // width drifted further between pages with every swipe.
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $pagerDayKey, anchor: .center)
        .scrollIndicators(.hidden)
        .onChange(of: pagerDayKey) { _, _ in
            // The position can arrive just after the pager reports that it is idle.
            if !isPagerMoving { commitPagerPosition() }
        }
        // Rotation changes the page width while the scroll offset stays where it was, so
        // the pager came to rest between pages (or on a neighbor) and that position was
        // adopted as a swipe. The selected day wins: re-place the pager on it.
        .onGeometryChange(for: Int.self) { proxy in
            Int(proxy.size.width.rounded())
        } action: { width in
            guard width != pagerWidth else { return }
            // Positions reported while the old pager goes away are not swipes.
            isPagerResizing = true
            pagerWidth = width
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                isPagerResizing = false
            }
        }
    }

    /// Adopts the page the pager settled on.
    private func commitPagerPosition() {
        guard isPagerPositioned, !isPagerResizing,
              let key = pagerDayKey,
              let index = dayTimelines.firstIndex(where: { $0.dayKey == key }) else { return }
        if index != selectedPageIndex {
            selectedPageIndex = index
        }
    }

    /// Moves the pager to the selected day when something other than a swipe chose it.
    private func syncPagerToSelection(animated: Bool) {
        guard !isPagerMoving, dayTimelines.indices.contains(selectedPageIndex) else { return }
        let key = dayTimelines[selectedPageIndex].dayKey
        defer { isPagerPositioned = true }
        guard pagerDayKey != key else { return }
        if animated {
            withAnimation(.snappy(duration: 0.3)) { pagerDayKey = key }
        } else {
            pagerDayKey = key
        }
    }

    private func refreshVisibleDays() {
        todayTimeline = fetchDay(DayTimeline.makeDayKey(for: .now))
        guard dayTimelines.indices.contains(selectedPageIndex) else { selectedDay = nil; return }
        let entry = dayTimelines[selectedPageIndex]
        selectedDay = fetchDay(entry.dayKey) ?? DayTimeline(dayStart: entry.dayStart)
    }

    private var canGoOlder: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex > 0
    }

    private var canGoNewer: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex < dayTimelines.count - 1
    }

    private func fetchDay(_ key: String) -> DayTimeline? {
        var query = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })
        query.fetchLimit = 1
        return try? modelContext.fetch(query).first
    }

    /// Bounded database reads; missing calendar days are navigation values, not new records.
    private func refreshDayIndex() {
        var firstQuery = FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart)])
        firstQuery.fetchLimit = 1
        var lastQuery = FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart, order: .reverse)])
        lastQuery.fetchLimit = 1
        guard let first = try? modelContext.fetch(firstQuery).first else { dayTimelines = []; return }
        let last = (try? modelContext.fetch(lastQuery).first)?.dayStart ?? first.dayStart
        // This runs after every save, and the calendar only changes with its first day, its
        // last day, or the time zone.
        let calendar = Calendar.current
        let firstStart = calendar.startOfDay(for: first.dayStart)
        let lastStart = calendar.startOfDay(for: max(last, .now))
        if dayTimelines.first?.dayStart != firstStart
            || dayTimelines.last?.dayStart != lastStart
            || dayIndexTimeZone != calendar.timeZone {
            dayTimelines = TimelineBrowsingDay.days(from: firstStart, through: lastStart)
            dayIndexTimeZone = calendar.timeZone
        }
        syncSelectedDayIfNeeded()
        refreshVisibleDays()
    }

    private var timelineNavigation: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 10) {
                    if dayTimelines.isEmpty {
                        emptyState
                            .safeAreaPadding(.horizontal, 14)
                    } else {
                        dayHeader
                            .safeAreaPadding(.horizontal, 14)
                            .padding(.top, 4)
                    }

                    if let trackingPermissionPrompt {
                        trackingPermissionBanner(trackingPermissionPrompt)
                            .safeAreaPadding(.horizontal, 14)
                    }

                    if let bannerData = trackingStatusBannerData(
                        for: captureManager,
                        context: .timeline
                    ) {
                        TrackingStatusBanner(
                            data: bannerData,
                            buttonAction: {
                                routeTracking.stop()
                            }
                        )
                        .safeAreaPadding(.horizontal, 14)
                    }

                    if !dayTimelines.isEmpty {
                        dayPager
                            .timelineDayMapHost()
                    }
                }
                
            }
            
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: Binding(
                get: { rootController.requestedMoveDetailID != nil },
                set: { if !$0 { rootController.requestedMoveDetailID = nil } }
            )) {
                if let id = rootController.requestedMoveDetailID {
                    RequestedMoveDetailView(id: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        rootController.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }

                if showsTodayButton {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Today"), action: returnToToday)
                            .accessibilityHint(String(localized: "Goes back to the current day"))
                    }
                }

                // Shows itself only when something is waiting for a look.
                ToolbarItem(placement: .principal) {
                    ReviewEntryButton()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        rootController.isShowingStatisticsSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Search")
                    .accessibilityLabel("Search")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    
                      
                            RouteTrackingToolbarButton(
                                endsAt: routeTracking.endsAt,
                                authorizationStatus: routeTracking.authorization,
                                tapAction: {
                                    rootController.isShowingRouteTrackingSettings = true
                                },
                                longPressAction: {
                                    routeTracking.start(routeTracking.duration)
                                }
                            )
                           
                            
                            
                        
                    
                }
               
            }
        }
    }

    private var historyChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .merge(with: NotificationCenter.default.publisher(for: .movesLocationSamplesDidChange))
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var spotlightChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter(PlaceSaveFilter.touchesPlaces)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var observedTimeline: some View {
        timelineNavigation
        .task {
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            await captureManager.start()
        }
        .onAppear {
            // The tab bar re-runs onAppear on every return to Timeline: only the first
            // appearance opens today, so a past day stays put across tab switches.
            // The root controller outlives this view, so it remembers the day either way.
            if !didOpenInitialDay, rootController.selectedDayKey.isEmpty {
                openCurrentDay()
            } else {
                if selectedDayKey.isEmpty { selectedDayKey = rootController.selectedDayKey }
                refreshDayIndex()
            }
            didOpenInitialDay = true
            modelContext.undoManager = undoController.manager
            publishWidgetSnapshot()
            refreshSpotlightIndex()
            cloudDataPresencePublisher.publishSoon()
            rootController.selectedDayKey = selectedDayKey
        }
        .onChange(of: dayTimelines) { _, _ in
            syncSelectedDayIfNeeded()
            syncPagerToSelection(animated: false)
            publishWidgetSnapshot()
        }
        .onChange(of: todayTimeline?.moves.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: todayTimeline?.places.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onReceive(historyChanges) { _ in
                refreshDayIndex()
                publishWidgetSnapshot()
                cloudDataPresencePublisher.publishSoon()
            }
    }

    var body: some View {
        observedTimeline
        .environment(\.timelineScreenHeight, screenHeight)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        } action: { height in
            screenHeight = height
        }
        .onReceive(spotlightChanges) { _ in refreshSpotlightIndex() }
        .onDisappear { spotlightRefreshTask?.cancel() }
        .task(id: selectedDay?.id) { await openScreenshotMoveIfNeeded() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { wentToBackground = true }
            guard newPhase == .active else { spotlightRefreshTask?.cancel(); return }
            // A share sheet, permission alert, or Control Center only makes the scene
            // inactive; the day on screen stays. Coming back from the background opens today.
            if wentToBackground {
                wentToBackground = false
                openCurrentDay()
            } else {
                refreshDayIndex()
            }
            publishWidgetSnapshot()
            refreshSpotlightIndex()
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: selectedPageIndex) { _, newIndex in
            guard dayTimelines.indices.contains(newIndex) else { return }
            refreshVisibleDays()
            selectedDayKey = dayTimelines[newIndex].dayKey
            syncPagerToSelection(animated: false)
        }
        .onChange(of: selectedDayKey) { _, newKey in
            if rootController.selectedDayKey != newKey {
                rootController.selectedDayKey = newKey
            }
        }
        .onChange(of: rootController.shouldOpenToday) { _, shouldOpen in
            guard shouldOpen else { return }
            openCurrentDay()
            rootController.shouldOpenToday = false
        }
        .onChange(of: rootController.requestedPlaceID) { _, placeID in
            guard let placeID else { return }
            selectPlace(placeID)
            rootController.requestedPlaceID = nil
        }
        .onChange(of: rootController.requestedJumpDate) { _, date in
            consumeRequestedJumpDateIfPossible()
        }
        .onChange(of: dayTimelines.count) { _, _ in
            consumeRequestedJumpDateIfPossible()
        }
    }

    @MainActor private func openScreenshotMoveIfNeeded() async {
        guard ProcessInfo.processInfo.environment["MOVES_OPEN_FIRST_MOVE"] == "1", !didOpenScreenshotMove,
              let move = selectedDay?.moves.min(by: { $0.timelineStartDate < $1.timelineStartDate }) else { return }
        didOpenScreenshotMove = true
        let id = move.id
        await Task.yield()
        guard !Task.isCancelled else { return }
        rootController.requestedMoveDetailID = id
    }

    private var background: some View {
        LinearGradient(
            colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func trackingPermissionBanner(_ prompt: TrackingPermissionPrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.circle.fill")
                .foregroundStyle(MovesPalette.start)

            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(prompt.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = prompt.buttonTitle,
               let action = prompt.action {
                Button(buttonTitle) {
                    performTrackingPromptAction(action)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .panelSurface()
    }

    private var dayHeader: some View {
        Group {
            if let selectedDay {
                DayHeaderView(
                    day: selectedDay,
                    canGoOlder: canGoOlder,
                    canGoNewer: canGoNewer,
                    onOlder: selectOlderDay,
                    onNewer: selectNewerDay,
                    onJumpToDate: { rootController.isShowingDatePicker = true }
                )
            }
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash.circle")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No timeline yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Keep Moves running in the background. Today’s story appears as visits and moves are recorded.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panelSurface()
    }

    private var trackingPermissionPrompt: TrackingPermissionPrompt? {
        if captureManager.isDemoMode {
            return nil
        }

        switch captureManager.authorizationStatus {
        case .notDetermined:
            return TrackingPermissionPrompt(
                title: "Enable location tracking",
                message: "Moves needs location access to record your timeline. We will ask for While Using first, then immediately request Always for background tracking.",
                buttonTitle: "Allow Location Access",
                action: .requestAuthorization
            )
        case .authorizedWhenInUse:
            return TrackingPermissionPrompt(
                title: "Allow Always for background tracking",
                message: "We can already read your location while the app is open. Tap below to switch to Always so Moves can keep recording in the background.",
                buttonTitle: "Continue to Always",
                action: .requestAuthorization
            )
        case .denied:
            return TrackingPermissionPrompt(
                title: "Location access is off",
                message: "Moves needs location access to record visits and movement. Open Settings to allow it.",
                buttonTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            return TrackingPermissionPrompt(
                title: "Location access is restricted",
                message: "This device does not allow location access for Moves.",
                buttonTitle: nil,
                action: nil
            )
        case .authorizedAlways:
            return nil
        @unknown default:
            return nil
        }
    }

    private func performTrackingPromptAction(_ action: TrackingPromptAction) {
        switch action {
        case .requestAuthorization:
            captureManager.requestTrackingAuthorization()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    private func openCurrentDay() {
        guard !ProcessInfo.processInfo.isRunningForPreviews else { return }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let todayKey = DayTimeline.makeDayKey(for: todayStart)

        refreshDayIndex()

        if let todayIndex = dayTimelines.firstIndex(where: { $0.dayKey == todayKey }) {
            select(dayAt: todayIndex)
        } else {
            selectedDayKey = todayKey
        }
    }

    private var showsTodayButton: Bool {
        !dayTimelines.isEmpty && selectedDayKey != DayTimeline.makeDayKey(for: .now)
    }

    /// A swipe still moving settles first; its day would otherwise take the selection back.
    private func returnToToday() {
        guard isPagerMoving else { return openCurrentDay() }
        returnsToTodayOnceSettled = true
    }

    private func returnToTodayIfRequested() {
        guard returnsToTodayOnceSettled else { return }
        returnsToTodayOnceSettled = false
        Task { @MainActor in
            // The pager can report its last position just after it reports that it is idle.
            try? await Task.sleep(for: .milliseconds(60))
            returnToToday()
        }
    }

    /// The widgets and the watch always describe today, whatever day is on screen.
    private func publishWidgetSnapshot() {
        guard let todayTimeline else { return }
        TimelineWidgetSnapshotStore.save(.make(from: todayTimeline))
    }

    private func refreshSpotlightIndex() {
        guard scenePhase == .active else { return }
        spotlightRefreshTask?.cancel()
        let container = modelContext.container
        spotlightRefreshTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                let entities = try await importWorkerValue(Task.detached(priority: .utility) {
                    let context = ModelContext(container)
                    var entities: [VisitedPlaceEntity] = []
                    var query = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate)])
                    query.fetchLimit = 500
                    query.propertiesToFetch = [\.id, \.arrivalDate, \.userLabel, \.autoLabel]
                    query.relationshipKeyPathsForPrefetching = [\.knownPlace, \.dayTimeline]
                    var offset = 0
                    while true {
                        try Task.checkCancellation()
                        query.fetchOffset = offset
                        let count = try autoreleasepool {
                            let page = try context.fetch(query)
                            entities.append(contentsOf: page.map(VisitedPlaceEntity.init))
                            return page.count
                        }
                        if count < 500 { break }
                        offset += count
                    }
                    return entities
                })
                try Task.checkCancellation()
                let signature = entities.map { "\($0.id)|\($0.name)|\($0.visitedAt)" }
                guard signature != lastSpotlightSignature else { return }
                try await VisitedPlaceSpotlightIndexer.replaceIndex(with: entities)
                lastSpotlightSignature = signature
            } catch { /* A later save retries; indexing never affects recording. */ }
        }
    }

    private func selectPlace(_ placeID: UUID) {
        var query = FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == placeID })
        query.fetchLimit = 1
        guard let date = (try? modelContext.fetch(query).first)?.arrivalDate else { return }
        jumpToDate(date)
    }

    private func syncSelectedDayIfNeeded() {
        guard !dayTimelines.isEmpty else {
            selectedPageIndex = 0
            selectedDayKey = ""
            return
        }

        if selectedDayKey.isEmpty {
            selectedPageIndex = dayTimelines.count - 1
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        if let selectedIndex = dayTimelines.firstIndex(where: { $0.dayKey == selectedDayKey }) {
            selectedPageIndex = selectedIndex
            return
        }

        if dayTimelines.indices.contains(selectedPageIndex) {
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        selectedPageIndex = dayTimelines.count - 1
        selectedDayKey = dayTimelines[selectedPageIndex].dayKey
    }

    private func selectOlderDay() {
        let nextIndex = selectedPageIndex - 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
        syncPagerToSelection(animated: true)
    }

    private func selectNewerDay() {
        let nextIndex = selectedPageIndex + 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
        syncPagerToSelection(animated: true)
    }

    /// Holds a launch or deep-link jump until demo days (or imported days) exist.
    private func consumeRequestedJumpDateIfPossible() {
        guard let date = rootController.requestedJumpDate else { return }
        guard !dayTimelines.isEmpty else { return }
        jumpToDate(date)
        rootController.requestedJumpDate = nil
    }

    private func jumpToDate(_ date: Date) {
        guard !dayTimelines.isEmpty else { return }

        // Every calendar day is in the list, in order: the day itself, else the nearest end.
        let targetStart = Calendar.autoupdatingCurrent.startOfDay(for: date)
        let index = dayTimelines.firstIndex { $0.dayStart >= targetStart } ?? dayTimelines.count - 1
        select(dayAt: index)
    }

    /// Shows a day chosen by something other than a swipe. It does not rely on the page number
    /// changing: days added before the first one move every page, so the chosen day can land
    /// on the number the previous day had.
    private func select(dayAt index: Int) {
        selectedPageIndex = index
        selectedDayKey = dayTimelines[index].dayKey
        refreshVisibleDays()
        syncPagerToSelection(animated: false)
    }
}

enum TimelineExportScope {
    case allDays
    case selectedDay
}

enum TimelineExportFormat {
    case gpx
    case geoJSON
    case csv
    case kml

    var contentType: UTType {
        switch self {
        case .gpx, .kml:
            return .xml
        case .geoJSON:
            return .json
        case .csv:
            return .commaSeparatedText
        }
    }

    var fileExtension: String {
        switch self {
        case .gpx:
            return "gpx"
        case .geoJSON:
            return "geojson"
        case .csv:
            return "csv"
        case .kml:
            return "kml"
        }
    }
}

struct TimelineExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
}

struct TimelineTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}

struct TimelineExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.xml, .json, .commaSeparatedText, .zip]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct GPXShareFile: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .xml) { file in
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let url = directory.appending(path: file.filename)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

enum TimelineExporter {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makePayload(
        days: [DayTimeline],
        format: TimelineExportFormat,
        fileStem: String,
        privacyZones: [PrivacyZone] = []
    ) -> TimelineExportPayload? {
        let orderedDays = days.sorted(by: { $0.dayStart < $1.dayStart })

        let exportData: Data?
        switch format {
        case .gpx:
            exportData = gpxData(for: orderedDays, privacyZones: privacyZones)
        case .geoJSON:
            exportData = geoJSONData(for: orderedDays, privacyZones: privacyZones)
        case .csv:
            exportData = csvData(for: orderedDays, privacyZones: privacyZones)
        case .kml:
            exportData = kmlData(for: orderedDays, privacyZones: privacyZones)
        }

        guard let exportData else { return nil }
        return TimelineExportPayload(
            data: exportData,
            filename: "\(fileStem).\(format.fileExtension)",
            contentType: format.contentType
        )
    }

    /// One zip containing GPX, GeoJSON, CSV, KML, learned places, and photo identifiers.
    static func makeZipPayload(
        days: [DayTimeline],
        knownPlaces: [KnownPlace],
        photos: [PhotoAttachment],
        fileStem: String,
        privacyZones: [PrivacyZone] = []
    ) -> TimelineExportPayload? {
        let orderedDays = days.sorted(by: { $0.dayStart < $1.dayStart })
        guard !orderedDays.isEmpty else { return nil }

        var files: [MovesZipFile] = []
        if let gpx = gpxData(for: orderedDays, privacyZones: privacyZones) {
            files.append(MovesZipFile(path: "\(fileStem).gpx", data: gpx))
        }
        if let geoJSON = geoJSONData(for: orderedDays, privacyZones: privacyZones) {
            files.append(MovesZipFile(path: "\(fileStem).geojson", data: geoJSON))
        }
        if let csv = csvData(for: orderedDays, privacyZones: privacyZones) {
            files.append(MovesZipFile(path: "\(fileStem).csv", data: csv))
        }
        if let kml = kmlData(for: orderedDays, privacyZones: privacyZones) {
            files.append(MovesZipFile(path: "\(fileStem).kml", data: kml))
        }
        if let places = placesJSONData(knownPlaces, privacyZones: privacyZones) {
            files.append(MovesZipFile(path: "places.json", data: places))
        }
        if let photosCSV = photosCSVData(photos) {
            files.append(MovesZipFile(path: "photos.csv", data: photosCSV))
        }
        guard !files.isEmpty else { return nil }

        return TimelineExportPayload(
            data: MovesZipArchive.pack(files),
            filename: "\(fileStem).zip",
            contentType: .zip
        )
    }

    static func makeMoveGPXPayload(
        move: MoveSegment,
        coordinates: [CLLocationCoordinate2D],
        fileStem: String,
        privacyZones: [PrivacyZone] = []
    ) -> TimelineExportPayload? {
        let filtered = coordinates.filter { coordinate in
            !PrivacyZoneResolver.containsRawFix(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                zones: privacyZones
            )
        }
        let points = routePoints(
            for: filtered,
            startDate: move.timelineStartDate,
            endDate: move.endDate
        )
        guard points.count > 1 else { return nil }

        let startTitle = exportTitle(for: move.startPlace, fallback: "Unknown start", privacyZones: privacyZones)
        let endTitle = exportTitle(for: move.endPlace, fallback: "Unknown destination", privacyZones: privacyZones)
        let trackName = "\(startTitle) to \(endTitle)"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(xmlEscaped(trackName))</name>
            <time>\(iso8601.string(from: move.timelineStartDate))</time>
          </metadata>
        """

        if let startPlace = move.startPlace, !isHidden(startPlace, privacyZones: privacyZones) {
            xml += """

              <wpt lat="\(coordinateString(startPlace.latitude))" lon="\(coordinateString(startPlace.longitude))">
                <name>\(xmlEscaped(startTitle))</name>
                <time>\(iso8601.string(from: move.timelineStartDate))</time>
              </wpt>
            """
        }

        if let endPlace = move.endPlace, !isHidden(endPlace, privacyZones: privacyZones) {
            xml += """

              <wpt lat="\(coordinateString(endPlace.latitude))" lon="\(coordinateString(endPlace.longitude))">
                <name>\(xmlEscaped(endTitle))</name>
                <time>\(iso8601.string(from: move.endDate))</time>
              </wpt>
            """
        }

        xml += """

          <trk>
            <name>\(xmlEscaped(trackName))</name>
            <type>\(xmlEscaped(move.transportMode.title))</type>
        """

        if let comment = move.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !comment.isEmpty {
            xml += """

                <desc>\(xmlEscaped(comment))</desc>
            """
        }

        xml += """

            <trkseg>
        """

        for point in points {
            xml += """

              <trkpt lat="\(coordinateString(point.latitude))" lon="\(coordinateString(point.longitude))">
                <time>\(iso8601.string(from: point.timestamp))</time>
              </trkpt>
            """
        }

        xml += """

            </trkseg>
          </trk>
        </gpx>
        """

        guard let data = xml.data(using: .utf8) else { return nil }
        return TimelineExportPayload(
            data: data,
            filename: "\(fileStem).gpx",
            contentType: .xml
        )
    }

    private static func gpxData(for days: [DayTimeline], privacyZones: [PrivacyZone]) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
        """

        for day in days {
            let sortedPlaces = day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
            for place in sortedPlaces where !isHidden(place, privacyZones: privacyZones) {
                xml += """

                  <wpt lat="\(coordinateString(place.latitude))" lon="\(coordinateString(place.longitude))">
                    <name>\(xmlEscaped(place.displayTitle))</name>
                    <time>\(iso8601.string(from: place.arrivalDate))</time>
                  </wpt>
                """
            }

            let sortedMoves = day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            guard !sortedMoves.isEmpty else { continue }

            xml += """
            
              <trk>
                <name>\(xmlEscaped(day.dayKey))</name>
            """

            for move in sortedMoves {
                let points = routePoints(for: move, privacyZones: privacyZones)
                guard points.count > 1 else { continue }

                xml += """
                
                    <trkseg>
                """

                for point in points {
                    xml += """
                    
                      <trkpt lat="\(coordinateString(point.latitude))" lon="\(coordinateString(point.longitude))">
                    """

                    if let elevation = point.elevation, elevation.isFinite {
                        xml += """
                        
                            <ele>\(elevationString(elevation))</ele>
                        """
                    }

                    xml += """
                    
                        <time>\(iso8601.string(from: point.timestamp))</time>
                      </trkpt>
                    """
                }

                xml += """
                
                    </trkseg>
                """
            }

            xml += """
            
              </trk>
            """
        }

        xml += """
        
        </gpx>
        """

        return xml.data(using: .utf8)
    }

    private static func kmlData(for days: [DayTimeline], privacyZones: [PrivacyZone]) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Moves</name>
        """

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) where !isHidden(place, privacyZones: privacyZones) {
                xml += """

            <Placemark>
              <name>\(xmlEscaped(place.displayTitle))</name>
              <TimeStamp><when>\(iso8601.string(from: place.arrivalDate))</when></TimeStamp>
              <Point>
                <coordinates>\(coordinateString(place.longitude)),\(coordinateString(place.latitude)),0</coordinates>
              </Point>
            </Placemark>
            """
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let points = routePoints(for: move, privacyZones: privacyZones)
                guard points.count > 1 else { continue }
                let title = moveTitle(for: move, privacyZones: privacyZones)
                let coordinates = points
                    .map { "\(coordinateString($0.longitude)),\(coordinateString($0.latitude)),0" }
                    .joined(separator: " ")
                xml += """

            <Placemark>
              <name>\(xmlEscaped(title))</name>
              <description>\(xmlEscaped(move.transportMode.title))</description>
              <LineString>
                <tessellate>1</tessellate>
                <coordinates>\(coordinates)</coordinates>
              </LineString>
            </Placemark>
            """
            }
        }

        xml += """

          </Document>
        </kml>
        """
        return xml.data(using: .utf8)
    }

    private static func placesJSONData(_ places: [KnownPlace], privacyZones: [PrivacyZone]) -> Data? {
        let payload: [[String: Any]] = places
            .filter { place in
                !PrivacyZoneResolver.containsRawFix(
                    latitude: place.centerLatitude,
                    longitude: place.centerLongitude,
                    zones: privacyZones
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { place in
                var object: [String: Any] = [
                    "id": place.id.uuidString,
                    "name": place.name,
                    "latitude": place.centerLatitude,
                    "longitude": place.centerLongitude,
                    "footprint_radius": place.footprintRadius,
                    "confirmed_visit_count": place.confirmedVisitCount,
                ]
                if let category = place.category { object["category"] = category }
                if let countryCode = place.countryCode { object["country_code"] = countryCode }
                if let locality = place.locality { object["locality"] = locality }
                return object
            }
        return try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func photosCSVData(_ photos: [PhotoAttachment]) -> Data? {
        var rows = ["asset_local_identifier,captured_at,visit_id,day_key"]
        for photo in photos.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let visitID = photo.visitPlace?.id.uuidString ?? ""
            let dayKey = photo.dayTimeline?.dayKey
                ?? photo.visitPlace?.dayTimeline?.dayKey
                ?? ""
            rows.append(
                [
                    csvEscaped(photo.assetLocalIdentifier),
                    iso8601.string(from: photo.capturedAt),
                    csvEscaped(visitID),
                    csvEscaped(dayKey),
                ].joined(separator: ",")
            )
        }
        return rows.joined(separator: "\n").data(using: .utf8)
    }

    private static func geoJSONData(for days: [DayTimeline], privacyZones: [PrivacyZone]) -> Data? {
        var features: [[String: Any]] = []

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) where !isHidden(place, privacyZones: privacyZones) {
                var properties: [String: Any] = [
                    "record_type": "place",
                    "title": place.displayTitle,
                    "arrival_time": iso8601.string(from: place.arrivalDate),
                    "day_key": day.dayKey,
                ]

                if let departureDate = place.departureDate {
                    properties["departure_time"] = iso8601.string(from: departureDate)
                }
                if let userLabel = place.userLabel, !userLabel.isEmpty {
                    properties["user_label"] = userLabel
                }
                if let autoLabel = place.autoLabel, !autoLabel.isEmpty {
                    properties["auto_label"] = autoLabel
                }
                if let comment = place.comment, !comment.isEmpty {
                    properties["comment"] = comment
                }

                let geometry: [String: Any] = [
                    "type": "Point",
                    "coordinates": [place.longitude, place.latitude],
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let points = routePoints(for: move, privacyZones: privacyZones)
                let coordinates = points.map { [$0.longitude, $0.latitude] }
                guard coordinates.count > 1 else { continue }

                var properties: [String: Any] = [
                    "record_type": "move",
                    "day_key": day.dayKey,
                    "transport_mode": move.transportMode.rawValue,
                    "start_time": iso8601.string(from: move.timelineStartDate),
                    "end_time": iso8601.string(from: move.endDate),
                    "distance_meters": move.distanceMeters,
                    "start_place": exportTitle(for: move.startPlace, fallback: "Unknown start", privacyZones: privacyZones),
                    "end_place": exportTitle(for: move.endPlace, fallback: "Unknown destination", privacyZones: privacyZones),
                ]

                if let stepCount = move.stepCount {
                    properties["step_count"] = stepCount
                }
                if let comment = move.comment, !comment.isEmpty {
                    properties["comment"] = comment
                }

                let geometry: [String: Any] = [
                    "type": "LineString",
                    "coordinates": coordinates,
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }
        }

        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features,
        ]

        return try? JSONSerialization.data(
            withJSONObject: collection,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func csvData(for days: [DayTimeline], privacyZones: [PrivacyZone]) -> Data? {
        var rows: [String] = []
        rows.append("record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment")

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) where !isHidden(place, privacyZones: privacyZones) {
                rows.append(
                    [
                        "place",
                        iso8601.string(from: place.arrivalDate),
                        place.departureDate.map(iso8601.string(from:)) ?? "",
                        csvEscaped(place.displayTitle),
                        day.dayKey,
                        "",
                        "",
                        "",
                        coordinateString(place.latitude),
                        coordinateString(place.longitude),
                        csvEscaped(place.comment ?? ""),
                    ].joined(separator: ",")
                )
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let title = moveTitle(for: move, privacyZones: privacyZones)
                rows.append(
                    [
                        "move",
                        iso8601.string(from: move.timelineStartDate),
                        iso8601.string(from: move.endDate),
                        csvEscaped(title),
                        day.dayKey,
                        move.transportMode.rawValue,
                        String(format: "%.2f", move.distanceMeters),
                        move.stepCount.map(String.init) ?? "",
                        "",
                        "",
                        csvEscaped(move.comment ?? ""),
                    ].joined(separator: ",")
                )
            }
        }

        return rows.joined(separator: "\n").data(using: .utf8)
    }

    private static func routePoints(
        for move: MoveSegment,
        privacyZones: [PrivacyZone]
    ) -> [TimelineTrackPoint] {
        var points: [TimelineTrackPoint] = []
        points.reserveCapacity(move.samples.count + 2)

        if let startPlace = move.startPlace, !isHidden(startPlace, privacyZones: privacyZones) {
            points.append(
                TimelineTrackPoint(
                    latitude: startPlace.latitude,
                    longitude: startPlace.longitude,
                    elevation: nil,
                    timestamp: move.timelineStartDate
                )
            )
        }

        let sortedSamples = move.samples
            .preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
        for sample in sortedSamples {
            if PrivacyZoneResolver.containsRawFix(
                latitude: sample.latitude,
                longitude: sample.longitude,
                zones: privacyZones
            ) {
                continue
            }
            points.append(
                TimelineTrackPoint(
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    elevation: sample.altitude,
                    timestamp: sample.timestamp
                )
            )
        }

        if let endPlace = move.endPlace, !isHidden(endPlace, privacyZones: privacyZones) {
            points.append(
                TimelineTrackPoint(
                    latitude: endPlace.latitude,
                    longitude: endPlace.longitude,
                    elevation: nil,
                    timestamp: move.endDate
                )
            )
        }

        let sortedPoints = points.sorted(by: { $0.timestamp < $1.timestamp })
        return dedupeSequentialPoints(in: sortedPoints)
    }

    private static func routePoints(
        for coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> [TimelineTrackPoint] {
        let coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates,
            minimumDistanceMeters: 0.01
        )
        guard coordinates.count > 1 else { return [] }

        let segmentDistances = zip(coordinates, coordinates.dropFirst()).map {
            RouteCoordinateOps.distanceMeters(from: $0.0, to: $0.1)
        }
        let totalDistance = segmentDistances.reduce(0, +)
        let duration = max(endDate.timeIntervalSince(startDate), 0)
        var distanceTravelled: CLLocationDistance = 0

        return coordinates.enumerated().map { index, coordinate in
            if index > 0 {
                distanceTravelled += segmentDistances[index - 1]
            }

            let fraction: Double
            if totalDistance > 0 {
                fraction = distanceTravelled / totalDistance
            } else {
                fraction = Double(index) / Double(coordinates.count - 1)
            }

            return TimelineTrackPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                elevation: nil,
                timestamp: startDate.addingTimeInterval(duration * fraction)
            )
        }
    }

    /// True when a place sits inside a privacy zone, so exports must not reveal where it is.
    private static func isHidden(_ place: VisitPlace, privacyZones: [PrivacyZone]) -> Bool {
        PrivacyZoneResolver.containsRawFix(
            latitude: place.latitude,
            longitude: place.longitude,
            zones: privacyZones
        )
    }

    /// A place's title can be its coordinates or street, so a hidden place goes by Home or Work.
    private static func exportTitle(
        for place: VisitPlace?,
        fallback: String,
        privacyZones: [PrivacyZone]
    ) -> String {
        guard let place else { return fallback }
        if let zone = privacyZones.first(where: { $0.contains(place.coordinate) }) {
            return zone.category.title
        }
        return place.displayTitle
    }

    private static func moveTitle(for move: MoveSegment, privacyZones: [PrivacyZone]) -> String {
        let start = exportTitle(for: move.startPlace, fallback: "Unknown start", privacyZones: privacyZones)
        let end = exportTitle(for: move.endPlace, fallback: "Unknown destination", privacyZones: privacyZones)
        return "\(start) to \(end)"
    }

    private static func dedupeSequentialPoints(in points: [TimelineTrackPoint]) -> [TimelineTrackPoint] {
        guard !points.isEmpty else { return [] }

        var deduped: [TimelineTrackPoint] = []
        deduped.reserveCapacity(points.count)

        var previousKey: String?
        for point in points {
            let key = "\(Int(point.timestamp.timeIntervalSince1970.rounded()))|\(coordinateString(point.latitude))|\(coordinateString(point.longitude))"
            if key == previousKey { continue }
            deduped.append(point)
            previousKey = key
        }

        return deduped
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func elevationString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct PanelSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MovesPalette.card.opacity(colorScheme == .dark ? 0.88 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(MovesPalette.border, lineWidth: 1)
                    }
            }
    }
}

struct FrostedCircleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.55))
            .background {
                Circle()
                    .fill(
                        MovesPalette.frostedFill.opacity(
                            enabled
                                ? (colorScheme == .dark ? 0.95 : 1.0)
                                : (colorScheme == .dark ? 0.55 : 0.75)
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(MovesPalette.border.opacity(enabled ? 0.9 : 0.7), lineWidth: 1)
                    }
                    .glassEffect(.regular, in: Circle())
            }
    }
}

private struct RouteTrackingToolbarButton: View {
    let endsAt: Date?
    let authorizationStatus: CLAuthorizationStatus
    let tapAction: () -> Void
    let longPressAction: () -> Void

    @State private var isPulsing = false

    /// How often the countdown redraws. Each tick relays out the navigation bar and the
    /// timeline under it, so it only ticks while route tracking runs, and every second
    /// only in the last minutes when seconds are shown.
    private var tickInterval: TimeInterval {
        guard let endsAt, isAuthorizedForRealTracking else { return 3_600 }
        let remaining = endsAt.timeIntervalSinceNow
        if remaining <= 0 { return 3_600 }
        return remaining > 120 ? 30 : 1
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            let remainingSeconds = endsAt.map { $0.timeIntervalSince(context.date) } ?? 0
            let isRunning = remainingSeconds > 0 && isAuthorizedForRealTracking

            HStack(spacing: 5) {
                Image(systemName: "location.fill.viewfinder")
                    .foregroundStyle(isRunning ? .red : Color.primary)
                    .scaleEffect(isRunning && isPulsing ? 1.16 : 1)
                    .opacity(isRunning && isPulsing ? 0.55 : 1)

                if isRunning {
                    Text(routeTrackingCountdownText(for: remainingSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                isRunning
                    ? String(localized: "Route Tracking, on, \(routeTrackingCountdownText(for: remainingSeconds)) left")
                    : String(localized: "Route Tracking, off")
            )
            .accessibilityHint(
                isRunning
                    ? String(localized: "Opens Route Tracking to stop it.")
                    : String(localized: "Opens Route Tracking to start it. Touch and hold to start right away.")
            )
            .accessibilityAddTraits(.isButton)
            .onTapGesture(perform: tapAction)
            .onLongPressGesture(minimumDuration: 0.55, perform: longPressAction)
            .onAppear {
                isPulsing = isRunning
            }
            .onChange(of: isRunning) { _, newValue in
                isPulsing = newValue
            }
            .animation(
                isRunning
                    ? .easeInOut(duration: 1.45).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .help(String(localized: "Route Tracking"))
        }
    }

    private var isAuthorizedForRealTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    private func routeTrackingCountdownText(for remainingSeconds: TimeInterval) -> String {
        if remainingSeconds < 60 {
            return "\(max(Int(ceil(remainingSeconds)), 0))s"
        }

        return DurationFormatter.text(for: remainingSeconds)
    }
}

extension View {
    func panelSurface() -> some View {
        modifier(PanelSurfaceModifier())
    }

    func frostedCircle(enabled: Bool) -> some View {
        modifier(FrostedCircleModifier(enabled: enabled))
    }
}

struct ShakeToUndoDetector: UIViewRepresentable {
    let undoManager: UndoManager
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeToUndoView {
        let view = ShakeToUndoView()
        view.managedUndoManager = undoManager
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeToUndoView, context: Context) {
        uiView.managedUndoManager = undoManager
        uiView.onShake = onShake
    }
}

final class ShakeToUndoView: UIView {
    var managedUndoManager: UndoManager?
    var onShake: (() -> Void)?
    private var activeObserver: NSObjectProtocol?

    override var undoManager: UndoManager? {
        managedUndoManager
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.becomeFirstResponderIfPossible()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponderIfPossible()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        becomeFirstResponderIfPossible()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }

        onShake?()
    }

    private func becomeFirstResponderIfPossible() {
        guard window != nil else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }
}

private extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(
            for: Schema(MovesTimelineSchema.models),
            configurations: configuration
        )

        ContentView()
            .modelContainer(container)
            .environmentObject(MovesLocationCaptureManager(modelContainer: container))
            .environmentObject(AppUndoController())
            .environmentObject(MovesCloudDataPresencePublisher(modelContainer: container))
            .environmentObject(MovesRootController())
            .environmentObject(HealthSummaryStore())
    }
}


/// The destination owns bounded observation and refreshes if this move changes.
/// Database fetches are not performed as side effects of rendering the parent.
private struct RequestedMoveDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let id: UUID
    @State private var move: MoveSegment?
    @State private var didLoad = false
    var body: some View {
        Group {
            if let move { MoveMapDetailView(segment: move) }
            else if didLoad { ContentUnavailableView("Move unavailable", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            else { ProgressView() }
        }
        .task(id: id) {
            let requestedID = id
            var query = FetchDescriptor<MoveSegment>(predicate: #Predicate { $0.id == requestedID })
            query.fetchLimit = 1
            move = try? modelContext.fetch(query).first
            didLoad = true
        }
    }
}

/// Whether a save changed a visit or a learned place. Location batches don't, so Spotlight
/// and calendar sync skip them. Unknown payloads count as a change, so older OS versions
/// still pick up renamed and deleted places.
enum PlaceSaveFilter {
    static func touchesPlaces(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        guard let info = notification.userInfo else { return true }
        if let invalidated = info[ModelContext.NotificationKey.invalidatedAllIdentifiers]
            ?? info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue],
           (invalidated as? Bool) != false { return true }
        var understood = false
        for key in keys {
            guard let payload = info[key] ?? info[key.rawValue] else { continue }
            let identifiers: [PersistentIdentifier]
            if let values = payload as? [PersistentIdentifier] { identifiers = values }
            else if let values = payload as? Set<PersistentIdentifier> { identifiers = Array(values) }
            else { return true }
            understood = true
            if identifiers.contains(where: { $0.entityName == "VisitPlace" || $0.entityName == "KnownPlace" }) { return true }
        }
        return !understood
    }
}
