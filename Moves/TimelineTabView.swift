import CoreLocation
import SwiftUI

/// Shared measurements for the iOS 26 floating tab bar.
///
/// TabView already contributes a bottom safe-area inset. Timeline content only
/// needs a few points of breathing room; map overlays ignore that inset and
/// need an explicit lift so Path / remarks stay above the tab pill.
enum MovesChromeMetrics {
    /// Extra space under mode chips so they are not flush with the tab bar.
    static let timelineTabBarBreathingRoom: CGFloat = 8

    /// Extra list/scroll padding so the last row sits above the floating tab pill.
    static let floatingTabBarClearance: CGFloat = 108

    /// Minimum overlay lift when a full-screen map does not inherit TabView's inset.
    static let detailOverlayTabBarClearance: CGFloat = 64
}

extension View {
    /// Keeps List and ScrollView content out from under the iOS 26 floating tab pill.
    ///
    /// TabView’s liquid-glass bar overlays the tab. `safeAreaInset` / `contentMargins`
    /// only add extra scroll range, so mid-list rows still draw through the pill.
    /// A layout sibling shrinks the viewport instead.
    func movesFloatingTabBarClearance() -> some View {
        // An inset, not a spacer: rows keep scrolling under the floating bar and the last
        // one can still scroll clear of it.
        safeAreaPadding(.bottom, MovesChromeMetrics.floatingTabBarClearance)
    }
}

/// Compact storyline clock that never wraps “AM” / “PM” onto a second glyph.
enum StorylineClock {
    /// Whether `locale` displays a 12-hour period (AM/PM) next to the time.
    static func usesTwelveHourClock(locale: Locale = .autoupdatingCurrent) -> Bool {
        switch locale.hourCycle {
        case .oneToTwelve, .zeroToEleven:
            return true
        case .oneToTwentyFour, .zeroToTwentyThree:
            return false
        @unknown default:
            return DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?
                .contains("a") ?? false
        }
    }

    /// Hour and minute only, so the period can sit on its own line.
    static func hourMinuteText(
        from date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("Jmm")
        return formatter.string(from: date)
    }

