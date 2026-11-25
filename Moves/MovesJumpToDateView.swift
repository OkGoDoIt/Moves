import CoreLocation
import SwiftData
import SwiftUI

/// What "Most active days" ranks by.
enum ActiveDayFilter: String, CaseIterable, Identifiable, Sendable {
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
        case .overall: return .secondary
        case .placeCount: return MovesPalette.place
        case .onFoot: return MovesPalette.transport(.running)
        case .swimming: return MovesPalette.transport(.swimming)
        case .cycling: return MovesPalette.transport(.cycling)
        case .automotive: return MovesPalette.transport(.automotive)
        case .train: return MovesPalette.transport(.train)
        case .plane: return MovesPalette.transport(.plane)
        case .boat: return MovesPalette.transport(.boat)
        }
    }

    /// The filter a trip counts towards besides Overall; nil when its way of moving has none.
    fileprivate static func transport(for mode: TransportMode) -> Self? {
        switch mode {
        case .walking, .running: return .onFoot
        case .swimming: return .swimming
        case .cycling: return .cycling
        case .automotive: return .automotive
        case .train: return .train
        case .plane: return .plane
        case .boat: return .boat
        case .stationary, .unknown: return nil
        }
    }
}

private extension InsightsVisitRecord {
    var locationKey: String? {
        guard let latitude, let longitude else { return nil }
        return VisitPlace.locationKey(latitude: latitude, longitude: longitude)
    }
}

/// The busiest days for every filter, worked out once from plain values and off the main
/// thread. Ranking means reading every trip and stop ever recorded, so it must never happen
/// while a view is being drawn.
struct ActiveDayRanking: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        let dayStart: Date
        let placeCount: Int
        let moveCount: Int
        let distanceMeters: CLLocationDistance

        var id: Date { dayStart }
    }

    static let dayLimit = 5

    /// Overall and Places always; a way of moving only once some distance was covered that way.
    let filters: [ActiveDayFilter]
    private let daysByFilter: [ActiveDayFilter: [Day]]

    func days(for filter: ActiveDayFilter) -> [Day] {
        daysByFilter[filter] ?? []
    }

    init(_ records: [InsightsDayRecord]) {
        var candidates: [ActiveDayFilter: [(day: Day, score: Double)]] = [:]
        var distanceByFilter: [ActiveDayFilter: CLLocationDistance] = [:]

        for record in records {
            var distance: CLLocationDistance = 0
            var duration: TimeInterval = 0
            var scores: [ActiveDayFilter: Double] = [:]
            for move in record.moves {
                let moveDistance = max(move.distanceMeters, 0)
                let moveDuration = max(move.duration, 0)
                distance += moveDistance
                duration += moveDuration
                if let filter = ActiveDayFilter.transport(for: move.mode) {
                    scores[filter, default: 0] += moveDistance + moveDuration / 8
                    distanceByFilter[filter, default: 0] += moveDistance
                }
            }

            let placeCount = Set(record.visits.compactMap(\.locationKey)).count
            scores[.placeCount] = Double(placeCount)
            scores[.overall] = Double(placeCount) * 1_200
                + Double(record.moves.count) * 900
                + distance
                + duration / 8

            let day = Day(
                dayStart: record.dayStart,
                placeCount: placeCount,
                moveCount: record.moves.count,
                distanceMeters: distance
            )
            for (filter, score) in scores where score > 0 {
                candidates[filter, default: []].append((day, score))
            }
        }

        filters = ActiveDayFilter.allCases.filter { filter in
            filter == .overall || filter == .placeCount || distanceByFilter[filter, default: 0] > 0
        }
        daysByFilter = candidates.mapValues { days in
            days.sorted { ($0.score, $1.day.dayStart) > ($1.score, $0.day.dayStart) }
                .prefix(Self.dayLimit)
                .map(\.day)
        }
    }

    static func load(from container: ModelContainer) async throws -> Self {
        try await importWorkerValue(Task.detached(priority: .userInitiated) {
            let source = try InsightsSourceLoader.load(from: container)
            try Task.checkCancellation()
            return Self(source.days)
        })
    }
}

struct MovesJumpToDateView: View {
    private let earliestDayStart: Date?
    private let onSelectDate: (Date) -> Void
    private let onSelectMoment: ((Date) -> Void)?
    private let onDismiss: () -> Void
    private let allowsTimeSelection: Bool

