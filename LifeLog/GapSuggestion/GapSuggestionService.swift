import Foundation
import FoundationModels

/// What a suggestion attempt produced. Kept distinct from `GapSuggestionOutcome`
/// itself, the same way `AskLifeLogPlanOutcome` is kept distinct from
/// `AskLifeLogQueryPlan` — a caller needs to tell "the model declined" from "the
/// model's output didn't validate" from "the model wasn't available at all",
/// each of which needs its own UI state per the product spec, not one generic
/// failure.
enum GapSuggestionResult: Sendable, Equatable {
    case outcome(GapSuggestionOutcome)
    case unavailable(AskLifeLogAvailability)
    case invalidOutput

    /// Privacy-safe label for diagnostics — never the outcome's own explanation
    /// text or candidate ID.
    var diagnosticOutcomeKind: String {
        switch self {
        case .outcome(let outcome): outcome.kind.rawValue
        case .unavailable: "unavailable"
        case .invalidOutput: "invalid"
        }
    }

    var diagnosticConfidence: String {
        if case .outcome(let outcome) = self { return outcome.confidence.rawValue }
        return "n/a"
    }
}

/// The seam between the UI and whatever turns a `GapSuggestionContext` into an
/// outcome. Exists so tests never depend on live Apple Intelligence — see
/// `FakeGapSuggestionService`. `availability()` is on the protocol, not just the
/// real implementation, so the UI can show "Apple Intelligence unavailable"
/// before a person even taps "Help me classify this gap", the same reason
/// `AskLifeLogPlanning` shapes its own protocol this way.
protocol GapSuggestionRequesting: Sendable {
    func availability() -> AskLifeLogAvailability
    func suggest(context: GapSuggestionContext) async -> GapSuggestionResult
}

/// Ranks or declines the candidates LifeLog already generated, using Apple's
/// on-device Foundation Models framework — never to invent what happened.
///
/// Follows `AskLifeLogPlanner`/`SmartActivityClassifier`'s pattern exactly:
/// availability is checked before a session is created, generation is
/// constrained to a closed vocabulary via `@Guide(.anyOf:)`, and the model's raw
/// response is never trusted directly — `GapSuggestionValidator` is the one
/// place that turns it into a real `GapSuggestionOutcome`, matching only a
/// candidate LifeLog itself supplied. Nothing beyond the values already on
/// `GapSuggestionContext` is ever sent to the model — no Visit, no SavedPlace,
/// no coordinate, no route, no note, no Health data, no archive.
struct FoundationModelsGapSuggestionService: GapSuggestionRequesting {
    func availability() -> AskLifeLogAvailability { FoundationModelsAskLifeLogPlanner.availability() }

