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

    /// A stay wholly inside the day being read shows its own true duration -- this is
    /// the ordinary case, and clipping must be a no-op for it.
    @Test("A same-day stay's duration is unclipped")
    func durationWithinDayLeavesASameDayStayUntouched() {
        let day = Calendar.current.startOfDay(for: base)
        let arrival = day.addingTimeInterval(9 * 3600)
        let departure = day.addingTimeInterval(10 * 3600)

        let duration = durationWithinDay(arrival: arrival, departure: departure,
                                         day: TimelineView.interval(of: day))
        #expect(duration == 3600)
    }

    /// The real capture this exists for: a Home stay from yesterday 7:45am to this
    /// morning 7:07am read 23h 21m on Timeline's "today" row -- its whole span, not
    /// the roughly seven hours of it that actually fall on today. `visit.duration`
    /// stays the honest total for anything that reads the record directly; this is
    /// only what one row displays for the day it is shown on.
    @Test("A stay that crosses into the day from before it is clipped to the day's start")
    func durationWithinDayClipsAStayThatBeganTheDayBefore() {
        let day = Calendar.current.startOfDay(for: base)
        let arrival = day.addingTimeInterval(-16.25 * 3600) // yesterday 7:45am
        let departure = day.addingTimeInterval(7 * 3600 + 7 * 60) // today 7:07am

        let duration = durationWithinDay(arrival: arrival, departure: departure,
                                         day: TimelineView.interval(of: day))
        #expect(duration == 7 * 3600 + 7 * 60, "only the portion inside today")
        #expect(departure.timeIntervalSince(arrival) > duration,
                "the visit's own full duration is longer than what today's row shows")
    }

    /// The mirror case: a stay still open past midnight when the day being read has
    /// already ended. `day.end`, not `.now`, bounds it -- the same reason an unclosed
    /// stay on a past day is measured against the end of that day rather than the
    /// present, immediately above.
    @Test("A stay still open past the day's end is clipped to the day's end")
    func durationWithinDayClipsAStayStillOpenAtTheDaysEnd() {
        let day = Calendar.current.startOfDay(for: base)
        let interval = TimelineView.interval(of: day)
        let arrival = day.addingTimeInterval(20 * 3600)

        let duration = durationWithinDay(arrival: arrival, departure: nil, day: interval)
        #expect(duration == 4 * 3600)
    }
}