    @State private var pickerDate: Date
    /// The last date handed to the caller. Its screen is rebuilt for every date it is given,
    /// so a date is handed over once the person settles on it, not on every tap or wheel tick.
    @State private var appliedDate: Date
    @State private var isTimeEnabled = false

    init(
        earliestDayStart: Date?,
        selectedDate: Date,
        onSelectDate: @escaping (Date) -> Void,
        onSelectMoment: ((Date) -> Void)? = nil,
        includesTime: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.earliestDayStart = earliestDayStart
        self.onSelectDate = onSelectDate
        self.onSelectMoment = onSelectMoment
        self.allowsTimeSelection = includesTime
        self.onDismiss = onDismiss
        _pickerDate = State(initialValue: selectedDate)
        _appliedDate = State(initialValue: selectedDate)
    }

    private var todayStart: Date {
        Calendar.autoupdatingCurrent.startOfDay(for: .now)
    }

    /// Through the end of today, so any time of day today is inside the range.
    private func selectableDates(from earliest: Date) -> ClosedRange<Date> {
        let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: todayStart) ?? .now
        return min(earliest, todayStart)...tomorrow.addingTimeInterval(-1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let earliestDayStart {
                        DatePicker(
                            "Date",
                            selection: $pickerDate,
                            in: selectableDates(from: earliestDayStart),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    }

                    HStack(spacing: 10) {
                        Button("Earliest") {
                            guard let earliestDayStart else { return }
                            choose(earliestDayStart)
                        }
                        .buttonStyle(.bordered)

                        Button("Today") {
                            choose(todayStart)
                        }
                        .buttonStyle(.bordered)
                    }

                    if allowsTimeSelection {
                        timeSelectionSection
                    }

                    MostActiveDaysSection(onSelect: choose)
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Jump to Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        apply()
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: pickerDate) {
            guard pickerDate != appliedDate else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            apply()
        }
        .onDisappear(perform: apply)
    }

    private func choose(_ date: Date) {
        pickerDate = date
        appliedDate = date
        onSelectDate(date)
        onDismiss()
    }

    private func apply() {
        guard pickerDate != appliedDate else { return }
        appliedDate = pickerDate
        onSelectDate(pickerDate)
    }

    private var timeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isTimeEnabled) {
                Text("Include time")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .tint(MovesPalette.routeTracking)

            if isTimeEnabled {
                DatePicker(
                    "Time",
                    selection: $pickerDate,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxHeight: 140)
                .clipped()
                .accessibilityLabel(String(localized: "Time"))

                Button {
                    appliedDate = pickerDate
                    onSelectMoment?(pickerDate)
                    onDismiss()
                } label: {
                    Text("Go to moment")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onSelectMoment == nil)
                .accessibilityHint(String(localized: "Opens that day and highlights where you were"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MovesPalette.card.opacity(0.8))
        )
    }
}

/// Its own view, so choosing a date or turning the time wheel never redraws the list, and
/// the list arriving never redraws the calendar.
private struct MostActiveDaysSection: View {
    let onSelect: (Date) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var ranking: ActiveDayRanking?
    @State private var filter: ActiveDayFilter = .overall
    @State private var isShowingFilterPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Most active days")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    isShowingFilterPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: filter.symbolName)
                            .foregroundStyle(filter.tint)
                        Text(filter.title)
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
                .disabled(ranking == nil)
                .popover(isPresented: $isShowingFilterPicker, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                    filterPickerContent
                }
            }

            if let ranking {
                let days = ranking.days(for: filter)
                if days.isEmpty {
                    Text("No matching days for this filter yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(days) { day in
                        row(for: day)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            ranking = (try? await ActiveDayRanking.load(from: modelContext.container)) ?? ActiveDayRanking([])
        }
    }

    private func row(for day: ActiveDayRanking.Day) -> some View {
        Button {
            onSelect(day.dayStart)
        } label: {
            HStack {
                Text(day.dayStart, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(day.placeCount) places")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("\(day.moveCount) moves")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(Measurement(value: day.distanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filterPickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity filter")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ForEach(ranking?.filters ?? []) { option in
                Button {
                    filter = option
                    isShowingFilterPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.symbolName)
                            .foregroundStyle(option.tint)
                            .frame(width: 20)

                        Text(option.title)
                            .foregroundStyle(.primary)

                        Spacer()

                        if filter == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(option.tint)
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
}
