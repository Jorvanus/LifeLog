import Foundation

/// Weekday arrival/departure ranges for explicit Home/Work roles, sleep timing
/// regularity, and commute duration stability -- all read off the same resolved
/// `InsightSegment`s (and `SavedPlaceRole`/`CommuteDetection`) the donut, Timeline,
/// and Week's own commute summary already use. Nothing here has a separate
/// definition of "a Home visit" or "a commute" that could quietly disagree with
/// what those already say.
///
/// Every conclusion is gated on two things: the same period's recording coverage
/// (see `InsightsRecordingQuality`) not being too poor to trust, and having enough
/// distinct days behind a specific bucket. A person who mostly doesn't log data, or
/// has only been to Work twice, should see "not enough data yet" rather than a
/// confident-looking number built from a handful of days and a lot of gaps.
enum InsightsRoutineStability {
    /// How many separate days a weekday bucket needs before its median/spread says
    /// anything -- a single early meeting should not read as "this is now your
    /// Tuesday." Slightly higher than `minimumCommuteSamples` because a weekday
    /// bucket is inherently a seventh of the sample.
    static let minimumWeekdaySamples = 3
    /// Nights of sleep. Matches `ActivityDataService.sleepPatternBaseline`'s own
    /// bar for the same reason: three completed nights is the threshold this
    /// codebase already uses before calling a sleep pattern a pattern.
    static let minimumSleepSamples = 3
    /// Matches `InsightsSnapshot.minimumConfidentCommuteDays` -- the lowest bar
    /// already established, for the identical reason it exists there. A literal
    /// rather than a reference to that `@MainActor`-isolated constant, since this
    /// type is deliberately nonisolated so `InsightsTrendAggregator` can call it
    /// off the main actor.
    static let minimumCommuteSamples = 2
    /// Below this, coverage itself is too poor to trust any conclusion built on
    /// top of it. Reuses `InsightsRecordingQuality`'s own threshold rather than a
    /// second number that could drift from it.
    static let coverageThreshold = InsightsRecordingQuality.defaultThreshold

    /// A single time-of-day statistic, e.g. "usually arrives around 18:20, give or
    /// take 25 minutes." Computed with a circular rotation (see `timeOfDayStat`)
    /// so a run of times either side of midnight -- sleep start, most of all --
    /// reads as one cluster rather than two.
    struct TimeOfDayStat: Sendable {
        let medianMinutes: Double
        let spreadMinutes: Double
        let sampleCount: Int
    }

    struct WeekdayRoutine: Identifiable, Sendable {
        let weekday: Int
        let arrival: TimeOfDayStat?
        let departure: TimeOfDayStat?
        var id: Int { weekday }
    }

    struct DurationStat: Sendable {
        let medianMinutes: Double
        let spreadMinutes: Double
        let sampleCount: Int
    }

    struct SleepStat: Sendable {
        let start: TimeOfDayStat
        let end: TimeOfDayStat
    }

    struct Presentation: Sendable {
        let sampleWindow: DateInterval
        let coverage: Double
        let hasEnoughCoverage: Bool
        let homeWeekdays: [WeekdayRoutine]
        let workWeekdays: [WeekdayRoutine]
        let sleep: SleepStat?
        let commute: DurationStat?

        static func empty(window: DateInterval) -> Presentation {
            Presentation(sampleWindow: window, coverage: 0, hasEnoughCoverage: false,
                        homeWeekdays: [], workWeekdays: [], sleep: nil, commute: nil)
        }

        /// Coverage was good enough to look, but nothing cleared its own
        /// distinct-day bar -- a real answer, "not yet," distinct from
        /// `hasEnoughCoverage == false`, which is "the data itself isn't trustworthy."
        var hasAnyConclusion: Bool {
            hasEnoughCoverage && (!homeWeekdays.isEmpty || !workWeekdays.isEmpty || sleep != nil || commute != nil)
        }
    }

