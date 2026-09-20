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
    @Published var requestedJumpDate: Date?

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

    @Query(sort: \DayTimeline.dayStart, order: .forward)
    private var dayTimelines: [DayTimeline]

    private var selectedDay: DayTimeline? {
        dayTimelines.first { $0.dayKey == controller.selectedDayKey } ?? dayTimelines.last
    }

    var body: some View {
        TabView(selection: $controller.selectedTab) {
            Tab("Timeline", systemImage: "calendar", value: MovesTab.timeline) {
                ContentView()
            }

            Tab("Map", systemImage: "map", value: MovesTab.map) {
                MovesPlaceholderTabView(
                    title: MovesTab.map.title,
                    symbolName: "map.fill",
                    summary: String(localized: "See a day, a week, or a year on one map."),
                    detail: String(localized: "Filter by how you moved, scrub through time, and switch between routes, heat, and the streets you’ve covered.")
                )
            }

            Tab("Places", systemImage: "mappin.and.ellipse", value: MovesTab.places) {
                MovesPlaceholderTabView(
                    title: MovesTab.places.title,
                    symbolName: "mappin.and.ellipse",
                    summary: String(localized: "Places you actually go."),
                    detail: String(localized: "Home, work, and the café downstairs will be grouped by country and city, with how often you visit and how long you stay.")
                )
            }

            Tab("Insights", systemImage: "chart.xyaxis.line", value: MovesTab.insights) {
                MovesPlaceholderTabView(
                    title: MovesTab.insights.title,
                    symbolName: "chart.xyaxis.line",
                    summary: String(localized: "Your year at a glance."),
                    detail: String(localized: "Distance, countries, streaks, and time-of-day patterns — compared with last year when there’s enough history.")
                )
            }
        }
        .environmentObject(controller)
        .onAppear {
            modelContext.undoManager = undoController.manager
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
                selectedDate: selectedDay?.dayStart ?? .now,
                onSelectDate: { date in
                    controller.requestedJumpDate = date
                },
                onDismiss: { controller.isShowingDatePicker = false }
            )
        }
        .onOpenURL(perform: handleDeepLink)
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "moves" else { return }

        switch url.host?.lowercased() {
        case "today":
            controller.selectedTab = .timeline
            controller.shouldOpenToday = true
        case "tracking":
            controller.selectedTab = .timeline
            controller.isShowingRouteTrackingSettings = true
        case "place":
            guard let identifier = url.pathComponents.dropFirst().first,
                  let placeID = UUID(uuidString: identifier) else { return }
            controller.selectedTab = .timeline
            controller.requestedPlaceID = placeID
        case "map":
            controller.selectedTab = .map
        case "places":
            controller.selectedTab = .places
        case "insights":
            controller.selectedTab = .insights
        case "review":
            controller.selectedTab = .timeline
        default:
            break
        }
    }

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

/// Polished empty destination used until Map, Places, and Insights ship.
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
