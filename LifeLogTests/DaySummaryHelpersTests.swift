import Foundation
import Testing
@testable import LifeLog

/// The small aggregates Insights' Day summary and "Needs your attention"
/// sections read — all built from the same post-resolution `InsightSegment`s
/// the donut and header total use, never a second pass over raw visits.
@MainActor
struct DaySummaryHelpersTests {
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func stay(_ startHour: Double, _ endHour: Double, place: String, activity: String) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: "automatic", recognitionConfidence: "learned")
    }

    private func travel(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: 0, longitude: 0,
              placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling",
              source: "motion", recognitionConfidence: "device")
    }

    private func walk(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: 0, longitude: 0,
              placeName: "Walking", inferredActivity: "Walking", userActivity: "Walking",
              source: "health-walking", recognitionConfidence: "device")
    }

    private func segments(for visits: [Visit], range: DateInterval, now: Date) -> [InsightSegment] {
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        return InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits, range: range, now: now)
    }

    @Test("Travel time sums Travel-category segments")
    func travelHoursSumsTravelCategory() {
        // A movement record with nothing real either side of it is not shown at
        // all (`ActivityLocationPolicy.isBetweenDestinations`) — anchoring stays
        // before and after are what make this a believed journey.
        let before = stay(-1, 0, place: "Home", activity: "At home")
        let drive = travel(0, 1)
        let after = stay(1, 2, place: "Office", activity: "Working")
        let range = DateInterval(start: day, end: day.addingTimeInterval(1 * 3600))
        let segs = segments(for: [before, drive, after], range: range, now: range.end)
        #expect(InsightsSnapshot.travelHours(in: segs) == 1)
    }

    @Test("Travel time also counts synthesised commute segments")
    func travelHoursIncludesCommuteSegments() {
        let commute = Commute(start: day, end: day.addingTimeInterval(1_800), direction: .toWork)
        let segment = InsightSegment.commute(commute, from: commute.start, to: commute.end)
        #expect(InsightsSnapshot.travelHours(in: [segment]) == 0.5)
    }

    @Test("Fitness time sums workout-category segments")
    func fitnessHoursSumsFitnessCategory() {
        let before = stay(-1, 0, place: "Home", activity: "At home")
        let walking = walk(0, 0.5)
        let after = stay(0.5, 1.5, place: "Office", activity: "Working")
        let range = DateInterval(start: day, end: day.addingTimeInterval(1 * 3600))
        let segs = segments(for: [before, walking, after], range: range, now: range.end)
        #expect(InsightsSnapshot.fitnessHours(in: segs) == 0.5)
    }

    @Test("Fitness and travel totals don't pick up unrelated categories")
    func categoryHelpersIgnoreOtherCategories() {
        let home = stay(0, 1, place: "Home", activity: "At home")
        let range = DateInterval(start: day, end: day.addingTimeInterval(1 * 3600))
        let segs = segments(for: [home], range: range, now: range.end)
        #expect(InsightsSnapshot.travelHours(in: segs) == 0)
        #expect(InsightsSnapshot.fitnessHours(in: segs) == 0)
    }

    @Test("Only past gaps at or above the threshold are meaningful")
    func meaningfulGapsExcludesShortAndFutureGaps() throws {
        // Home 0–2h, a 2h unlogged gap, Shop 4–5.8h, a 12-minute gap too short
        // to matter, then "now" at 6h with two more hours of the day still
        // ahead -- unlogged, but not yet happened, so not a gap to flag.
        let home = stay(0, 2, place: "Home", activity: "At home")
        let shop = stay(4, 5.8, place: "Shop", activity: "Shopping")
        let range = DateInterval(start: day, end: day.addingTimeInterval(8 * 3600))
        let now = day.addingTimeInterval(6 * 3600)
        let segs = segments(for: [home, shop], range: range, now: now)

        let gaps = InsightsSnapshot.meaningfulGaps(in: segs, before: now)
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(gap.hours == 2)
        #expect(gap.start == day.addingTimeInterval(2 * 3600))
    }
}
