import Foundation
import CoreLocation
import Testing
@testable import LifeLog

/// Presentation policy for what the Timeline screen shows and when: which
/// day is selected across a background/foreground cycle, and — for a given
/// day — which of several overlapping or archived visits get drawn as rows.
@MainActor
struct DayRolloverAndVisitPresentationTests {
    private let base = TimelineFixtureBuilders.referenceDate()

    @Test("Foregrounding after a background midnight re-pins today's selected day forward")
    func foregroundRefreshAdvancesSelectedDayAcrossMidnight() {
        let yesterday = Calendar.current.startOfDay(for: base)
        // The minute clock is stale from a suspended background task; the phone's
        // real clock has already crossed into the next day by the time foreground
        // refresh runs.
        let refreshedClock = Calendar.current.date(byAdding: .day, value: 1, to: base)!

        let advanced = TimelineView.selectedDayAfterForeground(
            current: yesterday, wasShowingToday: true, refreshedClock: refreshedClock)
        #expect(Calendar.current.isDate(advanced, inSameDayAs: refreshedClock))
    }

    @Test("Foregrounding never yanks a deliberately chosen past day back to today")
    func foregroundRefreshLeavesADeliberatePastDayAlone() {
        let aWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: base)!
        let refreshedClock = base.addingTimeInterval(60)

        let unchanged = TimelineView.selectedDayAfterForeground(
            current: aWeekAgo, wasShowingToday: false, refreshedClock: refreshedClock)
        #expect(Calendar.current.isDate(unchanged, inSameDayAs: aWeekAgo))
    }

    @Test("Overlapping destinations never expose movement inside an occupied interval")
    func overlappingVisitsAreLocationFirst() {
        let destinations = (0..<80).map { index in
            Visit(
                arrival: base.addingTimeInterval(Double(index) * 3_600),
                departure: base.addingTimeInterval(Double(index) * 3_600 + 2_400),
                latitude: -27.47 + Double(index) * 0.0001,
                longitude: 153.03,
                placeName: "Destination \(index)",
                inferredActivity: "Visiting",
                source: "automatic"
            )
        }
        let movement = Visit(
            arrival: base.addingTimeInterval(10 * 3_600 + 1_200),
            departure: base.addingTimeInterval(10 * 3_600 + 3_000),
            latitude: 0, longitude: 0, placeName: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking", source: "health-walking"
        )

        #expect(ActivityLocationPolicy.shouldShow(movement, locationVisits: destinations) == false)
    }

    /// Timeline showed only today, so nine years of journal were unreadable. The
    /// screen's own query excludes `imported-journal` to keep launch light, which is
    /// exactly what a past day is made of — so a past day is filtered by this, from its
    /// own fetch, and it has to keep what the live screen would have thrown away.
    @Test("A past day keeps the archive that today's query leaves out")
    func pastDayIncludesImportedJournal() {
        let day = Calendar.current.startOfDay(for: base)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let interval = DateInterval(start: day, end: dayEnd)

        let archived = Visit(arrival: day.addingTimeInterval(9 * 3600),
                             departure: day.addingTimeInterval(17 * 3600),
                             latitude: -23.38, longitude: 150.52, placeName: "atWork Australia",
                             inferredActivity: "Work", source: "imported-journal")
        // Began the evening before: a stay counts for every day it covers, so the day
        // must open with the stay it woke up in rather than the first time out.
        let overnight = Visit(arrival: day.addingTimeInterval(-6 * 3600),
                              departure: day.addingTimeInterval(8 * 3600),
                              latitude: -23.44, longitude: 150.45, placeName: "Home",
                              inferredActivity: "At home", source: "automatic")
        let anotherDay = Visit(arrival: dayEnd.addingTimeInterval(3600),
                               departure: dayEnd.addingTimeInterval(2 * 3600),
                               latitude: -23.44, longitude: 150.45, placeName: "Home",
                               inferredActivity: "At home", source: "automatic")

        let rows = TimelineView.rows(from: [archived, overnight, anotherDay],
                                     day: interval, now: dayEnd)

        #expect(rows.contains { $0 === archived }, "the archive is what a past day is made of")
        #expect(rows.contains { $0 === overnight }, "a day covers the stay it began in")
        #expect(!rows.contains { $0 === anotherDay })
    }

    /// A day that is over is measured against its own end. Against the present, a stay
    /// Core Location never closed in 2019 would be reported as still running, years long.
    @Test("An unclosed stay on a past day ends with the day, not with now")
    func pastDayMeasuresAgainstTheEndOfThatDay() {
        let day = Calendar.current.startOfDay(for: base)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let open = Visit(arrival: day.addingTimeInterval(20 * 3600), departure: nil,
                         latitude: -23.44, longitude: 150.45, placeName: "Home",
                         inferredActivity: "At home", source: "automatic")

        let rows = TimelineView.rows(from: [open], day: DateInterval(start: day, end: dayEnd),
                                     now: dayEnd)

        #expect(rows.contains { $0 === open })
        // Bounded by the day it is being read on rather than left running to the present.
        #expect(TimelineView.interval(of: day).end == dayEnd)
    }
}
