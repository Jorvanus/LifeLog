import CoreMotion
import Foundation
import HealthKit

/// Collects a workout route delivered in batches on HealthKit's queue.
///
/// Unchecked because the compiler cannot see the lock, which is the whole point:
/// every access to the two stored properties goes through it. `finish` is the
/// single gate on resuming the continuation — it hands back the route once and
/// returns nil to every later caller, whether the query finished or failed.
private final class RouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [RoutePoint] = []
    private var hasFinished = false

    func append(_ newPoints: [RoutePoint]) {
        lock.lock()
        defer { lock.unlock() }
        points += newPoints
    }

    func finish() -> [RoutePoint]? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished else { return nil }
        hasFinished = true
        return points
    }
}

/// A value-only import payload. HealthKit and Core Motion objects never cross into
/// the SwiftData writer, keeping framework objects and model instances isolated.
struct ActivityImportRecord: Sendable {
    let name: String
    let activity: String
    let source: String
    let start: Date
    let end: Date
    /// The HealthKit sample(s) this record was built from, so a later anchored-query
    /// deletion can be matched back to the visit it produced. Empty for non-HealthKit
    /// sources (motion, walking).
    var healthKitSampleIDs: [UUID] = []
    /// The path this movement followed, where the source recorded one. Only workouts
    /// carry a route; step counts and Core Motion inferences have no coordinates at all.
    var route: [RoutePoint] = []
}

struct ActivityAnchorResult: Sendable {
    let records: [ActivityImportRecord]
    let anchorData: Data
    /// HealthKit sample UUIDs removed since the previous anchor. Matched against
    /// each Visit's `healthKitSampleIDs` so a deleted Health record no longer
    /// leaves a stale imported entry in the timeline.
    let deletedSampleIDs: [UUID]
}

/// A classified Core Motion interval, kept separate from the framework object so the
/// coalescing rule can be tested without motion hardware.
struct MotionActivitySegment: Sendable, Equatable {
    let activity: String
    let start: Date
    let end: Date
}

enum HealthTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case restingHeartRate
    case walkingHeartRate
    case heartRateRecovery
    case respiratoryRate
    case heartRateVariability
    case cardioFitness
    case walkingSpeed
    case walkingStepLength

    var id: Self { self }

    var title: String {
        switch self {
        case .restingHeartRate: "Resting heart rate"
        case .walkingHeartRate: "Walking heart rate"
        case .heartRateRecovery: "One-minute heart-rate recovery"
        case .respiratoryRate: "Respiratory rate"
        case .heartRateVariability: "Heart-rate variability"
        case .cardioFitness: "Cardio fitness"
        case .walkingSpeed: "Walking speed"
        case .walkingStepLength: "Walking step length"
        }
    }

    var symbol: String {
        switch self {
        case .restingHeartRate, .walkingHeartRate, .heartRateRecovery, .heartRateVariability: "heart.fill"
        case .respiratoryRate: "wind"
        case .cardioFitness: "figure.run"
        case .walkingSpeed, .walkingStepLength: "figure.walk"
        }
    }

    var unitTitle: String {
        switch self {
        case .restingHeartRate, .walkingHeartRate: "bpm"
        case .heartRateRecovery: "bpm recovered"
        case .respiratoryRate: "breaths/min"
        case .heartRateVariability: "ms"
        case .cardioFitness: "mL/kg/min"
        case .walkingSpeed: "m/s"
        case .walkingStepLength: "cm"
        }
    }

    var identifier: HKQuantityTypeIdentifier {
        switch self {
        case .restingHeartRate: .restingHeartRate
        case .walkingHeartRate: .walkingHeartRateAverage
        case .heartRateRecovery: .heartRateRecoveryOneMinute
        case .respiratoryRate: .respiratoryRate
        case .heartRateVariability: .heartRateVariabilitySDNN
        case .cardioFitness: .vo2Max
        case .walkingSpeed: .walkingSpeed
        case .walkingStepLength: .walkingStepLength
        }
    }

    var unit: HKUnit {
        switch self {
        // HealthKit stores one-minute recovery as a rate, just like the other
        // pulse-derived measurements. Reading it as a plain count throws an
        // Objective-C exception that Swift cannot catch.
        case .restingHeartRate, .walkingHeartRate, .heartRateRecovery, .respiratoryRate:
            .heartRateUnit()
        case .heartRateVariability:
            .secondUnit(with: .milli)
        case .cardioFitness:
            .literUnit(with: .milli)
                .unitDivided(by: .gramUnit(with: .kilo))
                .unitDivided(by: .minute())
        case .walkingSpeed:
            .meter().unitDivided(by: .second())
        case .walkingStepLength:
            .meterUnit(with: .centi)
        }
    }
}

