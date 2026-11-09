import Foundation
import WidgetKit
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

extension TimelineWidgetSnapshotStore {
    private static let encoder = JSONEncoder()

    static func save(_ snapshot: TimelineWidgetSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        MovesWidgetSharedStore.userDefaults.set(data, forKey: MovesWidgetSharedStore.snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()

        #if os(iOS)
        TimelineWidgetSnapshotPhoneRelay.sendToWatch(data)
        #endif
    }
}

#if os(iOS)
enum TimelineWidgetSnapshotPhoneRelay {
    static func sendToWatch(_ data: Data) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled
        else { return }

        try? session.updateApplicationContext([
            MovesWidgetSharedStore.snapshotKey: data
        ])
    }
}
#endif

extension TimelineWidgetSnapshot {
    static func make(from dayTimeline: DayTimeline) -> TimelineWidgetSnapshot {
        var distanceByMode: [TransportMode: Double] = [:]

        for move in dayTimeline.moves {
            let aggregatedMode = aggregatedDisplayMode(for: move.transportMode)
            distanceByMode[aggregatedMode, default: 0] += max(move.distanceMeters, 0)
        }

        let metrics = distanceByMode
            .map { mode, distance in
                TimelineWidgetTransportMetric(
                    id: mode.rawValue,
                    title: mode.title,
                    symbolName: mode.symbolName,
                    colorAssetName: MovesPalette.transportColorAssetName(for: mode),
                    distanceMeters: distance
                )
            }
            .sorted {
                if $0.distanceMeters != $1.distanceMeters {
                    return $0.distanceMeters > $1.distanceMeters
                }
                return $0.title < $1.title
            }

        let totalDistance = metrics.reduce(0) { $0 + $1.distanceMeters }
        let routePoints = compressedRoutePoints(for: dayTimeline, limit: 320)

        return TimelineWidgetSnapshot(
            generatedAt: .now,
            dayKey: dayTimeline.dayKey,
            dayTitle: dayTimeline.dayStart.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
            totalDistanceMeters: totalDistance,
            visitedLocationCount: dayTimeline.uniqueLocationCount,
            moveCount: dayTimeline.moves.count,
            transportMetrics: metrics,
            routePoints: routePoints
        )
    }

    private static func aggregatedDisplayMode(for mode: TransportMode) -> TransportMode {
        switch mode {
        case .walking, .running:
            return .walking
        default:
            return mode
        }
    }

    /// Downsamples each move so the widget canvas stays light, keeping mode color per vertex.
    private static func compressedRoutePoints(
        for dayTimeline: DayTimeline,
        limit: Int
    ) -> [TimelineWidgetRoutePoint] {
        let moves = dayTimeline.moves.sorted { $0.startDate < $1.startDate }
        var colored: [(color: String, coordinate: CLLocationCoordinate2D)] = []
        colored.reserveCapacity(limit)

        for move in moves {
            let color = MovesPalette.transportColorAssetName(for: move.transportMode)
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            let coordinates = move.manualRouteCoordinates
                ?? move.cachedRouteCoordinates(for: signature)
                ?? fallback
            for coordinate in coordinates {
                colored.append((color, coordinate))
            }
        }

        guard !colored.isEmpty else { return [] }
        let stride = max(colored.count / max(limit, 1), 1)
        return colored.enumerated().compactMap { index, item in
            guard index.isMultiple(of: stride) || index == colored.count - 1 else { return nil }
            return TimelineWidgetRoutePoint(
                latitude: item.coordinate.latitude,
                longitude: item.coordinate.longitude,
                colorAssetName: item.color
            )
        }
    }
}
