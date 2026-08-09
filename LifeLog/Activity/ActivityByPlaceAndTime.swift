import Foundation

/// What a place has actually meant, at a given time of day, according to the
/// person's own history — weighted so a confirmed correction outweighs an
/// automatic guess, and a bulk-imported default barely counts at all.
///
/// `InferenceEngine`'s keyword table answers "what does a place named this,
/// categorised this way, usually mean" — a question about places in general. This
/// answers a narrower, better-evidenced one: "what has *this* place, at *this*
/// hour, actually been logged as before". Where there is enough evidence to
/// answer it, that answer is a better guess than a generic keyword match; where
/// there is not, this says nothing rather than guessing from one data point.
enum ActivityByPlaceAndTime {
    /// How much one piece of evidence counts toward the vote for an activity
    /// label. A person's own confirmation or correction is worth as much as
    /// several automatic guesses, so a single "no, actually" does not need dozens
    /// of unremarked repeats to outweigh what the phone assumed on its own.
    ///
    /// Bulk-imported rows count for the least — not zero, since 25,000 unreviewed
    /// visits are still real history, but a label the importer manufactured from
    /// its own six-keyword table is not evidence of what the place is, only of
    /// what an old app guessed it was. Weighting it above "learned"/"confirmed"
    /// would let that guess outvote the person's own corrections of it.
    static func weight(source: String, recognitionConfidence: String?) -> Int {
        if recognitionConfidence == "confirmed" { return 5 }
        switch source {
        case "imported-journal": return 1
        case "automatic", "manual":
            switch recognitionConfidence {
            case "learned": return 3
            case "high", "medium": return 2
            default: return 1
            }
        default: return 1
        }
    }

    /// Enough weighted evidence to trust, not merely the largest of a handful of
    /// scattered guesses. One confirmed visit is one data point; requiring more
    /// than a single confirmation's worth keeps a single correction from looking
    /// like an established pattern the moment it is made.
    static let minimumEvidence = 6

    /// The activity this place has meant at this time of day, if the archive has
    /// enough weighted evidence to say so with any confidence.
    ///
    /// `history` and `corrections` are expected to already be scoped to visits
    /// resembling `placeName` (matching by `NameKey`, as the rest of the app
    /// does) — this does no name matching of its own, so a caller with several
    /// places to ask about can filter once rather than rescanning per place.
    static func infer(arrival: Date, history: [Visit], corrections: [VisitCorrection]) -> String? {
        let band = PlaceTimeBand.containing(arrival)
        var votes: [String: Int] = [:]

        for visit in history where band.contains(visit.arrival) {
            let activity = visit.activity
            guard !activity.isEmpty else { continue }
            votes[activity, default: 0] += weight(source: visit.source,
                                                   recognitionConfidence: visit.recognitionConfidence)
        }
        // A correction is the person saying so directly, worth the same as a
        // confirmed visit regardless of what the visit it corrected once said.
        for correction in corrections where band.contains(correction.visitArrival) {
            votes[correction.newActivity, default: 0] += weight(source: "manual", recognitionConfidence: "confirmed")
        }

        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= minimumEvidence else { return nil }
        return best.key
    }
}
