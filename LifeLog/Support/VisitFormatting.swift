import Foundation
import CoreLocation

/// A span as a person would say it, rounded down to whole minutes.
func formattedDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds / 60))
    return formatDurationMinutes(totalMinutes)
}

/// A stay's own duration *within `day`*, not the whole record's. A stay that
/// started yesterday and is still open this morning is real and its arrival time
/// says so honestly -- but showing its full span as a same-row duration reads as
/// "home almost all day" when only a few hours of it actually fall on the day
/// being looked at. A same-day visit is untouched (its arrival and departure
/// already sit inside `day`); only one that crosses the boundary gets a different
/// number here than the visit's own `duration` would give.
func durationWithinDay(arrival: Date, departure: Date?, day: DateInterval) -> TimeInterval {
    let start = max(arrival, day.start)
    let end = min(departure ?? day.end, day.end)
    return max(0, end.timeIntervalSince(start))
}

/// Distance as a person would say it: whole metres up to a kilometre, then one
/// decimal place, because "1.4 km" is a walk and "1,428 m" is a measurement.
func formattedDistance(_ metres: CLLocationDistance) -> String {
    metres < 1_000
        ? "\(Int(metres.rounded())) m"
        : String(format: "%.1f km", metres / 1_000)
}
