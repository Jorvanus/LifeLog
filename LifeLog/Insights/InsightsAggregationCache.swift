import Foundation
import SwiftData

/// Coordinates invalidation from background imports and HealthKit without
/// sending SwiftData models across actors. The UI cache reads the generation
/// before publishing a snapshot, so stale aggregation cannot survive a write.
///
/// MainActor-isolated rather than a general `actor`: every writer and reader
/// already runs on the main actor (see `InsightsInvalidation.invalidate`, and
/// the `await`-ing views in InsightsView/ActivitiesView/PlaceHistoryView), so
/// the isolation was only ever nominal. Keeping it a general actor let the
/// generation bump and the invalidation notification race as two separately
/// scheduled tasks touching the same actor, with no guaranteed order between
/// them -- a listener could read the pre-bump generation and rebuild its
/// snapshot from stale data. MainActor isolation lets the bump happen
/// synchronously before the notification goes out, closing that race.
@MainActor
final class InsightsAggregationActor {
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
        InsightsAggregationActor.shared.invalidate()
        NotificationCenter.default.post(name: notification, object: reason)
    }
}
