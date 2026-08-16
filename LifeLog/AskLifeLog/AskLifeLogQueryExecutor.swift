import Foundation

/// The final, concise answer to a question — everything Ask LifeLog's result
/// view shows. No field here was ever produced by the model: every figure,
/// ranking, and comparison came from `AskLifeLogQueryExecutor` running a
/// resolved plan against LifeLog's own aggregation/comparison/place-history logic.
struct AskLifeLogAnswer: Sendable, Equatable {
    let interpretedQuestion: String
    let periodTitle: String
    let scopeTitle: String
    let headline: String
    /// A comparison baseline note, a caveat, or `nil` when the headline speaks
    /// for itself.
    let detail: String?
    let supportingRows: [String]
    let drillDown: InsightsRoute?
    let drillDownLabel: String?
}

/// What running a resolved plan produced. Ambiguity and "no match" are distinct
/// from "no data": the first two mean LifeLog couldn't tell what place/activity
/// was meant, the last means it could, but nothing was recorded.
enum AskLifeLogExecutionResult: Sendable, Equatable {
    case answer(AskLifeLogAnswer)
    case ambiguousPlace(candidates: [AskLifeLogPlaceCandidate], plan: AskLifeLogQueryPlan)
    case ambiguousActivity(candidates: [AskLifeLogActivityCandidate], plan: AskLifeLogQueryPlan)
    case noMatch(phrase: String)
    case noData(periodTitle: String)
    case noBaseline(periodTitle: String)

    /// Privacy-safe label for diagnostics — never the answer's own content,
    /// the resolved name, or the period/scope text.
    var diagnosticCategory: String {
        switch self {
        case .answer: "answer"
        case .ambiguousPlace: "ambiguousPlace"
        case .ambiguousActivity: "ambiguousActivity"
        case .noMatch: "noMatch"
        case .noData: "noData"
        case .noBaseline: "noBaseline"
        }
    }
}

/// Executes a validated `AskLifeLogQueryPlan` deterministically against LifeLog's
/// existing bounded archive/query infrastructure — `VisitArchiveReader` and
/// `ArchiveRepairActor`, both `@ModelActor` background actors, plus the
/// `nonisolated static` aggregation helpers on `InsightsSnapshot` they call
/// internally. Every date interval, total, ranking, and comparison is computed
/// here or in one of those; nothing here ever asks the model for a number.
///
/// Stateless and cache-free on purpose: a fresh question is a fresh, bounded
/// read, and staleness/cancellation is the caller's responsibility (see
/// `AskLifeLogViewModel`), not this type's.
@MainActor
enum AskLifeLogQueryExecutor {
    static func execute(_ plan: AskLifeLogQueryPlan, context: AskLifeLogQuestionContext,
                        reader: VisitArchiveReader, repairActor: ArchiveRepairActor,
                        catalogue: [ActivityDefinition]) async throws -> AskLifeLogExecutionResult {
        switch plan {
        case .activityTotal(let activity, let window):
            return try await activityTotal(activity, window: window, context: context, reader: reader, catalogue: catalogue)
        case .placeTotal(let place, let window):
            return try await placeTotal(place, window: window, context: context, reader: reader)
        case .placeRanking(let metric, let order, let window):
            return try await placeRanking(metric: metric, order: order, window: window, context: context, reader: reader)
        case .lastVisitToPlace(let place):
            return try await lastVisitToPlace(place, context: context, reader: reader)
        case .weekdayTimePattern(let weekday, let timeBand, let window):
            return try await weekdayTimePattern(weekday: weekday, timeBand: timeBand, window: window, context: context, reader: reader)
        case .strongestComparison(let window):
            return try await strongestComparison(window: window, context: context, reader: reader)
        case .unloggedTimeReview(let window):
            return try await unloggedTimeReview(window: window, context: context, repairActor: repairActor)
        case .navigation(let target):
            return try await navigation(target, context: context, reader: reader, catalogue: catalogue)
        }
    }

    // MARK: - Query types

