import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// Table-driven coverage for `InsightsPeriodComparison`, the one shared
/// policy `InsightsSnapshot.make`, `InsightsHealthState.reloadHealthSummary`,
/// and `InsightsArchiveRetrospectives.yearOverYearHighlight` all now build
/// their current/previous pair from — across the six edge cases named in
/// TODO.md's "one period-comparison policy" item: DST, an open multi-day
/// stay, overlapping visits, ignored/superseded rows, a changed Home radius,
/// and sparse Health samples.
@MainActor
struct InsightsPeriodComparisonTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - The policy itself

    @Test("clamped(_:now:) only shortens a period now actually falls inside")
    func clampedOnlyAffectsAnInProgressPeriod() {
        let inProgress = DateInterval(start: base, duration: 3_600)
        let now = base.addingTimeInterval(1_800)
        #expect(InsightsPeriodComparison.clamped(inProgress, now: now).end == now)

        let alreadyOver = DateInterval(start: base, duration: 3_600)
        let later = base.addingTimeInterval(7_200)
        #expect(InsightsPeriodComparison.clamped(alreadyOver, now: later) == alreadyOver)
    }

    @Test("comparisonIntervals pairs a partial current period with an equally partial previous one",
         arguments: [InsightWindow.day, .week, .month, .year])
    func comparisonIntervalsStayEquallyPartial(window: InsightWindow) {
        // A period genuinely in progress: anchor at its own start, "now" a
        // short way in -- the exact shape that used to compare a sliver of
        // the current period against a complete previous one.
        let anchor = window.interval(containing: base, calendar: calendar).start
        let now = calendar.date(byAdding: .hour, value: 6, to: anchor) ?? anchor
        let (current, previous) = InsightsPeriodComparison.comparisonIntervals(
            for: window, anchorDate: anchor, now: now, calendar: calendar)

        #expect(current.end == now, "the current period is clamped to now")
        #expect(previous.duration == current.duration,
               "the previous period covers exactly the same elapsed span as the current one")
        #expect(previous.end <= current.start, "the previous period never overlaps the current one")
    }

    @Test("isMeaningfulHoursChange needs both an absolute floor and a fraction")
    func isMeaningfulHoursChangeNeedsBothFloorAndFraction() {
        // 50% of a tiny total: passes the fraction, fails the floor.
        #expect(InsightsPeriodComparison.isMeaningfulHoursChange(current: 1.4, previous: 1.0) == false)
        // A large absolute change that's still a small fraction of a huge total.
        #expect(InsightsPeriodComparison.isMeaningfulHoursChange(current: 101, previous: 100) == false)
        // Both satisfied.
        #expect(InsightsPeriodComparison.isMeaningfulHoursChange(current: 6, previous: 4) == true)
        // No previous total to compare against at all.
        #expect(InsightsPeriodComparison.isMeaningfulHoursChange(current: 6, previous: 0) == false)
    }

    // MARK: - DST

    /// A US Eastern calendar so the transition is deterministic regardless of
    /// where the test actually runs -- `InsightWindow`'s own `Calendar.current`
    /// default would silently pass or silently miss the case depending on the
    /// machine's timezone otherwise.
    private var dstCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    @Test("A week straddling a DST transition still produces a coherent, non-overlapping comparison")
    func dstTransitionWeekStaysCoherent() {
        // 2026-03-08 is the US spring-forward Sunday; this week contains it.
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 10
        let anchor = dstCalendar.date(from: components)!
        let now = dstCalendar.date(byAdding: .day, value: 2, to: anchor)!
        let (current, previous) = InsightsPeriodComparison.comparisonIntervals(
            for: .week, anchorDate: anchor, now: now, calendar: dstCalendar)

        #expect(current.duration > 0)
        #expect(previous.duration > 0)
        #expect(previous.end <= current.start)
        // The two elapsed-day spans can differ by the DST hour -- real, not a
        // bug -- but never by more than that one hour.
        #expect(abs(current.duration - previous.duration) <= 3_600 + 1)
    }

    @Test("yearAgo across a leap year still returns an ordered, positive-duration interval")
    func yearAgoAcrossALeapYearStaysOrdered() throws {
        // 2028-02-29 exists; 2027 has no such day, so `date(byAdding:)` has to
        // fall back to the nearest valid one rather than producing nonsense.
        var components = DateComponents()
        components.year = 2028; components.month = 2; components.day = 29
        let current = DateInterval(start: dstCalendar.date(from: components)!, duration: 86_400)
        let yearAgo = try #require(InsightsPeriodComparison.yearAgo(current, calendar: dstCalendar))
        #expect(yearAgo.start < current.start)
        #expect(yearAgo.duration >= 0)
    }

    // MARK: - InsightsSnapshot.make across the remaining edge cases

    private func snapshot(visits: [Visit], window: InsightWindow = .day,
                          home: InsightsSnapshot.HomePlace? = nil,
                          savedPlaces: [SavedPlace] = [], now: Date? = nil) -> InsightsSnapshot {
        InsightsSnapshot.make(visits: visits, window: window, anchorDate: base,
                              now: now ?? base.addingTimeInterval(6 * 3_600),
                              home: home, savedPlaces: savedPlaces)
    }

    @Test("An open multi-day stay is clamped to now, in both the current and previous periods")
    func openMultiDayStayIsClampedNotProjected() {
        // Arrived two days before the window and never departed.
        let open = Visit(arrival: base.addingTimeInterval(-2 * 86_400), departure: nil,
                         latitude: -23.378, longitude: 150.511, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", recognitionConfidence: "learned")
        let now = base.addingTimeInterval(6 * 3_600)
        let result = snapshot(visits: [open], window: .day, now: now)
        #expect(result.loggedHours <= result.analysisInterval.duration / 3_600 + 0.01,
               "an open stay can never log more hours than the period actually spans")
        #expect(result.previousSegments.allSatisfy { $0.end <= result.analysisInterval.start },
               "no previous-period segment reaches into the current period")
    }

    @Test("Two overlapping visits never let logged hours exceed the period's own span")
    func overlappingVisitsDoNotDoubleCount() {
        let dayInterval = InsightWindow.day.interval(containing: base)
        let first = Visit(arrival: dayInterval.start, departure: dayInterval.start.addingTimeInterval(4 * 3_600),
                          latitude: -23.378, longitude: 150.511, placeName: "Office",
                          inferredActivity: "Working", source: "automatic", recognitionConfidence: "learned")
        // Overlaps the first visit by two hours.
        let second = Visit(arrival: dayInterval.start.addingTimeInterval(2 * 3_600),
                           departure: dayInterval.start.addingTimeInterval(5 * 3_600),
                           latitude: -23.40, longitude: 150.49, placeName: "Cafe",
                           inferredActivity: "Eating", source: "automatic", recognitionConfidence: "learned")
        let result = snapshot(visits: [first, second], window: .day, now: dayInterval.start.addingTimeInterval(6 * 3_600))
        #expect(result.loggedHours <= 6.01, "the resolved slices cannot claim more than the six elapsed hours")
    }

    @Test("Ignored and superseded rows are excluded from both the current and previous period")
    func ignoredAndSupersededRowsAreExcludedFromBothPeriods() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, configurations: configuration)
        let context = ModelContext(container)
        let dayInterval = InsightWindow.day.interval(containing: base)
        let ignored = Visit(arrival: dayInterval.start, departure: dayInterval.start.addingTimeInterval(3_600),
                            latitude: -23.378, longitude: 150.511, placeName: "Somewhere",
                            inferredActivity: "Visiting", source: "automatic", recognitionConfidence: "learned")
        // `isIgnored`'s setter is a no-op before the visit is in a store --
        // nothing to hide from a timeline it isn't part of yet.
        context.insert(ignored)
        ignored.isIgnored = true
        let superseded = Visit(arrival: dayInterval.start.addingTimeInterval(3_600),
                               departure: dayInterval.start.addingTimeInterval(7_200),
                               latitude: -23.378, longitude: 150.511, placeName: "Somewhere",
                               inferredActivity: "Visiting", source: "automatic", recognitionConfidence: "learned")
        superseded.setResolutionState(.superseded, actor: .user)

        let currentResult = snapshot(visits: [ignored, superseded], window: .day,
                                     now: dayInterval.start.addingTimeInterval(6 * 3_600))
        #expect(currentResult.loggedHours == 0, "neither row contributes logged time to the current period")

        // Same two rows, now inside what becomes the *previous* period once the
        // window has moved on a day -- excluded there too, not merely uncounted
        // because they fell outside the query window.
        let previousWindowResult = InsightsSnapshot.make(
            visits: [ignored, superseded], window: .day,
            anchorDate: base.addingTimeInterval(86_400),
            now: base.addingTimeInterval(86_400 + 6 * 3_600)
        )
        #expect(previousWindowResult.previousSegments.allSatisfy { $0.visit !== ignored && $0.visit !== superseded })
    }

    @Test("The same visits produce different away-from-Home hours under a changed Home radius")
    func changedHomeRadiusChangesAwayFromHomeConsistently() {
        let dayInterval = InsightWindow.day.interval(containing: base)
        // 150 metres from the coordinate below -- inside a 200m radius, outside a 50m one.
        let visit = Visit(arrival: dayInterval.start, departure: dayInterval.start.addingTimeInterval(3_600),
                          latitude: -23.3793, longitude: 150.511, placeName: "Nearby",
                          inferredActivity: "Visiting", source: "automatic", recognitionConfidence: "learned")
        let now = dayInterval.start.addingTimeInterval(6 * 3_600)

        let narrowHome = InsightsSnapshot.HomePlace(latitude: -23.378, longitude: 150.511, radius: 50)
        let wideHome = InsightsSnapshot.HomePlace(latitude: -23.378, longitude: 150.511, radius: 200)
        let narrow = snapshot(visits: [visit], window: .day, home: narrowHome, now: now)
        let wide = snapshot(visits: [visit], window: .day, home: wideHome, now: now)

        #expect(narrow.awayFromHomeHours > wide.awayFromHomeHours,
               "the same visit counts as away from Home under the narrow radius and at Home under the wide one")
    }

    // MARK: - Sparse Health samples

    @Test("Sparse Health samples never claim a comparison against too little history")
    func sparseHealthSamplesDoNotClaimAComparison() {
        // Below `DayHighlights.minimumBaselineSamples` -- too little to call a habit.
        #expect(DayHighlights.steps(today: 9_000, weekdayBaseline: [8_000, 8_500], weekdayName: "Tuesday") == nil)
        // Present but with nothing to compare against.
        #expect(DayHighlights.sleep(lastNight: 0, averageNight: 7 * 3_600) == nil)
        #expect(DayHighlights.sleep(lastNight: 7 * 3_600, averageNight: 0) == nil)
        // A year-over-year comparison with no prior-year data at all.
        #expect(ArchiveRetrospectives.yearOverYear(loggedHours: 10, yearAgoHours: 0, window: .week) == nil)
    }
}
