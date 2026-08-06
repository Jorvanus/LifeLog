import Foundation
import Testing
@testable import LifeLog

struct InsightsAggregationCacheTests {
    @Test("Insights invalidation actor advances its generation")
    func invalidationAdvancesGeneration() async {
        let cache = InsightsAggregationActor()
        let initial = await cache.currentGeneration()
        await cache.invalidate()
        #expect(await cache.currentGeneration() == initial + 1)
    }
}

struct DayHighlightTests {
    /// The comparison is the whole point of the card, so a day with nothing to be
    /// compared against must stay silent rather than dress a bare number up as news.
    @Test("Steps say nothing without enough history to compare against")
    func stepsNeedABaseline() {
        #expect(DayHighlights.steps(today: 5_000, weekdayBaseline: [], weekdayName: "Tuesday") == nil)
        #expect(DayHighlights.steps(today: 5_000, weekdayBaseline: [4_000], weekdayName: "Tuesday") == nil)
    }

    @Test("A clearly bigger day is celebrated, with the size of the change")
    func stepsCelebrateABigDay() {
        let highlight = DayHighlights.steps(today: 7_000, weekdayBaseline: [5_000, 5_000],
                                            weekdayName: "Tuesday")
        #expect(highlight?.isCelebration == true)
        #expect(highlight?.headline == "7,000 steps")
        #expect(highlight?.detail == "40% more than your usual Tuesday.")
    }

    @Test("A quieter day is reported plainly rather than congratulated")
    func stepsReportAQuietDay() {
        let highlight = DayHighlights.steps(today: 3_000, weekdayBaseline: [5_000, 5_000],
                                            weekdayName: "Tuesday")
        #expect(highlight?.isCelebration == false)
        #expect(highlight?.detail == "40% fewer than your usual Tuesday.")
    }

    /// Everything moves a little. Inventing a trend out of a few percent would make
    /// every other highlight less believable.
    @Test("A day within the noise is called about the same")
    func stepsWithinNoiseAreUnremarkable() {
        let highlight = DayHighlights.steps(today: 5_150, weekdayBaseline: [5_000, 5_000],
                                            weekdayName: "Tuesday")
        #expect(highlight?.isCelebration == false)
        #expect(highlight?.detail == "About the same as your usual Tuesday.")
    }

    @Test("A longer night than usual is celebrated")
    func sleepCelebratesALongerNight() {
        let highlight = DayHighlights.sleep(lastNight: 8 * 3600, averageNight: 6.5 * 3600)
        #expect(highlight?.isCelebration == true)
        #expect(highlight?.headline == "8h asleep")
    }

    @Test("No sleep recorded says nothing at all")
    func sleepNeedsBothSides() {
        #expect(DayHighlights.sleep(lastNight: 0, averageNight: 7 * 3600) == nil)
        #expect(DayHighlights.sleep(lastNight: 7 * 3600, averageNight: 0) == nil)
    }

    /// This highlight is built from LifeLog's own visits, so the card still has
    /// something true to say on a phone that never granted Health access.
    @Test("The largest change in how time was spent needs no Health data")
    func activityHighlightUsesComparisons() {
        let comparisons = [
            TrendComparison(name: "Work", hours: 6, previousHours: 5, delta: 1),
            TrendComparison(name: "Home", hours: 4, previousHours: 7, delta: -3)
        ]
        let highlight = DayHighlights.activity(from: comparisons, window: .day)
        #expect(highlight?.headline == "3h less on home")
    }

    /// Time has no agreed direction, so an activity shift is reported, never praised.
    /// Deciding that more hours at home deserved congratulation would be the app
    /// having an opinion about how the day should have gone.
    @Test("A shift in how time was spent is never dressed up as an achievement")
    func activityChangesAreNeverCelebrated() {
        let more = [TrendComparison(name: "Home", hours: 11, previousHours: 2, delta: 9)]
        let less = [TrendComparison(name: "Home", hours: 2, previousHours: 11, delta: -9)]
        #expect(DayHighlights.activity(from: more, window: .day)?.isCelebration == false)
        #expect(DayHighlights.activity(from: less, window: .day)?.isCelebration == false)
    }

