import Foundation
import FoundationModels

/// Why a planner couldn't produce a usable plan, mirroring
/// `SmartActivityClassifier.availabilityDescription`'s cases so Ask LifeLog and
/// smart classification explain an unavailable model the same way everywhere.
enum AskLifeLogAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unknown

    var description: String {
        switch self {
        case .available: "Available on device"
        case .deviceNotEligible: "This device doesn’t support Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence to use Ask LifeLog"
        case .modelNotReady: "Apple Intelligence is still preparing"
        case .unsupportedLocale: "Ask LifeLog isn’t available for this language yet"
        case .unknown: "Apple Intelligence availability is unknown"
        }
    }
}

/// What a planning attempt produced. Kept distinct from `AskLifeLogQueryPlan`
/// itself so a caller can tell "the model declined" from "the model's output
/// didn't validate" from "the model wasn't available at all" — each needs its
/// own UI state per the product spec, not one generic failure.
enum AskLifeLogPlanOutcome: Sendable, Equatable {
    case plan(AskLifeLogQueryPlan)
    /// The model explicitly judged the question outside Ask LifeLog's vocabulary.
    case unsupported
    case unavailable(AskLifeLogAvailability)
    /// The model produced output that failed `AskLifeLogPlanValidator`, or the
    /// session itself failed (guardrail violation, timeout, decoding error).
    case invalidOutput

    /// Privacy-safe label for diagnostics — never the plan's own content.
    var diagnosticOutcome: String {
        switch self {
        case .plan: "valid"
        case .unsupported: "declined"
        case .unavailable: "unavailable"
        case .invalidOutput: "invalid"
        }
    }

    /// The plan's kind as a bare label, for diagnostics only.
    var diagnosticPlanKind: String {
        guard case .plan(let plan) = self else { return "none" }
        switch plan {
        case .activityTotal: return "activityTotal"
        case .placeTotal: return "placeTotal"
        case .placeRanking(let metric, _, _): return metric == .visitCount ? "placeRankingByVisits" : "placeRankingByHours"
        case .lastVisitToPlace: return "lastVisitToPlace"
        case .weekdayTimePattern: return "weekdayTimePattern"
        case .strongestComparison: return "strongestComparison"
        case .unloggedTimeReview: return "unloggedTimeReview"
        case .navigation: return "navigation"
        }
    }
}

/// The seam between the UI and whatever turns a question into a plan. Exists so
/// tests never depend on live Apple Intelligence — see `FakeAskLifeLogPlanner`.
/// `availability()` is on the protocol, not just the real implementation, so the
/// UI can show "Apple Intelligence unavailable" up front — before a person types
/// a question — without special-casing which planner is in use.
protocol AskLifeLogPlanning: Sendable {
    func availability() -> AskLifeLogAvailability
    func plan(question: String, context: AskLifeLogQuestionContext) async -> AskLifeLogPlanOutcome
}

/// Translates a plain-language question into a typed query plan using Apple's
/// on-device Foundation Models framework — never to answer the question itself.
///
/// Follows `SmartActivityClassifier`'s pattern: availability is checked before a
/// session is created, generation is constrained to a closed vocabulary via
/// `@Guide(.anyOf:)`, and nothing beyond the question text and the plan schema is
/// ever sent to the model. In particular this planner never receives a Visit, a
/// SavedPlace, a coordinate, or archive contents of any kind — only the question
/// and the small `AskLifeLogQuestionContext` describing what's currently selected.
struct FoundationModelsAskLifeLogPlanner: AskLifeLogPlanning {
    func availability() -> AskLifeLogAvailability { Self.availability() }

