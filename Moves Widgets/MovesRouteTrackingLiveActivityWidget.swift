import ActivityKit
import SwiftUI
import WidgetKit

/// `start...end` traps once `end` has passed, and the system keeps rendering a
/// Live Activity after its tracking window closes.
func timerRange(from start: Date, to end: Date) -> ClosedRange<Date> {
    start...max(start, end)
}

struct MovesRouteTrackingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MovesRouteTrackingAttributes.self) { context in
            let tint = Color(context.state.colorAssetName)
            HStack(spacing: 14) {
                Image(systemName: context.state.symbolName)
                    .font(.title2)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Real route tracking")
                        .font(.headline)
                    Text(timerInterval: timerRange(from: context.attributes.startedAt, to: context.state.endsAt), countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(distanceText(context.state.distanceMeters))
                        .font(.headline.monospacedDigit())
                    Text("until \(context.state.endsAt, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(URL(string: "moves://tracking"))
        } dynamicIsland: { context in
            let tint = Color(context.state.colorAssetName)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Moves", systemImage: context.state.symbolName)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(distanceText(context.state.distanceMeters))
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Real route tracking")
                        Spacer()
                        Text(timerInterval: timerRange(from: Date.now, to: context.state.endsAt), countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(tint)
            } compactTrailing: {
                Text(distanceText(context.state.distanceMeters))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(tint)
            }
            .widgetURL(URL(string: "moves://tracking"))
            .keylineTint(tint)
        }
    }
}
