import Foundation

/// Health values used by Insights. The source is intentionally explicit so a
/// Health-derived number cannot be mistaken for a location-derived Visit.
struct HealthInsightsSummary: Equatable, Sendable {
    struct Workout: Identifiable, Equatable, Sendable {
        let id: UUID
        let type: String
        let duration: TimeInterval
        let distanceMeters: Double?

        var minutes: Double { duration / 60 }
    }

    let steps: Double?
    let walkingRunningMeters: Double?
    let activeEnergyKilocalories: Double?
    let exerciseMinutes: Double?
    let standHours: Double?
    let restingHeartRateBPM: Double?
    let walkingHeartRateBPM: Double?
    let heartRateRecoveryBPM: Double?
    let respiratoryRate: Double?
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
        walkingHeartRateBPM != nil || heartRateRecoveryBPM != nil || respiratoryRate != nil ||
        !workouts.isEmpty || sleep != nil
    }

    static let empty = Self(steps: nil, walkingRunningMeters: nil,
                            activeEnergyKilocalories: nil, exerciseMinutes: nil,
                            standHours: nil,
                            restingHeartRateBPM: nil, walkingHeartRateBPM: nil,
                            heartRateRecoveryBPM: nil, respiratoryRate: nil,
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
                        lastSuccessfulImport: Date? = nil) -> HealthInsightsSummary {
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
        let uniqueSteps = unique(steps)
        let distinctWorkouts = Dictionary(grouping: workouts, by: \.id).compactMap { $0.value.first }
            .filter { $0.end > interval.start && $0.start < interval.end }
            .map { workout in
                HealthInsightsSummary.Workout(id: workout.id, type: workout.type,
                                              duration: max(0, workout.end.timeIntervalSince(workout.start)),
                                              distanceMeters: workout.distanceMeters)
            }
        let elapsedEnd = max(interval.start, min(interval.end, now))
        let dayDifference = calendar.dateComponents([.day], from: calendar.startOfDay(for: interval.start),
                                                    to: calendar.startOfDay(for: elapsedEnd)).day ?? 0
        let dayCount = max(1, dayDifference + 1)
        let activeDays = Set(uniqueSteps.filter { $0.value > 0 }.map { calendar.startOfDay(for: $0.start) }).count
        return HealthInsightsSummary(
            steps: total(steps),
            walkingRunningMeters: total(walkingRunningMeters),
            activeEnergyKilocalories: total(activeEnergyKilocalories),
            exerciseMinutes: total(exerciseMinutes),
            standHours: total(standHours),
            restingHeartRateBPM: average(restingHeartRate),
            walkingHeartRateBPM: average(walkingHeartRate),
            heartRateRecoveryBPM: average(heartRateRecovery),
            respiratoryRate: average(respiratoryRate),
            workouts: distinctWorkouts,
            sleep: sleep,
            activeStepDays: activeDays,
            elapsedDays: dayCount,
            source: "Apple Health",
            lastSuccessfulImport: lastSuccessfulImport
        )
    }
}
