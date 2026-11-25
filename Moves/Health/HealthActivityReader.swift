import Foundation
import HealthKit
import os

enum HealthActivityMetric: String, CaseIterable, Sendable {
    case steps
    case walkingDistance
    case flights

    var quantityIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .steps: return .stepCount
        case .walkingDistance: return .distanceWalkingRunning
        case .flights: return .flightsClimbed
        }
    }

    var unit: HKUnit {
        switch self {
        case .steps, .flights: return .count()
        case .walkingDistance: return .meter()
        }
    }
}

/// Totals for one timeline day. Each field is independently known or unknown.
struct HealthDayTotals: Equatable, Sendable {
    var steps: HealthValue
    var walkingDistance: HealthValue
    var flights: HealthValue
}

/// Everything Moves reads from Apple Health about steps and walking distance.
///
/// Totals always come from statistics queries with a cumulative sum, which merge
/// iPhone and Apple Watch without double counting and prorate samples that only
/// partly overlap the interval. Read it in the foreground: while the device is
/// locked every answer is `.unknown(.locked)`.
protocol HealthActivityReading: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func total(_ metric: HealthActivityMetric, in interval: DateInterval) async -> HealthValue
    /// Steps and walking distance in fixed buckets from `interval.start`.
    func buckets(in interval: DateInterval, minutes: Int) async -> HealthBucketsResult
}

extension HealthActivityReading {
    func steps(in interval: DateInterval) async -> HealthValue { await total(.steps, in: interval) }
    func walkingDistance(in interval: DateInterval) async -> HealthValue { await total(.walkingDistance, in: interval) }
    func flights(in interval: DateInterval) async -> HealthValue { await total(.flights, in: interval) }

    /// - Parameter interval: The timeline day's own start and end.
    func dayTotals(for interval: DateInterval) async -> HealthDayTotals {
        HealthDayTotals(
            steps: await steps(in: interval),
            walkingDistance: await walkingDistance(in: interval),
            flights: await flights(in: interval)
        )
    }
}

/// The read set Moves asks Health for, in one request: workout routes plus
/// steps, walking distance, and flights.
enum MovesHealthAuthorization {
    static var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.flightsClimbed),
        ]
    }

    static func request(on store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }
}

