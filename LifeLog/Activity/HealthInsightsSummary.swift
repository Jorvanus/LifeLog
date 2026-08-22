import Foundation

/// Health values used by Insights. The source is intentionally explicit so a
/// Health-derived number cannot be mistaken for a location-derived Visit.
struct HealthInsightsSummary: Equatable, Sendable {
    struct Workout: Identifiable, Equatable, Sendable {
        let id: UUID
        let type: String
        let duration: TimeInterval
        let distanceMeters: Double?
        // The one-minute heart-rate recovery Apple scored for this specific
        // workout, when it has one. Deliberately per-workout rather than a
        // period average: a hard run and a gentle walk recover completely
        // differently, and blending them into one number would describe
        // neither. Nil is a real, expected answer -- recovery needs a
        // supported workout type tracked with a paired Watch, so plenty of
        // real workouts never get one.
        let heartRateRecoveryBPM: Double?

        var minutes: Double { duration / 60 }
    }

    let steps: Double?
    let walkingRunningMeters: Double?
    let activeEnergyKilocalories: Double?
    let exerciseMinutes: Double?
    let standHours: Double?
    let restingHeartRateBPM: Double?
    let walkingHeartRateBPM: Double?
    let respiratoryRate: Double?
    // How many distinct readings each average above was computed from. A period
    // average built from one reading and one built from thirty look identical as
    // a bare number; these let the display say which it was rather than imply a
    // stable trend either way.
    let restingHeartRateSampleCount: Int
    let walkingHeartRateSampleCount: Int
    let respiratoryRateSampleCount: Int
    let workouts: [Workout]
    let sleep: SleepSummary?
    let activeStepDays: Int
    let elapsedDays: Int
    let source: String
    let lastSuccessfulImport: Date?

    var averageDailySteps: Double? {
        guard let steps, elapsedDays > 0 else { return nil }
        return steps / Double(elapsedDays)
    }

    var workoutMinutes: Double { workouts.reduce(0) { $0 + $1.minutes } }
    var workoutCount: Int { workouts.count }
    var hasData: Bool {
        steps != nil || walkingRunningMeters != nil || activeEnergyKilocalories != nil ||
        exerciseMinutes != nil || standHours != nil || restingHeartRateBPM != nil ||
        walkingHeartRateBPM != nil || respiratoryRate != nil ||
        !workouts.isEmpty || sleep != nil
    }

    static let empty = Self(steps: nil, walkingRunningMeters: nil,
                            activeEnergyKilocalories: nil, exerciseMinutes: nil,
                            standHours: nil,
                            restingHeartRateBPM: nil, walkingHeartRateBPM: nil,
                            respiratoryRate: nil,
                            restingHeartRateSampleCount: 0, walkingHeartRateSampleCount: 0,
                            respiratoryRateSampleCount: 0,
                            workouts: [], sleep: nil,
                            activeStepDays: 0, elapsedDays: 0,
                            source: "Apple Health", lastSuccessfulImport: nil)

    /// HealthKit's workout description is an implementation detail (for example,
    /// `HKWorkoutActivityType(rawValue: 52)`). Keep that detail out of Insights
    /// while leaving genuinely unknown future types understandable.
    static func knownWorkoutTypeName(rawValue: Int) -> String? {
        switch rawValue {
        case 13: "Cycling"
        case 24, 52: "Walking"
        case 37: "Running"
        case 46: "Swimming"
        case 56: "Yoga"
        case 20, 50: "Strength training"
        case 11: "Cross-training"
        case 35: "Rowing"
        case 44, 67: "Stair climbing"
        case 15: "Elliptical"
        case 21: "Golf"
        case 41: "Soccer"
        case 48: "Tennis"
        case 6: "Basketball"
        case 1: "American football"
        case 3: "Australian football"
        case 8: "Boxing"
        case 28: "Martial arts"
        case 29: "Mind and body"
        default: nil
        }
    }

    /// A meaningful month-to-month health change needs both a useful absolute
    /// movement and a relative movement. This keeps sparse or tiny samples quiet.
    static func meaningfulChange(current: Double?, previous: Double?, minimum: Double,
                                 relative: Double = 0.10) -> Double? {
        guard let current, let previous, previous > 0,
              abs(current - previous) >= minimum,
              abs(current - previous) / previous >= relative else { return nil }
        return current - previous
    }
}

/// Sendable, framework-free fixtures/results for the Health aggregation boundary.
/// HealthKit UUIDs are the identity, so a repeated delivery cannot inflate totals.
struct HealthQuantityFixture: Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let value: Double
}

struct HealthWorkoutFixture: Equatable, Sendable {
    let id: UUID
    let type: String
    let start: Date
    let end: Date
    let distanceMeters: Double?
}

