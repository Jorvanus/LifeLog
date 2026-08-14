import Foundation
@testable import LifeLog

/// Shared fixture anchor for Insights snapshot tests that need a fixed "today" —
/// deterministic regardless of when the suite actually runs. Both
/// `InsightsAwayFromHomeTests` and `InsightsWeekdayPatternTests` were independently
/// defining this same constant; kept here once they needed the same `stay` builder too.
let insightsFixtureDay = Calendar(identifier: .gregorian)
    .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

/// A learned, automatically-detected stay at a named place on `insightsFixtureDay`,
/// at the coordinates of the fixture's default location. Duplicated identically in
/// `InsightsAwayFromHomeTests` and `InsightsWeekdayPatternTests` before being pulled
/// out here — both structs still keep their own additional `stay` overloads that take
/// an explicit coordinate, since those aren't shared.
func insightsStay(_ startHour: Double, _ endHour: Double, place: String, activity: String) -> Visit {
    Visit(arrival: insightsFixtureDay.addingTimeInterval(startHour * 3600),
          departure: insightsFixtureDay.addingTimeInterval(endHour * 3600),
          latitude: -23.378, longitude: 150.511,
          placeName: place, inferredActivity: activity, userActivity: activity,
          source: "automatic", recognitionConfidence: "learned")
}
