import Foundation

/// Confidence band for a suggestion, chosen by the model from a fixed vocabulary
/// (never a free-form number) so it can only ever say as much as "low", "medium",
/// or "high" — never a spurious precision like "83%".
enum GapSuggestionConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case low, medium, high
}

/// What kind of deterministic explanation LifeLog itself generated for a gap.
/// Exactly one candidate of each kind can ever exist for a given gap (see
/// `GapSuggestionCandidateGenerator`), so a model response naming a kind
/// unambiguously identifies which candidate it means — no candidate ID needs to
/// round-trip through the model at all.
enum GapSuggestionCandidateKind: String, Codable, Sendable, Equatable {
    /// The stay immediately before the gap continued through it — offered only
    /// when that stay is at a Saved Place with an explicit Home or Work role.
    case continuationOfBeforeStay
    /// The stay immediately after the gap had already begun — offered only when
    /// that stay is at a Saved Place with an explicit Home or Work role, and the
    /// gap isn't already better explained as a continuation of `before`.
    case continuationOfAfterStay
    /// The gap sits between a Home-role stay and a Work-role stay (in either
    /// order) — a commute LifeLog's own travel logic already recognises.
    case homeWorkTransition
    /// The same non-Home/Work resolved place is recorded on both sides of the
    /// gap — evidence the person likely never left it.
    case nearbyResolvedPlaceStay
}

/// One valid, deterministic explanation LifeLog itself constructed for a gap —
/// never something a model invented. `id` is a stable literal so a diagnostic or
/// a test can reference it without depending on array order.
struct GapSuggestionCandidate: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kind: GapSuggestionCandidateKind
    /// The place a "stay" candidate would populate `Add Visit`'s Location field
    /// with — always copied from an existing bordering Visit or Saved Place,
    /// never invented. `nil` for a travel candidate, which is presented as
    /// transition time rather than a place.
    let placeName: String?
    /// The activity a candidate would populate `Add Visit`'s activity field
    /// with. For `homeWorkTransition` this is `CommuteDetection.activityName`.
    let activity: String?
    let homeWorkRole: SavedPlaceRole?
    /// A short, deterministic, LifeLog-authored sentence — never model text —
    /// explaining why this candidate exists. Given to the model as supporting
    /// evidence, and available for display even before a model responds.
    let rationale: String
}

/// The four outcomes a suggestion can ever resolve to. Every other case this
/// feature reaches — an unavailable model, invalid model output, a cancelled or
/// stale request — is represented by `GapSuggestionResult`, not by widening this
/// enum, so a validated `GapSuggestionOutcome` only ever needs to express what
/// the model is allowed to say about the evidence itself.
enum GapSuggestionKind: String, Codable, Sendable, Equatable {
    case noSuggestion
    case possibleStay
    case possibleTravel
    case needsManualReview

    /// Whether this outcome kind is backed by one of the supplied candidates —
    /// `possibleStay`/`possibleTravel` must carry a `candidateID`, the other two
    /// never do. `GapSuggestionValidator` enforces this at construction time.
    var requiresCandidate: Bool { self == .possibleStay || self == .possibleTravel }

    /// Whether `candidateKind` is an acceptable match for this outcome kind —
    /// the one rule that keeps "possibleStay" from ever pointing at the travel
    /// candidate, or vice versa.
    func accepts(_ candidateKind: GapSuggestionCandidateKind) -> Bool {
        switch self {
        case .possibleStay:
            return candidateKind == .continuationOfBeforeStay || candidateKind == .continuationOfAfterStay
                || candidateKind == .nearbyResolvedPlaceStay
        case .possibleTravel:
            return candidateKind == .homeWorkTransition
        case .noSuggestion, .needsManualReview:
            return false
        }
    }
}

/// A validated suggestion, ready to show. Every value that ever crossed the
/// model boundary is required to pass through `GapSuggestionValidator` first —
/// this type itself carries no guarantee on its own beyond what the validator
/// enforced when it built one.
struct GapSuggestionOutcome: Codable, Sendable, Equatable {
    let kind: GapSuggestionKind
    /// The chosen candidate's own `id`, copied verbatim from
    /// `GapSuggestionContext.candidates` — never text the model produced.
    let candidateID: String?
    let confidence: GapSuggestionConfidence
    /// A brief explanation, cleaned and length-capped, built only from the
    /// supplied evidence categories per the model's own instructions.
    let explanation: String
    /// Why the suggestion is uncertain, when the model judged that worth
    /// saying — `nil` rather than an empty string when there's nothing to add.
    let uncertaintyNote: String?

