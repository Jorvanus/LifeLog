import Foundation
import Testing
@testable import LifeLog

/// States a stale cached snapshot would get wrong: a day still partway through, with
/// holes in it, and a visit that has not closed yet.
@MainActor
struct StaleResultHandlingTests {
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

    @Test("Hours with nothing recorded are counted as unlogged")
    func unloggedGapsAreCounted() {
        let now = day.addingTimeInterval(12 * 3600)
        let morning = visit(0, 6, place: "Home", activity: "At home")

        let snapshot = InsightsSnapshot.make(visits: [morning], window: .day, anchorDate: day, now: now)

        #expect(abs(snapshot.unloggedHours - 6) < 0.1, "six of the twelve elapsed hours hold nothing")
        #expect(abs(snapshot.loggedHours - 6) < 0.1)
    }

    /// The state Insights is in every time it is opened: the current stay has no
    /// departure. Measured to the end of the day it would claim hours that have not
    /// happened yet.
    @Test("The visit still running is measured to now, not to the end of the day")
    func openVisitIsMeasuredToNow() {
        let now = day.addingTimeInterval(12 * 3600)
        let open = visit(8, nil, place: "atWork Australia", activity: "Working")

        let snapshot = InsightsSnapshot.make(visits: [open], window: .day, anchorDate: day, now: now)

        #expect(abs(snapshot.loggedHours - 4) < 0.1, "08:00 until now is four hours, not sixteen")
        #expect(abs(snapshot.unloggedHours - 8) < 0.1, "and the eight before it hold nothing")
    }
}
