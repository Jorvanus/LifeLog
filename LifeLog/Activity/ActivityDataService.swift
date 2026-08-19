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
    /// Earliest/latest recorded sleep evidence in the selected session. Optional
    /// keeps summaries from sources that do not provide timing fully usable.
    let sleepStart: Date?
    let sleepEnd: Date?

    init(totalSleep: TimeInterval, timeInBed: TimeInterval, awake: TimeInterval,
         rem: TimeInterval, core: TimeInterval, deep: TimeInterval, interruptions: Int,
         sleepStart: Date? = nil, sleepEnd: Date? = nil) {
        self.totalSleep = totalSleep
        self.timeInBed = timeInBed
        self.awake = awake
        self.rem = rem
        self.core = core
        self.deep = deep
        self.interruptions = interruptions
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
    }

    var estimatedScore: Int {
        let durationPoints = min(50, totalSleep / (8 * 60 * 60) * 50)
        let restorativeRatio = totalSleep > 0 ? (rem + deep) / totalSleep : 0
        let stagePoints = min(30, max(0, restorativeRatio / 0.35 * 30))
        let interruptionPoints = max(0, 20 - Double(interruptions) * 3)
        return Int((durationPoints + stagePoints + interruptionPoints).rounded())
    }
}

/// A person's recent sleep pattern, used only to describe their own recorded
/// timing and duration. It deliberately contains no normative target or health
/// interpretation.
struct SleepPatternBaseline: Equatable, Sendable {
    let averageDuration: TimeInterval
    let usualStartMinute: Int
    let nights: Int

    func timingDifference(from date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let direct = abs(minute - usualStartMinute)
        return min(direct, 24 * 60 - direct)
    }
}

@MainActor @Observable
final class ActivityDataService {
    private let healthStore = HKHealthStore()
    private var context: ModelContext?
    private var modelContainer: ModelContainer?
    private let sampleReader = ActivitySampleReader()
    /// A `Task`, not the actor itself. `backgroundWriter()` awaits `Task.detached`
    /// before this is set, so two overlapping callers (see its own comment) used to
    /// each find it `nil` and each construct their own `ActivityImportActor` --
    /// distinct in-memory instances of the same underlying store, neither able to see
    /// the other's not-yet-saved insert. That produced exact duplicate sleep visits
    /// with identical arrival, departure and HealthKit sample IDs on 2026-08-13 and
    /// -14: two Insights `.task(id:)` refreshes racing at launch, most likely the
    /// same one SwiftUI cancels only cooperatively, so a superseded run kept
    /// importing after a new one started. Caching the creation `Task` instead of its
    /// result makes every caller `await` the same in-flight construction, so there is
    /// only ever one writer regardless of how many callers race to ask for it.
    private var importWriterTask: Task<ActivityImportActor, Never>?
    private let importWriteCoordinator = HealthImportWriteCoordinator()
    private var importTask: Task<Void, Never>?
    private var stepCache: [String: Double] = [:]
    private var healthObserverQueries: [HKQuery] = []
    /// HealthKit requires observer completion only after the anchored work has been
    /// processed. Coalesce arrivals while an import is active instead of acknowledging
    /// a Watch sync that is still waiting behind another batch.
    private let observerDeliveryCoordinator = HealthObserverDeliveryCoordinator()
    private var importCoordinator = IncrementalImportCoordinator()
    private var healthSummaryCache: [String: HealthInsightsSummary] = [:]
    private var sleepPatternCache: [String: SleepPatternBaseline?] = [:]
    private let sleepAnchorKey = "LifeLog.HealthKit.sleepAnchor.v1"
    private let workoutAnchorKey = "LifeLog.HealthKit.workoutAnchor.v1"

