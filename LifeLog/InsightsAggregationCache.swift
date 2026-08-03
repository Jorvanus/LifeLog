import Foundation

/// Coordinates invalidation from background imports and HealthKit without
/// sending SwiftData models across actors. The UI cache reads the generation
/// before publishing a snapshot, so stale aggregation cannot survive a write.
actor InsightsAggregationActor {
    static let shared = InsightsAggregationActor()
    private var generation = 0

    func invalidate(reason: String) {
        generation &+= 1
        _ = reason
    }

    func currentGeneration() -> Int { generation }
}

enum InsightsInvalidation {
    static let notification = Notification.Name("LifeLog.InsightsInvalidated")

    static func invalidate(reason: String) {
        Task {
            await InsightsAggregationActor.shared.invalidate(reason: reason)
            await MainActor.run {
                NotificationCenter.default.post(name: notification, object: reason)
            }
        }
    }
}