    /// Locale AM/PM symbol when the locale uses a 12-hour clock; otherwise `nil`.
    static func periodText(
        from date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard usesTwelveHourClock(locale: locale) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        let symbol = hour < 12 ? locale.calendar.amSymbol : locale.calendar.pmSymbol
        let text = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Timeline tab: wraps day paging so capture stays above the tab bar, and
/// hosts the header, mode chips, and moment-jump helpers that WS0
/// left as a placeholder.
struct TimelineTabView: View {
    var body: some View {
        ContentView()
    }
}

// MARK: - Day header

/// Weekday, date, live-now, and the day’s place / move / distance summary.
struct DayHeaderView: View {
    let day: DayTimeline
    let canGoOlder: Bool
    let canGoNewer: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onJumpToDate: () -> Void

    private var isToday: Bool {
        Calendar.autoupdatingCurrent.isDateInToday(day.dayStart)
    }

    private var totalDistanceMeters: CLLocationDistance {
        day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
    }

    private var statsText: String {
        let places = String(localized: "\(day.uniqueLocationCount) places")
        let moves = String(localized: "\(day.moves.count) moves")
        guard totalDistanceMeters > 1 else {
            return "\(places) · \(moves)"
        }
        let distance = Measurement(value: totalDistanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return "\(places) · \(moves) · \(distance)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOlder) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoOlder)
            .disabled(!canGoOlder)
            .accessibilityLabel(String(localized: "Previous day"))

            Button(action: onJumpToDate) {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(day.dayStart, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        if isToday {
                            liveNowBadge
                        }
                    }

                    Text(statsText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Jump to Date & Time"))
            .accessibilityHint(String(localized: "Opens the date and time picker"))

            Button(action: onNewer) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoNewer)
            .disabled(!canGoNewer)
            .accessibilityLabel(String(localized: "Next day"))
        }
    }

    private var liveNowBadge: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                Circle()
                    .fill(MovesPalette.routeTracking)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(String(localized: "Now"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Live now"))
    }
}

// MARK: - Activity chips

/// Compact height for the Timeline mode-filter chips (not the old 88pt bubbles).
enum ActivityChipSizing {
    static let rowHeight: CGFloat = 40
}

/// One transport mode’s moving time and distance for the chip row.
struct ActivityBubbleMetric: Identifiable, Equatable {
    let mode: TransportMode
    let duration: TimeInterval
    let distanceMeters: CLLocationDistance

    var id: String { mode.rawValue }

    var title: String { mode.title }
    var chipTitle: String { mode.chipTitle }
    var symbolName: String { mode.symbolName }
    var tint: Color { MovesPalette.transport(mode) }
}

enum ActivityBubbleMetrics {
    /// Groups a day’s moves by `TransportMode`, skipping stationary / unknown.
    static func make(from dayTimeline: DayTimeline) -> [ActivityBubbleMetric] {
        var durationByMode: [TransportMode: TimeInterval] = [:]
        var distanceByMode: [TransportMode: CLLocationDistance] = [:]

        for move in dayTimeline.moves {
            let mode = move.transportMode
            guard mode != .stationary, mode != .unknown else { continue }
            durationByMode[mode, default: 0] += move.timelineDuration
            distanceByMode[mode, default: 0] += max(move.distanceMeters, 0)
        }

        return TransportMode.allCases.compactMap { mode in
            let duration = durationByMode[mode] ?? 0
            let distance = distanceByMode[mode] ?? 0
            guard duration > 0 || distance > 0 else { return nil }
            return ActivityBubbleMetric(mode: mode, duration: duration, distanceMeters: distance)
        }
    }
}

/// Horizontal row of mode chips. Tap filters the day map to that mode;
/// tapping the active chip again clears the filter.
struct ActivityBubblesView: View {
    let metrics: [ActivityBubbleMetric]
    @Binding var filteredModes: Set<TransportMode>

    var body: some View {
        if metrics.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(metrics) { metric in
                        chip(for: metric)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ActivityChipSizing.rowHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Day activity"))
        }
    }

    private func chip(for metric: ActivityBubbleMetric) -> some View {
        let isSelected = filteredModes.contains(metric.mode)
        let duration = DurationFormatter.text(for: metric.duration)
        let distance = Measurement(value: max(metric.distanceMeters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        let hasDistance = metric.distanceMeters >= 1

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                if filteredModes == [metric.mode] {
                    filteredModes = []
                } else {
                    filteredModes = [metric.mode]
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: metric.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(hasDistance ? distance : duration)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(hasDistance ? "\(metric.chipTitle) · \(duration)" : metric.chipTitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
                .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : metric.tint)
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: ActivityChipSizing.rowHeight - 2)
            .background {
                Capsule()
                    .fill(isSelected ? metric.tint : metric.tint.opacity(0.12))
            }
            .overlay {
                Capsule()
                    .stroke(metric.tint.opacity(isSelected ? 0 : 0.45), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(duration), \(distance)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(String(localized: "Filters the map to this way of moving"))
    }
}

// MARK: - Moment jump

/// Maps a `TimelineLocator` result onto a storyline row id and map selection
/// so Jump to Time can scroll and highlight.
enum TimelineMomentJump {
    struct Target: Equatable {
        let entryID: String
        let mapSelection: TimelineMapSelection
        let visitID: UUID?
        let moveID: UUID?
    }

    /// Visit and move results highlight that item; gaps fall back to the
    /// nearest neighbour (the last known item, then the next).
    static func target(from result: TimelineLocator.Result) -> Target? {
        switch result {
        case .visit(let visit):
            return target(forVisit: visit)
        case .move(let move, _, _):
            return target(forMove: move)
        case .gap(let before, let after):
            if let before {
                return target(from: before)
            }
            if let after {
                return target(from: after)
            }
            return nil
        }
    }

    static func target(from item: TimelineLocator.Item) -> Target {
        switch item {
        case .visit(let visit):
            return target(forVisit: visit)
        case .move(let move):
            return target(forMove: move)
        }
    }

    static func target(forVisit visit: VisitPlace) -> Target {
        Target(
            entryID: "place-\(visit.id.uuidString)",
            mapSelection: .place(visit.id),
            visitID: visit.id,
            moveID: nil
        )
    }

    static func target(forMove move: MoveSegment) -> Target {
        Target(
            entryID: "move-\(move.id.uuidString)",
            mapSelection: .move(move.id),
            visitID: nil,
            moveID: move.id
        )
    }
}

/// Parses `moves://at/ISO8601` (and `moves://at?t=`) into a moment.
enum TimelineDeepLink {
    static func moment(from url: URL) -> Date? {
        guard url.scheme?.lowercased() == "moves" else { return nil }
        guard url.host?.lowercased() == "at" else { return nil }

        var raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if raw.isEmpty {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            raw = items.first(where: { $0.name == "t" || $0.name == "at" })?.value ?? ""
        }
        raw = raw.replacingOccurrences(of: " ", with: "+")
        guard !raw.isEmpty else { return nil }
        return parseTimestamp(raw)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        if !raw.contains("T"), raw.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.autoupdatingCurrent.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw).map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: raw) {
            return date
        }

        let local = ISO8601DateFormatter()
        local.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        local.timeZone = Calendar.autoupdatingCurrent.timeZone
        return local.date(from: raw)
    }
}

// MARK: - Compact map callout

/// Small capsule shown on the hero map when a place or move is selected.
struct TimelineMapCallout: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(MovesPalette.border, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}
