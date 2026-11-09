import SwiftData
import SwiftUI

/// Top-level destinations in the iPhone shell.
enum MovesTab: String, Hashable, CaseIterable, Identifiable {
    case timeline
    case map
    case places
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return String(localized: "Timeline")
        case .map: return String(localized: "Map")
        case .places: return String(localized: "Places")
        case .insights: return String(localized: "Insights")
        }
    }

    var symbolName: String {
        switch self {
        case .timeline: return "calendar"
        case .map: return "map"
        case .places: return "mappin.and.ellipse"
        case .insights: return "chart.xyaxis.line"
        }
    }
}

/// Presentation state shared by the tab shell and the Timeline tab.
@MainActor
final class MovesRootController: ObservableObject {
    @Published var selectedTab: MovesTab = MovesRootController.initialTab()
    @Published var isShowingSettings = false
    @Published var isShowingStatisticsSearch = ProcessInfo.processInfo.environment["MOVES_OPEN_SEARCH"] == "1"
    @Published var isShowingRouteTrackingSettings = false
    @Published var isShowingDatePicker = false
    @Published var selectedDayKey = ""
    @Published var shouldOpenToday = false
    @Published var requestedPlaceID: UUID?
    @Published var requestedMoveDetailID: UUID?
    /// Opens a learned place in the Places tab (`moves://place/{knownPlaceID}`).
    @Published var requestedKnownPlaceID: UUID?
    @Published var requestedJumpDate: Date?
    /// When set, the Timeline tab locates this instant and highlights the row.
    @Published var requestedJumpMoment: Date?
    @Published var isShowingReviewInbox = false
    /// Applied once from `moves://map?from=&to=`, then cleared.
    @Published var requestedMapInterval: DateInterval?
    /// Opens a named trip (`moves://trip/{uuid}`) on Insights.
    @Published var requestedTripID: UUID?
    /// Opens the trip list (`moves://trips`) on Insights. Screenshot agents can also set `MOVES_OPEN_TRIPS=1`.
    @Published var shouldOpenTripsList = ProcessInfo.processInfo.environment["MOVES_OPEN_TRIPS"] == "1"

    /// Honors `MOVES_START_TAB` so agents can screenshot a destination without tapping.
    private static func initialTab() -> MovesTab {
        if let raw = ProcessInfo.processInfo.environment["MOVES_START_TAB"],
           let tab = MovesTab(rawValue: raw) {
            return tab
        }
        return .timeline
    }
}

/// A history source chosen on the last onboarding page.
private enum OnboardingImport {
    case google
    case photos
    case health
    case files
}

