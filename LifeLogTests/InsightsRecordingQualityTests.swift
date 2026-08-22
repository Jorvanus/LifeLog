import Foundation
import Testing
@testable import LifeLog

/// `InsightsRecordingQuality.make` is pure over already-resolved `InsightSegment`s
/// and `Visit`s, mirroring `InsightsSnapshot.provisionalCount`'s own `.provisional`
/// filter -- see that type's doc comment. These tests build segments through
/// `InsightsSnapshot.makeSegments`, the same production path Week/Month use, so a
/// passing test proves the card agrees with what Insights itself would show.
@MainActor
struct InsightsRecordingQualityTests {
    private let day = insightsFixtureDay

    private func stay(dayOffset: Int, startHour: Double, endHour: Double, resolutionState: VisitResolutionState = .resolved) -> Visit {
        let base = day.addingTimeInterval(Double(dayOffset) * 24 * 3_600)
        return Visit(arrival: base.addingTimeInterval(startHour * 3_600),
                     departure: base.addingTimeInterval(endHour * 3_600),
                     latitude: -23.378, longitude: 150.511,
                     placeName: "Home", inferredActivity: "At home", userActivity: "At home",
                     source: "automatic", recognitionConfidence: "confirmed",
                     resolutionState: resolutionState)
    }

    private func threeDayInterval() -> DateInterval {
        DateInterval(start: day, end: day.addingTimeInterval(3 * 24 * 3_600))
    }

    @Test("A fully covered period has 100% coverage, no gaps, and no low-coverage days")
    func fullyCoveredPeriod() {
        let interval = threeDayInterval()
        let visits = (0..<3).map { stay(dayOffset: $0, startHour: 0, endHour: 24) }
        let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: visits, range: interval, now: interval.end)
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: interval, now: interval.end)
        #expect(quality.coverage == 1)
        #expect(quality.gapCount == 0)
        #expect(quality.daysBelowThreshold.isEmpty)
        #expect(quality.provisionalRows.isEmpty)
    }

    @Test("A day with nothing recorded is a gap, lowers coverage, and is flagged below threshold")
    func oneUnloggedDayLowersCoverageAndIsFlagged() {
        let interval = threeDayInterval()
        // Day 1 (the middle day) has no visit at all.
        let visits = [stay(dayOffset: 0, startHour: 0, endHour: 24), stay(dayOffset: 2, startHour: 0, endHour: 24)]
        let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: visits, range: interval, now: interval.end)
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: interval, now: interval.end)
        #expect(quality.coverage > 0 && quality.coverage < 1)
        #expect(quality.gapCount == 1)
        #expect(quality.longestGap?.hours == 24)
        #expect(quality.totalGapHours == 24)
        #expect(quality.daysBelowThreshold.count == 1)
        #expect(quality.daysBelowThreshold.first?.coverage == 0)
        let flaggedDay = quality.daysBelowThreshold.first?.date
        let middleDayStart = Calendar.current.startOfDay(for: day.addingTimeInterval(24 * 3_600))
        #expect(flaggedDay == middleDayStart)
    }

    @Test("A provisional visit is counted; a resolved one is not")
    func provisionalRowsMatchResolutionState() {
        let interval = threeDayInterval()
        let visits = [
            stay(dayOffset: 0, startHour: 0, endHour: 12, resolutionState: .provisional),
            stay(dayOffset: 0, startHour: 12, endHour: 24, resolutionState: .resolved),
        ]
        let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: visits, range: interval, now: interval.end)
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: interval, now: interval.end)
        #expect(quality.provisionalRows.count == 1)
        #expect(quality.provisionalRows.first?.stableID == visits[0].stableID)
    }

    @Test("A period with nothing elapsed yet reports no signal rather than a false 0%")
    func futurePeriodHasNoSignal() {
        let interval = threeDayInterval()
        let quality = InsightsRecordingQuality.make(segments: [], visits: [], interval: interval, now: interval.start)
        #expect(!quality.hasSignal)
        #expect(quality.daysBelowThreshold.isEmpty)
    }

    @Test("Coverage and gaps stop at now; a day that has not happened yet is never flagged")
    func onlyElapsedTimeIsMeasured() {
        let interval = threeDayInterval()
        let now = day.addingTimeInterval(30 * 3_600) // 6 hours into day 1
        let visits = [stay(dayOffset: 0, startHour: 0, endHour: 24)]
        let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: visits, range: interval, now: now)
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: interval, now: now)
        #expect(quality.totalHours == 30)
        // Day 1 is only 6 hours old and fully unlogged so far -- flagged, but as a
        // partial day, not a full 24-hour one.
        #expect(quality.daysBelowThreshold.count == 1)
        #expect(quality.daysBelowThreshold.first?.totalHours == 6)
        #expect(quality.daysBelowThreshold.first?.loggedHours == 0)
    }

    @Test("Days below threshold are ordered worst coverage first, not chronologically")
    func daysBelowThresholdAreSortedByCoverage() {
        // A ten-day period: day 0 mostly logged (worst-but-one), day 1 fully
        // unlogged (worst), the rest untouched -- also below the 50% bar, but
        // less badly than either. Chronological order would put day 0 first;
        // worst-first should put day 1 first, then day 0.
        let interval = DateInterval(start: day, end: day.addingTimeInterval(10 * 24 * 3_600))
        let visits = [stay(dayOffset: 0, startHour: 0, endHour: 20)]
        let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: visits, range: interval, now: interval.end)
        let quality = InsightsRecordingQuality.make(segments: segments, visits: visits, interval: interval, now: interval.end)
        let coverages = quality.daysBelowThreshold.map(\.coverage)
        #expect(coverages == coverages.sorted())
        #expect(quality.daysBelowThreshold.first?.date == day.addingTimeInterval(24 * 3_600))
    }

    @Test("A low-coverage period within a day of observation starting reads as early, not a gap")
    func recentObservationStartReadsAsEarly() {
        let interval = threeDayInterval()
        let observationStart = day
        let now = day.addingTimeInterval(2 * 3_600) // two hours after LifeLog started observing
        let quality = InsightsRecordingQuality.make(segments: [], visits: [], interval: interval, now: now,
                                                     observationStart: observationStart)
        #expect(quality.isEarlyInObservation)
    }

    @Test("The same low coverage a full day after observation started is a real gap, not early")
    func observationStartOverADayAgoIsNotEarly() {
        let interval = threeDayInterval()
        let observationStart = day
        let now = day.addingTimeInterval(25 * 3_600) // just over a day after LifeLog started observing
        let quality = InsightsRecordingQuality.make(segments: [], visits: [], interval: interval, now: now,
                                                     observationStart: observationStart)
        #expect(!quality.isEarlyInObservation)
    }

    @Test("No known observation start is never treated as early")
    func noObservationStartIsNeverEarly() {
        let interval = threeDayInterval()
        let quality = InsightsRecordingQuality.make(segments: [], visits: [], interval: interval, now: interval.end)
        #expect(!quality.isEarlyInObservation)
    }
}
