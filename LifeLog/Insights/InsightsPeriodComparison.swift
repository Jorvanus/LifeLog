import Foundation

/// The one shared policy for how a "current" period compares against a
/// previous one — partial-period clamping, the previous/year-ago interval
/// itself, and whether a change between two hours figures is worth
/// mentioning at all.
///
/// Before this existed, `InsightsSnapshot.make` clamped a partial period to
/// `now` before comparing it against a previous one, but at least two other
/// call sites did not: `InsightsHealthState.reloadHealthSummary` passed the
/// raw, un-clamped interval to `InsightWindow.previousComparisonInterval`,
/// comparing a partial current month's Health figures against a *complete*
/// previous month, and `InsightsArchiveRetrospectives.yearOverYearHighlight`
/// compared a partial current period's logged hours against a full year-ago
/// period. Both silently produced a real percentage for a comparison that
/// was not actually comparing like with like. Every caller that needs a
/// current/previous pair should go through `comparisonIntervals` rather than
/// clamping (or not clamping) its own copy.
enum InsightsPeriodComparison {
    /// A period that hasn't finished yet is compared only up to `now` — an
    /// elapsed slice, never projected or padded to look complete.
    static func clamped(_ interval: DateInterval, now: Date) -> DateInterval {
        guard interval.contains(now) else { return interval }
        return DateInterval(start: interval.start, end: now)
    }

    /// The current period (clamped to `now`) and the previous period to
    /// compare it against — itself clamped to the exact same elapsed
    /// duration, via `InsightWindow.previousComparisonInterval`'s own
    /// calendar-component subtraction of an already-clamped interval.
    /// Comparing five elapsed days of this month against a complete previous
    /// month is not a comparison; this is the one place that pairing is built
    /// so no caller can reintroduce it by hand.
    static func comparisonIntervals(for window: InsightWindow, anchorDate: Date, now: Date,
                                    calendar: Calendar = .current) -> (current: DateInterval, previous: DateInterval) {
        let raw = window.interval(containing: anchorDate, calendar: calendar)
        let current = clamped(raw, now: now)
        let previous = window.previousComparisonInterval(for: current, calendar: calendar)
        return (current, previous)
    }

    /// The same period exactly one year before `current` — same elapsed
    /// length, since `current` is expected to already be clamped. Distinct
    /// from `InsightWindow.previousComparisonInterval`, which steps back one
    /// unit of the window itself (a day, a week, a month, a year); year-over-
    /// year always steps back a full calendar year regardless of which
    /// window is selected, so a partial Day or Week can be compared against
    /// the same days a year ago too.
    static func yearAgo(_ current: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(byAdding: .year, value: -1, to: current.start),
              let end = calendar.date(byAdding: .year, value: -1, to: current.end) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// A change smaller than this is not a change, it is a period — the one
    /// threshold every hours-based comparison across Insights (Month's hero
    /// metrics and category changes, Week's routine changes, year-over-year)
    /// now agrees on. Both a floor and a fraction: twenty minutes is not
    /// worth mentioning even at 100% of a tiny previous total, and 20% of a
    /// large total is not worth mentioning if it amounts to a few minutes.
    /// Day's own steps/sleep highlights (`DayHighlights.noticeableChange`)
    /// are deliberately excluded — those compare a count and a duration
    /// against a personal daily baseline, not one category's hours against
    /// another period's, and don't have a natural "hours" floor to share.
    static let minimumAbsoluteHours = 1.0
    static let minimumFraction = 0.20

    static func isMeaningfulHoursChange(current: Double, previous: Double) -> Bool {
        guard previous > 0 else { return false }
        let delta = abs(current - previous)
        return delta >= minimumAbsoluteHours && delta / previous >= minimumFraction
    }
}
