import Foundation
import Testing
@testable import LifeLog

/// `AskLifeLogPlanValidator`: the one place a raw planner response becomes (or
/// fails to become) LifeLog's strict query-plan vocabulary. Covers every
/// supported kind converting cleanly, and the shapes that must be rejected
/// rather than let a planner improvise an unsupported operation.
struct AskLifeLogPlanValidatorTests {
    @Test("Every supported kind converts to its matching plan case")
    func validKindsConvert() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "activityTotal", subjectName: "Working", window: "thisWeek"))
                == .activityTotal(activity: .init("Working"), window: .thisWeek))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeTotal", subjectName: "Work", window: "thisMonth"))
                == .placeTotal(place: .init("Work"), window: .thisMonth))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeRankingByVisits", order: "most"))
                == .placeRanking(metric: .visitCount, order: .most, window: .current))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeRankingByHours", order: "least"))
                == .placeRanking(metric: .totalHours, order: .least, window: .current))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "lastVisitToPlace", subjectName: "Coffee Society"))
                == .lastVisitToPlace(place: .init("Coffee Society")))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "weekdayTimePattern", weekday: "friday", timeBand: "evening"))
                == .weekdayTimePattern(weekday: .friday, timeBand: .evening, window: .current))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "strongestComparison", window: "lastMonth"))
                == .strongestComparison(window: .lastMonth))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "unloggedTimeReview", window: "thisMonth"))
                == .unloggedTimeReview(window: .thisMonth))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "navigation", subjectName: "Work", navigationTarget: "activity"))
                == .navigation(.activity(.init("Work"))))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "navigation", navigationTarget: "unloggedTime"))
                == .navigation(.unloggedTime))
    }

    @Test("An explicit 'unsupported' kind is not a valid plan")
    func unsupportedKindProducesNoPlan() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "unsupported")) == nil)
    }

    @Test("A kind outside the closed vocabulary is rejected, not improvised")
    func unknownKindRejected() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "deleteAllVisits")) == nil)
    }

    @Test("activityTotal/placeTotal/lastVisitToPlace without a subject phrase are rejected")
    func missingSubjectRejected() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "activityTotal", subjectName: "")) == nil)
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeTotal", subjectName: "")) == nil)
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "lastVisitToPlace", subjectName: "")) == nil)
    }

    @Test("placeRanking with an invalid order is rejected")
    func invalidRankingOrderRejected() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeRankingByVisits", order: "notApplicable")) == nil)
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "placeRankingByVisits", order: "sideways")) == nil)
    }

    @Test("weekdayTimePattern with neither a weekday nor a time band is rejected as a no-op query")
    func degenerateWeekdayPatternRejected() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "weekdayTimePattern", weekday: "any", timeBand: "any")) == nil)
    }

    @Test("weekdayTimePattern with just one of weekday/timeBand still resolves")
    func partialWeekdayPatternAccepted() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "weekdayTimePattern", weekday: "friday", timeBand: "any"))
                == .weekdayTimePattern(weekday: .friday, timeBand: nil, window: .current))
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "weekdayTimePattern", weekday: "any", timeBand: "evening"))
                == .weekdayTimePattern(weekday: nil, timeBand: .evening, window: .current))
    }

    @Test("navigation without a resolvable target, or missing a required subject, is rejected")
    func invalidNavigationRejected() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "navigation", navigationTarget: "notApplicable")) == nil)
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "navigation", subjectName: "", navigationTarget: "place")) == nil)
    }

    @Test("An unrecognised window term falls back to 'current' rather than failing the whole plan")
    func unknownWindowFallsBackToCurrent() {
        #expect(AskLifeLogPlanValidator.validate(.init(kind: "strongestComparison", window: "nextDecade"))
                == .strongestComparison(window: .current))
    }
}

/// `AskLifeLogRelativeWindow.resolved(in:)`: every term LifeLog's own closed
/// vocabulary supports resolves to the exact calendar interval a person would
/// expect, entirely locally — the model never computes a date itself.
struct AskLifeLogRelativeWindowTests {
    private let calendar = Calendar.current

    private func context(now: Date, window: InsightWindow = .day) -> AskLifeLogQuestionContext {
        .current(window: window, interval: window.interval(containing: now), now: now, scope: .allHistory)
    }

    @Test("'today' and 'yesterday' resolve across a month boundary")
    func todayYesterdayCrossMonthBoundary() {
        // 1 March 00:30 local -- yesterday must land in February, not day 0 of March.
        var components = DateComponents(year: 2026, month: 3, day: 1, hour: 0, minute: 30)
        components.calendar = calendar
        let now = calendar.date(from: components)!
        let ctx = context(now: now)

        let today = AskLifeLogRelativeWindow.today.resolved(in: ctx)
        #expect(calendar.isDate(today.interval.start, inSameDayAs: now))

        let yesterday = AskLifeLogRelativeWindow.yesterday.resolved(in: ctx)
        #expect(calendar.component(.month, from: yesterday.interval.start) == 2)
        #expect(calendar.component(.day, from: yesterday.interval.start) == 28)
    }

    @Test("'lastMonth' crosses a year boundary from January to December")
    func lastMonthCrossesYearBoundary() {
        var components = DateComponents(year: 2026, month: 1, day: 15, hour: 10)
        components.calendar = calendar
        let now = calendar.date(from: components)!
        let resolved = AskLifeLogRelativeWindow.lastMonth.resolved(in: context(now: now))
        #expect(calendar.component(.year, from: resolved.interval.start) == 2025)
        #expect(calendar.component(.month, from: resolved.interval.start) == 12)
        #expect(resolved.isOngoing == false)
    }

    @Test("'lastYear' resolves to the full preceding calendar year")
    func lastYearResolvesFullPriorYear() {
        var components = DateComponents(year: 2026, month: 6, day: 1)
        components.calendar = calendar
        let now = calendar.date(from: components)!
        let resolved = AskLifeLogRelativeWindow.lastYear.resolved(in: context(now: now))
        #expect(calendar.component(.year, from: resolved.interval.start) == 2025)
        #expect(calendar.component(.year, from: resolved.interval.end.addingTimeInterval(-1)) == 2025)
    }

    @Test("'current' echoes exactly the selected window and interval, not a recomputed one")
    func currentEchoesSelection() {
        var components = DateComponents(year: 2026, month: 4, day: 10, hour: 9)
        components.calendar = calendar
        let now = calendar.date(from: components)!
        let selectedInterval = InsightWindow.week.interval(containing: now)
        let ctx = AskLifeLogQuestionContext.current(window: .week, interval: selectedInterval, now: now, scope: .allHistory)
        let resolved = AskLifeLogRelativeWindow.current.resolved(in: ctx)
        #expect(resolved.window == .week)
        #expect(resolved.interval == selectedInterval)
    }

    @Test("An in-progress period is reported as ongoing; a completed one is not")
    func ongoingFlagReflectsWhetherNowFallsInside() {
        let now = Date.now
        let thisWeek = AskLifeLogRelativeWindow.thisWeek.resolved(in: context(now: now))
        #expect(thisWeek.isOngoing == true)

        let lastWeekAnchor = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
        let lastWeek = AskLifeLogRelativeWindow.lastWeek.resolved(in: context(now: now))
        #expect(lastWeek.interval.contains(lastWeekAnchor))
        #expect(lastWeek.isOngoing == false)
    }
}
