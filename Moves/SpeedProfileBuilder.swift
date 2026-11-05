import CoreLocation
import Foundation

/// A timestamped point used to estimate speed along a rendered route.
///
/// `recordedSpeed` follows `CLLocation.speed`: values `>= 0` are used as-is;
/// negative values mean "invalid" and the builder falls back to distance / Δt.
struct SpeedProfileSample: Sendable, Equatable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let recordedSpeed: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Copies the move's samples into a Sendable value type so profiling can run off the main actor.
    static func capture(from move: MoveSegment) -> [SpeedProfileSample] {
        move.samples
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.dedupeKey < rhs.dedupeKey
            }
            .map { sample in
                SpeedProfileSample(
                    timestamp: sample.timestamp,
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    recordedSpeed: sample.speed
                )
            }
    }
}

extension TransportMode {
    /// Typical speed range in meters per second, used to normalise speed shading.
    ///
    /// Ranges follow the product table (km/h): walking 0–7, running 6–20,
    /// cycling 5–40, automotive 0–130, train 0–300.
    var typicalSpeedRange: ClosedRange<Double> {
        switch self {
        case .stationary:
            return 0 ... (1 / 3.6)
        case .walking:
            return 0 ... (7 / 3.6)
        case .running:
            return (6 / 3.6) ... (20 / 3.6)
        case .swimming:
            return 0 ... (8 / 3.6)
        case .cycling:
            return (5 / 3.6) ... (40 / 3.6)
        case .automotive:
            return 0 ... (130 / 3.6)
        case .train:
            return 0 ... (300 / 3.6)
        case .plane:
            return 0 ... (900 / 3.6)
        case .boat:
            return 0 ... (50 / 3.6)
        case .unknown:
            return 0 ... (40 / 3.6)
        }
    }
}

/// Builds a per-vertex 0…1 speed profile for route shading and caches it on `MoveSegment`.
enum SpeedProfileBuilder {
    static let smoothingWindow = 5
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Produces one normalised speed fraction per rendered vertex.
    static func fractions(
        coordinates: [CLLocationCoordinate2D],
        samples: [SpeedProfileSample],
        startDate: Date,
        endDate: Date,
        mode: TransportMode
    ) -> [Float] {
        guard !coordinates.isEmpty else { return [] }

        let sampleSpeeds = resolvedSampleSpeeds(
            samples: samples,
            coordinates: coordinates,
            startDate: startDate,
            endDate: endDate
        )
        let vertexSpeeds = vertexSpeedsMetersPerSecond(
            coordinates: coordinates,
            samples: samples,
            sampleSpeeds: sampleSpeeds,
            startDate: startDate,
            endDate: endDate
        )
        let smoothed = movingAverage(vertexSpeeds, window: smoothingWindow)
        return smoothed.map { Float(normalizedFraction(speed: $0, mode: mode)) }
    }

    /// Convenience for tests and callers that already have a `MoveSegment`.
    static func fractions(
        for move: MoveSegment,
        coordinates: [CLLocationCoordinate2D]
    ) -> [Float] {
        fractions(
            coordinates: coordinates,
            samples: SpeedProfileSample.capture(from: move),
            startDate: move.timelineStartDate,
            endDate: move.endDate,
            mode: move.transportMode
        )
    }

    /// Returns a cached profile when it still matches `routeCacheSignature` and vertex count.
    static func cachedFractions(
        for move: MoveSegment,
        coordinateCount: Int,
        signature: String
    ) -> [Float]? {
        guard move.routeCacheSignature == signature,
              let cached = decode(move.speedProfileData),
              cached.count == coordinateCount else {
            return nil
        }
        return cached
    }

    /// Persists a profile next to the route cache so it invalidates with the matched path.
    @MainActor
    static func store(_ fractions: [Float], on move: MoveSegment, signature: String) {
        guard move.routeCacheSignature == signature else { return }
        move.writeDerivedRouteData {
            move.speedProfileData = encode(fractions)
        }
    }

    /// Builds the profile off the main actor, then writes the cache back on it. The write
    /// saves the main context, which crashes a `@Query` reading it from another thread.
    @MainActor
    static func buildAndCache(
        for move: MoveSegment,
        coordinates: [CLLocationCoordinate2D]
    ) async -> [Float] {
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        if let cached = cachedFractions(
            for: move,
            coordinateCount: coordinates.count,
            signature: signature
        ) {
            return cached
        }

        let samples = SpeedProfileSample.capture(from: move)
        let startDate = move.timelineStartDate
        let endDate = move.endDate
        let modeRaw = move.transportMode.rawValue
        let packed = coordinates.map { SIMD2(Double($0.latitude), Double($0.longitude)) }
        let fractions = await Task.detached(priority: .utility) {
            let unpacked = packed.map {
                CLLocationCoordinate2D(latitude: $0.x, longitude: $0.y)
            }
            let mode = TransportMode(rawValue: modeRaw) ?? .unknown
            return Self.fractions(
                coordinates: unpacked,
                samples: samples,
                startDate: startDate,
                endDate: endDate,
                mode: mode
            )
        }.value
        store(fractions, on: move, signature: signature)
        return fractions
    }

