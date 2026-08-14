import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// The inputs that actually determine a snapshot's identity and content: the window,
/// the anchor date, the elapsed hours it is compared against, and whether a visit was
/// hidden. Get any of these wrong and a cached snapshot would be reused for — or built
/// from — the wrong inputs.
@MainActor
struct SnapshotCacheKeyTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func visit(_ startHour: Double, _ endHour: Double?, place: String, activity: String,
                       source: String = "automatic") -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: endHour.map { day.addingTimeInterval($0 * 3600) },
              latitude: -23.378, longitude: 150.511,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: source, recognitionConfidence: "learned")
    }

    @Test("Month comparisons use the preceding calendar month")
    func monthComparisonUsesCalendarMonth() {
        let calendar = Calendar(identifier: .gregorian)
        let may = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let interval = InsightWindow.month.interval(containing: may)
        let previous = InsightWindow.month.previousComparisonInterval(for: interval)

        #expect(previous.start == calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!)
        #expect(previous.end == may)
    }

    /// The `min` in `previousInterval` exists so a part-finished day is measured
    /// against the same number of hours yesterday. Without it every morning would
    /// report every activity collapsing, because six hours would be compared with a
    /// full twenty-four.
    @Test("A part-finished day is compared against the same hours of the day before")
    func comparisonUsesTheSameElapsedHours() {
        let now = day.addingTimeInterval(6 * 3600)
        let today = visit(0, 6, place: "atWork Australia", activity: "Working")
        // Twelve hours yesterday, of which six fall inside the matching window.
        let yesterday = visit(-24, -12, place: "atWork Australia", activity: "Working")

        let snapshot = InsightsSnapshot.make(visits: [today, yesterday], window: .day,
                                             anchorDate: day, now: now)

        #expect(!snapshot.comparisons.contains { abs($0.delta) > 1 },
                "six hours against the matching six is no change; against the whole day it would read as six lost")
    }

    /// The same shape, but genuinely different: half as much this morning as in the
    /// matching hours yesterday has to be reported.
    @Test("A real change against the matching hours is still reported")
    func comparisonStillReportsARealChange() {
        let now = day.addingTimeInterval(6 * 3600)
        let today = visit(0, 2, place: "atWork Australia", activity: "Working")
        let yesterday = visit(-24, -18, place: "atWork Australia", activity: "Working")

        let snapshot = InsightsSnapshot.make(visits: [today, yesterday], window: .day,
                                             anchorDate: day, now: now)

        #expect(snapshot.comparisons.contains { $0.delta <= -3 }, "two hours against six is four fewer")
    }

    @Test("A visit the person hid is left out of the totals and the places")
    func ignoredVisitsAreExcluded() throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let kept = visit(0, 4, place: "Home", activity: "At home")
        let hidden = visit(4, 8, place: "Somewhere Else", activity: "Visiting")
        [kept, hidden].forEach(context.insert)
        try context.save()
        // Ignore state is keyed on the persistent id, so the visit has to be stored
        // before it can be hidden at all.
        hidden.isIgnored = true
        defer { hidden.isIgnored = false }

        let snapshot = InsightsSnapshot.make(visits: [kept, hidden], window: .day,
                                             anchorDate: day, now: day.addingTimeInterval(8 * 3600))

        #expect(abs(snapshot.loggedHours - 4) < 0.1, "hidden hours are not logged time")
        #expect(abs(snapshot.unloggedHours - 4) < 0.1, "they are a hole in the day, not someone else's hours")
        #expect(!snapshot.placeTotals.contains { $0.name == "Somewhere Else" })
    }
}
