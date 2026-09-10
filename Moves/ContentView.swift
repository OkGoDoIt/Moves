import CoreLocation
import CoreTransferable
import Foundation
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

    if let endsAt = captureManager.temporaryRouteTrackingEndsAt,
       endsAt > .now {
        switch captureManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Real route tracking on",
                message: temporaryRouteTrackingBannerMessage(
                    for: captureManager,
                    context: context
                ),
                systemImage: "location.fill.viewfinder",
                tint: MovesPalette.routeTracking,
                buttonTitle: context == .timeline ? "Turn off now" : nil,
                buttonRole: context == .timeline ? .destructive : nil
            )
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
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

@MainActor
private func temporaryRouteTrackingBannerMessage(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> String {
    let durationText = captureManager.temporaryRouteTrackingDuration.availabilityText
    let autoStopText = temporaryRouteTrackingAutoStopText(for: captureManager)

    switch captureManager.authorizationStatus {
    case .authorizedAlways:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher and Moves will switch back automatically.\(autoStopText)"
        }
    case .authorizedWhenInUse:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        }
    case .notDetermined, .denied, .restricted:
        switch context {
        case .timeline:
            return "Frequent GPS updates are ready once location access is allowed."
        case .settings:
            return "Frequent GPS updates are ready once location access is allowed."
        }
    @unknown default:
        return "Frequent GPS updates are enabled."
    }
}

@MainActor
private func temporaryRouteTrackingAutoStopText(
    for captureManager: MovesLocationCaptureManager
) -> String {
    let stopAtBatteryFifty = captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
    let stopInLowPowerMode = captureManager.temporaryRouteTrackingStopsInLowPowerMode

    switch (stopAtBatteryFifty, stopInLowPowerMode) {
    case (true, true):
        return " It will also stop if battery reaches 50% or Low Power Mode turns on."
    case (true, false):
        return " It will also stop if battery reaches 50%."
    case (false, true):
        return " It will also stop if Low Power Mode turns on."
    case (false, false):
        return ""
    }
}

