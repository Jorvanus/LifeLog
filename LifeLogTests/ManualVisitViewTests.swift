import Foundation
import Testing
@testable import LifeLog

/// The overlap warning `ManualVisitView` shows before saving a hand-entered visit
/// over minutes another visit already claims — the product decision the cross-visit
/// `DateInterval` audit raised: Add Visit tells the person rather than leaving every
/// downstream calculation (`CommuteDetection`, reconciliation, Insights slicing) to
/// defend itself against a silent overlap.
@MainActor
struct ManualVisitViewTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A visit that shares no minutes with anything is not flagged")
    func noOverlapWhenTimesAreDisjoint() {
        let existing = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                             latitude: 0, longitude: 0, placeName: "Home",
                             inferredActivity: "At home", source: "automatic")
        let overlapping = ManualVisitView.overlapping(
            arrival: base.addingTimeInterval(60 * 60),
            departure: base.addingTimeInterval(120 * 60),
            among: [existing]
        )
        #expect(overlapping.isEmpty, "back-to-back visits touching at a single instant do not overlap")
    }

    @Test("A visit entirely inside an existing one is flagged")
    func overlapWhenFullyContained() {
        let existing = Visit(arrival: base, departure: base.addingTimeInterval(2 * 60 * 60),
                             latitude: 0, longitude: 0, placeName: "Work",
                             inferredActivity: "Working", source: "manual")
        let overlapping = ManualVisitView.overlapping(
            arrival: base.addingTimeInterval(30 * 60),
            departure: base.addingTimeInterval(45 * 60),
            among: [existing]
        )
        #expect(overlapping.map(\.persistentModelID) == [existing.persistentModelID])
    }

    @Test("A visit that only partially overlaps the tail of an existing one is flagged")
    func overlapWhenPartial() {
        let existing = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                             latitude: 0, longitude: 0, placeName: "Work",
                             inferredActivity: "Working", source: "manual")
        let overlapping = ManualVisitView.overlapping(
            arrival: base.addingTimeInterval(45 * 60),
            departure: base.addingTimeInterval(90 * 60),
            among: [existing]
        )
        #expect(overlapping.map(\.persistentModelID) == [existing.persistentModelID])
    }

    @Test("An open (still-current) visit overlapping the new entry is flagged")
    func overlapWithOpenVisit() {
        let open = Visit(arrival: base, departure: nil,
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic")
        let overlapping = ManualVisitView.overlapping(
            arrival: base.addingTimeInterval(30 * 60),
            departure: base.addingTimeInterval(45 * 60),
            among: [open],
            now: base.addingTimeInterval(60 * 60)
        )
        #expect(overlapping.map(\.persistentModelID) == [open.persistentModelID])
    }

    @Test("Two backfilled entries that overlap each other are both flagged")
    func overlapAmongMultipleManualVisits() {
        let work = Visit(arrival: base, departure: base.addingTimeInterval(8 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "manual")
        let errand = Visit(arrival: base.addingTimeInterval(90 * 60),
                           departure: base.addingTimeInterval(120 * 60),
                           latitude: 0, longitude: 0, placeName: "Post Office",
                           inferredActivity: "Errand", source: "manual")
        let overlapping = ManualVisitView.overlapping(
            arrival: base.addingTimeInterval(80 * 60),
            departure: base.addingTimeInterval(100 * 60),
            among: [work, errand]
        )
        #expect(Set(overlapping.map(\.persistentModelID)) == Set([work, errand].map(\.persistentModelID)))
    }
}
