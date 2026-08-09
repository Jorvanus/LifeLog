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

/// Health and Motion history is read away from the main actor and converted into
/// small Sendable records before any database work begins.
actor ActivitySampleReader {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()

    func sleepRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        try await anchoredSleepRecords(in: interval, anchorData: nil).records
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
                                     source: "health-sleep", start: $0.interval.start, end: $0.interval.end,
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

    private func encodeAnchor(_ anchor: HKQueryAnchor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)) ?? Data()
    }

    private func decodeAnchor(_ data: Data?) -> HKQueryAnchor? {
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
            .map {
                ActivityImportRecord(name: "Walking", activity: "Walking",
                                     source: "health-walking", start: $0.start, end: $0.end)
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

    private func merge(_ intervals: [DateInterval], maximumGap: TimeInterval) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start.timeIntervalSince(last.end) <= maximumGap {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Same merge as above, but keeps track of which sample UUIDs contributed to
    /// each merged interval, so a merged sleep session can still be matched back
    /// to every underlying HealthKit sample if one of them is later deleted.
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
        switch type {
        case .walking, .hiking: "Walking"
        case .running: "Running"
        case .cycling, .handCycling: "Cycling"
        case .swimming: "Swimming"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength training"
        default: "Exercising"
        }
    }
}