final class HealthKitActivityReader: HealthActivityReading, @unchecked Sendable {
    private static let log = Logger(subsystem: MovesAppIdentity.bundleIdentifier, category: "Health")
    private let store = HKHealthStore()
    private let lock = NSLock()
    private var earliestAuthorized: [HealthActivityMetric: Date]?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        try await MovesHealthAuthorization.request(on: store)
        lock.withLock { earliestAuthorized = nil }
    }

    func total(_ metric: HealthActivityMetric, in interval: DateInterval) async -> HealthValue {
        guard isAvailable else { return .unknown(.unavailable) }
        if let earliest = await earliestAuthorizedDate(for: metric), interval.start < earliest {
            return .unknown(.beforeAuthorizedWindow)
        }
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: Self.predicate(metric, interval),
            options: .cumulativeSum
        )
        do {
            guard let sum = try await descriptor.result(for: store)?.sumQuantity() else {
                return .unknown(.noData)
            }
            return .value(sum.doubleValue(for: metric.unit))
        } catch {
            return .unknown(Self.reason(for: error))
        }
    }

    func buckets(in interval: DateInterval, minutes: Int) async -> HealthBucketsResult {
        guard isAvailable else { return .unknown(.unavailable) }
        if let earliest = await earliestAuthorizedDate(for: .steps), interval.start < earliest {
            return .unknown(.beforeAuthorizedWindow)
        }
        let width = TimeInterval(max(minutes, 1) * 60)
        do {
            let steps = try await collection(.steps, interval: interval, minutes: minutes)
            let meters = try await collection(.walkingDistance, interval: interval, minutes: minutes)
            guard !steps.isEmpty || !meters.isEmpty else { return .unknown(.noData) }
            var result: [HealthBucket] = []
            var start = interval.start
            while start < interval.end {
                let end = min(start.addingTimeInterval(width), interval.end)
                result.append(HealthBucket(start: start, end: end, steps: steps[start] ?? 0, meters: meters[start] ?? 0))
                start = start.addingTimeInterval(width)
            }
            return .buckets(result)
        } catch {
            return .unknown(Self.reason(for: error))
        }
    }

    /// One-off diagnostic: how long step samples last, per kind of device.
    /// Logs only counts per duration band, never values, places, or device names.
    func logStepSampleDurationHistogram(days: Int = 7) async {
        guard isAvailable else { return }
        let start = Date.now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [Self.predicate(.steps, DateInterval(start: start, end: .now))],
            sortDescriptors: []
        )
        do {
            let samples = try await descriptor.result(for: store)
            var histogram: [String: [String: Int]] = [:]
            for sample in samples {
                let product = sample.sourceRevision.productType ?? "unknown"
                let kind = product.hasPrefix("Watch") ? "watch" : product.hasPrefix("iPhone") ? "iphone" : "other"
                let band = Self.durationBand(sample.endDate.timeIntervalSince(sample.startDate))
                histogram[kind, default: [:]][band, default: 0] += 1
            }
            for (kind, bands) in histogram.sorted(by: { $0.key < $1.key }) {
                let text = Self.durationBands.map { "\($0)=\(bands[$0] ?? 0)" }.joined(separator: " ")
                Self.log.info("Step sample durations (\(days, privacy: .public)d) \(kind, privacy: .public): \(text, privacy: .public)")
            }
        } catch {
            Self.log.info("Step sample histogram unavailable: \(Self.reason(for: error).rawValue, privacy: .public)")
        }
    }

    private static let durationBands = ["<1m", "1-3m", "3-6m", "6-10m", "10-30m", ">30m"]

    private static func durationBand(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<180: return "1-3m"
        case ..<360: return "3-6m"
        case ..<600: return "6-10m"
        case ..<1_800: return "10-30m"
        default: return ">30m"
        }
    }

    private func collection(
        _ metric: HealthActivityMetric,
        interval: DateInterval,
        minutes: Int
    ) async throws -> [Date: Double] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: Self.predicate(metric, interval),
            options: .cumulativeSum,
            anchorDate: interval.start,
            intervalComponents: DateComponents(minute: max(minutes, 1))
        )
        do {
            let collection = try await descriptor.result(for: store)
            var values: [Date: Double] = [:]
            for statistics in collection.statistics() {
                if let sum = statistics.sumQuantity() {
                    values[statistics.startDate] = sum.doubleValue(for: metric.unit)
                }
            }
            return values
        } catch let error as HKError where error.code == .errorNoData {
            return [:]
        }
    }

    private func earliestAuthorizedDate(for metric: HealthActivityMetric) async -> Date? {
        guard #available(iOS 27.0, *) else { return nil }
        if let cached = lock.withLock({ earliestAuthorized }) { return cached[metric] }
        let types = Dictionary(uniqueKeysWithValues: HealthActivityMetric.allCases.map {
            (HKQuantityType($0.quantityIdentifier) as HKObjectType, $0)
        })
        do {
            let dates = try await store.earliestAuthorizedSampleDate(for: Set(types.keys))
            var byMetric: [HealthActivityMetric: Date] = [:]
            for (type, date) in dates {
                if let metric = types[type] { byMetric[metric] = date }
            }
            lock.withLock { earliestAuthorized = byMetric }
            return byMetric[metric]
        } catch {
            // Unknown window: let the query itself answer, and ask again next time.
            return nil
        }
    }

    private static func predicate(_ metric: HealthActivityMetric, _ interval: DateInterval) -> HKSamplePredicate<HKQuantitySample> {
        // No strict-start option: statistics prorate samples that straddle the edges.
        let window = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let notTyped = NSPredicate(format: "metadata.%K != YES", HKMetadataKeyWasUserEntered)
        return .quantitySample(
            type: HKQuantityType(metric.quantityIdentifier),
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [window, notTyped])
        )
    }

    static func reason(for error: Error) -> HealthUnknownReason {
        guard let error = error as? HKError else { return .queryFailed }
        switch error.code {
        case .errorDatabaseInaccessible: return .locked
        case .errorNoData: return .noData
        case .errorHealthDataUnavailable, .errorHealthDataRestricted: return .unavailable
        default: return .queryFailed
        }
    }
}

/// Synthetic Health activity for tests and the simulator demo.
struct FakeHealthActivityReader: HealthActivityReading {
    struct Segment: Equatable, Sendable {
        var interval: DateInterval
        var stepsPerMinute: Double
        var metersPerStep: Double
        var flightsPerHour: Double = 0
    }

