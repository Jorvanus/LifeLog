import Foundation
import SwiftData

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

    init(createdAt: Date = .now, subsystem: String, severity: String = "warning", message: String,
         category: String = Diagnostics.Category.general) {
        self.createdAt = createdAt
        self.subsystem = TextSafety.clean(subsystem, maximumLength: 30)
        self.severity = TextSafety.clean(severity, maximumLength: 12)
        self.message = TextSafety.clean(message, maximumLength: 200)
        self.category = category
    }
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
    }

    static let storageKey = "LifeLog.Diagnostics.pending.v1"
    /// A store that has stopped accepting writes will keep failing, and each failure
    /// queues another entry. The oldest are the ones that explain how it started, so
    /// the newest are dropped once the queue is full rather than the other way round.
    static let queueLimit = 50

    static func queue(_ entry: Entry, defaults: UserDefaults = .standard) {
        var entries = queued(defaults: defaults)
        guard entries.count < queueLimit else { return }
        entries.append(entry)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

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
        static let performance = "performance"
        static let general = "general"
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

        static func insights(window: InsightWindow) -> TimeInterval {
            switch window {
            case .day: insightsDay
            case .week: 0.5
            case .month: insightsMonth
            case .year: insightsYear
            }
        }
    }

    static func record(_ context: ModelContext?, subsystem: String, message: String,
                       severity: String = "warning", category: String = Category.general) {
        guard let context else { return }
        context.insert(DiagnosticEvent(subsystem: subsystem, severity: severity, message: message, category: category))
        trimToRetentionLimit(context, category: category)
        try? context.save()
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
                              severity: String = "warning", defaults: UserDefaults = .standard) {
        PendingDiagnostics.queue(.init(createdAt: .now, subsystem: subsystem,
                                       severity: severity, message: message), defaults: defaults)
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
            context.insert(DiagnosticEvent(createdAt: entry.createdAt, subsystem: entry.subsystem,
                                           severity: entry.severity, message: entry.message))
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
    private static func trimToRetentionLimit(_ context: ModelContext, category: String) {
        let limit = category == Category.performance ? performanceRetentionLimit : generalRetentionLimit
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
        struct Sample: Codable { let createdAt: Date; let subsystem: String; let durationMs: Int?; let itemCount: Int?; let severity: String }
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

    static func makePerformanceReport(events: [DiagnosticEvent]) -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let device = deviceIdentifier()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osClass = "iOS \(os.majorVersion).\(os.minorVersion)"
        let samples = events
            .filter { $0.category == Category.performance }
            .map { event -> PerformanceReport.Sample in
                let duration = event.message.range(of: #"(\d+) ms"#, options: .regularExpression).flatMap { Int(event.message[$0].split(separator: " ").first ?? "") }
                let count = event.message.range(of: #"(\d+) items"#, options: .regularExpression).flatMap { Int(event.message[$0].split(separator: " ").first ?? "") }
                return .init(createdAt: event.createdAt, subsystem: event.subsystem, durationMs: duration, itemCount: count, severity: event.severity)
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
        let countText = itemCount.map { " (\($0) items)" } ?? ""
        record(context, subsystem: subsystem,
               message: "Slow \(operation): \(Int((elapsed * 1000).rounded())) ms\(countText)",
               severity: "info", category: Category.performance)
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
        let countText = itemCount.map { ", \($0) items" } ?? ""
        record(context, subsystem: subsystem,
               message: "Budget \(status): \(operation), \(Int((elapsed * 1000).rounded())) ms / \(Int((budget * 1000).rounded())) ms\(countText)",
               severity: elapsed <= budget ? "info" : "warning", category: Category.performance)
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
               message: fields.joined(separator: " "), severity: severity)
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
               severity: severity)
    }
}