/// Owns the tab bar and keeps capture, undo, and sheets above tab identity.
struct MovesRootView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @EnvironmentObject private var photoLibrary: PhotoLibraryController
    @Environment(\.modelContext) private var modelContext

    @StateObject private var controller = MovesRootController()
    @State private var editController = TimelineEditController()
    @State private var undoToast = UndoToastPresenter()
    @AppStorage(OnboardingStorage.hasSeenKey) private var hasSeenOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var pendingOnboardingImport: OnboardingImport?
    @State private var isShowingGoogleImport = false
    @State private var isShowingPhotoImport = false
    @State private var isShowingHealthImport = false
    @State private var isShowingFileImport = false

    @Query(Self.earliestDayQuery) private var earliestDays: [DayTimeline]
    private static var earliestDayQuery: FetchDescriptor<DayTimeline> {
        var query = FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart)])
        query.fetchLimit = 1
        return query
    }
    @Query(filter: #Predicate<VisitPlace> { $0.reviewStateRaw == "pending" })
    private var pendingReviewVisits: [VisitPlace]

    @Query(filter: #Predicate<MoveSegment> { $0.reviewStateRaw == "pending" })
    private var pendingReviewMoves: [MoveSegment]

    var body: some View {
        @Bindable var editor = editController
        TabView(selection: $controller.selectedTab) {
            Tab("Timeline", systemImage: "calendar", value: MovesTab.timeline) {
                TimelineTabView()
            }
            .badge(pendingReviewVisits.count + pendingReviewMoves.count)

            Tab("Map", systemImage: "map", value: MovesTab.map) {
                MapTabView()
            }

            Tab("Places", systemImage: "mappin.and.ellipse", value: MovesTab.places) {
                PlacesTabView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                controller.isShowingStatisticsSearch = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .accessibilityLabel(String(localized: "Search"))
                        }
                    }
            }

            Tab("Insights", systemImage: "chart.xyaxis.line", value: MovesTab.insights) {
                InsightsTabView()
            }
        }
        .onAppear {
            modelContext.undoManager = undoController.manager
            editController.attach(
                modelContext: modelContext,
                undoController: undoController,
                toast: undoToast
            )
            applyLaunchJumpIfNeeded()
            presentOnboardingIfNeeded()
        }
        .onChange(of: earliestDays.isEmpty) { _, isEmpty in
            if isEmpty {
                presentOnboardingIfNeeded()
            } else if !hasSeenOnboarding {
                hasSeenOnboarding = true
            }
        }
        .sheet(isPresented: $controller.isShowingSettings) {
            TimelineHistorySheet { days in
                MovesSettingsView(dayTimelines: days, selectedDayKey: controller.selectedDayKey, captureManager: captureManager)
            }
        }
        .sheet(isPresented: $controller.isShowingStatisticsSearch) {
            TimelineHistorySheet { days in
                NavigationStack { MovesSearchView(dayTimelines: days) }
            }
        }
        .sheet(isPresented: $controller.isShowingRouteTrackingSettings) {
            RouteTrackingSettingsSheet(captureManager: captureManager)
        }
        .sheet(isPresented: $controller.isShowingDatePicker) {
            TimelineHistorySheet { days in
            MovesJumpToDateView(
                dayTimelines: days,
                selectedDate: days.first(where: { $0.dayKey == controller.selectedDayKey })?.dayStart ?? controller.requestedJumpMoment ?? .now,
                onSelectDate: { date in
                    controller.requestedJumpDate = date
                },
                onSelectMoment: { date in
                    controller.requestedJumpDate = date
                    controller.requestedJumpMoment = date
                },
                includesTime: true,
                onDismiss: { controller.isShowingDatePicker = false }
            )
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .sheet(isPresented: $controller.isShowingReviewInbox) {
            ReviewInboxView()
                .sheet(item: $editor.presentedSheet) { sheet in
                    editSheet(sheet)
                }
        }
        // A view can present only one sheet at a time, so the inbox presents its own edits.
        .sheet(item: Binding(
            get: { controller.isShowingReviewInbox ? nil : editController.presentedSheet },
            set: { editController.presentedSheet = $0 }
        )) { sheet in
            editSheet(sheet)
        }
        .confirmationDialog(
            String(localized: "Delete Place?"),
            isPresented: Binding(
                get: { editController.confirmDeletePlaceID != nil },
                set: { if !$0 { editController.confirmDeletePlaceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                editController.confirmPendingPlaceDeletion()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                editController.confirmDeletePlaceID = nil
            }
        } message: {
            Text(String(localized: "This stay was longer than an hour. You can undo afterwards."))
        }
        .alert(
            String(localized: "Couldn’t update the timeline"),
            isPresented: $editor.isShowingError
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(editController.errorMessage ?? "")
        }
        .undoToast(undoToast)
        .fullScreenCover(isPresented: $isShowingOnboarding, onDismiss: presentPendingOnboardingImport) {
            OnboardingFlow(
                onRequestLocation: {
                    captureManager.requestTrackingAuthorization()
                },
                onImportGoogle: { finishOnboarding(importing: .google) },
                onImportPhotos: { finishOnboarding(importing: .photos) },
                onImportHealth: { finishOnboarding(importing: .health) },
                onImportFiles: { finishOnboarding(importing: .files) },
                onSkip: { finishOnboarding() }
            )
        }
        .sheet(isPresented: $isShowingGoogleImport) {
            NavigationStack {
                GoogleTimelineImportSettingsView(modelContext: modelContext)
            }
        }
        .sheet(isPresented: $isShowingPhotoImport) {
            PhotoHistoryImportSheet(firstRecordedDayStart: earliestDays.first?.dayStart)
        }
        .sheet(isPresented: $isShowingHealthImport) {
            NavigationStack {
                HealthWorkoutRouteImportSettingsView()
            }
        }
        .sheet(isPresented: $isShowingFileImport) {
            NavigationStack {
                RouteFileImportSettingsView(modelContext: modelContext)
            }
        }
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
        // Outermost so every sheet above can read these too, not only the tabs.
        .environmentObject(controller)
        .environment(\.timelineItemActions, editController)
        .environment(\.timelineEditController, editController)
        .environment(\.undoToastPresenter, undoToast)
    }

    /// First-launch onboarding stays off while demo data seeds or screenshot flags are set.
    private var shouldPresentOnboarding: Bool {
        if ProcessInfo.processInfo.isRunningUnitTests { return false }
        let env = ProcessInfo.processInfo.environment
        if env["MOVES_OPEN_ONBOARDING"] == "1" { return true }
        if captureManager.isDemoMode { return false }
        if env["MOVES_START_TAB"] != nil
            || env["MOVES_OPEN_SETTINGS"] == "1"
            || env["MOVES_OPEN_SEARCH"] == "1"
            || env["MOVES_OPEN_TRIPS"] == "1"
            || env["MOVES_OPEN_SAVE_TRIP"] == "1"
            || env["MOVES_OPEN_TRIP"] == "1"
            || env["MOVES_OPEN_GOOGLE_IMPORT"] == "1"
            || env["MOVES_OPEN_WEBHOOK"] == "1"
            || env["MOVES_OPEN_ICLOUD"] == "1"
            || env["MOVES_OPEN_PRIVACY"] == "1"
            || env["MOVES_JUMP_DATE"] != nil
            || env["MOVES_OPEN_FIRST_PLACE"] == "1"
            || env["MOVES_OPEN_REVIEW"] == "1" {
            return false
        }
        return earliestDays.isEmpty && !hasSeenOnboarding
    }

    private func presentOnboardingIfNeeded() {
        guard shouldPresentOnboarding else { return }
        isShowingOnboarding = true
    }

    private func finishOnboarding(importing source: OnboardingImport? = nil) {
        pendingOnboardingImport = source
        hasSeenOnboarding = true
        isShowingOnboarding = false
    }

    /// A sheet can only come up once the cover is gone, and Photos asks for access first.
    private func presentPendingOnboardingImport() {
        let source = pendingOnboardingImport
        pendingOnboardingImport = nil
        switch source {
        case .google:
            isShowingGoogleImport = true
        case .photos:
            Task { @MainActor in
                if !photoLibrary.hasReadAccess {
                    let status = await photoLibrary.requestAccess()
                    guard status == .authorized || status == .limited else { return }
                }
                isShowingPhotoImport = true
            }
        case .health:
            isShowingHealthImport = true
        case .files:
            isShowingFileImport = true
        case nil:
            break
        }
    }

    /// Screenshot-agent launch flags (`MOVES_OPEN_ONBOARDING`, `MOVES_JUMP_DATE`, `MOVES_OPEN_SETTINGS`, `MOVES_OPEN_GOOGLE_IMPORT`, `MOVES_OPEN_WEBHOOK`, `MOVES_OPEN_ICLOUD`, `MOVES_OPEN_PRIVACY`, `MOVES_OPEN_REVIEW`, `MOVES_OPEN_SEARCH`, `MOVES_OPEN_TRIPS`, `MOVES_START_TAB`, `MOVES_OPEN_FIRST_PLACE`).
    private func applyLaunchJumpIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if env["MOVES_OPEN_SETTINGS"] == "1"
            || env["MOVES_OPEN_GOOGLE_IMPORT"] == "1"
            || env["MOVES_OPEN_WEBHOOK"] == "1"
            || env["MOVES_OPEN_ICLOUD"] == "1"
            || env["MOVES_OPEN_PRIVACY"] == "1" {
            controller.isShowingSettings = true
        }
        if env["MOVES_OPEN_REVIEW"] == "1" {
            controller.isShowingReviewInbox = true
        }
        if env["MOVES_OPEN_SEARCH"] == "1" {
            controller.isShowingStatisticsSearch = true
        }
        guard let raw = env["MOVES_JUMP_DATE"],
              let date = TimelineDeepLink.parseTimestamp(raw) else { return }
        controller.selectedTab = .timeline
        controller.requestedJumpDate = date
        if raw.contains("T") {
            controller.requestedJumpMoment = date
        }
    }

    @ViewBuilder
    private func editSheet(_ sheet: TimelineEditSheet) -> some View {
        switch sheet {
        case .rename(let id):
            if let visit = editController.visit(id: id) {
                PlaceRenameSheet(visit: visit, editController: editController)
            }
        case .pickNearby(let id):
            if let visit = editController.visit(id: id) {
                PlaceRenameSheet(visit: visit, focusesNearby: true, editController: editController)
            }
        case .editTimes(let id):
            if let visit = editController.visit(id: id) {
                EditTimesSheet(
                    visit: visit,
                    bounds: editController.timeBounds(for: visit),
                    editController: editController
                )
            }
        case .splitVisit(let id):
            if let visit = editController.visit(id: id) {
                SplitSheet(target: .visit(visit), editController: editController)
            }
        case .splitMove(let id):
            if let move = editController.move(id: id) {
                SplitSheet(target: .move(move), editController: editController)
            }
        case .changeMode(let id):
            if let move = editController.move(id: id) {
                TransportModePickerSheet(move: move, editController: editController)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "moves" else { return }

        switch url.host?.lowercased() {
        case "today":
            controller.selectedTab = .timeline
            controller.shouldOpenToday = true
        case "at":
            guard let moment = TimelineDeepLink.moment(from: url) else { return }
            controller.selectedTab = .timeline
            controller.requestedJumpDate = moment
            controller.requestedJumpMoment = moment
        case "tracking":
            controller.selectedTab = .timeline
            controller.isShowingRouteTrackingSettings = true
        case "place":
            guard let identifier = url.pathComponents.dropFirst().first,
                  let placeID = UUID(uuidString: identifier) else { return }
            if knownPlaceExists(placeID) {
                controller.selectedTab = .places
                controller.requestedKnownPlaceID = placeID
            } else {
                controller.selectedTab = .timeline
                controller.requestedPlaceID = placeID
            }
        case "calendar-visit":
            guard let id = CalendarVisit.ownedID(in: url) else { return }
            controller.selectedTab = .timeline
            controller.requestedPlaceID = id
        case "day":
            guard let raw = url.pathComponents.dropFirst().first,
                  let date = TimelineDeepLink.parseTimestamp(raw) else { return }
            controller.selectedTab = .timeline
            controller.requestedJumpDate = date
        case "map":
            controller.selectedTab = .map
            if let interval = MapDeepLink.interval(from: url) {
                controller.requestedMapInterval = interval
            }
        case "places":
            controller.selectedTab = .places
        case "insights":
            controller.selectedTab = .insights
        case "trips":
            controller.selectedTab = .insights
            controller.shouldOpenTripsList = true
        case "trip":
            guard let tripID = TripDeepLink.tripID(from: url) else { return }
            controller.selectedTab = .insights
            controller.requestedTripID = tripID
        case "review":
            controller.selectedTab = .timeline
            controller.isShowingReviewInbox = true
        case "settings":
            controller.isShowingSettings = true
        default:
            break
        }
    }

    private func knownPlaceExists(_ placeID: UUID) -> Bool {
        let identifier = placeID
        var descriptor = FetchDescriptor<KnownPlace>(
            predicate: #Predicate { $0.id == identifier }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor))?.isEmpty == false)
    }

    private func handleShakeToUndo() {
        undoToast.dismiss()
        editController.undoLastChange()
    }
}


/// Full history is observed only while a destination that needs it is presented.
private struct TimelineHistorySheet<Content: View>: View {
    @Query(sort: \DayTimeline.dayStart) private var days: [DayTimeline]
    @ViewBuilder var content: ([DayTimeline]) -> Content
    var body: some View { content(days) }
}
