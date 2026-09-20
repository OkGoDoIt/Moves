import CoreLocation
import Foundation

/// Locates a visit, move, or gap at an absolute time so Jump to Time and
/// the Map callout can highlight the matching storyline item.
enum TimelineLocator {
    /// A visit or move used as a neighbour when `locate` falls in a gap.
    enum Item {
        case visit(VisitPlace)
        case move(MoveSegment)

        var startDate: Date {
            switch self {
            case .visit(let visit): return visit.arrivalDate
            case .move(let move): return move.startDate
            }
        }

        var endDate: Date {
            switch self {
            case .visit(let visit): return visit.departureDate ?? visit.arrivalDate
            case .move(let move): return move.endDate
            }
        }
    }

    /// Result of looking up a moment on the timeline.
    enum Result {
        case visit(VisitPlace)
        /// `progress` is 0 at the move start and 1 at the move end.
        case move(MoveSegment, coordinate: CLLocationCoordinate2D, progress: Double)
        case gap(before: Item?, after: Item?)
    }

    /// Finds the visit or move covering `date`, interpolating a coordinate on a move.
    static func locate(
        at date: Date,
        visits: [VisitPlace],
        moves: [MoveSegment]
    ) -> Result {
        let coveringVisits = visits.filter { $0.covers(date) }
            .sorted { $0.arrivalDate > $1.arrivalDate }
        if let visit = coveringVisits.first(where: { $0.departureDate != nil }) {
            return .visit(visit)
        }

        let coveringMoves = moves.filter { $0.covers(date) }
            .sorted { $0.startDate < $1.startDate }
        if let move = coveringMoves.first {
            let progress = progress(of: date, on: move)
            let coordinates = displayedCoordinates(for: move)
            let coordinate = interpolate(along: coordinates, progress: progress)
                ?? move.startPlace?.coordinate
                ?? move.endPlace?.coordinate
                ?? CLLocationCoordinate2D()
            return .move(move, coordinate: coordinate, progress: progress)
        }

        if let visit = coveringVisits.first {
            return .visit(visit)
        }

        let visitItems = visits.map(Item.visit)
        let moveItems = moves.map(Item.move)
        let items = (visitItems + moveItems).sorted { $0.endDate < $1.endDate }

        let before = items.filter { $0.endDate <= date }.max { $0.endDate < $1.endDate }
        let after = items.filter { $0.startDate > date }.min { $0.startDate < $1.startDate }
        return .gap(before: before, after: after)
    }

    /// 0…1 fraction of the move's time span.
    static func progress(of date: Date, on move: MoveSegment) -> Double {
        let span = move.endDate.timeIntervalSince(move.startDate)
        guard span > 0 else { return 0 }
        return min(max(date.timeIntervalSince(move.startDate) / span, 0), 1)
    }

    /// Manual path, then cached matched path, then the start/end places.
    static func displayedCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        if let manual = move.manualRouteCoordinates, manual.count >= 2 {
            return manual
        }

        let cached = RouteCoordinateStorage.decode(move.routeCacheCoordinatesData)
        if cached.count >= 2 {
            return cached
        }

        var ends: [CLLocationCoordinate2D] = []
        if let start = move.startPlace?.coordinate {
            ends.append(start)
        }
        if let end = move.endPlace?.coordinate {
            if let last = ends.last, approximatelyEqual(last, end) {
                return ends
            }
            ends.append(end)
        }
        return ends
    }

    /// Interpolates along a polyline by cumulative distance.
    static func interpolate(
        along coordinates: [CLLocationCoordinate2D],
        progress: Double
    ) -> CLLocationCoordinate2D? {
        let clamped = min(max(progress, 0), 1)
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else { return first }

        var distances: [CLLocationDistance] = [0]
        var total: CLLocationDistance = 0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            total += distance(from: start, to: end)
            distances.append(total)
        }

        if total <= 0 {
            return first
        }

        let target = total * clamped
        for index in 1..<distances.count {
            if distances[index] >= target {
                let segmentStart = distances[index - 1]
                let segmentLength = distances[index] - segmentStart
                let t = segmentLength > 0 ? (target - segmentStart) / segmentLength : 0
                let a = coordinates[index - 1]
                let b = coordinates[index]
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            }
        }
        return coordinates.last
    }

    /// Splits a polyline at `progress`, sharing the interpolated vertex.
    static func split(
        _ coordinates: [CLLocationCoordinate2D],
        at progress: Double
    ) -> ([CLLocationCoordinate2D], [CLLocationCoordinate2D]) {
        let point = interpolate(along: coordinates, progress: progress)
        guard coordinates.count >= 2, let point else {
            let fallback = coordinates
            return (fallback, fallback)
        }

        let clamped = min(max(progress, 0), 1)
        var distances: [CLLocationDistance] = [0]
        var total: CLLocationDistance = 0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            total += distance(from: start, to: end)
            distances.append(total)
        }

        if total <= 0 {
            return (coordinates, coordinates)
        }

        let target = total * clamped
        var splitIndex = coordinates.count - 1
        for index in 1..<distances.count {
            if distances[index] >= target {
                splitIndex = index
                break
            }
        }

        var first = Array(coordinates[0..<splitIndex])
        if first.last.map({ !approximatelyEqual($0, point) }) ?? true {
            first.append(point)
        }

        var second = [point]
        let rest = Array(coordinates[splitIndex...])
        if let restFirst = rest.first, approximatelyEqual(restFirst, point) {
            second.append(contentsOf: rest.dropFirst())
        } else {
            second.append(contentsOf: rest)
        }
        return (first, second)
    }

    static func concatenating(
        _ first: [CLLocationCoordinate2D],
        _ second: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard !first.isEmpty else { return second }
        guard let firstOfSecond = second.first else { return first }
        if let last = first.last, approximatelyEqual(last, firstOfSecond) {
            return first + second.dropFirst()
        }
        return first + second
    }

    private static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    private static func approximatelyEqual(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        distance(from: lhs, to: rhs) < 2
    }
}
