import Foundation
import SwiftData

/// One-time cleanup for the duplicate `health-sleep` visits a matching bug in
/// `ActivityImportActor.insertBatch` could create before it was fixed
/// (2026-08-10): a session whose freshly re-merged start moved by more than two
/// minutes between refreshes read as a new visit instead of an update to the
/// existing one, and was inserted beside it.
enum SleepSessionRepair {
    static let repairKey = "sleep-duplicates-merged-v1"

    /// Folds overlapping, or near-adjacent (within the sample reader's own
    /// 15-minute merge gap), `health-sleep` visits into the earliest-starting one
    /// in the cluster — the same "keep the first, absorb the rest" shape
    /// `ActivityLocationPolicy.deduplicateAutomaticLocations` already uses for
    /// duplicate location callbacks.
    @discardableResult
    static func mergeDuplicates(context: ModelContext) throws -> Int {
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "health-sleep" },
            sortBy: [SortDescriptor(\.arrival)]
        ))
        var retained: [Visit] = []
        var merged = 0
        for candidate in visits {
            guard let previous = retained.last else {
                retained.append(candidate)
                continue
            }
            let previousEnd = previous.departure ?? .distantFuture
            let gap = candidate.arrival.timeIntervalSince(previousEnd)
            guard candidate.arrival < previousEnd || gap <= 15 * 60 else {
                retained.append(candidate)
                continue
            }
            previous.arrival = min(previous.arrival, candidate.arrival)
            switch (previous.departure, candidate.departure) {
            case (nil, _), (_, nil): previous.departure = nil
            case let (left?, right?): previous.departure = max(left, right)
            }
            let ids = Set((previous.healthKitSampleIDs ?? []) + (candidate.healthKitSampleIDs ?? []))
            previous.healthKitSampleIDs = ids.isEmpty ? nil : Array(ids)
            // A person's own confirmation on either half of the duplicate outranks
            // the device guess the survivor would otherwise keep.
            if previous.recognition != .confirmed, candidate.recognition == .confirmed {
                previous.recognitionConfidence = candidate.recognitionConfidence
                previous.userActivity = candidate.userActivity
            }
            context.delete(candidate)
            merged += 1
        }
        if merged > 0 { try context.save() }
        return merged
    }
}
