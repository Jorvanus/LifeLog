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
    private var context: ModelContext?
    private var modelContainer: ModelContainer?
    private let sampleReader = ActivitySampleReader()
    private var importWriter: ActivityImportActor?
    private var importTask: Task<Void, Never>?
    private var importID: UUID?
    private var stepCache: [String: Double] = [:]

    var healthStatus = "Not connected"
    var motionStatus = "Not connected"
    var lastImport: Date?
    var lastError: String?
    var importProgress: ActivityImportProgress?

    var isImporting: Bool { importProgress?.isActive == true }

    func connect(_ context: ModelContext, container: ModelContainer) {
        self.context = context
        modelContainer = container
        refreshMotionStatus()
        // History remains opt-in. When requested, its queries and writes use isolated
        // actors so navigation and touch handling stay on the main interaction path.
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
                startImport(healthDays: 2, motionDays: nil)
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
        startImport(healthDays: nil, motionDays: 7)
    }

    func importAll() {
        startImport(
            healthDays: HKHealthStore.isHealthDataAvailable() ? 30 : nil,
            motionDays: CMMotionActivityManager.authorizationStatus() == .authorized ? 7 : nil
        )
    }

    func cancelImport() {
        guard isImporting else { return }
        importProgress = ActivityImportProgress(
            state: .cancelling, title: "Cancelling after this batch…",
            completed: importProgress?.completed ?? 0,
            total: importProgress?.total ?? 0
        )
        importTask?.cancel()
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

    /// Refreshes only the displayed Insights period. Sleep remains meaningful while
    /// the user is at Home, so these records deliberately bypass the movement policy
    /// that removes walking and travel while a destination visit is active.
    @discardableResult
    func refreshSleep(for interval: DateInterval, context: ModelContext) async -> Bool {
        guard interval.duration > 0,
              HKHealthStore.isHealthDataAvailable(),
              !isImporting,
              let importWriter = await backgroundWriter() else { return false }
        do {
            let records = try await sampleReader.sleepRecords(in: interval)
            guard !records.isEmpty else { return false }
            return try await importWriter.importStandalone(records) > 0
        } catch {
            Diagnostics.record(error, context: context, subsystem: "HealthKit",
                               operation: "Insights sleep refresh", severity: "info")
            return false
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
            healthStatus = "Connect Apple Health to show steps"
            Diagnostics.record(error, context: context, subsystem: "HealthKit",
                               operation: "step-count query", severity: "info")
            return nil
        }
    }

    private var healthTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKWorkoutType.workoutType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        return types
    }

    private func startImport(healthDays: Int?, motionDays: Int?) {
        guard modelContainer != nil, healthDays != nil || motionDays != nil else { return }
        importTask?.cancel()
        let id = UUID()
        importID = id
        importProgress = ActivityImportProgress(state: .preparing, title: "Preparing import…", completed: 0, total: 0)
        lastError = nil

        importTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date.now
            guard let importWriter = await backgroundWriter() else { return }
            do {
                try await importWriter.prepare()
                var records: [ActivityImportRecord] = []
                let end = Date.now

                if let healthDays {
                    let start = Calendar.current.date(byAdding: .day, value: -healthDays, to: end) ?? end
                    let interval = DateInterval(start: start, end: end)
                    updateProgress(id: id, state: .reading, title: "Reading sleep…", completed: 0, total: 0)
                    records += try await sampleReader.sleepRecords(in: interval)
                    try Task.checkCancellation()
                    updateProgress(id: id, state: .reading, title: "Reading workouts…", completed: 0, total: 0)
                    records += try await sampleReader.workoutRecords(in: interval)
                    try Task.checkCancellation()
                    updateProgress(id: id, state: .reading, title: "Reading walking…", completed: 0, total: 0)
                    records += try await sampleReader.walkingRecords(in: interval)
                }

                if let motionDays {
                    try Task.checkCancellation()
                    let start = Calendar.current.date(byAdding: .day, value: -motionDays, to: end) ?? end
                    updateProgress(id: id, state: .reading, title: "Reading travel…", completed: 0, total: 0)
                    records += try await sampleReader.motionRecords(in: DateInterval(start: start, end: end))
                }

                try Task.checkCancellation()
                let batchSize = 40
                var completed = 0
                for startIndex in stride(from: 0, to: records.count, by: batchSize) {
                    try Task.checkCancellation()
                    let endIndex = min(startIndex + batchSize, records.count)
                    _ = try await importWriter.insertBatch(Array(records[startIndex..<endIndex]))
                    completed = endIndex
                    updateProgress(id: id, state: .saving, title: "Saving activity…",
                                   completed: completed, total: records.count)
                    await Task.yield()
                }
                try Task.checkCancellation()
                try await importWriter.finish()
                guard importID == id else { return }
                healthStatus = healthDays == nil ? healthStatus : "Connected"
                refreshMotionStatus()
                lastImport = .now
                importProgress = ActivityImportProgress(state: .complete, title: "Import complete",
                                                        completed: records.count, total: records.count)
                importTask = nil
                Diagnostics.performance(context, subsystem: "Activity Import", operation: "background import",
                                        startedAt: startedAt, itemCount: records.count)
            } catch is CancellationError {
                await importWriter.cancel()
                guard importID == id else { return }
                importProgress = ActivityImportProgress(state: .cancelled, title: "Import cancelled",
                                                        completed: importProgress?.completed ?? 0,
                                                        total: importProgress?.total ?? 0)
                importTask = nil
            } catch {
                await importWriter.cancel()
                guard importID == id else { return }
                lastError = "Recent activity couldn’t finish importing. Batches already saved remain available."
                importProgress = ActivityImportProgress(state: .failed, title: "Import failed",
                                                        completed: importProgress?.completed ?? 0,
                                                        total: importProgress?.total ?? 0)
                importTask = nil
                Diagnostics.record(error, context: context, subsystem: "Activity Import",
                                   operation: "background import")
            }
        }
    }

    /// ModelActor contexts inherit their creation executor. Constructing this actor
    /// from a detached utility task guarantees its SwiftData context is not main-bound.
    private func backgroundWriter() async -> ActivityImportActor? {
        if let importWriter { return importWriter }
        guard let modelContainer else { return nil }
        let writer = await Task.detached(priority: .utility) {
            ActivityImportActor(modelContainer: modelContainer)
        }.value
        if importWriter == nil { importWriter = writer }
        return importWriter
    }

    private func updateProgress(id: UUID, state: ActivityImportProgress.State, title: String,
                                completed: Int, total: Int) {
        guard importID == id else { return }
        importProgress = ActivityImportProgress(state: state, title: title,
                                                completed: completed, total: total)
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
