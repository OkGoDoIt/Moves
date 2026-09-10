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
}

struct MovesWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MovesWidgetEntry {
        MovesWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MovesWidgetEntry) -> Void) {
        completion(MovesWidgetEntry(date: .now, snapshot: TimelineWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MovesWidgetEntry>) -> Void) {
        let entry = MovesWidgetEntry(date: .now, snapshot: TimelineWidgetSnapshotStore.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 20, to: .now) ?? .now.addingTimeInterval(20 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
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
                    .foregroundStyle(Color("MovesRouteTracking"))
                Spacer()
                Text("\(snapshot.visitedLocationCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

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

            Spacer()

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
