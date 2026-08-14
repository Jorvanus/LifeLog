import Foundation
import Testing
@testable import LifeLog

/// "On this day" retrospective policy: which past years are offered, and
/// which place is reported for each — by time actually spent inside that
/// calendar day, not by activity label or by a stay's full duration.
@MainActor
struct OnThisDayRetrospectiveTests {
    private let base = TimelineFixtureBuilders.referenceDate()

    /// Places, not activity labels. Almost the whole archive came from a bulk import
    /// whose labels are whatever the old app defaulted to, so an activity read back
    /// from years ago is often not what happened — a recorded place name is.
    @Test("On this day reports where the day was spent, longest first")
    func onThisDaySummarisesPlacesByTimeSpent() {
        let day = Calendar.current.startOfDay(for: base)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let shops = Visit(arrival: day.addingTimeInterval(9 * 3600),
                          departure: day.addingTimeInterval(10 * 3600),
                          latitude: -23.44, longitude: 150.45, placeName: "Gracemere Shopping World",
                          inferredActivity: "Shopping", source: "imported-journal")
        let home = Visit(arrival: day.addingTimeInterval(11 * 3600),
                         departure: day.addingTimeInterval(20 * 3600),
                         latitude: -23.44, longitude: 150.45, placeName: "Home",
                         inferredActivity: "At home", source: "automatic")
        // Device activity carries "Walking" as its place name, which is not a place.
        let walk = Visit(arrival: day.addingTimeInterval(10 * 3600),
                         departure: day.addingTimeInterval(10.5 * 3600),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        let unnamed = Visit(arrival: day.addingTimeInterval(21 * 3600),
                            departure: day.addingTimeInterval(22 * 3600),
                            latitude: -23.44, longitude: 150.45,
                            placeName: Visit.unknownPlaceName,
                            inferredActivity: "Visiting", source: "automatic")

        let summary = OnThisDay.summarise([shops, home, walk, unnamed], on: day)

        #expect(summary?.year == Calendar.current.component(.year, from: day))
        #expect(summary?.places == ["Home", "Gracemere Shopping World"],
                "longest first, with device activity and placeholders left out")
        #expect(summary?.day == day)
        #expect(end > day)
    }

    /// A stay running from the evening before must not out-rank a place on hours it
    /// spent in a different day.
    @Test("Only the part of a stay inside the day counts towards it")
    func onThisDayCountsOnlyTheOverlap() {
        let day = Calendar.current.startOfDay(for: base)
        // Twelve hours long, but only two of them fall in this day.
        let overnight = Visit(arrival: day.addingTimeInterval(-10 * 3600),
                              departure: day.addingTimeInterval(2 * 3600),
                              latitude: -23.44, longitude: 150.45, placeName: "Home",
                              inferredActivity: "At home", source: "automatic")
        let work = Visit(arrival: day.addingTimeInterval(9 * 3600),
                         departure: day.addingTimeInterval(17 * 3600),
                         latitude: -23.38, longitude: 150.52, placeName: "Work",
                         inferredActivity: "Work", source: "imported-journal")

        let summary = OnThisDay.summarise([overnight, work], on: day)

        #expect(summary?.places.first == "Work", "eight hours in this day beats two")
    }

    @Test("Earlier days stop at the first record rather than offering empty years")
    func onThisDayStopsAtTheEarliestRecord() {
        let day = Calendar.current.startOfDay(for: base)
        let threeYearsBack = Calendar.current.date(byAdding: .year, value: -3, to: day)!

        let bounded = OnThisDay.earlierDays(matching: day, notBefore: threeYearsBack)
        #expect(bounded.count == 3)
        #expect(bounded.first == Calendar.current.date(byAdding: .year, value: -1, to: day))
        #expect(bounded.last == threeYearsBack)

        // With no earliest known, it still cannot run away.
        #expect(OnThisDay.earlierDays(matching: day, notBefore: nil).count == OnThisDay.maximumYears)
    }

    @Test("A day with nothing recorded is not offered")
    func onThisDaySkipsEmptyYears() {
        let day = Calendar.current.startOfDay(for: base)
        #expect(OnThisDay.summarise([], on: day) == nil)

        // Present, but nothing that names a place.
        let walk = Visit(arrival: day.addingTimeInterval(3600), departure: day.addingTimeInterval(4000),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        #expect(OnThisDay.summarise([walk], on: day) == nil)
    }
}
