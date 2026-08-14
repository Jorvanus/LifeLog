import Foundation
import Testing
@testable import LifeLog

@MainActor
struct InsightsAwayFromHomeTests {
    private let day = insightsFixtureDay

    private func sleep(_ startHour: Double, _ endHour: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: -23.378, longitude: 150.511,
              placeName: "Sleep", inferredActivity: "Sleeping", userActivity: "Sleeping",
              source: "health-sleep", recognitionConfidence: "device")
    }

    /// Sleep is imported as "Sleeping" at a place called "Sleep", and it takes the
    /// segment over the Home stay it sits inside. Neither label says "home", so
    /// every night in your own bed used to be reported as time away from it.
    @Test("A night slept at home is not time away from home")
    func sleepInsideHomeIsNotAway() {
        let visits = [insightsStay(0, 12, place: "Home", activity: "At home"), sleep(0, 7)]
        let home = InsightsSnapshot.HomePlace(latitude: -23.378, longitude: 150.511, radius: 100)
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600), home: home
        )
        #expect(snapshot.awayFromHomeHours == 0)
    }

    /// The same record, with no Home stay around it, is a night spent elsewhere.
    @Test("A night slept away from home still counts as away")
    func sleepAwayFromHomeIsAway() {
        let visits = [insightsStay(0, 12, place: "Seaside Motel", activity: "Staying over"), sleep(0, 7)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600)
        )
        #expect(snapshot.awayFromHomeHours > 0)
    }

    /// Where home is, once the person has said where home is.
    private static let homeCoordinate = (latitude: -23.4454, longitude: 150.4581)
    private var savedHome: InsightsSnapshot.HomePlace {
        .init(latitude: Self.homeCoordinate.latitude,
              longitude: Self.homeCoordinate.longitude, radius: 100)
    }

    private func stay(_ startHour: Double, _ endHour: Double, place: String, activity: String,
                      latitude: Double, longitude: Double) -> Visit {
        Visit(arrival: day.addingTimeInterval(startHour * 3600),
              departure: day.addingTimeInterval(endHour * 3600),
              latitude: latitude, longitude: longitude,
              placeName: place, inferredActivity: activity, userActivity: activity,
              source: "automatic", recognitionConfidence: "learned")
    }

    /// "Home" was a substring test, so anywhere carrying those four letters counted as
    /// being home — a Homemaker Centre, a suburb called Homebush. A saved place has a
    /// coordinate and a radius, which cannot be misread.
    @Test("A place merely named like home is still time away from it")
    func aPlaceNamedLikeHomeIsNotHome() {
        let visits = [stay(9, 12, place: "Rockhampton Homemaker Centre", activity: "Shopping",
                           latitude: -23.378, longitude: 150.511)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600), home: savedHome
        )
        #expect(snapshot.awayFromHomeHours > 0, "kilometres away is not home, whatever it is called")
    }

    /// And the reverse: the place decides, so a stay there is home even when Core
    /// Location never worked out what to call it.
    @Test("An unnamed stay at the saved home is not time away")
    func anUnnamedStayAtHomeIsHome() {
        let visits = [stay(0, 12, place: Visit.unknownPlaceName, activity: "Visiting",
                           latitude: Self.homeCoordinate.latitude,
                           longitude: Self.homeCoordinate.longitude)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600), home: savedHome
        )
        #expect(snapshot.awayFromHomeHours == 0)
    }

    /// No guessing from wording: a stay merely called "Home" does not make Insights
    /// invent a home that was never saved. The older name-substring fallback made a
    /// café called "Homeward Bound" count as home too, which is exactly the false
    /// positive an explicit Saved Place role exists to remove.
    @Test("Without a saved home, nothing is read as home")
    func withoutASavedHomeNothingIsHome() {
        let visits = [stay(0, 12, place: "Home", activity: "At home",
                           latitude: -23.378, longitude: 150.511)]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600), home: nil
        )
        #expect(snapshot.awayFromHomeHours > 0)
    }

    /// A visit that names its own place is away from home whatever else claims
    /// those minutes — an open Home stay overlapping it must not absorb it.
    @Test("A place visit overlapping an open home stay is still time away")
    func overlappingPlaceVisitStaysAway() {
        let visits = [insightsStay(0, 12, place: "Home", activity: "At home"),
                      insightsStay(9, 11, place: "Gracemere Shopping World", activity: "Shopping")]
        let snapshot = InsightsSnapshot.make(
            visits: visits, window: .day, anchorDate: day,
            now: day.addingTimeInterval(12 * 3600)
        )
        #expect(snapshot.awayFromHomeHours > 0)
    }
}
