import Foundation

/// Health-derived figures Day/Week/Month/Year show — steps, sleep, the Health
/// summary card's current/previous figures, and Year's twelve monthly points.
///
/// Extracted from `InsightsView` so this fetching can be exercised without a
/// live `View`. `InsightsView` still decides *when* to reload (its own
/// `.task(id:)` keys, built from `window`/`anchorDate`/scope/generation);
/// this only owns *what* each reload fetches and stores. Exactly one of
/// Day/Week/Month's own fields is ever populated at a time, matching how
/// only one layout is ever visible — each `reloadForX` clears the others.
@MainActor @Observable
final class InsightsHealthState {
    private(set) var todaySteps: Double?
    private(set) var lastNightSleep: SleepSummary?
    private(set) var weekSteps: Double?
    private(set) var weekAverageNightlySleep: TimeInterval?
    private(set) var monthSteps: Double?
    private(set) var monthAverageNightlySleep: TimeInterval?
    private(set) var healthSummary: HealthInsightsSummary?
    private(set) var previousHealthSummary: HealthInsightsSummary?
    private(set) var annualHealth = AnnualInsights.HealthMetrics.empty
    private(set) var monthDailyHealth = MonthlyInsights.HealthMetrics.empty

    /// Day's steps and last night's sleep, over `dayInterval` (already capped
    /// at `now` for today by the caller, same as every other period fetch here).
    func reloadForDay(activityData: ActivityDataService, dayInterval: DateInterval,
                      scope: InsightsScope) async {
        weekSteps = nil; weekAverageNightlySleep = nil
        monthSteps = nil; monthAverageNightlySleep = nil
        todaySteps = scope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
        lastNightSleep = scope.includesHealthData ? await activityData.sleepSummary(for: dayInterval) : nil
    }

    /// Week's total steps and its nightly sleep average — one call per metric
    /// over the week's own interval, not seven daily calls.
    func reloadForWeek(activityData: ActivityDataService, dayInterval: DateInterval,
                       weekEnd: Date, scope: InsightsScope) async {
        todaySteps = nil; lastNightSleep = nil
        monthSteps = nil; monthAverageNightlySleep = nil
        weekSteps = scope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
        weekAverageNightlySleep = scope.includesHealthData
            ? await activityData.averageNightlySleep(before: weekEnd, nights: 7)
            : nil
    }

    /// Month's total steps and its nightly sleep average, over the elapsed
    /// nights so a current month is not diluted by future dates.
    func reloadForMonth(activityData: ActivityDataService, dayInterval: DateInterval,
                        scope: InsightsScope) async {
        todaySteps = nil; lastNightSleep = nil
        weekSteps = nil; weekAverageNightlySleep = nil
        monthSteps = scope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
        let elapsedSeconds = max(0, dayInterval.duration)
        let elapsedNights = max(1, Int(ceil(elapsedSeconds / 86_400)))
        monthAverageNightlySleep = scope.includesHealthData
            ? await activityData.averageNightlySleep(before: dayInterval.end, nights: elapsedNights)
            : nil
    }

    /// Year shows none of Day/Week/Month's own steps/sleep fields — only
    /// `annualHealth`'s twelve monthly points, reloaded separately.
    func clearForYear() {
        todaySteps = nil; lastNightSleep = nil
        weekSteps = nil; weekAverageNightlySleep = nil
        monthSteps = nil; monthAverageNightlySleep = nil
    }

    /// Reloads the Health summary card's current/previous figures. `window`
    /// decides whether a previous-period comparison is fetched at all — only
    /// Month currently shows one. `isStillCurrent` is re-checked after every
    /// `await`, the same defence `InsightsView`'s own `.task(id:)` bodies
    /// already used before this moved — cooperative cancellation only takes
    /// effect at the next suspension point, not immediately.
    func reloadHealthSummary(activityData: ActivityDataService, interval: DateInterval, now: Date,
                             window: InsightWindow, scope: InsightsScope,
                             isStillCurrent: () -> Bool) async {
        guard scope.includesHealthData else {
            healthSummary = nil
            previousHealthSummary = nil
            return
        }
        let current = InsightsPeriodComparison.clamped(interval, now: now)
        let summary = await activityData.healthSummary(for: current)
        guard !Task.isCancelled, isStillCurrent() else { return }
        healthSummary = summary
        if window == .month {
            // `current`, not the raw `interval` — comparing a partial current
            // month's Health figures against a *complete* previous month
            // silently made every early-month Health comparison meaningless.
            let previous = window.previousComparisonInterval(for: current)
            let previousSummary = await activityData.healthSummary(for: previous)
            guard !Task.isCancelled, isStillCurrent() else { return }
            previousHealthSummary = previousSummary
        } else {
            previousHealthSummary = nil
        }
    }

