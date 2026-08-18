import Foundation
import Testing
@testable import LifeLog

/// `InsightsRoutineStability.make` is pure over already-resolved `InsightSegment`s,
/// `Visit`s, and `Commute`s -- the same production path `InsightsTrendAggregator`
/// feeds it. These tests build segments through `InsightsSnapshot.segments` (the
/// same call `InsightsTrendAggregator.load` makes) and commutes through
/// `CommuteDetection.commutes`, so a passing test proves the card agrees with what
/// the donut/Timeline and Week's own commute summary would show for the same data.
@MainActor
struct InsightsRoutineStabilityTests {
    private let day = insightsFixtureDay
    private let homeLatitude = -23.378, homeLongitude = 150.511
    private let workLatitude = -23.400, workLongitude = 150.490

    private func homeSavedPlace() -> SavedPlace {
        let place = SavedPlace(name: "Home", latitude: homeLatitude, longitude: homeLongitude)
        place.homeWorkRole = .home
        return place
    }

    private func workSavedPlace() -> SavedPlace {
        let place = SavedPlace(name: "Office", latitude: workLatitude, longitude: workLongitude)
        place.homeWorkRole = .work
        return place
    }

    private func visit(dayOffset: Int, startHour: Double, endHour: Double,
                       latitude: Double, longitude: Double, placeName: String, activity: String) -> Visit {
        let base = day.addingTimeInterval(Double(dayOffset) * 24 * 3_600)
        return Visit(arrival: base.addingTimeInterval(startHour * 3_600),
                     departure: base.addingTimeInterval(endHour * 3_600),
                     latitude: latitude, longitude: longitude,
                     placeName: placeName, inferredActivity: activity, userActivity: activity,
                     source: "automatic", recognitionConfidence: "confirmed")
    }

    /// Home overnight (18:00-08:00), a 30-minute gap (a real commute, not a
    /// zero-duration transition `CommuteDetection` would ignore), Work daytime
    /// (08:30-17:30), another 30-minute gap, repeating every day in `0..<days`.
    private func routineVisits(days: Int) -> [Visit] {
        (0..<days).flatMap { offset in
            [visit(dayOffset: offset, startHour: 18, endHour: 32, latitude: homeLatitude, longitude: homeLongitude,
                   placeName: "Home", activity: "At home"),
             visit(dayOffset: offset, startHour: 8.5, endHour: 17.5, latitude: workLatitude, longitude: workLongitude,
                   placeName: "Office", activity: "Work")]
        }
    }

    private func makeRoutine(visits: [Visit], savedPlaces: [SavedPlace], days: Int) -> InsightsRoutineStability.Presentation {
        let window = DateInterval(start: day, end: day.addingTimeInterval(Double(days) * 24 * 3_600))
        let commutes = CommuteDetection.commutes(in: visits, savedPlaces: savedPlaces, now: window.end)
        let segments = InsightsSnapshot.segments(visits: visits, range: window, now: window.end,
                                                 commutes: commutes, savedPlaces: savedPlaces)
        return InsightsRoutineStability.make(segments: segments, visits: visits, commutes: commutes,
                                             savedPlaces: savedPlaces, window: window, now: window.end)
    }

