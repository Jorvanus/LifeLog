import Foundation

/// Everything a planner is given about the question being asked, other than the
/// question text itself. Deliberately data, not archive content: no Visit, no
/// SavedPlace, no coordinate ever appears here. `AskLifeLogPlanner` sends this
/// plus the question so the model can choose a query type and its parameters —
/// never so it can compute an answer.
struct AskLifeLogQuestionContext: Sendable, Equatable {
    let now: Date
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let localeIdentifier: String
    /// The period currently selected in Insights, so "this week" and an unqualified
    /// question both resolve the same way without another round trip.
    let selectedWindow: InsightWindow
    let selectedInterval: DateInterval
    let selectedIntervalIsOngoing: Bool
    let scope: InsightsScope

    static func current(window: InsightWindow, interval: DateInterval, now: Date, scope: InsightsScope,
                        calendar: Calendar = .current, locale: Locale = .current) -> AskLifeLogQuestionContext {
        AskLifeLogQuestionContext(
            now: now,
            calendarIdentifier: String(describing: calendar.identifier),
            timeZoneIdentifier: calendar.timeZone.identifier,
            localeIdentifier: locale.identifier,
            selectedWindow: window,
            selectedInterval: interval,
            selectedIntervalIsOngoing: interval.contains(now),
            scope: scope
        )
    }
}

/// A period a plan refers to, expressed as a closed vocabulary term rather than a
/// date. LifeLog is the only thing that ever turns one of these into a concrete
/// `DateInterval` — the model picks a term, never a date.
enum AskLifeLogRelativeWindow: String, Sendable, Equatable, CaseIterable {
    /// Whatever period is already selected in Insights when the question was asked.
    case current
    case today, yesterday
    case thisWeek, lastWeek
    case thisMonth, lastMonth
    case thisYear, lastYear

    /// Resolves this term into a concrete interval, deterministically, using the
    /// same calendar arithmetic as `InsightWindow`. `context` supplies "now" and
    /// the currently selected period so `.current` and an unqualified question
    /// answer identically.
    func resolved(in context: AskLifeLogQuestionContext) -> (window: InsightWindow, interval: DateInterval, isOngoing: Bool) {
        let calendar = Calendar.current
        func window(_ w: InsightWindow, anchor: Date) -> (InsightWindow, DateInterval, Bool) {
            let interval = w.interval(containing: anchor)
            return (w, interval, interval.contains(context.now))
        }
        switch self {
        case .current:
            return (context.selectedWindow, context.selectedInterval, context.selectedIntervalIsOngoing)
        case .today:
            return window(.day, anchor: context.now)
        case .yesterday:
            let anchor = calendar.date(byAdding: .day, value: -1, to: context.now) ?? context.now
            return window(.day, anchor: anchor)
        case .thisWeek:
            return window(.week, anchor: context.now)
        case .lastWeek:
            let anchor = calendar.date(byAdding: .weekOfYear, value: -1, to: context.now) ?? context.now
            return window(.week, anchor: anchor)
        case .thisMonth:
            return window(.month, anchor: context.now)
        case .lastMonth:
            let anchor = calendar.date(byAdding: .month, value: -1, to: context.now) ?? context.now
            return window(.month, anchor: anchor)
        case .thisYear:
            return window(.year, anchor: context.now)
        case .lastYear:
            let anchor = calendar.date(byAdding: .year, value: -1, to: context.now) ?? context.now
            return window(.year, anchor: anchor)
        }
    }
}

/// A broad part of the day, matching the bands `SmartActivityClassifier` already
/// uses so "evening" means the same stretch of hours everywhere in LifeLog.
enum AskLifeLogTimeBand: String, Sendable, Equatable, CaseIterable {
    case morning, midday, afternoon, evening, night

    func contains(hour: Int) -> Bool {
        switch self {
        case .morning: return (5..<11).contains(hour)
        case .midday: return (11..<14).contains(hour)
        case .afternoon: return (14..<18).contains(hour)
        case .evening: return (18..<22).contains(hour)
        case .night: return !(5..<22).contains(hour)
        }
    }
}

/// `Calendar`'s own weekday numbering (Sunday = 1) — used directly rather than a
/// separate enum so resolving a segment's weekday never needs a translation step.
enum AskLifeLogWeekday: Int, Sendable, Equatable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var name: String {
        Calendar.current.weekdaySymbols[rawValue - 1]
    }
}

enum PlaceRankingMetric: String, Sendable, Equatable {
    case visitCount, totalHours
}

enum RankingOrder: String, Sendable, Equatable {
    case most, least
}

/// A place or activity phrase exactly as the person said it, not yet matched to
/// anything in the archive. Resolving this locally (see `AskLifeLogResolver`) is a
/// separate step from planning — the model never sees the catalogue or history it
/// would be matched against.
struct AskLifeLogUnresolvedReference: Sendable, Equatable {
    let phrase: String

    init(_ phrase: String) {
        self.phrase = TextSafety.clean(phrase, maximumLength: 120)
    }

