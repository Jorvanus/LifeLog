import Foundation
import Testing
@testable import LifeLog

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
        let highlight = DayHighlights.steps(today: 7_000, weekdayBaseline: [5_000, 5_000, 5_000, 5_000],
                                            weekdayName: "Tuesday")
        #expect(highlight?.isCelebration == true)
        #expect(highlight?.headline == "7,000 steps")
        #expect(highlight?.detail == "40% more than your usual Tuesday.")
    }

    @Test("A quieter day is reported plainly rather than congratulated")
    func stepsReportAQuietDay() {
        let highlight = DayHighlights.steps(today: 3_000, weekdayBaseline: [5_000, 5_000, 5_000, 5_000],
                                            weekdayName: "Tuesday")
        #expect(highlight?.isCelebration == false)
        #expect(highlight?.detail == "40% fewer than your usual Tuesday.")
    }

    /// Everything moves a little. Inventing a trend out of a few percent would make
    /// every other highlight less believable.
    @Test("A day within the noise is called about the same")
    func stepsWithinNoiseAreUnremarkable() {
        let highlight = DayHighlights.steps(today: 5_150, weekdayBaseline: [5_000, 5_000, 5_000, 5_000],
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

    @Test("A catch-all Other comparison is not presented as an insight")
    func activitySuppressesOther() {
        let comparisons = [
            TrendComparison(name: "Other", hours: 8, previousHours: 1, delta: 7),
            TrendComparison(name: "Work", hours: 4, previousHours: 3, delta: 1)
        ]
        #expect(DayHighlights.activity(from: comparisons, window: .day) == nil)
    }
}