    private static func activityTotal(_ activity: AskLifeLogUnresolvedReference, window: AskLifeLogRelativeWindow,
                                      context: AskLifeLogQuestionContext, reader: VisitArchiveReader,
                                      catalogue: [ActivityDefinition]) async throws -> AskLifeLogExecutionResult {
        switch AskLifeLogResolver.resolveActivity(activity, among: catalogue) {
        case .none: return .noMatch(phrase: activity.phrase)
        case .ambiguous(let candidates): return .ambiguousActivity(candidates: candidates, plan: .activityTotal(activity: activity, window: window))
        case .resolved(let candidate):
            let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
            // Match every alias the resolved activity answers to, not just its
            // current label — see `activityTotalHours(activityAliases:...)`.
            let aliases = Set([candidate.name] + (catalogue.first { $0.name == candidate.name }?.legacyNames ?? []))
            let hours = try await reader.activityTotalHours(activityAliases: aliases, in: interval, scope: context.scope, now: context.now)
            guard hours > 0.01 else { return .noData(periodTitle: periodLabel(resolvedWindow, interval, isOngoing)) }
            return .answer(AskLifeLogAnswer(
                interpretedQuestion: "Time spent on \(candidate.name)",
                periodTitle: periodLabel(resolvedWindow, interval, isOngoing), scopeTitle: context.scope.title,
                headline: formatHours(hours), detail: nil, supportingRows: [],
                drillDown: .activity(name: candidate.name, isUnlogged: false),
                drillDownLabel: "View \(candidate.name) visits"
            ))
        }
    }

    private static func placeTotal(_ place: AskLifeLogUnresolvedReference, window: AskLifeLogRelativeWindow,
                                   context: AskLifeLogQuestionContext, reader: VisitArchiveReader) async throws -> AskLifeLogExecutionResult {
        let summaries = try await scopedPlaceSummaries(reader)
        switch AskLifeLogResolver.resolvePlace(place, among: summaries) {
        case .none: return .noMatch(phrase: place.phrase)
        case .ambiguous(let candidates): return .ambiguousPlace(candidates: candidates, plan: .placeTotal(place: place, window: window))
        case .resolved(let candidate):
            let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
            let hours = try await reader.placeTotalHours(place: candidate.name, in: interval, scope: context.scope, now: context.now)
            guard hours > 0.01 else { return .noData(periodTitle: periodLabel(resolvedWindow, interval, isOngoing)) }
            return .answer(AskLifeLogAnswer(
                interpretedQuestion: "Time spent at \(candidate.name)",
                periodTitle: periodLabel(resolvedWindow, interval, isOngoing), scopeTitle: context.scope.title,
                headline: formatHours(hours), detail: nil, supportingRows: [],
                drillDown: .place(name: candidate.name), drillDownLabel: "View \(candidate.name) visits"
            ))
        }
    }

    private static func placeRanking(metric: PlaceRankingMetric, order: RankingOrder, window: AskLifeLogRelativeWindow,
                                     context: AskLifeLogQuestionContext, reader: VisitArchiveReader) async throws -> AskLifeLogExecutionResult {
        let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
        let title = periodLabel(resolvedWindow, interval, isOngoing)
        switch metric {
        case .totalHours:
            let places = try await reader.rankedPlaceHours(in: interval, scope: context.scope, now: context.now)
            let ranked = order == .most ? places : places.reversed()
            guard let top = ranked.first else { return .noData(periodTitle: title) }
            return .answer(AskLifeLogAnswer(
                interpretedQuestion: "\(order == .most ? "Most" : "Least") time spent at a place",
                periodTitle: title, scopeTitle: context.scope.title,
                headline: "\(top.name) — \(formatHours(top.hours))", detail: nil,
                supportingRows: ranked.prefix(5).map { "\($0.name): \(formatHours($0.hours))" },
                drillDown: .place(name: top.name), drillDownLabel: "View \(top.name) visits"
            ))
        case .visitCount:
            let counts = try await reader.placeVisitCounts(in: interval, scope: context.scope, now: context.now)
            let ranked = order == .most ? counts.sorted { $0.value > $1.value } : counts.sorted { $0.value < $1.value }
            guard let top = ranked.first else { return .noData(periodTitle: title) }
            func label(_ count: Int) -> String { "\(count) visit\(count == 1 ? "" : "s")" }
            return .answer(AskLifeLogAnswer(
                interpretedQuestion: "\(order == .most ? "Most" : "Least") visited place",
                periodTitle: title, scopeTitle: context.scope.title,
                headline: "\(top.key) — \(label(top.value))", detail: nil,
                supportingRows: ranked.prefix(5).map { "\($0.key): \(label($0.value))" },
                drillDown: .place(name: top.key), drillDownLabel: "View \(top.key) visits"
            ))
        }
    }

