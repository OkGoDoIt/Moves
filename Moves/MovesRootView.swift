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
    @Published var isShowingStatisticsSearch = false
    @Published var isShowingRouteTrackingSettings = false
    @Published var isShowingDatePicker = false
    @Published var selectedDayKey = ""
    @Published var shouldOpenToday = false
    @Published var requestedPlaceID: UUID?
    /// Opens a learned place in the Places tab (`moves://place/{knownPlaceID}`).
    @Published var requestedKnownPlaceID: UUID?
    @Published var requestedJumpDate: Date?
    /// When set, the Timeline tab locates this instant and highlights the row.
    @Published var requestedJumpMoment: Date?
    @Published var isShowingReviewInbox = false
    /// Applied once from `moves://map?from=&to=`, then cleared.
    @Published var requestedMapInterval: DateInterval?
    /// Opens a trip from `moves://trip/{uuid}`.
    @Published var requestedTripID: UUID?

    /// Honors `MOVES_START_TAB` so agents can screenshot a destination without tapping.
    private static func initialTab() -> MovesTab {
        if let raw = ProcessInfo.processInfo.environment["MOVES_START_TAB"],
           let tab = MovesTab(rawValue: raw) {
            return tab
        }
        return .timeline
    }
}

/// Owns the tab bar and keeps capture, undo, and sheets above tab identity.
struct MovesRootView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @Environment(\.modelContext) private var modelContext

    @StateObject private var controller = MovesRootController()
    @State private var editController = TimelineEditController()
    @State private var undoToast = UndoToastPresenter()

    @Query(sort: \DayTimeline.dayStart, order: .forward)
    private var dayTimelines: [DayTimeline]

    @Query(filter: #Predicate<VisitPlace> { $0.reviewStateRaw == "pending" })
    private var pendingReviewVisits: [VisitPlace]

    @Query(filter: #Predicate<MoveSegment> { $0.reviewStateRaw == "pending" })
    private var pendingReviewMoves: [MoveSegment]

    private var selectedDay: DayTimeline? {
        dayTimelines.first { $0.dayKey == controller.selectedDayKey } ?? dayTimelines.last
    }

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
            }

            Tab("Insights", systemImage: "chart.xyaxis.line", value: MovesTab.insights) {
                InsightsTripsGatewayView()
            }
        }
        .environmentObject(controller)
        .environment(\.timelineItemActions, editController)
        .environment(\.timelineEditController, editController)
        .environment(\.undoToastPresenter, undoToast)
        .onAppear {
            modelContext.undoManager = undoController.manager
            editController.attach(
                modelContext: modelContext,
                undoController: undoController,
                toast: undoToast
            )
            applyLaunchJumpIfNeeded()
        }
        .sheet(isPresented: $controller.isShowingSettings) {
            MovesSettingsView(
                dayTimelines: dayTimelines,
                selectedDayKey: controller.selectedDayKey,
                captureManager: captureManager
            )
        }
        .sheet(isPresented: $controller.isShowingStatisticsSearch) {
            NavigationStack {
                MovesStatisticsSearchView(
                    dayTimelines: dayTimelines,
                    initialDate: selectedDay?.dayStart ?? .now
                )
            }
        }
        .sheet(isPresented: $controller.isShowingRouteTrackingSettings) {
            RouteTrackingSettingsSheet(captureManager: captureManager)
        }
        .sheet(isPresented: $controller.isShowingDatePicker) {
            MovesJumpToDateView(
                dayTimelines: dayTimelines,
                selectedDate: selectedDay?.dayStart ?? controller.requestedJumpMoment ?? .now,
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
        .onOpenURL(perform: handleDeepLink)
        .sheet(isPresented: $controller.isShowingReviewInbox) {
            ReviewInboxView()
        }
        .sheet(item: $editor.presentedSheet) { sheet in
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
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
    }

    /// Screenshot-agent launch flags (`MOVES_JUMP_DATE`, `MOVES_OPEN_SETTINGS`, `MOVES_OPEN_REVIEW`, `MOVES_START_TAB`, `MOVES_OPEN_FIRST_PLACE`).
    private func applyLaunchJumpIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if env["MOVES_OPEN_SETTINGS"] == "1" {
            controller.isShowingSettings = true
        }
        if env["MOVES_OPEN_REVIEW"] == "1" {
            controller.isShowingReviewInbox = true
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

/// Polished empty destination used until Insights ships.
struct MovesPlaceholderTabView: View {
    let title: String
    let symbolName: String
    let summary: String
    let detail: String

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 22) {
                    Image(systemName: symbolName)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 96, height: 96)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    VStack(spacing: 10) {
                        Text(summary)
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text(detail)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 8)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .panelSurface()
                .padding(.horizontal, 20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