    private var usesUITestHealthFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-health-connected")
    }
    private static let uiTestSleepSummary = SleepSummary(
        totalSleep: 7.25 * 60 * 60, timeInBed: 7.75 * 60 * 60,
        awake: 20 * 60, rem: 95 * 60, core: 4 * 60 * 60, deep: 70 * 60,
        interruptions: 1,
        sleepStart: Date(timeIntervalSinceReferenceDate: 789_000_000),
        sleepEnd: Date(timeIntervalSinceReferenceDate: 789_026_100)
    )
    private static let uiTestHealthImportDate = Date(timeIntervalSinceReferenceDate: 789_004_800)

    let ui = HealthUIFacade()
    var healthStatus: String { get { ui.authorizationStatus } set { ui.authorizationStatus = newValue } }
    /// Health categories iOS has never shown a prompt for. Non-empty means a sheet is
    /// still available for them; everything else has been asked once and cannot be
    /// asked again from inside the app.
    var unaskedHealthTypes: [String] { get { ui.unaskedTypes } set { ui.unaskedTypes = newValue } }
    var motionStatus: String { get { ui.motionStatus } set { ui.motionStatus = newValue } }
    var lastImport: Date? { get { ui.lastImport } set { ui.lastImport = newValue } }
    var lastError: String? { get { ui.lastError } set { ui.lastError = newValue } }
    var importProgress: ActivityImportProgress? { get { ui.progress } set { ui.progress = newValue } }
    /// Evidence wording is intentionally narrower than Health authorisation: HealthKit
    /// does not reveal read denials, but a successful query can say what arrived.
    var sleepEvidenceStatus: String { get { ui.sleepEvidenceStatus } set { ui.sleepEvidenceStatus = newValue } }

    var isImporting: Bool { ui.isImporting }

    init() {
        ui.authorizationStatus = usesUITestHealthFixture ? "Connected" : "Not connected"
        ui.lastImport = usesUITestHealthFixture
            ? Self.uiTestHealthImportDate
            : UserDefaults.standard.object(forKey: "LifeLog.HealthLastSuccessfulImport") as? Date
    }

    func connect(_ context: ModelContext, container: ModelContainer) {
        self.context = context
        modelContainer = container
        guard !usesUITestHealthFixture else {
            healthStatus = "Connected"
            unaskedHealthTypes = []
            return
        }
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
        for type in HealthKitTypeCatalog.observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                let delivery = HealthObserverDelivery(completion)
                Task { @MainActor [weak self] in
                    guard let self else { delivery.finish(); return }
                    self.processHealthObserverDelivery(delivery)
                }
            }
            healthStore.execute(query)
            healthObserverQueries.append(query)
            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    private func processHealthObserverDelivery(_ delivery: HealthObserverDelivery) {
        invalidateHealthSummaryCache()
        guard observerDeliveryCoordinator.receive(delivery, importing: isImporting) else { return }
        // Anchors make this cheap; the two-day read is only the bounded sleep rebuild
        // and catches a complete night that was delivered after waking.
        startImport(healthDays: 2, motionDays: nil)
    }

    private func finishHealthObserverDeliveries() {
        observerDeliveryCoordinator.finishAll()
    }

    private func continueQueuedHealthObserverImportIfNeeded() -> Bool {
        guard observerDeliveryCoordinator.takeReplacementIfNeeded() else { return false }
        startImport(healthDays: 2, motionDays: nil)
        return true
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
    /// It is asked **per type**, not for the set as a whole, because the set answer is
    /// all-or-nothing: one never-asked type makes the whole request "should request",
    /// which reads as "not connected" even when everything else was granted years ago.
    /// That is exactly what happened when workout routes were added to `healthTypes`
    /// after sleep, workouts and steps had already been authorised — the label said
    /// "Not connected" and the sheet, correctly, offered only routes.
    ///
    /// Note the honest limit: HealthKit never discloses whether a *read* was allowed,
    /// so "asked" is not "granted". Settings says so.
    func refreshHealthStatus(requestingIfNeeded: Bool = false) async {
        guard !usesUITestHealthFixture else {
            healthStatus = "Connected"
            unaskedHealthTypes = []
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            healthStatus = "Unavailable on this device"
            unaskedHealthTypes = []
            return
        }
        var unasked: [String] = []
        var unknown = false
        for type in healthTypes {
            switch try? await healthStore.statusForAuthorizationRequest(
                toShare: [], read: Self.authorizationProbe(for: type)
            ) {
            case .shouldRequest: unasked.append(Self.healthTypeName(type))
            case .unnecessary: break
            default: unknown = true
            }
        }
        unaskedHealthTypes = unasked.sorted()

        healthStatus = HealthAuthorizationService.status(
            unaskedCount: unasked.count, totalCount: healthTypes.count, hadUnknownResult: unknown
        )
        if unasked.isEmpty, healthStatus == "Connected" {
            UserDefaults.standard.set(true, forKey: healthRequestedKey)
        } else if healthStatus == "Partly connected" {
            // Naming what is outstanding matters: a route permission missing while
            // sleep and workouts work is invisible otherwise, and it is the difference
            // between a walk having a path and being two timestamps.
            healthStatus = "Partly connected"
        }
        if !unasked.isEmpty, requestingIfNeeded { await requestHealthAccess() }
    }

    /// The set to ask HealthKit about when probing one type's status.
    ///
    /// Normally just the type itself. A workout route is the exception: it is a series
    /// hanging off a workout, and HealthKit raises an Objective-C exception —
    /// `_throwIfParentTypeNotRequestedForSharing` — if it is named without its parent
    /// workout type in the same request. That is a trap, not an error: it cannot be
    /// caught from Swift and takes the app down, so the parent has to be included
    /// rather than the failure handled.
    private static func authorizationProbe(for type: HKSampleType) -> Set<HKObjectType> {
        type == HKSeriesType.workoutRoute() ? [type, HKWorkoutType.workoutType()] : [type]
    }

    /// Wording for the Health categories LifeLog reads, for a status line that can say
    /// which one is missing.
    private static func healthTypeName(_ type: HKSampleType) -> String {
        switch type {
        case HKWorkoutType.workoutType(): "Workouts"
        case HKSeriesType.workoutRoute(): "Workout routes"
        case HKObjectType.categoryType(forIdentifier: .sleepAnalysis): "Sleep"
        case HKObjectType.quantityType(forIdentifier: .stepCount): "Steps"
        case HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning): "Walking + running distance"
        case HKObjectType.quantityType(forIdentifier: .activeEnergyBurned): "Active energy"
        case HKObjectType.quantityType(forIdentifier: .appleExerciseTime): "Exercise minutes"
        case HKObjectType.quantityType(forIdentifier: .appleStandTime): "Stand hours"
        case HKObjectType.quantityType(forIdentifier: .restingHeartRate): "Resting heart rate"
        case HKObjectType.quantityType(forIdentifier: .walkingHeartRateAverage): "Walking heart rate"
        case HKObjectType.quantityType(forIdentifier: .heartRateRecoveryOneMinute): "Heart-rate recovery"
        case HKObjectType.quantityType(forIdentifier: .respiratoryRate): "Respiratory rate"
        default: type.identifier
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
    ///
    /// The two sources are throttled separately, and must be. A single six-hourly gate
    /// used to cover both, which quietly disabled the thing background delivery exists
    /// for: an Apple Watch writes the night's sleep to the phone some time after
    /// waking, the sleep observer fired exactly as designed, called this, and was
    /// turned away by a throttle that had been set by a Core Motion sweep. Last
    /// night's sleep would then be missing from the timeline all morning and appear
    /// hours later for no visible reason.
    ///
    /// Motion keeps the long interval because its queries are expensive and its
    /// history spans a week. Workout updates are read by anchor. Sleep uses its anchor
    /// to find changed nights, then reads the bounded recent window in full so delayed
    /// Watch stages form one session; the two-day floor keeps that reliable work small.
    /// `walkingRecords` has no anchored-query equivalent
    /// and re-reads every step-count sample in the window on every call. A flat 30-day
    /// window here, throttled to once every two minutes, meant every foreground
    /// reprocessed roughly a month of steps: a real capture (`LifeLog-Performance-
    /// Report.json`, 9 August) showed 18 imports averaging ~700ms, one at 1.9s, with
    /// item counts flat around 392-421 rather than trending toward the handful of
    /// genuinely new samples since the last read — the signature of a full re-scan,
    /// not an incremental one.
    ///
    /// The window is now sized to the actual gap since the last successful health
    /// refresh, floored at two days (what `requestHealthAccess` already uses for the
    /// same "catch up since last time" purpose) and capped at thirty (what a full
    /// `reimportHealthHistory` re-scans). Opened every few minutes, as this capture
    /// was, it stays at the two-day floor and walking stops being re-read from scratch.
    /// Left closed for a week, it widens to cover the real gap instead of silently
    /// losing that week's walks the way a flat two-day window would have.
    func refreshAutomatically(now: Date = .now) {
        guard !usesUITestHealthFixture else { return }
        // Never interrupt an import in flight: starting one cancels the last, and a
        // half-finished import would lose its place.
        guard !isImporting else { return }

        let lastMotion = UserDefaults.standard.object(forKey: motionRefreshKey) as? Date
        let motionDue = lastMotion.map { now.timeIntervalSince($0) >= motionRefreshInterval } ?? true
        let motionDays = motionDue && MotionActivityReader.isReadable(
            available: CMMotionActivityManager.isActivityAvailable(),
            authorization: CMMotionActivityManager.authorizationStatus()
        ) ? 7 : nil

        let lastHealth = UserDefaults.standard.object(forKey: healthRefreshKey) as? Date
        let healthDue = lastHealth.map { now.timeIntervalSince($0) >= healthRefreshInterval } ?? true
        let healthDays = healthDue && HKHealthStore.isHealthDataAvailable()
            && UserDefaults.standard.bool(forKey: healthRequestedKey)
            ? Self.healthImportWindowDays(since: lastHealth, now: now) : nil

        guard motionDays != nil || healthDays != nil else { return }
        if healthDays != nil { UserDefaults.standard.set(now, forKey: healthRefreshKey) }
        startImport(healthDays: healthDays, motionDays: motionDays)
    }

    /// How many days of Health history the routine refresh re-reads, sized to the
    /// actual gap since the last successful read rather than a flat constant.
    ///
    /// Floored at two days — what `requestHealthAccess` already reads on first
    /// connect — so the window comfortably outlasts `healthRefreshInterval` without
    /// `walkingRecords`, which has no anchored-query equivalent, re-scanning a much
    /// wider window than the gap it exists to cover. Capped at thirty, the same ceiling
    /// `reimportHealthHistory` uses, so a very long absence costs one wide read rather
    /// than an unbounded one. Pure and separated from `refreshAutomatically` so this
    /// sizing can be tested without a `HealthKit`/`ModelContainer` fixture.
    nonisolated static func healthImportWindowDays(since lastHealth: Date?, now: Date) -> Int {
        let gapDays = lastHealth.map { Int((now.timeIntervalSince($0) / (24 * 60 * 60)).rounded(.up)) } ?? 2
        return max(2, min(gapDays, 30))
    }

    /// Forgets where the Health import had got to, so the next one re-reads the window
    /// from the beginning.
    ///
    /// Anchored queries return only what has arrived since the last one, which is what
    /// makes the routine import cheap — and also means anything LifeLog dropped after
    /// reading it is gone for good. Two things need this. A walk deleted by the old
    /// reconciliation rules, before a started workout was protected from being absorbed,
    /// is not coming back any other way. And every workout imported before Health
    /// granted route access has no path stored, which is precisely what decides whether
    /// a walk left the place it started from.
    ///
    /// Safe to repeat. The importer matches a replayed sample to the visit it already
    /// made and updates it in place — it never adds a second row, never overwrites an
    /// activity the person confirmed, and never erases a route with an absent one.
    func reimportHealthHistory() {
        UserDefaults.standard.removeObject(forKey: sleepAnchorKey)
        UserDefaults.standard.removeObject(forKey: workoutAnchorKey)
        UserDefaults.standard.removeObject(forKey: healthRefreshKey)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        startImport(healthDays: 30, motionDays: nil)
    }

    /// Quiesces Health writes while Settings replaces or erases the store. Cancelling
    /// alone is insufficient because an async import may still be between two SwiftData
    /// saves; the same write coordinator used by live Health sync makes the boundary
    /// explicit and prevents a stale import from repopulating erased/restored rows.
    func withStoreReplacement<T>(_ operation: () throws -> T) async rethrows -> T {
        importTask?.cancel()
        await importWriteCoordinator.acquire()
        defer { Task { await importWriteCoordinator.release() } }
        return try operation()
    }

    /// Core Motion has no separate authorization API. Its first history query is the
    /// request, so keep that tiny query behind the explicit Settings action rather
    /// than making a person wait for the next automatic import.
    func requestMotionAccess() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            motionStatus = "Unavailable on this device"
            return
        }
        guard CMMotionActivityManager.authorizationStatus() == .notDetermined else {
            refreshMotionStatus()
            return
        }
        let end = Date.now
        let interval = DateInterval(start: end.addingTimeInterval(-60), end: end)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sampleReader.motionRecords(in: interval)
            } catch {
                // A denial is represented by the system status below; only retain
                // unexpected query failures as a diagnostic for the owner.
                if CMMotionActivityManager.authorizationStatus() == .notDetermined {
                    lastError = "Motion Activity access couldn’t be requested."
                }
            }
            refreshMotionStatus()
        }
    }

    /// Gives the owner a deliberate recovery path when the automatic six-hour sweep
    /// was missed, without resetting the independent HealthKit anchors.
    func refreshMotionHistory() {
        guard CMMotionActivityManager.authorizationStatus() == .authorized else {
            requestMotionAccess()
            return
        }
        startImport(healthDays: nil, motionDays: 7)
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

    /// Step totals for the same weekday over the preceding weeks, newest first.
    ///
    /// A day is only remarkable against the days like it, and weekdays are genuinely
    /// unalike — measuring a Saturday against an average that is mostly Mondays would
    /// report a triumph every weekend. Days with no samples at all are dropped rather
    /// than averaged in as zero, which would otherwise turn a week's holiday from
    /// Health into a permanent personal best.
    func stepHistory(forSameWeekdayAs day: Date, through endOfDay: Date? = nil, weeks: Int) async -> [Double] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        // At 11am, compare the current Sunday with prior Sundays at 11am—not with
        // their completed totals, which makes every ordinary morning look deficient.
        let duration = min(max(endOfDay?.timeIntervalSince(dayStart) ?? dayEnd.timeIntervalSince(dayStart), 0),
                           dayEnd.timeIntervalSince(dayStart))
        var totals: [Double] = []
        for offset in 1...max(1, weeks) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset,
                                            to: dayStart) else { continue }
            let end = start.addingTimeInterval(duration)
            if let steps = await stepCount(for: DateInterval(start: start, end: end)), steps > 0 {
                totals.append(steps)
            }
        }
        return totals
    }

    /// The average night's sleep across the days before `day`, as a duration.
    ///
    /// One query for the whole stretch rather than one per night: the summary is
    /// additive, so the mean is the total over the number of nights, and asking
    /// HealthKit fourteen separate times to learn one number is not worth the wait.
    func averageNightlySleep(before day: Date, nights: Int) async -> TimeInterval? {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: day)
        guard nights > 0,
              let start = calendar.date(byAdding: .day, value: -nights, to: end),
              let summary = await sleepSummary(for: DateInterval(start: start, end: end)),
              summary.totalSleep > 0 else { return nil }
        return summary.totalSleep / Double(nights)
    }

    /// Reads one bounded run of completed nights for a personal baseline. This is
    /// intentionally on-demand from the Health detail screen, never a side effect
    /// of opening Insights or rendering a card.
    func sleepPatternBaseline(before day: Date, nights: Int = 14) async -> SleepPatternBaseline? {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: day)
        guard nights > 0,
              let start = calendar.date(byAdding: .day, value: -nights, to: end) else { return nil }
        let interval = DateInterval(start: start, end: end)
        let key = "sleep-pattern-\(HealthSummaryReader.cacheKey(for: interval))"
        if let cached = sleepPatternCache[key] { return cached }
        let sessions = usesUITestHealthFixture
            ? Self.uiTestSleepSessions(endingBefore: end, calendar: calendar)
            : await sampleReader.sleepSessions(in: interval)
        guard sessions.count >= 3 else {
            sleepPatternCache[key] = nil
            return nil
        }
        let averageDuration = sessions.reduce(0) { $0 + $1.duration } / Double(sessions.count)
        let startMinutes = sessions.map { session -> Int in
            let components = calendar.dateComponents([.hour, .minute], from: session.start)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
        // Sleep starts can sit either side of midnight. Rotate early-morning
        // values into the following day before averaging, then wrap back.
        let rotated = startMinutes.map { $0 < 12 * 60 ? $0 + 24 * 60 : $0 }
        let usualStartMinute = Int((Double(rotated.reduce(0, +)) / Double(rotated.count)).rounded()) % (24 * 60)
        let baseline = SleepPatternBaseline(averageDuration: averageDuration,
                                            usualStartMinute: usualStartMinute,
                                            nights: sessions.count)
        sleepPatternCache[key] = baseline
        return baseline
    }

    /// Reads the selected sleep session on demand so opening Insights does not add a
    /// HealthKit query to every chart render.
    func sleepSummary(for interval: DateInterval) async -> SleepSummary? {
        if usesUITestHealthFixture { return Self.uiTestSleepSummary }
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

    /// Period-scoped Health summary. The query is performed by the reader actor and
    /// cached by exact interval; observer delivery is the only normal invalidation.
    /// Opening a different Insights tab therefore never scans the Health archive.
    func healthSummary(for interval: DateInterval) async -> HealthInsightsSummary? {
        if usesUITestHealthFixture { return uiTestHealthSummary(for: interval) }
        guard interval.duration > 0, HKHealthStore.isHealthDataAvailable() else { return nil }
        let key = HealthSummaryReader.cacheKey(for: interval)
        if let cached = healthSummaryCache[key] { return cached }
        async let fixtures = sampleReader.healthInsightsFixtures(in: interval)
        async let sleep = sleepSummary(for: interval)
        let result = await fixtures
        let summary = HealthInsightsAggregation.summary(
            steps: result.steps, walkingRunningMeters: result.walking,
            activeEnergyKilocalories: result.energy, exerciseMinutes: result.exercise,
            standHours: result.stand, workouts: result.workouts, sleep: await sleep,
            interval: interval, calendar: Calendar.current,
            lastSuccessfulImport: lastImport
        )
        healthSummaryCache[key] = summary
        return summary
    }

    private func uiTestHealthSummary(for interval: DateInterval) -> HealthInsightsSummary {
        let days = max(1, Int((interval.duration / 86_400).rounded(.up)))
        return HealthInsightsSummary(
            steps: Double(days * 10_355), walkingRunningMeters: Double(days) * 7_200,
            activeEnergyKilocalories: Double(days * 540), exerciseMinutes: Double(days * 40),
            standHours: Double(days * 11),
            restingHeartRateBPM: 58, walkingHeartRateBPM: 102,
            heartRateRecoveryBPM: 26, respiratoryRate: 14,
            workouts: [.init(id: UUID(uuidString: "E8DF4817-D15E-4B2C-9A06-8514C9C8DE32")!,
                             type: "Walking", duration: 40 * 60, distanceMeters: 4_100)],
            sleep: Self.uiTestSleepSummary,
            activeStepDays: days, elapsedDays: days,
            source: "Apple Health", lastSuccessfulImport: Self.uiTestHealthImportDate
        )
    }

    private static func uiTestSleepSessions(endingBefore end: Date, calendar: Calendar) -> [HealthSleepSession] {
        (0..<14).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -(offset + 1), to: end)?
                .addingTimeInterval(22.75 * 60 * 60) else { return nil }
            return HealthSleepSession(start: start, end: start.addingTimeInterval(7.25 * 60 * 60),
                                      duration: 7.25 * 60 * 60)
        }
    }

    /// Daily averages for the Health Trends screen. HealthKit owns the raw
    /// samples; LifeLog only keeps the small, display-ready series in memory.
    func healthTrend(for metric: HealthTrendMetric, interval: DateInterval) async -> [HealthTrendPoint] {
        guard interval.duration > 0, HKHealthStore.isHealthDataAvailable() else { return [] }
        let fixtures = await sampleReader.healthTrendFixtures(for: metric, in: interval)
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: fixtures) { calendar.startOfDay(for: $0.start) }
        return grouped.compactMap { day, values in
            let distinct = Dictionary(grouping: values, by: \.id).compactMap { $0.value.first }
            guard !distinct.isEmpty else { return nil }
            return HealthTrendPoint(date: day,
                                    value: distinct.reduce(0) { $0 + $1.value } / Double(distinct.count))
        }.sorted { $0.date < $1.date }
    }

    private func invalidateHealthSummaryCache() {
        healthSummaryCache.removeAll(keepingCapacity: true)
        sleepPatternCache.removeAll(keepingCapacity: true)
        stepCache.removeAll(keepingCapacity: true)
    }

    /// Refreshes only the displayed Insights period. Sleep remains meaningful while
    /// the user is at Home, so these records deliberately bypass the movement policy
    /// that removes walking and travel while a destination visit is active.
    @discardableResult
    func refreshSleep(for interval: DateInterval, context: ModelContext) async -> Bool {
        if usesUITestHealthFixture { return false }
        guard interval.duration > 0,
              HKHealthStore.isHealthDataAvailable(),
              !isImporting,
              let importWriter = await backgroundWriter() else { return false }
        do {
            let records = try await sampleReader.sleepRecords(in: interval)
            guard !records.isEmpty else { return false }
            await importWriteCoordinator.acquire()
            defer { Task { await importWriteCoordinator.release() } }
            // A foreground import may have started while HealthKit was being read.
            // Let that serialized full import own the archive write instead of using
            // a stale snapshot to insert the same sleep session beside it.
            guard !isImporting else { return false }
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
        if usesUITestHealthFixture { return uiTestHealthSummary(for: interval).steps }
        let startedAt = Date.now
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let cacheKey = HealthSummaryReader.cacheKey(for: interval)
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

    /// See `HealthKitTypeCatalog` — this is every type that catalog says LifeLog
    /// reads, so it can never again omit one `configureBackgroundDelivery` or
    /// `ActivitySampleReader` already asks for.
    private var healthTypes: Set<HKSampleType> { HealthKitTypeCatalog.readTypes }

    private let healthRequestedKey = "LifeLogHealthAccessRequested"
    private let motionRefreshKey = "LifeLog.MotionLastRefreshed"
    /// Often enough that a week of history is never lost, rare enough that opening the
    /// app repeatedly does not re-read the same days.
    private let motionRefreshInterval: TimeInterval = 6 * 60 * 60
    private let healthRefreshKey = "LifeLog.HealthLastRefreshed"
    /// Short, because the anchored read only returns what has arrived since the last
    /// one. It exists to stop a burst of observer callbacks from stacking imports, not
    /// to ration the work. Anything longer delays the night's sleep reaching the
    /// timeline after the Watch syncs it.
    private let healthRefreshInterval: TimeInterval = 2 * 60

    private func startImport(healthDays: Int?, motionDays: Int?) {
        guard modelContainer != nil, healthDays != nil || motionDays != nil else {
            if healthDays != nil { finishHealthObserverDeliveries() }
            return
        }
        importTask?.cancel()
        let id = importCoordinator.begin()
        importProgress = ActivityImportProgress(state: .preparing, title: "Preparing import…", completed: 0, total: 0)
        lastError = nil

        importTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date.now
            guard let importWriter = await backgroundWriter() else {
                if healthDays != nil { finishHealthObserverDeliveries() }
                return
            }
            await importWriteCoordinator.acquire()
            defer { Task { await importWriteCoordinator.release() } }
            do {
                try Task.checkCancellation()
                try await importWriter.prepare()
                var records: [ActivityImportRecord] = []
                var rebuiltSleepRecords: [ActivityImportRecord] = []
                var rebuiltSleepWindows: [DateInterval] = []
                var observedSleepDeletion = false
                var sleepResultAnchor = Data()
                var workoutResultAnchor = Data()
                var deletedSampleIDs: [UUID] = []
                var motionSegmentsRead = 0
                let end = Date.now

                if let healthDays {
                    let start = Calendar.current.date(byAdding: .day, value: -healthDays, to: end) ?? end
                    let interval = DateInterval(start: start, end: end)
                    updateProgress(id: id, state: .reading, title: "Reading sleep…", completed: 0, total: 0)
                    let sleepResult = try await sampleReader.anchoredSleepRecords(
                        in: interval, anchorData: UserDefaults.standard.data(forKey: sleepAnchorKey))
                    sleepResultAnchor = sleepResult.anchorData
                    deletedSampleIDs += sleepResult.deletedSampleIDs
                    observedSleepDeletion = !sleepResult.deletedSampleIDs.isEmpty
                    // An anchored delta only says what changed. Re-read the complete
                    // night so separately synced sleep stages become one session.
                    rebuiltSleepWindows.append(interval)
                    rebuiltSleepWindows += await importWriter.sleepWindows(
                        containing: sleepResult.deletedSampleIDs
                    )
                    for window in Self.mergedSleepWindows(rebuiltSleepWindows) {
                        let sleep = try await sampleReader.sleepRecords(in: window)
                        rebuiltSleepRecords += sleep
                    }
                    records += rebuiltSleepRecords
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
                    let motionRecords = try await sampleReader.motionRecords(in: DateInterval(start: start, end: end))
                    motionSegmentsRead = motionRecords.count
                    records += motionRecords
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
                // A successful empty query cannot distinguish "no sleep" from a
                // revoked Health read permission. Only withdraw old evidence when a
                // fresh session arrived, or Health explicitly reported a deletion.
                if healthDays != nil, !rebuiltSleepWindows.isEmpty,
                   !rebuiltSleepRecords.isEmpty || observedSleepDeletion {
                    _ = try await importWriter.reconcileSleepEvidence(
                        in: Self.mergedSleepWindows(rebuiltSleepWindows), expected: rebuiltSleepRecords
                    )
                }
                let importedDays = max(healthDays ?? 0, motionDays ?? 0)
                let importedLookback = importedDays > 0
                    ? TimeInterval(importedDays) * 24 * 60 * 60
                    : nil
                try await importWriter.finish()
                if let importedLookback, let context {
                    // The writer has committed and will not save its stale snapshot
                    // again, so this main-context repair cannot be overwritten by
                    // the import batch that made it necessary.
                    _ = try ActivityLocationPolicy.reapplyRecentMovementAbsorption(
                        context: context, lookback: importedLookback, save: false)
                    _ = try ActivityLocationPolicy.reapplyRecentJourneyTiming(
                        context: context, lookback: importedLookback, save: false)
                    _ = try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(
                        context: context, lookback: importedLookback, save: false)
                    if context.hasChanges { try context.save() }
                }
                // A newer request cancels this task and owns all user-visible state.
                // Its anchor must win too; a superseded read can be replayed safely.
                guard importCoordinator.mayPublish(id) else { return }
                // Commit anchors only after all records have been saved. If the
                // task is cancelled or the store fails, the next launch safely
                // re-reads that window and the writer's duplicate checks remain
                // idempotent.
                if healthDays != nil {
                    UserDefaults.standard.set(sleepResultAnchor, forKey: sleepAnchorKey)
                    UserDefaults.standard.set(workoutResultAnchor, forKey: workoutAnchorKey)
                }
                // A Health observer can replace this combined task before it reaches
                // the Core Motion query. Advance the throttle only after the entire
                // motion read and write completed, otherwise a cancelled attempt
                // falsely suppresses car-trip recovery for the next six hours.
                if motionDays != nil { UserDefaults.standard.set(Date.now, forKey: motionRefreshKey) }
                healthStatus = healthDays == nil ? healthStatus : "Connected"
                refreshMotionStatus()
                lastImport = .now
                UserDefaults.standard.set(lastImport, forKey: "LifeLog.HealthLastSuccessfulImport")
                if !records.isEmpty || !deletedSampleIDs.isEmpty { invalidateHealthSummaryCache() }
                updateSleepEvidenceStatus(rebuiltSleepRecords)
                importProgress = ActivityImportProgress(state: .complete, title: "Import complete",
                                                        completed: records.count, total: records.count)
                importTask = nil
                importCoordinator.finish(id)
                // Unconditionally, not only when slow. This import has its own store
                // connection and its save lands on top of whatever the main context
                // wrote, so "did it run, and when" is the question every visit
                // correction is now sequenced against — and `performance` answered it
                // only on the launches where it happened to exceed 250 ms. The two
                // entries that finally explained four failed fixes on 8 August, at
                // 334 ms and 361 ms, were luck; a faster import left no trace at all.
                // Kept in the performance bucket so chatty location logging cannot
                // evict it, and worded so the performance report still reads both
                // numbers out of it.
                Diagnostics.record(context, subsystem: "Activity Import",
                                   message: "Background import finished: "
                                          + "\(Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded())) ms "
                                          + "(\(records.count) items)",
                                   severity: "info", category: Diagnostics.Category.performance)
                if motionSegmentsRead > 0 {
                    HardwareValidation.recordFirst(.motionHistory, context: context,
                        message: "Core Motion returned \(motionSegmentsRead) segment(s) and the automatic import finished.")
                }
                InsightsInvalidation.invalidate(reason: "HealthKit or Motion import", context: context)
                if continueQueuedHealthObserverImportIfNeeded() { return }
                if healthDays != nil { finishHealthObserverDeliveries() }
            } catch is CancellationError {
                await importWriter.cancel()
                guard importCoordinator.mayPublish(id) else { return }
                importProgress = ActivityImportProgress(state: .cancelled, title: "Import cancelled",
                                                        completed: importProgress?.completed ?? 0,
                                                        total: importProgress?.total ?? 0)
                importTask = nil
                importCoordinator.finish(id)
                if continueQueuedHealthObserverImportIfNeeded() { return }
                if healthDays != nil { finishHealthObserverDeliveries() }
            } catch {
                await importWriter.cancel()
                guard importCoordinator.mayPublish(id) else { return }
                lastError = "Recent activity couldn’t finish importing. Batches already saved remain available."
                importProgress = ActivityImportProgress(state: .failed, title: "Import failed",
                                                        completed: importProgress?.completed ?? 0,
                                                        total: importProgress?.total ?? 0)
                importTask = nil
                importCoordinator.finish(id)
                Diagnostics.record(error, context: context, subsystem: "Activity Import",
                                   operation: "background import")
                if continueQueuedHealthObserverImportIfNeeded() { return }
                if healthDays != nil { finishHealthObserverDeliveries() }
            }
        }
    }

    /// Combines overlapping rebuild ranges so a deleted stage does not issue several
    /// equivalent HealthKit queries for the same night.
    nonisolated static func mergedSleepWindows(_ windows: [DateInterval]) -> [DateInterval] {
        let sorted = windows.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        return sorted.reduce(into: [DateInterval]()) { result, window in
            guard let last = result.last else { result.append(window); return }
            if window.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, window.end))
            } else {
                result.append(window)
            }
        }
    }

    private func updateSleepEvidenceStatus(_ records: [ActivityImportRecord]) {
        let measured = records.filter { SleepEvidence.isMeasured($0.source) }.count
        let inBed = records.filter { $0.source == SleepEvidence.inBedSource }.count
        if measured > 0 {
            sleepEvidenceStatus = "Measured sleep imported"
            HardwareValidation.recordFirst(.measuredSleep, context: context,
                message: "HealthKit delivered measured sleep and LifeLog rebuilt the overnight session.")
        } else if inBed > 0 {
            sleepEvidenceStatus = "Estimated time in bed imported"
            HardwareValidation.recordFirst(.estimatedTimeInBed, context: context,
                message: "HealthKit delivered time-in-bed evidence without measured sleep.")
        } else {
            sleepEvidenceStatus = "No recent measured sleep — wear Watch or add it manually"
        }
        Diagnostics.record(context, subsystem: "HealthKit",
                           message: "Sleep evidence rebuilt: \(measured) measured, \(inBed) in-bed session(s).",
                           severity: "info", category: Diagnostics.Category.performance)
    }

    /// ModelActor contexts inherit their creation executor. Constructing this actor
    /// from a detached utility task guarantees its SwiftData context is not main-bound.
    ///
    /// Caches the construction `Task`, not its result -- see `importWriterTask`'s own
    /// comment for why the difference matters. Assigning the task before the first
    /// `await` keeps the whole check-then-create sequence a single atomic step on the
    /// main actor: a second caller arriving while construction is still in flight
    /// finds `importWriterTask` already set and awaits that same task instead of
    /// starting a second one.
    ///
    /// Internal, not private: `ActivityDataServiceConcurrencyTests` calls this
    /// directly to prove two overlapping callers converge on one actor instance --
    /// the property this whole cache exists for, which no test of the public
    /// `refreshSleep` surface alone can pin down without a live HealthKit fixture.
    func backgroundWriter() async -> ActivityImportActor? {
        if let importWriterTask { return await importWriterTask.value }
        guard let modelContainer else { return nil }
        let task = Task.detached(priority: .utility) {
            ActivityImportActor(modelContainer: modelContainer)
        }
        importWriterTask = task
        return await task.value
    }

    private func updateProgress(id: UUID, state: ActivityImportProgress.State, title: String,
                                completed: Int, total: Int) {
        guard importCoordinator.mayPublish(id) else { return }
        importProgress = ActivityImportProgress(state: state, title: title,
                                                completed: completed, total: total)
    }

    private func refreshMotionStatus() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            motionStatus = "Unavailable on this device"
            return
        }
        motionStatus = switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: "Connected"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
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
        var sleepStart: Date?
        var sleepEnd: Date?

        var occupied: [Int: [DateInterval]] = [:]
        for sample in samples {
            let start = max(sample.startDate, interval.start)
            let end = min(sample.endDate, interval.end)
            guard end > start,
                  let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            occupied[value.rawValue, default: []].append(DateInterval(start: start, end: end))
            if value == .inBed || value == .asleepREM || value == .asleepCore ||
                value == .asleepDeep || value == .asleepUnspecified {
                sleepStart = min(sleepStart ?? start, start)
                sleepEnd = max(sleepEnd ?? end, end)
            }
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
                  rem: rem, core: core, deep: deep, interruptions: interruptions,
                  sleepStart: sleepStart, sleepEnd: sleepEnd)
    }
}
