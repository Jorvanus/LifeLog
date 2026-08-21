import Foundation
import SwiftData

/// Everything Day/Week/Month/Year present beyond the raw `InsightsSnapshot`:
/// highlights, the rolling weekly baseline trend, Year's derived story, and
/// the per-layout metric/attention rows built from all of the above.
///
/// Extracted from `InsightsView` so this can be exercised without a live
/// `View`. Two collaborators are passed into every reload rather than held:
/// `InsightsHealthState` (steps/sleep/Health summary) and
/// `InsightsArchiveRetrospectives` (place history, year-over-year, Year's
/// historical places) — this only decides *when* to ask them for what and
/// how to fold the answer into a highlight or a metric row. Navigation stays
/// in `InsightsView`: a metric/attention row's own `action` closure is
/// supplied by the caller (`openCategory`/`openSleep`), never built here.
@MainActor @Observable
final class InsightsPresentationState {
    private(set) var highlights: [DayHighlight] = []
    /// Up to `InsightsTrends.habitWeeks` of completed weeks' per-category hours,
    /// the same fetch `trendSeries`/`habits` already use -- never includes the
    /// in-progress week (`InsightsTrends.range` ends before it), which is what
    /// keeps the Week rolling baseline from comparing a partial week as if it
    /// were whole.
    private(set) var weeklyBaselineTotals: [WeeklyTotals] = []
    /// Weekday Home/Work arrival-departure ranges, sleep timing regularity, and
    /// commute stability, over the same season `weeklyBaselineTotals` reads --
    /// see `reloadTrends`, which is the one fetch behind both.
    private(set) var routineStability = InsightsRoutineStability.Presentation.empty(
        window: DateInterval(start: .distantPast, duration: 0))
    private(set) var annualInsights = AnnualInsights.make(current: [], previous: [],
                                                          yearInterval: DateInterval(start: .distantPast, duration: 0), now: .now)

    private enum NeedsAttentionItem: Identifiable {
        case review(ReviewQueue.Entry)
        case gap(InsightSegment)

        var id: String {
            switch self {
            case .review(let entry): "review-\(entry.id)"
            case .gap(let segment): "gap-\(segment.start.timeIntervalSinceReferenceDate)"
            }
        }
    }

    /// Two existing detection paths, not new ones: `ReviewQueue.entries` is the
    /// exact function/ordering Timeline's own review card already uses, and
    /// `InsightsSnapshot.meaningfulGaps` reads the same `daySegments` the day bar
    /// draws. Capped short — this names what needs a look, it does not replace
    /// the day bar as the place to browse everything.
    private func needsAttentionItems(visits: [Visit], daySegments: [InsightSegment], now: Date) -> [NeedsAttentionItem] {
        let review = ReviewQueue.entries(in: visits, now: now).prefix(3).map { NeedsAttentionItem.review($0) }
        let gaps = InsightsSnapshot.meaningfulGaps(in: daySegments, before: now).prefix(2).map { NeedsAttentionItem.gap($0) }
        return Array((review + gaps).prefix(4))
    }

    func dayAttentionPresentations(visits: [Visit], daySegments: [InsightSegment], now: Date) -> [DayAttentionPresentation] {
        needsAttentionItems(visits: visits, daySegments: daySegments, now: now).map { item in
            switch item {
            case .review(let entry):
                return DayAttentionPresentation(
                    id: "review-\(entry.id)", title: entry.visit.displayPlaceName,
                    detail: entry.reason.prompt, icon: "questionmark.circle.fill",
                    accessibilityLabel: "\(entry.visit.displayPlaceName), \(entry.reason.prompt)",
                    accessibilityHint: "Opens the editor for this visit", target: .visit(entry.visit.stableID)
                )
            case .gap(let segment):
                let detail = "\(segment.start.formatted(date: .omitted, time: .shortened))–\(segment.end.formatted(date: .omitted, time: .shortened)) · \(formatHours(segment.hours))"
                return DayAttentionPresentation(
                    id: "gap-\(segment.start.timeIntervalSinceReferenceDate)", title: "Nothing logged",
                    detail: detail, icon: "clock.badge.questionmark",
                    accessibilityLabel: "Nothing logged, \(formatHours(segment.hours)), from \(segment.start.formatted(date: .omitted, time: .shortened)) to \(segment.end.formatted(date: .omitted, time: .shortened))",
                    accessibilityHint: "Add a visit for this time", target: .gap(DateInterval(start: segment.start, end: segment.end))
                )
            }
        }
    }

