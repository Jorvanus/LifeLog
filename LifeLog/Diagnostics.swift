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
}