    var segments: [Segment]
    /// Every answer is this reason instead, as when the phone is locked.
    var forcedUnknown: HealthUnknownReason?
    /// Intervals starting before this are outside the authorized window.
    var earliestAuthorizedDate: Date?

    init(segments: [Segment], forcedUnknown: HealthUnknownReason? = nil, earliestAuthorizedDate: Date? = nil) {
        self.segments = segments
        self.forcedUnknown = forcedUnknown
        self.earliestAuthorizedDate = earliestAuthorizedDate
    }

    var isAvailable: Bool { true }

    func requestAuthorization() async throws {}

    func total(_ metric: HealthActivityMetric, in interval: DateInterval) async -> HealthValue {
        if let forcedUnknown { return .unknown(forcedUnknown) }
        if let earliestAuthorizedDate, interval.start < earliestAuthorizedDate { return .unknown(.beforeAuthorizedWindow) }
        var any = false
        var sum = 0.0
        for segment in segments {
            let overlap = Self.overlap(segment.interval, interval)
            guard overlap > 0 else { continue }
            any = true
            let steps = segment.stepsPerMinute * overlap / 60
            switch metric {
            case .steps: sum += steps
            case .walkingDistance: sum += steps * segment.metersPerStep
            case .flights: sum += segment.flightsPerHour * overlap / 3_600
            }
        }
        return any ? .value(sum) : .unknown(.noData)
    }

    func buckets(in interval: DateInterval, minutes: Int) async -> HealthBucketsResult {
        if let forcedUnknown { return .unknown(forcedUnknown) }
        guard segments.contains(where: { Self.overlap($0.interval, interval) > 0 }) else { return .unknown(.noData) }
        let width = TimeInterval(max(minutes, 1) * 60)
        var result: [HealthBucket] = []
        var start = interval.start
        while start < interval.end {
            let end = min(start.addingTimeInterval(width), interval.end)
            let slice = DateInterval(start: start, end: end)
            let steps = await total(.steps, in: slice).known ?? 0
            let meters = await total(.walkingDistance, in: slice).known ?? 0
            result.append(HealthBucket(start: start, end: end, steps: steps, meters: meters))
            start = end
        }
        return .buckets(result)
    }

    private static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(min(a.end, b.end).timeIntervalSince(max(a.start, b.start)), 0)
    }
}

/// Plausible synthetic activity aligned with the timeline that is on screen, so the
/// whole pipeline can run in the simulator without real Health data.
enum HealthDemoProfile {
    static func reader(for days: [HealthDaySnapshot]) -> FakeHealthActivityReader {
        var segments: [FakeHealthActivityReader.Segment] = []
        for day in days {
            for (index, trip) in day.trips.enumerated() where trip.duration > 0 {
                let interval = DateInterval(start: trip.start, end: trip.end)
                switch trip.mode {
                case .walking, .running:
                    let rate: Double = trip.mode == .running ? 160 : 105
                    let steps = rate * trip.duration / 60
                    // Health reads a little short of GPS, as an uncalibrated stride does.
                    let stride = steps > 0 ? trip.distanceMeters / steps / (1.04 + Double(index % 3) * 0.02) : 0.75
                    segments.append(.init(interval: interval, stepsPerMinute: rate, metersPerStep: stride, flightsPerHour: 2))
                default:
                    // A few false steps from bumps in traffic.
                    segments.append(.init(interval: interval, stepsPerMinute: 4, metersPerStep: 0.7))
                }
            }
            for (index, stay) in day.stays.enumerated() where stay.duration > 0 {
                let interval = DateInterval(start: stay.arrival, end: stay.departure)
                segments.append(.init(interval: interval, stepsPerMinute: 3, metersPerStep: 0.65, flightsPerHour: 0.5))
                // Longer stays get a stretch of walking around, like a market or a campus.
                if stay.duration >= 2 * 3_600 {
                    let start = stay.arrival.addingTimeInterval(stay.duration * 0.3)
                    let minutes = Double(8 + (index % 3) * 4)
                    segments.append(.init(
                        interval: DateInterval(start: start, duration: minutes * 60),
                        stepsPerMinute: 95, metersPerStep: 0.7, flightsPerHour: 6
                    ))
                }
            }
        }
        return FakeHealthActivityReader(segments: segments)
    }
}
