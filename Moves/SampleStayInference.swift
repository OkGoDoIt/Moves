import CoreLocation
import Foundation

/// A stop reconstructed from sparse GPS fixes.
///
/// Visit monitoring often closes a stay while the phone is still there, and it
/// often never opens one for a stop that significant-location fixes did see.
/// `departureDate` is nil when the latest fix is still inside the stop and
/// nothing has shown the phone leaving.
struct SampleStay: Equatable {
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    /// Best (smallest) horizontal accuracy of the fixes that belong to the stop, in metres.
    var horizontalAccuracy: Double
    /// Timestamp of the last fix that was still inside the stop.
    var lastInsideDate: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// When the stop is known to have ended. Open stops report the last inside fix.
    var presenceEnd: Date {
        departureDate ?? lastInsideDate
    }
}

/// Turns the live, low-power fix stream into stops.
///
/// Significant-location delivery is the opposite of a route log: fixes arrive
/// while the phone is moving, then go quiet for the whole time it stays put.
/// A stop is therefore either
///
/// - several fixes that remain inside `stayRadius` for at least
///   `minimumStayDuration`, or
/// - a fix followed by a long gap whose next fix is still close enough that
///   the gap cannot have been travel (a few hundred metres over a couple of
///   hours is someone staying, not someone walking).
///
/// Fixes worse than `maximumHorizontalAccuracy`, and single fixes that jump
/// away and straight back, are dropped before clustering so one bad visit
/// callback cannot punch a hole in a real stop.
enum SampleStayInference {
    struct Configuration: Sendable, Equatable {
        /// Fixes inside this distance of the running centre belong to the stop.
        var stayRadius: CLLocationDistance = 160
        /// Shortest presence that counts as a stop.
        var minimumStayDuration: TimeInterval = 10 * 60
        /// A gap slower than this, and shorter than `maximumStillGap`, is presence.
        /// Kept well under a slow walk so a couple of blocks is a trip, while a
        /// phone sitting overnight (a few hundred metres over many hours) is not.
        var maximumStillSpeed: CLLocationSpeed = 0.2
        /// Silence longer than this is not assumed to be the same stop.
        var maximumStillGap: TimeInterval = 14 * 60 * 60
        /// A later fix farther than this is travel, however slow the average looks.
        var maximumStillGapDistance: CLLocationDistance = 1_200
        /// Fixes worse than this are ignored. Cell-tower fallbacks are often 1 km.
        var maximumHorizontalAccuracy: CLLocationDistance = 250
        /// A fix this far from both neighbours is a spike when those neighbours agree.
        var spikeDistance: CLLocationDistance = 1_500
        /// Neighbours closer than this count as "the same place" for spike rejection.
        var spikeNeighborDistance: CLLocationDistance = 350

        init() {}
    }

    /// Fixes worth trusting for stops and for move distance.
    static func reliablePoints(
        from points: [LocationLogPoint],
        configuration: Configuration = Configuration()
    ) -> [LocationLogPoint] {
        var filtered = points.filter { point in
            CLLocationCoordinate2DIsValid(point.coordinate)
                && !(point.latitude == 0 && point.longitude == 0)
                && (point.horizontalAccuracy ?? 0) >= 0
                && (point.horizontalAccuracy ?? 0) <= configuration.maximumHorizontalAccuracy
        }
        filtered.sort { $0.timestamp < $1.timestamp }

        var deduped: [LocationLogPoint] = []
        deduped.reserveCapacity(filtered.count)
        for point in filtered {
            if let last = deduped.last, point.timestamp.timeIntervalSince(last.timestamp) < 1 {
                let lastAccuracy = last.horizontalAccuracy ?? .greatestFiniteMagnitude
                let accuracy = point.horizontalAccuracy ?? .greatestFiniteMagnitude
                if accuracy < lastAccuracy {
                    deduped[deduped.count - 1] = point
                }
                continue
            }
            deduped.append(point)
        }

        guard deduped.count >= 3 else { return deduped }

        var kept: [LocationLogPoint] = []
        kept.reserveCapacity(deduped.count)
        for index in deduped.indices {
            let point = deduped[index]
            if index > 0, index < deduped.count - 1 {
                let previous = deduped[index - 1]
                let next = deduped[index + 1]
                let fromPrevious = point.distance(to: previous)
                let toNext = point.distance(to: next)
                let span = previous.distance(to: next)
                if fromPrevious >= configuration.spikeDistance,
                   toNext >= configuration.spikeDistance,
                   span <= configuration.spikeNeighborDistance {
                    continue
                }
            }
            kept.append(point)
        }
        return kept
    }

