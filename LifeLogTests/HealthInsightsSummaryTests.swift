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
        let recovery = HealthQuantityFixture(id: UUID(), start: interval.start, end: interval.end, value: 35)
        let breathing = HealthQuantityFixture(id: UUID(), start: interval.start, end: interval.end, value: 15)
        let summary = HealthInsightsAggregation.summary(
            steps: [], walkingRunningMeters: [], activeEnergyKilocalories: [], exerciseMinutes: [],
            standHours: [], workouts: [], sleep: nil, interval: interval,
            calendar: Calendar(identifier: .gregorian), restingHeartRate: [resting, resting],
            walkingHeartRate: [walking], heartRateRecovery: [recovery], respiratoryRate: [breathing],
            now: interval.end
        )
        #expect(summary.restingHeartRateBPM == 60)
        #expect(summary.walkingHeartRateBPM == 110)
        #expect(summary.heartRateRecoveryBPM == 35)
        #expect(summary.respiratoryRate == 15)
        #expect(summary.hasData)
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
