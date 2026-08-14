import Foundation
import SwiftData

/// Values crossing from an isolated SwiftData reader back to SwiftUI. Keeping
/// model instances inside the actor prevents a background read from invalidating
/// or accidentally saving the main context while a screen is being displayed.
struct PlaceHistorySummary: Identifiable, Sendable, Hashable {
    let name: String
    let count: Int
    let dominantActivity: String
    let dominantShare: Int
    var id: String { name }
}

struct ArchiveSearchEntry: Identifiable, Sendable, Hashable {
    let stableID: UUID
    let arrival: Date
    let departure: Date?
    let placeName: String
    let activity: String

    var id: UUID { stableID }
}

struct PlaceHistoryEntry: Identifiable, Sendable, Hashable {
    let stableID: UUID
    let arrival: Date
    let departure: Date?
    let placeName: String
    let activity: String
    let recognitionConfidence: String?

    var id: UUID { stableID }
    var duration: TimeInterval { (departure ?? .now).timeIntervalSince(arrival) }
}

/// The only archive-wide reader used by interactive history screens. Full scans
/// are intentional here, but run in this actor and are cached by the shared store
/// generation so a navigation return does not repeat them unnecessarily.
@ModelActor
actor VisitArchiveReader {
    private var usageCache: (generation: Int, counts: [String: Int])?
    private var placeSummaryCache: (generation: Int, summaries: [PlaceHistorySummary], itemCount: Int)?

    func activityUsage(generation: Int) throws -> [String: Int] {
        if let usageCache, usageCache.generation == generation { return usageCache.counts }
        try Task.checkCancellation()
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        var counts: [String: Int] = [:]
        for visit in visits {
            let key = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        try Task.checkCancellation()
        usageCache = (generation, counts)
        return counts
    }

    func placeSummaries(generation: Int) throws -> (summaries: [PlaceHistorySummary], itemCount: Int) {
        if let placeSummaryCache, placeSummaryCache.generation == generation {
            return (placeSummaryCache.summaries, placeSummaryCache.itemCount)
        }
        try Task.checkCancellation()
        let allVisits = try modelContext.fetch(FetchDescriptor<Visit>())
        let locationVisits = allVisits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        var counts: [String: [String: Int]] = [:]
        var eligible = 0
        for visit in allVisits where ActivityLocationPolicy.shouldShowInInsights(visit, locationVisits: locationVisits) {
            let name = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Visit.isPlaceholderName(name), name != "Imported journal" else { continue }
            counts[name, default: [:]][visit.activity, default: 0] += 1
            eligible += 1
        }
        try Task.checkCancellation()
        let summaries = counts.map { name, activities in
            let total = activities.values.reduce(0, +)
            let top = activities.max { $0.value < $1.value }
            return PlaceHistorySummary(
                name: name,
                count: total,
                dominantActivity: top?.key.isEmpty == false ? top!.key : "no activity",
                dominantShare: total > 0 ? Int((Double(top?.value ?? 0) / Double(total) * 100).rounded()) : 0
            )
        }.sorted { $0.count > $1.count }
        placeSummaryCache = (generation, summaries, eligible)
        return (summaries, eligible)
    }

    /// Backs the explicit archive search screen. Deliberately uncached: a search
    /// term changes on nearly every keystroke and a request also carries its own
    /// page offset, so a generation-keyed cache like `placeSummaryCache` above
    /// would need to key on (generation, text, includeNotes, offset) and would
    /// almost never hit. `VisitHistoryQuery.search` is already a bounded fetch,
    /// so there is nothing here worth caching.
    ///
    /// Fetches one row past `limit` to learn whether another page exists without
    /// a second round trip; the extra row is trimmed before returning.
    func search(_ text: String, includeNotes: Bool, limit: Int, offset: Int) throws
    -> (entries: [ArchiveSearchEntry], hasMore: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], false) }
        try Task.checkCancellation()
        let descriptor = VisitHistoryQuery.search(trimmed, includeNotes: includeNotes, limit: limit + 1, offset: offset)
        let rows = try modelContext.fetch(descriptor)
        try Task.checkCancellation()
        let hasMore = rows.count > limit
        let entries = rows.prefix(limit).map { visit in
            ArchiveSearchEntry(stableID: visit.stableID, arrival: visit.arrival, departure: visit.departure,
                               placeName: visit.placeName, activity: visit.activity)
        }
        return (entries, hasMore)
    }

    func placeEntries(named name: String) throws -> [PlaceHistoryEntry] {
        try Task.checkCancellation()
        var placeDescriptor = FetchDescriptor<SavedPlace>(predicate: #Predicate { $0.name == name })
        placeDescriptor.fetchLimit = 1
        let mapsIdentifier = try modelContext.fetch(placeDescriptor).first?.mapsIdentifier
        let candidates: [Visit]
        if let mapsIdentifier, !mapsIdentifier.isEmpty {
            candidates = try modelContext.fetch(VisitHistoryQuery.place(mapsIdentifier: mapsIdentifier))
        } else {
            candidates = try modelContext.fetch(VisitHistoryQuery.legacyPlace(named: name))
        }
        try Task.checkCancellation()
        return candidates.filter { NameKey.same($0.placeName, name) ||
            (mapsIdentifier != nil && $0.mapsIdentifier == mapsIdentifier) }
            .map { visit in
                PlaceHistoryEntry(stableID: visit.stableID, arrival: visit.arrival,
                                  departure: visit.departure, placeName: visit.placeName,
                                  activity: visit.activity,
                                  recognitionConfidence: visit.recognitionConfidence)
            }
    }
}
