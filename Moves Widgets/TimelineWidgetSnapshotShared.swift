import CoreGraphics
import Foundation

enum MovesWidgetSharedStore {
    static let appGroupIdentifier = MovesAppIdentity.appGroupIdentifier
    static let snapshotKey = "Moves.widgetSnapshot.v1"

    static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

struct TimelineWidgetTransportMetric: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let colorAssetName: String
    let distanceMeters: Double
}

/// One vertex of today's route, tinted with the move's transport color asset.
struct TimelineWidgetRoutePoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let colorAssetName: String

    init(latitude: Double, longitude: Double, colorAssetName: String = "MovesTransportUnknown") {
        self.latitude = latitude
        self.longitude = longitude
        self.colorAssetName = colorAssetName
    }

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case colorAssetName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        colorAssetName = try container.decodeIfPresent(String.self, forKey: .colorAssetName)
            ?? "MovesTransportUnknown"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(colorAssetName, forKey: .colorAssetName)
    }
}

struct TimelineWidgetSnapshot: Codable, Hashable {
    let generatedAt: Date
    let dayKey: String
    let dayTitle: String
    let totalDistanceMeters: Double
    let visitedLocationCount: Int
    let moveCount: Int
    let transportMetrics: [TimelineWidgetTransportMetric]
    let routePoints: [TimelineWidgetRoutePoint]

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case dayKey
        case dayTitle
        case totalDistanceMeters
        case visitedLocationCount
        case moveCount
        case transportMetrics
        case routePoints
    }

    init(
        generatedAt: Date,
        dayKey: String,
        dayTitle: String,
        totalDistanceMeters: Double,
        visitedLocationCount: Int,
        moveCount: Int,
        transportMetrics: [TimelineWidgetTransportMetric],
        routePoints: [TimelineWidgetRoutePoint]
    ) {
        self.generatedAt = generatedAt
        self.dayKey = dayKey
        self.dayTitle = dayTitle
        self.totalDistanceMeters = totalDistanceMeters
        self.visitedLocationCount = visitedLocationCount
        self.moveCount = moveCount
        self.transportMetrics = transportMetrics
        self.routePoints = routePoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        dayTitle = try container.decode(String.self, forKey: .dayTitle)
        totalDistanceMeters = try container.decode(Double.self, forKey: .totalDistanceMeters)
        visitedLocationCount = try container.decode(Int.self, forKey: .visitedLocationCount)
        moveCount = try container.decode(Int.self, forKey: .moveCount)
        transportMetrics = try container.decode([TimelineWidgetTransportMetric].self, forKey: .transportMetrics)
        routePoints = try container.decodeIfPresent([TimelineWidgetRoutePoint].self, forKey: .routePoints) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(dayTitle, forKey: .dayTitle)
        try container.encode(totalDistanceMeters, forKey: .totalDistanceMeters)
        try container.encode(visitedLocationCount, forKey: .visitedLocationCount)
        try container.encode(moveCount, forKey: .moveCount)
        try container.encode(transportMetrics, forKey: .transportMetrics)
        try container.encode(routePoints, forKey: .routePoints)
    }

    static let placeholder = TimelineWidgetSnapshot(
        generatedAt: .now,
        dayKey: "today",
        dayTitle: "Today",
        totalDistanceMeters: 5_240,
        visitedLocationCount: 4,
        moveCount: 6,
        transportMetrics: [
            TimelineWidgetTransportMetric(
                id: "walking",
                title: "On Foot",
                symbolName: "figure.walk",
                colorAssetName: "MovesTransportWalking",
                distanceMeters: 1_120
            ),
            TimelineWidgetTransportMetric(
                id: "cycling",
                title: "Cycling",
                symbolName: "figure.outdoor.cycle",
                colorAssetName: "MovesTransportCycling",
                distanceMeters: 4_120
            )
        ],
        routePoints: TimelineWidgetSnapshot.placeholderRoute
    )

    /// Harbour-side walk then a longer cycle, used when no snapshot is stored yet.
    static let placeholderRoute: [TimelineWidgetRoutePoint] = [
        TimelineWidgetRoutePoint(latitude: -33.8587, longitude: 151.2140, colorAssetName: "MovesTransportWalking"),
        TimelineWidgetRoutePoint(latitude: -33.8578, longitude: 151.2154, colorAssetName: "MovesTransportWalking"),
        TimelineWidgetRoutePoint(latitude: -33.8569, longitude: 151.2151, colorAssetName: "MovesTransportWalking"),
        TimelineWidgetRoutePoint(latitude: -33.8572, longitude: 151.2188, colorAssetName: "MovesTransportCycling"),
        TimelineWidgetRoutePoint(latitude: -33.8598, longitude: 151.2254, colorAssetName: "MovesTransportCycling"),
        TimelineWidgetRoutePoint(latitude: -33.8634, longitude: 151.2320, colorAssetName: "MovesTransportCycling"),
        TimelineWidgetRoutePoint(latitude: -33.8688, longitude: 151.2412, colorAssetName: "MovesTransportCycling"),
        TimelineWidgetRoutePoint(latitude: -33.8712, longitude: 151.2476, colorAssetName: "MovesTransportCycling")
    ]

    var primaryTransportMetric: TimelineWidgetTransportMetric? {
        transportMetrics.max { $0.distanceMeters < $1.distanceMeters }
    }
}

/// Fits today's route into a widget rectangle without map tiles.
enum WidgetRouteLayout {
    /// Projects latitudes and longitudes into `size`, preserving aspect ratio.
    static func project(
        latitudes: [Double],
        longitudes: [Double],
        in size: CGSize,
        padding: CGFloat = 10
    ) -> [CGPoint] {
        guard latitudes.count == longitudes.count, latitudes.count >= 2 else { return [] }
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let latSpan = max(maxLat - minLat, 0.0004)
        let lonSpan = max(maxLon - minLon, 0.0004)
        let drawable = CGSize(
            width: max(size.width - padding * 2, 1),
            height: max(size.height - padding * 2, 1)
        )
        let scale = min(drawable.width / CGFloat(lonSpan), drawable.height / CGFloat(latSpan))
        let used = CGSize(width: CGFloat(lonSpan) * scale, height: CGFloat(latSpan) * scale)
        let origin = CGPoint(
            x: padding + (drawable.width - used.width) / 2,
            y: padding + (drawable.height - used.height) / 2
        )
        return zip(longitudes, latitudes).map { longitude, latitude in
            CGPoint(
                x: origin.x + CGFloat(longitude - minLon) * scale,
                y: origin.y + CGFloat(maxLat - latitude) * scale
            )
        }
    }
}

enum TimelineWidgetSnapshotStore {
    private static let decoder = JSONDecoder()

    static func load() -> TimelineWidgetSnapshot {
        guard let data = MovesWidgetSharedStore.userDefaults.data(
            forKey: MovesWidgetSharedStore.snapshotKey
        ),
              let snapshot = try? decoder.decode(TimelineWidgetSnapshot.self, from: data) else {
            return .placeholder
        }

        return snapshot
    }
}
