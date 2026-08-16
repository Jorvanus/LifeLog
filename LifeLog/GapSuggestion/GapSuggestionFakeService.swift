import Foundation

/// A deterministic stand-in for `FoundationModelsGapSuggestionService`. Automated
/// tests never depend on live Apple Intelligence — this maps a small set of
/// exact gap starts to fixed results, the same way `FakeAskLifeLogPlanner` gates
/// deterministic behaviour behind a launch argument rather than the real
/// device/model state.
///
/// Responses are scripted by *candidate kind*, not by a literal ID: the fake
/// looks up whichever candidate of that kind the real, deterministic
/// `GapSuggestionContextBuilder` actually supplied for this gap and uses its
/// `id`, exactly as `GapSuggestionValidator` would. This keeps a fixture
/// resilient to candidate ordering and means a scripted response can never
/// reference a candidate the local generator didn't really produce — the fake
/// is only standing in for the model, never for the deterministic half of this
/// feature.
struct FakeGapSuggestionService: GapSuggestionRequesting {
    /// Launch argument that switches the live app onto this service instead of
    /// `FoundationModelsGapSuggestionService`, for seeded UI tests.
    static let launchArgument = "-ui-test-gap-suggestion-fake"

    struct ScriptedResponse: Sendable, Equatable {
        let kind: GapSuggestionKind
        /// `nil` for `.noSuggestion`/`.needsManualReview`, which never carry a
        /// candidate.
        let candidateKind: GapSuggestionCandidateKind?
        let confidence: GapSuggestionConfidence
        let explanation: String
        let uncertaintyNote: String?
    }

    private let responses: [Date: ScriptedResponse]
    private let fallback: ScriptedResponse
    private let fixedAvailability: AskLifeLogAvailability
    /// Lets a cancellation/staleness test observe a suggestion arriving after a
    /// deliberate delay, the same way a real model call takes real time.
    private let delayNanoseconds: UInt64

    init(responses: [Date: ScriptedResponse] = [:], fallback: ScriptedResponse = FakeGapSuggestionService.noSuggestionFallback,
        availability: AskLifeLogAvailability = .available, delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.fallback = fallback
        self.fixedAvailability = availability
        self.delayNanoseconds = delayNanoseconds
    }

    /// A service that always returns the same scripted response regardless of
    /// which gap was asked about, for tests that only care about one code path.
    init(result: ScriptedResponse, availability: AskLifeLogAvailability = .available, delayNanoseconds: UInt64 = 0) {
        self.init(responses: [:], fallback: result, availability: availability, delayNanoseconds: delayNanoseconds)
    }

    /// A service that reports Apple Intelligence as unavailable, for exercising
    /// that state without a real device.
    static func unavailable(_ reason: AskLifeLogAvailability) -> FakeGapSuggestionService {
        FakeGapSuggestionService(result: noSuggestionFallback, availability: reason)
    }

    static let noSuggestionFallback = ScriptedResponse(
        kind: .noSuggestion, candidateKind: nil, confidence: .low,
        explanation: "No comparable pattern.", uncertaintyNote: nil)

    func availability() -> AskLifeLogAvailability { fixedAvailability }

    func suggest(context: GapSuggestionContext) async -> GapSuggestionResult {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard fixedAvailability == .available else { return .unavailable(fixedAvailability) }
        let scripted = responses[context.timing.start] ?? fallback

        guard let candidateKind = scripted.candidateKind else {
            return .outcome(GapSuggestionOutcome(
                kind: scripted.kind, candidateID: nil, confidence: scripted.confidence,
                explanation: scripted.explanation, uncertaintyNote: scripted.uncertaintyNote))
        }
        // Mirrors `GapSuggestionValidator`: a scripted "possibleStay"/"possibleTravel"
        // that names a candidate kind the real context doesn't actually contain
        // (a fixture drifted from the generator) surfaces as invalid output in
        // tests, exactly as it would from a real malformed response.
        guard let candidate = context.candidates.first(where: { $0.kind == candidateKind }) else {
            return .invalidOutput
        }
        return .outcome(GapSuggestionOutcome(
            kind: scripted.kind, candidateID: candidate.id, confidence: scripted.confidence,
            explanation: scripted.explanation, uncertaintyNote: scripted.uncertaintyNote))
    }

    /// Fixed gap → response pairs used by the seeded UI test, keyed by the gap
    /// start `UITestSeedData`'s `-ui-test-gap-suggestion` fixture actually
    /// creates, so the suggestion shown is a real one drawn from real
    /// deterministic candidates, not a "no match".
    static func uiTestService(gapStart: Date) -> FakeGapSuggestionService {
        FakeGapSuggestionService(responses: [
            gapStart: ScriptedResponse(
                kind: .possibleTravel, candidateKind: .homeWorkTransition, confidence: .medium,
                explanation: "The gap sits between a Home stay and a Work stay, a pattern LifeLog recognises as a commute.",
                uncertaintyNote: "The exact route and timing weren't recorded."),
        ], fallback: noSuggestionFallback)
    }
}