    private static func lastVisitToPlace(_ place: AskLifeLogUnresolvedReference, context: AskLifeLogQuestionContext,
                                         reader: VisitArchiveReader) async throws -> AskLifeLogExecutionResult {
        let summaries = try await scopedPlaceSummaries(reader)
        switch AskLifeLogResolver.resolvePlace(place, among: summaries) {
        case .none: return .noMatch(phrase: place.phrase)
        case .ambiguous(let candidates): return .ambiguousPlace(candidates: candidates, plan: .lastVisitToPlace(place: place))
        case .resolved(let candidate):
            let occurrences = try await reader.placeOccurrences(matching: candidate.name, before: context.now, scope: context.scope)
            guard let last = occurrences.max(by: { $0.arrival < $1.arrival }) else {
                return .noMatch(phrase: candidate.name)
            }
            return .answer(AskLifeLogAnswer(
                interpretedQuestion: "Last visit to \(candidate.name)",
                periodTitle: "All history", scopeTitle: context.scope.title,
                headline: last.arrival.formatted(.dateTime.day().month(.wide).year()),
                detail: relativeDescription(from: last.arrival, to: context.now),
                supportingRows: [], drillDown: .place(name: candidate.name), drillDownLabel: "View \(candidate.name) visits"
            ))
        }
    }

    private static func weekdayTimePattern(weekday: AskLifeLogWeekday?, timeBand: AskLifeLogTimeBand?, window: AskLifeLogRelativeWindow,
                                           context: AskLifeLogQuestionContext, reader: VisitArchiveReader) async throws -> AskLifeLogExecutionResult {
        let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
        let title = periodLabel(resolvedWindow, interval, isOngoing)
        let places = try await reader.weekdayTimePatternPlaces(weekday: weekday, timeBand: timeBand, in: interval, scope: context.scope, now: context.now)
        guard let top = places.first else { return .noData(periodTitle: title) }
        let descriptor = [weekday?.name, timeBand?.rawValue.capitalized].compactMap { $0 }.joined(separator: " ")
        return .answer(AskLifeLogAnswer(
            interpretedQuestion: "Where you usually spend \(descriptor.isEmpty ? "this time" : descriptor)",
            periodTitle: title, scopeTitle: context.scope.title,
            headline: "\(top.name) — \(formatHours(top.hours))", detail: nil,
            supportingRows: places.prefix(5).map { "\($0.name): \(formatHours($0.hours))" },
            drillDown: .place(name: top.name), drillDownLabel: "View \(top.name) visits"
        ))
    }

    private static func strongestComparison(window: AskLifeLogRelativeWindow, context: AskLifeLogQuestionContext,
                                             reader: VisitArchiveReader) async throws -> AskLifeLogExecutionResult {
        let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
        let title = periodLabel(resolvedWindow, interval, isOngoing)
        let previousInterval = resolvedWindow.previousComparisonInterval(for: interval)
        guard let comparison = try await reader.strongestComparison(in: interval, previousInterval: previousInterval, scope: context.scope, now: context.now) else {
            return .noBaseline(periodTitle: title)
        }
        let direction = comparison.delta >= 0 ? "more" : "less"
        let percentage = comparison.previousHours > 0
            ? " (\(Int((abs(comparison.delta) / comparison.previousHours * 100).rounded()))%)" : " (new)"
        return .answer(AskLifeLogAnswer(
            interpretedQuestion: "What changed most",
            periodTitle: title, scopeTitle: context.scope.title,
            headline: "\(formatHours(abs(comparison.delta)))\(percentage) \(direction) on \(comparison.name.lowercased())",
            detail: comparisonBaselineNote(resolvedWindow, interval, previousInterval, isOngoing),
            supportingRows: [],
            drillDown: .comparison(name: comparison.name, hours: comparison.hours, previousHours: comparison.previousHours, delta: comparison.delta),
            drillDownLabel: "View comparison"
        ))
    }

