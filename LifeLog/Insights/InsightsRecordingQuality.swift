import Foundation

/// The recording-quality insight: how much of the selected period has an actual
/// record behind it, the gaps and provisional rows that make up the rest, and
/// which individual days fell below a useful coverage bar.
///
/// Every number here is read off the same `InsightSegment`s and `Visit.resolutionState`
/// the donut, Timeline, and `ReviewQueue` already resolve -- see
/// `InsightsSnapshot.provisionalCount` for the identical `.provisional` filter this
/// mirrors -- so this can never disagree with what tapping through to a gap or a
/// visit shows. Pure and synchronous: it reads only the already-fetched period data
/// `InsightsPeriodLoader` holds, the same way `MonthlyInsights`/`ArchiveRetrospectives`
/// do, and issues no query of its own.
enum InsightsRecordingQuality {
    struct DayCoverage: Identifiable {
        let date: Date
        let loggedHours: Double
        let totalHours: Double
        var id: Date { date }
        var coverage: Double { totalHours > 0 ? min(1, loggedHours / totalHours) : 1 }
    }

    struct ProvisionalRow: Identifiable {
        let stableID: UUID
        let placeName: String
        let activity: String
        let start: Date
        var id: UUID { stableID }
    }

    struct Presentation {
        let coverage: Double
        let loggedHours: Double
        let totalHours: Double
        let gaps: [InsightSegment]
        let totalGapHours: Double
        let longestGap: InsightSegment?
        let provisionalRows: [ProvisionalRow]
        let daysBelowThreshold: [DayCoverage]
        let threshold: Double
        /// True for roughly the first day LifeLog has been able to record anything on
        /// this device. A low coverage percentage is expected and uninformative here --
        /// there just hasn't been much elapsed time to log yet -- so the card reads
        /// this instead of the same wording it uses once a real pattern of gaps exists.
        let isEarlyInObservation: Bool

        var gapCount: Int { gaps.count }
        /// Nothing to say yet about an empty or entirely future period -- not the
        /// same as a real period that turned out fully logged.
        var hasSignal: Bool { totalHours > 0.01 }
    }

    static let defaultThreshold = 0.5
    /// How long a low coverage percentage is attributed to "just started," not a
    /// real gap. Matches the day someone is most likely to open Insights minutes
    /// after installing and see almost none of the elapsed period logged yet.
    static let earlyObservationWindow: TimeInterval = 24 * 60 * 60

    static func make(segments: [InsightSegment], visits: [Visit], interval: DateInterval, now: Date,
                     observationStart: Date? = nil, threshold: Double = defaultThreshold) -> Presentation {
        let isEarlyInObservation = observationStart.map { now.timeIntervalSince($0) < earlyObservationWindow } ?? false
        let cappedEnd = min(interval.end, now)
        guard cappedEnd > interval.start else {
            return Presentation(coverage: 1, loggedHours: 0, totalHours: 0, gaps: [],
                                totalGapHours: 0, longestGap: nil, provisionalRows: [],
                                daysBelowThreshold: [], threshold: threshold,
                                isEarlyInObservation: isEarlyInObservation)
        }
        let elapsed = DateInterval(start: interval.start, end: cappedEnd)
        let totalHours = elapsed.duration / 3600
        let elapsedSegments = segments.filter { $0.start < cappedEnd }
        let loggedHours = elapsedSegments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        // Same 0.01h floor `InsightsView.unloggedSegments` already uses for "a real
        // gap worth naming" -- keeping this in step means the card's gap count
        // never disagrees with the existing Unlogged Time list it links to.
        let gaps = elapsedSegments.filter { $0.isUnlogged && $0.end <= cappedEnd && $0.hours > 0.01 }
            .sorted { $0.hours > $1.hours }
        let totalGapHours = gaps.reduce(0) { $0 + $1.hours }
        // Mirrors `InsightsSnapshot.provisionalCount`'s own `periodVisits` filter
        // exactly, so this card's count is the same number the donut/snapshot would
        // report for the identical period.
        let provisional = visits
            .filter { $0.overlaps(elapsed, now: now) && $0.resolutionState == .provisional }
            .sorted { $0.arrival < $1.arrival }
            .map { ProvisionalRow(stableID: $0.stableID, placeName: $0.displayPlaceName,
                                  activity: $0.suspectedActivity, start: $0.arrival) }
        let days = dayCoverage(segments: elapsedSegments, interval: elapsed)
        // Worst first: the day a person most needs to go fill in, not whichever
        // happens to fall earliest in the period.
        let below = days.filter { $0.totalHours > 0.01 && $0.coverage < threshold }
            .sorted { $0.coverage < $1.coverage }
        return Presentation(
            coverage: totalHours > 0 ? min(1, loggedHours / totalHours) : 1,
            loggedHours: loggedHours, totalHours: totalHours, gaps: gaps,
            totalGapHours: totalGapHours, longestGap: gaps.first,
            provisionalRows: provisional, daysBelowThreshold: below, threshold: threshold,
            isEarlyInObservation: isEarlyInObservation
        )
    }

    /// Splits already-resolved segments into calendar-day buckets, attributing an
    /// overnight segment's hours proportionally to each day it actually spans
    /// rather than crediting its whole duration to the day it started on.
    private static func dayCoverage(segments: [InsightSegment], interval: DateInterval,
                                    calendar: Calendar = .current) -> [DayCoverage] {
        var result: [DayCoverage] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
            let dayEnd = min(nextDay, interval.end)
            let dayStart = max(day, interval.start)
            guard dayEnd > dayStart else {
                day = nextDay
                continue
            }
            let loggedInDay = segments.filter { !$0.isUnlogged && $0.start < dayEnd && $0.end > dayStart }
                .reduce(0.0) { total, segment in
                    total + max(0, min(segment.end, dayEnd).timeIntervalSince(max(segment.start, dayStart))) / 3600
                }
            let totalInDay = dayEnd.timeIntervalSince(dayStart) / 3600
            result.append(DayCoverage(date: day, loggedHours: loggedInDay, totalHours: totalInDay))
            day = nextDay
        }
        return result
    }
}
