import Foundation
import SwiftData

enum DiagnosticSeverity: Codable, Sendable, Equatable, Hashable {
    case info, warning, error
    case unknown(String)

    static let infoRaw = "info"
    static let warningRaw = "warning"
    static let errorRaw = "error"
    init(rawValue: String) {
        switch rawValue {
        case Self.infoRaw: self = .info
        case Self.warningRaw: self = .warning
        case Self.errorRaw: self = .error
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .info: Self.infoRaw
        case .warning: Self.warningRaw
        case .error: Self.errorRaw
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

enum DiagnosticCategory: Codable, Sendable, Equatable, Hashable {
    case performance, general
    /// `LocationDiagnostics`' bucket: resolver decisions and Maps lookups. Kept
    /// distinct from `.general` in name even though it currently shares its
    /// retention limit, so retention can be tuned per-category later without
    /// another string threaded through every call site.
    case location
    case unknown(String)

    static let performanceRaw = "performance"
    static let generalRaw = "general"
    static let locationRaw = "location"
    init(rawValue: String) {
        switch rawValue {
        case Self.performanceRaw: self = .performance
        case Self.generalRaw: self = .general
        case Self.locationRaw: self = .location
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .performance: Self.performanceRaw
        case .general: Self.generalRaw
        case .location: Self.locationRaw
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// The central catalogue of what kind of event a `DiagnosticEvent` records. This is
/// what a performance report reads to decide which typed numeric fields apply,
/// replacing the previous approach of parsing `message` with a regular expression
/// to recover a duration or item count that was only ever informally embedded in
/// human-readable text.
///
/// Open-ended for the same reason `DiagnosticSubsystem` is: a build that predates a
/// new code must still show that event's message rather than fail to decode it.
enum DiagnosticEventCode: Codable, Sendable, Equatable, Hashable {
    /// A row written before this catalogue existed, or by a caller that has not
    /// been given a specific code. Its typed numeric fields are unset by
    /// definition; a reader falls back to the message text alone.
    case legacyMessage
    case generic
    case performanceSample
    case budgetSample
    case locationMetric
    case errorReport
    case storeFailure
    case hardwareValidation
    case unknown(String)

    static let legacyMessageRaw = "legacy-message"
    static let genericRaw = "generic"
    static let performanceSampleRaw = "performance-sample"
    static let budgetSampleRaw = "budget-sample"
    static let locationMetricRaw = "location-metric"
    static let errorReportRaw = "error-report"
    static let storeFailureRaw = "store-failure"
    static let hardwareValidationRaw = "hardware-validation"

    init(rawValue: String) {
        switch rawValue {
        case Self.legacyMessageRaw: self = .legacyMessage
        case Self.genericRaw: self = .generic
        case Self.performanceSampleRaw: self = .performanceSample
        case Self.budgetSampleRaw: self = .budgetSample
        case Self.locationMetricRaw: self = .locationMetric
        case Self.errorReportRaw: self = .errorReport
        case Self.storeFailureRaw: self = .storeFailure
        case Self.hardwareValidationRaw: self = .hardwareValidation
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .legacyMessage: Self.legacyMessageRaw
        case .generic: Self.genericRaw
        case .performanceSample: Self.performanceSampleRaw
        case .budgetSample: Self.budgetSampleRaw
        case .locationMetric: Self.locationMetricRaw
        case .errorReport: Self.errorReportRaw
        case .storeFailure: Self.storeFailureRaw
        case .hardwareValidation: Self.hardwareValidationRaw
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// Subsystems are intentionally open-ended: diagnostics are often the first feature
/// to receive a new component name, and an older build must still show that evidence.
enum DiagnosticSubsystem: Codable, Sendable, Equatable, Hashable {
    case timeline, insights, coreLocation, healthKit, launch, activities, activityImport, store
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "Timeline": self = .timeline
        case "Insights": self = .insights
        case "Core Location": self = .coreLocation
        case "HealthKit": self = .healthKit
        case "Launch": self = .launch
        case "Activities": self = .activities
        case "Activity Import": self = .activityImport
        case "Store": self = .store
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .timeline: "Timeline"
        case .insights: "Insights"
        case .coreLocation: "Core Location"
        case .healthKit: "HealthKit"
        case .launch: "Launch"
        case .activities: "Activities"
        case .activityImport: "Activity Import"
        case .store: "Store"
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// A privacy-safe diagnostic record. Callers must provide generic messages only;
/// this model intentionally has no coordinate, place, or health-data fields.
@Model
final class DiagnosticEvent {
    var createdAt: Date
    var subsystem: String
    var severity: String
    var message: String
    /// Which retention bucket this event competes in. Existing rows created before
    /// this field was added default to "general" via lightweight migration.
    var category: String = Diagnostics.Category.general
    /// What kind of event this is, from `DiagnosticEventCode`'s catalogue. This and
    /// the four fields below are additive, optional-or-defaulted properties, which
    /// SwiftData migrates losslessly with no custom stage: an existing row simply
    /// gets `eventCode = "legacy-message"` and every numeric field `nil`, reading
    /// exactly as before through `message` alone. A row written going forward
    /// always sets a real code and whichever numeric fields apply to it, so a
    /// performance report can read them directly instead of pattern-matching text
    /// that was only ever informally structured.
    var eventCode: String = DiagnosticEventCode.legacyMessage.rawValue
    var durationMs: Int?
    var budgetMs: Int?
    var itemCount: Int?
    var repairCount: Int?

    init(createdAt: Date = .now, subsystem: String, severity: String = DiagnosticSeverity.warningRaw, message: String,
         category: String = Diagnostics.Category.general, eventCode: String = DiagnosticEventCode.generic.rawValue,
         durationMs: Int? = nil, budgetMs: Int? = nil, itemCount: Int? = nil, repairCount: Int? = nil) {
        self.createdAt = createdAt
        self.subsystem = TextSafety.clean(subsystem, maximumLength: 30)
        self.severity = TextSafety.clean(severity, maximumLength: 12)
        self.message = TextSafety.clean(message, maximumLength: 200)
        self.category = category
        self.eventCode = eventCode
        self.durationMs = durationMs
        self.budgetMs = budgetMs
        self.itemCount = itemCount
        self.repairCount = repairCount
    }

    var diagnosticSubsystem: DiagnosticSubsystem { DiagnosticSubsystem(rawValue: subsystem) }
    var diagnosticSeverity: DiagnosticSeverity { DiagnosticSeverity(rawValue: severity) }
    var diagnosticCategory: DiagnosticCategory { DiagnosticCategory(rawValue: category) }
    var diagnosticEventCode: DiagnosticEventCode { DiagnosticEventCode(rawValue: eventCode) }
}

/// Diagnostics waiting for a store that will accept them.
///
/// Deliberately not SwiftData. Everything else LifeLog records assumes the store
/// works; these are the records made when it does not, so they are held somewhere
/// that does not depend on it and survives relaunch on its own.
enum PendingDiagnostics {
    struct Entry: Codable, Equatable {
        let createdAt: Date
        let subsystem: String
        let severity: String
        let message: String
        /// Optional so a queue entry written before event codes existed still
        /// decodes from `UserDefaults` on the next launch: a missing JSON key
        /// simply decodes to `nil`, and `flushPending` falls back to `.storeFailure`
        /// for it, which is what every pre-existing caller of `recordDurable` meant.
        let eventCode: String?

        init(createdAt: Date, subsystem: String, severity: String, message: String, eventCode: String? = nil) {
            self.createdAt = createdAt
            self.subsystem = subsystem
            self.severity = severity
            self.message = message
            self.eventCode = eventCode
        }
    }

    static let storageKey = "LifeLog.Diagnostics.pending.v1"
    /// A store that has stopped accepting writes will keep failing, and each failure
    /// queues another entry. The oldest are the ones that explain how it started, so
    /// the newest are dropped once the queue is full rather than the other way round.
    static let queueLimit = 50

    /// Best effort: `Entry` is a plain `Codable` struct, so `JSONEncoder` failing
    /// here is not a realistic outcome, only a defensive `guard`. There is
    /// deliberately nowhere to report this failure to — this queue exists
    /// specifically so evidence of a store failure survives even when nothing
    /// can be written to the store, so logging its own failure through the
    /// same durable path would be circular.
    static func queue(_ entry: Entry, defaults: UserDefaults = .standard) {
        var entries = queued(defaults: defaults)
        guard entries.count < queueLimit else { return }
        entries.append(entry)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Decoding fallback, missing and corrupt collapsed deliberately: an empty
    /// key and an unreadable one both mean the same thing to every caller —
    /// there is nothing here to flush — and there is no way to tell a person
    /// apart what a corrupted `UserDefaults` value even was. Content this
    /// queue holds is not otherwise recoverable once it fails to decode.
    static func queued(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

@MainActor
enum Diagnostics {
    enum Category {
        static let performance = DiagnosticCategory.performanceRaw
        static let general = DiagnosticCategory.generalRaw
    }

    /// Performance/budget samples are rare (roughly one per launch or Insights view)
    /// but high-value, while location callbacks log far more often. Retaining them
    /// in separate buckets keeps chatty location logging from evicting the timing
    /// data a performance report actually needs.
    static let performanceRetentionLimit = 150
    static let generalRetentionLimit = 350
    /// Product-level performance budgets. These are intentionally centralized so
    /// device checks and diagnostic records use the same limits.
    enum PerformanceBudget {
        static let responsiveFirstScreen: TimeInterval = 0.25
        static let insightsDay: TimeInterval = 0.25
        static let insightsMonth: TimeInterval = 0.75
        static let insightsYear: TimeInterval = 1.5
        static let returnToTimeline: TimeInterval = 0.35
        /// A normal Core Location/Maps mutation only considers the callback's local
        /// repair window plus open stays. At a 32,000-row archive it should remain
        /// comfortably below an interaction frame stall; full recovery is allowed a
        /// larger budget because it is explicit and never runs per callback.
        static let locationMutation: TimeInterval = 0.35
        static let locationFullAudit: TimeInterval = 8

        static func insights(window: InsightWindow) -> TimeInterval {
            switch window {
            case .day: insightsDay
            case .week: 0.5
            case .month: insightsMonth
            case .year: insightsYear
            }
        }
    }

    /// Reentrancy guard: nothing today calls `record`/`stage` from their own
    /// failure path, but both write to the same store they are describing, and
    /// a future change that logged its own `context.save()` failure through
    /// this same entry point would recurse without bound. `record`/`stage`
    /// simply no-op while already inside one another rather than relying on
    /// every future caller to remember not to do that.
    private static var isRecording = false

    /// Best effort by design: a diagnostic that failed to save is a diagnostic
    /// about a healthy path that never gets read, not a mutation a person is
    /// waiting on — `try?` here deliberately does not retry or surface,
    /// because the only two things that could do that (logging again, or
    /// alerting through a UI this call site cannot see) are worse than losing
    /// one event. `recordDurable` exists for the cases that do need to survive
    /// a failed save.
    static func record(_ context: ModelContext?, subsystem: String, message: String,
                       severity: String = DiagnosticSeverity.warningRaw, category: String = Category.general,
                       eventCode: DiagnosticEventCode = .generic, durationMs: Int? = nil,
                       budgetMs: Int? = nil, itemCount: Int? = nil, repairCount: Int? = nil) {
        guard let context, !isRecording else { return }
        isRecording = true
        defer { isRecording = false }
        context.insert(DiagnosticEvent(subsystem: subsystem, severity: severity, message: message, category: category,
                                       eventCode: eventCode.rawValue, durationMs: durationMs, budgetMs: budgetMs,
                                       itemCount: itemCount, repairCount: repairCount))
        trimToRetentionLimit(context, category: category)
        try? context.save()
    }

    /// Adds a diagnostic to the caller's current transaction without saving it.
    /// VisitMutationService uses this so one mutation produces one durable commit,
    /// rather than a diagnostic save followed by a second timeline save. Same
    /// reentrancy guard as `record`, for the same reason.
    static func stage(_ context: ModelContext, subsystem: String, message: String,
                      severity: String = DiagnosticSeverity.warningRaw, category: String = Category.general,
                      eventCode: DiagnosticEventCode = .generic, durationMs: Int? = nil,
                      budgetMs: Int? = nil, itemCount: Int? = nil, repairCount: Int? = nil) {
        guard !isRecording else { return }
        isRecording = true
        defer { isRecording = false }
        context.insert(DiagnosticEvent(subsystem: subsystem, severity: severity, message: message, category: category,
                                       eventCode: eventCode.rawValue, durationMs: durationMs, budgetMs: budgetMs,
                                       itemCount: itemCount, repairCount: repairCount))
        trimToRetentionLimit(context, category: category)
    }

    /// Records an event that must outlive the process that saw it, even when the
    /// store is the thing that is broken.
    ///
    /// `record` writes the event straight into SwiftData, which is exactly what a
    /// failed save cannot rely on: the write that would record the failure is a write
    /// to the store that just refused one. So the event is queued in `UserDefaults`
    /// first — a separate file, with its own protection class, writable whenever the
    /// app is running — and only then offered to the store. If the store takes it, the
    /// queue is emptied; if not, it waits for the next launch.
    static func recordDurable(_ context: ModelContext?, subsystem: String, message: String,
                              severity: String = DiagnosticSeverity.warningRaw,
                              eventCode: DiagnosticEventCode = .storeFailure, defaults: UserDefaults = .standard) {
        PendingDiagnostics.queue(.init(createdAt: .now, subsystem: subsystem,
                                       severity: severity, message: message, eventCode: eventCode.rawValue),
                                 defaults: defaults)
        guard let context else { return }
        flushPending(context, defaults: defaults)
    }

    /// Moves anything queued by `recordDurable` into the store. Call after a save is
    /// known to have worked, and once at launch, so an overnight failure is on screen
    /// in Diagnostics the next morning rather than lost with the process that saw it.
    @discardableResult
    static func flushPending(_ context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        let pending = PendingDiagnostics.queued(defaults: defaults)
        guard !pending.isEmpty else { return 0 }
        for entry in pending {
            // A queue entry written before event codes existed has no `eventCode` of
            // its own; every pre-existing caller of `recordDurable` meant a store
            // failure, so that is the fallback rather than a bare `.generic`.
            context.insert(DiagnosticEvent(createdAt: entry.createdAt, subsystem: entry.subsystem,
                                           severity: entry.severity, message: entry.message,
                                           eventCode: entry.eventCode ?? DiagnosticEventCode.storeFailure.rawValue))
        }
        trimToRetentionLimit(context, category: Category.general)
        // A failure here is the case this whole path exists for. The queue is left
        // alone so the next launch tries again; clearing it would throw away the only
        // copy at the exact moment the store proved it could not hold one.
        do { try context.save() } catch { return 0 }
        PendingDiagnostics.clear(defaults: defaults)
        return pending.count
    }

    /// Keeps the diagnostic log bounded without loading every event on every write.
    /// `record(...)` runs on the hot path (every HealthKit/MapKit/location callback
    /// can log one), so this uses a lightweight count fetch first and only pulls the
    /// specific overflow rows that need deleting, instead of fetching the full table
    /// each time just to check its size. Trimming is scoped to the event's own
    /// category so a burst of location logging can't evict performance samples.
    ///
    /// Best effort: a failed count or fetch here just skips trimming for this
    /// one call rather than failing the write that triggered it — the event
    /// being recorded is more valuable than staying exactly at the retention
    /// limit, and the next successful call trims whatever built up meanwhile.
    private static func trimToRetentionLimit(_ context: ModelContext, category: String) {
        // Typed rather than a raw string compare: `.performance` gets its own
        // headroom, and every other category -- `.general`, `.location`, and any
        // future or unrecognised one -- shares the general bucket.
        let limit: Int
        switch DiagnosticCategory(rawValue: category) {
        case .performance: limit = performanceRetentionLimit
        case .general, .location, .unknown: limit = generalRetentionLimit
        }
        let predicate = #Predicate<DiagnosticEvent> { $0.category == category }
        guard let count = try? context.fetchCount(FetchDescriptor<DiagnosticEvent>(predicate: predicate)),
              count > limit else { return }
        var descriptor = FetchDescriptor<DiagnosticEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\DiagnosticEvent.createdAt, order: .forward)])
        descriptor.fetchLimit = count - limit
        if let stale = try? context.fetch(descriptor) {
            for event in stale { context.delete(event) }
        }
    }

    struct PerformanceReport: Codable {
        let generatedAt: Date
        let appVersion: String
        let deviceClass: String
        let osClass: String
        let samples: [Sample]
        struct Sample: Codable {
            let createdAt: Date; let subsystem: String; let eventCode: String
            let durationMs: Int?; let budgetMs: Int?; let itemCount: Int?; let repairCount: Int?
            let severity: String
        }
    }

    /// A row written before typed fields existed carries its duration and item
    /// count only inside `message`, in the free-text shape `performance`/`budget`
    /// happened to produce at the time. Reached only when `event.durationMs`/
    /// `itemCount` are `nil` -- a typed row never falls back to this.
    private static func legacyDuration(from message: String) -> Int? {
        message.range(of: #"(\d+) ms"#, options: .regularExpression)
            .flatMap { Int(message[$0].split(separator: " ").first ?? "") }
    }
    private static func legacyItemCount(from message: String) -> Int? {
        message.range(of: #"(\d+) items"#, options: .regularExpression)
            .flatMap { Int(message[$0].split(separator: " ").first ?? "") }
    }

    /// The real hardware identifier (e.g. "iPhone16,2"), not a friendly marketing
    /// name. `SIMULATOR_MODEL_IDENTIFIER` only exists in the simulator, so on a
    /// real device this previously always fell back to the generic string "iPhone",
    /// making it impossible to correlate performance samples with hardware.
    private static func deviceIdentifier() -> String {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Best effort: `PerformanceReport` is a plain `Codable` struct built entirely
    /// from primitives, so an encode failure here is not a realistic outcome. An
    /// empty `Data()` fallback writes as a zero-byte file the person can share —
    /// indistinguishable from a report with no samples, which is judged an
    /// acceptable ambiguity for a path this unlikely to ever run.
    static func makePerformanceReport(events: [DiagnosticEvent]) -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let device = deviceIdentifier()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osClass = "iOS \(os.majorVersion).\(os.minorVersion)"
        let samples = events
            .filter { $0.category == Category.performance }
            .map { event -> PerformanceReport.Sample in
                .init(createdAt: event.createdAt, subsystem: event.subsystem, eventCode: event.eventCode,
                      durationMs: event.durationMs ?? legacyDuration(from: event.message),
                      budgetMs: event.budgetMs,
                      itemCount: event.itemCount ?? legacyItemCount(from: event.message),
                      repairCount: event.repairCount,
                      severity: event.severity)
            }
        return (try? JSONEncoder().encode(PerformanceReport(generatedAt: .now, appVersion: version, deviceClass: device, osClass: osClass, samples: samples))) ?? Data()
    }

    /// Records only slow operations. The message intentionally contains timing and
    /// aggregate counts, never coordinates, place names, notes, or Health values.
    static func performance(_ context: ModelContext?, subsystem: String,
                            operation: String, startedAt: Date, itemCount: Int? = nil,
                            threshold: TimeInterval = 0.25) {
        let elapsed = Date.now.timeIntervalSince(startedAt)
        guard elapsed >= threshold else { return }
        let durationMs = Int((elapsed * 1000).rounded())
        let countText = itemCount.map { " (\($0) items)" } ?? ""
        record(context, subsystem: subsystem,
               message: "Slow \(operation): \(durationMs) ms\(countText)",
               severity: "info", category: Category.performance,
               eventCode: .performanceSample, durationMs: durationMs, itemCount: itemCount)
    }

    /// Retains one privacy-safe timing sample for a budgeted operation, whether it
    /// passed or not. The record contains only elapsed time, the budget, and an
    /// aggregate count; it never includes places, coordinates, notes, or health values.
    ///
    /// Unconditional on purpose, unlike `performance` above: a timing sample answers
    /// "was this slow", but only an unconditional record answers "did this run at
    /// all". Conflating the two cost four builds on 8 August, when a repair that ran
    /// and a repair that never ran left the same silence behind — see
    /// `budgetRecordsEveryTime` in `DiagnosticsTests.swift`, which failed the one time
    /// this was made conditional and caught it.
    static func budget(_ context: ModelContext?, subsystem: String, operation: String,
                       startedAt: Date, budget: TimeInterval, itemCount: Int? = nil) {
        let elapsed = Date.now.timeIntervalSince(startedAt)
        let status = elapsed <= budget ? "pass" : "over budget"
        let durationMs = Int((elapsed * 1000).rounded())
        let budgetMs = Int((budget * 1000).rounded())
        let countText = itemCount.map { ", \($0) items" } ?? ""
        record(context, subsystem: subsystem,
               message: "Budget \(status): \(operation), \(durationMs) ms / \(budgetMs) ms\(countText)",
               severity: elapsed <= budget ? "info" : "warning", category: Category.performance,
               eventCode: .budgetSample, durationMs: durationMs, budgetMs: budgetMs, itemCount: itemCount)
    }

    /// Stores structured-but-human-readable location metrics in the existing
    /// bounded event stream. These fields deliberately avoid names and raw
    /// coordinates while remaining detailed enough to diagnose this personal
    /// device's resolver and Maps behavior.
    static func locationMetric(_ context: ModelContext?, operation: String,
                               durationMs: Int? = nil, candidateCount: Int? = nil,
                               cacheHit: Bool? = nil, distanceMeters: Int? = nil,
                               repairs: Int? = nil, correctedSuggestion: Bool? = nil,
                               payloadBytes: Int? = nil,
                               severity: String = "info") {
        var fields = ["operation=\(TextSafety.clean(operation, maximumLength: 40))"]
        if let durationMs { fields.append("duration_ms=\(max(0, durationMs))") }
        if let candidateCount { fields.append("candidates=\(max(0, candidateCount))") }
        if let cacheHit { fields.append("cache_hit=\(cacheHit)") }
        if let distanceMeters { fields.append("distance_m=\(max(0, distanceMeters))") }
        if let repairs { fields.append("repairs=\(max(0, repairs))") }
        if let correctedSuggestion { fields.append("suggestion_corrected=\(correctedSuggestion)") }
        if let payloadBytes { fields.append("payload_bytes=\(max(0, payloadBytes))") }
        record(context, subsystem: "Location Diagnostics",
               message: fields.joined(separator: " "), severity: severity,
               eventCode: .locationMetric, durationMs: durationMs.map { max(0, $0) },
               itemCount: candidateCount.map { max(0, $0) }, repairCount: repairs.map { max(0, $0) })
    }

    /// Error diagnostics retain only an NSError domain/code pair. This distinguishes
    /// protected-store and permission failures without persisting user data.
    static func record(_ error: Error, context: ModelContext?, subsystem: String,
                       operation: String, severity: String = "warning") {
        let nsError = error as NSError
        // `operation` must be interpolated (`\(operation)`), not written as a literal
        // "(operation)". The literal form previously meant every error diagnostic
        // across HealthKit, MapKit, and Activity Import read as the same generic
        // "(operation) failed" text, making it impossible to tell which call site
        // actually failed from the Diagnostics screen.
        record(context, subsystem: subsystem,
               message: "\(operation) failed (\(nsError.domain) code \(nsError.code)).",
               severity: severity, eventCode: .errorReport)
    }
}
