import CoreLocation
import Foundation

/// Finds the meaningful place endpoints around a small unlogged gap, skipping a
/// trailing passive walking fragment. The result is only a reviewable travel
/// draft: distance and timing can support a journey, but cannot prove its mode.
enum TravelGapEndpointResolver {
    static let maximumAdjacentDelay: TimeInterval = 20 * 60
    static let maximumGapDuration: TimeInterval = 90 * 60
    static let minimumEndpointDistance: CLLocationDistance = 750

    struct Endpoints {
        let before: Visit
        let after: Visit
    }

    static func endpoints(for gap: DateInterval, in visits: [Visit]) -> Endpoints? {
        guard gap.duration > 0, gap.duration <= maximumGapDuration else { return nil }

        let usable: (Visit) -> Bool = { visit in
            ActivityLocationPolicy.isLocationVisit(visit)
                && visit.resolutionState != .ignored
                && visit.resolutionState != .superseded
                && !visit.hasPlaceholderName
                && (visit.latitude != 0 || visit.longitude != 0)
        }
        let before = visits
            .filter(usable)
            .filter { visit in
                guard let departure = visit.departure else { return false }
                return departure <= gap.start
                    && gap.start.timeIntervalSince(departure) <= maximumAdjacentDelay
            }
            .max { ($0.departure ?? .distantPast) < ($1.departure ?? .distantPast) }
        let after = visits
            .filter(usable)
            .filter { visit in
                visit.arrival >= gap.end
                    && visit.arrival.timeIntervalSince(gap.end) <= maximumAdjacentDelay
            }
            .min { $0.arrival < $1.arrival }

        guard let before, let after,
              before.displayPlaceName.caseInsensitiveCompare(after.displayPlaceName) != .orderedSame
        else { return nil }

        let distance = CLLocation(latitude: before.latitude, longitude: before.longitude)
            .distance(from: CLLocation(latitude: after.latitude, longitude: after.longitude))
        guard distance >= minimumEndpointDistance else { return nil }
        return Endpoints(before: before, after: after)
    }
}
