import Foundation
import SwiftData

/// The selected period's own data: a bounded `Visit` fetch, the cached
/// `InsightsSnapshot` built from it, and the Day/Week/Month layouts' own
/// segment breakdowns built from the same fetched visits.
///
/// Extracted verbatim from `InsightsView.reloadInsights` — the bounded fetch
/// and the snapshot cache are unchanged in shape and behaviour, per
/// TODO.md's own instruction not to replace them with an archive-wide query.
/// `InsightsView` still owns `window`/`anchorDate`/scope (the selected
/// period) and calls `reload` when any of them change; this only owns what
/// happens to the store once it does.
@MainActor @Observable
final class InsightsPeriodLoader {
    private(set) var visits: [Visit] = []
    private(set) var snapshot = InsightsSnapshot.empty
    private(set) var archiveHasAnyVisits = false
    private var snapshotCache = InsightsSnapshotCache()
    /// The day bar's own segments, over the *uncapped* calendar day rather
    /// than `snapshot.analysisInterval` (which stops at `now` for today) --
    /// built from the exact same `InsightsSnapshot.makeSegments` the donut
    /// and header total already use, just given the full range. Nothing
    /// beyond `now` has a visit yet, so that portion resolves to trailing
    /// `.unlogged` segments on its own; the bar renders those distinctly
    /// rather than reporting them as missing time. Only populated for
    /// `window == .day`.
    private(set) var daySegments: [InsightSegment] = []
    private(set) var weekDays: [WeeklyStrip.Day] = []
    private(set) var monthDays: [MonthlyInsights.Day] = []

    /// Fetches, caches, and re-segments the selected period. Mirrors
    /// `InsightsView.reloadInsights` exactly, minus `now` (still owned by the
    /// view, since it drives far more than this one reload) and Year's own
    /// placeholder `annualInsights` assignment (presentation state, not period
    /// data — the view triggers that separately once this returns).
    func reload(window: InsightWindow, anchorDate: Date, scope: InsightsScope, now: Date,
               home: InsightsSnapshot.HomePlace?, savedPlaces: [SavedPlace],
               aggregationGeneration: Int, context: ModelContext) {
        // Fetch only the selected and comparison periods. Keeping the nine-year journal
        // archive out of memory is substantially cheaper than trimming useful history.
        let currentInterval = window.interval(containing: anchorDate)
        let observationStart = RecordingObservation.startedAt()
        let fetchEnd = currentInterval.contains(now) ? now : currentInterval.end
        let analysisInterval = DateInterval(start: currentInterval.start, end: fetchEnd)
        let comparisonBasis = window == .month && currentInterval.contains(now) ? currentInterval : analysisInterval
        let fetchStart = window.previousComparisonInterval(for: comparisonBasis).start
        let fetchStartedAt = Date.now
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                visit.arrival >= fetchStart && visit.arrival < fetchEnd
            },
            sortBy: [SortDescriptor(\.arrival)]
        )
        do {
            archiveHasAnyVisits = ((try? context.fetchCount(FetchDescriptor<Visit>())) ?? 0) > 0
            var fetched = scope.filtering(try context.fetch(descriptor))
            // Preserve a current multi-day location whose arrival predates the comparison
            // range without widening the main archive query.
            do {
                let activeDescriptor = FetchDescriptor<Visit>(
                    predicate: #Predicate { $0.departure == nil },
                    sortBy: [SortDescriptor(\.arrival)]
                )
                let existingIDs = Set(fetched.map { ObjectIdentifier($0) })
                fetched.append(contentsOf: try context.fetch(activeDescriptor).filter(scope.includes).filter {
                    !existingIDs.contains(ObjectIdentifier($0))
                })
            } catch {
                // The period data is still valid if the optional-date supplement is
                // unavailable on a particular protected-store/runtime combination.
                Diagnostics.record(error, context: context, subsystem: "Insights",
                                   operation: "active visit supplement", severity: "info")
            }
            visits = fetched.sorted { $0.arrival < $1.arrival }
        } catch {
            // Do not turn a predicate-translation problem into a synchronous archive
            // scan. The empty state is preferable to blocking an Insights interaction;
            // the next invalidation retries the same bounded query.
            visits = []
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "date-scoped fetch", severity: "warning")
        }
        // `budget` records this same elapsed time unconditionally, and against the
        // window's own limit rather than a flat 250 ms — which a year view is expected
        // to exceed. The `performance` sample beside it wrote a second row calling that
        // "Slow" while the budget row called the same measurement a pass.
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) period fetch",
                           startedAt: fetchStartedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)

        // Donut taps remain local to the chart and never rebuild history, trends,
        // place totals, or Map content.
        let startedAt = Date.now
        // The generation is captured with the input. A write arriving during
        // aggregation will post invalidation and trigger a fresh rebuild.
        // Home is part of the key: moving or resizing the saved place changes what
        // counts as time away from it, and a stale snapshot would not know.
        let homeKey = home.map { "\($0.latitude),\($0.longitude),\($0.radius)" } ?? "none"
        // Commute detection now reads every roled place, not just Home — moving Work
        // or clearing its role changes what counts as commuting just as much as Home
        // moving does, and a stale snapshot would not know either.
        let rolesKey = savedPlaces.compactMap { place -> String? in
            guard let role = place.homeWorkRole else { return nil }
            return "\(role.rawValue):\(place.latitude),\(place.longitude),\(place.radius)"
        }.sorted().joined(separator: "|")
        let observationKey = observationStart?.timeIntervalSinceReferenceDate.description ?? "none"
        let cacheKey = "\(window.rawValue)|\(scope.rawValue)|\(anchorDate.timeIntervalSinceReferenceDate)|\(visits.count)|\(homeKey)|\(rolesKey)|\(observationKey)"
        snapshot = snapshotCache.snapshot(key: cacheKey, generation: aggregationGeneration) {
            InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now,
                                  home: home, savedPlaces: savedPlaces,
                                  observationStart: observationStart)
        }
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) snapshot rebuild",
                           startedAt: startedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)

        // The weekly strip's seven columns, one `makeSegments` call each, all
        // over `visits` already fetched for this period -- no new query. Each
        // day's segments are exactly what opening that day in Day Insights
        // would build, so the strip can never disagree with the screen it
        // links to.
        if window == .day {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            daySegments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                        range: currentInterval, now: now, savedPlaces: savedPlaces,
                                                        observationStart: observationStart)
        } else {
            daySegments = []
        }

        if window == .week {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            let calendar = Calendar.current
            var days: [WeeklyStrip.Day] = []
            var dayStart = currentInterval.start
            while dayStart < currentInterval.end {
                let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? currentInterval.end, currentInterval.end)
                guard dayEnd > dayStart else { break }
                let dayInterval = DateInterval(start: dayStart, end: dayEnd)
                let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                             range: dayInterval, now: now, savedPlaces: savedPlaces,
                                                             observationStart: observationStart)
                days.append(WeeklyStrip.Day(date: dayStart, segments: segments))
                dayStart = dayEnd
            }
            weekDays = days
        } else {
            weekDays = []
        }

        if window == .month {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            monthDays = MonthlyInsights.daySummaries(
                segments: InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                        range: currentInterval, now: now, savedPlaces: savedPlaces,
                                                        observationStart: observationStart),
                interval: currentInterval, now: now
            )
        } else {
            monthDays = []
        }
    }
}
