import SwiftUI
import WidgetKit

struct MovesWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TimelineWidgetSnapshot
    let showsTransportBreakdown: Bool

    init(
        date: Date,
        snapshot: TimelineWidgetSnapshot,
        showsTransportBreakdown: Bool = true
    ) {
        self.date = date
        self.snapshot = snapshot
        self.showsTransportBreakdown = showsTransportBreakdown
    }

    /// An entry for now and one for midnight, so a widget the system hasn't reloaded yet
    /// doesn't carry yesterday's numbers into the new day.
    static func timelineEntries(
        now: Date = .now,
        calendar: Calendar = .current,
        showsTransportBreakdown: Bool = true
    ) -> [MovesWidgetEntry] {
        let current = MovesWidgetEntry(
            date: now,
            snapshot: TimelineWidgetSnapshotStore.load(now: now, calendar: calendar),
            showsTransportBreakdown: showsTransportBreakdown
        )
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return [current]
        }
        let nextDay = MovesWidgetEntry(
            date: midnight,
            snapshot: TimelineWidgetSnapshotStore.load(now: midnight, calendar: calendar),
            showsTransportBreakdown: showsTransportBreakdown
        )
        return [current, nextDay]
    }
}

struct MovesWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MovesWidgetEntry {
        MovesWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MovesWidgetEntry) -> Void) {
        completion(MovesWidgetEntry(date: .now, snapshot: TimelineWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MovesWidgetEntry>) -> Void) {
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 20, to: .now) ?? .now.addingTimeInterval(20 * 60)
        completion(Timeline(entries: MovesWidgetEntry.timelineEntries(), policy: .after(nextRefresh)))
    }
}

struct MovesWidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MovesWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            MovesSmallWidget(
                snapshot: entry.snapshot,
                showsTransportBreakdown: entry.showsTransportBreakdown
            )
        case .systemMedium:
            MovesMediumWidget(
                snapshot: entry.snapshot,
                showsTransportBreakdown: entry.showsTransportBreakdown
            )
        case .systemLarge, .systemExtraLarge:
            MovesLargeWidget(
                snapshot: entry.snapshot,
                showsTransportBreakdown: entry.showsTransportBreakdown
            )
        case .accessoryCircular:
            MovesCircularAccessory(snapshot: entry.snapshot)
        case .accessoryRectangular:
            MovesRectangularAccessory(snapshot: entry.snapshot)
        case .accessoryInline:
            MovesInlineAccessory(snapshot: entry.snapshot)
        #if os(watchOS)
        case .accessoryCorner:
            MovesCornerAccessory(snapshot: entry.snapshot)
        #endif
        @unknown default:
            MovesSmallWidget(snapshot: entry.snapshot)
        }
    }
}

struct MovesSmallWidget: View {
    let snapshot: TimelineWidgetSnapshot
    var showsTransportBreakdown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image("M")
                    .foregroundStyle(Color(snapshot.primaryTransportMetric?.colorAssetName ?? "MovesTransportWalking"))
                Spacer()
                Text("\(snapshot.visitedLocationCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            WidgetRouteCanvas(points: snapshot.routePoints, lineWidth: 2.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(distanceText(snapshot.totalDistanceMeters))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)

            Text(
                showsTransportBreakdown
                    ? (snapshot.primaryTransportMetric?.title ?? "Moved")
                    : "\(snapshot.visitedLocationCount) places visited"
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .movesWidgetBackground()
    }
}

struct MovesMediumWidget: View {
    let snapshot: TimelineWidgetSnapshot
    var showsTransportBreakdown = true

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.dayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(distanceText(snapshot.totalDistanceMeters))
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)

                Text("\(snapshot.visitedLocationCount) places · \(snapshot.moveCount) moves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WidgetRouteCanvas(points: snapshot.routePoints, lineWidth: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsTransportBreakdown {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.transportMetrics.prefix(3)) { metric in
                        HStack(spacing: 8) {
                            Image(systemName: metric.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(Color(metric.colorAssetName))

                            Spacer(minLength: 4)
                            Text(distanceText(metric.distanceMeters))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth: 148)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(snapshot.visitedLocationCount) places", systemImage: "mappin.and.ellipse")
                    Label("\(snapshot.moveCount) moves", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .movesWidgetBackground()
    }
}

struct MovesLargeWidget: View {
    let snapshot: TimelineWidgetSnapshot
    var showsTransportBreakdown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MovesWidgetHeader(snapshot: snapshot)

            HStack(alignment: .firstTextBaseline) {
                Text(distanceText(snapshot.totalDistanceMeters))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Spacer()
                Label("\(snapshot.visitedLocationCount)", systemImage: "mappin.and.ellipse")
                    .font(.headline)
            }

            WidgetRouteCanvas(points: snapshot.routePoints, lineWidth: 4)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 96, maxHeight: 160)

            if showsTransportBreakdown {
                VStack(spacing: 10) {
                    ForEach(snapshot.transportMetrics.prefix(6)) { metric in
                        MovesMetricBar(
                            metric: metric,
                            totalDistance: max(snapshot.totalDistanceMeters, 1)
                        )
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        "\(snapshot.visitedLocationCount) visited places",
                        systemImage: "mappin.and.ellipse"
                    )
                    Label(
                        "\(snapshot.moveCount) recorded moves",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                }
                .font(.title3.weight(.semibold))
            }

            Spacer(minLength: 0)
        }
        .movesWidgetBackground()
    }
}

