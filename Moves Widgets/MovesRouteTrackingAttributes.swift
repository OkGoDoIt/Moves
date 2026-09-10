import ActivityKit
import Foundation

/// Shared between the app and widget extension so ActivityKit decodes one stable schema.
struct MovesRouteTrackingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let distanceMeters: Double
        let sampleCount: Int
        let lastUpdatedAt: Date
    }

    let startedAt: Date
}
