import Foundation
import Testing
@testable import LifeLog

/// A month in progress must be measured against the same elapsed span of the
/// previous month, not the whole of it — otherwise "more/less than last month"
/// is structurally misleading purely because less time has passed. Covers the
/// boundary math in `InsightWindow.previousComparisonInterval` (first day,
/// mid-month, leap years, different month lengths) and the end-to-end effect
/// on `InsightsSnapshot.make`'s resolved segments.
@MainActor
struct MonthComparisonTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func visit(_ start: Date, hours: Double, place: String, activity: String) -> Visit {
        Visit(arrival: start, departure: start.addingTimeInterval(hours * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: "automatic", recognitionConfidence: "learned")
    }

    // MARK: - Boundary math on `InsightWindow.previousComparisonInterval`

    @Test("A few hours into the first day of the month compares against the same hours on the first of last month")
    func firstDayOfMonth() {
        let start = date(2026, 6, 1)
        let elapsed = DateInterval(start: start, end: date(2026, 6, 1, hour: 3))
        let previous = InsightWindow.month.previousComparisonInterval(for: elapsed)
        #expect(previous.start == date(2026, 5, 1))
        #expect(previous.end == date(2026, 5, 1, hour: 3))
    }

    @Test("Mid-month elapsed span compares against the same elapsed span last month")
    func midMonth() {
        let start = date(2026, 8, 1)
        let elapsed = DateInterval(start: start, end: date(2026, 8, 12, hour: 9))
        let previous = InsightWindow.month.previousComparisonInterval(for: elapsed)
        #expect(previous.start == date(2026, 7, 1))
        #expect(previous.end == date(2026, 7, 12, hour: 9))
    }

    @Test("A completed month still compares against the whole preceding calendar month")
    func completedMonth() {
        let interval = InsightWindow.month.interval(containing: date(2026, 5, 15))
        let previous = InsightWindow.month.previousComparisonInterval(for: interval)
        #expect(previous.start == date(2026, 4, 1))
        #expect(previous.end == date(2026, 5, 1))
    }

    @Test("A 31-day month elapsed in full clamps against the shorter month before it")
    func differentMonthLengths() {
        // May has 31 days; April only has 30, so "May 31" one month back has no
        // literal match and must clamp to April 30, not overflow into May.
        let elapsed = DateInterval(start: date(2026, 5, 1), end: date(2026, 5, 31, hour: 23))
        let previous = InsightWindow.month.previousComparisonInterval(for: elapsed)
        #expect(previous.start == date(2026, 4, 1))
        #expect(previous.end == date(2026, 4, 30, hour: 23))
    }

    @Test("A leap-year February 29th compares against January 29th, not a rollover")
    func leapYear() {
        #expect(calendar.range(of: .day, in: .month, for: date(2028, 2, 1))?.count == 29,
                "2028 must actually be a leap year for this test to mean anything")
        let elapsed = DateInterval(start: date(2028, 2, 1), end: date(2028, 2, 29, hour: 23))
        let previous = InsightWindow.month.previousComparisonInterval(for: elapsed)
        #expect(previous.start == date(2028, 1, 1))
        #expect(previous.end == date(2028, 1, 29, hour: 23))
    }

    // MARK: - End-to-end: `InsightsSnapshot.make`

    /// The bug this whole file exists for: with the old month-specific special
    /// case, three days of this month were compared against the *whole* of last
    /// month, so a category with plenty of unrelated hours later in last month
    /// read as a huge drop even when the matching days were identical.
    @Test("A part-finished month is compared against the same elapsed days of the previous month")
    func partFinishedMonthMatchesElapsedDays() {
        let now = date(2026, 8, 3, hour: 18)
        let thisMonth = [
            visit(date(2026, 8, 1), hours: 4, place: "Office", activity: "Work"),
            visit(date(2026, 8, 2), hours: 4, place: "Office", activity: "Work")
        ]
        let lastMonth = [
            visit(date(2026, 7, 1), hours: 4, place: "Office", activity: "Work"),
            visit(date(2026, 7, 2), hours: 4, place: "Office", activity: "Work"),
            // Falls outside the matching elapsed window (days 1-3) and must not
            // be counted — under the old bug this alone would read as a ~20h drop.
            visit(date(2026, 7, 20), hours: 20, place: "Office", activity: "Work")
        ]
        let snapshot = InsightsSnapshot.make(visits: thisMonth + lastMonth, window: .month,
                                             anchorDate: now, now: now)
        #expect(!snapshot.comparisons.contains { $0.name == "Work" && abs($0.delta) > 1 },
                "eight hours against the matching eight is no change; against the whole month it would read as twenty fewer")
    }

    @Test("A real change against the matching elapsed days of the previous month is still reported")
    func partFinishedMonthStillReportsARealChange() {
        let now = date(2026, 8, 3, hour: 18)
        let thisMonth = [visit(date(2026, 8, 1), hours: 2, place: "Office", activity: "Work")]
        let lastMonth = [
            visit(date(2026, 7, 1), hours: 4, place: "Office", activity: "Work"),
            visit(date(2026, 7, 2), hours: 4, place: "Office", activity: "Work"),
            visit(date(2026, 7, 20), hours: 20, place: "Office", activity: "Work")
        ]
        let snapshot = InsightsSnapshot.make(visits: thisMonth + lastMonth, window: .month,
                                             anchorDate: now, now: now)
        #expect(snapshot.comparisons.contains { $0.name == "Work" && $0.delta <= -5 },
                "two hours against the matching eight is six fewer, whatever else happened later last month")
    }

    @Test("A completed month is still compared whole-against-whole")
    func completedMonthEndToEnd() {
        let now = date(2026, 9, 15)
        let thisMonth = [visit(date(2026, 8, 1), hours: 4, place: "Office", activity: "Work")]
        // Late in July, outside any "elapsed so far" window -- but July is a
        // completed month here, so it must still be counted in full.
        let lastMonth = [visit(date(2026, 7, 28), hours: 4, place: "Office", activity: "Work")]
        let snapshot = InsightsSnapshot.make(visits: thisMonth + lastMonth, window: .month,
                                             anchorDate: date(2026, 8, 15), now: now)
        #expect(!snapshot.comparisons.contains { $0.name == "Work" && abs($0.delta) > 1 },
                "four hours against four, wherever in the completed month they fell")
    }

    // MARK: - `MonthlyInsights.comparisonSubtitle`

    @Test("A month in progress states exactly how many days it was compared over")
    func comparisonSubtitleStatesElapsedDays() {
        let now = date(2026, 8, 3, hour: 18)
        let currentInterval = DateInterval(start: date(2026, 8, 1), end: now)
        let previousInterval = InsightWindow.month.previousComparisonInterval(for: currentInterval)
        let insights = MonthlyInsights.make(current: [], previous: [],
                                            currentInterval: currentInterval,
                                            previousInterval: previousInterval, now: now)
        #expect(insights.comparisonSubtitle == "Compared with the first 3 days of July")
    }

    @Test("A completed month names the whole previous month, not a day count")
    func comparisonSubtitleNamesCompletedMonth() {
        let interval = InsightWindow.month.interval(containing: date(2026, 8, 15))
        let previous = InsightWindow.month.previousComparisonInterval(for: interval)
        let insights = MonthlyInsights.make(current: [], previous: [],
                                            currentInterval: interval, previousInterval: previous,
                                            now: date(2026, 9, 15))
        #expect(insights.comparisonSubtitle == "Compared with July")
    }
}