struct ContentView: View {
    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case overall
        case placeCount
        case onFoot
        case swimming
        case cycling
        case automotive
        case train
        case plane
        case boat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overall: return "Overall"
            case .placeCount: return "Places"
            case .onFoot: return "On Foot"
            case .swimming: return "Swim"
            case .cycling: return "Cycle"
            case .automotive: return "Car"
            case .train: return "Train"
            case .plane: return "Plane"
            case .boat: return "Boat"
            }
        }

        var symbolName: String {
            switch self {
            case .overall: return "chart.bar.fill"
            case .placeCount: return "mappin.and.ellipse"
            case .onFoot: return "figure.walk"
            case .swimming: return "figure.pool.swim"
            case .cycling: return "figure.outdoor.cycle"
            case .automotive: return "car.fill"
            case .train: return "tram.fill"
            case .plane: return "airplane"
            case .boat: return "sailboat.fill"
            }
        }

        var tint: Color {
            switch self {
            case .overall:
                return .secondary
            case .placeCount:
                return MovesPalette.place
            case .onFoot:
                return MovesPalette.transport(.running)
            case .swimming:
                return MovesPalette.transport(.swimming)
            case .cycling:
                return MovesPalette.transport(.cycling)
            case .automotive:
                return MovesPalette.transport(.automotive)
            case .train:
                return MovesPalette.transport(.train)
            case .plane:
                return MovesPalette.transport(.plane)
            case .boat:
                return MovesPalette.transport(.boat)
            }
        }
    }

    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \DayTimeline.dayStart, order: .forward)
    private var dayTimelines: [DayTimeline]

    @State private var selectedDayKey = ""
    @State private var selectedPageIndex = 0
    @State private var isShowingSettings = false
    @State private var isShowingShareImages = false
    @State private var isShowingRouteTrackingSettings = false
    @State private var isShowingDatePicker = false
    @State private var isShowingActivityFilterPicker = false
    @State private var pickerDate = Date.now
    @State private var activityFilter: ActivityFilter = .overall

    private var selectedDay: DayTimeline? {
        guard dayTimelines.indices.contains(selectedPageIndex) else { return nil }
        return dayTimelines[selectedPageIndex]
    }

    private var canGoOlder: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex > 0
    }

    private var canGoNewer: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex < dayTimelines.count - 1
    }

    private var earliestRecordedDayStart: Date? {
        dayTimelines.first?.dayStart
    }

    private var latestSelectableDayStart: Date {
        Calendar.autoupdatingCurrent.startOfDay(for: .now)
    }

    private var cloudDataPresenceCountSignature: String {
        let placeCount = dayTimelines.reduce(0) { $0 + $1.places.count }
        let moveCount = dayTimelines.reduce(0) { $0 + $1.moves.count }
        return "\(placeCount)|\(moveCount)"
    }

    private var mostActiveDays: [DayTimeline] {
        dayTimelines
            .sorted { lhs, rhs in
                activityScore(for: lhs, filter: activityFilter) > activityScore(for: rhs, filter: activityFilter)
            }
            .filter { activityScore(for: $0, filter: activityFilter) > 0 }
            .prefix(5)
            .map { $0 }
    }

    private var availableActivityFilters: [ActivityFilter] {
        let transportFilters: [ActivityFilter] = [.onFoot, .swimming, .cycling, .automotive, .train, .plane, .boat]
        let availableTransports = transportFilters.filter { totalDistance(for: $0) > 0 }
        return [.overall, .placeCount] + availableTransports
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 12) {
                    if let trackingPermissionPrompt {
                        trackingPermissionBanner(trackingPermissionPrompt)
                    }

                    if let bannerData = trackingStatusBannerData(
                        for: captureManager,
                        context: .timeline
                    ) {
                        TrackingStatusBanner(
                            data: bannerData,
                            buttonAction: {
                                captureManager.disableTemporaryRouteTracking()
                            }
                        )
                    }

                    if dayTimelines.isEmpty {
                        emptyState
                    } else {
                        dayHeader

                        TabView(selection: $selectedPageIndex) {
                            ForEach(Array(dayTimelines.enumerated()), id: \.element.dayKey) { index, day in
                                DayTimelinePage(
                                    dayKey: day.dayKey,
                                    isActive: index == selectedPageIndex
                                )
                                    .tag(index)
                                    
                            }
                        }
                        .ignoresSafeArea()
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                
            }
            
            .navigationTitle("Moves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingShareImages = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .disabled(dayTimelines.allSatisfy { !$0.hasRecordedActivity })
                    .help("Share Images")
                    .accessibilityLabel("Share Images")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    
                      
                            RouteTrackingToolbarButton(
                                endsAt: captureManager.temporaryRouteTrackingEndsAt,
                                authorizationStatus: captureManager.authorizationStatus,
                                tapAction: {
                                    isShowingRouteTrackingSettings = true
                                },
                                longPressAction: {
                                    captureManager.enableTemporaryRouteTracking(
                                        duration: captureManager.temporaryRouteTrackingDuration
                                    )
                                }
                            )
                           
                            
                            
                        
                    
                }
               
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            MovesSettingsView(
                dayTimelines: dayTimelines,
                selectedDayKey: selectedDayKey,
                captureManager: captureManager
            )
        }
        .sheet(isPresented: $isShowingShareImages) {
            NavigationStack {
                MovesShareGalleryView(dayTimelines: dayTimelines)
            }
        }
        .sheet(isPresented: $isShowingRouteTrackingSettings) {
            RouteTrackingSettingsSheet(captureManager: captureManager)
        }
        .sheet(isPresented: $isShowingDatePicker) {
            datePickerSheet
        }
        .task {
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            await captureManager.start()
        }
        .onAppear {
            openCurrentDay()
            modelContext.undoManager = undoController.manager
            publishWidgetSnapshot()
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: dayTimelines.map(\.dayKey)) { _, _ in
            syncSelectedDayIfNeeded()
            publishWidgetSnapshot()
            ensureValidActivityFilterSelection()
        }
        .onChange(of: selectedDay?.moves.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: selectedDay?.places.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: cloudDataPresenceCountSignature) { _, _ in
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            openCurrentDay()
            publishWidgetSnapshot()
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: selectedPageIndex) { _, newIndex in
            guard dayTimelines.indices.contains(newIndex) else { return }
            selectedDayKey = dayTimelines[newIndex].dayKey
        }
        .onAppear {
            ensureValidActivityFilterSelection()
        }
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
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
        HStack(spacing: 10) {
            Button {
                selectOlderDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoOlder)
            .disabled(!canGoOlder)

            VStack(spacing: 2) {
                if let selectedDay {
                    Button {
                        pickerDate = selectedDay.dayStart
                        isShowingDatePicker = true
                    } label: {
                        Text(selectedDay.dayStart, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.92))
                    }
                    .buttonStyle(.plain)

                    Text("\(selectedDay.uniqueLocationCount) places   \(selectedDay.moves.count) moves")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                selectNewerDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoNewer)
            .disabled(!canGoNewer)
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

            Text("Keep Moves running in the background. Visits and movement segments appear as iOS records them.")
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
        var existingKeys = Set(dayTimelines.map(\.dayKey))
        var didInsertDay = false

        if !existingKeys.contains(todayKey) {
            modelContext.insert(DayTimeline(dayStart: todayStart))
            existingKeys.insert(todayKey)
            didInsertDay = true
        }

        // Days without any recorded location have no timeline of their own, which made paging
        // skip them entirely. Fill the gaps so every day since the first recording is reachable.
        if let earliestDayStart = dayTimelines.first?.dayStart {
            var dayStart = calendar.startOfDay(for: earliestDayStart)

            while dayStart < todayStart {
                let dayKey = DayTimeline.makeDayKey(for: dayStart)
                if !existingKeys.contains(dayKey) {
                    modelContext.insert(DayTimeline(dayStart: dayStart))
                    existingKeys.insert(dayKey)
                    didInsertDay = true
                }

                guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                dayStart = nextDayStart
            }
        }

        if didInsertDay {
            do {
                try modelContext.save()
            } catch {
                print("Failed to create day timelines: \(error.localizedDescription)")
            }
        }

        selectedDayKey = todayKey
        if let todayIndex = dayTimelines.firstIndex(where: { $0.dayKey == todayKey }) {
            selectedPageIndex = todayIndex
        }
    }

    private func publishWidgetSnapshot() {
        guard let dayTimeline = selectedDay ?? dayTimelines.last else { return }
        TimelineWidgetSnapshotStore.save(.make(from: dayTimeline))
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
    }

    private func selectNewerDay() {
        let nextIndex = selectedPageIndex + 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
    }

    private func jumpToDate(_ date: Date) {
        guard !dayTimelines.isEmpty else { return }

        let calendar = Calendar.autoupdatingCurrent
        let targetStart = calendar.startOfDay(for: date)

        let closest = dayTimelines.enumerated().min { lhs, rhs in
            let lhsStart = calendar.startOfDay(for: lhs.element.dayStart)
            let rhsStart = calendar.startOfDay(for: rhs.element.dayStart)
            return abs(lhsStart.timeIntervalSince(targetStart)) < abs(rhsStart.timeIntervalSince(targetStart))
        }

        guard let closest else { return }
        selectedPageIndex = closest.offset
        selectedDayKey = closest.element.dayKey
    }

    private func jumpToDay(_ day: DayTimeline) {
        guard let index = dayTimelines.firstIndex(where: { $0.dayKey == day.dayKey }) else { return }
        selectedPageIndex = index
        selectedDayKey = day.dayKey
    }

    private func activityScore(for day: DayTimeline, filter: ActivityFilter) -> Double {
        let totalDistance = day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let totalMoveDuration = day.moves.reduce(0) { $0 + max($1.timelineDuration, 0) }
        let filteredMoves: [MoveSegment]

        switch filter {
        case .overall:
            filteredMoves = day.moves
        case .placeCount:
            return Double(day.uniqueLocationCount)
        case .onFoot:
            filteredMoves = day.moves.filter { $0.transportMode == .walking || $0.transportMode == .running }
        case .swimming:
            filteredMoves = day.moves.filter { $0.transportMode == .swimming }
        case .cycling:
            filteredMoves = day.moves.filter { $0.transportMode == .cycling }
        case .automotive:
            filteredMoves = day.moves.filter { $0.transportMode == .automotive }
        case .train:
            filteredMoves = day.moves.filter { $0.transportMode == .train }
        case .plane:
            filteredMoves = day.moves.filter { $0.transportMode == .plane }
        case .boat:
            filteredMoves = day.moves.filter { $0.transportMode == .boat }
        }

        if filter == .overall {
            let placeComponent = Double(day.uniqueLocationCount) * 1_200
            let moveComponent = Double(day.moves.count) * 900
            let distanceComponent = totalDistance
            let durationComponent = totalMoveDuration / 8
            return placeComponent + moveComponent + distanceComponent + durationComponent
        }

        let filteredDistance = filteredMoves.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let filteredDuration = filteredMoves.reduce(0) { $0 + max($1.timelineDuration, 0) }
        return filteredDistance + (filteredDuration / 8)
    }

    private func totalDistance(for day: DayTimeline) -> CLLocationDistance {
        day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
    }

    private func totalDistance(for filter: ActivityFilter) -> CLLocationDistance {
        dayTimelines.reduce(0) { partial, day in
            let distance: CLLocationDistance
            switch filter {
            case .onFoot:
                distance = day.moves
                    .filter { $0.transportMode == .walking || $0.transportMode == .running }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .swimming:
                distance = day.moves
                    .filter { $0.transportMode == .swimming }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .cycling:
                distance = day.moves
                    .filter { $0.transportMode == .cycling }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .automotive:
                distance = day.moves
                    .filter { $0.transportMode == .automotive }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .train:
                distance = day.moves
                    .filter { $0.transportMode == .train }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .plane:
                distance = day.moves
                    .filter { $0.transportMode == .plane }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .boat:
                distance = day.moves
                    .filter { $0.transportMode == .boat }
                    .reduce(0) { $0 + max($1.distanceMeters, 0) }
            case .overall, .placeCount:
                distance = 0
            }
            return partial + distance
        }
    }

    private func ensureValidActivityFilterSelection() {
        if !availableActivityFilters.contains(activityFilter) {
            activityFilter = .overall
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let earliestRecordedDayStart {
                    DatePicker(
                        "Date",
                        selection: $pickerDate,
                        in: earliestRecordedDayStart...latestSelectableDayStart,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .onChange(of: pickerDate) { _, newDate in
                        jumpToDate(newDate)
                    }
                }

                HStack(spacing: 10) {
                    Button("Earliest") {
                        guard let earliestRecordedDayStart else { return }
                        pickerDate = earliestRecordedDayStart
                        jumpToDate(earliestRecordedDayStart)
                        isShowingDatePicker = false
                    }
                    .buttonStyle(.bordered)

                    Button("Today") {
                        pickerDate = latestSelectableDayStart
                        jumpToDate(latestSelectableDayStart)
                        isShowingDatePicker = false
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Most active days")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            isShowingActivityFilterPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: activityFilter.symbolName)
                                    .foregroundStyle(activityFilter.tint)
                                Text(activityFilter.title)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(MovesPalette.card.opacity(0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isShowingActivityFilterPicker, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                            activityFilterPickerContent
                        }
                    }

                    if mostActiveDays.isEmpty {
                        Text("No matching days for this filter yet.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(mostActiveDays, id: \.dayKey) { day in
                            Button {
                                jumpToDay(day)
                                isShowingDatePicker = false
                            } label: {
                                HStack {
                                    Text(day.dayStart, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    Text("\(day.uniqueLocationCount) places")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)

                                    Text("\(day.moves.count) moves")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)

                                    Text(Measurement(value: totalDistance(for: day), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding()
            .navigationTitle("Jump to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        isShowingDatePicker = false
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var activityFilterPickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity filter")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ForEach(availableActivityFilters) { filter in
                Button {
                    activityFilter = filter
                    isShowingActivityFilterPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: filter.symbolName)
                            .foregroundStyle(filter.tint)
                            .frame(width: 20)

                        Text(filter.title)
                            .foregroundStyle(.primary)

                        Spacer()

                        if activityFilter == filter {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(filter.tint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
        .frame(minWidth: 220)
        .presentationCompactAdaptation(.popover)
    }

    @MainActor
    private func handleShakeToUndo() {
        let undoManager = undoController.manager
        guard undoManager.canUndo else { return }
        modelContext.undoManager = undoManager

        undoManager.undo()

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to save undo changes: \(error.localizedDescription)")
            }
        }
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

    var contentType: UTType {
        switch self {
        case .gpx:
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
    static var readableContentTypes: [UTType] = [.xml, .json, .commaSeparatedText]

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
        fileStem: String
    ) -> TimelineExportPayload? {
        let orderedDays = days.sorted(by: { $0.dayStart < $1.dayStart })

        let exportData: Data?
        switch format {
        case .gpx:
            exportData = gpxData(for: orderedDays)
        case .geoJSON:
            exportData = geoJSONData(for: orderedDays)
        case .csv:
            exportData = csvData(for: orderedDays)
        }

        guard let exportData else { return nil }
        return TimelineExportPayload(
            data: exportData,
            filename: "\(fileStem).\(format.fileExtension)",
            contentType: format.contentType
        )
    }

    static func makeMoveGPXPayload(
        move: MoveSegment,
        coordinates: [CLLocationCoordinate2D],
        fileStem: String
    ) -> TimelineExportPayload? {
        let points = routePoints(
            for: coordinates,
            startDate: move.timelineStartDate,
            endDate: move.endDate
        )
        guard points.count > 1 else { return nil }

        let startTitle = move.startPlace?.displayTitle ?? "Unknown start"
        let endTitle = move.endPlace?.displayTitle ?? "Unknown destination"
        let trackName = "\(startTitle) to \(endTitle)"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(xmlEscaped(trackName))</name>
            <time>\(iso8601.string(from: move.timelineStartDate))</time>
          </metadata>
        """

        if let startPlace = move.startPlace {
            xml += """

              <wpt lat="\(coordinateString(startPlace.latitude))" lon="\(coordinateString(startPlace.longitude))">
                <name>\(xmlEscaped(startTitle))</name>
                <time>\(iso8601.string(from: move.timelineStartDate))</time>
              </wpt>
            """
        }

        if let endPlace = move.endPlace {
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

    private static func gpxData(for days: [DayTimeline]) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
        """

        for day in days {
            let sortedPlaces = day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
            for place in sortedPlaces {
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
                let points = routePoints(for: move)
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

    private static func geoJSONData(for days: [DayTimeline]) -> Data? {
        var features: [[String: Any]] = []

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
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
                let points = routePoints(for: move)
                let coordinates = points.map { [$0.longitude, $0.latitude] }
                guard coordinates.count > 1 else { continue }

                var properties: [String: Any] = [
                    "record_type": "move",
                    "day_key": day.dayKey,
                    "transport_mode": move.transportMode.rawValue,
                    "start_time": iso8601.string(from: move.timelineStartDate),
                    "end_time": iso8601.string(from: move.endDate),
                    "distance_meters": move.distanceMeters,
                    "start_place": move.startPlace?.displayTitle ?? "Unknown start",
                    "end_place": move.endPlace?.displayTitle ?? "Unknown destination",
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

    private static func csvData(for days: [DayTimeline]) -> Data? {
        var rows: [String] = []
        rows.append("record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment")

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
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
                let title = "\(move.startPlace?.displayTitle ?? "Unknown start") to \(move.endPlace?.displayTitle ?? "Unknown destination")"
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

    private static func routePoints(for move: MoveSegment) -> [TimelineTrackPoint] {
        var points: [TimelineTrackPoint] = []
        points.reserveCapacity(move.samples.count + 2)

        if let startPlace = move.startPlace {
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
            points.append(
                TimelineTrackPoint(
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    elevation: sample.altitude,
                    timestamp: sample.timestamp
                )
            )
        }

        if let endPlace = move.endPlace {
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
                    ? "Real route tracking, \(routeTrackingCountdownText(for: remainingSeconds)) remaining"
                    : "Real route tracking"
            )
            .accessibilityHint("Tap to open settings. Touch and hold to start tracking.")
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
            .help("Real route tracking")
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

private struct ShakeToUndoDetector: UIViewRepresentable {
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

private final class ShakeToUndoView: UIView {
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

// MARK: - Share images

private struct MovesSharePlace: Identifiable {
    let id: String
    let title: String
    let visitCount: Int
    let totalDuration: TimeInterval
    let dayCount: Int
}

private struct MovesShareDay: Identifiable {
    let id: String
    let date: Date
    let distanceMeters: CLLocationDistance
    let moveDuration: TimeInterval
    let placeCount: Int
    let moveCount: Int
    let activityScore: Double
}

private struct MovesShareTransport: Identifiable {
    let mode: TransportMode
    let distanceMeters: CLLocationDistance
    let duration: TimeInterval
    let segmentCount: Int

    var id: String { mode.rawValue }
}

private struct MovesShareSnapshot {
    let periodLabel: String
    let recordedDayCount: Int
    let uniquePlaceCount: Int
    let visitCount: Int
    let moveCount: Int
    let totalDistanceMeters: CLLocationDistance
    let totalMoveDuration: TimeInterval
    let totalStepCount: Int
    let longestMoveMeters: CLLocationDistance
    let busiestWeekday: String?
    let topPlaces: [MovesSharePlace]
    let activeDays: [MovesShareDay]
    let transports: [MovesShareTransport]

    var hasContent: Bool {
        visitCount > 0 || moveCount > 0
    }

    static func make(from timelines: [DayTimeline], now: Date = .now) -> MovesShareSnapshot {
        let recordedDays = timelines.filter(\.hasRecordedActivity)
        let allPlaces = timelines.flatMap(\.places)
        let allMoves = timelines.flatMap(\.moves)
        let calendar = Calendar.autoupdatingCurrent

        struct PlaceAccumulator {
            var title: String
            var titlePriority: Int
            var visits = 0
            var duration: TimeInterval = 0
            var dayKeys = Set<String>()
        }

        var placesByCoordinate: [String: PlaceAccumulator] = [:]
        for place in allPlaces {
            let latitudeBucket = Int((place.latitude * 10_000).rounded())
            let longitudeBucket = Int((place.longitude * 10_000).rounded())
            let key = "\(latitudeBucket)|\(longitudeBucket)"
            let userLabel = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoLabel = place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateTitle: String
            let candidatePriority: Int

            if let userLabel, !userLabel.isEmpty {
                candidateTitle = userLabel
                candidatePriority = 2
            } else if let autoLabel, !autoLabel.isEmpty {
                candidateTitle = autoLabel
                candidatePriority = 1
            } else {
                candidateTitle = place.displayTitle
                candidatePriority = 0
            }

            var accumulator = placesByCoordinate[key] ?? PlaceAccumulator(
                title: candidateTitle,
                titlePriority: candidatePriority
            )
            if candidatePriority > accumulator.titlePriority {
                accumulator.title = candidateTitle
                accumulator.titlePriority = candidatePriority
            }
            accumulator.visits += 1
            let fallbackDeparture = min(
                now,
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: place.arrivalDate)) ?? now
            )
            accumulator.duration += max((place.departureDate ?? fallbackDeparture).timeIntervalSince(place.arrivalDate), 0)
            accumulator.dayKeys.insert(place.dayTimeline?.dayKey ?? DayTimeline.makeDayKey(for: place.arrivalDate))
            placesByCoordinate[key] = accumulator
        }

        let topPlaces = placesByCoordinate.map { key, value in
            MovesSharePlace(
                id: key,
                title: value.title,
                visitCount: value.visits,
                totalDuration: value.duration,
                dayCount: value.dayKeys.count
            )
        }
        .sorted {
            if $0.visitCount == $1.visitCount {
                if $0.totalDuration == $1.totalDuration {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.totalDuration > $1.totalDuration
            }
            return $0.visitCount > $1.visitCount
        }

        let activeDays = recordedDays.map { day in
            let distance = day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
            let duration = day.moves.reduce(0) { $0 + max($1.timelineDuration, 0) }
            let score = distance + duration / 4 + Double(day.uniqueLocationCount) * 500 + Double(day.moves.count) * 250
            return MovesShareDay(
                id: day.dayKey,
                date: day.dayStart,
                distanceMeters: distance,
                moveDuration: duration,
                placeCount: day.uniqueLocationCount,
                moveCount: day.moves.count,
                activityScore: score
            )
        }
        .sorted {
            if $0.activityScore == $1.activityScore {
                return $0.date > $1.date
            }
            return $0.activityScore > $1.activityScore
        }

        let transports = TransportMode.allCases.compactMap { mode -> MovesShareTransport? in
            guard mode != .stationary else { return nil }
            let moves = allMoves.filter { $0.transportMode == mode }
            guard !moves.isEmpty else { return nil }
            return MovesShareTransport(
                mode: mode,
                distanceMeters: moves.reduce(0) { $0 + max($1.distanceMeters, 0) },
                duration: moves.reduce(0) { $0 + max($1.timelineDuration, 0) },
                segmentCount: moves.count
            )
        }
        .sorted {
            if $0.distanceMeters == $1.distanceMeters {
                return $0.duration > $1.duration
            }
            return $0.distanceMeters > $1.distanceMeters
        }

        let weekdayTotals = Dictionary(grouping: activeDays) { day in
            calendar.component(.weekday, from: day.date)
        }
        let busiestWeekdayNumber = weekdayTotals.max { lhs, rhs in
            let leftScore = lhs.value.reduce(0) { $0 + $1.activityScore }
            let rightScore = rhs.value.reduce(0) { $0 + $1.activityScore }
            return leftScore < rightScore
        }?.key
        let busiestWeekday: String?
        if let weekday = busiestWeekdayNumber {
            let symbols = DateFormatter().weekdaySymbols ?? []
            busiestWeekday = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : nil
        } else {
            busiestWeekday = nil
        }

        let sortedDates = recordedDays.map(\.dayStart).sorted()
        let periodLabel: String
        if let first = sortedDates.first, let last = sortedDates.last {
            if calendar.isDate(first, inSameDayAs: last) {
                periodLabel = first.formatted(.dateTime.day().month(.abbreviated).year())
            } else {
                periodLabel = "\(first.formatted(.dateTime.day().month(.abbreviated).year())) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
            }
        } else {
            periodLabel = "No recorded activity"
        }

        return MovesShareSnapshot(
            periodLabel: periodLabel,
            recordedDayCount: recordedDays.count,
            uniquePlaceCount: placesByCoordinate.count,
            visitCount: allPlaces.count,
            moveCount: allMoves.count,
            totalDistanceMeters: allMoves.reduce(0) { $0 + max($1.distanceMeters, 0) },
            totalMoveDuration: allMoves.reduce(0) { $0 + max($1.timelineDuration, 0) },
            totalStepCount: allMoves.compactMap(\.stepCount).reduce(0, +),
            longestMoveMeters: allMoves.map(\.distanceMeters).max() ?? 0,
            busiestWeekday: busiestWeekday,
            topPlaces: topPlaces,
            activeDays: activeDays,
            transports: transports
        )
    }
}

private enum MovesShareDesign: String, CaseIterable, Identifiable {
    case overview
    case places
    case activeDays
    case transport

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .places: return "Top Places"
        case .activeDays: return "Active Days"
        case .transport: return "Transport Mix"
        }
    }
}

private enum MovesShareBackground: String, CaseIterable, Identifiable {
    case moves
    case sunrise
    case midnight
    case rainbow
    case light

    var id: Self { self }

    var title: String {
        switch self {
        case .moves: return "Moves"
        case .sunrise: return "Sunrise"
        case .midnight: return "Midnight"
        case .rainbow: return "Rainbow"
        case .light: return "Light"
        }
    }

    var isLight: Bool { self == .light }
}

private enum MovesShareAspect: String, CaseIterable, Identifiable {
    case portrait
    case square
    case landscape

    var id: Self { self }

    var title: String {
        switch self {
        case .portrait: return "Portrait"
        case .square: return "Square"
        case .landscape: return "Landscape"
        }
    }

    var renderSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }

    var ratio: CGFloat { renderSize.width / renderSize.height }
}

private struct MovesShareGalleryView: View {
    @Environment(\.dismiss) private var dismiss

    private let snapshot: MovesShareSnapshot
    @State private var shareTitle = "My Moves"
    @State private var background: MovesShareBackground = .moves
    @State private var aspect: MovesShareAspect = .portrait
    @State private var renderedImages: [MovesShareDesign: UIImage] = [:]
    @State private var selectedDesigns = Set<MovesShareDesign>()
    @State private var isRendering = false
    @State private var renderedCount = 0
    @State private var activityItems: [Any] = []
    @State private var showsShareSheet = false

    init(dayTimelines: [DayTimeline]) {
        snapshot = MovesShareSnapshot.make(from: dayTimelines)
    }

    private var effectiveTitle: String {
        let trimmed = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Moves" : trimmed
    }

    private var availableDesigns: [MovesShareDesign] {
        MovesShareDesign.allCases.filter { design in
            switch design {
            case .overview: return snapshot.hasContent
            case .places: return !snapshot.topPlaces.isEmpty
            case .activeDays: return !snapshot.activeDays.isEmpty
            case .transport: return !snapshot.transports.isEmpty
            }
        }
    }

    private var renderSignature: String {
        [
            effectiveTitle,
            background.rawValue,
            aspect.rawValue,
            snapshot.periodLabel,
            String(snapshot.visitCount),
            String(snapshot.moveCount),
            String(Int(snapshot.totalDistanceMeters.rounded()))
        ].joined(separator: "|")
    }

    private var canShareSelection: Bool {
        !selectedDesigns.isEmpty && selectedDesigns.allSatisfy { renderedImages[$0] != nil }
    }

    var body: some View {
        List {
            if !snapshot.hasContent {
                ContentUnavailableView(
                    "No Share Images",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Share images become available after Moves records places or movement.")
                )
            } else {
                Section {
                    NavigationLink {
                        MovesShareCustomizeView(
                            title: $shareTitle,
                            background: $background,
                            aspect: $aspect
                        )
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("\(effectiveTitle) · \(aspect.title) · \(background.title)")
                }

                Section {
                    if isRendering {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(
                                value: Double(renderedCount),
                                total: Double(max(availableDesigns.count, 1))
                            )
                            Text("Rendering \(renderedCount) of \(availableDesigns.count) share images")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(availableDesigns) { design in
                            MovesSharePreviewTile(
                                title: design.title,
                                image: renderedImages[design],
                                aspectRatio: aspect.ratio,
                                isSelected: selectedDesigns.contains(design),
                                selectAction: { toggleSelection(design) },
                                shareAction: { share([design]) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Designs")
                } footer: {
                    Text("Tap images to select several, or use the share button on a single design. Statistics are calculated entirely on this device.")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle("Share Images")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    share(Array(selectedDesigns))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!canShareSelection)
                .accessibilityLabel(selectedDesigns.count == 1 ? "Share Selected Image" : "Share Selected Images")
            }
        }
        .task(id: renderSignature) {
            await renderImages()
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: { activityItems = [] }) {
            MovesActivityView(activityItems: activityItems)
        }
    }

    private func toggleSelection(_ design: MovesShareDesign) {
        if selectedDesigns.contains(design) {
            selectedDesigns.remove(design)
        } else {
            selectedDesigns.insert(design)
        }
    }

    private func share(_ designs: [MovesShareDesign]) {
        let images = designs.compactMap { renderedImages[$0] }
        guard !images.isEmpty else { return }
        activityItems = images
        showsShareSheet = true
    }

    @MainActor
    private func renderImages() async {
        let designs = availableDesigns
        guard !designs.isEmpty else { return }

        isRendering = true
        renderedCount = 0
        renderedImages = [:]
        await Task.yield()

        var images: [MovesShareDesign: UIImage] = [:]
        for design in designs {
            if Task.isCancelled { return }
            let renderer = ImageRenderer(
                content: MovesShareCard(
                    snapshot: snapshot,
                    design: design,
                    title: effectiveTitle,
                    background: background,
                    aspect: aspect
                )
                .frame(width: aspect.renderSize.width, height: aspect.renderSize.height)
            )
            renderer.scale = 1
            if let image = renderer.uiImage {
                images[design] = image
                renderedImages = images
            }
            renderedCount += 1
            await Task.yield()
        }

        selectedDesigns.formIntersection(Set(designs))
        isRendering = false
    }
}

private struct MovesShareCustomizeView: View {
    @Binding var title: String
    @Binding var background: MovesShareBackground
    @Binding var aspect: MovesShareAspect

    var body: some View {
        Form {
            Section("Share Image Title") {
                TextField("Title", text: $title)
                Button("Reset to Default") { title = "My Moves" }
            }

            Section("Aspect Ratio") {
                Picker("Aspect Ratio", selection: $aspect) {
                    ForEach(MovesShareAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Background") {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(MovesShareBackground.allCases) { option in
                        Button {
                            background = option
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MovesShareBackgroundView(background: option)
                                    .frame(height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                background == option ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: background == option ? 3 : 1
                                            )
                                    }

                                Label(
                                    option.title,
                                    systemImage: background == option ? "checkmark.circle.fill" : "circle"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(background == option ? Color.accentColor : Color.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MovesSharePreviewTile: View {
    let title: String
    let image: UIImage?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let selectAction: () -> Void
    let shareAction: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: selectAction) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))

                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9), isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(7)
                }
                .padding(7)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2.5 : 1)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Button(action: shareAction) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(image == nil)
                .accessibilityLabel("Share \(title)")
            }
            .padding(.horizontal, 3)
        }
    }
}

private struct MovesActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MovesShareBackgroundView: View {
    let background: MovesShareBackground

    var body: some View {
        switch background {
        case .moves:
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.16, blue: 0.18),
                    Color(red: 0.03, green: 0.32, blue: 0.29),
                    Color(red: 0.93, green: 0.40, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sunrise:
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.08, blue: 0.30),
                    Color(red: 0.79, green: 0.20, blue: 0.28),
                    Color(red: 1.00, green: 0.68, blue: 0.25)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        case .midnight:
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.09),
                    Color(red: 0.04, green: 0.12, blue: 0.24),
                    Color(red: 0.14, green: 0.08, blue: 0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .rainbow:
            LinearGradient(
                colors: [.pink, .orange, .yellow, .green, .cyan, .blue, .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light:
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 0.97),
                    Color(red: 0.88, green: 0.95, blue: 0.93),
                    Color(red: 1.00, green: 0.93, blue: 0.83)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct MovesShareCard: View {
    let snapshot: MovesShareSnapshot
    let design: MovesShareDesign
    let title: String
    let background: MovesShareBackground
    let aspect: MovesShareAspect

    private var primary: Color { background.isLight ? .black : .white }
    private var secondary: Color { primary.opacity(background.isLight ? 0.62 : 0.76) }
    private var scale: CGFloat {
        switch aspect {
        case .portrait: return 1
        case .square: return 0.76
        case .landscape: return 0.64
        }
    }
    private var padding: CGFloat { max(68 * scale, 42) }

    var body: some View {
        ZStack {
            MovesShareBackgroundView(background: background)

            VStack(alignment: .leading, spacing: scaled(36, minimum: 18)) {
                header

                Group {
                    switch design {
                    case .overview:
                        overviewContent
                    case .places:
                        placesContent
                    case .activeDays:
                        activeDaysContent
                    case .transport:
                        transportContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer
            }
            .padding(padding)
        }
        .foregroundStyle(primary)
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(value * scale, minimum)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: scaled(22, minimum: 12)) {
            VStack(alignment: .leading, spacing: scaled(8, minimum: 5)) {
                Text(title)
                    .font(.system(size: scaled(68, minimum: 38), weight: .black, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)

                Text(design.title.uppercased())
                    .font(.system(size: scaled(23, minimum: 14), weight: .bold, design: .rounded))
                    .tracking(scaled(2.2, minimum: 1.2))
                    .foregroundStyle(secondary)
            }

            Spacer()

            Image(systemName: "location.fill")
                .font(.system(size: scaled(48, minimum: 29), weight: .bold))
                .frame(width: scaled(82, minimum: 50), height: scaled(82, minimum: 50))
                .background(primary.opacity(0.15), in: Circle())
                .overlay { Circle().stroke(primary.opacity(0.22), lineWidth: 2) }
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
            HStack(spacing: scaled(18, minimum: 10)) {
                metricTile(value: distanceText(snapshot.totalDistanceMeters), label: "distance")
                metricTile(value: "\(snapshot.uniquePlaceCount)", label: "places")
                metricTile(value: "\(snapshot.recordedDayCount)", label: "active days")
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: scaled(18, minimum: 10)
            ) {
                detailTile(symbol: "clock.fill", value: durationText(snapshot.totalMoveDuration), label: "moving")
                if snapshot.totalStepCount > 0 {
                    detailTile(symbol: "figure.walk", value: snapshot.totalStepCount.formatted(), label: "recorded steps")
                } else {
                    detailTile(symbol: "arrow.right", value: distanceText(snapshot.longestMoveMeters), label: "longest move")
                }
                detailTile(symbol: "arrow.triangle.swap", value: snapshot.moveCount.formatted(), label: "moves")
                detailTile(symbol: "mappin.and.ellipse", value: snapshot.visitCount.formatted(), label: "visits")
            }

            VStack(spacing: scaled(14, minimum: 8)) {
                if let place = snapshot.topPlaces.first {
                    highlightRow(
                        symbol: "heart.fill",
                        label: "Most visited",
                        value: place.title,
                        detail: "\(place.visitCount) visits"
                    )
                }
                if let day = snapshot.activeDays.first {
                    highlightRow(
                        symbol: "flame.fill",
                        label: "Most active",
                        value: day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                        detail: distanceText(day.distanceMeters)
                    )
                }
                if let transport = snapshot.transports.first {
                    highlightRow(
                        symbol: transport.mode.symbolName,
                        label: "Top transport",
                        value: transport.mode.title,
                        detail: distanceText(transport.distanceMeters)
                    )
                }
            }
        }
    }

    private var placesContent: some View {
        let places = Array(snapshot.topPlaces.prefix(aspect == .landscape ? 5 : 7))
        let maximumVisits = max(places.first?.visitCount ?? 1, 1)

        return VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                rankedBarRow(
                    rank: index + 1,
                    symbol: "mappin.circle.fill",
                    title: place.title,
                    value: "\(place.visitCount) \(place.visitCount == 1 ? "visit" : "visits")",
                    detail: "\(place.dayCount) \(place.dayCount == 1 ? "day" : "days") · \(durationText(place.totalDuration))",
                    progress: Double(place.visitCount) / Double(maximumVisits),
                    color: Color(red: 0.98, green: 0.50, blue: 0.24)
                )
            }
        }
    }

    private var activeDaysContent: some View {
        let days = Array(snapshot.activeDays.prefix(aspect == .landscape ? 5 : 7))
        let maximumScore = max(days.first?.activityScore ?? 1, 1)

        return VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                rankedBarRow(
                    rank: index + 1,
                    symbol: "calendar",
                    title: day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year()),
                    value: distanceText(day.distanceMeters),
                    detail: "\(day.placeCount) places · \(day.moveCount) moves · \(durationText(day.moveDuration))",
                    progress: day.activityScore / maximumScore,
                    color: Color(red: 0.22, green: 0.85, blue: 0.68)
                )
            }
        }
    }

    private var transportContent: some View {
        let transports = Array(snapshot.transports.prefix(aspect == .landscape ? 5 : 7))
        let usesDistance = snapshot.totalDistanceMeters > 0
        let maximum = max(
            transports.map { usesDistance ? $0.distanceMeters : $0.duration }.max() ?? 1,
            1
        )

        return VStack(alignment: .leading, spacing: scaled(26, minimum: 13)) {
            HStack(spacing: scaled(18, minimum: 10)) {
                metricTile(value: distanceText(snapshot.totalDistanceMeters), label: "total distance")
                metricTile(value: durationText(snapshot.totalMoveDuration), label: "time moving")
                metricTile(value: snapshot.busiestWeekday ?? "–", label: "busiest weekday")
            }

            VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
                ForEach(Array(transports.enumerated()), id: \.element.id) { index, transport in
                    rankedBarRow(
                        rank: index + 1,
                        symbol: transport.mode.symbolName,
                        title: transport.mode.title,
                        value: distanceText(transport.distanceMeters),
                        detail: "\(transport.segmentCount) segments · \(durationText(transport.duration))",
                        progress: (usesDistance ? transport.distanceMeters : transport.duration) / maximum,
                        color: MovesPalette.transport(transport.mode)
                    )
                }
            }
        }
    }

    private func metricTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(5, minimum: 3)) {
            Text(value)
                .font(.system(size: scaled(42, minimum: 23), weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text(label.uppercased())
                .font(.system(size: scaled(16, minimum: 10), weight: .bold, design: .rounded))
                .tracking(scaled(1.2, minimum: 0.7))
                .foregroundStyle(secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(22, minimum: 13))
        .background(primary.opacity(background.isLight ? 0.10 : 0.13), in: RoundedRectangle(cornerRadius: scaled(24, minimum: 15)))
        .overlay {
            RoundedRectangle(cornerRadius: scaled(24, minimum: 15))
                .stroke(primary.opacity(0.15), lineWidth: 2)
        }
    }

    private func detailTile(symbol: String, value: String, label: String) -> some View {
        HStack(spacing: scaled(16, minimum: 9)) {
            Image(systemName: symbol)
                .font(.system(size: scaled(29, minimum: 18), weight: .bold))
                .frame(width: scaled(50, minimum: 30), height: scaled(50, minimum: 30))
                .background(primary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: scaled(2, minimum: 1)) {
                Text(value)
                    .font(.system(size: scaled(28, minimum: 17), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(label)
                    .font(.system(size: scaled(17, minimum: 11), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(20, minimum: 12))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(20, minimum: 13)))
    }

    private func highlightRow(symbol: String, label: String, value: String, detail: String) -> some View {
        HStack(spacing: scaled(17, minimum: 10)) {
            Image(systemName: symbol)
                .font(.system(size: scaled(27, minimum: 17), weight: .bold))
                .frame(width: scaled(52, minimum: 32), height: scaled(52, minimum: 32))
                .background(primary.opacity(0.13), in: Circle())

            Text(label)
                .font(.system(size: scaled(18, minimum: 12), weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)

            Spacer()

            VStack(alignment: .trailing, spacing: scaled(2, minimum: 1)) {
                Text(value)
                    .font(.system(size: scaled(23, minimum: 15), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(detail)
                    .font(.system(size: scaled(16, minimum: 10), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, scaled(20, minimum: 12))
        .padding(.vertical, scaled(15, minimum: 9))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(20, minimum: 13)))
    }

    private func rankedBarRow(
        rank: Int,
        symbol: String,
        title: String,
        value: String,
        detail: String,
        progress: Double,
        color: Color
    ) -> some View {
        HStack(spacing: scaled(17, minimum: 10)) {
            Text("\(rank)")
                .font(.system(size: scaled(25, minimum: 16), weight: .black, design: .rounded))
                .frame(width: scaled(42, minimum: 26))

            Image(systemName: symbol)
                .font(.system(size: scaled(27, minimum: 17), weight: .bold))
                .frame(width: scaled(54, minimum: 33), height: scaled(54, minimum: 33))
                .background(color.opacity(background.isLight ? 0.20 : 0.28), in: Circle())

            VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: scaled(25, minimum: 16), weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.system(size: scaled(22, minimum: 14), weight: .bold, design: .rounded))
                        .lineLimit(1)
                }

                GeometryReader { geometry in
                    Capsule()
                        .fill(primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(color)
                                .frame(width: max(geometry.size.width * min(max(progress, 0), 1), scaled(10, minimum: 6)))
                        }
                }
                .frame(height: scaled(13, minimum: 8))

                Text(detail)
                    .font(.system(size: scaled(16, minimum: 10), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, scaled(20, minimum: 12))
        .padding(.vertical, scaled(17, minimum: 9))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(22, minimum: 14)))
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(snapshot.periodLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Text("Made with Moves")
        }
        .font(.system(size: scaled(18, minimum: 11), weight: .semibold, design: .rounded))
        .foregroundStyle(secondary)
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        Measurement(value: max(meters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        DurationFormatter.text(for: duration)
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
            for: DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
            configurations: configuration
        )

        ContentView()
            .modelContainer(container)
            .environmentObject(MovesLocationCaptureManager(modelContainer: container))
            .environmentObject(AppUndoController())
            .environmentObject(MovesCloudDataPresencePublisher(modelContainer: container))
    }
}
