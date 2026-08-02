import Foundation
import SwiftData

struct VisitCorrectionSnapshot: Equatable {
    let placeName: String
    let category: String
    let activity: String
    let confidence: String
}

@MainActor
enum CorrectionHistory {
    static func record(visit: Visit, from previous: VisitCorrectionSnapshot,
                       context: ModelContext, reason: String) {
        let current = VisitCorrectionSnapshot(
            placeName: visit.placeName,
            category: visit.placeCategory,
            activity: visit.activity,
            confidence: visit.recognitionConfidence ?? "pending"
        )
        guard previous != current else { return }
        context.insert(VisitCorrection(
            visitArrival: visit.arrival,
            latitude: visit.latitude,
            longitude: visit.longitude,
            previousPlaceName: previous.placeName,
            newPlaceName: current.placeName,
            previousActivity: previous.activity,
            newActivity: current.activity,
            previousConfidence: previous.confidence,
            newConfidence: current.confidence,
            reason: reason
        ))
    }
}
