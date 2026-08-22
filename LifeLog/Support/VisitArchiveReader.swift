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

/// Diagnostics' four archive-derived counts. `needsReview`, `placeScoreBreakdown`,
/// and the resolution candidate/explanation presence are all `Visit` computed
/// properties that decode a raw payload column, so a store predicate alone
/// cannot answer any of them -- this is why `resolutionInspectableCount` still
/// requires reading the automatic visits themselves, not just counting them.
struct DiagnosticsSummary: Sendable, Equatable {
    let provisionalCount: Int
    let supersededCount: Int
    let approximateVisitCount: Int
    let resolutionInspectableCount: Int

    static let empty = DiagnosticsSummary(provisionalCount: 0, supersededCount: 0,
                                          approximateVisitCount: 0, resolutionInspectableCount: 0)
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
///
/// Whole-store `Visit` contract:
/// - Allowed only for an attended backup/import, explicit Archive Repair or complete
///   validation, an attended rename/merge, or an archive statistic with a named
///   result. Each route uses an isolated actor, exposes in-progress/cancellation in
///   its owning screen, and carries the 32,000-row fixture before it is accepted.
/// - `activityUsage`, `placeSummaries`, `completeReviewQueue`, `diagnosticsSummary`,
///   and `historicalPlaceNames` are the statistics exceptions here; they check
///   cancellation, return Sendable summaries, and cache by store generation.
///   `search`, day history, and detail lookups stay bounded.
/// - Launch, Settings setup, ordinary navigation, and a single-day correction must
///   otherwise use a date/identity/limit-bounded descriptor. Timeline's review preview
///   is the explicit exception: it derives after the shell renders from the cached
///   complete queue so its classification agrees with Locations.
@ModelActor
actor VisitArchiveReader {
    private var usageCache: (generation: Int, counts: [String: Int])?
    private var placeSummaryCache: (generation: Int, summaries: [PlaceHistorySummary], itemCount: Int)?
    private var reviewQueueCache: (generation: Int, result: ReviewQueue.PreparedResult, itemCount: Int)?
    private var diagnosticsSummaryCache: (generation: Int, summary: DiagnosticsSummary)?
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

    /// Locations' complete review queue. Timeline derives its seven-day preview
    /// from this same prepared result, so classification and ranking never depend
    /// on which surface asked. Only automatic visits can enter `ReviewQueue`; the
    /// store predicate avoids hydrating manual, journal, Health, and Motion rows.
    func completeReviewQueue(generation: Int, now: Date) throws
    -> (result: ReviewQueue.PreparedResult, itemCount: Int) {
        if let reviewQueueCache, reviewQueueCache.generation == generation {
            return (reviewQueueCache.result, reviewQueueCache.itemCount)
        }
        try Task.checkCancellation()
        let visits = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" }
        ))
        try Task.checkCancellation()
        let result = ReviewQueue.prepare(visits: visits, now: now)
        reviewQueueCache = (generation, result, visits.count)
        return (result, visits.count)
    }

    /// Diagnostics' four counts, off the interaction path. `DiagnosticsView` and
    /// `LocationResolutionChoicesView` each used to keep two whole-model
    /// `@Query`s (`automatic` and `automatic-superseded` visits) alive on the
    /// main actor just to be counted or filtered in Swift -- a live, continuously
    /// re-observing fetch of the entire automatic-visit archive for a screen that
    /// shows only totals until a detail link is tapped. `supersededCount` and the
    /// superseded half of `resolutionInspectableCount` are store-side counts,
    /// since `source`, `resolutionExplanation`, and `candidateData` are all raw
    /// stored columns; `provisionalCount`, `approximateVisitCount`, and the
    /// automatic half of `resolutionInspectableCount` still require the automatic
    /// visits themselves, since `needsReview`, `placeScoreBreakdown`, and the
    /// resolution candidate/explanation accessors all decode a payload column.
    func diagnosticsSummary(generation: Int) throws -> DiagnosticsSummary {
        if let diagnosticsSummaryCache, diagnosticsSummaryCache.generation == generation {
            return diagnosticsSummaryCache.summary
        }
        try Task.checkCancellation()
        let automatic = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" }
        ))
        try Task.checkCancellation()
        let supersededCount = try modelContext.fetchCount(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic-superseded" }
        ))
        let supersededWithPayload = try modelContext.fetchCount(FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                visit.source == "automatic-superseded"
                    && (visit.resolutionExplanation != nil || visit.candidateData != nil)
            }
        ))
        try Task.checkCancellation()
        var provisionalCount = 0
        var approximateVisitCount = 0
        var resolutionInspectableCount = supersededWithPayload
        for visit in automatic {
            if visit.needsReview { provisionalCount += 1 }
            if LocationQuality.isApproximate(recordedAccuracyMeters: visit.placeScoreBreakdown?.accuracyMeters) {
                approximateVisitCount += 1
            }
            if visit.locationResolutionCandidates != nil || visit.locationResolutionExplanation != nil {
                resolutionInspectableCount += 1
            }
        }
        let summary = DiagnosticsSummary(provisionalCount: provisionalCount, supersededCount: supersededCount,
                                         approximateVisitCount: approximateVisitCount,
                                         resolutionInspectableCount: resolutionInspectableCount)
        diagnosticsSummaryCache = (generation, summary)
        return summary
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

    // MARK: - Ask LifeLog

    /// Shared first step for every Ask LifeLog query below: a bounded,
    /// scope-filtered fetch resolved into the same overlap-aware segments the
    /// donut and Timeline are built from. Never returned itself — only ever
    /// consumed on this actor and reduced to a `Sendable` result before crossing
    /// back out, the same discipline every other method here already follows.
    private func scopedSegments(in interval: DateInterval, scope: InsightsScope, now: Date) throws -> [InsightSegment] {
        let visits = try scopedVisits(in: interval, scope: scope)
        try Task.checkCancellation()
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        return InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits, range: interval, now: now)
    }

    private func scopedVisits(in interval: DateInterval, scope: InsightsScope) throws -> [Visit] {
        let start = interval.start, end = interval.end
        try Task.checkCancellation()
        return try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival < end && ($0.departure ?? end) >= start }
        )).filter(scope.includes)
    }

    /// Total hours logged under one resolved activity over a bounded interval —
    /// not a whole category. Backs Ask LifeLog's "activity total" query.
    ///
    /// Matches against every alias the resolved activity answers to (its current
    /// label plus any legacy name), not just its current label:
    /// `ActivityCatalog.renameActivity` rewrites existing visits' text when a
    /// rename happens, but a row written before that rewrite ran, or restored
    /// from a backup taken before it, can still carry the old label. Passing
    /// only the current name here would silently undercount those rows even
    /// though `AskLifeLogResolver` already resolved the phrase past the rename.
    func activityTotalHours(activityAliases names: Set<String>, in interval: DateInterval, scope: InsightsScope, now: Date) throws -> Double {
        let keys = Set(names.map(NameKey.matching)).subtracting([""])
        guard !keys.isEmpty else { return 0 }
        return try scopedSegments(in: interval, scope: scope, now: now)
            .filter { !$0.isUnlogged && keys.contains(NameKey.matching($0.activity)) }
            .reduce(0) { $0 + $1.hours }
    }

    /// Total hours at one specific place over a bounded interval. Backs Ask
    /// LifeLog's "place total" query.
    func placeTotalHours(place name: String, in interval: DateInterval, scope: InsightsScope, now: Date) throws -> Double {
        let key = NameKey.matching(name)
        guard !key.isEmpty else { return 0 }
        return try scopedSegments(in: interval, scope: scope, now: now)
            .filter { !$0.isUnlogged && $0.placeName.map { NameKey.matching($0) == key } == true }
            .reduce(0) { $0 + $1.hours }
    }

    /// Every place's total hours over a bounded interval, ranked the identical
    /// way the donut's own place list is. Backs "most/least time at a place".
    func rankedPlaceHours(in interval: DateInterval, scope: InsightsScope, now: Date) throws -> [PlaceTotal] {
        InsightsSnapshot.makePlaceTotals(segments: try scopedSegments(in: interval, scope: scope, now: now))
    }

    /// Visit counts per place over a bounded interval. Kept separate from
    /// `rankedPlaceHours`: "most visited" and "most time spent" are different
    /// rankings over the same places, and a place with many short stays should
    /// be able to outrank one with fewer, longer ones on this metric.
    func placeVisitCounts(in interval: DateInterval, scope: InsightsScope, now: Date) throws -> [String: Int] {
        let visits = try scopedVisits(in: interval, scope: scope)
            .filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        try Task.checkCancellation()
        var counts: [String: Int] = [:]
        for visit in visits {
            let name = visit.displayPlaceName
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts
    }

    /// Place totals restricted to segments starting on a given weekday and/or
    /// falling in a given time-of-day band. Backs "where did I spend most Friday
    /// evenings" — `weekday`/`timeBand` are already LifeLog's own closed
    /// vocabulary (see `AskLifeLogWeekday`/`AskLifeLogTimeBand`), never raw text.
    func weekdayTimePatternPlaces(weekday: AskLifeLogWeekday?, timeBand: AskLifeLogTimeBand?,
                                  in interval: DateInterval, scope: InsightsScope, now: Date) throws -> [PlaceTotal] {
        let calendar = Calendar.current
        let matching = try scopedSegments(in: interval, scope: scope, now: now).filter { segment in
            guard !segment.isUnlogged else { return false }
            if let weekday, calendar.component(.weekday, from: segment.start) != weekday.rawValue { return false }
            if let timeBand, !timeBand.contains(hour: calendar.component(.hour, from: segment.start)) { return false }
            return true
        }
        return InsightsSnapshot.makePlaceTotals(segments: matching)
    }

    struct AskLifeLogComparison: Sendable, Equatable {
        let name: String
        let hours: Double
        let previousHours: Double
        let delta: Double
    }

    /// The single category with the largest absolute change between one interval
    /// and its comparison baseline, matching `InsightsSnapshot`'s own comparison
    /// selection (same 0.25-hour noise floor). Backs "what changed most".
    func strongestComparison(in interval: DateInterval, previousInterval: DateInterval,
                             scope: InsightsScope, now: Date) throws -> AskLifeLogComparison? {
        let current = InsightsSnapshot.categoryHours(visits: try scopedVisits(in: interval, scope: scope),
                                                      range: interval, now: now)
        let previous = InsightsSnapshot.categoryHours(visits: try scopedVisits(in: previousInterval, scope: scope),
                                                       range: previousInterval, now: now)
        try Task.checkCancellation()
        return Set(current.keys).union(previous.keys)
            .map { name -> AskLifeLogComparison in
                let hours = current[name] ?? 0
                let previousHours = previous[name] ?? 0
                return AskLifeLogComparison(name: name, hours: hours, previousHours: previousHours, delta: hours - previousHours)
            }
            .filter { abs($0.delta) >= 0.25 }
            .max { abs($0.delta) < abs($1.delta) }
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