struct HealthTrendPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct HealthSleepSession: Equatable, Sendable {
    let start: Date
    let end: Date
    let duration: TimeInterval
}

/// Health and Motion history is read away from the main actor and converted into
/// small Sendable records before any database work begins.
actor ActivitySampleReader {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()

    /// Reads only the selected period. These are ordinary bounded sample queries;
    /// the long-lived change signal remains the anchored observer/import path.
    func healthInsightsFixtures(in interval: DateInterval) async -> (
        steps: [HealthQuantityFixture], walking: [HealthQuantityFixture],
        energy: [HealthQuantityFixture], exercise: [HealthQuantityFixture],
        stand: [HealthQuantityFixture], workouts: [HealthWorkoutFixture],
        heartRateRecovery: [HealthQuantityFixture],
        stepsTotal: Double?, walkingTotal: Double?, energyTotal: Double?,
        exerciseTotal: Double?, standTotal: Double?
    ) {
        async let steps = safeQuantityFixtures(in: interval, identifier: .stepCount, unit: .count())
        async let walking = safeQuantityFixtures(in: interval, identifier: .distanceWalkingRunning, unit: .meter())
        async let energy = safeQuantityFixtures(in: interval, identifier: .activeEnergyBurned, unit: .kilocalorie())
        async let exercise = safeQuantityFixtures(in: interval, identifier: .appleExerciseTime, unit: .minute())
        async let stand = safeQuantityFixtures(in: interval, identifier: .appleStandTime, unit: .hour())
        async let workouts = safeWorkoutFixtures(in: interval)
        // Padded past `interval.end`: recovery is scored a minute or so after a
        // workout ends, so a workout finishing right at the period boundary has
        // its recovery sample land just outside it.
        async let heartRateRecovery = safeQuantityFixtures(
            in: DateInterval(start: interval.start, end: interval.end.addingTimeInterval(15 * 60)),
            identifier: .heartRateRecoveryOneMinute, unit: .heartRateUnit()
        )
        // The raw fixtures above are kept for `activeStepDays`' day-by-day presence
        // check, which genuinely needs per-sample granularity across a multi-day
        // window. The *totals* Health overview actually displays must not be a
        // naive sum of those same raw fixtures -- summing every distinct sample
        // double-counts a walk both an iPhone and a paired Watch independently
        // recorded (confirmed on-device: Steps and Walk+Run both read almost
        // exactly 2x Apple Health's own figures). `quantityCumulativeSum` mirrors
        // `ActivityDataService.stepCount(for:)`'s already-correct pattern.
        async let stepsTotal = quantityCumulativeSum(in: interval, identifier: .stepCount, unit: .count())
        async let walkingTotal = quantityCumulativeSum(in: interval, identifier: .distanceWalkingRunning, unit: .meter())
        async let energyTotal = quantityCumulativeSum(in: interval, identifier: .activeEnergyBurned, unit: .kilocalorie())
        async let exerciseTotal = quantityCumulativeSum(in: interval, identifier: .appleExerciseTime, unit: .minute())
        async let standTotal = quantityCumulativeSum(in: interval, identifier: .appleStandTime, unit: .hour())
        return await (steps, walking, energy, exercise, stand, workouts, heartRateRecovery,
                      stepsTotal, walkingTotal, energyTotal, exerciseTotal, standTotal)
    }

    private func safeQuantityFixtures(in interval: DateInterval, identifier: HKQuantityTypeIdentifier,
                                      unit: HKUnit) async -> [HealthQuantityFixture] {
        (try? await quantityFixtures(in: interval, identifier: identifier, unit: unit)) ?? []
    }

    /// Source-aware deduplicated total, matching `ActivityDataService.stepCount(for:)`'s
    /// pattern exactly: HealthKit's own cumulative statistic merges overlapping
    /// iPhone/Watch samples for the same real-world activity, which a raw per-sample
    /// sum (`quantityFixtures`, `total(_:)` in `HealthInsightsAggregation`) cannot --
    /// two devices independently recording the same walk have distinct sample UUIDs,
    /// so UUID-based dedup alone does not merge them.
    private func quantityCumulativeSum(in interval: DateInterval, identifier: HKQuantityTypeIdentifier,
                                       unit: HKUnit) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                     options: [.strictStartDate, .strictEndDate])
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let statistics = try? await descriptor.result(for: healthStore) else { return nil }
        return statistics.sumQuantity()?.doubleValue(for: unit)
    }

    private func safeWorkoutFixtures(in interval: DateInterval) async -> [HealthWorkoutFixture] {
        (try? await workoutFixtures(in: interval)) ?? []
    }

    /// Just the workout start times in the period -- for correlating another
    /// metric (sleep, say) against "did a workout happen this day," which
    /// doesn't need the full `HealthWorkoutFixture` (type, duration, distance)
    /// the main Health-insights query already fetches for other purposes.
    func workoutDates(in interval: DateInterval) async -> [Date] {
        await safeWorkoutFixtures(in: interval).map(\.start)
    }

    func healthTrendFixtures(for metric: HealthTrendMetric, in interval: DateInterval) async -> [HealthQuantityFixture] {
        (try? await quantityFixtures(in: interval, identifier: metric.identifier, unit: metric.unit)) ?? []
    }

    /// Returns one compact value per recorded night for the personal sleep-pattern
    /// comparison. The query is bounded by its caller and runs only on drill-down.
    func sleepSessions(in interval: DateInterval) async -> [HealthSleepSession] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let padded = DateInterval(start: interval.start.addingTimeInterval(-12 * 60 * 60),
                                  end: interval.end.addingTimeInterval(12 * 60 * 60))
        let predicate = HKQuery.predicateForSamples(withStart: padded.start, end: padded.end,
                                                     options: [.strictStartDate, .strictEndDate])
        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let samples = try? await descriptor.result(for: healthStore) else { return [] }
        let calendar = Calendar.current
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        ]
        let grouped = Dictionary(grouping: samples.compactMap { sample -> DateInterval? in
            guard asleepValues.contains(sample.value), sample.endDate > sample.startDate else { return nil }
            return DateInterval(start: max(sample.startDate, padded.start), end: min(sample.endDate, padded.end))
        }) { interval in
            calendar.startOfDay(for: interval.start.addingTimeInterval(-12 * 60 * 60))
        }
        return grouped.compactMap { _, intervals in
            let merged = intervals.sorted { $0.start < $1.start }.reduce(into: [DateInterval]()) { result, interval in
                guard let last = result.last, interval.start <= last.end else { result.append(interval); return }
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            }
            guard let first = merged.first, let last = merged.last else { return nil }
            return HealthSleepSession(start: first.start, end: last.end,
                                      duration: merged.reduce(0) { $0 + $1.duration })
        }
        .filter { $0.end <= interval.end && $0.start >= interval.start.addingTimeInterval(-12 * 60 * 60) }
        .sorted { $0.start < $1.start }
    }

    private func quantityFixtures(in interval: DateInterval, identifier: HKQuantityTypeIdentifier,
                                  unit: HKUnit) async throws -> [HealthQuantityFixture] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                     options: [.strictStartDate, .strictEndDate])
        let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: healthStore).map {
            HealthQuantityFixture(id: $0.uuid, start: $0.startDate, end: $0.endDate,
                                  value: $0.quantity.doubleValue(for: unit))
        }
    }

    private func workoutFixtures(in interval: DateInterval) async throws -> [HealthWorkoutFixture] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                     options: [.strictStartDate, .strictEndDate])
        let descriptor = HKSampleQueryDescriptor<HKWorkout>(
            predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: healthStore).map { workout in
            HealthWorkoutFixture(id: workout.uuid,
                                 type: HealthInsightsSummary.knownWorkoutTypeName(
                                    rawValue: Int(workout.workoutActivityType.rawValue)
                                 ) ?? "Workout",
                                 start: workout.startDate, end: workout.endDate,
                                 distanceMeters: workout.totalDistance?.doubleValue(for: .meter()))
        }
    }

    /// Rebuilds complete sleep evidence in a small window. Anchors are still used to
    /// learn that Health changed, but their delta alone cannot describe a whole night:
    /// a Watch may deliver its Core, REM and Deep samples in separate syncs.
    func sleepRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: healthStore)
        try Task.checkCancellation()

        let measured = samples.compactMap { sample -> (interval: DateInterval, id: UUID)? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  value == .asleepCore || value == .asleepDeep ||
                    value == .asleepREM || value == .asleepUnspecified else { return nil }
            return (DateInterval(start: sample.startDate, end: sample.endDate), sample.uuid)
        }
        let inBed = samples.compactMap { sample -> (interval: DateInterval, id: UUID)? in
            guard HKCategoryValueSleepAnalysis(rawValue: sample.value) == .inBed else { return nil }
            return (DateInterval(start: sample.startDate, end: sample.endDate), sample.uuid)
        }
        let measuredSessions = mergeWithIdentifiers(measured, maximumGap: 15 * 60)
            .filter { $0.interval.duration >= 20 * 60 }
        let measuredRecords = measuredSessions
            .map {
                ActivityImportRecord(name: "Sleep", activity: "Sleeping",
                                     source: SleepEvidence.measuredSource,
                                     start: $0.interval.start, end: $0.interval.end,
                                     healthKitSampleIDs: $0.ids)
            }
        let inBedRecords = mergeWithIdentifiers(inBed, maximumGap: 30 * 60)
            .filter { $0.interval.duration >= 20 * 60 }
            // When the Watch supplied actual sleep for this night, an overlapping
            // schedule estimate adds no information and would create a second card.
            .filter { inBedSession in
                !measuredSessions.contains {
                    $0.interval.start < inBedSession.interval.end && $0.interval.end > inBedSession.interval.start
                }
            }
            .map {
                ActivityImportRecord(name: "In bed", activity: "In bed",
                                     source: SleepEvidence.inBedSource,
                                     start: $0.interval.start, end: $0.interval.end,
                                     healthKitSampleIDs: $0.ids)
            }
        return measuredRecords + inBedRecords
    }

    func anchoredSleepRecords(in interval: DateInterval, anchorData: Data?) async throws -> ActivityAnchorResult {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ActivityAnchorResult(records: [], anchorData: Data(), deletedSampleIDs: [])
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let anchor = decodeAnchor(anchorData)
        let descriptor = HKAnchoredObjectQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: type, predicate: predicate)], anchor: anchor)
        let result = try await descriptor.result(for: healthStore)
        let samples = result.addedSamples
        try Task.checkCancellation()
        let asleep = samples.compactMap { sample -> (interval: DateInterval, id: UUID)? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  value == .asleepCore || value == .asleepDeep ||
                  value == .asleepREM || value == .asleepUnspecified else { return nil }
            return (DateInterval(start: sample.startDate, end: sample.endDate), sample.uuid)
        }
        let records = mergeWithIdentifiers(asleep, maximumGap: 15 * 60)
            .filter { $0.interval.duration >= 20 * 60 }
            .map {
                ActivityImportRecord(name: "Sleep", activity: "Sleeping",
                                     source: SleepEvidence.measuredSource, start: $0.interval.start, end: $0.interval.end,
                                     healthKitSampleIDs: $0.ids)
            }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedSampleIDs: result.deletedObjects.map(\.uuid))
    }

    func anchoredWorkoutRecords(in interval: DateInterval, anchorData: Data?) async throws -> ActivityAnchorResult {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let anchor = decodeAnchor(anchorData)
        let descriptor = HKAnchoredObjectQueryDescriptor<HKWorkout>(
            predicates: [.workout(predicate)], anchor: anchor)
        let result = try await descriptor.result(for: healthStore)
        let workouts = result.addedSamples
        try Task.checkCancellation()
        var records: [ActivityImportRecord] = []
        for workout in workouts {
            let activity = workoutActivity(workout.workoutActivityType)
            records.append(ActivityImportRecord(name: "\(activity) workout", activity: activity,
                                               source: "health-workout",
                                               start: workout.startDate, end: workout.endDate,
                                               healthKitSampleIDs: [workout.uuid],
                                               route: try await route(for: workout)))
            try Task.checkCancellation()
        }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedSampleIDs: result.deletedObjects.map(\.uuid))
    }

    /// The path a workout followed, if one was recorded. A watch or phone workout
    /// stores its GPS track alongside the sample, so this is a walk LifeLog already
    /// has the route for — no extra recording, and no battery cost, only the asking.
    /// Workouts done indoors, or on a device without GPS, simply have no route.
    private func route(for workout: HKWorkout) async throws -> [RoutePoint] {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            anchor: nil
        )
        let routes = try await descriptor.result(for: healthStore).addedSamples
        var points: [RoutePoint] = []
        for route in routes {
            points += try await locations(in: route)
        }
        guard points.count > 1 else { return [] }
        return RouteSimplification.simplify(points.sorted { $0.time < $1.time })
    }

    /// `HKWorkoutRouteQuery` predates async/await and delivers a route in batches, so
    /// the locations are accumulated across callbacks and returned once it reports done.
    ///
    /// The batches arrive on HealthKit's own queue rather than this actor, so the
    /// partial route and the resumed flag live behind a lock. Resuming a continuation
    /// twice is a crash rather than a warning, and `finish()` can only succeed once.
    private func locations(in route: HKWorkoutRoute) async throws -> [RoutePoint] {
        let accumulator = RouteAccumulator()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    guard accumulator.finish() != nil else { return }
                    continuation.resume(throwing: error)
                    return
                }
                accumulator.append((locations ?? []).map(RoutePoint.init))
                guard done, let points = accumulator.finish() else { return }
                continuation.resume(returning: points)
            }
            healthStore.execute(query)
        }
    }

    /// Best effort: `HKQueryAnchor` is a HealthKit-opaque cursor with no
    /// meaningful partial-failure mode to report, and an encode failure has no
    /// worse fallback than "the next query starts over" (see `decodeAnchor`).
    func encodeAnchor(_ anchor: HKQueryAnchor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)) ?? Data()
    }

    /// Decoding fallback: missing and corrupt anchor data are deliberately
    /// treated identically, both as "no anchor." `nil` is itself a valid
    /// `HKAnchoredObjectQueryDescriptor` anchor meaning "start from the
    /// beginning of the queried interval" — not all-time — and
    /// `ActivityDataService.startImport` bounds that interval to the
    /// configured `healthDays` window and writes samples through a
    /// duplicate-checked path, so a corrupted anchor costs a bounded re-read,
    /// not a silent gap or a crash. Internal rather than private so the
    /// distinction itself (corrupt bytes decode the same as `nil`, without
    /// crashing) can be exercised directly in tests.
    func decodeAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data, !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// How long a pause in stepping may be before it is treated as two separate walks.
    ///
    /// These records are built from step counts, not from a walking workout, so the
    /// only thing separating "one walk" from "walked, drove, walked" is this gap. It
    /// was five minutes, which is longer than a short drive: on 8 August steps around
    /// Gracemere Shopping World, steps to the car, and steps inside Star Liquor 455 m
    /// away fused into a single 29-minute walk covering a two-minute drive between two
    /// shops. Ninety seconds still absorbs a wait at a crossing or a pause to answer
    /// the phone, and no longer spans a journey by car.
    ///
    /// A burst shorter than the two-minute floor below is dropped rather than shown,
    /// so splitting more often means fewer spurious walks, not more.
    private let walkingBurstGap: TimeInterval = 90

    func walkingRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: healthStore)
        try Task.checkCancellation()
        let watchSamples = samples.filter {
            $0.device?.model?.localizedCaseInsensitiveContains("watch") == true ||
            $0.sourceRevision.source.name.localizedCaseInsensitiveContains("watch")
        }
        let preferred = watchSamples.isEmpty ? samples : watchSamples
        let intervals = preferred.compactMap { sample -> DateInterval? in
            guard sample.quantity.doubleValue(for: .count()) >= 10 else { return nil }
            return DateInterval(start: sample.startDate,
                                end: max(sample.endDate, sample.startDate.addingTimeInterval(60)))
        }
        return merge(intervals, maximumGap: walkingBurstGap)
            .filter { $0.duration >= 2 * 60 }
            .map { walk in
                // Step counts carry no location of their own; this is the only
                // place a passive walk can pick up a coordinate at all, and only
                // when `WalkRouteTracking.isEnabled` has ever left anything behind
                // for this window (see `WalkBreadcrumbStore`). Empty otherwise,
                // exactly as every passive walk has been until now.
                let route = WalkBreadcrumbStore.breadcrumbs(in: walk)
                    .map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude, time: $0.recordedAt) }
                return ActivityImportRecord(name: "Walking", activity: "Walking",
                                            source: "health-walking", start: walk.start, end: walk.end,
                                            route: route)
            }
    }

    func motionRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        let records: [ActivityImportRecord] = try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.qualityOfService = .utility
            motionManager.queryActivityStarting(from: interval.start, to: interval.end, to: queue) { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: Self.makeMotionRecords(values ?? [], interval: interval)) }
            }
        }
        try Task.checkCancellation()
        return records
    }

    /// Motion framework objects stay on the callback queue; only Sendable value
    /// records cross back into the ingestion actor under Swift 6 concurrency.
    private nonisolated static func makeMotionRecords(
        _ activities: [CMMotionActivity], interval: DateInterval
    ) -> [ActivityImportRecord] {
        let segments = activities.enumerated().compactMap { index, event -> MotionActivitySegment? in
            guard event.confidence != .low, let activity = motionActivity(event) else { return nil }
            let end = index + 1 < activities.count ? activities[index + 1].startDate : interval.end
            return MotionActivitySegment(activity: activity, start: event.startDate, end: end)
        }
        return makeMotionRecords(segments: segments)
    }

    /// Automotive classification often briefly drops while the car is still moving.
    /// Treating those short unclassified windows as the end of the journey split one
    /// observed 43-minute drive into four rows and erased seventeen minutes of it.
    /// Walking deliberately keeps its much tighter gap: it must not bridge a car ride
    /// between two short bouts of steps.
    nonisolated static func makeMotionRecords(segments input: [MotionActivitySegment]) -> [ActivityImportRecord] {
        var segments: [MotionActivitySegment] = []
        for event in input where event.end > event.start {
            let minimumDuration: TimeInterval = event.activity == "Travelling" ? 3 * 60 : 2 * 60
            guard event.end.timeIntervalSince(event.start) >= minimumDuration else { continue }
            if let last = segments.last,
               last.activity == event.activity,
               event.start.timeIntervalSince(last.end) <= motionMergeGap(for: event.activity) {
                segments[segments.count - 1] = MotionActivitySegment(
                    activity: last.activity, start: last.start, end: event.end
                )
            } else {
                segments.append(event)
            }
        }
        return segments.map { segment in
            let isTravel = segment.activity == "Travelling"
            return ActivityImportRecord(
                name: isTravel ? "In transit" : segment.activity,
                activity: segment.activity,
                source: "motion", start: segment.start, end: segment.end
            )
        }
    }

    private nonisolated static func motionMergeGap(for activity: String) -> TimeInterval {
        activity == "Travelling" ? 10 * 60 : 90
    }

    /// `mergeWithIdentifiers` with the per-item id discarded, for the one caller
    /// that has no sample to track back to.
    private func merge(_ intervals: [DateInterval], maximumGap: TimeInterval) -> [DateInterval] {
        mergeWithIdentifiers(intervals.map { (interval: $0, id: UUID()) }, maximumGap: maximumGap)
            .map(\.interval)
    }

    /// Keeps track of which sample UUIDs contributed to each merged interval, so a
    /// merged sleep session can still be matched back to every underlying
    /// HealthKit sample if one of them is later deleted.
    private func mergeWithIdentifiers(
        _ items: [(interval: DateInterval, id: UUID)], maximumGap: TimeInterval
    ) -> [(interval: DateInterval, ids: [UUID])] {
        let sorted = items.sorted { $0.interval.start < $1.interval.start }
        var result: [(interval: DateInterval, ids: [UUID])] = []
        for item in sorted {
            if let last = result.last, item.interval.start.timeIntervalSince(last.interval.end) <= maximumGap {
                let merged = DateInterval(start: last.interval.start,
                                          end: max(last.interval.end, item.interval.end))
                result[result.count - 1] = (merged, last.ids + [item.id])
            } else {
                result.append((item.interval, [item.id]))
            }
        }
        return result
    }

    private nonisolated static func motionActivity(_ activity: CMMotionActivity) -> String? {
        if activity.automotive { return "Travelling" }
        if activity.cycling { return "Cycling" }
        if activity.running { return "Running" }
        if activity.walking { return "Walking" }
        return nil
    }

    private func workoutActivity(_ type: HKWorkoutActivityType) -> String {
        HealthInsightsSummary.knownWorkoutTypeName(rawValue: Int(type.rawValue)) ?? "Exercising"
    }
}

private extension HKUnit {
    static func heartRateUnit() -> HKUnit {
        HKUnit.count().unitDivided(by: HKUnit.minute())
    }
}
