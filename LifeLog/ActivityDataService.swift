import Foundation
import CoreMotion
import HealthKit
import SwiftData
import Observation

/// Sleep details read from HealthKit for one selected overnight session.
/// The score is LifeLog's transparent estimate; Apple does not expose its private
/// Sleep Score as a public HealthKit value.
struct SleepSummary: Equatable, Sendable {
    let totalSleep: TimeInterval
    let timeInBed: TimeInterval
    let awake: TimeInterval
    let rem: TimeInterval
    let core: TimeInterval
    let deep: TimeInterval
    let interruptions: Int

    var estimatedScore: Int {
        let durationPoints = min(50, totalSleep / (8 * 60 * 60) * 50)
        let restorativeRatio = totalSleep > 0 ? (rem + deep) / totalSleep : 0
        let stagePoints = min(30, max(0, restorativeRatio / 0.35 * 30))
        let interruptionPoints = max(0, 20 - Double(interruptions) * 3)
        return Int((durationPoints + stagePoints + interruptionPoints).rounded())
    }
}

@MainActor @Observable
final class ActivityDataService {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()
    private var context: ModelContext?
    private var stepCache: [String: Double] = [:]
    // HealthKit imports can contain thousands of samples. Reusing this batch cache
    // prevents insertActivity from fetching the entire SwiftData store per sample.
    private var importExistingVisits: [Visit]?
    private var importVisitsBySource: [String: [Visit]] = [:]
    private var importLocationVisits: [Visit] = []
    private var importHealthVisits: [Visit] = []

    var healthStatus = "Not connected"
    var motionStatus = "Not connected"
    var lastImport: Date?
    var lastError: String?

    func connect(_ context: ModelContext) {
        self.context = context
        refreshMotionStatus()
        // HealthKit history writes are intentionally opt-in now. Even a delayed task
        // still runs SwiftData inserts on the main actor and can freeze an otherwise
        // responsive Timeline several seconds after launch. Insights reads its own
        // step/sleep data on demand; Settings provides the explicit import action.
    }

