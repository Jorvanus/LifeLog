import Foundation
import Testing
@testable import LifeLog

/// `InsightsSnapshot.sliceRows` is what closes the gap between the donut's
/// deduplicated header total and the rows `InsightSliceEditor` lists below it.
/// Every test here asserts the same invariant a different way: the rows for a
/// selected slice must sum to exactly that slice's category total, never more —
/// which raw `Visit.duration`/`Visit.duration(in:)` cannot guarantee once two
/// records overlap in time.
@MainActor
struct InsightSliceRowsTests {
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func stay(_ startHour: Double, _ endHour: Double, place: String, activity: String,
                      source: String = "automatic") -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: source, recognitionConfidence: "learned")
    }

    private func sleep(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: "Sleep", inferredActivity: "Sleeping", userActivity: "Sleeping",
              source: "health-sleep", recognitionConfidence: "device")
    }

    /// A placeless device fragment — the shape a motion-sourced travel record
    /// actually has, with no coordinate of its own.
    private func travel(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: 0, longitude: 0,
              placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling",
              source: "motion", recognitionConfidence: "device")
    }

    private func segments(for visits: [Visit], range: DateInterval, now: Date) -> [InsightSegment] {
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        return InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits, range: range, now: now)
    }

    /// Mirrors what `InsightsSnapshot`'s private `makeSlices` sums per category —
    /// the same donut/header total the rows must add up to.
    private func categoryTotal(_ category: String, in segments: [InsightSegment]) -> Double {
        segments.filter { $0.category == category && !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
    }

    @Test("Home overlapping Sleep: rows match the deduplicated Home and Sleep totals, not the raw 12h/7h")
    func homeOverlappingSleepRowsMatchSliceTotals() throws {
        let home = stay(0, 12, place: "Home", activity: "At home")
        let sleepVisit = sleep(0, 7)
        let range = DateInterval(start: day, end: day.addingTimeInterval(12 * 3600))
        let now = range.end
        let segs = segments(for: [home, sleepVisit], range: range, now: now)

        let homeTotal = categoryTotal("Home", in: segs)
        let homeRows = InsightsSnapshot.sliceRows(forCategory: "Home", segments: segs, interval: range, now: now)
        #expect(homeTotal == 5, "sleep, the shorter completed record, wins the overlapping 7h")
        #expect(homeRows.reduce(0) { $0 + $1.hours } == homeTotal)
        let homeRow = try #require(homeRows.first)
        #expect(homeRows.count == 1)
        #expect(homeRow.hours == 5)
        #expect(homeRow.isPartial, "Home's own 12h span exceeds the 5h it actually won")

        let sleepTotal = categoryTotal("Sleep", in: segs)
        let sleepRows = InsightsSnapshot.sliceRows(forCategory: "Sleep", segments: segs, interval: range, now: now)
        #expect(sleepTotal == 7)
        #expect(sleepRows.reduce(0) { $0 + $1.hours } == sleepTotal)
        #expect(sleepRows.first?.isPartial == false, "sleep won every hour it was ever recorded for")
    }

    @Test("Multiple overlapping automatic callbacks in one category split without double-counting")
    func overlappingLocationCallbacksSplitWithoutDoubleCounting() throws {
        // Two automatic arrivals for the same kind of stay, imperfectly
        // deduplicated, overlapping in the middle of the window.
        let first = stay(0, 10, place: "Home", activity: "At home")
        let second = stay(5, 8, place: "Home Entrance", activity: "At home")
        let range = DateInterval(start: day, end: day.addingTimeInterval(10 * 3600))
        let now = range.end
        let segs = segments(for: [first, second], range: range, now: now)

        let total = categoryTotal("Home", in: segs)
        let rows = InsightsSnapshot.sliceRows(forCategory: "Home", segments: segs, interval: range, now: now)
        #expect(total == 10, "the window is fully covered by one record or the other, never both at once")
        #expect(rows.reduce(0) { $0 + $1.hours } == total)
        #expect(rows.count == 2, "both records contributed real time and each keeps its own row")

        let byPlace = Dictionary(uniqueKeysWithValues: rows.map { ($0.placeName, $0.hours) })
        // `second` is the shorter completed record, so it wins the 5–8 overlap;
        // `first` keeps the two slivers either side of it (0–5 and 8–10), summed
        // into one row rather than shown as two disconnected entries.
        #expect(byPlace["Home"] == 7)
        #expect(byPlace["Home Entrance"] == 3)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.placeName, $0) })
        #expect(byName["Home"]?.isPartial == true, "first's own 10h span exceeds the 7h it actually won")
        #expect(byName["Home Entrance"]?.isPartial == false, "second won every hour of its own recorded span")
    }

    @Test("A selected travel segment's rows still sum to its category total")
    func travelSegmentRowsMatchSliceTotal() throws {
        // Two overlapping motion-sourced travel fragments, the placeless shape
        // a duplicate or re-detected drive actually has. Anchored by a departure
        // before and an arrival after: a movement record with nothing real either
        // side of it is not shown at all (`isBetweenDestinations`), which is a
        // deliberately separate concern from what this test is proving.
        let before = stay(-2, 0, place: "Home", activity: "At home")
        let first = travel(0, 3)
        let second = travel(1, 4)
        let after = stay(4, 6, place: "Office", activity: "Working")
        let range = DateInterval(start: day, end: day.addingTimeInterval(4 * 3600))
        let now = range.end
        let segs = segments(for: [before, first, second, after], range: range, now: now)

        let total = categoryTotal("Travel", in: segs)
        let rows = InsightsSnapshot.sliceRows(forCategory: "Travel", segments: segs, interval: range, now: now)
        #expect(total == 4)
        #expect(rows.reduce(0) { $0 + $1.hours } == total)
        #expect(rows.count == 2)
        // `second` arrived later, so it wins every slice the two dispute; `first`
        // keeps only the 0–1 sliver before `second` starts. Only `first` lost time
        // it would otherwise have shown as its own.
        let hours = rows.map(\.hours).sorted()
        #expect(hours == [1, 3])
        #expect(rows.first { $0.hours == 1 }?.isPartial == true)
        #expect(rows.first { $0.hours == 3 }?.isPartial == false)
    }

    /// `makePlaceTotals` now sums the same post-resolution segments `sliceRows`
    /// does, rather than raw visit durations, so the two entry points into
    /// `InsightSliceEditor` (a category slice and a place total) stay consistent
    /// with each other on the same overlapping data.
    @Test("A place visited by two overlapping records is not double-counted in its total")
    func overlappingVisitsAtOnePlaceDoNotDoubleCountTheTotal() throws {
        let first = stay(0, 10, place: "Corner Cafe", activity: "Visiting")
        let second = stay(5, 8, place: "Corner Cafe", activity: "Visiting")
        let now = day.addingTimeInterval(10 * 3600)
        let snapshot = InsightsSnapshot.make(visits: [first, second], window: .day, anchorDate: day, now: now)

        let place = try #require(snapshot.placeTotals.first { $0.name == "Corner Cafe" })
        #expect(place.hours == 10, "the window is fully covered once, never twice over")
        let rows = InsightsSnapshot.sliceRows(forPlace: "Corner Cafe", segments: snapshot.segments,
                                              interval: snapshot.analysisInterval, now: now)
        #expect(rows.reduce(0) { $0 + $1.hours } == place.hours)
    }
}