    /// The cautious, undramatic line shown when nothing here should look like a
    /// settled fact — used directly by the view whenever `kind` is
    /// `.noSuggestion`/`.needsManualReview`, or confidence is `.low` for any
    /// kind (an uncertain "possible" reads as authoritative if shown plainly).
    static let noReliableSuggestionText = "No reliable suggestion — choose manually."
}

/// Everything a gap-suggestion request is allowed to see, built once by
/// `GapSuggestionContextBuilder`/`ArchiveRepairActor.gapSuggestionContext` from
/// the archive for exactly one selected gap. Deliberately excludes precise
/// coordinates, routes, raw motion, free text notes, Health data, unrelated
/// visits, and the archive itself — every field below is either a small closed
/// vocabulary, a rounded/bucketed number, or a label already shown elsewhere in
/// the app (a display place name, an activity, a Home/Work role).
struct GapSuggestionContext: Codable, Sendable, Equatable {
    /// How long the gap is, in the coarse terms the model reasons about rather
    /// than a raw `TimeInterval` it might otherwise treat as more precise than
    /// intended.
    enum LengthClass: String, Codable, Sendable, Equatable {
        case short, long, overnight
    }

    struct Timing: Codable, Sendable, Equatable {
        let start: Date
        let end: Date
        let durationMinutes: Int
        let timeZoneIdentifier: String
        let weekday: String
        /// Matches `SmartActivityClassifier`'s own bands, so "evening" means the
        /// same stretch of hours everywhere in LifeLog.
        let timeBand: String
        let lengthClass: LengthClass
        let crossesDayBoundary: Bool
    }

    struct BorderingRecord: Codable, Sendable, Equatable {
        enum Relationship: String, Codable, Sendable, Equatable {
            case immediatelyBefore, immediatelyAfter
        }
        let relationship: Relationship
        /// The same text Timeline and Insights already show for this visit —
        /// never a raw place name that might still be a placeholder.
        let displayLabel: String
        let homeWorkRole: SavedPlaceRole?
        let activity: String
        let resolutionStatus: VisitResolutionState
        /// `departure == nil` — the archive's own meaning of "still open",
        /// matching every other live/open check in the codebase.
        let isLive: Bool
    }

    struct ExistingTravel: Codable, Sendable, Equatable {
        let direction: String
        let durationMinutes: Int
        let overlapsGapStart: Bool
        let overlapsGapEnd: Bool
    }

    /// One anonymised, already-summarised historical match — never a raw
    /// archive record, never a coordinate, never a note.
    struct HistoricalSample: Codable, Sendable, Equatable {
        let description: String
    }

    struct HistoricalSummary: Codable, Sendable, Equatable {
        let matchingTransitionCount: Int
        let medianDurationMinutes: Int?
        let occurrenceDescription: String
        /// A small capped set of matches, described in aggregate terms only —
        /// see `GapSuggestionHistoricalMatcher.sampleCap`.
        let samples: [HistoricalSample]
    }

    let timing: Timing
    let before: BorderingRecord?
    let after: BorderingRecord?
    let existingTravel: ExistingTravel?
    let historicalSummary: HistoricalSummary
    /// The deterministic candidates LifeLog itself generated — the model may
    /// only ever choose among these or decline; see `GapSuggestionValidator`.
    let candidates: [GapSuggestionCandidate]
    /// Fixed, non-negotiable framing given to the model every time: this is a
    /// suggestion for a person to review, never a finding of fact.
    static let reviewDisclaimer =
        "This is a suggestion for a person to review and edit, not a finding of fact. Never assert it happened."

    /// A coarse size bucket for diagnostics — never the context's own content,
    /// only how much of it there was, so a performance report can tell "a
    /// context with no history to draw on" from "a context with a rich pattern"
    /// without a single label or number crossing into the record.
    var diagnosticSizeBucket: String {
        let historyWeight = historicalSummary.samples.count + (historicalSummary.matchingTransitionCount > 0 ? 1 : 0)
        switch candidates.count + historyWeight {
        case 0: return "empty"
        case 1...2: return "small"
        case 3...5: return "medium"
        default: return "large"
        }
    }
}