    @Test("A change too small to matter is not reported as one")
    func activityIgnoresTinyChanges() {
        let comparisons = [TrendComparison(name: "Work", hours: 6, previousHours: 6.1, delta: -0.1)]
        #expect(DayHighlights.activity(from: comparisons, window: .day) == nil)
    }
}

@MainActor
struct InsightsAwayFromHomeTests {
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func stay(_ startHour: Double, _ endHour: Double, place: String, activity: String) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: "automatic", recognitionConfidence: "learned")
    }

    private func sleep(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: "Sleep", inferredActivity: "Sleeping", userActivity: "Sleeping",
              source: "health-sleep", recognitionConfidence: "device")
    }

    /// Sleep is imported as "Sleeping" at a place called "Sleep", and it takes the
    /// segment over the Home stay it sits inside. Neither label says "home", so
    /// every night in your own bed used to be reported as time away from it.
    @Test("A night slept at home is not time away from home")
    func sleepInsideHomeIsNotAway() {
        let visits = [stay(0, 12, place: "Home", activity: "At home"), sleep(0, 7)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600)
        )
        #expect(snapshot.awayFromHomeHours == 0)
    }

    /// The same record, with no Home stay around it, is a night spent elsewhere.
    @Test("A night slept away from home still counts as away")
    func sleepAwayFromHomeIsAway() {
        let visits = [stay(0, 12, place: "Seaside Motel", activity: "Staying over"), sleep(0, 7)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600)
        )
        #expect(snapshot.awayFromHomeHours > 0)
    }

    /// A visit that names its own place is away from home whatever else claims
    /// those minutes — an open Home stay overlapping it must not absorb it.
    @Test("A place visit overlapping an open home stay is still time away")
    func overlappingPlaceVisitStaysAway() {
        let visits = [stay(0, 12, place: "Home", activity: "At home"),
                      stay(9, 11, place: "Gracemere Shopping World", activity: "Shopping")]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600)
        )
        #expect(snapshot.awayFromHomeHours > 0)
    }
}

@MainActor
struct InsightsTrendSeriesTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A part-finished week would show as a collapse in the line and pull the
    /// comparison sentence down with it, so the range stops at the last full week.
    @Test("The trend range ends at the last completed week")
    func rangeExcludesTheCurrentWeek() {
        let span = InsightsTrends.range(endingAt: now, calendar: calendar)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)

        #expect(span.end == thisWeek?.start)
        #expect(span.contains(now) == false)
    }

    @Test("The range covers exactly the weeks the charts draw")
    func rangeCoversTheChartedWeeks() {
        let span = InsightsTrends.range(endingAt: now, calendar: calendar)
        let weeks = calendar.dateComponents([.weekOfYear], from: span.start, to: span.end).weekOfYear

        #expect(weeks == InsightsTrends.weeks)
    }

    /// The sentence has to survive a first run, where there is a line but nothing
    /// behind it to call usual.
    @Test("With no history the message says so rather than inventing a comparison")
    func messageWithoutBaseline() {
        let message = InsightsTrends.message(title: "Home", latest: 40, baseline: 0)
        #expect(message.contains("Not enough history"))
    }

    @Test("A clearly bigger week reads as more than usual, in hours")
    func messageForABiggerWeek() {
        let message = InsightsTrends.message(title: "Home", latest: 60, baseline: 40)
        #expect(message.hasPrefix("More home than usual"))
        #expect(message.contains("60h"))
        #expect(message.contains("40h"))
    }

    @Test("A quieter week reads as less than usual")
    func messageForAQuieterWeek() {
        #expect(InsightsTrends.message(title: "Sleep", latest: 40, baseline: 56)
            .hasPrefix("Less sleep than usual"))
    }

    /// Matches the day highlights: a few percent either way is a week, not a trend.
    @Test("A week within the noise is called about the same")
    func messageWithinNoise() {
        #expect(InsightsTrends.message(title: "Sleep", latest: 56, baseline: 55)
            .hasPrefix("About as much sleep as usual"))
    }

    @Test("A week with the category missing is reported, not silently zeroed")
    func messageForAMissingWeek() {
        let message = InsightsTrends.message(title: "Home", latest: 0, baseline: 40)
        #expect(message.contains("Nothing recorded"))
    }

    /// The line is built from resolved segments, so an overnight stay and the sleep
    /// record inside it cannot both be counted — the week would otherwise total more
    /// hours than a week contains.
    @Test("A week's hours are resolved, not double-counted across overlapping records")
    func weeklyHoursResolveOverlaps() {
        let span = InsightsTrends.range(endingAt: now, calendar: calendar)
        let weekStart = span.start
        let stay = Visit(arrival: weekStart, departure: weekStart.addingTimeInterval(8 * 3600),
                         latitude: -23.378, longitude: 150.511,
                         placeName: "Home", inferredActivity: "At home", userActivity: "At home",
                         source: "automatic", recognitionConfidence: "learned")
        let sleeping = Visit(arrival: weekStart, departure: weekStart.addingTimeInterval(7 * 3600),
                             latitude: -23.378, longitude: 150.511,
                             placeName: "Sleep", inferredActivity: "Sleeping",
                             userActivity: "Sleeping", source: "health-sleep",
                             recognitionConfidence: "device")
        let totals = InsightsSnapshot.categoryHours(
            visits: [stay, sleeping],
            range: DateInterval(start: weekStart, end: weekStart.addingTimeInterval(8 * 3600)),
            now: now
        )

        #expect(abs(totals.values.reduce(0, +) - 8) < 0.001)
    }
}

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