    func dayMetricPresentations(snapshot: InsightsSnapshot, daySegments: [InsightSegment],
                                todaySteps: Double?, lastNightSleep: SleepSummary?,
                                healthSummary: HealthInsightsSummary?) -> [DayInsightMetricPresentation] {
        var metrics: [DayInsightMetricPresentation] = []
        let atHome = max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)
        if atHome > 0.01 {
            metrics.append(.init(id: "day-metric-home", icon: "house.fill", title: "At Home", value: formatHours(atHome)))
        }
        if snapshot.awayFromHomeHours > 0.01 {
            metrics.append(.init(id: "day-metric-away", icon: "figure.walk.departure", title: "Away from Home", value: formatHours(snapshot.awayFromHomeHours)))
        }
        if let steps = todaySteps ?? healthSummary?.steps, steps > 0 {
            metrics.append(.init(id: "day-metric-steps", icon: "shoeprints.fill", title: "Steps", value: Int(steps).formatted()))
        }
        // Prefer the already-reconciled Sleep visit's own hours -- the same total the
        // donut wedge and Timeline card show -- over a fresh, independent HealthKit
        // query. Both used to run their own query against the same night and could
        // disagree by a minute (a different padded fetch window landing on a
        // different edge sample), showing two different numbers for what a person
        // reasonably expects to be the same fact. Only fall back to the live query
        // when sleep has not been reconciled into a visit for today yet.
        let segmentSleepHours = daySegments.filter(\.isSleep).reduce(0) { $0 + $1.hours }
        let sleepHours = segmentSleepHours > 0.01 ? segmentSleepHours : (lastNightSleep.map { $0.totalSleep / 3600 } ?? 0)
        if sleepHours > 0.01 {
            metrics.append(.init(id: "day-metric-sleep", icon: "bed.double.fill", title: "Last night’s sleep", value: formatHours(sleepHours)))
        }
        if let exercise = healthSummary?.exerciseMinutes, exercise > 0 {
            metrics.append(.init(id: "day-metric-exercise", icon: "figure.run", title: "Exercise", value: "\(Int(exercise.rounded())) min"))
        } else if let workoutCount = healthSummary?.workoutCount, workoutCount > 0 {
            metrics.append(.init(id: "day-metric-exercise", icon: "figure.run.circle.fill", title: "Workouts", value: "\(workoutCount) · \(Int(healthSummary?.workoutMinutes.rounded() ?? 0)) min"))
        } else {
            let workout = InsightsSnapshot.fitnessHours(in: daySegments)
            if workout > 0.01 {
                metrics.append(.init(id: "day-metric-exercise", icon: "figure.run", title: "Exercise", value: formatHours(workout)))
            }
        }
        let travel = TravelInsights.make(from: daySegments)
        if travel.hasTravel {
            metrics.append(.init(id: "day-metric-travel", icon: "car.fill", title: "Travel", value: formatHours(travel.totalHours)))
        }
        return metrics
    }

    /// The Week layout's per-metric facts, built from the same fetched health
    /// values and resolved segments as the rest of this screen — the presentation
    /// prep `WeekInsightsView` itself must not repeat, since it receives no
    /// SwiftData/health state, only this already-resolved array. `openCategory`/
    /// `openSleep` are `InsightsView`'s own navigation actions, threaded through
    /// rather than built here.
    func weeklyYourWeekMetrics(snapshot: InsightsSnapshot, now: Date, interval: DateInterval,
                               weekSteps: Double?, weekAverageNightlySleep: TimeInterval?,
                               healthSummary: HealthInsightsSummary?,
                               openCategory: @escaping (String) -> Void,
                               openSleep: @escaping () -> Void) -> [WeeklyYourWeekMetric] {
        let categoryHours = InsightsSnapshot.categoryHours(in: snapshot.segments)
        let atHome = max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)
        let workHours = categoryHours["Work"] ?? 0
        let travelHours = InsightsSnapshot.travelHours(in: snapshot.segments)
        let elapsedSeconds = min(now, interval.end).timeIntervalSince(interval.start)
        let elapsedDays = max(1, min(7, Int(ceil(elapsedSeconds / 86_400))))
        var metrics: [WeeklyYourWeekMetric] = [
            .init(id: "home", icon: "house.fill", title: "At Home", value: formatHours(atHome), action: { openCategory("Home") })
        ]
        if workHours > 0.01 {
            metrics.append(.init(id: "work", icon: "briefcase.fill", title: "At Work", value: formatHours(workHours)))
        }
        if travelHours > 0.01 {
            metrics.append(.init(id: "travel", icon: "car.fill", title: "Travelling", value: formatHours(travelHours)))
        }
        if let weekAverageNightlySleep, weekAverageNightlySleep > 0 {
            metrics.append(.init(id: "sleep", icon: "bed.double.fill", title: "Sleep average",
                                 value: formatHours(weekAverageNightlySleep / 3600), action: openSleep))
        }
        if let steps = weekSteps ?? healthSummary?.steps, steps > 0 {
            metrics.append(.init(id: "steps", icon: "shoeprints.fill", title: "Steps · Apple Health",
                                 value: "\(Int(steps).formatted()) total · \(Int(steps / Double(elapsedDays)).formatted())/day avg"))
        }
        if let exercise = healthSummary?.exerciseMinutes, exercise > 0 {
            metrics.append(.init(id: "exercise", icon: "figure.run", title: "Exercise · Apple Health",
                                 value: "\(Int(exercise.rounded())) min"))
        }
        if let workouts = healthSummary?.workoutCount, workouts > 0 {
            metrics.append(.init(id: "workouts", icon: "figure.run.circle.fill", title: "Workouts · Apple Health",
                                 value: "\(workouts) · \(Int(healthSummary?.workoutMinutes.rounded() ?? 0)) min"))
        }
        return metrics
    }

    /// This week's per-category hours appended to the rolling baseline and run
    /// through `InsightsTrends.series` — see `WeekRoutineChange.changes` for the
    /// math, kept beside its type in `WeekInsightsView.swift` and unit-tested
    /// there. Needs `weeklyBaselineTotals`, which only `reloadTrends` populates.
    func weekRoutineChanges(interval: DateInterval, snapshot: InsightsSnapshot, now: Date) -> [WeekRoutineChange] {
        WeekRoutineChange.changes(currentWeekStart: interval.start, currentSegments: snapshot.segments,
                                  baselineTotals: weeklyBaselineTotals, now: now)
    }

    /// `nil` whenever there isn't a real commute to summarise: no Home/Work
    /// roles configured, or the week's own confidence gate
    /// (`InsightsSnapshot.weekCommuteSummary`) isn't met. `commutes` is
    /// recomputed here rather than cached — it runs over `visits`, already
    /// bounded to this period, the same cost `CommuteDetection` already pays
    /// elsewhere on this screen.
    func weeklyCommuteSummary(visits: [Visit], savedPlaces: [SavedPlace], now: Date,
                              interval: DateInterval, homePlace: SavedPlace?,
                              workPlace: SavedPlace?) -> InsightsSnapshot.WeekCommuteSummary? {
        guard homePlace != nil, workPlace != nil else { return nil }
        let commutes = CommuteDetection.commutes(in: visits, savedPlaces: savedPlaces, now: now)
        let baselineWeeks = Array(weeklyBaselineTotals.suffix(WeekRoutineChange.baselineWeekCount))
        let nonzero = baselineWeeks.map { $0.hours[CommuteDetection.categoryName] ?? 0 }.filter { $0 > 0 }
        let baselineHours = nonzero.isEmpty ? nil : nonzero.reduce(0, +) / Double(nonzero.count)
        return InsightsSnapshot.weekCommuteSummary(commutes: commutes, weekInterval: interval, baselineHours: baselineHours)
    }

    func monthlyInsights(snapshot: InsightsSnapshot, window: InsightWindow, now: Date) -> MonthlyInsights {
        MonthlyInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                             currentInterval: snapshot.analysisInterval,
                             previousInterval: window.previousComparisonInterval(for: snapshot.analysisInterval),
                             now: now)
    }

    private func monthlyChangeDetail(current: Double, previous: Double, unit: String = "") -> String {
        guard previous > 0 else { return "This month" }
        let delta = current - previous
        guard abs(delta) >= MonthlyInsights.minimumAbsoluteChange,
              abs(delta) / previous >= MonthlyInsights.minimumPercentageChange else {
            return "This month"
        }
        let direction = delta >= 0 ? "more" : "less"
        return "\(formatHours(abs(delta)))\(unit) \(direction) than last month"
    }

    private func monthAverageDailySteps(monthSteps: Double?, interval: DateInterval, now: Date) -> Double? {
        guard let monthSteps, monthSteps > 0 else { return nil }
        let queryEnd = interval.contains(now) ? now : interval.end
        let elapsedDays = max(1, Int(ceil(max(0, queryEnd.timeIntervalSince(interval.start)) / 86_400)))
        return monthSteps / Double(elapsedDays)
    }

    /// `openCategory`/`openSleep` are `InsightsView`'s own navigation actions,
    /// threaded through rather than built here — see this type's own doc comment.
    func monthlyHeroMetrics(snapshot: InsightsSnapshot, interval: DateInterval, now: Date,
                            monthAverageNightlySleep: TimeInterval?, monthSteps: Double?,
                            openCategory: @escaping (String) -> Void,
                            openSleep: @escaping () -> Void) -> [MonthlyHeroMetric] {
        let currentCategories = InsightsSnapshot.categoryHours(in: snapshot.segments)
        let previousCategories = InsightsSnapshot.categoryHours(in: snapshot.previousSegments)
        let currentLogged = snapshot.loggedHours
        let previousLogged = snapshot.previousSegments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let currentAway = max(0, currentLogged - currentCategories["Home", default: 0])
        let previousAway = max(0, previousLogged - previousCategories["Home", default: 0])
        var metrics: [MonthlyHeroMetric] = []

        if currentAway > 0.01 {
            metrics.append(.init(id: "away", icon: "figure.walk.departure", title: "Away from Home",
                                 value: formatHours(currentAway), detail: monthlyChangeDetail(current: currentAway, previous: previousAway)))
        }
        if let work = currentCategories["Work"], work > 0.01 {
            metrics.append(.init(id: "work", icon: "briefcase.fill", title: "Work", value: formatHours(work),
                                 detail: monthlyChangeDetail(current: work, previous: previousCategories["Work", default: 0]),
                                 action: { openCategory("Work") }))
        }
        if snapshot.travel.totalHours > 0.01 {
            let previousTravel = TravelInsights.make(from: snapshot.previousSegments).totalHours
            metrics.append(.init(id: "travel", icon: "car.fill", title: "Travel", value: formatHours(snapshot.travel.totalHours),
                                 detail: monthlyChangeDetail(current: snapshot.travel.totalHours, previous: previousTravel)))
        }
        if let sleep = monthAverageNightlySleep, sleep > 0 {
            metrics.append(.init(id: "sleep", icon: "bed.double.fill", title: "Sleep · Apple Health",
                                 value: formatHours(sleep / 3600), detail: "Nightly average", action: openSleep))
        } else if let steps = monthAverageDailySteps(monthSteps: monthSteps, interval: interval, now: now), steps > 0 {
            metrics.append(.init(id: "steps", icon: "shoeprints.fill", title: "Steps · Apple Health",
                                 value: "\(Int(steps.rounded()).formatted())/day", detail: "Daily average"))
        }

        let meaningful = metrics.filter { $0.detail != "This month" }
        return Array((meaningful + metrics.filter { $0.detail == "This month" }).prefix(4))
    }

    /// Keep the strongest comparison first, but rotate supporting cards by the
    /// selected period. This gives the carousel variety without it jumping around
    /// every time SwiftUI refreshes the screen.
    private func variedHighlights(_ candidates: [DayHighlight], interval: DateInterval) -> [DayHighlight] {
        guard candidates.count > 2, let primary = candidates.first else { return candidates }
        let supporting = Array(candidates.dropFirst())
        let periodNumber = Int(interval.start.timeIntervalSinceReferenceDate / (24 * 60 * 60))
        let offset = abs(periodNumber) % supporting.count
        let rotated = Array(supporting[offset...]) + Array(supporting[..<offset])
        return [primary] + rotated
    }

    /// Rebuilds `highlights` for the selected period — day/week/month's own
    /// steps and sleep (delegated to `health`, which also stores them for the
    /// metric tiles), the strongest category/place comparisons, the leading
    /// place's own retrospective (delegated to `retrospectives`), and a
    /// year-over-year comparison. `isStillCurrent` guards every `await` the
    /// same way `InsightsView`'s own tasks always did.
    func reloadHighlights(window: InsightWindow, interval: DateInterval, now: Date, anchorDate: Date,
                          scope: InsightsScope, snapshot: InsightsSnapshot, daySegments: [InsightSegment],
                          activityData: ActivityDataService, health: InsightsHealthState,
                          retrospectives: InsightsArchiveRetrospectives, context: ModelContext,
                          isStillCurrent: () -> Bool) async {
        var found: [DayHighlight] = []
        let queryEnd = interval.contains(now) ? now : interval.end
        let dayInterval = DateInterval(start: interval.start, end: max(interval.start, queryEnd))

        if window == .day {
            await health.reloadForDay(activityData: activityData, dayInterval: dayInterval, scope: scope)
            if let steps = health.todaySteps {
                let baseline = await activityData.stepHistory(
                    forSameWeekdayAs: interval.start,
                    through: interval.contains(now) ? now : nil,
                    weeks: 4
                )
                let weekday = interval.start.formatted(.dateTime.weekday(.wide))
                if let highlight = DayHighlights.steps(today: steps, weekdayBaseline: baseline,
                                                       weekdayName: weekday) {
                    found.append(highlight)
                }
            }
            if let night = health.lastNightSleep,
               let average = await activityData.averageNightlySleep(before: interval.start, nights: 14),
               let highlight = DayHighlights.sleep(lastNight: night.totalSleep, averageNight: average) {
                found.append(highlight)
            }
        } else if window == .week {
            await health.reloadForWeek(activityData: activityData, dayInterval: dayInterval,
                                       weekEnd: interval.end, scope: scope)
        } else if window == .month {
            await health.reloadForMonth(activityData: activityData, dayInterval: dayInterval, scope: scope)
        } else {
            health.clearForYear()
        }
        if let highlight = DayHighlights.activity(from: snapshot.comparisons, window: window) {
            found.append(highlight)
        }
        if let place = snapshot.placeTotals.first {
            if let highlight = DayHighlights.leadingPlace(place, window: window) {
                found.append(highlight)
            }
            let history = await retrospectives.placeHistory(matching: place.name, before: interval.end,
                                                             scope: scope, context: context)
            guard !Task.isCancelled, isStillCurrent() else { return }
            if let highlight = ArchiveRetrospectives.firstVisitToPlace(
                place, history: history, windowStart: interval.start, window: window
            ) {
                found.append(highlight)
            }
            if let highlight = ArchiveRetrospectives.longestAbsenceFromPlace(
                place, history: history, windowStart: interval.start
            ) {
                found.append(highlight)
            }
        }
        if let highlight = await retrospectives.yearOverYearHighlight(
            anchorDate: anchorDate, window: window, loggedHours: snapshot.loggedHours,
            scope: scope, now: now, context: context
        ) {
            found.append(highlight)
        }
        guard !Task.isCancelled, isStillCurrent() else { return }
        // Only `dayLayout` ever reads this (`highlights.first`), and only for
        // `window == .day` -- capped at three deliberately, a daily review
        // screen names what stood out rather than repeating every comparison
        // available. Still computed for every window, unread the rest of the
        // time; the underlying fetches already run off the main actor and are
        // bounded, so this is left alone rather than gating it on `window`.
        //
        // `found` is otherwise plain append order (steps, sleep, activity, leading
        // place, retrospectives, year-over-year), and steps is appended first and
        // almost always non-nil once a month of history exists -- including its own
        // honest "about the same" filler when nothing actually moved. Left as
        // append order, that filler structurally won `highlights.first` on most
        // days regardless of whether sleep or activity had a far bigger, genuinely
        // noteworthy swing that same day. `isNotable` (false only for that filler
        // and sleep's equivalent) moves any real finding ahead of it while leaving
        // relative order untouched within each tier -- `filter` is stable, so this
        // is a partition, not a re-sort by some new priority scheme.
        let ordered = variedHighlights(found.filter(\.isNotable) + found.filter { !$0.isNotable },
                                       interval: interval)
        highlights = window == .day ? Array(ordered.prefix(3)) : ordered
    }

    /// Loads the season of trend history Week's rolling baseline needs.
    ///
    /// A fetch of its own, deliberately separate from period preparation. That one
    /// is scoped tightly to the selected period and re-runs on every tap of the
    /// date arrows; this one reaches back up to a year and must not be dragged
    /// along with it. It is keyed to the week by the caller, so stepping through
    /// days never refetches.
    ///
    /// Runs entirely inside `InsightsTrendAggregator`, off the main actor — a year
    /// of history and its per-week segmenting no longer has to fit inside the
    /// interaction path.
    func reloadTrends(now: Date, scope: InsightsScope, context: ModelContext,
                      isStillCurrent: () -> Bool) async {
        let startedAt = Date.now
        let container = context.container
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try await InsightsTrendAggregator(modelContainer: container).load(
                    endingAt: now, scope: scope
                )
            }.value
            guard !Task.isCancelled, isStillCurrent() else { return }
            // Already the completed-weeks-only fetch Week's rolling baseline needs
            // -- `InsightsTrends.range` ends before the in-progress week, so this
            // can never include a partial week. Kept as the full fetched span
            // (not sliced to a fixed count here) so the Week section can choose
            // its own baseline width without a second fetch.
            weeklyBaselineTotals = data.weeklyTotals
            routineStability = data.routineStability
            Diagnostics.performance(context, subsystem: "Insights", operation: "trend history",
                                    startedAt: startedAt, itemCount: data.itemCount)
        } catch {
            // The rest of Insights is unaffected, so a trend that cannot be built is
            // simply not drawn rather than taken as a failure of the screen.
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "trend history fetch", severity: "warning")
            weeklyBaselineTotals = []
            routineStability = .empty(window: DateInterval(start: .distantPast, duration: 0))
        }
    }

    /// Year's own placeholder story, built the instant the period switches to
    /// Year — before the archive-scale historical-places fetch below completes
    /// — so the shell renders immediately with an empty historical-places set.
    /// Mirrors what `InsightsView.reloadInsights` used to do inline right after
    /// assigning `snapshot`. The caller is also responsible for setting
    /// `InsightsArchiveRetrospectives.annualPlacesLoading = true` alongside this
    /// — a separate model's state, not duplicated here.
    func beginYearPlaceholder(snapshot: InsightsSnapshot, interval: DateInterval, now: Date,
                              annualHealth: AnnualInsights.HealthMetrics) {
        annualInsights = AnnualInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                                             yearInterval: interval, now: now,
                                             historicalPlaceNames: [], health: annualHealth)
    }

    /// Year's deferred, archive-scale work: historical place names (from
    /// `retrospectives`) and the twelve months of Health metrics (from
    /// `health`) — both reached only after the current year's own story has
    /// already rendered from `beginYearPlaceholder`.
    func reloadAnnualHealth(window: InsightWindow, interval: DateInterval, now: Date, scope: InsightsScope,
                            snapshot: InsightsSnapshot, activityData: ActivityDataService,
                            health: InsightsHealthState, retrospectives: InsightsArchiveRetrospectives,
                            aggregationGeneration: Int, context: ModelContext,
                            isStillCurrent: () -> Bool) async {
        guard window == .year else { return }
        // Let the Year shell render before its archive-scale place-history work.
        await Task.yield()
        guard !Task.isCancelled, isStillCurrent() else { return }
        let historical = await retrospectives.annualHistoricalPlaces(
            before: interval.start, scope: scope, generation: aggregationGeneration, context: context
        )
        guard !Task.isCancelled, isStillCurrent() else { return }
        retrospectives.annualPlacesLoading = false
        guard scope.includesHealthData else {
            guard isStillCurrent() else { return }
            // `health.reloadAnnualHealth` itself sets `annualHealth = .empty` and
            // returns immediately when the scope excludes Health data — reused
            // here rather than duplicating that reset.
            await health.reloadAnnualHealth(activityData: activityData, year: interval, now: now,
                                            scope: scope, isStillCurrent: isStillCurrent)
            guard isStillCurrent() else { return }
            annualInsights = AnnualInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                                                 yearInterval: interval, now: now,
                                                 historicalPlaceNames: historical, health: health.annualHealth)
            return
        }
        annualInsights = AnnualInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                                             yearInterval: interval, now: now,
                                             historicalPlaceNames: historical, health: health.annualHealth)
        await health.reloadAnnualHealth(activityData: activityData, year: interval, now: now,
                                        scope: scope, isStillCurrent: isStillCurrent)
        guard !Task.isCancelled, isStillCurrent() else { return }
        annualInsights = AnnualInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                                             yearInterval: interval, now: now,
                                             historicalPlaceNames: historical, health: health.annualHealth)
    }
}
