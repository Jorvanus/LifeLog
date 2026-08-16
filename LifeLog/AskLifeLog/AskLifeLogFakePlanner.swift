import Foundation

/// A deterministic stand-in for `FoundationModelsAskLifeLogPlanner`. Automated
/// tests never depend on live Apple Intelligence — this maps a small set of
/// exact question strings to fixed outcomes, the same way `UITestSeedData` and
/// `UITestFailureInjection` gate deterministic behaviour behind a launch
/// argument rather than the real device/model state.
///
/// Unit tests (`LifeLogTests`) can also construct this directly, or build one
/// with a single fixed `result` via `init(result:)` for a one-shot test.
struct FakeAskLifeLogPlanner: AskLifeLogPlanning {
    /// Launch argument that switches the live app onto this planner instead of
    /// `FoundationModelsAskLifeLogPlanner`, for seeded UI tests.
    static let launchArgument = "-ui-test-ask-lifelog-fake"

    private let responses: [String: AskLifeLogPlanOutcome]
    private let fallback: AskLifeLogPlanOutcome
    private let fixedAvailability: AskLifeLogAvailability
    /// Lets a cancellation/staleness test observe a suggestion arriving after a
    /// deliberate delay, the same way a real model call takes real time.
    private let delayNanoseconds: UInt64

    init(responses: [String: AskLifeLogPlanOutcome] = [:], fallback: AskLifeLogPlanOutcome = .unsupported,
         availability: AskLifeLogAvailability = .available, delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.fallback = fallback
        self.fixedAvailability = availability
        self.delayNanoseconds = delayNanoseconds
    }

    /// A planner that always returns the same outcome regardless of the question,
    /// for tests that only care about one code path.
    init(result: AskLifeLogPlanOutcome, availability: AskLifeLogAvailability = .available, delayNanoseconds: UInt64 = 0) {
        self.init(responses: [:], fallback: result, availability: availability, delayNanoseconds: delayNanoseconds)
    }

    /// A planner that reports Apple Intelligence as unavailable, for exercising
    /// that state without a real device.
    static func unavailable(_ reason: AskLifeLogAvailability) -> FakeAskLifeLogPlanner {
        FakeAskLifeLogPlanner(result: .unavailable(reason), availability: reason)
    }

    func availability() -> AskLifeLogAvailability { fixedAvailability }

    func plan(question: String, context: AskLifeLogQuestionContext) async -> AskLifeLogPlanOutcome {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard fixedAvailability == .available else { return .unavailable(fixedAvailability) }
        let key = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return responses[key] ?? fallback
    }

    /// Fixed question → plan pairs used by the seeded UI test, matching places
    /// `UITestSeedData` actually creates ("Home", "Gracemere Shopping World") so
    /// the answer is a real one, not a "no match". Kept here rather than in the
    /// UI test target so the plan shapes stay next to the vocabulary they exercise.
    static func uiTestPlanner() -> FakeAskLifeLogPlanner {
        FakeAskLifeLogPlanner(responses: [
            "how much time did i spend at home this week?":
                .plan(.placeTotal(place: .init("Home"), window: .thisWeek)),
            "when did i last visit gracemere shopping world?":
                .plan(.lastVisitToPlace(place: .init("Gracemere Shopping World"))),
            "what's my favourite pizza topping?": .unsupported,
        ], fallback: .unsupported)
    }
}