    @Test("Three full weeks of Home/Work/commute produces a conclusion for every weekday and a real commute stat")
    func fullSeasonProducesConclusions() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        let routine = makeRoutine(visits: routineVisits(days: 21), savedPlaces: savedPlaces, days: 21)
        #expect(routine.hasEnoughCoverage)
        #expect(routine.homeWeekdays.count == 7)
        #expect(routine.workWeekdays.count == 7)
        let anyHomeDay = routine.homeWeekdays[0]
        #expect(anyHomeDay.arrival?.sampleCount == 3)
        // Arrival at 18:00 every time, so the median is exact (within the
        // Date/TimeInterval round-trip's floating-point epsilon) and the spread zero.
        #expect(abs((anyHomeDay.arrival?.medianMinutes ?? -1) - 18 * 60) < 0.01)
        #expect((anyHomeDay.arrival?.spreadMinutes ?? -1) < 0.01)
        // 2 commutes/day * 21 days, minus one: the very first Work visit in the
        // whole fetched history has no preceding stay to commute from, so its
        // morning leg is correctly never counted -- the same rule
        // `CommuteDetection` documents for any origin-less first stay.
        #expect(routine.commute?.sampleCount == 41)
        #expect(routine.commute?.medianMinutes == 30)
    }

    @Test("Two weeks -- two occurrences per weekday -- is below the distinct-day bar, so no weekday routine is shown")
    func notEnoughDistinctDaysSuppressesWeekdayRoutine() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        let routine = makeRoutine(visits: routineVisits(days: 14), savedPlaces: savedPlaces, days: 14)
        #expect(routine.hasEnoughCoverage)
        #expect(routine.homeWeekdays.isEmpty)
        #expect(routine.workWeekdays.isEmpty)
        // The commute's own bar (2 distinct days) is still cleared even though the
        // weekday-specific bar (3) is not -- these are independent thresholds.
        #expect(routine.commute != nil)
    }

    @Test("Poor overall coverage suppresses every conclusion, not just the ones with too few days")
    func poorCoverageSuppressesEverything() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        // A month-long window with only three real days of Home/Work in it.
        let visits = routineVisits(days: 3)
        let routine = makeRoutine(visits: visits, savedPlaces: savedPlaces, days: 30)
        #expect(!routine.hasEnoughCoverage)
        #expect(routine.homeWeekdays.isEmpty)
        #expect(routine.workWeekdays.isEmpty)
        #expect(routine.commute == nil)
        #expect(routine.sleep == nil)
        #expect(!routine.hasAnyConclusion)
    }

    @Test("A commute needs at least two distinct days; one real day alone is a data point, not a pattern")
    func commuteRequiresTwoDistinctDays() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        // A single day of Home/Work, padded with plain Home stays so coverage
        // clears the bar without adding a second day of commuting.
        var visits = routineVisits(days: 1)
        for offset in 1..<10 {
            visits.append(visit(dayOffset: offset, startHour: 0, endHour: 24,
                                latitude: homeLatitude, longitude: homeLongitude, placeName: "Home", activity: "At home"))
        }
        let routine = makeRoutine(visits: visits, savedPlaces: savedPlaces, days: 10)
        #expect(routine.hasEnoughCoverage)
        #expect(routine.commute == nil)
    }

    @Test("Sleep timing that straddles midnight is treated as one cluster, not pulled toward noon")
    func sleepTimingCrossesMidnightWithoutSkewingTheMedian() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        var visits = routineVisits(days: 10)
        // Four nights, symmetric around midnight: 23:50, 23:55, 00:05, 00:10.
        let starts: [(offset: Int, hour: Double)] = [(0, 23.833), (1, 23.916), (2, 0.083), (3, 0.166)]
        for (offset, hour) in starts {
            visits.append(visit(dayOffset: offset, startHour: hour, endHour: hour + 7.5,
                                latitude: homeLatitude, longitude: homeLongitude, placeName: "Sleep", activity: "Sleeping"))
        }
        let routine = makeRoutine(visits: visits, savedPlaces: savedPlaces, days: 10)
        #expect(routine.hasEnoughCoverage)
        let sleep = routine.sleep
        #expect(sleep?.start.sampleCount == 4)
        // A naive (non-circular) median of {23:50, 23:55, 00:05, 00:10} would land
        // near noon; the real centre of this cluster is midnight.
        let medianMinutes = sleep?.start.medianMinutes ?? -1
        #expect(medianMinutes < 10 || medianMinutes > 1_430)
    }

    @Test("Fewer than three nights of sleep is not yet a pattern")
    func sleepRequiresThreeNights() {
        let savedPlaces = [homeSavedPlace(), workSavedPlace()]
        var visits = routineVisits(days: 10)
        for offset in 0..<2 {
            visits.append(visit(dayOffset: offset, startHour: 23, endHour: 30.5,
                                latitude: homeLatitude, longitude: homeLongitude, placeName: "Sleep", activity: "Sleeping"))
        }
        let routine = makeRoutine(visits: visits, savedPlaces: savedPlaces, days: 10)
        #expect(routine.hasEnoughCoverage)
        #expect(routine.sleep == nil)
    }
}