enum HealthInsightsAggregation {
    static func summary(steps: [HealthQuantityFixture], walkingRunningMeters: [HealthQuantityFixture],
                        activeEnergyKilocalories: [HealthQuantityFixture], exerciseMinutes: [HealthQuantityFixture],
                        standHours: [HealthQuantityFixture], workouts: [HealthWorkoutFixture],
                        sleep: SleepSummary?, interval: DateInterval, calendar: Calendar,
                        restingHeartRate: [HealthQuantityFixture] = [],
                        walkingHeartRate: [HealthQuantityFixture] = [], heartRateRecovery: [HealthQuantityFixture] = [],
                        respiratoryRate: [HealthQuantityFixture] = [], now: Date = .now,
                        lastSuccessfulImport: Date? = nil,
                        // Source-aware deduplicated totals, when the caller has them (see
                        // `ActivitySampleReader.quantityCumulativeSum`). Defaulted `nil` so
                        // every existing caller/test that only has raw fixtures is
                        // unaffected; production code passes these, and they take
                        // priority over the naive raw-fixture sum below, which double
                        // counts a sample independently recorded by both an iPhone and a
                        // paired Watch.
                        stepsTotal: Double? = nil, walkingRunningMetersTotal: Double? = nil,
                        activeEnergyKilocaloriesTotal: Double? = nil, exerciseMinutesTotal: Double? = nil,
                        standHoursTotal: Double? = nil) -> HealthInsightsSummary {
        func unique(_ values: [HealthQuantityFixture]) -> [HealthQuantityFixture] {
            var seen = Set<UUID>()
            return values.filter { seen.insert($0.id).inserted }
        }
        func total(_ values: [HealthQuantityFixture]) -> Double? {
            let distinct = unique(values)
            return distinct.isEmpty ? nil : distinct.reduce(0) { $0 + $1.value }
        }
        func average(_ values: [HealthQuantityFixture]) -> Double? {
            let distinct = unique(values)
            guard !distinct.isEmpty else { return nil }
            return distinct.reduce(0) { $0 + $1.value } / Double(distinct.count)
        }
        func sampleCount(_ values: [HealthQuantityFixture]) -> Int { unique(values).count }
        let uniqueSteps = unique(steps)
        let recoveryByWorkout = heartRateRecoveryByWorkout(unique(heartRateRecovery), workouts: workouts)
        let distinctWorkouts = Dictionary(grouping: workouts, by: \.id).compactMap { $0.value.first }
            .filter { $0.end > interval.start && $0.start < interval.end }
            .map { workout in
                HealthInsightsSummary.Workout(id: workout.id, type: workout.type,
                                              duration: max(0, workout.end.timeIntervalSince(workout.start)),
                                              distanceMeters: workout.distanceMeters,
                                              heartRateRecoveryBPM: recoveryByWorkout[workout.id])
            }
        let elapsedEnd = max(interval.start, min(interval.end, now))
        let dayDifference = calendar.dateComponents([.day], from: calendar.startOfDay(for: interval.start),
                                                    to: calendar.startOfDay(for: elapsedEnd)).day ?? 0
        let dayCount = max(1, dayDifference + 1)
        let activeDays = Set(uniqueSteps.filter { $0.value > 0 }.map { calendar.startOfDay(for: $0.start) }).count
        return HealthInsightsSummary(
            steps: stepsTotal ?? total(steps),
            walkingRunningMeters: walkingRunningMetersTotal ?? total(walkingRunningMeters),
            activeEnergyKilocalories: activeEnergyKilocaloriesTotal ?? total(activeEnergyKilocalories),
            exerciseMinutes: exerciseMinutesTotal ?? total(exerciseMinutes),
            standHours: standHoursTotal ?? total(standHours),
            restingHeartRateBPM: average(restingHeartRate),
            walkingHeartRateBPM: average(walkingHeartRate),
            respiratoryRate: average(respiratoryRate),
            restingHeartRateSampleCount: sampleCount(restingHeartRate),
            walkingHeartRateSampleCount: sampleCount(walkingHeartRate),
            respiratoryRateSampleCount: sampleCount(respiratoryRate),
            workouts: distinctWorkouts,
            sleep: sleep,
            activeStepDays: activeDays,
            elapsedDays: dayCount,
            source: "Apple Health",
            lastSuccessfulImport: lastSuccessfulImport
        )
    }

    /// Apple scores one-minute heart-rate recovery immediately after a
    /// supported workout ends, so a sample's own start date sits within a few
    /// minutes of that workout's end -- never before it. Matching by timing
    /// rather than an explicit workout reference because `HKQuantitySample`
    /// carries no such link; this window is generous enough to survive
    /// HealthKit's own save latency without reaching into an unrelated later
    /// workout.
    ///
    /// A sample's closest-preceding workout wins it, not the other way
    /// around: two workouts close together must not let an earlier one's
    /// recovery sample also get claimed by the later one just because it
    /// asked first.
    private static let heartRateRecoveryMatchWindow: TimeInterval = 15 * 60

    private static func heartRateRecoveryByWorkout(_ samples: [HealthQuantityFixture],
                                                    workouts: [HealthWorkoutFixture]) -> [UUID: Double] {
        var best: [UUID: (value: Double, gap: TimeInterval)] = [:]
        for sample in samples {
            guard let closest = workouts
                .filter({ sample.start >= $0.end && sample.start <= $0.end.addingTimeInterval(heartRateRecoveryMatchWindow) })
                .min(by: { sample.start.timeIntervalSince($0.end) < sample.start.timeIntervalSince($1.end) })
            else { continue }
            let gap = sample.start.timeIntervalSince(closest.end)
            if let existing = best[closest.id], existing.gap <= gap { continue }
            best[closest.id] = (sample.value, gap)
        }
        return best.mapValues { $0.value }
    }
}
