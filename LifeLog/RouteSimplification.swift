import Foundation
import CoreLocation

/// Reduces a recorded track to the points that describe its shape.
///
/// Apple Health returns roughly one fix per second, so a twelve-minute walk arrives
/// as several hundred points, nearly all of them saying "still walking in a straight
/// line". Ramer–Douglas–Peucker keeps the corners and drops the filler, which leaves
/// tens of points for the same path: cheap to store, and identical to look at.
enum RouteSimplification {
    /// How far a point may sit from the line between its neighbours before it is
    /// carrying information. Fifteen metres is wider than a suburban street, so a
    /// turn survives while GPS jitter along a straight footpath does not.
    static let defaultTolerance: CLLocationDistance = 15

    static func simplify(_ points: [RoutePoint],
                         tolerance: CLLocationDistance = defaultTolerance) -> [RoutePoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        // An explicit stack rather than recursion: a long recorded walk can be tens of
        // thousands of fixes, and this runs on the import actor alongside everything else.
        var segments = [(0, points.count - 1)]
        while let (start, end) = segments.popLast() {
            guard end > start + 1 else { continue }
            var furthest = start
            var furthestDistance: CLLocationDistance = 0
            for index in (start + 1)..<end {
                let distance = perpendicularDistance(points[index], from: points[start], to: points[end])
                if distance > furthestDistance {
                    furthest = index
                    furthestDistance = distance
                }
            }
            guard furthestDistance > tolerance else { continue }
            keep[furthest] = true
            segments.append((start, furthest))
            segments.append((furthest, end))
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Distance from a point to the segment joining two others. Latitude and longitude
    /// are projected to metres around the segment's start, which is accurate enough
    /// over the span of one walk and avoids trigonometry per candidate point.
    private static func perpendicularDistance(_ point: RoutePoint,
                                              from start: RoutePoint,
                                              to end: RoutePoint) -> CLLocationDistance {
        let metresPerDegreeLatitude = 111_320.0
        let metresPerDegreeLongitude = metresPerDegreeLatitude *
            cos(start.latitude * .pi / 180)
        func project(_ value: RoutePoint) -> (x: Double, y: Double) {
            ((value.longitude - start.longitude) * metresPerDegreeLongitude,
             (value.latitude - start.latitude) * metresPerDegreeLatitude)
        }
        let target = project(point)
        let line = project(end)
        let lengthSquared = line.x * line.x + line.y * line.y
        guard lengthSquared > 0 else {
            return (target.x * target.x + target.y * target.y).squareRoot()
        }
        // Clamped so a point beyond either end measures to that end, not to the
        // infinite line, which would understate a doubling-back path.
        let position = min(1, max(0, (target.x * line.x + target.y * line.y) / lengthSquared))
        let closest = (x: line.x * position, y: line.y * position)
        let dx = target.x - closest.x
        let dy = target.y - closest.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
