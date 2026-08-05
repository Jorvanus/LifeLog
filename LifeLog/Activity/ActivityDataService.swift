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
    private var healthObserverQueries: [HKQuery] = []
    private let sleepAnchorKey = "LifeLog.HealthKit.sleepAnchor.v1"
    private let workoutAnchorKey = "LifeLog.HealthKit.workoutAnchor.v1"

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
        configureBackgroundDelivery()
        requestAccessIfNeeded()
        // History remains opt-in. When requested, its queries and writes use isolated
        // actors so navigation and touch handling stay on the main interaction path.
    }

    /// Background delivery is unconditional. It was held behind a debug toggle while
    /// the anchored importer was proved out on-device; leaving it off means Health
    /// only arrives when the app is opened, which is the opposite of what a record of
    /// your life should need from you. The observer callback schedules the same
    /// isolated, anchored import used by Settings; it does not query or write on the
    /// main interaction path.
    private func configureBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard healthObserverQueries.isEmpty else { return }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let types: [HKSampleType] = [sleepType, HKWorkoutType.workoutType()]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                completion()
                Task { @MainActor [weak self] in
                    guard let self, !self.isImporting else { return }
                    self.refreshAutomatically()
                }
            }
            healthStore.execute(query)
            healthObserverQueries.append(query)
            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Asks for Health and Motion once, on first run.
    ///
    /// Both used to wait behind a button in Settings, which meant a fresh install
    /// recorded nothing from either until the owner went looking — and in Motion's
    /// case, silently lost every week that passed before they did.
    func requestAccessIfNeeded() {
        // A UI test run cannot dismiss a system permission sheet, and a sheet over the
        // first screen fails every test that follows it. The seeded run has its own
        // data and needs neither source.
        guard !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }
        Task { await refreshHealthStatus(requestingIfNeeded: true) }
        // Core Motion has no request call: authorisation is raised by the first query,
        // which the automatic refresh performs.
        refreshAutomatically()
    }

    /// Asks HealthKit what it would actually do, and reports that.
    ///
    /// This used to be decided by `healthRequestedKey` — LifeLog's own note that it
    /// had asked once. That note was the only thing gating the prompt, and
    /// `healthStatus` was only ever set as a side effect of a successful request or
    /// import. So if the note was set while authorisation never completed — the
    /// request threw, the app was killed over the sheet, Health data was reset —
    /// LifeLog would never ask again and never update the label. Settings then read
    /// "Not connected" for good, with nothing offering to reconnect.
    ///
    /// `statusForAuthorizationRequest` answers exactly the right question: would the
    /// person be prompted if we asked now? `.shouldRequest` means the prompt is still
    /// available, so take it.
    ///
    /// Note the honest limit: HealthKit never discloses whether a *read* was allowed,
    /// so `.unnecessary` means "already asked", not "granted". Settings says so.
    func refreshHealthStatus(requestingIfNeeded: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthStatus = "Unavailable on this device"
            return
        }
        let status = try? await healthStore.statusForAuthorizationRequest(toShare: [], read: healthTypes)
        switch status {
        case .unnecessary:
            UserDefaults.standard.set(true, forKey: healthRequestedKey)
            healthStatus = "Connected"
        case .shouldRequest:
            healthStatus = "Not connected"
            if requestingIfNeeded { await requestHealthAccess() }
        default:
            healthStatus = "Couldn’t check"
        }
    }

    /// Presents the Health sheet. Safe to call when access was already granted — iOS
    /// simply returns without showing anything — which is what makes it usable as the
    /// Reconnect action in Settings.
    func requestHealthAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthStatus = "Unavailable on this device"
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: healthTypes)
            UserDefaults.standard.set(true, forKey: healthRequestedKey)
            healthStatus = "Connected"
            startImport(healthDays: 2, motionDays: nil)
        } catch {
            lastError = "Health access couldn’t be completed. Check Health permissions in Settings."
            healthStatus = "Couldn’t connect"
        }
    }

    /// Core Motion keeps only about a week of history, and LifeLog imported it solely
    /// when the owner pressed a button in Settings. Miss a week and that week is gone
    /// for good — which is why a phone reporting "Connected" had no motion records at
    /// all, and why walks and drives were missing from the timeline while sleep and
    /// workouts arrived normally. Health has no such problem: its samples persist and
    /// are read by anchor.
    ///
    /// Called at launch, when LifeLog is opened, and whenever Health delivers in the
    /// background, so the rolling window is drained well before it expires.
    func refreshAutomatically(now: Date = .now) {
        // Never interrupt an import in flight: starting one cancels the last, and a
        // half-finished import would lose its place.
        guard !isImporting else { return }
        let last = UserDefaults.standard.object(forKey: motionRefreshKey) as? Date
        if let last, now.timeIntervalSince(last) < motionRefreshInterval { return }

        let motionDays = CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() == .authorized ? 7 : nil
        // Health samples are read by anchor, so repeating this only ever collects what
        // arrived since last time. It rides along rather than needing its own button.
        let healthDays = HKHealthStore.isHealthDataAvailable()
            && UserDefaults.standard.bool(forKey: healthRequestedKey) ? 30 : nil
        guard motionDays != nil || healthDays != nil else { return }

        UserDefaults.standard.set(now, forKey: motionRefreshKey)
        startImport(healthDays: healthDays, motionDays: motionDays)
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
        // Sleep commonly crosses midnight. Padding the request by half a day
        // lets one selected night include stages recorded just outside the
        // visible Insights interval.
        let padded = DateInterval(start: interval.start.addingTimeInterval(-12 * 60 * 60),
                                  end: interval.end.addingTimeInterval(12 * 60 * 60))
        let predicate = HKQuery.predicateForSamples(
            withStart: padded.start,
            end: padded.end,
            options: [.strictStartDate, .strictEndDate]
        )
        do {
            let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                predicates: [.categorySample(type: sleepType, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let samples = try await descriptor.result(for: healthStore)
            return SleepSummary(samples: samples, interval: padded)
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
            let imported = try await importWriter.importStandalone(records) > 0
            if imported { InsightsInvalidation.invalidate(reason: "HealthKit sleep update", context: context) }
            return imported
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
            // HealthKit's cumulative statistic applies source-aware de-duplication
            // for overlapping iPhone and Apple Watch samples. That is the accurate
            // total for Insights and avoids loading tens of thousands of rows.
            let descriptor = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: stepType, predicate: predicate),
                options: .cumulativeSum
            )
            let statistics = try await descriptor.result(for: healthStore)
            let total = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            stepCache[cacheKey] = total
            Diagnostics.performance(context, subsystem: "HealthKit", operation: "step query",
                                    startedAt: startedAt)
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
        // Workout routes are a separate permission from the workout itself. Without
        // it a walk is only a start and an end time, and LifeLog cannot tell a loop
        // around the block from walking about indoors.
        types.insert(HKSeriesType.workoutRoute())
        return types
    }

    private let healthRequestedKey = "LifeLogHealthAccessRequested"
    private let motionRefreshKey = "LifeLog.MotionLastRefreshed"
    /// Often enough that a week of history is never lost, rare enough that opening the
    /// app repeatedly does not re-read the same days.
    private let motionRefreshInterval: TimeInterval = 6 * 60 * 60

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
                var sleepResultAnchor = Data()
                var workoutResultAnchor = Data()
                var deletedSampleIDs: [UUID] = []
                let end = Date.now

                if let healthDays {
                    let start = Calendar.current.date(byAdding: .day, value: -healthDays, to: end) ?? end
                    let interval = DateInterval(start: start, end: end)
                    updateProgress(id: id, state: .reading, title: "Reading sleep…", completed: 0, total: 0)
                    let sleepResult = try await sampleReader.anchoredSleepRecords(
                        in: interval, anchorData: UserDefaults.standard.data(forKey: sleepAnchorKey))
                    records += sleepResult.records
                    sleepResultAnchor = sleepResult.anchorData
                    deletedSampleIDs += sleepResult.deletedSampleIDs
                    try Task.checkCancellation()
                    updateProgress(id: id, state: .reading, title: "Reading workouts…", completed: 0, total: 0)
                    let workoutResult = try await sampleReader.anchoredWorkoutRecords(
                        in: interval, anchorData: UserDefaults.standard.data(forKey: workoutAnchorKey))
                    records += workoutResult.records
                    workoutResultAnchor = workoutResult.anchorData
                    deletedSampleIDs += workoutResult.deletedSampleIDs
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
                if !deletedSampleIDs.isEmpty {
                    _ = try await importWriter.deleteRemovedRecords(sampleIDs: deletedSampleIDs)
                }
                try Task.checkCancellation()
                // Larger background batches reduce SwiftData transaction overhead;
                // the actor remains off the interaction path and cancellation is
                // still checked between each batch.
                let batchSize = 80
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
                // Commit anchors only after all records have been saved. If the
                // task is cancelled or the store fails, the next launch safely
                // re-reads that window and the writer's duplicate checks remain
                // idempotent.
                if healthDays != nil {
                    UserDefaults.standard.set(sleepResultAnchor, forKey: sleepAnchorKey)
                    UserDefaults.standard.set(workoutResultAnchor, forKey: workoutAnchorKey)
                }
                guard importID == id else { return }
                healthStatus = healthDays == nil ? healthStatus : "Connected"
                refreshMotionStatus()
                lastImport = .now
                importProgress = ActivityImportProgress(state: .complete, title: "Import complete",
                                                        completed: records.count, total: records.count)
                importTask = nil
                Diagnostics.performance(context, subsystem: "Activity Import", operation: "background import",
                                        startedAt: startedAt, itemCount: records.count)
                InsightsInvalidation.invalidate(reason: "HealthKit or Motion import", context: context)
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

        var occupied: [Int: [DateInterval]] = [:]
        for sample in samples {
            let start = max(sample.startDate, interval.start)
            let end = min(sample.endDate, interval.end)
            guard end > start,
                  let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            occupied[value.rawValue, default: []].append(DateInterval(start: start, end: end))
        }
        // Watch and phone can report overlapping stage samples. Merge each
        // stage before calculating one overnight session so durations stay
        // accurate and the estimate is never inflated by duplicates.
        for (rawValue, intervals) in occupied {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: rawValue) else { continue }
            let merged = intervals.sorted { $0.start < $1.start }.reduce(into: [DateInterval]()) { result, interval in
                guard let last = result.last else { result.append(interval); return }
                if interval.start <= last.end {
                    result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
                } else { result.append(interval) }
            }
            let duration = merged.reduce(0) { $0 + $1.duration }
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