    func suggest(context: GapSuggestionContext) async -> GapSuggestionResult {
        let currentAvailability = availability()
        guard currentAvailability == .available else { return .unavailable(currentAvailability) }

        // Nothing to rank or decline — asking the model would only invite it to
        // invent an option LifeLog never offered, which the validator would then
        // have to reject anyway. Resolved locally, with no model call at all.
        guard !context.candidates.isEmpty else {
            return .outcome(GapSuggestionOutcome(
                kind: .noSuggestion, candidateID: nil, confidence: .low,
                explanation: "LifeLog found no matching resolver rule, saved-place role, or travel pattern for this gap.",
                uncertaintyNote: nil))
        }

        let session = LanguageModelSession(model: .default, tools: [], instructions: Self.instructions)
        let prompt = Self.prompt(for: context)

        do {
            let response = try await session.respond(
                to: prompt, generating: GeneratedGapSuggestion.self,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 220)
            )
            let raw = GapSuggestionRawOutcome(
                kind: response.content.kind, candidateKind: response.content.candidateKind,
                confidence: response.content.confidence, explanation: response.content.explanation,
                uncertaintyNote: response.content.uncertaintyNote
            )
            guard let outcome = GapSuggestionValidator.validate(raw, candidates: context.candidates) else {
                return .invalidOutput
            }
            return .outcome(outcome)
        } catch {
            return .invalidOutput
        }
    }

    /// Fixed rules, stable across every request — kept in `instructions` rather
    /// than the per-gap prompt so the session can reuse them.
    private static let instructions = """
        You are helping LifeLog, a personal history app, cautiously classify one \
        stretch of time nothing was recorded for ("the gap"). You never invent a \
        place, activity, coordinate, or fact of any kind. LifeLog has already \
        built a small set of candidate explanations from its own resolver rules, \
        Saved Place roles, travel logic, and historical patterns — you may only \
        choose one of those candidates by its kind, or decline. LifeLog performs \
        every save, overlap check, and Visit creation itself, only after a \
        person explicitly reviews and confirms — you never create, edit, merge, \
        or delete anything.

        Respond with:
        - kind: "possibleStay" only when a continuation-of-stay or nearby-place \
        candidate is well supported by the evidence; "possibleTravel" only when \
        the home-work-transition candidate is well supported; \
        "needsManualReview" when the evidence is real but not strong enough to \
        trust a specific candidate; "noSuggestion" when nothing here is usable.
        - candidateKind: the exact kind of the one candidate you chose \
        ("continuationOfBeforeStay", "continuationOfAfterStay", \
        "homeWorkTransition", "nearbyResolvedPlaceStay", or \
        "resolverRuleStay"), or "none" for \
        "noSuggestion"/"needsManualReview".
        - confidence: "low", "medium", or "high" — be conservative. A long or \
        overnight gap, a gap bordering a still-open record, or a gap with no \
        comparable historical pattern should rarely be "high".
        - explanation: one brief sentence, using only the evidence you were \
        given — never a number, place, or fact you were not told.
        - uncertaintyNote: a short reason this could be wrong, when there is \
        one worth naming, otherwise leave it empty.

        Never name a candidate kind you were not given. Never state a place, \
        coordinate, or activity beyond what the candidate you chose already \
        carries. This is always a suggestion for a person to review and edit \
        before saving — never a finding of fact.
        """

    /// The part that changes on every call: the one gap's own context. Every
    /// value here already came from `GapSuggestionContextBuilder`, so nothing
    /// this function does can add archive content the context itself excluded.
    private static func prompt(for context: GapSuggestionContext) -> String {
        var lines: [String] = []
        let timing = context.timing
        lines.append(
            "Gap: \(timing.durationMinutes) minutes, \(timing.weekday) \(timing.timeBand), " +
            "\(timing.lengthClass.rawValue)\(timing.crossesDayBoundary ? ", crosses a day boundary" : ""), " +
            "time zone \(timing.timeZoneIdentifier)."
        )
        if let before = context.before {
            lines.append(
                "Immediately before: \(before.displayLabel) (\(before.activity))" +
                (before.homeWorkRole.map { ", role: \($0.rawValue)" } ?? "") +
                ", status \(before.resolutionStatus.rawValue)" + (before.isLive ? ", still open." : ".")
            )
        }
        if let after = context.after {
            lines.append(
                "Immediately after: \(after.displayLabel) (\(after.activity))" +
                (after.homeWorkRole.map { ", role: \($0.rawValue)" } ?? "") +
                ", status \(after.resolutionStatus.rawValue)" + (after.isLive ? ", still open." : ".")
            )
        }
        if let travel = context.existingTravel {
            lines.append("LifeLog already computes \(travel.durationMinutes) min of \(travel.direction) travel overlapping this gap.")
        }
        let history = context.historicalSummary
        lines.append("Historical pattern: \(history.occurrenceDescription)")
        if !history.samples.isEmpty {
            lines.append("Sample matches: " + history.samples.map(\.description).joined(separator: "; "))
        }
        lines.append("Candidates:")
        for candidate in context.candidates {
            var descriptor = "- \(candidate.kind.rawValue)"
            if let placeName = candidate.placeName { descriptor += ", place: \(placeName)" }
            if let activity = candidate.activity { descriptor += ", activity: \(activity)" }
            descriptor += " — \(candidate.rationale)"
            lines.append(descriptor)
        }
        lines.append(GapSuggestionContext.reviewDisclaimer)
        return lines.joined(separator: "\n")
    }
}