    /// `segments`/`visits` should already be scoped to `window` -- see
    /// `InsightsTrendAggregator.load`, which builds both over the same season of
    /// history the weekly-rhythm chart reads. `commutes` may be resolved over a
    /// wider span (commute detection has no window of its own); this filters them
    /// to `window` itself before use.
    static func make(segments: [InsightSegment], visits: [Visit], commutes: [Commute],
                     savedPlaces: [SavedPlace], window: DateInterval, now: Date,
                     calendar: Calendar = .current) -> Presentation {
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: window, now: now)
        guard quality.hasSignal, quality.coverage >= coverageThreshold else {
            return Presentation(sampleWindow: window, coverage: quality.coverage, hasEnoughCoverage: false,
                                homeWeekdays: [], workWeekdays: [], sleep: nil, commute: nil)
        }
        let windowedCommutes = commutes.filter { $0.start >= window.start && $0.start < window.end }
        return Presentation(
            sampleWindow: window, coverage: quality.coverage, hasEnoughCoverage: true,
            homeWeekdays: weekdayRoutines(segments: segments, role: .home, savedPlaces: savedPlaces, now: now, calendar: calendar),
            workWeekdays: weekdayRoutines(segments: segments, role: .work, savedPlaces: savedPlaces, now: now, calendar: calendar),
            sleep: sleepRegularity(segments: segments, calendar: calendar),
            commute: commuteStability(commutes: windowedCommutes, calendar: calendar)
        )
    }

    /// One row per weekday with enough distinct days at this role, built from the
    /// unique resolved visits behind `segments` -- not the segments' own (possibly
    /// slice-clipped) start/end, so an interrupted Home stay's boundary slices
    /// don't masquerade as several separate arrivals.
    private static func weekdayRoutines(segments: [InsightSegment], role: SavedPlaceRole, savedPlaces: [SavedPlace],
                                        now: Date, calendar: Calendar) -> [WeekdayRoutine] {
        var seen = Set<ObjectIdentifier>()
        var arrivalsByWeekday: [Int: [Date]] = [:]
        var departuresByWeekday: [Int: [Date]] = [:]
        for segment in segments {
            guard !segment.isUnlogged, let visit = segment.visit, !visit.hasPlaceholderName,
                  SavedPlaceRole.of(visit, in: savedPlaces) == role,
                  seen.insert(ObjectIdentifier(visit)).inserted else { continue }
            let weekday = calendar.component(.weekday, from: visit.arrival)
            arrivalsByWeekday[weekday, default: []].append(visit.arrival)
            departuresByWeekday[weekday, default: []].append(min(visit.departure ?? now, now))
        }
        return (1...7).compactMap { weekday -> WeekdayRoutine? in
            let arrivals = arrivalsByWeekday[weekday] ?? []
            let distinctDays = Set(arrivals.map { calendar.startOfDay(for: $0) }).count
            guard distinctDays >= minimumWeekdaySamples else { return nil }
            return WeekdayRoutine(weekday: weekday,
                                  arrival: timeOfDayStat(arrivals, calendar: calendar),
                                  departure: timeOfDayStat(departuresByWeekday[weekday] ?? [], calendar: calendar))
        }
    }

    /// Every resolved sleep-labelled visit in the window, deduplicated the same
    /// way `weekdayRoutines` is -- see `InsightSegment.isSleep`.
    private static func sleepRegularity(segments: [InsightSegment], calendar: Calendar) -> SleepStat? {
        var seen = Set<ObjectIdentifier>()
        var starts: [Date] = []
        var ends: [Date] = []
        for segment in segments {
            guard !segment.isUnlogged, segment.isSleep, let visit = segment.visit,
                  seen.insert(ObjectIdentifier(visit)).inserted else { continue }
            starts.append(visit.arrival)
            if let departure = visit.departure { ends.append(departure) }
        }
        let distinctNights = Set(starts.map { calendar.startOfDay(for: $0) }).count
        guard distinctNights >= minimumSleepSamples,
              let startStat = timeOfDayStat(starts, calendar: calendar),
              let endStat = timeOfDayStat(ends, calendar: calendar) else { return nil }
        return SleepStat(start: startStat, end: endStat)
    }

    private static func commuteStability(commutes: [Commute], calendar: Calendar) -> DurationStat? {
        let distinctDays = Set(commutes.map { calendar.startOfDay(for: $0.start) }).count
        guard distinctDays >= minimumCommuteSamples else { return nil }
        return durationStat(commutes.map(\.duration))
    }

    /// Rotates any time before 6am forward by a day before taking the median, so a
    /// cluster of times either side of midnight (23:40, 00:10, 23:55…) reads as one
    /// tight group instead of two far-apart ones. Mirrors the same rotate-then-wrap
    /// approach `ActivityDataService.sleepPatternBaseline` already uses for its own
    /// mean sleep-start time, applied here to a median instead.
    private static func timeOfDayStat(_ dates: [Date], calendar: Calendar) -> TimeOfDayStat? {
        guard !dates.isEmpty else { return nil }
        let raw = dates.map { minutesSinceMidnight($0, calendar: calendar) }
        let rotated = raw.map { $0 < 360 ? $0 + 1_440 : $0 }
        let med = median(rotated)
        let spread = median(rotated.map { abs($0 - med) })
        return TimeOfDayStat(medianMinutes: med.truncatingRemainder(dividingBy: 1_440),
                             spreadMinutes: spread, sampleCount: dates.count)
    }

    private static func durationStat(_ durations: [TimeInterval]) -> DurationStat? {
        guard !durations.isEmpty else { return nil }
        let minutes = durations.map { $0 / 60 }
        let med = median(minutes)
        let spread = median(minutes.map { abs($0 - med) })
        return DurationStat(medianMinutes: med, spreadMinutes: spread, sampleCount: durations.count)
    }

    private static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
    }

    /// The median absolute deviation's median step reuses this too: robust to the
    /// occasional very-late night or very-long commute in a way a mean/standard
    /// deviation is not.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
