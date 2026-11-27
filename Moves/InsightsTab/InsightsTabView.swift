import Charts
import Combine
import SwiftData
import SwiftUI

/// Insights tab: one year at a glance, with year-over-year deltas and a share path into Years cards.
struct InsightsTabView: View {
    @EnvironmentObject private var rootController: MovesRootController
    @EnvironmentObject private var health: HealthSummaryStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store = InsightsStore()
    @State private var path = NavigationPath()
    @State private var isShowingYearReview = false
    @State private var connectionsSnapshot: MovesStatisticsSnapshot?
    @State private var isScrolled = false
    @State private var pendingRemoval: PendingRemoval?
    @Environment(\.timelineEditController) private var editController

    private struct PendingRemoval: Identifiable {
        let removal: InsightsRemoval
        let closesPage: Bool
        var id: String { removal.id }
    }

    /// One day with a stop or three is taken off at once; Undo is right there. More asks first.
    private static let removalsWithoutAsking = 3

    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !store.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.hasRecordedActivity {
                    insightsScroll
                } else {
                    emptyState
                }
            }
            .background {
                // Flat under the navigation bar so its solid background meets the page seamlessly.
                LinearGradient(
                    stops: [
                        .init(color: MovesPalette.backgroundTop, location: 0),
                        .init(color: MovesPalette.backgroundTop, location: 0.25),
                        .init(color: MovesPalette.backgroundBottom, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(String(localized: "Insights"))
            .navigationBarTitleDisplayMode(.large)
            // Cards scrolled under the title sit behind the page's own colour instead of
            // showing through. Only while scrolled: kept on at the top, it hides the large title.
            .toolbarBackground(MovesPalette.backgroundTop, for: .navigationBar)
            .toolbarBackgroundVisibility(isScrolled ? .visible : .automatic, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: InsightsRoute.self) { route in
                switch route {
                case .countries:
                    InsightsWorldView(store: store, mode: .countries)
                case .cities:
                    InsightsWorldView(store: store, mode: .cities)
                // A country or city page covers the whole history, whatever year led to it.
                case .country(let code):
                    if let country = store.snapshot.allTimeGeography.country(code) {
                        InsightsCountryView(country: country)
                    } else {
                        ContentUnavailableView(String(localized: "Place unavailable"), systemImage: "mappin.slash")
                    }
                case .city(let id):
                    if let city = store.snapshot.allTimeGeography.city(id) {
                        InsightsCityView(city: city)
                    } else {
                        ContentUnavailableView(String(localized: "Place unavailable"), systemImage: "mappin.slash")
                    }
                case .connections:
                    if let connectionsSnapshot {
                        InsightsConnectionsView(snapshot: connectionsSnapshot)
                    } else {
                        ProgressView()
                            .task { await loadConnections() }
                    }
                case .trips:
                    TripListView()
                }
            }
            .navigationDestination(for: UUID.self) { tripID in
                TripDetailView(tripID: tripID)
            }
        }
        .environment(\.requestInsightsRemoval, InsightsRemovalRequest(perform: requestRemoval))
        .confirmationDialog(
            pendingRemoval.map(removalTitle) ?? Text(verbatim: ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { pending in
            Button(String(localized: "Remove"), role: .destructive) {
                performRemoval(pending.removal, closesPage: pending.closesPage)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { pending in
            Text("This takes ^[\(pending.removal.visitIDs.count) stop](inflect: true) off your timeline.")
        }
        .onAppear {
            reload()
            applyRequestedTrip()
            openTripsListIfRequested()
        }
        .onReceive(timelineChanges) { _ in reload() }
        .onChange(of: store.period) { _, _ in store.reloadCurrentPeriod(now: .now, calendar: calendar) }
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

    private func requestRemoval(
        _ scope: InsightsRemoval.Scope,
        placeName: String,
        stays: [InsightsGeography.Stay],
        closesPage: Bool
    ) {
        let removal = InsightsRemoval.make(scope: scope, placeName: placeName, stays: stays, in: modelContext)
        guard !removal.visitIDs.isEmpty else { return }
        if removal.dayCount == 1, removal.visitIDs.count <= Self.removalsWithoutAsking {
            performRemoval(removal, closesPage: closesPage)
        } else {
            pendingRemoval = PendingRemoval(removal: removal, closesPage: closesPage)
        }
    }

    /// A dialog title is drawn as plain text and shows `inflect` markup as typed, so the
    /// agreement ("1 day", "16 days") is worked out here first.
    private func removalTitle(_ pending: PendingRemoval) -> Text {
        let title = AttributedString(
            localized: "Remove ^[\(pending.removal.dayCount) day](inflect: true) in \(pending.removal.placeName)?"
        )
        return Text(verbatim: String(title.characters))
    }

    private func performRemoval(_ removal: InsightsRemoval, closesPage: Bool) {
        // The page would be left showing a place that is no longer in the history.
        if closesPage, !path.isEmpty {
            path.removeLast()
        }
        Task { @MainActor in
            await store.deleteWhenNotReading {
                editController?.removeVisits(ids: removal.visitIDs)
            }
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
                if store.snapshot.isEmptyPeriod {
                    emptyPeriodCard
                } else {
                    heroCard
                    activityCard
                    healthCard
                    geographyCard
                    calendarCard
                    monthlyCard
                    timeOfDayCard
                    weekdayCard
                }
                connectionsCard
                tripsButton
                yearInReviewButton
            }
            .padding(.horizontal, 16)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 12
        } action: { _, scrolled in
            isScrolled = scrolled
        }
        .movesFloatingTabBarClearance()
    }

    private var emptyPeriodCard: some View {
        InsightsCard {
            Text(emptyPeriodTitle)
                .font(.system(.headline, design: .rounded))
            Text(String(localized: "Trips and places you record will show up here."))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyPeriodTitle: String {
        if case .year(let year) = store.period {
            return String(localized: "Nothing recorded in \(String(year))")
        }
        return String(localized: "Nothing recorded yet")
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
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
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
        let snapshot = store.snapshot
        let hasAir = snapshot.airDistanceMeters > 0
        return InsightsCard {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 20))
            layout {
                InsightsHeadlineValue(
                    value: MovesStatisticsFormatting.distance(snapshot.groundDistanceMeters),
                    label: hasAir ? String(localized: "On the ground") : String(localized: "Distance")
                )
                InsightsHeadlineValue(
                    value: MovesStatisticsFormatting.duration(snapshot.groundMovingDuration),
                    label: String(localized: "Moving")
                )
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            if let comparison = snapshot.comparison,
               let fraction = comparison.deltaFraction(current: snapshot.groundDistanceMeters) {
                InsightsDeltaLabel(fraction: fraction, against: comparisonPhrase(comparison))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            if hasAir {
                Label {
                    Text(String(localized: "Plus \(MovesStatisticsFormatting.distance(snapshot.airDistanceMeters)) by air in \(MovesStatisticsFormatting.duration(snapshot.airMovingDuration))"))
                } icon: {
                    Image(systemName: TransportMode.plane.symbolName)
                        .foregroundStyle(MovesPalette.transport(.plane))
                }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
            }
            Text("^[\(snapshot.activeDayCount) active day](inflect: true)")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var activityCard: some View {
        let modes = store.snapshot.modes
        let ground = modes.filter { !$0.isAir }
        let air = modes.filter(\.isAir)
        let comparison = store.snapshot.comparison
        let showsDeltas = comparison != nil && modes.contains { $0.distanceDeltaFraction != nil }
        return InsightsCard(title: String(localized: "Activity")) {
            VStack(spacing: 12) {
                ForEach(ground) { mode in
                    InsightsModeRow(mode: mode, showsDelta: showsDeltas)
                }
                if !air.isEmpty {
                    if !ground.isEmpty { Divider() }
                    ForEach(air) { mode in
                        InsightsModeRow(mode: mode, showsDelta: showsDeltas)
                    }
                }
            }
            if showsDeltas, let comparison {
                Text(comparison.isSameDates
                     ? String(localized: "Change from the same dates in \(String(comparison.year)).")
                     : String(localized: "Change from \(String(comparison.year))."))
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Steps and walking distance from Apple Health, only when the setting is on and
    /// Health knows at least one day of the period.
    @ViewBuilder
    private var healthCard: some View {
        let keys = store.snapshot.periodDayKeys
        let totals = health.totals(forDayKeys: keys)
        if totals.steps != nil || totals.walkedMeters != nil {
            let knownKeys = keys.filter { health.daySummary(forDayKey: $0) != nil }
            InsightsCard(title: String(localized: "Apple Health")) {
                InsightsMetricRow {
                    if let steps = totals.steps {
                        InsightsMetric(title: String(localized: "Steps"), value: steps.formatted())
                            .accessibilityLabel(HealthSummaryText.steps(steps))
                    }
                    if let meters = totals.walkedMeters {
                        InsightsMetric(title: String(localized: "Walking distance"), value: HealthSummaryText.distance(meters))
                    }
                }
                if knownKeys.count < keys.count, let range = healthCoverage(knownKeys) {
                    Text(range)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var geographyCard: some View {
        let geography = store.snapshot.geography
        return InsightsCard(title: String(localized: "Places")) {
            if geography.countries.isEmpty {
                Text(String(localized: "Countries and cities appear once you’ve been somewhere."))
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    path.append(InsightsRoute.countries)
                } label: {
                    InsightsWorldThumbnail(
                        visited: geography.countryCodes,
                        everVisited: store.snapshot.allTimeGeography.countryCodes
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "World map"))
                InsightsMetricRow {
                    placeMetricButton(
                        title: String(localized: "Countries"),
                        count: geography.countries.count,
                        route: .countries
                    )
                    placeMetricButton(
                        title: String(localized: "Cities"),
                        count: geography.cityCount,
                        route: .cities
                    )
                }
            }
        }
    }

    private func placeMetricButton(title: String, count: Int, route: InsightsRoute) -> some View {
        Button {
            path.append(route)
        } label: {
            InsightsMetric(title: title, value: count.formatted(), showsDisclosure: count > 0)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }

    /// Active days and the streak on top, the days themselves month by month below.
    private var calendarCard: some View {
        let snapshot = store.snapshot
        return InsightsCard(title: String(localized: "Activity calendar")) {
            InsightsMetricRow {
                InsightsMetric(
                    title: String(localized: "Active days"),
                    value: snapshot.activeDayCount.formatted()
                )
                InsightsMetric(title: streakTitle, value: streakLabel(streakValue))
            }
            InsightsActivityCalendar(days: snapshot.calendarDays, calendar: calendar) { date in
                rootController.selectedTab = .timeline
                rootController.requestedJumpDate = date
            }
            .equatable()
        }
    }

    private var streakValue: Int {
        store.snapshot.showsCurrentStreak ? store.snapshot.currentStreakDays : store.snapshot.longestStreakDays
    }

    /// One tile says both: the streak running now, and how it compares with the longest.
    private var streakTitle: String {
        let snapshot = store.snapshot
        guard snapshot.showsCurrentStreak else { return String(localized: "Longest streak") }
        if snapshot.currentStreakDays > 1, snapshot.currentStreakDays >= snapshot.longestStreakDays {
            return String(localized: "Streak, your longest")
        }
        return String(localized: "Streak · longest \(snapshot.longestStreakDays)")
    }

    private var monthlyCard: some View {
        InsightsCard(title: monthlyTitle) {
            InsightsMonthlyChart(
                rows: store.snapshot.monthlyDistance,
                usesYears: isAllPeriod,
                leavesOutFlights: store.snapshot.airDistanceMeters > 0,
                calendar: calendar
            )
        }
    }

    private var timeOfDayCard: some View {
        InsightsCard(title: String(localized: "Time of day")) {
            InsightsHourChart(durations: store.snapshot.hourDurations, calendar: calendar)
        }
    }

    private var weekdayCard: some View {
        InsightsCard(title: String(localized: "Days of the week")) {
            InsightsWeekdayChart(durations: store.snapshot.weekdayDurations, calendar: calendar)
        }
    }

    private var connectionsCard: some View {
        InsightsCard(title: String(localized: "Connections")) {
            Text(String(localized: "How long it usually takes to get from one place to another."))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
            Button {
                connectionsSnapshot = nil
                path.append(InsightsRoute.connections)
            } label: {
                HStack {
                    Text(String(localized: "Find a connection"))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
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
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                    Text(String(localized: "Saved ranges from the Map"))
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                    Text(String(localized: "Share a card for this year"))
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
        InsightsYearReviewSheet(initialDate: yearReviewDate)
    }

    /// A save on any context that touched trips, stops, or days, read after it committed.
    /// Readers start from a fresh context, so they never depend on the main context's merge.
    private var timelineChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter(TimelineSaveFilter.touchesTimeline)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange))
            // The first save shows at once; after it, at most one reload every few seconds.
            // The place-name backfill saves after every lookup for as long as it runs, and
            // each reload rereads the whole history.
            .throttle(for: .seconds(4), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
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
        store.reload(container: modelContext.container, now: .now, calendar: calendar)
    }

    private func loadConnections() async {
        connectionsSnapshot = try? await MovesStatisticsSnapshot.load(from: modelContext.container)
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
            if store.hasLoaded, store.hasRecordedActivity {
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
        days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
    }

    private func comparisonPhrase(_ comparison: InsightsSnapshot.Comparison) -> String {
        comparison.isSameDates
            ? String(localized: "this time in \(String(comparison.year))")
            : String(comparison.year)
    }

    /// "Nov 12 – 25": the days Health has totals for, when they are fewer than the period.
    private func healthCoverage(_ knownKeys: [String]) -> String? {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        let dates = knownKeys.compactMap { parser.date(from: $0) }.sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if first == last {
            return String(localized: "For \(first.formatted(style))")
        }
        let span = (first..<last).formatted(.interval.month(.abbreviated).day())
        return String(localized: "For \(span)")
    }
}

/// Metric tiles side by side, stacked once text is too large for two across.
private struct InsightsMetricRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout { content() }
    }
}

/// Large headline number with a small label under it.
private struct InsightsHeadlineValue: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// "↗ +12% vs 2025": an arrow and a signed number, so the direction never rests on colour.
private struct InsightsDeltaLabel: View {
    let fraction: Double
    var against: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.secondary)
    }

    static func percentText(_ fraction: Double) -> String {
        if abs(fraction) < 0.005 { return String(localized: "About the same") }
        return fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
    }

    private var symbol: String {
        if abs(fraction) < 0.005 { return "equal" }
        return fraction > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private var text: String {
        let percent = Self.percentText(fraction)
        guard let against else { return percent }
        if abs(fraction) < 0.005 {
            return String(localized: "About the same as \(against)")
        }
        return String(localized: "\(percent) vs \(against)")
    }
}

/// Owns the day query the share gallery takes, so the Insights tab itself holds no rows.
private struct InsightsYearReviewSheet: View {
    let initialDate: Date
    @Query(sort: \DayTimeline.dayStart, order: .forward) private var dayTimelines: [DayTimeline]

    var body: some View {
        NavigationStack {
            MovesShareGalleryView(
                dayTimelines: dayTimelines,
                initialDate: initialDate,
                initialPeriod: .year,
                showsDismissButton: true
            )
        }
    }
}

enum InsightsRoute: Hashable {
    case countries
    case cities
    case country(String)
    case city(String)
    case connections
    case trips
}

/// Reads the store on a private context off the main actor, builds snapshots there, and
/// memoizes by year until the rows change. The last snapshot stays up while a reload runs.
@MainActor
@Observable
final class InsightsStore {
    var period: InsightsPeriod
    private(set) var snapshot: InsightsSnapshot
    private(set) var isComputing = false
    /// False until the first read finishes, so the tab shows neither zeros nor the empty state.
    private(set) var hasLoaded = false
    private(set) var hasRecordedActivity = false

    @ObservationIgnored
    private var cache: [String: InsightsSnapshot] = [:]
    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    private var loadGeneration = 0
    @ObservationIgnored
    private var records: [InsightsDayRecord] = []
    /// The cache key of `snapshot`; nil while it is the empty placeholder.
    @ObservationIgnored
    private var snapshotKey: String?
    /// Reads of the store still running. Each holds rows on a context of its own, and a
    /// stop deleted under one of them aborts the app the moment it reads that row.
    @ObservationIgnored
    private var readsInFlight = 0
    @ObservationIgnored
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    /// While a delete waits for the reads above, new ones wait for it.
    @ObservationIgnored
    private var readHolds = 0
    @ObservationIgnored
    private var heldReload: ModelContainer?

    init(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        let year = calendar.component(.year, from: now)
        let initial = InsightsPeriod.year(year)
        period = initial
        snapshot = .empty(period: initial, availableYears: [year])
    }

    /// Re-reads the store. Never touches a model on the main actor.
    func reload(container: ModelContainer, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        guard readHolds == 0 else {
            heldReload = container
            return
        }
        loadGeneration += 1
        let load = loadGeneration
        let current = hasLoaded ? InsightsSource(days: records, hasRecordedActivity: hasRecordedActivity) : nil
        isComputing = true
        readsInFlight += 1
        Task.detached(priority: .userInitiated) {
            let source: InsightsSource
            do {
                source = try InsightsSourceLoader.load(from: container)
            } catch {
                await MainActor.run {
                    self.finishRead()
                    guard load == self.loadGeneration else { return }
                    self.isComputing = false
                }
                return
            }
            // Most saves (a place name filled in, a fix on today) change nothing Insights
            // shows. Comparing the whole history happens here, not on the main actor, and
            // an unchanged read leaves the snapshot, and every view built on it, alone.
            let daysChanged = source.days != current?.days
            await MainActor.run {
                self.finishRead()
                guard load == self.loadGeneration else { return }
                self.apply(source, daysChanged: daysChanged, now: now, calendar: calendar)
            }
        }
    }

    /// Runs `delete` once the reads already running have finished, holding back any that
    /// would start meanwhile, then lets a held reload go.
    func deleteWhenNotReading(_ delete: () -> Void) async {
        readHolds += 1
        if readsInFlight > 0 {
            await withCheckedContinuation { readWaiters.append($0) }
        }
        delete()
        readHolds -= 1
        if readHolds == 0, let container = heldReload {
            heldReload = nil
            reload(container: container)
        }
    }

    private func finishRead() {
        readsInFlight -= 1
        guard readsInFlight == 0 else { return }
        let waiters = readWaiters
        readWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Takes values already read off the store; tests and the loader both end here.
    func apply(_ source: InsightsSource, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        apply(source, daysChanged: source.days != records, now: now, calendar: calendar)
    }

    private func apply(_ source: InsightsSource, daysChanged: Bool, now: Date, calendar: Calendar) {
        if !hasLoaded { hasLoaded = true }
        // Observable properties tell their views on every write, equal or not.
        if hasRecordedActivity != source.hasRecordedActivity {
            hasRecordedActivity = source.hasRecordedActivity
        }
        if daysChanged {
            records = source.days
            cache.removeAll()
        }
        reloadCurrentPeriod(now: now, calendar: calendar)
    }

    /// Switching a year chip reuses the rows already copied off SwiftData.
    func reloadCurrentPeriod(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        generation += 1
        // Streaks and the activity grid depend on today as well as on the rows.
        let key = "\(period.id)|\(calendar.startOfDay(for: now).timeIntervalSinceReferenceDate)"
        if let cached = cache[key] {
            // Writing the same snapshot again would still re-render every page built on it.
            if key != snapshotKey {
                snapshot = cached
                snapshotKey = key
            }
            isComputing = false
            return
        }

        let gen = generation
        let selected = period
        let records = records
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
                self.snapshotKey = key
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
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
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

/// One way of getting around: name and time on the left, distance (which adds up to
/// the headline) and its change on the right.
private struct InsightsModeRow: View {
    let mode: InsightsSnapshot.ModeStats
    /// Only when the card has an earlier span to compare with.
    var showsDelta: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            Image(systemName: mode.mode.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(MovesPalette.transport(mode.mode))
                .frame(width: iconWidth)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text(MovesStatisticsFormatting.duration(mode.duration))
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    Text(MovesStatisticsFormatting.distance(mode.distanceMeters))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    if let fraction = delta {
                        InsightsDeltaLabel(fraction: fraction)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                }
            }
            if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Trips with no mode, shown so the rows add up to the headline.
    private var title: String {
        mode.mode == .unknown ? String(localized: "Other") : mode.mode.title
    }

    private var delta: Double? {
        showsDelta ? mode.distanceDeltaFraction : nil
    }

    private var accessibilityLabel: String {
        let delta = delta.map { ", \(InsightsDeltaLabel.percentText($0))" } ?? ""
        return "\(title), \(MovesStatisticsFormatting.distance(mode.distanceMeters)), \(MovesStatisticsFormatting.duration(mode.duration))\(delta)"
    }
}

/// The world at a glance on the Places card.
private struct InsightsWorldThumbnail: View {
    let visited: Set<String>
    let everVisited: Set<String>
    @State private var geometry: WorldMapGeometry?

    var body: some View {
        ZStack {
            Color.clear.aspectRatio(WorldMapGeometry.aspectRatio, contentMode: .fit)
            if let geometry {
                WorldMapCanvas(
                    geometry: geometry,
                    content: WorldMapContent(visited: visited, visitedBefore: everVisited.subtracting(visited))
                )
                .equatable()
                .aspectRatio(WorldMapGeometry.aspectRatio, contentMode: .fit)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .task {
            let loaded = await WorldMapGeometry.load()
            withAnimation(.easeOut(duration: 0.25)) { geometry = loaded }
        }
    }
}

/// The period's days month by month, shaded by distance. Tapping a day shows its
/// distance and offers it on the Timeline. Future days stay faint.
private struct InsightsActivityCalendar: View, Equatable {
    let days: [InsightsSnapshot.CalendarDay]
    var calendar: Calendar = .autoupdatingCurrent
    var openDay: (Date) -> Void = { _ in }

    /// The months are laid out by calendar arithmetic, so they are drawn again only when
    /// the days change, not each time the Insights page re-renders around them. `openDay`
    /// only reaches the root controller, which never changes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.days == rhs.days && lhs.calendar == rhs.calendar
    }

    @State private var selectedKey: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if days.isEmpty {
            Text(String(localized: "Not enough days to draw a calendar."))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            let months = self.months
            let titles = monthTitles(months)
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount),
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(months) { month in
                        InsightsCalendarMonth(
                            month: month,
                            title: titles[month.id] ?? "",
                            selectedKey: selectedKey,
                            fill: { color(for: $0.day, level: $0.level) }
                        ) { day in
                            withAnimation(.snappy) {
                                selectedKey = selectedKey == day.dayKey ? nil : day.dayKey
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "\(activeCount) active days"))
                .accessibilityChartDescriptor(InsightsCalendarDescriptor(days: days))
                footer
                    .frame(minHeight: 36, alignment: .top)
            }
        }
    }

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 4
    }

    /// The tapped day, or the key to the shading.
    @ViewBuilder
    private var footer: some View {
        if let day = selectedDay {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.date.formatted(dayStyle))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text(dayDetail(day))
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    openDay(day.date)
                } label: {
                    Text(String(localized: "Open day"))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(MovesPalette.place)
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else {
            legend
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
        }
    }

    /// Less-to-more key, so the shading reads without guessing.
    private var legend: some View {
        HStack(spacing: 4) {
            Text(String(localized: "Less"))
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(forLevel: level))
                    .frame(width: 11, height: 11)
            }
            Text(String(localized: "More"))
        }
        .font(.system(.caption2, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var selectedDay: InsightsSnapshot.CalendarDay? {
        guard let selectedKey else { return nil }
        return days.first { $0.dayKey == selectedKey }
    }

    private var dayStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
    }

    private func dayDetail(_ day: InsightsSnapshot.CalendarDay) -> String {
        if day.distanceMeters > 0 { return MovesStatisticsFormatting.distance(day.distanceMeters) }
        return day.isActive ? String(localized: "Flights only") : String(localized: "No trips")
    }

    /// The last year's days touch thirteen months; the sliver of the first is left out.
    private var months: [InsightsCalendarMonthData] {
        let maximum = maximumDistance
        var result: [InsightsCalendarMonthData] = []
        for day in days {
            let parts = calendar.dateComponents([.year, .month, .day], from: day.date)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let id = "\(year)-\(month)"
            if result.last?.id != id {
                guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { continue }
                let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
                result.append(InsightsCalendarMonthData(id: id, start: start, year: year, month: month, offset: offset))
            }
            let index = result[result.count - 1].offset + dayOfMonth - 1
            guard result[result.count - 1].cells.indices.contains(index) else { continue }
            result[result.count - 1].cells[index] = InsightsCalendarCell(
                day: day,
                level: level(for: day.distanceMeters, maximum: maximum)
            )
        }
        if result.count > 12 { result.removeFirst(result.count - 12) }
        return result
    }

    /// "Mar", with the year on the first month and on January when the months span two years.
    private func monthTitles(_ months: [InsightsCalendarMonthData]) -> [String: String] {
        let spansYears = Set(months.map(\.year)).count > 1
        let short = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated)
        let withYear = short.year()
        var titles: [String: String] = [:]
        for (index, month) in months.enumerated() {
            let showsYear = spansYears && (index == 0 || month.month == 1)
            titles[month.id] = month.start.formatted(showsYear ? withYear : short)
        }
        return titles
    }

    private func color(forLevel level: Int) -> Color {
        let base = MovesPalette.transport(.walking)
        switch level {
        case 0: return Color(uiColor: .tertiarySystemFill)
        case 1: return base.opacity(0.28)
        case 2: return base.opacity(0.48)
        case 3: return base.opacity(0.72)
        default: return base
        }
    }

    /// The top of the shading scale: the 90th percentile of days with distance, so one
    /// very long day does not leave every other day at the palest shade.
    private var maximumDistance: Double {
        let distances = days.map(\.distanceMeters).filter { $0 > 0 }.sorted()
        guard !distances.isEmpty else { return 0 }
        return distances[Int(Double(distances.count - 1) * 0.9)]
    }

    private var activeCount: Int {
        days.filter(\.isActive).count
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
        // An active day never shows as empty, even next to a much longer day.
        return color(forLevel: day.isActive ? max(level, 1) : level)
    }
}

private struct InsightsCalendarCell {
    let day: InsightsSnapshot.CalendarDay
    let level: Int
}

/// One month laid out on its weeks: six rows of seven, so every month block is the same height.
private struct InsightsCalendarMonthData: Identifiable {
    let id: String
    let start: Date
    let year: Int
    let month: Int
    /// Blank cells before the 1st, counted from the locale's first weekday.
    let offset: Int
    var cells: [InsightsCalendarCell?] = Array(repeating: nil, count: 42)
}

private struct InsightsCalendarMonth: View {
    let month: InsightsCalendarMonthData
    let title: String
    let selectedKey: String?
    let fill: (InsightsCalendarCell) -> Color
    let select: (InsightsSnapshot.CalendarDay) -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Canvas { context, size in
                let cell = size.width / 7
                let inset = max(cell * 0.11, 0.75)
                for (index, entry) in month.cells.enumerated() {
                    guard let entry else { continue }
                    let frame = CGRect(
                        x: CGFloat(index % 7) * cell,
                        y: CGFloat(index / 7) * cell,
                        width: cell,
                        height: cell
                    ).insetBy(dx: inset, dy: inset)
                    let radius = frame.width * 0.28
                    context.fill(
                        Path(roundedRect: frame, cornerRadius: radius, style: .continuous),
                        with: .color(fill(entry))
                    )
                    if entry.day.dayKey == selectedKey {
                        let ring = frame.insetBy(dx: -inset * 0.9, dy: -inset * 0.9)
                        context.stroke(
                            Path(roundedRect: ring, cornerRadius: radius + inset, style: .continuous),
                            with: .color(.primary),
                            lineWidth: 1.5
                        )
                    }
                }
            }
            .aspectRatio(7.0 / 6.0, contentMode: .fit)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onTapGesture(coordinateSpace: .local) { location in
                guard width > 0 else { return }
                let cell = width / 7
                let index = Int(location.y / cell) * 7 + Int(location.x / cell)
                guard month.cells.indices.contains(index),
                      let entry = month.cells[index],
                      !entry.day.isFuture else { return }
                select(entry.day)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let active = month.cells.compactMap { $0 }.filter(\.day.isActive).count
        return String(localized: "\(title): \(active) active days")
    }
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

/// The answer above a chart: the highlighted bar's value, large, and what it is under it.
/// It follows the tapped bar, and the biggest one otherwise.
private struct InsightsChartHeadline: View {
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "9%", or "Under 1%" for a sliver that would otherwise round to nothing.
private func insightsShareText(_ fraction: Double) -> String {
    if fraction > 0, fraction < 0.005 { return String(localized: "Under 1%") }
    return fraction.formatted(.percent.precision(.fractionLength(0)))
}

private extension View {
    /// Tapping a bar selects it and keeps it selected; tapping it again, or tapping
    /// empty space, goes back to the default caption. Scrolling still passes through.
    func insightsTapSelection<ID: Equatable>(
        _ selection: Binding<ID?>,
        resolve: @escaping (ChartProxy, CGFloat) -> ID?
    ) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { tap in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = tap.location.x - geometry[plotFrame].origin.x
                            let tapped = resolve(proxy, x)
                            withAnimation(.snappy) {
                                selection.wrappedValue = tapped == selection.wrappedValue ? nil : tapped
                            }
                        }
                    )
            }
        }
    }
}

/// Axis value in the person's road unit with the unit written out: "150 mi", "1.2K km".
private enum InsightsAxisFormat {
    static var roadUnit: UnitLength {
        MovesStatisticsFormatting.roadUnitMeters == 1_000 ? .kilometers : .miles
    }

    static func distance(_ value: Double) -> String {
        if value == 0 { return "0" }
        return Measurement(value: value, unit: roadUnit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.notation(.compactName))
        )
    }
}

private struct InsightsMonthlyChart: View {
    let rows: [InsightsSnapshot.MonthDistance]
    var usesYears: Bool
    var leavesOutFlights: Bool
    var calendar: Calendar = .autoupdatingCurrent
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row = highlighted {
                InsightsChartHeadline(
                    value: row.distanceMeters > 0
                        ? MovesStatisticsFormatting.distance(row.distanceMeters)
                        : String(localized: "No trips"),
                    detail: detail(for: row)
                )
            } else {
                InsightsChartHeadline(value: MovesStatisticsFormatting.distance(0), detail: String(localized: "No trips on the ground yet"))
            }
            let highlightedID = highlighted?.id
            let plotted = Array(rows.enumerated())
            // Bars on a numeric axis, one unit each: a category axis labels every bar
            // whatever values it is given, which piled nineteen years on top of each other.
            Chart(plotted, id: \.element.id) { index, row in
                let distance = row.distanceMeters / MovesStatisticsFormatting.roadUnitMeters
                RectangleMark(
                    xStart: .value("Position", Double(index) + 0.14),
                    xEnd: .value("Position", Double(index) + 0.86),
                    yStart: .value("Distance", 0.0),
                    yEnd: .value("Distance", distance)
                )
                .foregroundStyle(MovesPalette.transport(.cycling).gradient)
                .opacity(highlightedID == nil || highlightedID == row.id ? 1 : 0.4)
                .cornerRadius(rows.count > 12 ? 3 : 4)
            }
            .chartXScale(domain: 0...Double(max(rows.count, 1)))
            .insightsTapSelection($selectedID) { proxy, x in
                guard let value: Double = proxy.value(atX: x) else { return nil }
                let index = Int(value.rounded(.down))
                return rows.indices.contains(index) ? rows[index].id : nil
            }
            .chartXAxis {
                AxisMarks(values: labelledPositions) { value in
                    AxisValueLabel(anchor: .top) {
                        if let position = value.as(Double.self) {
                            let index = Int(position.rounded(.down))
                            if rows.indices.contains(index) {
                                Text(shortName(rows[index]))
                                    .font(.system(.caption2, design: .rounded, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(InsightsAxisFormat.distance(amount))
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .frame(height: 150)
            .accessibilityChartDescriptor(InsightsMonthlyDescriptor(rows: rows, usesYears: usesYears))
            .accessibilityLabel(usesYears ? String(localized: "Distance by year") : String(localized: "Distance by month"))
        }
    }

    /// Every month gets its initial. Years are labelled on round numbers (every year,
    /// every second, fifth, or tenth), never more than six, so they never overlap.
    private var labelledPositions: [Double] {
        let step = usesYears ? ([1, 2, 5, 10, 20].first { rows.count / $0 <= 6 } ?? 50) : 1
        return rows.indices.compactMap { index in
            let year = calendar.component(.year, from: rows[index].date)
            return !usesYears || year % step == 0 ? Double(index) + 0.5 : nil
        }
    }

    private func shortName(_ row: InsightsSnapshot.MonthDistance) -> String {
        if usesYears { return String(calendar.component(.year, from: row.date)) }
        let index = calendar.component(.month, from: row.date) - 1
        let symbols = calendar.veryShortStandaloneMonthSymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private var selectedRow: InsightsSnapshot.MonthDistance? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    private var peak: InsightsSnapshot.MonthDistance? {
        guard let peak = rows.max(by: { $0.distanceMeters < $1.distanceMeters }), peak.distanceMeters > 0 else { return nil }
        return peak
    }

    /// The tapped bar, or the biggest.
    private var highlighted: InsightsSnapshot.MonthDistance? {
        selectedRow ?? peak
    }

    private func name(_ row: InsightsSnapshot.MonthDistance) -> String {
        usesYears
            ? String(calendar.component(.year, from: row.date))
            : row.date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide))
    }

    private func detail(for row: InsightsSnapshot.MonthDistance) -> String {
        let base: String
        if selectedRow != nil || rows.filter({ $0.distanceMeters > 0 }).count == 1 {
            base = name(row)
        } else {
            base = String(localized: "Most in \(name(row))")
        }
        return leavesOutFlights ? base + " · " + String(localized: "on the ground") : base
    }
}

private struct InsightsMonthlyDescriptor: AXChartDescriptorRepresentable {
    let rows: [InsightsSnapshot.MonthDistance]
    var usesYears: Bool

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: usesYears ? String(localized: "Yearly distance") : String(localized: "Monthly distance"),
            summary: String(localized: "Distance on the ground in \(MovesStatisticsFormatting.roadUnitTitle.lowercased())"),
            xAxis: AXCategoricalDataAxisDescriptor(
                title: String(localized: "Month"),
                categoryOrder: rows.map(\.id)
            ),
            yAxis: AXNumericDataAxisDescriptor(
                title: MovesStatisticsFormatting.roadUnitTitle,
                range: 0...max((rows.map(\.distanceMeters).max() ?? 1) / MovesStatisticsFormatting.roadUnitMeters, 1),
                gridlinePositions: []
            ) { String(format: "%.1f", $0) },
            series: [
                AXDataSeriesDescriptor(
                    name: String(localized: "Distance"),
                    isContinuous: false,
                    dataPoints: rows.map { row in
                        AXDataPoint(x: row.id, y: row.distanceMeters / MovesStatisticsFormatting.roadUnitMeters)
                    }
                )
            ]
        )
    }
}

private struct InsightsHourChart: View {
    let durations: [TimeInterval]
    var calendar: Calendar = .autoupdatingCurrent

    @State private var selectedHour: Int?

    private var rows: [HourRow] {
        durations.enumerated().map { HourRow(hour: $0.offset, duration: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row = highlighted {
                InsightsChartHeadline(value: Self.hourSpan(row.hour, calendar: calendar), detail: detail(for: row))
            } else {
                InsightsChartHeadline(value: "—", detail: String(localized: "No trips on the ground yet"))
            }
            let highlightedHour = highlighted?.hour
            Chart(rows) { row in
                // Each bar fills its own hour, so the quarter lines fall exactly between bars.
                let start = Double(row.hour) + 0.12
                let end = Double(row.hour) + 0.88
                let minutes = row.duration / 60
                RectangleMark(
                    xStart: .value("Hour", start),
                    xEnd: .value("Hour", end),
                    yStart: .value("Minutes", 0.0),
                    yEnd: .value("Minutes", minutes)
                )
                .foregroundStyle(MovesPalette.transport(.walking).gradient)
                .opacity(highlightedHour == nil || highlightedHour == row.hour ? 1 : 0.4)
                .cornerRadius(2)
            }
            .chartXScale(domain: 0...24)
            .insightsTapSelection($selectedHour) { proxy, x in
                guard let value: Double = proxy.value(atX: x) else { return nil }
                let hour = Int(value.rounded(.down))
                return (0...23).contains(hour) ? hour : nil
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 24]) { _ in
                    AxisGridLine()
                }
                AxisMarks(values: [3, 9, 15, 21]) { value in
                    AxisValueLabel(anchor: .top) {
                        if let quarter = value.as(Int.self) {
                            Text(Self.partOfDay(quarter))
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            // Four words share the width; past Large, "Evening" reaches the card's edge.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .frame(height: 120)
            .accessibilityChartDescriptor(InsightsHourDescriptor(durations: durations, calendar: calendar))
            .accessibilityLabel(String(localized: "Moving time by hour"))
        }
        // Another year's chart starts from its own busiest hour.
        .onChange(of: durations) { _, _ in selectedHour = nil }
    }

    private var selected: HourRow? {
        guard let selectedHour, rows.indices.contains(selectedHour) else { return nil }
        return rows[selectedHour]
    }

    private var peak: HourRow? {
        guard let peak = rows.max(by: { $0.duration < $1.duration }), peak.duration > 0 else { return nil }
        return peak
    }

    private var highlighted: HourRow? {
        selected ?? peak
    }

    private func detail(for row: HourRow) -> String {
        let total = durations.reduce(0, +)
        guard row.duration > 0, total > 0 else { return String(localized: "No trips at this hour") }
        let share = String(localized: "\(insightsShareText(row.duration / total)) of your time moving")
        return selected == nil ? String(localized: "Busiest hour") + " · " + share : share
    }

    /// The quarter of the day a label sits in the middle of.
    static func partOfDay(_ hour: Int) -> String {
        switch hour {
        case ..<6: return String(localized: "Night")
        case ..<12: return String(localized: "Morning")
        case ..<18: return String(localized: "Afternoon")
        default: return String(localized: "Evening")
        }
    }

    /// "6 AM" or "06" in the locale's own clock.
    static func hourLabel(_ hour: Int, calendar: Calendar) -> String {
        hourDate(hour, calendar: calendar).formatted(
            Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
                .hour(.defaultDigits(amPM: .abbreviated))
        )
    }

    /// "5 – 6 PM": the hour a bar covers.
    static func hourSpan(_ hour: Int, calendar: Calendar) -> String {
        let start = hourDate(hour, calendar: calendar)
        let end = start.addingTimeInterval(3_600)
        var style = Date.IntervalFormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        style = style.hour(.defaultDigits(amPM: .abbreviated))
        return (start..<end).formatted(style)
    }

    private static func hourDate(_ hour: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: .now)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today
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
                fullName: calendar.standaloneWeekdaySymbols[sundayIndex],
                duration: durations.indices.contains(sundayIndex) ? durations[sundayIndex] : 0
            )
        }
    }

    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .caption) private var shareWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 14

    /// Every day's share is written beside its bar, so nothing needs a tap.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let peak {
                InsightsChartHeadline(value: peak.fullName, detail: String(localized: "Busiest day"))
            } else {
                InsightsChartHeadline(value: "—", detail: String(localized: "No trips on the ground yet"))
            }
            let longest = rows.map(share).max() ?? 0
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(peak?.order == row.order ? .primary : .secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule(style: .continuous)
                                .fill(MovesPalette.place.gradient)
                                .opacity(peak == nil || peak?.order == row.order ? 1 : 0.45)
                                .frame(width: longest > 0 ? max(geometry.size.width * share(row) / longest, share(row) > 0 ? barHeight : 0) : 0)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: barHeight)
                        Text(insightsShareText(share(row)))
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: shareWidth, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.fullName), \(insightsShareText(share(row)))")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Moving time by day of the week"))
        }
    }

    private var total: TimeInterval {
        rows.reduce(0) { $0 + $1.duration }
    }

    private func share(_ row: WeekdayRow) -> Double {
        total > 0 ? row.duration / total : 0
    }

    private var peak: WeekdayRow? {
        guard let peak = rows.max(by: { $0.duration < $1.duration }), peak.duration > 0 else { return nil }
        return peak
    }
}

private struct WeekdayRow: Identifiable {
    var id: Int { order }
    let order: Int
    let sundayIndex: Int
    let label: String
    var fullName: String = ""
    let duration: TimeInterval
}

private struct InsightsHourDescriptor: AXChartDescriptorRepresentable {
    let durations: [TimeInterval]
    var calendar: Calendar = .autoupdatingCurrent

    func makeChartDescriptor() -> AXChartDescriptor {
        let calendar = calendar
        return AXChartDescriptor(
            title: String(localized: "Moving time by hour"),
            summary: String(localized: "Minutes moving"),
            xAxis: AXNumericDataAxisDescriptor(
                title: String(localized: "Hour"),
                range: 0...23,
                gridlinePositions: [0, 6, 12, 18]
            ) { InsightsHourChart.hourLabel(Int($0), calendar: calendar) },
            yAxis: AXNumericDataAxisDescriptor(
                title: String(localized: "Minutes"),
                range: 0...max((durations.max() ?? 1) / 60, 1),
                gridlinePositions: []
            ) { String(format: "%.0f", $0) },
            series: [
                AXDataSeriesDescriptor(
                    name: String(localized: "Moving"),
                    isContinuous: false,
                    dataPoints: durations.enumerated().map { hour, duration in
                        AXDataPoint(x: Double(hour), y: duration / 60)
                    }
                )
            ]
        )
    }
}