    func requestHealthAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthStatus = "Unavailable on this device"
            return
        }
        Task {
            do {
                try await healthStore.requestAuthorization(toShare: [], read: healthTypes)
                UserDefaults.standard.set(true, forKey: "LifeLogHealthAccessRequested")
                healthStatus = "Connected"
                await importHealthHistory(daysBack: 2, includeWorkouts: true)
            } catch {
                lastError = "Health access couldn’t be completed. Check Health permissions in Settings."
                healthStatus = "Couldn’t connect"
            }
        }
    }

    func requestMotionAccess() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            motionStatus = "Unavailable on this device"
            return
        }
        importMotionHistory()
    }

    func importAll() {
        Task { await importHealthHistory(daysBack: 30, includeWorkouts: true) }
        if CMMotionActivityManager.authorizationStatus() == .authorized { importMotionHistory() }
    }

    /// Reads the selected sleep session on demand so opening Insights does not add a
    /// HealthKit query to every chart render.
    func sleepSummary(for interval: DateInterval) async -> SleepSummary? {
        guard HKHealthStore.isHealthDataAvailable(),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: [.strictStartDate, .strictEndDate]
        )
        do {
            let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                predicates: [.categorySample(type: sleepType, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let samples = try await descriptor.result(for: healthStore)
            return SleepSummary(samples: samples, interval: interval)
        } catch {
            Diagnostics.record(context, subsystem: "HealthKit",
                               message: "A sleep query failed; no Health data was imported.")
            return nil
        }
    }

    /// Reads total step count for the selected Insights interval without storing
    /// a second copy of Health data in the timeline.
    func stepCount(for interval: DateInterval) async -> Double? {
        let startedAt = Date.now
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let cacheKey = "\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
        if let cached = stepCache[cacheKey] { return cached }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: [.strictStartDate, .strictEndDate]
        )
        do {
            let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
                predicates: [.quantitySample(type: stepType, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let samples = try await descriptor.result(for: healthStore)
            let total = samples.reduce(0) { $0 + $1.quantity.doubleValue(for: .count()) }
            stepCache[cacheKey] = total
            Diagnostics.performance(context, subsystem: "HealthKit", operation: "step query",
                                    startedAt: startedAt, itemCount: samples.count)
            return total
        } catch {
            Diagnostics.record(context, subsystem: "HealthKit",
                               message: "A step-count query failed; the Insights center value was unavailable.")
            return nil
        }
    }

    private var healthTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKWorkoutType.workoutType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        return types
    }

    private func importHealthHistory(daysBack: Int, includeWorkouts: Bool) async {
        let startedAt = Date.now
        guard HKHealthStore.isHealthDataAvailable(), let context else { return }
        importExistingVisits = try? context.fetch(FetchDescriptor<Visit>())
        if let importExistingVisits {
            importVisitsBySource = Dictionary(grouping: importExistingVisits, by: \.source)
            importLocationVisits = importExistingVisits.filter(ActivityLocationPolicy.isLocationVisit)
            importHealthVisits = importExistingVisits.filter { $0.source.hasPrefix("health") }
        }
        defer {
            importExistingVisits = nil
            importVisitsBySource.removeAll(keepingCapacity: false)
            importLocationVisits.removeAll(keepingCapacity: false)
            importHealthVisits.removeAll(keepingCapacity: false)
        }
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: .now) ?? .now
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictEndDate)
        do {
            var healthItemCount = 0
            if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                let queryStartedAt = Date.now
                let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                    predicates: [.categorySample(type: sleepType, predicate: datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let samples = try await descriptor.result(for: healthStore)
                Diagnostics.performance(context, subsystem: "HealthKit", operation: "sleep query",
                                        startedAt: queryStartedAt, itemCount: samples.count)
                healthItemCount += samples.count
                importSleep(samples, context: context)
                await Task.yield()
            }
            if includeWorkouts {
                let workoutQueryStartedAt = Date.now
                let workoutDescriptor = HKSampleQueryDescriptor<HKWorkout>(
                    predicates: [.workout(datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let workouts = try await workoutDescriptor.result(for: healthStore)
                Diagnostics.performance(context, subsystem: "HealthKit", operation: "workout query",
                                        startedAt: workoutQueryStartedAt, itemCount: workouts.count)
                healthItemCount += workouts.count
                importWorkouts(workouts, context: context)
                await Task.yield()
            }
            if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
                let stepQueryStartedAt = Date.now
                let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
                    predicates: [.quantitySample(type: stepType, predicate: datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let steps = try await descriptor.result(for: healthStore)
                Diagnostics.performance(context, subsystem: "HealthKit", operation: "step history query",
                                        startedAt: stepQueryStartedAt, itemCount: steps.count)
                healthItemCount += steps.count
                importWalkingSamples(steps, context: context)
                await Task.yield()
            }
            let saveStartedAt = Date.now
            try context.save()
            Diagnostics.performance(context, subsystem: "HealthKit", operation: "history save",
                                    startedAt: saveStartedAt, itemCount: healthItemCount)
            healthStatus = "Connected"
            lastImport = .now
            Diagnostics.performance(context, subsystem: "HealthKit", operation: "history catch-up",
                                    startedAt: startedAt, itemCount: healthItemCount)
        } catch {
            lastError = "Recent Health data couldn’t be imported. Your existing timeline is unchanged."
            Diagnostics.record(context, subsystem: "HealthKit",
                               message: "A HealthKit history import failed; existing timeline data was preserved.")
        }
    }

    private func importSleep(_ samples: [HKCategorySample], context: ModelContext) {
        let asleep = samples.filter { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return false }
            return value == .asleepCore || value == .asleepDeep || value == .asleepREM || value == .asleepUnspecified
        }
        let merged = mergeIntervals(asleep.map { DateInterval(start: $0.startDate, end: $0.endDate) }, maximumGap: 15 * 60)
        for interval in merged where interval.duration >= 20 * 60 {
            insertActivity(name: "Sleep", activity: "Sleeping", category: "Sleep", source: "health-sleep",
                           start: interval.start, end: interval.end, context: context)
        }
    }

    private func importWorkouts(_ workouts: [HKWorkout], context: ModelContext) {
        for workout in workouts {
            let activity = workoutActivity(workout.workoutActivityType)
            insertActivity(name: "\(activity) workout", activity: activity, category: activity,
                           source: "health-workout", start: workout.startDate, end: workout.endDate, context: context)
        }
    }

    private func importWalkingSamples(_ samples: [HKQuantitySample], context: ModelContext) {
        let watchSamples = samples.filter {
            $0.device?.model?.localizedCaseInsensitiveContains("watch") == true ||
            $0.sourceRevision.source.name.localizedCaseInsensitiveContains("watch")
        }
        let preferred = watchSamples.isEmpty ? samples : watchSamples
        let walkingIntervals = preferred.compactMap { sample -> DateInterval? in
            guard sample.quantity.doubleValue(for: .count()) >= 10 else { return nil }
            let end = max(sample.endDate, sample.startDate.addingTimeInterval(60))
            return DateInterval(start: sample.startDate, end: end)
        }
        let merged = mergeIntervals(walkingIntervals, maximumGap: 5 * 60)
        for interval in merged where interval.duration >= 2 * 60 {
            insertActivity(name: "Walking", activity: "Walking", category: "Walking", source: "health-walking",
                           start: interval.start, end: interval.end, context: context)
        }
    }

    private func importMotionHistory() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        motionManager.queryActivityStarting(from: start, to: .now, to: .main) { [weak self] activities, error in
            Task { @MainActor in
                guard let self, let context = self.context else { return }
                if let error {
                    _ = error
                    self.lastError = "Motion history couldn’t be imported. Check Motion & Fitness permissions."
                    Diagnostics.record(context, subsystem: "Motion",
                                       message: "Motion history import failed; existing timeline data was preserved.")
                    self.refreshMotionStatus()
                    return
                }
                self.importMotionActivities(activities ?? [], context: context)
                try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
                try? context.save()
                self.refreshMotionStatus()
                self.lastImport = .now
            }
        }
    }

    private func importMotionActivities(_ activities: [CMMotionActivity], context: ModelContext) {
        var segments: [ActivitySegment] = []
        for (index, event) in activities.enumerated() {
            guard event.confidence != .low, let activity = motionActivity(event) else { continue }
            let end = index + 1 < activities.count ? activities[index + 1].startDate : Date.now
            let minimumDuration: TimeInterval = activity == "Travelling" ? 3 * 60 : 2 * 60
            guard end.timeIntervalSince(event.startDate) >= minimumDuration else { continue }
            let next = ActivitySegment(activity: activity, start: event.startDate, end: end)
            if let last = segments.last, last.activity == next.activity, next.start.timeIntervalSince(last.end) <= 90 {
                segments[segments.count - 1].end = next.end
            } else {
                segments.append(next)
            }
        }
        for segment in segments {
            // Motion reports automotive movement, while LifeLog presents every transport
            // mode consistently under the broader Travel category.
            let isTravel = segment.activity == "Travelling"
            insertActivity(name: isTravel ? "In transit" : segment.activity,
                           activity: segment.activity, category: isTravel ? "Travel" : segment.activity, source: "motion",
                           start: segment.start, end: segment.end, context: context)
        }
    }

    private func insertActivity(name: String, activity: String, category: String, source: String,
                                start: Date, end: Date, context: ModelContext) {
        guard end > start else { return }
        let existing = importExistingVisits ?? ((try? context.fetch(FetchDescriptor<Visit>())) ?? [])
        let sourceVisits = importVisitsBySource[source] ?? existing.filter { $0.source == source }
        let locationVisits = importExistingVisits == nil
            ? existing.filter(ActivityLocationPolicy.isLocationVisit)
            : importLocationVisits
        let original = DateInterval(start: start, end: end)
        let minimumDuration = ActivityLocationPolicy.minimumRetainedDuration(for: source)
        let segments = ActivityLocationPolicy.remainingSegments(
            for: original,
            locationVisits: locationVisits
        ).filter { $0.duration >= minimumDuration }

        for segment in segments {
            let duplicate = sourceVisits.contains {
                abs($0.arrival.timeIntervalSince(segment.start)) < 120 &&
                abs(($0.departure ?? $0.arrival).timeIntervalSince(segment.end)) < 120
            }
            guard !duplicate else { continue }

            if source == "motion" {
                let healthVisits = importExistingVisits == nil
                    ? existing.filter { $0.source.hasPrefix("health") }
                    : importHealthVisits
                let overlapsWorkout = healthVisits.contains {
                    $0.arrival < segment.end &&
                    ($0.departure ?? .now) > segment.start
                }
                guard !overlapsWorkout else { continue }
            }
            if source == "health-walking" {
                let workouts = importVisitsBySource["health-workout"] ?? existing.filter { $0.source == "health-workout" }
                let overlapsWorkout = workouts.contains {
                    $0.arrival < segment.end &&
                    ($0.departure ?? .now) > segment.start
                }
                guard !overlapsWorkout else { continue }
            }

            let visit = Visit(arrival: segment.start, departure: segment.end, latitude: 0, longitude: 0,
                              placeName: name, placeCategory: category, inferredActivity: activity,
                              userActivity: activity, source: source, recognitionConfidence: "device")
            context.insert(visit)
            importExistingVisits?.append(visit)
            importVisitsBySource[source, default: []].append(visit)
        }
    }

    private func mergeIntervals(_ intervals: [DateInterval], maximumGap: TimeInterval) -> [DateInterval] {
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

    private func motionActivity(_ activity: CMMotionActivity) -> String? {
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

    private func refreshMotionStatus() {
        motionStatus = switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: "Connected"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not connected"
        @unknown default: "Unknown"
        }
    }
}

private extension SleepSummary {
    init(samples: [HKCategorySample], interval: DateInterval) {
        var totalSleep = 0.0
        var timeInBed = 0.0
        var awake = 0.0
        var rem = 0.0
        var core = 0.0
        var deep = 0.0
        var interruptions = 0

        for sample in samples {
            let start = max(sample.startDate, interval.start)
            let end = min(sample.endDate, interval.end)
            guard end > start,
                  let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            let duration = end.timeIntervalSince(start)
            switch value {
            case .inBed:
                timeInBed += duration
            case .asleepREM:
                rem += duration
                totalSleep += duration
            case .asleepCore:
                core += duration
                totalSleep += duration
            case .asleepDeep:
                deep += duration
                totalSleep += duration
            case .asleepUnspecified:
                totalSleep += duration
            case .awake:
                awake += duration
                interruptions += 1
            default:
                break
            }
        }

        self.init(totalSleep: totalSleep, timeInBed: max(timeInBed, totalSleep + awake), awake: awake,
                  rem: rem, core: core, deep: deep, interruptions: interruptions)
    }
}

private struct ActivitySegment {
    let activity: String
    let start: Date
    var end: Date
}