    static func availability() -> AskLifeLogAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale() ? .available : .unsupportedLocale
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .unknown
        }
    }

    func plan(question: String, context: AskLifeLogQuestionContext) async -> AskLifeLogPlanOutcome {
        let currentAvailability = availability()
        guard currentAvailability == .available else { return .unavailable(currentAvailability) }

        let cleanedQuestion = TextSafety.clean(question, maximumLength: 240)
        guard !cleanedQuestion.isEmpty else { return .invalidOutput }

        let session = LanguageModelSession(model: .default, tools: [], instructions: Self.instructions)
        let prompt = Self.prompt(for: cleanedQuestion, context: context)

        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedAskLifeLogPlan.self,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 220)
            )
            let raw = AskLifeLogRawPlan(
                kind: response.content.kind,
                subjectName: response.content.subjectName,
                window: response.content.window,
                order: response.content.order,
                weekday: response.content.weekday,
                timeBand: response.content.timeBand,
                navigationTarget: response.content.navigationTarget,
                confidence: response.content.confidence
            )
            if raw.kind == "unsupported" { return .unsupported }
            guard let plan = AskLifeLogPlanValidator.validate(raw) else { return .invalidOutput }
            return .plan(plan)
        } catch {
            return .invalidOutput
        }
    }

    /// Fixed rules and term definitions, stable across every question — kept in
    /// `instructions` rather than the per-question prompt so the session can reuse
    /// them. Nothing here is specific to any one person's data.
    private static let instructions = """
        You are choosing how LifeLog, a personal history app, should look up the \
        answer to a person's question. You never answer the question yourself: you \
        only choose one supported query type and its parameters. LifeLog performs \
        every date calculation, total, ranking, and comparison locally after you \
        respond — never state a number, a date, a place name, or an answer of your \
        own.

        If the question does not clearly match one of the supported query types \
        below, respond with kind "unsupported" and leave every other field at its \
        default. Do not guess a close-enough query type.

        Supported query types (the "kind" field):
        - activityTotal: how much time was spent on a named activity in a period.
        - placeTotal: how much time was spent at a named place in a period.
        - placeRankingByVisits: which place was visited the most or least often.
        - placeRankingByHours: which place had the most or least time spent at it.
        - lastVisitToPlace: when a named place was last visited.
        - weekdayTimePattern: what usually happens on a given weekday and/or time \
        of day (for example "Friday evenings").
        - strongestComparison: what changed the most compared with a baseline \
        period.
        - unloggedTimeReview: unlogged time or gaps in the record.
        - navigation: the person wants to open an existing screen rather than hear \
        a figure (an activity, a place, the comparison list, unlogged time, or the \
        timeline).
        - unsupported: none of the above cleanly fits.

        Term definitions, exactly as LifeLog uses them:
        - "visit" / "place": a recorded stay at a specific location.
        - "activity": the labelled thing being done, which may or may not be tied \
        to one place.
        - "unlogged": a stretch of time with no recorded visit or activity.
        - "this week" / "this month" / "last month" etc: calendar periods relative \
        to today, in the person's own calendar and time zone — you only choose the \
        term, never a date.
        - "usual" / a weekday+time pattern: an average or typical pattern drawn \
        from historical data, not a single occurrence.

        For "subjectName", copy the place or activity phrase exactly as the person \
        said it — do not correct, translate, or normalize it, and do not invent a \
        name if none was said. Leave it empty when the query type doesn't need one.
        """

    /// The part that changes on every call: the question itself and the exact
    /// selected period/scope, so "this week" in the question and the Insights
    /// period currently on screen resolve identically without another exchange.
    private static func prompt(for question: String, context: AskLifeLogQuestionContext) -> String {
        let interval = context.selectedInterval
        return """
            Question: "\(question)"

            Current date/time: \(context.now.ISO8601Format())
            Time zone: \(context.timeZoneIdentifier)
            Calendar: \(context.calendarIdentifier)
            Locale: \(context.localeIdentifier)

            Currently selected period: \(context.selectedWindow.rawValue), \
            from \(interval.start.ISO8601Format()) to \(interval.end.ISO8601Format()), \
            \(context.selectedIntervalIsOngoing ? "still in progress" : "complete").

            Currently selected data scope: \(context.scope.rawValue) \
            (\(context.scope.title) — \(scopeMeaning(context.scope))).
            """
    }

    private static func scopeMeaning(_ scope: InsightsScope) -> String {
        switch scope {
        case .allHistory: "every recorded source"
        case .deviceAndManual: "device-detected and manually entered visits only, excluding imported journal entries"
        case .importedJournal: "imported journal entries only"
        case .confirmedLocations: "only visits at a confirmed or corrected location"
        }
    }
}

/// The exact shape the model is constrained to produce. Every field is either a
/// small closed vocabulary (via `@Guide(.anyOf:)`) or, for `subjectName`, an
/// echoed phrase — this struct is the model's entire output surface, and none of
/// it is treated as fact until `AskLifeLogPlanValidator` accepts it.
@Generable(description: "A choice of LifeLog query type and its parameters, not an answer to the question.")
private struct GeneratedAskLifeLogPlan {
    @Guide(
        description: "The supported query type that best matches the question, or 'unsupported'.",
        .anyOf(AskLifeLogRawPlan.supportedKinds)
    )
    var kind: String

    @Guide(description: "The place or activity phrase from the question, copied exactly, or empty.")
    var subjectName: String

    @Guide(
        description: "The period the question refers to.",
        .anyOf(["current", "today", "yesterday", "thisWeek", "lastWeek", "thisMonth", "lastMonth", "thisYear", "lastYear"])
    )
    var window: String

    @Guide(
        description: "Ranking direction, only for placeRankingByVisits/placeRankingByHours.",
        .anyOf(["most", "least", "notApplicable"])
    )
    var order: String

    @Guide(
        description: "Day of week, only for weekdayTimePattern.",
        .anyOf(["any", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"])
    )
    var weekday: String

    @Guide(
        description: "Time-of-day band, only for weekdayTimePattern.",
        .anyOf(["any", "morning", "midday", "afternoon", "evening", "night"])
    )
    var timeBand: String

    @Guide(
        description: "Which screen to open, only for navigation.",
        .anyOf(["notApplicable", "activity", "place", "comparison", "unloggedTime", "timeline"])
    )
    var navigationTarget: String

    @Guide(description: "How confident this plan captures the question, 0-100.", .range(0...100))
    var confidence: Int
}
