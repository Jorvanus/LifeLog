import Foundation
import Testing
@testable import LifeLog

/// The pieces Week's rolling-baseline comparison and commute summary are
/// built from: `InsightsTrends.weeklyTotals` never handing back a partial
/// in-progress week, `InsightsSnapshot.makeSegments` handling a day with no
/// visits at all, the noticeable-change threshold the routine-changes
/// section reuses, and the commute confidence gate.
@MainActor
struct InsightsWeekBaselineTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Same fixture shape `InsightsHabitTests` already uses: a run of weeks
    /// from one category's hours, oldest first, no `ModelContainer` needed.
    private func weeks(_ hours: [Double], category: String = "Work") -> [WeeklyTotals] {
        hours.enumerated().map { index, value in
            WeeklyTotals(
                weekStart: calendar.date(byAdding: .weekOfYear, value: index, to: start)!,
                hours: value > 0 ? [category: value] : [:]
            )
        }
    }

    @Test("The rolling baseline never includes the in-progress week")
    func baselineExcludesPartialCurrentWeek() {
        // A Wednesday partway through a week, with visits recorded up to now.
        let midWeek = calendar.date(byAdding: .day, value: 2, to: start)!
        let visit = Visit(arrival: midWeek, departure: midWeek.addingTimeInterval(3_600),
                          latitude: -23.378, longitude: 150.511,
                          placeName: "Office", inferredActivity: "Working", userActivity: "Working",
                          source: "automatic", recognitionConfidence: "learned")
        let totals = InsightsTrends.weeklyTotals(visits: [visit], now: midWeek, weeks: 4, calendar: calendar)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: midWeek)!.start
        #expect(totals.allSatisfy { $0.weekStart < currentWeekStart },
                "no returned week starts on or after the week `now` falls in")
        // The visit itself, recorded inside the in-progress week, must not
        // silently leak into an earlier bucket's total either.
        #expect(totals.reduce(0) { $0 + ($1.hours["Work"] ?? 0) } == 0)
    }

    @Test("A day with no visits at all is one full-day unlogged segment, not empty or a crash")
    func emptyDayProducesOneUnloggedSegment() {
        let dayInterval = DateInterval(start: start, end: start.addingTimeInterval(24 * 3_600))
        let segments = InsightsSnapshot.makeSegments(visits: [], locationVisits: [], range: dayInterval, now: dayInterval.end)
        #expect(segments.count == 1)
        #expect(segments.first?.isUnlogged == true)
        #expect(segments.first?.hours == 24)
    }

    @Test("The noticeable-change threshold includes a real swing and excludes a small one")
    func noticeableChangeThresholdGatesRoutineChanges() {
        // Baseline of 10h/week, this week 15h -- a 50% swing, well past 10%.
        let notable = weeks([10, 10, 10, 15])
        let notableSeries = InsightsTrends.series(for: "Work", title: "Work", symbol: "briefcase.fill", weeks: notable)
        let notableChange = abs(notableSeries.latest - notableSeries.baseline) / notableSeries.baseline
        #expect(notableChange >= InsightsTrends.noticeableChange)

        // Baseline of 10h/week, this week 10.5h -- a 5% swing, under the threshold.
        let quiet = weeks([10, 10, 10, 10.5])
        let quietSeries = InsightsTrends.series(for: "Work", title: "Work", symbol: "briefcase.fill", weeks: quiet)
        let quietChange = abs(quietSeries.latest - quietSeries.baseline) / quietSeries.baseline
        #expect(quietChange < InsightsTrends.noticeableChange)
    }

    @Test("A single commute day is not enough to summarise")
    func oneCommuteDayIsNotConfident() {
        let interval = DateInterval(start: start, end: start.addingTimeInterval(7 * 24 * 3_600))
        let commute = Commute(start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(5_400), direction: .toWork)
        let summary = InsightsSnapshot.weekCommuteSummary(commutes: [commute], weekInterval: interval, baselineHours: nil)
        #expect(summary == nil)
    }

    @Test("Two or more distinct commute days produce a real summary with correct totals")
    func twoCommuteDaysProduceASummary() throws {
        let interval = DateInterval(start: start, end: start.addingTimeInterval(7 * 24 * 3_600))
        let dayOne = Commute(start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(5_400), direction: .toWork)
        let dayTwo = Commute(start: start.addingTimeInterval(24 * 3_600 + 3_600),
                             end: start.addingTimeInterval(24 * 3_600 + 3_600 + 1_800), direction: .toWork)
        let summary = try #require(
            InsightsSnapshot.weekCommuteSummary(commutes: [dayOne, dayTwo], weekInterval: interval, baselineHours: 1.25)
        )
        #expect(summary.days == 2)
        #expect(summary.totalHours == 1)  // 30 min + 30 min
        #expect(summary.averageMinutes == 30)
        #expect(summary.changeFromUsual == -0.25)  // 1h vs a 1.25h baseline
    }

    @Test("categoryHours sums every category present in the segments")
    func categoryHoursCoversEveryCategory() {
        let home = InsightSegment(id: .visit(ObjectIdentifier(NSObject())), visit: nil, category: "Home",
                                  activity: "At home", placeName: "Home", start: start, end: start.addingTimeInterval(3_600),
                                  hours: 1, color: .blue, symbol: "house.fill", isUnlogged: false, isLive: false)
        let work = InsightSegment(id: .unlogged(0), visit: nil, category: "Work",
                                  activity: "Working", placeName: "Office", start: start, end: start.addingTimeInterval(7_200),
                                  hours: 2, color: .blue, symbol: "briefcase.fill", isUnlogged: false, isLive: false)
        let totals = InsightsSnapshot.categoryHours(in: [home, work])
        #expect(totals["Home"] == 1)
        #expect(totals["Work"] == 2)
    }

    @Test("Resolved segment identity survives an inserted segment")
    func segmentIdentitySurvivesSequenceChange() {
        let firstVisit = Visit(arrival: start, departure: start.addingTimeInterval(3_600),
                               latitude: -23.37, longitude: 150.51, placeName: "Home",
                               inferredActivity: "At home", source: "automatic")
        let secondVisit = Visit(arrival: start.addingTimeInterval(7_200),
                                departure: start.addingTimeInterval(10_800),
                                latitude: -23.38, longitude: 150.52, placeName: "Office",
                                inferredActivity: "Working", source: "automatic")
        let first = InsightSegment.visit(firstVisit, visibleFrom: firstVisit.arrival,
                                         visibleTo: firstVisit.departure!, now: start)
        let second = InsightSegment.visit(secondVisit, visibleFrom: secondVisit.arrival,
                                          visibleTo: secondVisit.departure!, now: start)
        let inserted = InsightSegment.unlogged(index: 0,
                                               from: start.addingTimeInterval(3_600),
                                               to: start.addingTimeInterval(7_200))

        let original = [first, second]
        let revised = [first, inserted, second]

        #expect(revised.map(\.id) == [first.id, inserted.id, second.id])
        #expect(revised[0].id == original[0].id)
        #expect(revised[2].id == original[1].id)
    }
}
