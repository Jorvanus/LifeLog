import Foundation
import SwiftData

/// Coordinates invalidation from background imports and HealthKit without
/// sending SwiftData models across actors. The UI cache reads the generation
/// before publishing a snapshot, so stale aggregation cannot survive a write.
actor InsightsAggregationActor {
    static let shared = InsightsAggregationActor()
    private var generation = 0

    func invalidate() {
        generation &+= 1
    }

    func currentGeneration() -> Int { generation }
}

enum InsightsInvalidation {
    enum Scope: String, CaseIterable, Hashable, Sendable {
        case timeline
        case insights
        case places
        case travel
    }
    static let notification = Notification.Name("LifeLog.InsightsInvalidated")

    /// `context` is optional because a few callers invalidate before a model
    /// context is available; when present, the reason is recorded alongside
    /// the app's other privacy-safe diagnostics instead of being discarded.
    /// MainActor-isolated because `ModelContext` isn't Sendable and every
    /// caller already holds one on the main actor.
    @MainActor
    static func invalidate(reason: String, context: ModelContext? = nil) {
        invalidate(scopes: Set(Scope.allCases), reason: reason, context: context)
    }

    /// A scoped reason documents which readers need refreshing even though the
    /// current aggregation actor advances one shared generation. `recordsDiagnostic`
    /// lets a surrounding transaction stage its own event and still publish once.
    @MainActor
    static func invalidate(scopes: Set<Scope>, reason: String, context: ModelContext? = nil,
                           recordsDiagnostic: Bool = true) {
        if recordsDiagnostic {
            Diagnostics.record(context, subsystem: "Insights",
                               message: "Cache invalidated: \(reason) [\(scopes.map(\.rawValue).sorted().joined(separator: ","))]",
                               severity: "info")
        }
        NotificationCenter.default.post(name: notification, object: reason)
        Task { await InsightsAggregationActor.shared.invalidate() }
    }
}
