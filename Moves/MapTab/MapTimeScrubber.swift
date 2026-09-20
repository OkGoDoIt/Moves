import SwiftUI

/// Canvas histogram with two handles. Drag a handle to crop, drag the middle to slide,
/// pinch to change grain, double-tap to reset.
struct MapTimeScrubber: View {
    let buckets: [MapHistogramBucket]
    @Binding var selection: MapRangeSelection
    var calendar: Calendar = .autoupdatingCurrent
    var now: Date = .now

    @State private var drag: DragKind?
    @GestureState private var pinchScale: CGFloat = 1

    private enum DragKind {
        case start
        case end
        case slide(original: DateInterval)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(selection.focusCaption(now: now, calendar: calendar))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = proxy.size.height
                let maxMinutes = max(buckets.map(\.movingMinutes).max() ?? 0, 1)
                let startX = x(for: selection.focus.start, width: width)
                let endX = x(for: selection.focus.end, width: width)

                ZStack(alignment: .bottom) {
                    histogram(maxMinutes: maxMinutes, width: width, height: height, startX: startX, endX: endX)
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                        .offset(y: -10)
                    Capsule()
                        .fill(MovesPalette.routeTracking)
                        .frame(width: max(endX - startX, 6), height: 3)
                        .position(x: (startX + endX) / 2, y: height - 11)
                    handle(at: startX, height: height)
                    handle(at: endX, height: height)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
                .simultaneousGesture(pinchGesture)
                .onTapGesture(count: 2) {
                    selection = selection.resettingFocus()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Time range"))
                .accessibilityValue(selection.focusCaption(now: now, calendar: calendar))
                .accessibilityAdjustableAction { direction in
                    nudge(direction == .increment ? 1 : -1)
                }
            }
            .frame(height: 52)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func histogram(
        maxMinutes: Double,
        width: CGFloat,
        height: CGFloat,
        startX: CGFloat,
        endX: CGFloat
    ) -> some View {
        Canvas { context, size in
            guard !buckets.isEmpty else { return }
            let barWidth = max(size.width / CGFloat(buckets.count) - 1.5, 1)
            for (index, bucket) in buckets.enumerated() {
                let x = CGFloat(index) / CGFloat(buckets.count) * size.width + 0.75
                let fraction = CGFloat(bucket.movingMinutes / maxMinutes)
                let barHeight = max(3, fraction * (size.height - 18))
                let rect = CGRect(x: x, y: size.height - 14 - barHeight, width: barWidth, height: barHeight)
                let mid = x + barWidth / 2
                let inside = mid >= startX && mid <= endX
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(MovesPalette.routeTracking.opacity(inside ? 0.85 : 0.22))
                )
            }
        }
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 7, height: 22)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .position(x: x, y: height - 18)
            .allowsHitTesting(false)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    drag = kind(for: value.startLocation.x, width: width)
                }
                apply(drag: drag, translation: value.translation.width, location: value.location.x, width: width)
            }
            .onEnded { _ in
                drag = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let midpoint = selection.focus.start.addingTimeInterval(selection.focus.duration / 2)
                if value > 1.18, let finer = selection.granularity.finer {
                    selection = selection.switchingGranularity(to: finer, around: midpoint, now: now, calendar: calendar)
                } else if value < 0.84, let coarser = selection.granularity.coarser {
                    selection = selection.switchingGranularity(to: coarser, around: midpoint, now: now, calendar: calendar)
                }
            }
    }

    private func kind(for x: CGFloat, width: CGFloat) -> DragKind {
        let startX = self.x(for: selection.focus.start, width: width)
        let endX = self.x(for: selection.focus.end, width: width)
        if abs(x - startX) < 22 { return .start }
        if abs(x - endX) < 22 { return .end }
        if x > startX && x < endX { return .slide(original: selection.focus) }
        return abs(x - startX) < abs(x - endX) ? .start : .end
    }

    private func apply(drag: DragKind?, translation: CGFloat, location: CGFloat, width: CGFloat) {
        guard let drag else { return }
        switch drag {
        case .start:
            let date = date(at: location, width: width)
            let latest = selection.focus.end.addingTimeInterval(-minimumDuration)
            selection = selection.withFocus(
                DateInterval(start: min(date, latest), end: selection.focus.end)
            )
        case .end:
            let date = date(at: location, width: width)
            let earliest = selection.focus.start.addingTimeInterval(minimumDuration)
            selection = selection.withFocus(
                DateInterval(start: selection.focus.start, end: max(date, earliest))
            )
        case .slide(let original):
            let delta = durationDelta(for: translation, width: width)
            var start = original.start.addingTimeInterval(delta)
            var end = original.end.addingTimeInterval(delta)
            if start < selection.interval.start {
                end += selection.interval.start.timeIntervalSince(start)
                start = selection.interval.start
            }
            if end > selection.interval.end {
                start -= end.timeIntervalSince(selection.interval.end)
                end = selection.interval.end
            }
            selection = selection.withFocus(DateInterval(start: start, end: end))
        }
    }

    private var minimumDuration: TimeInterval {
        switch selection.granularity {
        case .day: return 15 * 60
        case .week, .month: return 6 * 60 * 60
        case .year: return 7 * 24 * 60 * 60
        case .allTime: return 24 * 60 * 60
        }
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        let start = selection.interval.start.timeIntervalSinceReferenceDate
        let end = selection.interval.end.timeIntervalSinceReferenceDate
        let span = max(end - start, 1)
        let t = (date.timeIntervalSinceReferenceDate - start) / span
        return CGFloat(min(max(t, 0), 1)) * width
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
        let t = min(max(x / max(width, 1), 0), 1)
        let start = selection.interval.start.timeIntervalSinceReferenceDate
        let end = selection.interval.end.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: start + (end - start) * Double(t))
    }

    private func durationDelta(for translation: CGFloat, width: CGFloat) -> TimeInterval {
        Double(translation / max(width, 1)) * selection.interval.duration
    }

    private func nudge(_ direction: Int) {
        let step = max(selection.focus.duration * 0.1, minimumDuration)
        let delta = TimeInterval(direction) * step
        selection = selection.withFocus(
            DateInterval(
                start: selection.focus.start.addingTimeInterval(delta),
                end: selection.focus.end.addingTimeInterval(delta)
            )
        )
    }
}
