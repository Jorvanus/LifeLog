import Foundation
@testable import LifeLog

/// Fixture builders shared by the files that grew out of
/// `TimelineFixtureCoverageTests`. Every builder takes its time zone,
/// calendar, clock, or coordinate explicitly, with the value the split
/// files previously hard-coded kept only as the default — so a test that
/// needs a different zone or a different instant can ask for one without
/// copying the whole helper.
enum TimelineFixtureBuilders {
    /// The fixed instant most of these fixtures were originally written
    /// against (2027-01-15T06:40:00Z). Kept as a named default rather than
    /// a magic literal repeated in every file.
    static func referenceDate(secondsSince1970: TimeInterval = 1_800_000_000) -> Date {
        Date(timeIntervalSince1970: secondsSince1970)
    }

    /// A Gregorian calendar pinned to an explicit time zone, defaulting to
    /// the device's current zone the way the original tests implicitly did
    /// via `Calendar.current` / `Calendar(identifier: .gregorian)`.
    static func gregorianCalendar(timeZone: TimeZone? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    /// A simple automatic "stay" visit offset in minutes from `base`, used
    /// by the Add Visit gap-suggestion fixtures. Two call sites in the
    /// original file built this identically inline; this is that helper
    /// with every value now an explicit, overridable parameter.
    static func stayVisit(
        _ placeName: String,
        fromMinutes: Double,
        toMinutes: Double,
        base: Date = referenceDate(),
        latitude: Double = -23.37,
        longitude: Double = 150.51,
        inferredActivity: String = "Visiting",
        source: String = "automatic",
        recognitionConfidence: String? = "learned"
    ) -> Visit {
        Visit(
            arrival: base.addingTimeInterval(fromMinutes * 60),
            departure: base.addingTimeInterval(toMinutes * 60),
            latitude: latitude, longitude: longitude, placeName: placeName,
            inferredActivity: inferredActivity, source: source,
            recognitionConfidence: recognitionConfidence
        )
    }
}