    // MARK: - Encoding

    static func encode(_ fractions: [Float]) -> Data? {
        try? encoder.encode(fractions)
    }

    static func decode(_ data: Data?) -> [Float]? {
        guard let data else { return nil }
        return try? decoder.decode([Float].self, from: data)
    }

    // MARK: - Speed resolution

    private static func resolvedSampleSpeeds(
        samples: [SpeedProfileSample],
        coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> [Double] {
        if samples.isEmpty {
            return []
        }

        var speeds = Array(repeating: 0.0, count: samples.count)
        for index in samples.indices {
            let sample = samples[index]
            if sample.recordedSpeed >= 0 {
                speeds[index] = sample.recordedSpeed
                continue
            }

            if index > 0 {
                let previous = samples[index - 1]
                let delta = sample.timestamp.timeIntervalSince(previous.timestamp)
                if delta > 0.05 {
                    speeds[index] = distance(from: previous.coordinate, to: sample.coordinate) / delta
                    continue
                }
            }

            if index + 1 < samples.count {
                let next = samples[index + 1]
                let delta = next.timestamp.timeIntervalSince(sample.timestamp)
                if delta > 0.05 {
                    speeds[index] = distance(from: sample.coordinate, to: next.coordinate) / delta
                    continue
                }
            }

            speeds[index] = overallSpeed(
                coordinates: coordinates,
                startDate: startDate,
                endDate: endDate
            )
        }
        return speeds
    }

    private static func vertexSpeedsMetersPerSecond(
        coordinates: [CLLocationCoordinate2D],
        samples: [SpeedProfileSample],
        sampleSpeeds: [Double],
        startDate: Date,
        endDate: Date
    ) -> [Double] {
        let fallback = overallSpeed(
            coordinates: coordinates,
            startDate: startDate,
            endDate: endDate
        )
        guard !samples.isEmpty, sampleSpeeds.count == samples.count else {
            return Array(repeating: fallback, count: coordinates.count)
        }

        let vertexTimes = interpolatedVertexTimes(
            coordinates: coordinates,
            startDate: startDate,
            endDate: endDate
        )
        return vertexTimes.map { timestamp in
            nearestSampleSpeed(
                at: timestamp,
                samples: samples,
                sampleSpeeds: sampleSpeeds,
                fallback: fallback
            )
        }
    }

    private static func interpolatedVertexTimes(
        coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> [Date] {
        let duration = max(endDate.timeIntervalSince(startDate), 0)
        guard coordinates.count > 1, duration > 0 else {
            return Array(repeating: startDate, count: coordinates.count)
        }

        let locations = cumulativeDistanceFractions(along: coordinates)
        return locations.map { fraction in
            startDate.addingTimeInterval(duration * fraction)
        }
    }

    private static func nearestSampleSpeed(
        at timestamp: Date,
        samples: [SpeedProfileSample],
        sampleSpeeds: [Double],
        fallback: Double
    ) -> Double {
        guard let first = samples.first else { return fallback }

        var bestIndex = 0
        var bestDelta = abs(first.timestamp.timeIntervalSince(timestamp))
        for index in samples.indices.dropFirst() {
            let delta = abs(samples[index].timestamp.timeIntervalSince(timestamp))
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        return sampleSpeeds[bestIndex]
    }

    private static func overallSpeed(
        coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> Double {
        let duration = max(endDate.timeIntervalSince(startDate), 0.5)
        var total: CLLocationDistance = 0
        for index in coordinates.indices.dropFirst() {
            total += distance(from: coordinates[index - 1], to: coordinates[index])
        }
        return total / duration
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 1 else { return values }
        let half = window / 2
        return values.indices.map { index in
            let lower = max(0, index - half)
            let upper = min(values.count - 1, index + half)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    static func normalizedFraction(speed: Double, mode: TransportMode) -> Double {
        let range = mode.typicalSpeedRange
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((speed - range.lowerBound) / span, 0), 1)
    }

    /// Distance along the polyline as 0…1 locations, one per vertex.
    static func cumulativeDistanceFractions(along coordinates: [CLLocationCoordinate2D]) -> [Double] {
        guard let first = coordinates.first else { return [] }
        guard coordinates.count > 1 else { return [0] }

        var distances: [Double] = [0]
        distances.reserveCapacity(coordinates.count)
        var total: Double = 0
        var previous = first
        for coordinate in coordinates.dropFirst() {
            total += distance(from: previous, to: coordinate)
            distances.append(total)
            previous = coordinate
        }
        guard total > 0 else {
            return coordinates.indices.map { index in
                coordinates.count == 1 ? 0 : Double(index) / Double(coordinates.count - 1)
            }
        }
        return distances.map { $0 / total }
    }

    private static func distance(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}
