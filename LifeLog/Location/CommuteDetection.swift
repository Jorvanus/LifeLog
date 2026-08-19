import Foundation

/// A journey that ends at Home or Work — a drive to work from the gym counts just
/// as much as the drive from home does. Only the destination is required to be a
/// Saved Place role; the origin can be any real stay, or none at all.
///
/// Nothing here is written to the store. A commute is the interval between two real
/// arrivals, recomputed whenever the timeline is read, so it corrects itself when the
/// stays either side are merged or re-timed, and it can never survive as a record of
/// something that did not happen.
struct Commute: Identifiable, Sendable {
    enum Direction: String, Sendable {
        case toWork, toHome

        var label: String {
            switch self {
            case .toWork: "Commute to work"
            case .toHome: "Commute home"
            }
        }
    }

    /// One stretch of a commute: either moving, or a brief real stop along the way
    /// (a quick grocery run) that the journey still absorbs rather than treating as
    /// a separate errand. A stop keeps its own place/activity so it can be shown for
    /// what it actually was, even though its time still counts toward the commute.
    struct Leg: Identifiable, Sendable {
        enum Kind: Sendable {
            case transport
            case stop(placeName: String, activityLabel: String)
        }

        let kind: Kind
        let start: Date
        let end: Date
        var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
        var id: Date { start }
    }

    let start: Date
    let end: Date
    let direction: Direction
    let legs: [Leg]
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var id: Date { start }

    init(start: Date, end: Date, direction: Direction, legs: [Leg] = []) {
        self.start = start
        self.end = end
        self.direction = direction
        self.legs = legs
    }
}

enum CommuteDetection {
    /// The activity and group commuting is counted under. Its own group rather than
    /// Travel: the question "how much of my life goes to commuting" is a different
    /// one from how much time went on holidays and flights.
    static let activityName = "Commuting"
    static let categoryName = "Commute"

    /// A stop this brief on the way does not end the journey, and leaves no trace of
    /// itself either. It also absorbs the spurious three-to-six minute matches Apple
    /// Maps returns for businesses passed at speed, which otherwise interrupt every
    /// commute a person makes.
    static let stopTolerance: TimeInterval = 10 * 60

    /// A stop longer than `stopTolerance` but still this brief is a real errand on
    /// the way — a grocery run, not a separate outing — so the journey still counts
    /// as one commute through it, with the stop itself shown as a step. Set from a
    /// real 16m50s ALDI stop that should chain (2026-08-19) against a real 38-minute
    /// grocery trip that should not (2026-08-14).
    static let waypointTolerance: TimeInterval = 25 * 60

    /// More stops than this and it reads as an errand run, not a trip that happens
    /// to pass one shop — the journey should break rather than keep chaining.
    static let maxWaypoints = 2

    /// Beyond this the interval is not a journey between two places; something else
    /// happened that LifeLog has no record of, and calling it commuting would be a
    /// guess dressed up as a measurement.
    static let longestPlausible: TimeInterval = 4 * 60 * 60