    /// Year's twelve monthly points — sleep, steps, walking distance, active
    /// energy, exercise minutes, workout minutes, and stand hours, one
    /// `healthSummary`/`stepCount` pair per month up to `now`. `annualHealth`
    /// is only assigned once, after every month has been read — matching the
    /// original inline implementation, which never updated it progressively.
    func reloadAnnualHealth(activityData: ActivityDataService, year: DateInterval, now: Date,
                            scope: InsightsScope, isStillCurrent: () -> Bool) async {
        guard scope.includesHealthData else {
            annualHealth = .empty
            return
        }
        let calendar = Calendar.current
        var sleep: [Double?] = []
        var steps: [Double?] = []
        var walking: [Double?] = []
        var energy: [Double?] = []
        var exercise: [Double?] = []
        var workouts: [Double?] = []
        var stand: [Double?] = []
        var cursor = year.start
        var hasHealthData = false
        while cursor < year.end {
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            let monthEnd = min(next, min(year.end, now))
            if monthEnd <= cursor {
                sleep.append(nil)
                steps.append(nil)
                walking.append(nil); energy.append(nil); exercise.append(nil); workouts.append(nil); stand.append(nil)
            } else {
                let month = DateInterval(start: cursor, end: monthEnd)
                let summary = await activityData.healthSummary(for: month)
                let monthSteps = await activityData.stepCount(for: month)
                guard !Task.isCancelled, isStillCurrent() else { return }
                let sleepValue = summary?.sleep.map { $0.totalSleep / max(1, month.duration / 86_400) / 3600 }
                sleep.append(sleepValue)
                steps.append(monthSteps.map { $0 / max(1, month.duration / 86_400) })
                walking.append(summary?.walkingRunningMeters.map { $0 / 1_000 })
                energy.append(summary?.activeEnergyKilocalories)
                exercise.append(summary?.exerciseMinutes)
                workouts.append(summary.flatMap { $0.workouts.isEmpty ? nil : $0.workoutMinutes })
                stand.append(summary?.standHours)
                hasHealthData = hasHealthData || summary?.hasData == true
            }
            cursor = next
        }
        annualHealth = AnnualInsights.HealthMetrics(monthlySleepHours: sleep,
                                                    monthlySteps: steps,
                                                    monthlyWalkingKilometres: walking,
                                                    monthlyActiveEnergy: energy,
                                                    monthlyExerciseMinutes: exercise,
                                                    monthlyWorkoutMinutes: workouts,
                                                    monthlyStandHours: stand,
                                                    healthDataAvailable: hasHealthData)
    }

    /// Month's daily points -- the same idea as `reloadAnnualHealth`'s twelve
    /// monthly points, just one `healthSummary`/`stepCount` pair per day of
    /// the month instead of per month of the year. Sleep and steps need no
    /// per-bucket averaging the way the annual version divides by days in the
    /// month: each bucket here already *is* one day.
    func reloadMonthDailyHealth(activityData: ActivityDataService, monthInterval: DateInterval, now: Date,
                                scope: InsightsScope, isStillCurrent: () -> Bool) async {
        guard scope.includesHealthData else {
            monthDailyHealth = .empty
            return
        }
        let calendar = Calendar.current
        var days: [Date] = []
        var sleep: [Double?] = []
        var steps: [Double?] = []
        var walking: [Double?] = []
        var energy: [Double?] = []
        var exercise: [Double?] = []
        var workouts: [Double?] = []
        var cursor = monthInterval.start
        var hasHealthData = false
        while cursor < monthInterval.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            days.append(cursor)
            let dayEnd = min(next, min(monthInterval.end, now))
            if dayEnd <= cursor {
                sleep.append(nil)
                steps.append(nil)
                walking.append(nil); energy.append(nil); exercise.append(nil); workouts.append(nil)
            } else {
                let day = DateInterval(start: cursor, end: dayEnd)
                let summary = await activityData.healthSummary(for: day)
                let daySteps = await activityData.stepCount(for: day)
                guard !Task.isCancelled, isStillCurrent() else { return }
                sleep.append(summary?.sleep.map { $0.totalSleep / 3_600 })
                steps.append(daySteps)
                walking.append(summary?.walkingRunningMeters.map { $0 / 1_000 })
                energy.append(summary?.activeEnergyKilocalories)
                exercise.append(summary?.exerciseMinutes)
                workouts.append(summary.flatMap { $0.workouts.isEmpty ? nil : $0.workoutMinutes })
                hasHealthData = hasHealthData || summary?.hasData == true
            }
            cursor = next
        }
        monthDailyHealth = MonthlyInsights.HealthMetrics(days: days, dailySleepHours: sleep, dailySteps: steps,
                                                          dailyWalkingKilometres: walking, dailyActiveEnergy: energy,
                                                          dailyExerciseMinutes: exercise, dailyWorkoutMinutes: workouts,
                                                          healthDataAvailable: hasHealthData)
    }
}
