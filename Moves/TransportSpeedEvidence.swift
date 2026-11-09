import CoreLocation
import Foundation

/// Speed is supporting evidence, not a unique signature of a bicycle, train,
/// or runner. Keep uncertainty and missing time instead of counting every fix
/// (or a long recording gap) as another confident vote.
struct TransportSpeedEvidence {
    struct Interval {
        let duration: TimeInterval
        let lowerSpeed: Double
        let upperSpeed: Double
    }

    let locations: [CLLocation]
    let intervals: [Interval]
    let duration: TimeInterval
    let directDistance: Double
    let directLowerDistance: Double

    init(locations input: [CLLocation]) {
        let valid = input.filter {
            CLLocationCoordinate2DIsValid($0.coordinate)
                && $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= 250
        }.sorted { $0.timestamp < $1.timestamp }
        // An interval shorter than five seconds is dominated by fix-to-fix
        // uncertainty in city recordings. Keep its best fix, not its peak speed.
        var spaced: [CLLocation] = []
        var clusterStart: Date?
        for location in valid {
            if let start = clusterStart, location.timestamp.timeIntervalSince(start) < 5 {
                if let previous = spaced.last, location.horizontalAccuracy < previous.horizontalAccuracy {
                    spaced[spaced.count - 1] = location
                }
            } else {
                spaced.append(location)
                clusterStart = location.timestamp
            }
        }
        // Reject an isolated excursion when the fixes on either side agree
        // within their uncertainty. This changes evidence, never stored points.
        let cleaned = spaced.enumerated().compactMap { index, location -> CLLocation? in
            guard index > 0, index + 1 < spaced.count else { return location }
            let previous = spaced[index - 1], next = spaced[index + 1]
            let neighborUncertainty = previous.horizontalAccuracy + next.horizontalAccuracy
            let excursionUncertainty = location.horizontalAccuracy + max(previous.horizontalAccuracy, next.horizontalAccuracy)
            let neighborSpan = previous.distance(from: next)
            let excursionLimit = max(150, neighborSpan * 3 + excursionUncertainty * 3)
            if next.timestamp.timeIntervalSince(previous.timestamp) <= 120,
               (neighborSpan <= max(50, neighborUncertainty)
                || (previous.distance(from: location) > excursionLimit && next.distance(from: location) > excursionLimit)),
               previous.distance(from: location) > max(150, excursionUncertainty * 3),
               next.distance(from: location) > max(150, excursionUncertainty * 3) {
                return nil
            }
            return location
        }
        locations = cleaned
        if let first = cleaned.first, let last = cleaned.last {
            duration = max(0, last.timestamp.timeIntervalSince(first.timestamp))
            directDistance = first.distance(from: last)
            directLowerDistance = max(0, directDistance - first.horizontalAccuracy - last.horizontalAccuracy)
        } else {
            duration = 0; directDistance = 0; directLowerDistance = 0
        }
        var measured: [Interval] = []
        var anchor = cleaned.first
        for last in cleaned.dropFirst() {
            guard let first = anchor else { break }
            let seconds = last.timestamp.timeIntervalSince(first.timestamp)
            // A silent gap is unknown time, not evidence of a continuous speed.
            if seconds > 5 * 60 { anchor = last; continue }
            let distance = first.distance(from: last)
            let uncertainty = first.horizontalAccuracy + last.horizontalAccuracy
            // Dense fixes are not independent speed votes. Extend the baseline
            // so ordinary walking displacement can rise above GPS uncertainty.
            guard seconds >= 30, distance >= uncertainty * 2 || seconds >= 60 else { continue }
            measured.append(Interval(duration: seconds, lowerSpeed: max(0, distance - uncertainty) / seconds,
                                     upperSpeed: (distance + uncertainty) / seconds))
            anchor = last
        }
        intervals = measured
    }

    var hasSustainedCoverage: Bool {
        intervals.count >= 2 && observedDuration >= 60 && observedDuration >= duration * 0.5
    }

    var observedDuration: TimeInterval { intervals.reduce(0) { $0 + $1.duration } }

    /// Requires repeated, time-supported displacement even after accounting for
    /// uncertainty. Missing steps and a single jump cannot meet this condition.
    func supportsSpeed(above threshold: Double, tripDuration: TimeInterval) -> Bool {
        let fast = intervals.filter { $0.lowerSpeed > threshold }
        let fastDuration = fast.reduce(0) { $0 + $1.duration }
        return fast.count >= 2 && fastDuration >= 60
            && fastDuration >= max(duration, tripDuration) * 0.5
    }

    var inferredMode: TransportMode {
        // Long-distance displacement can establish flight despite sparse fixes;
        // a peak instantaneous speed alone cannot.
        if duration > 0, directLowerDistance >= 150_000, directLowerDistance / duration >= 55 {
            return .plane
        }
        guard hasSustainedCoverage else { return .unknown }
        // A consensus of reported speeds is useful even when the geometry is
        // sparse. One exceptional speed never outweighs the other readings.
        if reportedSpeeds.count >= 3 {
            let speed = reportedSpeeds[(reportedSpeeds.count - 1) / 2]
            if speed >= 75, directLowerDistance >= 20_000,
               directLowerDistance / max(duration, 1) >= 40 { return .plane }
            if speed >= 9, speed < 32 { return .automotive }
            if speed >= 0.7, speed < 2.3 { return .walking }
        }
        let low = weightedMedian(\.lowerSpeed), high = weightedMedian(\.upperSpeed)
        if high < 0.7 { return .stationary }
        if low >= 0.35, high < 2.3 { return .walking }
        if low >= 9, high < 32 { return .automotive }
        // Running, cycling, city traffic, and rail overlap in speed. Motion can
        // identify some of them; speed on its own leaves the mode unresolved.
        return .unknown
    }

    var typicalSpeed: Double {
        if reportedSpeeds.count >= 3 { return reportedSpeeds[(reportedSpeeds.count - 1) / 2] }
        guard !intervals.isEmpty else { return 0 }
        return (weightedMedian(\.lowerSpeed) + weightedMedian(\.upperSpeed)) / 2
    }

    private var reportedSpeeds: [Double] {
        locations.map(\.speed).filter { $0.isFinite && $0 >= 0 }.sorted()
    }

    private func weightedMedian(_ keyPath: KeyPath<Interval, Double>) -> Double {
        let ordered = intervals.sorted { $0[keyPath: keyPath] < $1[keyPath: keyPath] }
        var covered: TimeInterval = 0
        for interval in ordered {
            covered += interval.duration
            if covered >= observedDuration / 2 { return interval[keyPath: keyPath] }
        }
        return 0
    }
}