    static func commutes(in visits: [Visit], savedPlaces: [SavedPlace] = [], now: Date = .now) -> [Commute] {
        let stays = visits
            .filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            .filter { $0.resolutionState != .superseded }
            .sorted { $0.arrival < $1.arrival }

        var commutes: [Commute] = []
        // The departure of the most recent real (non-brief) stay, its Home/Work role
        // if it has one, and any real-but-brief waypoint stops absorbed since. This
        // is where a commute would start from if the next recognised endpoint it
        // reaches has a role of its own — the origin need not be Home or Work
        // itself, only a real stay (the gym, an errand). A brief pass-through stop
        // never becomes this and never resets it either.
        var origin: (departure: Date, kind: Endpoint?, waypoints: [Visit])?

        for stay in stays {
            if let kind = endpoint(stay, savedPlaces: savedPlaces) {
                if let origin, origin.kind != kind {
                    // `stays` is sorted by arrival, not departure, so a manually
                    // added or otherwise overlapping visit can have an arrival
                    // earlier than `origin.departure` here. `DateInterval.init`
                    // traps on end < start, so duration is computed by hand rather
                    // than trusting the sort to guarantee that ordering (crashed
                    // on-device 2026-08-10 adding a backfilled Work visit that
                    // overlapped the stay before it).
                    let commuteDuration = stay.arrival.timeIntervalSince(origin.departure)
                    if commuteDuration > 0, commuteDuration <= longestPlausible {
                        commutes.append(Commute(start: origin.departure, end: stay.arrival,
                                                direction: kind == .work ? .toWork : .toHome,
                                                legs: legs(from: origin.departure, waypoints: origin.waypoints,
                                                          to: stay.arrival)))
                    }
                }
                // A still-open endpoint stay has no departure yet, so it cannot
                // seed the next leg — there is nothing after it to reach anyway.
                origin = stay.departure.map { (departure: $0, kind: kind, waypoints: []) }
            } else if let departure = stay.departure {
                let stopDuration = duration(of: stay, now: now)
                if stopDuration > stopTolerance, stopDuration <= waypointTolerance,
                   let pending = origin, pending.waypoints.count < maxWaypoints {
                    // A real but brief stop on the way — the journey keeps chaining
                    // through it rather than starting over from here.
                    origin = (pending.departure, pending.kind, pending.waypoints + [stay])
                } else if stopDuration > stopTolerance {
                    // Too long, or too many stops already: this reads as its own
                    // excursion, not a stop along a commute — start over from here.
                    origin = (departure, nil, [])
                }
                // A stop within `stopTolerance` leaves `origin` exactly as it was —
                // still in transit either way.
            }
            // A still-open non-endpoint stay leaves `origin` exactly as it was too;
            // there is nothing after it yet to reach.
        }
        return commutes
    }

    /// Splits a commute into transport and stop steps: a transport leg fills every
    /// gap between the origin, each waypoint, and the destination — whether or not
    /// anything was recorded there — and each waypoint becomes its own stop leg.
    private static func legs(from origin: Date, waypoints: [Visit], to destination: Date) -> [Commute.Leg] {
        var result: [Commute.Leg] = []
        var cursor = origin
        for waypoint in waypoints.sorted(by: { $0.arrival < $1.arrival }) {
            if waypoint.arrival > cursor {
                result.append(Commute.Leg(kind: .transport, start: cursor, end: waypoint.arrival))
            }
            guard let departure = waypoint.departure else { continue }
            result.append(Commute.Leg(kind: .stop(placeName: waypoint.displayPlaceName,
                                                   activityLabel: waypoint.suspectedActivity),
                                      start: waypoint.arrival, end: departure))
            cursor = departure
        }
        if destination > cursor {
            result.append(Commute.Leg(kind: .transport, start: cursor, end: destination))
        }
        return result
    }

    /// Whether a commute covers a moment, used to relabel time Insights would
    /// otherwise report as unlogged.
    static func commute(covering moment: Date, in commutes: [Commute]) -> Commute? {
        commutes.first { $0.start <= moment && $0.end > moment }
    }

    private enum Endpoint { case home, work }

    /// Recognised by the visit's Saved Place role, an explicit fact the owner
    /// stated — not by guessing from the place's name, which used to make a café
    /// called "Homeward Bound" a false positive and an unnamed office a false
    /// negative.
    private static func endpoint(_ visit: Visit, savedPlaces: [SavedPlace]) -> Endpoint? {
        guard !visit.hasPlaceholderName else { return nil }
        switch SavedPlaceRole.of(visit, in: savedPlaces) {
        case .home: return .home
        case .work: return .work
        case nil: return nil
        }
    }

    private static func duration(of visit: Visit, now: Date) -> TimeInterval {
        max(0, (visit.departure ?? now).timeIntervalSince(visit.arrival))
    }
}
