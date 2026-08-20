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

    @Test("A day before LifeLog started is outside the unlogged timeline")
    func dayBeforeObservationStartProducesNoSegments() {
        let dayInterval = DateInterval(start: start, end: start.addingTimeInterval(24 * 3_600))
        let segments = InsightsSnapshot.makeSegments(visits: [], locationVisits: [], range: dayInterval,
                                                     now: dayInterval.end,
                                                     observationStart: dayInterval.end.addingTimeInterval(1))
        #expect(segments.isEmpty)
    }

    @Test("A silent period after LifeLog started remains an unlogged segment")
    func silentPeriodAfterObservationStartRemainsUnlogged() {
        let dayInterval = DateInterval(start: start, end: start.addingTimeInterval(24 * 3_600))
        let segments = InsightsSnapshot.makeSegments(visits: [], locationVisits: [], range: dayInterval,
                                                     now: dayInterval.end,
                                                     observationStart: dayInterval.start)
        #expect(segments.count == 1)
        #expect(segments.first?.isUnlogged == true)
        #expect(segments.first?.hours == 24)
    }

    @Test("Observation start preserves an existing archive and round-trips through preferences")
    func observationStartPreservesExistingHistory() {
        let defaults = UserDefaults(suiteName: "LifeLogTests.RecordingObservation")!
        defaults.removePersistentDomain(forName: "LifeLogTests.RecordingObservation")
        let historyStart = start.addingTimeInterval(-86_400)
        #expect(RecordingObservation.ensureStarted(now: start,
                                                   existingHistoryStart: historyStart,
                                                   defaults: defaults) == historyStart)
        #expect(RecordingObservation.startedAt(defaults: defaults) == historyStart)
        RecordingObservation.setStartedAt(start, defaults: defaults)
        #expect(RecordingObservation.startedAt(defaults: defaults) == start)
        defaults.removePersistentDomain(forName: "LifeLogTests.RecordingObservation")
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
        let home = InsightSegment(id: .visit(ObjectIdentifier(NSObject())), visit: nil, commute: nil, category: "Home",
                                  activity: "At home", placeName: "Home", start: start, end: start.addingTimeInterval(3_600),
                                  hours: 1, color: .blue, symbol: "house.fill", isUnlogged: false, isLive: false)
        let work = InsightSegment(id: .unlogged(0), visit: nil, commute: nil, category: "Work",
                                  activity: "Working", placeName: "Office", start: start, end: start.addingTimeInterval(7_200),
                                  hours: 2, color: .blue, symbol: "briefcase.fill", isUnlogged: false, isLive: false)
        let totals = InsightsSnapshot.categoryHours(in: [home, work])
        #expect(totals["Home"] == 1)
        #expect(totals["Work"] == 2)
    }

    @Test("WeekRoutineChange excludes Sleep/Unlogged/Uncategorised and returns the top 3 by magnitude")
    func weekRoutineChangeExcludesAndLimits() {
        // Work swings 50%, Groceries swings 40%, Exercising swings 25% -- all
        // past the noticeable threshold. Sleep swings 60% but is excluded (it
        // already has its own scorecard row), and Reading barely moves.
        let baselineHours: [String: Double] = [
            "Work": 10, "Groceries": 5, "Exercising": 4, "Sleep": 50, "Reading": 3
        ]
        let baseline: [WeeklyTotals] = (0..<3).map { index in
            WeeklyTotals(weekStart: calendar.date(byAdding: .weekOfYear, value: index, to: start)!, hours: baselineHours)
        }
        let currentWeekStart = calendar.date(byAdding: .weekOfYear, value: 3, to: start)!
        let currentSegments: [InsightSegment] = [
            makeSegment(category: "Work", hours: 15),
            makeSegment(category: "Groceries", hours: 7),
            makeSegment(category: "Exercising", hours: 5),
            makeSegment(category: "Sleep", hours: 20),
            makeSegment(category: "Reading", hours: 3.1)
        ]

        // Six of seven days elapsed -- past `minimumElapsedDaysToCompare`, so
        // the comparison actually runs.
        let now = calendar.date(byAdding: .day, value: 6, to: currentWeekStart)!
        let changes = WeekRoutineChange.changes(currentWeekStart: currentWeekStart, currentSegments: currentSegments,
                                                baselineTotals: baseline, now: now, calendar: calendar)

        #expect(!changes.contains { $0.category == "Sleep" }, "Sleep already has its own scorecard row")
        #expect(!changes.contains { $0.category == "Reading" }, "a change under the noticeable threshold is excluded")
        #expect(changes.count == 3, "capped at the 3 largest changes")
        #expect(changes.map(\.category) == ["Work", "Groceries", "Exercising"],
                "sorted by the largest absolute change first")
    }

    @Test("WeekRoutineChange returns nothing with no baseline history, or only one combined week")
    func weekRoutineChangeNeedsRealHistory() {
        let currentSegments: [InsightSegment] = [makeSegment(category: "Work", hours: 20)]
        #expect(WeekRoutineChange.changes(currentWeekStart: start, currentSegments: currentSegments, baselineTotals: [], now: start).isEmpty,
                "no baseline at all means nothing to compare against")
    }

    /// The bug this guards against: `InsightsTrends.series` documents its own
    /// `latest` as always a *complete* week, but `WeekRoutineChange.changes`
    /// is the one caller that hands it a partial one — so a real two-day
    /// swing, hours short of a full week's worth, used to report as "less
    /// Work than usual" every Monday and Tuesday regardless of what actually
    /// happened that week.
    @Test("A partial week reports nothing yet, even with hours far below the baseline")
    func partialWeekReportsNothingBeforeMostOfItHasElapsed() {
        let baselineHours: [String: Double] = ["Work": 40]
        let baseline: [WeeklyTotals] = (0..<4).map { index in
            WeeklyTotals(weekStart: calendar.date(byAdding: .weekOfYear, value: index, to: start)!, hours: baselineHours)
        }
        let currentWeekStart = calendar.date(byAdding: .weekOfYear, value: 4, to: start)!
        // Two elapsed days, 8h logged against a 40h/week baseline -- an 80%
        // "drop" if compared naively, but only because a fifth of the week
        // has happened so far.
        let currentSegments: [InsightSegment] = [makeSegment(category: "Work", hours: 8)]

        let tuesday = calendar.date(byAdding: .day, value: 2, to: currentWeekStart)!
        #expect(WeekRoutineChange.changes(currentWeekStart: currentWeekStart, currentSegments: currentSegments,
                                          baselineTotals: baseline, now: tuesday, calendar: calendar).isEmpty,
                "two elapsed days is not enough of the week to compare honestly")

        let saturday = calendar.date(byAdding: .day, value: 5, to: currentWeekStart)!
        let changes = WeekRoutineChange.changes(currentWeekStart: currentWeekStart, currentSegments: currentSegments,
                                                baselineTotals: baseline, now: saturday, calendar: calendar)
        #expect(changes.contains { $0.category == "Work" },
                "once most of the week has elapsed, a real gap is reported")
    }

    private func makeSegment(category: String, hours: Double) -> InsightSegment {
        InsightSegment(id: .unlogged(Int.random(in: 0..<Int.max)), visit: nil, commute: nil, category: category,
                       activity: category, placeName: "Test", start: start, end: start.addingTimeInterval(hours * 3_600),
                       hours: hours, color: .blue, symbol: "circle.fill", isUnlogged: false, isLive: false)
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
