import Foundation

/// A small, factual note one visit has earned against every other visit to the
/// same place: the first time there, a round-numbered visit, or the longest stay
/// yet. Deliberately separate from `DayHighlight`/`ArchiveRetrospectives`, which
/// describe a whole day or period — this describes a single visit, so it lives on
/// the card that already represents it rather than in a summary card above it.
struct VisitMicroInsight: Identifiable, Equatable {
    let id: String
    let symbol: String
    let label: String
}

enum VisitMicroInsights {
    /// Visit counts worth naming. Every count is technically a milestone; only the
    /// round numbers a person would actually notice are called out.
    static let milestoneCounts: Set<Int> = [10, 25, 50, 100, 250, 500, 1000]

    /// How many visits a place needs before its longest stay means anything — the
    /// same reasoning as `ArchiveRetrospectives.minimumOccasionsForAGap`: a place
    /// seen twice has exactly one stay, and calling it "the longest" would be true
    /// by definition rather than an observation.
    static let minimumOccasionsForLongestStay = 3

    /// The badges this one visit has earned, judged against every other visit to
    /// the same place. `history` is expected to be every automatic/manual visit
    /// with a real place name — the same restriction `InsightsView.placeHistory`
    /// and `ArchiveRetrospectives` already use, so a badge here means the same
    /// thing a retrospective in Insights would. A visit missing from its own
    /// `history` (an imported-journal entry, or one still uncategorised) earns
    /// nothing rather than guessing at its place in a pattern it was excluded from.
    static func badges(for visit: Visit, history: [Visit]) -> [VisitMicroInsight] {
        guard !visit.hasPlaceholderName, !visit.needsCategorisation else { return [] }
        let matching = history
            .filter { NameKey.matching($0.placeName) == NameKey.matching(visit.placeName) }
            .sorted { $0.arrival < $1.arrival }
        guard let ordinal = matching.firstIndex(where: { $0.id == visit.id }).map({ $0 + 1 }) else { return [] }

        var badges: [VisitMicroInsight] = []
        if ordinal == 1 {
            badges.append(VisitMicroInsight(id: "first-visit", symbol: "sparkles", label: "First time here"))
        } else if milestoneCounts.contains(ordinal) {
            badges.append(VisitMicroInsight(id: "milestone-visit", symbol: "flag.checkered",
                                            label: "\(ordinalWord(ordinal)) visit"))
        }

        // A tie for longest is read as "this one, too" rather than picked apart —
        // the badge is about noticing a record, not adjudicating one to the second.
        if matching.count >= minimumOccasionsForLongestStay,
           let longest = matching.max(by: { $0.duration < $1.duration }),
           longest.id == visit.id {
            badges.append(VisitMicroInsight(id: "longest-stay", symbol: "trophy.fill", label: "Longest stay here"))
        }
        return badges
    }

    private static func ordinalWord(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)th"
    }
}
