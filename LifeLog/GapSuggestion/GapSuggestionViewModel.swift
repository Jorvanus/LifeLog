import Foundation
import SwiftData
import Observation

/// Drives one "Help me classify this gap" request from `ManualVisitView`:
/// builds the deterministic context for exactly the selected gap, asks a
/// `GapSuggestionRequesting` to rank or decline it, and holds whatever should
/// be on screen next. Never creates, edits, merges, or deletes a `Visit` on its
/// own — the view alone decides what "Use as draft" does with the result, and
/// only an explicit Save in `ManualVisitView` ever writes anything.
///
/// Every asynchronous step is guarded by `runID`, the same token pattern
/// `AskLifeLogViewModel` uses: starting a new request, or invalidating the
/// current one, changes the token, and any earlier step that finishes after
/// that change discards its result instead of publishing it. This is what keeps
/// a stale suggestion from ever reaching the screen after the gap, the
/// neighbouring visits, or the Saved Places it was built from have moved on.
@MainActor
@Observable
final class GapSuggestionViewModel {
    enum ResultSource: Equatable {
        case resolverRule
        case appleIntelligence
    }

    enum State: Equatable {
        case idle
        case unavailable(AskLifeLogAvailability)
        case working
        /// A validated, candidate-backed outcome worth showing plainly.
        case result(GapSuggestionOutcome)
        /// Covers every cautious collapse into one message: `.noSuggestion`,
        /// `.needsManualReview`, low confidence, or the gap having disappeared
        /// before a context could even be built — the view shows the same
        /// "No reliable suggestion — choose manually" line for all of them
        /// rather than distinguishing shades of "nothing to offer".
        case noReliableSuggestion
        case invalidOutput
    }

    private(set) var state: State = .idle
    /// The context the current (or most recently shown) result was built from —
    /// kept only so the view can look up which candidate an accepted outcome
    /// refers to; never displayed or logged itself.
    private(set) var lastContext: GapSuggestionContext?
    /// Kept separate from the outcome so the sheet never attributes a
    /// deterministic resolver answer to Apple Intelligence.
    private(set) var resultSource: ResultSource?

    private let service: GapSuggestionRequesting
    private var runID = UUID()
    /// Held only so a test can `await` a run to completion instead of polling
    /// `state` — the UI never reads this, since `requestSuggestion` is
    /// fire-and-forget from a button tap by design.
    private var inFlightTask: Task<Void, Never>?

    init(service: GapSuggestionRequesting) {
        self.service = service
    }

    var availability: AskLifeLogAvailability { service.availability() }

    /// Abandons whatever is in flight without changing what's currently shown —
    /// used when the sheet is about to close.
    func cancel() {
        runID = UUID()
    }

    /// Test-only: waits for the most recently started `requestSuggestion` run
    /// to finish publishing (or discarding) its result, so a test can assert on
    /// `state` deterministically instead of polling or sleeping.
    func waitForCompletion() async {
        await inFlightTask?.value
    }

    /// Called whenever the neighbouring visits or Saved Places this suggestion
    /// was built from change while the sheet is still open — an existing
    /// `.result`/`.noReliableSuggestion` described a specific gap and context;
    /// once that has moved on, it must not keep being shown as if it still
    /// applied. (Period, date, scope, and filter changes cannot happen while
    /// this sheet is open at all — it is modal over the screen that owns them —
    /// so there is nothing further to invalidate for those.)
    func invalidateIfShowingResult() {
        cancel()
        switch state {
        case .result, .noReliableSuggestion, .invalidOutput: state = .idle
        case .idle, .unavailable, .working: break
        }
        lastContext = nil
        resultSource = nil
    }

    func requestSuggestion(gapStart: Date, gapEnd: Date, repairActor: ArchiveRepairActor,
                           diagnosticsContext: ModelContext?) {
        let token = UUID()
        runID = token
        state = .working
        lastContext = nil
        resultSource = nil

        inFlightTask = Task { [service] in
            let startedAt = Date.now
            let context = try? await repairActor.gapSuggestionContext(gapStart: gapStart, gapEnd: gapEnd)
            guard runID == token else {
                Diagnostics.gapSuggestionEvent(diagnosticsContext, event: "stale-result")
                return
            }
            guard let context else {
                // The gap itself no longer exists (something else already
                // filled or edited it since the sheet opened) — nothing to
                // suggest, and never a stale suggestion for a gap that's gone.
                state = .idle
                return
            }

            if let resolverCandidate = context.candidates.first(where: { $0.kind == .resolverRuleStay }) {
                let confidence: GapSuggestionConfidence = resolverCandidate.id == "sleep-walking-workout-home" ? .medium : .high
                let result = GapSuggestionOutcome(
                    kind: .possibleStay, candidateID: resolverCandidate.id, confidence: confidence,
                    explanation: resolverCandidate.rationale, uncertaintyNote: nil)
                lastContext = context
                resultSource = .resolverRule
                Diagnostics.gapSuggestionRequest(
                    diagnosticsContext, durationMs: Int(Date.now.timeIntervalSince(startedAt) * 1000),
                    contextSizeBucket: context.diagnosticSizeBucket, candidateCount: context.candidates.count,
                    outcomeKind: result.kind.rawValue, confidence: result.confidence.rawValue)
                state = .result(result)
                return
            }

            let outcome = await service.suggest(context: context)
            let durationMs = Int(Date.now.timeIntervalSince(startedAt) * 1000)
            guard runID == token else {
                Diagnostics.gapSuggestionEvent(diagnosticsContext, event: "stale-result")
                return
            }
            Diagnostics.gapSuggestionRequest(
                diagnosticsContext, durationMs: durationMs, contextSizeBucket: context.diagnosticSizeBucket,
                candidateCount: context.candidates.count, outcomeKind: outcome.diagnosticOutcomeKind,
                confidence: outcome.diagnosticConfidence)

            switch outcome {
            case .unavailable(let availability):
                state = .unavailable(availability)
            case .invalidOutput:
                Diagnostics.gapSuggestionEvent(diagnosticsContext, event: "invalid-output")
                state = .invalidOutput
            case .outcome(let result):
                lastContext = context
                resultSource = .appleIntelligence
                // A shaky "possible" reads as authoritative if shown plainly —
                // low confidence collapses into the same cautious message as
                // an outright decline, regardless of which kind it carries.
                if result.kind == .noSuggestion || result.kind == .needsManualReview || result.confidence == .low {
                    state = .noReliableSuggestion
                } else {
                    state = .result(result)
                }
            }
        }
    }

    /// The candidate a shown result refers to, looked up from the context it
    /// was built from — `nil` for a candidate-less outcome or once the context
    /// has been cleared by `invalidateIfShowingResult`.
    func candidate(for outcome: GapSuggestionOutcome) -> GapSuggestionCandidate? {
        guard let id = outcome.candidateID else { return nil }
        return lastContext?.candidates.first { $0.id == id }
    }

    /// Privacy-safe record of what a person did with a shown suggestion —
    /// "accepted", "edited", "rejected", or "saved". Never the suggestion's own
    /// text or the candidate it referred to.
    func recordUserAction(_ action: String, diagnosticsContext: ModelContext?) {
        Diagnostics.gapSuggestionEvent(diagnosticsContext, event: action)
    }
}
