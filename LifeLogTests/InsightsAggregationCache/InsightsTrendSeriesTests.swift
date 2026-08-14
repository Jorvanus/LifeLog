import Foundation
import Testing
@testable import LifeLog

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
        #expect(message.contains("2d 12h"))
        #expect(message.contains("1d 16h"))
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

    /// The exact gap the twelve-week window left: a return the archive actually
    /// recorded, reported as a first-ever occurrence because nothing further back
    /// than a season was ever read. `habitWeeks` exists so `habits` can tell these
    /// apart; this proves it does, not just that the constant is bigger.
    @Test("habitWeeks lets a real return be recognised where the twelve-week window would have missed it")
    func widerWindowFindsAReturnANarrowerWindowMisses() {
        let span = InsightsTrends.range(endingAt: now, calendar: calendar)
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: span.end)!
        let twentyWeeksBack = calendar.date(byAdding: .weekOfYear, value: -20, to: span.end)!
        let recentVisit = Visit(
            arrival: lastWeek.addingTimeInterval(3600), departure: lastWeek.addingTimeInterval(4 * 3600),
            latitude: -23.378, longitude: 150.511, placeName: "Cinema",
            inferredActivity: "Watching a movie", userActivity: "Watching a movie",
            source: "automatic", recognitionConfidence: "confirmed"
        )
        let oldVisit = Visit(
            arrival: twentyWeeksBack.addingTimeInterval(3600), departure: twentyWeeksBack.addingTimeInterval(4 * 3600),
            latitude: -23.378, longitude: 150.511, placeName: "Cinema",
            inferredActivity: "Watching a movie", userActivity: "Watching a movie",
            source: "automatic", recognitionConfidence: "confirmed"
        )
        let visits = [oldVisit, recentVisit]

        let narrowWeeks = InsightsTrends.weeklyTotals(visits: visits, now: now,
                                                       weeks: InsightsTrends.weeks, calendar: calendar)
        let narrowHabits = InsightsTrends.habits(from: narrowWeeks, calendar: calendar)
        #expect(narrowHabits.first?.headline == "First entertainment in \(InsightsTrends.weeks) weeks",
                "with only a season in hand, the return 20 weeks back is invisible")

        let wideWeeks = InsightsTrends.weeklyTotals(visits: visits, now: now,
                                                     weeks: InsightsTrends.habitWeeks, calendar: calendar)
        let wideHabits = InsightsTrends.habits(from: wideWeeks, calendar: calendar)
        #expect(wideHabits.first?.headline == "Back to entertainment")
        #expect(wideHabits.first?.detail.contains("weeks away") == true)
    }
}
