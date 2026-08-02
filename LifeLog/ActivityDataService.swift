import Foundation
import CoreMotion
import HealthKit
import SwiftData
import Observation

@MainActor @Observable
final class ActivityDataService {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()
    private var context: ModelContext?

    var healthStatus = "Not connected"
    var motionStatus = "Not connected"
    var lastImport: Date?
    var lastError: String?

    func connect(_ context: ModelContext) {
        self.context = context
        do {
            try ActivityLocationPolicy.reconcileAll(context: context)
            try ActivityLocationPolicy.updateTravelDescriptions(context: context)
            try context.save()
        } catch {
            lastError = "Existing activity couldn’t be reconciled with location visits."
        }
        refreshMotionStatus()
        if UserDefaults.standard.bool(forKey: "LifeLogHealthAccessRequested") {
            Task { await importHealthHistory() }
        }
        if CMMotionActivityManager.authorizationStatus() == .authorized { importMotionHistory() }
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
                await importHealthHistory()
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
        Task { await importHealthHistory() }
        if CMMotionActivityManager.authorizationStatus() == .authorized { importMotionHistory() }
    }

    private var healthTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKWorkoutType.workoutType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        return types
    }

    private func importHealthHistory() async {
        guard HKHealthStore.isHealthDataAvailable(), let context else { return }
        let start = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictEndDate)
        do {
            if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                    predicates: [.categorySample(type: sleepType, predicate: datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let samples = try await descriptor.result(for: healthStore)
                importSleep(samples, context: context)
            }
            let workoutDescriptor = HKSampleQueryDescriptor<HKWorkout>(
                predicates: [.workout(datePredicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let workouts = try await workoutDescriptor.result(for: healthStore)
            importWorkouts(workouts, context: context)
            if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
                let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
                    predicates: [.quantitySample(type: stepType, predicate: datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let steps = try await descriptor.result(for: healthStore)
                importWalkingSamples(steps, context: context)
            }
            try context.save()
            healthStatus = "Connected"
            lastImport = .now
        } catch {
            lastError = "Recent Health data couldn’t be imported. Your existing timeline is unchanged."
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
        let existing = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        let original = DateInterval(start: start, end: end)
        let minimumDuration = ActivityLocationPolicy.minimumRetainedDuration(for: source)
        let segments = ActivityLocationPolicy.remainingSegments(
            for: original,
            locationVisits: existing
        ).filter { $0.duration >= minimumDuration }

        for segment in segments {
            let duplicate = existing.contains {
                $0.source == source && abs($0.arrival.timeIntervalSince(segment.start)) < 120 &&
                abs(($0.departure ?? $0.arrival).timeIntervalSince(segment.end)) < 120
            }
            guard !duplicate else { continue }

            if source == "motion" {
                let overlapsWorkout = existing.contains {
                    $0.source.hasPrefix("health") && $0.arrival < segment.end &&
                    ($0.departure ?? .now) > segment.start
                }
                guard !overlapsWorkout else { continue }
            }
            if source == "health-walking" {
                let overlapsWorkout = existing.contains {
                    $0.source == "health-workout" && $0.arrival < segment.end &&
                    ($0.departure ?? .now) > segment.start
                }
                guard !overlapsWorkout else { continue }
            }

            context.insert(Visit(arrival: segment.start, departure: segment.end, latitude: 0, longitude: 0,
                                 placeName: name, placeCategory: category, inferredActivity: activity,
                                 userActivity: activity, source: source, recognitionConfidence: "device"))
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

private struct ActivitySegment {
    let activity: String
    let start: Date
    var end: Date
}
