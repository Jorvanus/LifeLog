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

/// Just enough of a visit to place it in time. Backs the Insights
/// retrospectives (`ArchiveRetrospectives`), which only ever ask "when" of a
/// place's history, never "what."
struct PlaceVisitOccurrence: Sendable, Hashable {
    let arrival: Date
    let departure: Date?
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
    /// Keyed on the year boundary and scope too, not just generation: Year's own
    /// date navigation changes `before` far more often than the store itself
    /// changes, and the Insights source-scope picker can change `scope` without
    /// either of the other two moving at all.
    private var historicalPlaceNamesCache: (generation: Int, before: Date, scope: InsightsScope, names: Set<String>)?

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

    /// Every visit at a place matching `name` (the same identity `NameKey` uses
    /// everywhere) strictly before `before`, scoped the same way as the visible
    /// story. Backs `ArchiveRetrospectives.firstVisitToPlace`/
    /// `longestAbsenceFromPlace`, which need archive-wide history a `@Query`
    /// would otherwise force onto the interaction path — this is what used to
    /// be `InsightsView.placeHistory(matching:)`, fetching every visit in the
    /// whole store and filtering in Swift.
    ///
    /// Narrowed in the store first with `localizedStandardContains`, same as
    /// `PlaceVisitLookup` in `VisitEditor.swift`: a superset of the names
    /// `NameKey` calls the same, small enough that the exact match afterward
    /// is cheap regardless of archive size.
    func placeOccurrences(matching name: String, before: Date, scope: InsightsScope) throws -> [PlaceVisitOccurrence] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = NameKey.matching(trimmed)
        guard !key.isEmpty, !Visit.isPlaceholderName(trimmed) else { return [] }
        try Task.checkCancellation()
        let candidates = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName.localizedStandardContains(trimmed) && $0.arrival < before }
        ))
        try Task.checkCancellation()
        return candidates
            .filter { NameKey.matching($0.placeName) == key && scope.includes($0) && ActivityLocationPolicy.isLocationVisit($0) }
            .map { PlaceVisitOccurrence(arrival: $0.arrival, departure: $0.departure) }
    }

    /// Total logged hours across one bounded historical interval, scoped the
    /// same way as the visible story. Backs the "same period a year ago"
    /// comparison — already a narrow, date-scoped fetch as
    /// `InsightsView.yearOverYearHighlight()`, just moved off the main actor
    /// so the interaction path never blocks on it.
    func loggedHours(in interval: DateInterval, scope: InsightsScope, now: Date) throws -> Double {
        let start = interval.start, end = interval.end
        try Task.checkCancellation()
        let visits = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival < end && ($0.departure ?? end) >= start }
        )).filter(scope.includes)
        try Task.checkCancellation()
        return InsightsSnapshot.categoryHours(visits: visits, range: interval, now: now).values.reduce(0, +)
    }

    /// Distinct display names of every place visited before `before`, filtered
    /// the same way Insights already decides what is shown at all
    /// (`ActivityLocationPolicy.shouldShowInInsights`) and scoped the same way
    /// as the visible story. Backs Year's "new this year"/"not visited this
    /// year" place comparisons — this is what used to be
    /// `InsightsView.annualHistoricalPlaces()`, an unbounded whole-archive
    /// fetch on the main actor.
    ///
    /// Genuinely archive-wide by nature: a complete distinct-names answer has
    /// no natural early stop the way a paged search does. Measured against a
    /// 32,000-row synthetic archive (`VisitArchiveReaderTests`) at well under
    /// the budget below running on this background actor, which is what makes
    /// it acceptable without a persisted index or a schema change.
    func historicalPlaceNames(before: Date, scope: InsightsScope, generation: Int) throws -> Set<String> {
        if let historicalPlaceNamesCache, historicalPlaceNamesCache.generation == generation,
           historicalPlaceNamesCache.before == before, historicalPlaceNamesCache.scope == scope {
            return historicalPlaceNamesCache.names
        }
        try Task.checkCancellation()
        let all = try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.arrival < before }))
        let scoped = all.filter(scope.includes)
        let locationVisits = scoped.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        try Task.checkCancellation()
        let names = Set(scoped
            .filter { ActivityLocationPolicy.shouldShowInInsights($0, locationVisits: locationVisits) }
            .map(\.displayPlaceName)
            .filter { !$0.isEmpty })
        historicalPlaceNamesCache = (generation, before, scope, names)
        return names
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
