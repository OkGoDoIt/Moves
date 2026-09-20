import ActivityKit
import Foundation

/// Shared between the app and widget extension so ActivityKit decodes one stable schema.
struct MovesRouteTrackingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let distanceMeters: Double
        let sampleCount: Int
        let lastUpdatedAt: Date
        /// Color asset matching `MovesPalette.transport` for the current mode.
        let colorAssetName: String
        /// SF Symbol for the current mode.
        let symbolName: String

        enum CodingKeys: String, CodingKey {
            case endsAt
            case distanceMeters
            case sampleCount
            case lastUpdatedAt
            case colorAssetName
            case symbolName
        }

        init(
            endsAt: Date,
            distanceMeters: Double,
            sampleCount: Int,
            lastUpdatedAt: Date,
            colorAssetName: String = "MovesTransportWalking",
            symbolName: String = "figure.walk"
        ) {
            self.endsAt = endsAt
            self.distanceMeters = distanceMeters
            self.sampleCount = sampleCount
            self.lastUpdatedAt = lastUpdatedAt
            self.colorAssetName = colorAssetName
            self.symbolName = symbolName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            endsAt = try container.decode(Date.self, forKey: .endsAt)
            distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
            sampleCount = try container.decode(Int.self, forKey: .sampleCount)
            lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
            colorAssetName = try container.decodeIfPresent(String.self, forKey: .colorAssetName)
                ?? "MovesTransportWalking"
            symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
                ?? "figure.walk"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(endsAt, forKey: .endsAt)
            try container.encode(distanceMeters, forKey: .distanceMeters)
            try container.encode(sampleCount, forKey: .sampleCount)
            try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
            try container.encode(colorAssetName, forKey: .colorAssetName)
            try container.encode(symbolName, forKey: .symbolName)
        }
    }

    let startedAt: Date
}
