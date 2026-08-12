import Foundation

/// The journey between home and work, and only that journey.
///
/// A commute is defined by both of its ends. The existing travel labelling looks only
/// at where a journey finished, so a drive to work from the gym reads as the same
/// thing as the drive from home — which is why "Travelling to Work" could never be
/// totalled as a commute.
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

    let start: Date
    let end: Date
    let direction: Direction
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var id: Date { start }
}

enum CommuteDetection {
    /// The activity and group commuting is counted under. Its own group rather than
    /// Travel: the question "how much of my life goes to commuting" is a different
    /// one from how much time went on holidays and flights.
    static let activityName = "Commuting"
    static let categoryName = "Commute"

    /// A stop this brief on the way does not end the journey. It also absorbs the
    /// spurious three-to-six minute matches Apple Maps returns for businesses passed
    /// at speed, which otherwise interrupt every commute a person makes.
    static let stopTolerance: TimeInterval = 10 * 60

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
        for (index, origin) in stays.enumerated() {
            guard let kind = endpoint(origin, savedPlaces: savedPlaces), let departure = origin.departure else { continue }
            // Everything between the two ends must be brief enough to be a stop on the
            // way rather than a destination of its own.
            var cursor = index + 1
            while cursor < stays.count {
                let candidate = stays[cursor]
                if let candidateKind = endpoint(candidate, savedPlaces: savedPlaces) {
                    // Home to home, or work to work, is not a commute — the person
                    // returned to where they started.
                    guard candidateKind != kind else { break }
                    // `stays` is sorted by arrival, not departure, so a manually
                    // added or otherwise overlapping visit can have an arrival
                    // earlier than `departure` here. `DateInterval.init` traps on
                    // end < start, so duration is computed by hand rather than
                    // trusting the sort to guarantee that ordering (crashed
                    // on-device 2026-08-10 adding a backfilled Work visit that
                    // overlapped the stay before it).
                    let commuteDuration = candidate.arrival.timeIntervalSince(departure)
                    guard commuteDuration > 0, commuteDuration <= longestPlausible else { break }
                    commutes.append(Commute(start: departure, end: candidate.arrival,
                                            direction: kind == .home ? .toWork : .toHome))
                    break
                }
                guard duration(of: candidate, now: now) <= stopTolerance else { break }
                cursor += 1
            }
        }
        return commutes
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
