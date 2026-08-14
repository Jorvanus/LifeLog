import Foundation
import Testing
@testable import LifeLog

@MainActor
struct InsightsHabitTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a run of weeks from one category's hours, oldest first.
    private func weeks(_ hours: [Double], category: String = "Entertainment") -> [WeeklyTotals] {
        hours.enumerated().map { index, value in
            WeeklyTotals(
                weekStart: calendar.date(byAdding: .weekOfYear, value: index, to: start)!,
                hours: value > 0 ? [category: value] : [:]
            )
        }
    }

    @Test("Something never seen before is reported as a first")
    func firstTimeInTheWindow() {
        let habits = InsightsTrends.habits(from: weeks([0, 0, 0, 0, 0, 2]), calendar: calendar)
        #expect(habits.count == 1)
        #expect(habits.first?.headline == "First entertainment in 6 weeks")
    }

    @Test("Something taken up again after a long gap names when it last happened")
    func returnAfterAGap() {
        let habits = InsightsTrends.habits(from: weeks([3, 0, 0, 0, 0, 2]), calendar: calendar)
        #expect(habits.first?.headline == "Back to entertainment")
        #expect(habits.first?.detail.contains("5 weeks away") == true)
    }

    /// A week or two off is ordinary life, not a comeback.
    @Test("A short gap is not treated as a return")
    func shortGapIsNotAReturn() {
        let habits = InsightsTrends.habits(from: weeks([3, 3, 3, 0, 2]), calendar: calendar)
        #expect(habits.contains { $0.headline == "Back to entertainment" } == false)
    }

    @Test("A best week is reported against the previous best")
    func newHighBeatsThePreviousBest() {
        let habits = InsightsTrends.habits(from: weeks([1, 2, 3, 9]), calendar: calendar)
        #expect(habits.first?.headline == "Most entertainment in 4 weeks")
        #expect(habits.first?.detail.contains("beating 3h") == true)
    }

    @Test("A run of weeks is reported once it is long enough to mean something")
    func longRunsAreReported() {
        let habits = InsightsTrends.habits(from: weeks([0, 2, 2, 2, 2, 2]), calendar: calendar)
        #expect(habits.first?.headline == "5 weeks of entertainment")
    }

    @Test("Three weeks running is a coincidence, not a habit")
    func shortRunsAreNotReported() {
        let habits = InsightsTrends.habits(from: weeks([0, 0, 2, 2, 2]), calendar: calendar)
        #expect(habits.contains { $0.headline.contains("weeks of") } == false)
    }

    /// Sleeping and being at home every week is a fact about being alive, not a
    /// habit worth surfacing. Both have their own cards asking how much instead.
    @Test("Sleep and Home never appear as habits")
    func constantCategoriesAreExcluded() {
        for category in ["Sleep", "Home", "Unlogged", "Uncategorised"] {
            let run = weeks([0, 0, 0, 0, 0, 40], category: category)
            #expect(InsightsTrends.habits(from: run, calendar: calendar).isEmpty)
        }
    }

    @Test("At most two habits are shown, however many qualify")
    func atMostTwoAreShown() {
        let combined: [WeeklyTotals] = (0..<6).map { index in
            WeeklyTotals(
                weekStart: calendar.date(byAdding: .weekOfYear, value: index, to: start)!,
                hours: index == 5 ? ["Entertainment": 2, "Fitness": 3, "Shopping": 4] : [:]
            )
        }
        #expect(InsightsTrends.habits(from: combined, calendar: calendar).count == 2)
    }

    @Test("A single week of history says nothing")
    func oneWeekIsNotEnough() {
        #expect(InsightsTrends.habits(from: weeks([2]), calendar: calendar).isEmpty)
    }

    /// A brush past a place is not taking something up.
    @Test("A few minutes does not count as doing something")
    func trivialTimeIsIgnored() {
        #expect(InsightsTrends.habits(from: weeks([0, 0, 0, 0, 0.1]), calendar: calendar).isEmpty)
    }
}
