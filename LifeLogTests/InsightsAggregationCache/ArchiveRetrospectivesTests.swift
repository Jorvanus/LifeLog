import Foundation
import Testing
@testable import LifeLog

struct ArchiveRetrospectivesTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let place = PlaceTotal(name: "Cinema", category: "Entertainment", activity: "Watching a movie",
                                   latitude: -23.37, longitude: 150.51, hours: 2)

    private func visit(daysAgo: Double, durationHours: Double = 1) -> PlaceVisitOccurrence {
        let arrival = start.addingTimeInterval(-daysAgo * 86_400)
        return PlaceVisitOccurrence(arrival: arrival, departure: arrival.addingTimeInterval(durationHours * 3600))
    }

    @Test("A place with an earlier visit outside the window is not a first visit")
    func firstVisitRequiresNoEarlierRecord() {
        let history = [visit(daysAgo: 40), visit(daysAgo: 0)]
        #expect(ArchiveRetrospectives.firstVisitToPlace(
            place, history: history, windowStart: start.addingTimeInterval(-7 * 86_400), window: .week
        ) == nil)
    }

    @Test("A place with no earlier record at all is a genuine first visit")
    func firstVisitWithNoHistory() {
        let history = [visit(daysAgo: 0)]
        let highlight = ArchiveRetrospectives.firstVisitToPlace(
            place, history: history, windowStart: start.addingTimeInterval(-7 * 86_400), window: .week
        )
        #expect(highlight?.isCelebration == true)
        #expect(highlight?.headline == "First time at Cinema")
    }

    @Test("A place seen only a couple of times has no gap worth naming")
    func longestAbsenceNeedsAPattern() {
        let history = [visit(daysAgo: 200), visit(daysAgo: 0)]
        #expect(ArchiveRetrospectives.longestAbsenceFromPlace(
            place, history: history, windowStart: start.addingTimeInterval(-7 * 86_400)
        ) == nil)
    }

    @Test("A short gap between otherwise-frequent visits is not notable")
    func longestAbsenceIgnoresOrdinaryGaps() {
        // Four visits, evenly spaced a week apart -- an ordinary pattern, no record.
        let history = [visit(daysAgo: 21), visit(daysAgo: 14), visit(daysAgo: 7), visit(daysAgo: 0)]
        #expect(ArchiveRetrospectives.longestAbsenceFromPlace(
            place, history: history, windowStart: start.addingTimeInterval(-7 * 86_400)
        ) == nil)
    }

    @Test("A record gap that ends inside the window is reported")
    func longestAbsenceReportsARealRecord() {
        // Three close visits establish the pattern, then a six-month gap before
        // the visit that falls inside the window being looked at.
        let history = [visit(daysAgo: 220), visit(daysAgo: 213), visit(daysAgo: 206), visit(daysAgo: 0)]
        let highlight = ArchiveRetrospectives.longestAbsenceFromPlace(
            place, history: history, windowStart: start.addingTimeInterval(-7 * 86_400)
        )
        #expect(highlight?.headline == "Longest gap yet at Cinema")
        // 206 days between arrivals, less the hour the earlier visit itself lasted --
        // the gap is measured from when the place was left, not when it was reached.
        #expect(highlight?.detail.contains("205") == true)
    }

    @Test("A record gap that ended before this window is not re-reported")
    func longestAbsenceOnlyFiresOnceForTheWindowThatEarnedIt() {
        let history = [visit(daysAgo: 220), visit(daysAgo: 213), visit(daysAgo: 206), visit(daysAgo: 0)]
        // Looking at a window that starts after the record-setting visit already
        // happened -- the record is old news by now, not this window's story.
        #expect(ArchiveRetrospectives.longestAbsenceFromPlace(
            place, history: history, windowStart: start.addingTimeInterval(3 * 86_400)
        ) == nil)
    }

    @Test("No data a year ago leaves the comparison silent")
    func yearOverYearNeedsAYearAgoBaseline() {
        #expect(ArchiveRetrospectives.yearOverYear(loggedHours: 40, yearAgoHours: 0, window: .week) == nil)
    }

    @Test("A change too small to matter is not reported")
    func yearOverYearIgnoresTinyChanges() {
        #expect(ArchiveRetrospectives.yearOverYear(loggedHours: 40, yearAgoHours: 40.5, window: .week) == nil)
    }

    @Test("More logged than a year ago says so, in both directions")
    func yearOverYearReportsTheDirection() {
        let more = ArchiveRetrospectives.yearOverYear(loggedHours: 60, yearAgoHours: 40, window: .month)
        #expect(more?.headline.contains("more") == true)
        let less = ArchiveRetrospectives.yearOverYear(loggedHours: 20, yearAgoHours: 40, window: .month)
        #expect(less?.headline.contains("less") == true)
    }
}
