import Foundation
import CoreLocation

/// Decides what to put in front of a person, and in what order.
///
/// Confidence alone was the whole test, which let the wrong things through in both
/// directions. Apple Maps reports how sure it is about *which business sits at a
/// coordinate* — it has no opinion on whether the person went inside. A real capture
/// held two "high confidence" stays of 3m46s and 5m46s, both on a commute, both
/// almost certainly traffic rather than visits; nothing could ever queue them. So a
/// brief stay at a place never returned to is now reviewable however sure Maps was.
///
/// Order is by impact rather than by uncertainty: the place the person is standing in
/// right now, then the unidentified places that account for the most time, then
/// uncertain matches, and last the ones that merely look like passing traffic.
enum ReviewQueue {
    /// Short enough to be somewhere passed rather than somewhere spent time. Ten
    /// minutes covers a set of traffic lights, a drive-through, or a wrong turn,
    /// while a genuine errand — a shop, a pharmacy — usually runs longer.
    static let briefStayLimit: TimeInterval = 10 * 60

    /// Roughly 110 m, so repeated callbacks around one address group together while
    /// neighbouring businesses stay separate.
    private static let coordinatePrecision = 1_000.0

    enum Reason: String, Sendable {
        /// LifeLog has no name for it.
        case unidentified
        /// It has a name, but only a weak guess at one.
        case uncertainMatch
        /// Named confidently, but brief and never returned to — likely passed by.
        case passingStay

        var prompt: String {
            switch self {
            case .unidentified: "Where was this?"
            case .uncertainMatch: "Is this right?"
            case .passingStay: "Did you stop here?"
            }
        }
    }

    struct Entry: Identifiable {
        let visit: Visit
        let reason: Reason
        /// Lower sorts first.
        let tier: Int
        /// Seconds this entry accounts for, counting every stay at the same place.
        /// Correcting one that recurs fixes more of the timeline than a one-off.
        let impact: TimeInterval
        var id: Visit.ID { visit.id }
    }

    /// Everything worth reviewing, most valuable first.
    static func entries(in visits: [Visit], now: Date = .now) -> [Entry] {
        let stays = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        // Counted once for the whole queue rather than per candidate: this runs on
        // every Timeline appearance, and an archive holds thousands of stays.
        var timeByPlace: [String: TimeInterval] = [:]
        var countByPlace: [String: Int] = [:]
        for stay in stays {
            let key = placeKey(for: stay)
            timeByPlace[key, default: 0] += duration(of: stay, now: now)
            countByPlace[key, default: 0] += 1
        }

        return stays.compactMap { stay -> Entry? in
            let key = placeKey(for: stay)
            guard let reason = reason(for: stay, visitCount: countByPlace[key] ?? 1, now: now) else { return nil }
            // The place the person is standing in right now comes first: it is the
            // only one they can still answer from memory of being there.
            let isCurrent = stay.departure == nil
            let tier: Int
            switch reason {
            case .unidentified: tier = isCurrent ? 0 : 1
            case .uncertainMatch: tier = isCurrent ? 0 : 2
            case .passingStay: tier = 3
            }
            return Entry(visit: stay, reason: reason, tier: tier, impact: timeByPlace[key] ?? 0)
        }
        .sorted { left, right in
            if left.tier != right.tier { return left.tier < right.tier }
            if left.impact != right.impact { return left.impact > right.impact }
            return left.visit.arrival > right.visit.arrival
        }
    }

    /// Why this stay needs a person, or nil if it does not.
    static func reason(for visit: Visit, visitCount: Int, now: Date = .now) -> Reason? {
        guard visit.visitSource == .automatic, !visit.isIgnored else { return nil }
        if visit.needsCategorisation { return .unidentified }
        if visit.needsConfirmation { return .uncertainMatch }
        // Only a settled-looking stay reaches here, so the bar is higher: it must be
        // brief, never returned to, and not already answered by the person.
        guard visit.userActivity?.isEmpty != false, visitCount == 1,
              duration(of: visit, now: now) <= briefStayLimit,
              visit.departure != nil else { return nil }
        return .passingStay
    }

    private static func duration(of visit: Visit, now: Date) -> TimeInterval {
        max(0, (visit.departure ?? now).timeIntervalSince(visit.arrival))
    }

    /// Groups a stay with the others at the same address. Name first, because two
    /// callbacks for one place can drift apart; coordinate when there is no name,
    /// which is exactly the "repeated unknown coordinates" case.
    private static func placeKey(for visit: Visit) -> String {
        if !visit.hasPlaceholderName { return NameKey.matching(visit.placeName) }
        let latitude = (visit.latitude * coordinatePrecision).rounded() / coordinatePrecision
        let longitude = (visit.longitude * coordinatePrecision).rounded() / coordinatePrecision
        return "\(latitude),\(longitude)"
    }
}
