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
}
