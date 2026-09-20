import Charts
import SwiftData
import SwiftUI

/// Insights tab: one year at a glance, with year-over-year deltas and a share path into Years cards.
struct InsightsTabView: View {
    @EnvironmentObject private var rootController: MovesRootController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayTimeline.dayStart, order: .forward) private var dayTimelines: [DayTimeline]
    @State private var store = InsightsStore()
    @State private var path = NavigationPath()
    @State private var isShowingYearReview = false
    @State private var connectionsSnapshot: MovesStatisticsSnapshot?

    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if dayTimelines.contains(where: \.hasRecordedActivity) {
                    insightsScroll
                } else {
                    emptyState
                }
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(String(localized: "Insights"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(for: InsightsRoute.self) { route in
                switch route {
                case .countries:
                    InsightsPlaceListView(
                        title: String(localized: "Countries"),
                        rows: store.snapshot.countries
                    )
                case .cities:
                    InsightsPlaceListView(
                        title: String(localized: "Cities"),
                        rows: store.snapshot.cities
                    )
                case .connections:
                    InsightsConnectionsView(
                        snapshot: connectionsSnapshot ?? MovesStatisticsSnapshot(dayTimelines: dayTimelines)
                    )
                case .trips:
                    TripListView()
                }
            }
            .navigationDestination(for: UUID.self) { tripID in
                TripDetailView(tripID: tripID)
            }
        }
        .onAppear {
            reload()
            applyRequestedTrip()
            openTripsListIfRequested()
        }
        .onChange(of: dataSignature) { _, _ in reload() }
        .onChange(of: store.period) { _, _ in reload() }
        .onChange(of: rootController.requestedTripID) { _, _ in applyRequestedTrip() }
        .onChange(of: rootController.shouldOpenTripsList) { _, _ in
            openTripsListIfRequested()
        }
        .sheet(isPresented: $isShowingYearReview) {
            yearReviewSheet
        }
        .task {
            await PlaceGeocodeBackfill.runForegroundTrickle(in: modelContext.container)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                rootController.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(String(localized: "Settings"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                rootController.isShowingStatisticsSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel(String(localized: "Search"))
        }
    }

    private var insightsScroll: some View {
        ScrollView {
            VStack(spacing: 18) {
                yearChips
                heroCard
                activityCard
                geographyCard
                calendarCard
                streaksCard
                monthlyCard
                timeOfDayCard
                weekdayCard
                connectionsCard
                tripsButton
                yearInReviewButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label(String(localized: "Your year at a glance"), systemImage: "chart.xyaxis.line")
            } description: {
                Text(String(localized: "Walks, rides, countries, and streaks will show up here after a few recorded days."))
            }
            tripsButton
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 24)
    }

    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InsightsPeriod.ordered(store.snapshot.availableYears), id: \.id) { period in
                    let selected = store.period == period
                    Button {
                        store.period = period
                    } label: {
                        Text(periodTitle(period))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selected ? MovesPalette.place : Color(uiColor: .tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel(String(localized: "Year"))
    }

    private var heroCard: some View {
        InsightsCard {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MovesStatisticsFormatting.distance(store.snapshot.totalDistanceMeters))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(String(localized: "Distance"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(MovesStatisticsFormatting.duration(store.snapshot.totalMovingDuration))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(String(localized: "Moving"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text("^[\(store.snapshot.activeDayCount) active day](inflect: true)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var activityCard: some View {
        InsightsCard(title: String(localized: "Activity")) {
            if store.snapshot.modes.isEmpty {
                Text(String(localized: "No recorded movement in this period."))
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.snapshot.modes) { mode in
                        InsightsModeRow(mode: mode)
                    }
                }
            }
        }
    }

    private var geographyCard: some View {
        InsightsCard(title: String(localized: "Places")) {
            HStack(spacing: 10) {
                Button {
                    path.append(InsightsRoute.countries)
                } label: {
                    InsightsMetric(
                        title: String(localized: "Countries"),
                        value: store.snapshot.countries.count.formatted()
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.snapshot.countries.isEmpty)

                Button {
                    path.append(InsightsRoute.cities)
                } label: {
                    InsightsMetric(
                        title: String(localized: "Cities"),
                        value: store.snapshot.cities.count.formatted()
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.snapshot.cities.isEmpty)
            }

            if store.snapshot.countries.isEmpty {
                Text(String(localized: "Country and city counts appear after visits are named."))
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var calendarCard: some View {
        InsightsCard(title: String(localized: "Activity calendar")) {
            InsightsActivityCalendar(days: store.snapshot.calendarDays, calendar: calendar)
        }
    }

    private var streaksCard: some View {
        InsightsCard(title: String(localized: "Streaks")) {
            HStack(spacing: 10) {
                if store.snapshot.showsCurrentStreak {
                    InsightsMetric(
                        title: String(localized: "Current"),
                        value: streakLabel(store.snapshot.currentStreakDays)
                    )
                }
                InsightsMetric(
                    title: String(localized: "Longest"),
                    value: streakLabel(store.snapshot.longestStreakDays)
                )
            }
            Text(String(localized: "A day counts when you moved at least 500 m."))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var monthlyCard: some View {
        InsightsCard(title: monthlyTitle) {
            InsightsMonthlyChart(rows: store.snapshot.monthlyDistance, usesYears: isAllPeriod)
        }
    }

    private var timeOfDayCard: some View {
        InsightsCard(title: String(localized: "Time of day")) {
            InsightsHourChart(durations: store.snapshot.hourDurations, calendar: calendar)
        }
    }

    private var weekdayCard: some View {
        InsightsCard(title: String(localized: "Weekdays")) {
            InsightsWeekdayChart(durations: store.snapshot.weekdayDurations, calendar: calendar)
        }
    }

    private var connectionsCard: some View {
        InsightsCard(title: String(localized: "Connections")) {
            Text(String(localized: "How long it usually takes to get from one place to another."))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
            Button {
                connectionsSnapshot = MovesStatisticsSnapshot(dayTimelines: dayTimelines)
                path.append(InsightsRoute.connections)
            } label: {
                HStack {
                    Text(String(localized: "Find a connection"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var tripsButton: some View {
        Button {
            path.append(InsightsRoute.trips)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "suitcase.fill")
                    .font(.title3)
                    .foregroundStyle(MovesPalette.place)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Trips"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(String(localized: "Saved ranges from the Map"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MovesPalette.card.opacity(0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(MovesPalette.border, lineWidth: 1)
        }
        .accessibilityLabel(String(localized: "Trips"))
    }

    private var yearInReviewButton: some View {
        Button {
            isShowingYearReview = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                    .foregroundStyle(MovesPalette.place)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Year in review"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(String(localized: "Share a card for this year"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MovesPalette.card.opacity(0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(MovesPalette.border, lineWidth: 1)
        }
    }

    private var yearReviewSheet: some View {
        NavigationStack {
            MovesShareGalleryView(
                dayTimelines: dayTimelines,
                initialDate: yearReviewDate,
                initialPeriod: .year,
                showsDismissButton: true
            )
        }
    }

    private var dataSignature: String {
        let last = dayTimelines.last?.dayKey ?? ""
        let moves = dayTimelines.reduce(0) { $0 + $1.moves.count }
        let visits = dayTimelines.reduce(0) { $0 + $1.places.count }
        return "\(dayTimelines.count)|\(last)|\(moves)|\(visits)"
    }

    private var isAllPeriod: Bool {
        if case .all = store.period { return true }
        return false
    }

    private var monthlyTitle: String {
        isAllPeriod ? String(localized: "Yearly distance") : String(localized: "Monthly distance")
    }

    private var yearReviewDate: Date {
        if case .year(let year) = store.period {
            return calendar.date(from: DateComponents(year: year, month: 6, day: 15)) ?? .now
        }
        return .now
    }

    private func reload() {
        store.reload(days: dayTimelines, now: .now, calendar: calendar)
    }

    /// Deep links `moves://trip/{uuid}` land on Insights, then push the trip.
    private func applyRequestedTrip() {
        guard let tripID = rootController.requestedTripID else { return }
        rootController.requestedTripID = nil
        if !path.isEmpty {
            path = NavigationPath()
        }
        path.append(InsightsRoute.trips)
        path.append(tripID)
    }

    /// Deep links `moves://trips` and the screenshot flag `MOVES_OPEN_TRIPS`.
    private func openTripsListIfRequested() {
        guard rootController.shouldOpenTripsList else { return }
        rootController.shouldOpenTripsList = false
        if ProcessInfo.processInfo.environment["MOVES_OPEN_TRIPS"] == "1" {
            Task { @MainActor in
                await waitForSeededDays()
                _ = TripRangeStats.ensureScreenshotTrip(
                    covering: MapRangeSelection.today().focus,
                    in: modelContext,
                    calendar: calendar
                )
                path.append(InsightsRoute.trips)
            }
            return
        }
        path.append(InsightsRoute.trips)
    }

    private func waitForSeededDays() async {
        for _ in 0..<60 {
            if dayTimelines.contains(where: { !$0.places.isEmpty || !$0.moves.isEmpty }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func periodTitle(_ period: InsightsPeriod) -> String {
        switch period {
        case .year(let year):
            return String(year)
        case .all:
            return String(localized: "All")
        }
    }

    private func streakLabel(_ days: Int) -> String {
        days == 0 ? "0" : String(localized: "\(days) d")
    }
}

enum InsightsRoute: Hashable {
    case countries
    case cities
    case connections
    case trips
}

/// Copies SwiftData days, then builds snapshots off-main and memoizes by year + data signature.
@MainActor
@Observable
final class InsightsStore {
    var period: InsightsPeriod
    private(set) var snapshot: InsightsSnapshot
    private(set) var isComputing = false

    @ObservationIgnored
    private var cache: [String: InsightsSnapshot] = [:]
    @ObservationIgnored
    private var generation = 0

    init(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        let year = calendar.component(.year, from: now)
        let initial = InsightsPeriod.year(year)
        period = initial
        snapshot = .empty(period: initial, availableYears: [year])
    }

    func reload(days: [DayTimeline], now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        let records = days.map(InsightsDayRecord.init)
        let signature = "\(days.count)|\(days.last?.dayKey ?? "")|\(days.reduce(0) { $0 + $1.moves.count })"
        let key = "\(period.id)|\(signature)"
        if let cached = cache[key] {
            snapshot = cached
            isComputing = false
            return
        }

        generation += 1
        let gen = generation
        let selected = period
        isComputing = true
        Task.detached(priority: .userInitiated) {
            let built = InsightsSnapshotBuilder.build(
                days: records,
                period: selected,
                now: now,
                calendar: calendar
            )
            await MainActor.run {
                guard gen == self.generation else { return }
                self.cache[key] = built
                self.snapshot = built
                self.isComputing = false
            }
        }
    }
}

/// Rounded 20 pt card used throughout Insights.
struct InsightsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MovesPalette.card.opacity(0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(MovesPalette.border, lineWidth: 1)
        }
    }
}

private struct InsightsModeRow: View {
    let mode: InsightsSnapshot.ModeStats

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode.mode.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(MovesPalette.transport(mode.mode))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.mode.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(MovesStatisticsFormatting.distance(mode.distanceMeters))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(MovesStatisticsFormatting.duration(mode.duration))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let delta = deltaText {
                    Text(delta)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(deltaColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var deltaText: String? {
        if let fraction = mode.durationDeltaFraction ?? mode.distanceDeltaFraction {
            let percent = Int((fraction * 100).rounded())
            if percent == 0 { return "0%" }
            return percent > 0 ? "+\(percent)%" : "\(percent)%"
        }
        if mode.previousDistanceMeters == 0 && mode.distanceMeters > 0 {
            return String(localized: "New")
        }
        return nil
    }

    private var deltaColor: Color {
        guard let fraction = mode.durationDeltaFraction ?? mode.distanceDeltaFraction else {
            return .secondary
        }
        if fraction > 0.005 { return Color.green }
        if fraction < -0.005 { return Color.orange }
        return .secondary
    }

    private var accessibilityLabel: String {
        let delta = deltaText.map { " \($0)" } ?? ""
        return "\(mode.mode.title), \(MovesStatisticsFormatting.duration(mode.duration)), \(MovesStatisticsFormatting.distance(mode.distanceMeters))\(delta)"
    }
}

private struct InsightsPlaceListView: View {
    let title: String
    let rows: [InsightsSnapshot.PlaceCount]

    var body: some View {
        List(rows) { row in
            HStack(spacing: 12) {
                if !row.flagEmoji.isEmpty {
                    Text(row.flagEmoji)
                }
                Text(row.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Text("^[\(row.visitCount) visit](inflect: true)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// GitHub-style year grid, colored by distance. Future days stay empty.
private struct InsightsActivityCalendar: View {
    let days: [InsightsSnapshot.CalendarDay]
    var calendar: Calendar = .autoupdatingCurrent

    var body: some View {
        if days.isEmpty {
            Text(String(localized: "Not enough days to draw a calendar."))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            Chart(plotPoints) { point in
                RectangleMark(
                    x: .value(String(localized: "Week"), point.weekIndex),
                    y: .value(String(localized: "Day"), point.plotY)
                )
                .foregroundStyle(color(for: point.day, level: point.level))
                .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 2, 4, 6]) { value in
                    AxisValueLabel {
                        if let plotY = value.as(Int.self) {
                            let row = 6 - plotY
                            if weekdayLabels.indices.contains(row) {
                                Text(weekdayLabels[row])
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                            }
                        }
                    }
                }
            }
            .chartYScale(domain: -0.5...6.5)
            .chartLegend(.hidden)
            .frame(height: 128)
            .accessibilityLabel(String(localized: "\(activeCount) active days"))
            .accessibilityChartDescriptor(InsightsCalendarDescriptor(days: days))
        }
    }

    private var maximumDistance: Double {
        days.map(\.distanceMeters).max() ?? 0
    }

    private var activeCount: Int {
        days.filter(\.isActive).count
    }

    private var weekdayLabels: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { offset in
            symbols[(first + offset) % 7]
        }
    }

    private var plotPoints: [CalendarPlotPoint] {
        guard let first = days.first else { return [] }
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: first.date)?.start
            ?? first.date
        let maxDistance = maximumDistance
        return days.map { day in
            let weekday = calendar.component(.weekday, from: day.date)
            let row = (weekday - calendar.firstWeekday + 7) % 7
            let daysFromStart = calendar.dateComponents([.day], from: gridStart, to: day.date).day ?? 0
            let weekIndex = max(daysFromStart, 0) / 7
            return CalendarPlotPoint(
                id: day.dayKey,
                weekIndex: weekIndex,
                plotY: 6 - row,
                level: level(for: day.distanceMeters, maximum: maxDistance),
                day: day
            )
        }
    }

    private func level(for distance: Double, maximum: Double) -> Int {
        guard distance > 0, maximum > 0 else { return 0 }
        let fraction = distance / maximum
        if fraction < 0.25 { return 1 }
        if fraction < 0.5 { return 2 }
        if fraction < 0.75 { return 3 }
        return 4
    }

    private func color(for day: InsightsSnapshot.CalendarDay, level: Int) -> Color {
        if day.isFuture {
            return Color(uiColor: .tertiarySystemFill).opacity(0.35)
        }
        let base = MovesPalette.transport(.walking)
        switch level {
        case 0: return Color(uiColor: .tertiarySystemFill)
        case 1: return base.opacity(0.28)
        case 2: return base.opacity(0.48)
        case 3: return base.opacity(0.72)
        default: return base
        }
    }
}

private struct CalendarPlotPoint: Identifiable {
    let id: String
    let weekIndex: Int
    let plotY: Int
    let level: Int
    let day: InsightsSnapshot.CalendarDay
}

private struct InsightsCalendarDescriptor: AXChartDescriptorRepresentable {
    let days: [InsightsSnapshot.CalendarDay]

    func makeChartDescriptor() -> AXChartDescriptor {
        let active = days.filter(\.isActive).count
        let total = days.map(\.distanceMeters).reduce(0, +)
        return AXChartDescriptor(
            title: String(localized: "Activity calendar"),
            summary: String(localized: "\(active) active days, \(MovesStatisticsFormatting.distance(total)) in total."),
            xAxis: AXNumericDataAxisDescriptor(
                title: String(localized: "Day"),
                range: 0...Double(max(days.count - 1, 1)),
                gridlinePositions: []
            ) { "\($0)" },
            yAxis: AXNumericDataAxisDescriptor(
                title: String(localized: "Distance"),
                range: 0...max(days.map(\.distanceMeters).max() ?? 1, 1),
                gridlinePositions: []
            ) { MovesStatisticsFormatting.distance($0) },
            series: [
                AXDataSeriesDescriptor(
                    name: String(localized: "Distance"),
                    isContinuous: false,
                    dataPoints: days.enumerated().map { index, day in
                        AXDataPoint(x: Double(index), y: day.distanceMeters)
                    }
                )
            ]
        )
    }
}

private struct InsightsMonthlyChart: View {
    let rows: [InsightsSnapshot.MonthDistance]
    var usesYears: Bool

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value(
                    usesYears ? String(localized: "Year") : String(localized: "Month"),
                    row.date,
                    unit: usesYears ? .year : .month
                ),
                y: .value(String(localized: "Kilometers"), row.distanceMeters / 1_000)
            )
            .foregroundStyle(MovesPalette.transport(.cycling).gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: usesYears ? .year : .month, count: usesYears ? 1 : 3)) { _ in
                AxisValueLabel(format: usesYears ? .dateTime.year() : .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let km = value.as(Double.self) {
                        Text(km == 0 ? "0" : String(format: "%.0f", km))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 140)
        .accessibilityChartDescriptor(InsightsMonthlyDescriptor(rows: rows))
        .accessibilityLabel(String(localized: "Distance by month"))
    }
}

private struct InsightsMonthlyDescriptor: AXChartDescriptorRepresentable {
    let rows: [InsightsSnapshot.MonthDistance]

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: String(localized: "Monthly distance"),
            summary: String(localized: "Distance in kilometers"),
            xAxis: AXCategoricalDataAxisDescriptor(
                title: String(localized: "Month"),
                categoryOrder: rows.map(\.id)
            ),
            yAxis: AXNumericDataAxisDescriptor(
                title: String(localized: "Kilometers"),
                range: 0...max((rows.map(\.distanceMeters).max() ?? 1) / 1_000, 1),
                gridlinePositions: []
            ) { String(format: "%.1f", $0) },
            series: [
                AXDataSeriesDescriptor(
                    name: String(localized: "Distance"),
                    isContinuous: false,
                    dataPoints: rows.map { row in
                        AXDataPoint(x: row.id, y: row.distanceMeters / 1_000)
                    }
                )
            ]
        )
    }
}

private struct InsightsHourChart: View {
    let durations: [TimeInterval]
    var calendar: Calendar = .autoupdatingCurrent

    private var rows: [HourRow] {
        durations.enumerated().map { HourRow(hour: $0.offset, duration: $0.element) }
    }

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value(String(localized: "Hour"), row.hour),
                y: .value(String(localized: "Minutes"), row.duration / 60)
            )
            .foregroundStyle(MovesPalette.transport(.walking).gradient)
            .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(hourLabel(hour))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 120)
        .accessibilityLabel(String(localized: "Moving time by hour"))
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = calendar.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.setLocalizedDateFormatFromTemplate("J")
        return formatter.string(from: date)
    }
}

private struct HourRow: Identifiable {
    var id: Int { hour }
    let hour: Int
    let duration: TimeInterval
}

private struct InsightsWeekdayChart: View {
    let durations: [TimeInterval]
    var calendar: Calendar = .autoupdatingCurrent

    private var rows: [WeekdayRow] {
        let first = calendar.firstWeekday - 1
        return (0..<7).map { offset in
            let sundayIndex = (first + offset) % 7
            return WeekdayRow(
                order: offset,
                sundayIndex: sundayIndex,
                label: calendar.shortStandaloneWeekdaySymbols[sundayIndex],
                duration: durations.indices.contains(sundayIndex) ? durations[sundayIndex] : 0
            )
        }
    }

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value(String(localized: "Day"), row.label),
                y: .value(String(localized: "Hours"), row.duration / 3600)
            )
            .foregroundStyle(MovesPalette.place.gradient)
            .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 120)
        .accessibilityLabel(String(localized: "Moving time by weekday"))
    }
}

private struct WeekdayRow: Identifiable {
    var id: Int { order }
    let order: Int
    let sundayIndex: Int
    let label: String
    let duration: TimeInterval
}