    private static func unloggedTimeReview(window: AskLifeLogRelativeWindow, context: AskLifeLogQuestionContext,
                                           repairActor: ArchiveRepairActor) async throws -> AskLifeLogExecutionResult {
        let (resolvedWindow, interval, isOngoing) = window.resolved(in: context)
        let title = periodLabel(resolvedWindow, interval, isOngoing)
        let gaps = try await repairActor.listGaps(now: context.now, scope: context.scope)
            .filter { $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.hours > $1.hours }
        guard !gaps.isEmpty else { return .noData(periodTitle: title) }
        let totalHours = gaps.reduce(0) { $0 + $1.hours }
        return .answer(AskLifeLogAnswer(
            interpretedQuestion: "Unlogged time",
            periodTitle: title, scopeTitle: context.scope.title,
            headline: "\(gaps.count) gap\(gaps.count == 1 ? "" : "s") · \(formatHours(totalHours))", detail: nil,
            supportingRows: gaps.prefix(5).map { "\(formatHours($0.hours)) — \($0.beforePlaceName) to \($0.afterPlaceName)" },
            drillDown: .unloggedTime, drillDownLabel: "Review unlogged time"
        ))
    }

    /// Navigation still resolves any named place/activity through the same
    /// bounded local matching as every other query type — "open Coffee Society"
    /// must not let the model pick between two similarly named places any more
    /// than a total or a comparison would.
    private static func navigation(_ target: AskLifeLogNavigationTarget, context: AskLifeLogQuestionContext,
                                   reader: VisitArchiveReader, catalogue: [ActivityDefinition]) async throws -> AskLifeLogExecutionResult {
        let periodTitle = periodLabel(context.selectedWindow, context.selectedInterval, context.selectedIntervalIsOngoing)
        func opening(_ name: String, route: InsightsRoute) -> AskLifeLogExecutionResult {
            .answer(AskLifeLogAnswer(interpretedQuestion: "Open \(name)", periodTitle: periodTitle, scopeTitle: context.scope.title,
                                     headline: "Opening \(name)", detail: nil, supportingRows: [],
                                     drillDown: route, drillDownLabel: "Open \(name)"))
        }
        switch target {
        case .activity(let reference):
            switch AskLifeLogResolver.resolveActivity(reference, among: catalogue) {
            case .none: return .noMatch(phrase: reference.phrase)
            case .ambiguous(let candidates): return .ambiguousActivity(candidates: candidates, plan: .navigation(.activity(reference)))
            case .resolved(let candidate): return opening(candidate.name, route: .activity(name: candidate.name, isUnlogged: false))
            }
        case .place(let reference):
            let summaries = try await scopedPlaceSummaries(reader)
            switch AskLifeLogResolver.resolvePlace(reference, among: summaries) {
            case .none: return .noMatch(phrase: reference.phrase)
            case .ambiguous(let candidates): return .ambiguousPlace(candidates: candidates, plan: .navigation(.place(reference)))
            case .resolved(let candidate): return opening(candidate.name, route: .place(name: candidate.name))
            }
        case .unloggedTime:
            return opening("unlogged time", route: .unloggedTime)
        case .comparison, .timeline:
            // Neither has a single existing `InsightsRoute` destination to push
            // to (comparison needs one specific entry; the timeline is a
            // different tab entirely) — Ask LifeLog says so honestly instead
            // of guessing a target or pretending a link that doesn't exist.
            let name = target == .comparison ? "the comparison list" : "the Timeline tab"
            return .answer(AskLifeLogAnswer(interpretedQuestion: "Open \(name)", periodTitle: periodTitle, scopeTitle: context.scope.title,
                                            headline: "Open \(name) to see this", detail: nil, supportingRows: [],
                                            drillDown: nil, drillDownLabel: nil))
        }
    }

    // MARK: - Helpers

    private static func scopedPlaceSummaries(_ reader: VisitArchiveReader) async throws -> [PlaceHistorySummary] {
        let generation = InsightsAggregationActor.shared.currentGeneration()
        return try await reader.placeSummaries(generation: generation).summaries
    }

    private static func periodLabel(_ window: InsightWindow, _ interval: DateInterval, _ isOngoing: Bool) -> String {
        let title = window.title(for: interval)
        return isOngoing ? "\(title) (so far)" : title
    }

    private static func comparisonBaselineNote(_ window: InsightWindow, _ interval: DateInterval,
                                               _ previousInterval: DateInterval, _ isOngoing: Bool) -> String {
        if isOngoing {
            let days = max(1, Int(interval.duration / 86400))
            return "Compared with the same first \(days) day\(days == 1 ? "" : "s") of the previous \(window.rawValue)."
        }
        return "Compared with the previous \(window.rawValue), \(window.title(for: previousInterval))."
    }

    private static func relativeDescription(from date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
