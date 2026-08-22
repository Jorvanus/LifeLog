import Foundation
import HealthKit
import Testing
@testable import LifeLog

struct HealthInsightsSummaryTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let interval = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 86_400)

    @Test("Heart-rate trend types use a rate unit")
    func heartRateTrendUnits() {
        let expected = HKUnit.count().unitDivided(by: .minute()).unitString
        #expect(HealthTrendMetric.restingHeartRate.unit.unitString == expected)
        #expect(HealthTrendMetric.walkingHeartRate.unit.unitString == expected)
        #expect(HealthTrendMetric.heartRateRecovery.unit.unitString == expected)
        #expect(HealthTrendMetric.respiratoryRate.unit.unitString == expected)
    }

    @Test("Additional Health Trends types have their documented display units")
    func additionalTrendUnits() {
        #expect(HealthTrendMetric.heartRateVariability.unit.unitString == HKUnit.secondUnit(with: .milli).unitString)
        #expect(HealthTrendMetric.cardioFitness.unit.unitString == HKUnit.literUnit(with: .milli)
            .unitDivided(by: .gramUnit(with: .kilo))
            .unitDivided(by: .minute()).unitString)
        #expect(HealthTrendMetric.walkingSpeed.unit.unitString == HKUnit.meter().unitDivided(by: .second()).unitString)
        #expect(HealthTrendMetric.walkingStepLength.unit.unitString == HKUnit.meterUnit(with: .centi).unitString)
    }

    @Test("No Health data produces an explicit empty summary")
    func noData() {
        let summary = HealthInsightsAggregation.summary(steps: [], walkingRunningMeters: [],
                                                        activeEnergyKilocalories: [], exerciseMinutes: [],
                                                        standHours: [], workouts: [], sleep: nil,
                                                        interval: interval, calendar: Calendar(identifier: .gregorian),
                                                        now: interval.end)
        #expect(!summary.hasData)
        #expect(summary.steps == nil)
        #expect(summary.source == "Apple Health")
    }

    @Test("Repeated Health deliveries with the same UUID count once")
    func duplicateSamples() {
        let sample = HealthQuantityFixture(id: id, start: interval.start, end: interval.end, value: 4_000)
        let summary = HealthInsightsAggregation.summary(steps: [sample, sample], walkingRunningMeters: [],
                                                        activeEnergyKilocalories: [], exerciseMinutes: [],
                                                        standHours: [], workouts: [], sleep: nil,
                                                        interval: interval, calendar: Calendar(identifier: .gregorian),
                                                        now: interval.end)
        #expect(summary.steps == 4_000)
    }

    /// Confirmed on-device 2026-08-22: Health overview read Steps 9,545 and
    /// Walk+Run 7.9 km against Apple Health's own 4,771 steps / 4 km for the same
    /// day -- both almost exactly 2x, consistent with an iPhone and a paired Watch
    /// each independently recording the same walking, as two samples with distinct
    /// UUIDs. UUID-based dedup alone cannot merge those; only HealthKit's own
    /// source-aware cumulative statistic can, which `ActivitySampleReader` now
    /// fetches separately and passes in as `stepsTotal`/`walkingRunningMetersTotal`.
    /// This must win over the naive raw-fixture sum whenever it's available.
    @Test("A supplied deduplicated total wins over the raw double-counted sample sum")
    func deduplicatedTotalOverridesRawSampleSum() {
        let phone = HealthQuantityFixture(id: id, start: interval.start, end: interval.end, value: 4_771)
        let watch = HealthQuantityFixture(id: UUID(), start: interval.start, end: interval.end, value: 4_774)
        let summary = HealthInsightsAggregation.summary(
            steps: [phone, watch], walkingRunningMeters: [], activeEnergyKilocalories: [],
            exerciseMinutes: [], standHours: [], workouts: [], sleep: nil,
            interval: interval, calendar: Calendar(identifier: .gregorian), now: interval.end,
            stepsTotal: 4_771
        )
        #expect(summary.steps == 4_771, "the deduplicated total, not phone + watch's 9,545")
    }

    @Test("Deleted samples disappear from the next aggregation")
    func deletedSample() {
        let sample = HealthQuantityFixture(id: id, start: interval.start, end: interval.end, value: 4_000)
        let withSample = HealthInsightsAggregation.summary(steps: [sample], walkingRunningMeters: [],
                                                           activeEnergyKilocalories: [], exerciseMinutes: [],
                                                           standHours: [], workouts: [], sleep: nil,
                                                           interval: interval, calendar: Calendar(identifier: .gregorian),
                                                           now: interval.end)
        let withoutSample = HealthInsightsAggregation.summary(steps: [], walkingRunningMeters: [],
                                                              activeEnergyKilocalories: [], exerciseMinutes: [],
                                                              standHours: [], workouts: [], sleep: nil,
                                                              interval: interval, calendar: Calendar(identifier: .gregorian),
                                                              now: interval.end)
        #expect(withSample.steps == 4_000)
        #expect(withoutSample.steps == nil)
    }

    @Test("Daily averages use calendar days across a DST boundary")
    func dstBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 10
        components.day = 3
        components.hour = 12
        let start = calendar.date(from: components)!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let first = HealthQuantityFixture(id: id, start: start, end: start.addingTimeInterval(60), value: 1_000)
        let second = HealthQuantityFixture(id: UUID(), start: calendar.date(byAdding: .day, value: 2, to: start)!,
                                           end: calendar.date(byAdding: .day, value: 2, to: start)!.addingTimeInterval(60), value: 3_000)
        let summary = HealthInsightsAggregation.summary(steps: [first, second], walkingRunningMeters: [],
                                                        activeEnergyKilocalories: [], exerciseMinutes: [],
                                                        standHours: [], workouts: [], sleep: nil,
                                                        interval: DateInterval(start: start, end: end),
                                                        calendar: calendar, now: end)
        #expect(summary.elapsedDays == 4)
        #expect(summary.averageDailySteps == 1_000)
        #expect(summary.activeStepDays == 2)
    }

    @Test("Current-day summaries use elapsed calendar days and update values")
    func currentDay() {
        let first = HealthQuantityFixture(id: id, start: interval.start, end: interval.start.addingTimeInterval(60), value: 1_000)
        let second = HealthQuantityFixture(id: UUID(), start: interval.start.addingTimeInterval(3_600),
                                           end: interval.start.addingTimeInterval(3_660), value: 500)
        let summary = HealthInsightsAggregation.summary(steps: [first, second], walkingRunningMeters: [],
                                                        activeEnergyKilocalories: [], exerciseMinutes: [],
                                                        standHours: [], workouts: [], sleep: nil,
                                                        interval: interval, calendar: Calendar.current,
                                                        now: interval.start.addingTimeInterval(7_200))
        #expect(summary.elapsedDays == 1)
        #expect(summary.averageDailySteps == 1_500)
    }

    @Test("Health signal summaries average duplicate-safe samples")
    func healthSignals() {
        let resting = HealthQuantityFixture(id: id, start: interval.start, end: interval.end, value: 60)
        let walking = HealthQuantityFixture(id: UUID(), start: interval.start, end: interval.end, value: 110)
        let breathing = HealthQuantityFixture(id: UUID(), start: interval.start, end: interval.end, value: 15)
        let summary = HealthInsightsAggregation.summary(
            steps: [], walkingRunningMeters: [], activeEnergyKilocalories: [], exerciseMinutes: [],
            standHours: [], workouts: [], sleep: nil, interval: interval,
            calendar: Calendar(identifier: .gregorian), restingHeartRate: [resting, resting],
            walkingHeartRate: [walking], respiratoryRate: [breathing],
            now: interval.end
        )
        #expect(summary.restingHeartRateBPM == 60)
        #expect(summary.walkingHeartRateBPM == 110)
        #expect(summary.respiratoryRate == 15)
        #expect(summary.hasData)
        // The duplicate `resting` sample (same id) must not inflate the count any
        // more than it inflates the average above -- both read off the same
        // deduplicated list.
        #expect(summary.restingHeartRateSampleCount == 1)
        #expect(summary.walkingHeartRateSampleCount == 1)
        #expect(summary.respiratoryRateSampleCount == 1)
    }

    @Test("A heart-rate-recovery sample attaches to the workout it followed, not a period average")
    func heartRateRecoveryAttachesToItsWorkout() {
        let workoutEnd = interval.start.addingTimeInterval(30 * 60)
        let workout = HealthWorkoutFixture(id: UUID(), type: "Running", start: interval.start,
                                           end: workoutEnd, distanceMeters: 5_000)
        // Two minutes after the workout ends -- well within the matching window.
        let recovery = HealthQuantityFixture(id: UUID(), start: workoutEnd.addingTimeInterval(2 * 60),
                                             end: workoutEnd.addingTimeInterval(2 * 60), value: 28)
        let summary = HealthInsightsAggregation.summary(
            steps: [], walkingRunningMeters: [], activeEnergyKilocalories: [], exerciseMinutes: [],
            standHours: [], workouts: [workout], sleep: nil, interval: interval,
            calendar: Calendar(identifier: .gregorian), heartRateRecovery: [recovery],
            now: interval.end
        )
        #expect(summary.workouts.first?.heartRateRecoveryBPM == 28)
    }

    @Test("A recovery sample outside the matching window, or with no workout at all, is dropped")
    func heartRateRecoveryIgnoresUnmatchedSamples() {
        let workoutEnd = interval.start.addingTimeInterval(30 * 60)
        let workout = HealthWorkoutFixture(id: UUID(), type: "Running", start: interval.start,
                                           end: workoutEnd, distanceMeters: 5_000)
        // 20 minutes after the workout ends -- past the matching window.
        let tooLate = HealthQuantityFixture(id: UUID(), start: workoutEnd.addingTimeInterval(20 * 60),
                                            end: workoutEnd.addingTimeInterval(20 * 60), value: 28)
        let summary = HealthInsightsAggregation.summary(
            steps: [], walkingRunningMeters: [], activeEnergyKilocalories: [], exerciseMinutes: [],
            standHours: [], workouts: [workout], sleep: nil, interval: interval,
            calendar: Calendar(identifier: .gregorian), heartRateRecovery: [tooLate],
            now: interval.end
        )
        #expect(summary.workouts.first?.heartRateRecoveryBPM == nil)
    }

    @Test("Each workout claims its own closest recovery sample when several are close together")
    func heartRateRecoveryMatchesTheClosestWorkout() {
        let firstEnd = interval.start.addingTimeInterval(30 * 60)
        let secondEnd = firstEnd.addingTimeInterval(20 * 60)
        let first = HealthWorkoutFixture(id: UUID(), type: "Running", start: interval.start,
                                         end: firstEnd, distanceMeters: 5_000)
        let second = HealthWorkoutFixture(id: UUID(), type: "Cycling", start: firstEnd.addingTimeInterval(5 * 60),
                                          end: secondEnd, distanceMeters: 10_000)
        // One minute after each workout's own end -- each sample belongs to the
        // workout it immediately follows, not whichever one is scanned first.
        let firstRecovery = HealthQuantityFixture(id: UUID(), start: firstEnd.addingTimeInterval(60),
                                                   end: firstEnd.addingTimeInterval(60), value: 30)
        let secondRecovery = HealthQuantityFixture(id: UUID(), start: secondEnd.addingTimeInterval(60),
                                                    end: secondEnd.addingTimeInterval(60), value: 22)
        let summary = HealthInsightsAggregation.summary(
            steps: [], walkingRunningMeters: [], activeEnergyKilocalories: [], exerciseMinutes: [],
            standHours: [], workouts: [first, second], sleep: nil, interval: interval,
            calendar: Calendar(identifier: .gregorian), heartRateRecovery: [firstRecovery, secondRecovery],
            now: interval.end
        )
        #expect(summary.workouts.first { $0.type == "Running" }?.heartRateRecoveryBPM == 30)
        #expect(summary.workouts.first { $0.type == "Cycling" }?.heartRateRecoveryBPM == 22)
    }

    @Test("Month changes require absolute and relative movement")
    func meaningfulChange() {
        #expect(HealthInsightsSummary.meaningfulChange(current: 5_400, previous: 5_000, minimum: 500) == nil)
        #expect(HealthInsightsSummary.meaningfulChange(current: 6_000, previous: 5_000, minimum: 500) == 1_000)
    }

    @Test("Workout types use human-readable names")
    func workoutTypeNames() {
        #expect(HealthInsightsSummary.knownWorkoutTypeName(rawValue: 52) == "Walking")
        #expect(HealthInsightsSummary.knownWorkoutTypeName(rawValue: 37) == "Running")
        #expect(HealthInsightsSummary.knownWorkoutTypeName(rawValue: 999) == nil)
    }

    @Test("Sleep timing baseline wraps around midnight")
    func sleepTimingBaselineWrapsAcrossMidnight() {
        let baseline = SleepPatternBaseline(averageDuration: 7 * 60 * 60,
                                            usualStartMinute: 23 * 60 + 45, nights: 14)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17,
                                                               hour: 0, minute: 15))!

        #expect(baseline.timingDifference(from: afterMidnight, calendar: calendar) == 30)
    }
}