/// The flat shape a suggestion service actually produces, before validation.
/// Kept separate from `GapSuggestionOutcome` so both the real Foundation Models
/// service and a deterministic fake can build one from plain strings, and so
/// validation logic lives in exactly one place regardless of which produced it.
struct GapSuggestionRawOutcome: Sendable, Equatable {
    var kind: String
    var candidateKind: String = "none"
    var confidence: String = "low"
    var explanation: String = ""
    var uncertaintyNote: String = ""

    static let supportedKinds = ["noSuggestion", "possibleStay", "possibleTravel", "needsManualReview"]
    static let supportedCandidateKinds = [
        "continuationOfBeforeStay", "continuationOfAfterStay", "homeWorkTransition", "nearbyResolvedPlaceStay", "resolverRuleStay", "none",
    ]
}

/// Turns a raw suggestion response into a trustworthy `GapSuggestionOutcome`,
/// rejecting anything that doesn't cleanly fit rather than letting a response
/// improvise. This is the one place that decides whether an outcome is valid —
/// both the real service and the fake test service produce a
/// `GapSuggestionRawOutcome` and go through the same gate. In particular, a
/// `candidateID` is never taken from the raw response's own text: it is always
/// looked up from `candidates` by matching `candidateKind`, so the model has no
/// way to reference an ID it wasn't given.
enum GapSuggestionValidator {
    static func validate(_ raw: GapSuggestionRawOutcome, candidates: [GapSuggestionCandidate]) -> GapSuggestionOutcome? {
        guard let kind = GapSuggestionKind(rawValue: raw.kind) else { return nil }
        guard let confidence = GapSuggestionConfidence(rawValue: raw.confidence) else { return nil }
        let explanation = TextSafety.clean(raw.explanation, maximumLength: 240)
        guard !explanation.isEmpty else { return nil }
        let uncertaintyNote = TextSafety.clean(raw.uncertaintyNote, maximumLength: 200)

        guard kind.requiresCandidate else {
            return GapSuggestionOutcome(kind: kind, candidateID: nil, confidence: confidence,
                                        explanation: explanation, uncertaintyNote: uncertaintyNote.isEmpty ? nil : uncertaintyNote)
        }
        guard let candidateKind = GapSuggestionCandidateKind(rawValue: raw.candidateKind),
              kind.accepts(candidateKind),
              let candidate = candidates.first(where: { $0.kind == candidateKind })
        else { return nil }
        return GapSuggestionOutcome(kind: kind, candidateID: candidate.id, confidence: confidence,
                                    explanation: explanation, uncertaintyNote: uncertaintyNote.isEmpty ? nil : uncertaintyNote)
    }
}

/// The exact shape the model is constrained to produce. Every field is a small
/// closed vocabulary via `@Guide(.anyOf:)` except `explanation`/`uncertaintyNote`,
/// which are free text but capped and cleaned by `GapSuggestionValidator` before
/// they ever reach a view — this struct is the model's entire output surface.
@Generable(description: "A cautious classification choice for one unlogged time gap in a personal history app — a suggestion for a person to review, not a stated fact.")
private struct GeneratedGapSuggestion {
    @Guide(description: "The outcome kind that best fits the supplied evidence.", .anyOf(GapSuggestionRawOutcome.supportedKinds))
    var kind: String

    @Guide(description: "Which supplied candidate kind this refers to, or 'none'.", .anyOf(GapSuggestionRawOutcome.supportedCandidateKinds))
    var candidateKind: String

    @Guide(description: "Confidence band for this suggestion.", .anyOf(["low", "medium", "high"]))
    var confidence: String

    @Guide(description: "One brief sentence explaining the choice, using only the supplied evidence.")
    var explanation: String

    @Guide(description: "A short reason this could be wrong, or empty.")
    var uncertaintyNote: String
}