/// Mode-colored silhouette of today's route. No map tiles.
struct WidgetRouteCanvas: View {
    let points: [TimelineWidgetRoutePoint]
    var lineWidth: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let latitudes = points.map(\.latitude)
            let longitudes = points.map(\.longitude)
            let projected = WidgetRouteLayout.project(
                latitudes: latitudes,
                longitudes: longitudes,
                in: size,
                padding: max(lineWidth + 3, 8)
            )
            guard projected.count > 1 else { return }

            var segmentStart = 0
            while segmentStart < projected.count - 1 {
                let colorName = points[segmentStart].colorAssetName
                var segmentEnd = segmentStart + 1
                while segmentEnd < points.count, points[segmentEnd].colorAssetName == colorName {
                    segmentEnd += 1
                }
                let lastIndex = min(max(segmentEnd - 1, segmentStart + 1), projected.count - 1)
                var path = Path()
                path.move(to: projected[segmentStart])
                for index in (segmentStart + 1)...lastIndex {
                    path.addLine(to: projected[index])
                }
                context.stroke(
                    path,
                    with: .color(Color(colorName)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                segmentStart = max(lastIndex, segmentStart + 1)
            }

            if let start = projected.first, let end = projected.last {
                let startDot = Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
                context.fill(startDot, with: .color(Color(points.first?.colorAssetName ?? "MovesTransportWalking")))
                let endDot = Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7))
                context.fill(endDot, with: .color(.white))
                context.stroke(endDot, with: .color(Color(points.last?.colorAssetName ?? "MovesTransportWalking")), lineWidth: 1.5)
            }
        }
        .accessibilityLabel(String(localized: "Today's route"))
        .accessibilityHidden(points.count < 2)
    }
}

struct MovesWidgetHeader: View {
    let snapshot: TimelineWidgetSnapshot

    var body: some View {
        HStack {
            Label("Moves", systemImage: "location.fill")
                .font(.headline.weight(.bold))
            Spacer()
            Text(snapshot.dayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct MovesMetricBar: View {
    let metric: TimelineWidgetTransportMetric
    let totalDistance: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(metric.title, systemImage: metric.symbolName)
                    .foregroundStyle(Color(metric.colorAssetName))
                Spacer()
                Text(distanceText(metric.distanceMeters))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))

            GeometryReader { proxy in
                Capsule()
                    .fill(.secondary.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color(metric.colorAssetName))
                            .frame(width: proxy.size.width * min(metric.distanceMeters / totalDistance, 1))
                    }
            }
            .frame(height: 5)
        }
    }
}

struct MovesCircularAccessory: View {
    let snapshot: TimelineWidgetSnapshot

    var body: some View {
        Gauge(value: snapshot.totalDistanceMeters, in: 0...max(snapshot.totalDistanceMeters, 10_000)) {
            Image(systemName: "figure.walk.motion")
        } currentValueLabel: {
            Text(distanceText(snapshot.totalDistanceMeters))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(URL(string: "moves://today"))
    }
}

struct MovesRectangularAccessory: View {
    let snapshot: TimelineWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading) {
            Text("Moves Today")
                .font(.caption.weight(.semibold))
            Text("\(distanceText(snapshot.totalDistanceMeters)) · \(snapshot.visitedLocationCount) places")
            if let metric = snapshot.primaryTransportMetric {
                Text("\(metric.title) \(distanceText(metric.distanceMeters))")
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "moves://today"))
    }
}

struct MovesInlineAccessory: View {
    let snapshot: TimelineWidgetSnapshot

    var body: some View {
        Text("\(distanceText(snapshot.totalDistanceMeters)) moved · \(snapshot.visitedLocationCount) places")
            .widgetURL(URL(string: "moves://today"))
    }
}

#if os(watchOS)
struct MovesCornerAccessory: View {
    let snapshot: TimelineWidgetSnapshot

    var body: some View {
        Text(distanceText(snapshot.totalDistanceMeters))
            .widgetCurvesContent()
            .widgetURL(URL(string: "moves://today"))
    }
}
#endif

extension View {
    func movesWidgetBackground() -> some View {
        padding()
            .containerBackground(for: .widget) {
                LinearGradient(
                    colors: [
                        Color("MovesWidgetBackgroundTop"),
                        Color("MovesWidgetBackgroundBottom")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

func distanceText(_ meters: Double) -> String {
    Measurement(value: max(meters, 0), unit: UnitLength.meters)
        .formatted(.measurement(width: .abbreviated, usage: .road))
}

#if DEBUG
#if !os(watchOS)
#Preview("Small Widget") {
    MovesSmallWidget(snapshot: .placeholder)
        .previewContext(WidgetPreviewContext(family: .systemSmall))
}

#Preview("Medium Widget") {
    MovesMediumWidget(snapshot: .placeholder)
        .previewContext(WidgetPreviewContext(family: .systemMedium))
}
#endif

#Preview("Circular Accessory") {
    MovesCircularAccessory(snapshot: .placeholder)
        .previewContext(WidgetPreviewContext(family: .accessoryCircular))
}

#Preview("Rectangular Accessory") {
    MovesRectangularAccessory(snapshot: .placeholder)
        .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
}

#Preview("Inline Accessory") {
    MovesInlineAccessory(snapshot: .placeholder)
        .previewContext(WidgetPreviewContext(family: .accessoryInline))
}
#endif
