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
        try? context.save()
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
