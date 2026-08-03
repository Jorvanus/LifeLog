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

    init(createdAt: Date = .now, subsystem: String, severity: String = "warning", message: String) {
        self.createdAt = createdAt
        self.subsystem = TextSafety.clean(subsystem, maximumLength: 30)
        self.severity = TextSafety.clean(severity, maximumLength: 12)
        self.message = TextSafety.clean(message, maximumLength: 200)
    }
}

@MainActor
enum Diagnostics {
    static let retentionLimit = 500
    /// Product-level performance budgets. These are intentionally centralized so
    /// device checks and diagnostic records use the same limits.
    enum PerformanceBudget {
        static let responsiveFirstScreen: TimeInterval = 0.25
        static let normalInteraction: TimeInterval = 0.25
        static let insightsDay: TimeInterval = 0.25
        static let insightsMonth: TimeInterval = 0.75
        static let insightsYear: TimeInterval = 1.5

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
                       severity: String = "warning") {
        guard let context else { return }
        context.insert(DiagnosticEvent(subsystem: subsystem, severity: severity, message: message))
        if let existing = try? context.fetch(FetchDescriptor<DiagnosticEvent>(sortBy: [SortDescriptor(\DiagnosticEvent.createdAt, order: .forward)])), existing.count > retentionLimit {
            for event in existing.prefix(existing.count - retentionLimit) { context.delete(event) }
        }
        try? context.save()
    }

    struct PerformanceReport: Codable {
        let generatedAt: Date
        let appVersion: String
        let deviceClass: String
        let osClass: String
        let samples: [Sample]
        struct Sample: Codable { let createdAt: Date; let subsystem: String; let durationMs: Int?; let itemCount: Int?; let severity: String }
    }

    static func makePerformanceReport(events: [DiagnosticEvent]) -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let device = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPhone"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osClass = "iOS \(os.majorVersion).\(os.minorVersion)"
        let samples = events.map { event -> PerformanceReport.Sample in
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
               severity: "info")
    }

    /// Retains one privacy-safe timing sample for a budgeted operation. The
    /// record contains only elapsed time, the budget, and an aggregate count;
    /// it never includes places, coordinates, notes, or health values.
    static func budget(_ context: ModelContext?, subsystem: String, operation: String,
                       startedAt: Date, budget: TimeInterval, itemCount: Int? = nil) {
        let elapsed = Date.now.timeIntervalSince(startedAt)
        let status = elapsed <= budget ? "pass" : "over budget"
        let countText = itemCount.map { ", \($0) items" } ?? ""
        record(context, subsystem: subsystem,
               message: "Budget \(status): \(operation), \(Int((elapsed * 1000).rounded())) ms / \(Int((budget * 1000).rounded())) ms\(countText)",
               severity: elapsed <= budget ? "info" : "warning")
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
        record(context, subsystem: subsystem,
               message: "(operation) failed (\(nsError.domain) code \(nsError.code)).",
               severity: severity)
    }
}
