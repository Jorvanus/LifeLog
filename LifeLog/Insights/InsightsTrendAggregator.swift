import Foundation
import SwiftData

/// What the trend lines, habits card and weekly rhythm all need from one fetch and
/// one pass over it. `Sendable` so it can cross back out of `InsightsTrendAggregator`
/// to the main actor.
struct InsightsTrendData: Sendable {
    /// The full `InsightsTrends.habitWeeks` of weekly totals — `habits` reads all of
    /// it; the trend lines and weekly rhythm only need the most recent `weeks`.
    let weeklyTotals: [WeeklyTotals]
    let weekdayPatterns: [WeekdayPattern]
    let routineStability: InsightsRoutineStability.Presentation
    let itemCount: Int
}

/// Fetches and resolves the season (and, for habits, the year) of history trends and
/// habits need — entirely off the main actor, mirroring `ActivityImportActor`'s own
/// isolation. `Visit` never crosses back out; only the `Sendable` result does.
///
/// This is what makes widening `InsightsTrends.habitWeeks` past a season affordable.
/// The old twelve-week limit existed specifically because this fetch and its
/// per-week segmenting ran on the main actor beside a nine-year journal — moving it
/// here removes that constraint, so the window can be sized to what `habits` needs
/// to say honestly ("first this year") rather than to what the interaction path
/// could absorb.
@ModelActor
actor InsightsTrendAggregator {
    func load(endingAt now: Date, calendar: Calendar = .current,
              scope: InsightsScope = .allHistory) throws -> InsightsTrendData {
        let habitSpan = InsightsTrends.range(endingAt: now, weeks: InsightsTrends.habitWeeks, calendar: calendar)
        let start = habitSpan.start
        let end = habitSpan.end
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival < end && ($0.departure ?? end) >= start },
            sortBy: [SortDescriptor(\.arrival)]
        )
        let visits = scope.filtering(try modelContext.fetch(descriptor))
        let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        // Resolved once here, not per week and not a second time for the weekday
        // chart below — CommuteDetection.commutes sorts the whole array and does
        // not depend on which range is being segmented.
        let commutes = CommuteDetection.commutes(in: visits, savedPlaces: savedPlaces, now: now)
        let allWeeks = InsightsTrends.weeklyTotals(visits: visits, now: now,
                                                    weeks: InsightsTrends.habitWeeks, calendar: calendar,
                                                    commutes: commutes)
        // The weekly rhythm chart stays scoped to the season, same as the trend
        // lines — `visits` is a superset of that window, and weekdayPatterns
        // filters to `range` itself, so this needs no separate fetch.
        let displaySpan = InsightsTrends.range(endingAt: now, weeks: InsightsTrends.weeks, calendar: calendar)
        let rhythm = InsightsSnapshot.weekdayPatterns(visits: visits, range: displaySpan, now: now,
                                                       commutes: commutes)
        // Same season, same already-fetched visits/commutes -- Routine Stability
        // needs the resolved segments themselves (not the weekday chart's summed
        // totals), so this is the one place that calls `InsightsSnapshot.segments`
        // rather than `weekdayPatterns`.
        let displaySegments = InsightsSnapshot.segments(visits: visits, range: displaySpan, now: now,
                                                        commutes: commutes, savedPlaces: savedPlaces)
        let routineStability = InsightsRoutineStability.make(segments: displaySegments, visits: visits, commutes: commutes,
                                                              savedPlaces: savedPlaces, window: displaySpan, now: now,
                                                              calendar: calendar)
        return InsightsTrendData(weeklyTotals: allWeeks, weekdayPatterns: rhythm,
                                 routineStability: routineStability, itemCount: visits.count)
    }
}