@MainActor
struct InsightsWeekdayPatternTests {
    private let calendar = Calendar.current
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func stay(_ startHour: Double, _ endHour: Double, place: String, activity: String) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: "automatic", recognitionConfidence: "learned")
    }

    private func snapshot(_ visits: [Visit]) -> InsightsSnapshot {
        InsightsSnapshot.make(visits: visits, window: .day, anchorDate: day,
                              now: day.addingTimeInterval(24 * 3600))
    }

    /// Sleep is the largest and steadiest block of almost every day, so leaving it in
    /// flattened the seven bars into near-identical columns and hid the differences
    /// the chart exists to show.
    @Test("Sleep is left out of the weekly rhythm")
    func weekdayPatternsExcludeSleep() {
        let sleeping = Visit(arrival: day, departure: day.addingTimeInterval(7 * 3600),
                             latitude: -23.378, longitude: 150.511,
                             placeName: "Sleep", inferredActivity: "Sleeping",
                             userActivity: "Sleeping", source: "health-sleep",
                             recognitionConfidence: "device")
        let visits = [stay(8, 12, place: "Gracemere Shopping World", activity: "Shopping"), sleeping]
        let weekday = calendar.component(.weekday, from: day)
        let pattern = snapshot(visits).weekdayPatterns.first { $0.weekday == weekday }

        #expect(pattern?.activities.contains { $0.category == "Sleep" } == false)
        #expect(pattern?.hours == 4)
    }

    /// The bars are drawn from this breakdown, so a day's bands must add up to the
    /// total printed beside it.
    @Test("A weekday's activities add up to its total")
    func weekdayBreakdownSumsToTotal() {
        let visits = [stay(8, 12, place: "Gracemere Shopping World", activity: "Shopping"),
                      stay(13, 15, place: "Rockhampton Hospital", activity: "Donate Blood")]
        let weekday = calendar.component(.weekday, from: day)
        let pattern = snapshot(visits).weekdayPatterns.first { $0.weekday == weekday }
        let summed = pattern?.activities.reduce(0) { $0 + $1.hours } ?? 0

        #expect(pattern?.activities.count == 2)
        #expect(abs(summed - (pattern?.hours ?? 0)) < 0.001)
    }

    /// A Monday-first region must not be told its week begins on Sunday.
    @Test("The week is ordered from the calendar's own first day")
    func weekOrderStartsAtFirstWeekday() {
        let ordered = WeekdayPattern.empty.inWeekOrder

        #expect(ordered.count == 7)
        #expect(ordered.first?.weekday == calendar.firstWeekday)
        #expect(Set(ordered.map(\.weekday)) == Set(1...7))
    }
}
