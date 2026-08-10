import Foundation
import Testing
@testable import LifeLog

struct InsightsDonutChartTests {
    private func homeVisit(from: Double, to: Double) -> Visit {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return Visit(arrival: base.addingTimeInterval(from * 60), departure: base.addingTimeInterval(to * 60),
                    latitude: -23.37, longitude: 150.51, placeName: "Home",
                    inferredActivity: "At home", userActivity: "At home",
                    source: "automatic", recognitionConfidence: "learned")
    }

    @Test("The largest segment in a category represents it, not the earliest")
    func picksLargestSegmentNotEarliest() throws {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        // The exact shape reported 2026-08-10: an overnight Home stay interrupted by
        // Sleep leaves an 11-minute sliver before the main stay resumes. Tapping the
        // Home wedge showed that sliver's times, which matched nothing in the entry
        // list below it.
        let sliver = homeVisit(from: 0, to: 11)
        let mainStay = homeVisit(from: 100, to: 500)
        let sliverSegment = InsightSegment.visit(sliver, visibleFrom: sliver.arrival,
                                                 visibleTo: try #require(sliver.departure), now: now)
        let mainSegment = InsightSegment.visit(mainStay, visibleFrom: mainStay.arrival,
                                                visibleTo: try #require(mainStay.departure), now: now)

        // Earliest-first order, matching how `makeSegments` builds its list.
        let representative = InsightsDonutChart.representativeSegment(
            in: [sliverSegment, mainSegment], matching: sliverSegment.category, isUnlogged: false
        )

        #expect(representative?.id == mainSegment.id)
    }
}