    /// Stops implied by `points`. `now` decides whether the trailing stop is still open.
    static func stays(
        from points: [LocationLogPoint],
        now: Date,
        configuration: Configuration = Configuration()
    ) -> [SampleStay] {
        let fixes = reliablePoints(from: points, configuration: configuration)
        guard !fixes.isEmpty else { return [] }

        var stays: [SampleStay] = []
        var index = 0

        while index < fixes.count {
            var memberIndexes = [index]
            var latitudeSum = fixes[index].latitude
            var longitudeSum = fixes[index].longitude
            var cursor = index + 1
            var leftAt: Date?

            while cursor < fixes.count {
                let count = Double(memberIndexes.count)
                let centre = CLLocationCoordinate2D(
                    latitude: latitudeSum / count,
                    longitude: longitudeSum / count
                )
                let candidate = fixes[cursor]
                let distance = LocationLogGeometry.distance(from: centre, to: candidate.coordinate)

                if distance <= configuration.stayRadius {
                    memberIndexes.append(cursor)
                    latitudeSum += candidate.latitude
                    longitudeSum += candidate.longitude
                    cursor += 1
                    continue
                }

                let anchor = fixes[memberIndexes[memberIndexes.count - 1]]
                let gap = candidate.timestamp.timeIntervalSince(anchor.timestamp)
                let speed = distance / max(gap, 1)
                // A couple of blocks in a few minutes is the walk after a bus,
                // not the stop continuing. Significant-change delivery often
                // has no fix in between, so the average speed looks very low.
                let isLastBlockWalk = LastBlockWalk.isShape(distance: distance, duration: gap)
                if !isLastBlockWalk,
                   gap >= configuration.minimumStayDuration,
                   gap <= configuration.maximumStillGap,
                   distance <= configuration.maximumStillGapDistance,
                   speed <= configuration.maximumStillSpeed {
                    leftAt = candidate.timestamp
                }
                break
            }

            let members = memberIndexes.map { fixes[$0] }
            let arrival = members[0].timestamp
            let lastInside = members[members.count - 1].timestamp
            let insideDuration = lastInside.timeIntervalSince(arrival)
            let stayedByCluster = members.count >= 2 && insideDuration >= configuration.minimumStayDuration
            let stayedByStillGap = leftAt.map { $0.timeIntervalSince(arrival) >= configuration.minimumStayDuration } ?? false

            if stayedByCluster || stayedByStillGap {
                let count = Double(members.count)
                let accuracy = members.compactMap(\.horizontalAccuracy).min() ?? configuration.stayRadius
                let departure: Date?
                if let leftAt {
                    departure = leftAt
                } else if cursor >= fixes.count {
                    let silence = now.timeIntervalSince(lastInside)
                    departure = silence > configuration.maximumStillGap ? lastInside : nil
                } else {
                    departure = lastInside
                }

                stays.append(
                    SampleStay(
                        arrivalDate: arrival,
                        departureDate: departure,
                        latitude: latitudeSum / count,
                        longitude: longitudeSum / count,
                        horizontalAccuracy: accuracy,
                        lastInsideDate: lastInside
                    )
                )
                index = leftAt == nil ? memberIndexes[memberIndexes.count - 1] + 1 : cursor
            } else {
                index += 1
            }
        }

        return stays
    }
}

/// The shape of "got off a ride and walked the last couple of blocks."
///
/// Low-power fixes often have nothing between the kerb and the door, so the
/// gap looks like a very slow stay. Distance and duration are enough to tell
/// it from a phone that did not move for hours.
enum LastBlockWalk {
    static let minimumDistance: CLLocationDistance = 70
    static let maximumDistance: CLLocationDistance = 450
    /// Long enough that a doorway jitter is not a trip.
    static let minimumDuration: TimeInterval = 60
    /// Longer than this, the same distance is someone staying, not walking a block.
    static let maximumDuration: TimeInterval = 20 * 60

    static func isShape(distance: CLLocationDistance, duration: TimeInterval) -> Bool {
        distance >= minimumDistance
            && distance <= maximumDistance
            && duration >= minimumDuration
            && duration <= maximumDuration
    }

    /// Mode for a last-block gap. A bus that then crawls has almost no steps;
    /// the walk off that bus does.
    static func mode(
        proposed: TransportMode,
        distance: CLLocationDistance,
        duration: TimeInterval,
        stepCount: Int?
    ) -> TransportMode {
        guard isShape(distance: distance, duration: duration) else { return proposed }
        let speed = distance / max(duration, 1)
        guard speed < 1.8 else { return proposed }

        if let stepCount {
            if stepCount >= 60 { return .walking }
            if stepCount == 0, proposed == .automotive || proposed == .train {
                return proposed
            }
        }

        switch proposed {
        case .automotive, .train, .unknown, .stationary:
            return .walking
        case .walking, .running, .cycling, .swimming, .plane, .boat:
            return proposed
        }
    }
}