    var isEmpty: Bool { phrase.isEmpty }
}

enum AskLifeLogNavigationTarget: Sendable, Equatable {
    case activity(AskLifeLogUnresolvedReference)
    case place(AskLifeLogUnresolvedReference)
    case comparison
    case unloggedTime
    case timeline
}

/// LifeLog's complete supported query vocabulary. Every case here is something
/// `AskLifeLogQueryExecutor` can answer deterministically from existing
/// aggregation/comparison/place-history/gap logic — there is deliberately no case
/// that would require the model to have computed or invented anything.
enum AskLifeLogQueryPlan: Sendable, Equatable {
    case activityTotal(activity: AskLifeLogUnresolvedReference, window: AskLifeLogRelativeWindow)
    case placeTotal(place: AskLifeLogUnresolvedReference, window: AskLifeLogRelativeWindow)
    case placeRanking(metric: PlaceRankingMetric, order: RankingOrder, window: AskLifeLogRelativeWindow)
    case lastVisitToPlace(place: AskLifeLogUnresolvedReference)
    case weekdayTimePattern(weekday: AskLifeLogWeekday?, timeBand: AskLifeLogTimeBand?, window: AskLifeLogRelativeWindow)
    case strongestComparison(window: AskLifeLogRelativeWindow)
    case unloggedTimeReview(window: AskLifeLogRelativeWindow)
    case navigation(AskLifeLogNavigationTarget)
}

/// The flat shape a planner actually produces, before validation. Kept separate
/// from `AskLifeLogQueryPlan` so both the real Foundation Models planner and a
/// deterministic fake can build one from plain strings, and so validation logic
/// lives in exactly one place regardless of which planner produced the raw values.
///
/// Every field is a member of a small closed vocabulary (or an echoed phrase for
/// `subjectName`) — this is the entire surface the model is allowed to fill in.
struct AskLifeLogRawPlan: Sendable, Equatable {
    var kind: String
    var subjectName: String = ""
    var window: String = AskLifeLogRelativeWindow.current.rawValue
    var order: String = "notApplicable"
    var weekday: String = "any"
    var timeBand: String = "any"
    var navigationTarget: String = "notApplicable"
    var confidence: Int = 0

    static let supportedKinds = [
        "activityTotal", "placeTotal", "placeRankingByVisits", "placeRankingByHours",
        "lastVisitToPlace", "weekdayTimePattern", "strongestComparison",
        "unloggedTimeReview", "navigation", "unsupported",
    ]
}

/// Turns a raw planner response into LifeLog's strict query-plan vocabulary,
/// rejecting anything that doesn't cleanly fit a supported shape rather than
/// letting a planner improvise an unsupported operation. This is the one place
/// that decides whether a plan is valid — both the real planner and the fake test
/// planner produce an `AskLifeLogRawPlan` and go through the same gate.
enum AskLifeLogPlanValidator {
    static func validate(_ raw: AskLifeLogRawPlan) -> AskLifeLogQueryPlan? {
        let window = AskLifeLogRelativeWindow(rawValue: raw.window) ?? .current
        let subject = AskLifeLogUnresolvedReference(raw.subjectName)

        switch raw.kind {
        case "activityTotal":
            guard !subject.isEmpty else { return nil }
            return .activityTotal(activity: subject, window: window)

        case "placeTotal":
            guard !subject.isEmpty else { return nil }
            return .placeTotal(place: subject, window: window)

        case "placeRankingByVisits", "placeRankingByHours":
            guard let order = RankingOrder(rawValue: raw.order) else { return nil }
            let metric: PlaceRankingMetric = raw.kind == "placeRankingByVisits" ? .visitCount : .totalHours
            return .placeRanking(metric: metric, order: order, window: window)

        case "lastVisitToPlace":
            guard !subject.isEmpty else { return nil }
            return .lastVisitToPlace(place: subject)

        case "weekdayTimePattern":
            let weekdayIndex = ["any", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
                .firstIndex(of: raw.weekday)
            let weekday: AskLifeLogWeekday? = (weekdayIndex.map { $0 > 0 } ?? false)
                ? AskLifeLogWeekday(rawValue: weekdayIndex!) : nil
            let timeBand = AskLifeLogTimeBand(rawValue: raw.timeBand)
            guard weekday != nil || timeBand != nil else { return nil }
            return .weekdayTimePattern(weekday: weekday, timeBand: timeBand, window: window)

        case "strongestComparison":
            return .strongestComparison(window: window)

        case "unloggedTimeReview":
            return .unloggedTimeReview(window: window)

        case "navigation":
            switch raw.navigationTarget {
            case "activity":
                guard !subject.isEmpty else { return nil }
                return .navigation(.activity(subject))
            case "place":
                guard !subject.isEmpty else { return nil }
                return .navigation(.place(subject))
            case "comparison": return .navigation(.comparison)
            case "unloggedTime": return .navigation(.unloggedTime)
            case "timeline": return .navigation(.timeline)
            default: return nil
            }

        default:
            return nil
        }
    }
}
