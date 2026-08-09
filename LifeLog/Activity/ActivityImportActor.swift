import Foundation
import SwiftData

struct ActivityImportProgress: Equatable, Sendable {
    enum State: String, Sendable {
        case preparing, reading, saving, cancelling, complete, cancelled, failed
    }

    let state: State
    let title: String
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return state == .complete ? 1 : 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var isActive: Bool {
        state == .preparing || state == .reading || state == .saving || state == .cancelling
    }
}

/// Owns an isolated SwiftData context. Each call saves only one small batch so the
/// main context can continue serving Timeline, Insights, and Settings interactions.
@ModelActor
actor ActivityImportActor {
    private var visitsBySource: [String: [Visit]] = [:]
    private var locations: [Visit] = []
    // A detached copy of `locations`, index-paired with it, that `boundStay` is free to
    // mutate. Two independent `ModelContext`s — this actor's and the main context's —
    // routinely hold and correct the same stay within the same second: on 2026-08-08 a
    // departure written as 07:16:22 by the main context read back as 07:02:44, the
    // import actor's own stale value, because `boundStay` used to mutate `locations`
    // itself and `context.save()` persisted whatever it landed on regardless of what the
    // main context had just written to the same row. These copies are never inserted
    // into `modelContext`, so mutating them can never be swept into a save — the main
    // context remains the only writer of a stay's own recorded departure, and re-applies
    // the same correction itself right after this import announces it has finished
    // (`ActivityLocationPolicy.reapplyRecentJourneyTiming`). This array exists solely so
    // this session's own segment math sees a bounded stay's shortened window immediately,
    // the same way it always has.
    private var boundableStays: [Visit] = []
    private var healthVisits: [Visit] = []

    func prepare() throws {
        modelContext.autosaveEnabled = false
        let existing = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" }
        ))
        visitsBySource = Dictionary(grouping: existing, by: \.source)
        locations = existing.filter { $0.source == "automatic" || $0.source == "manual" }
        boundableStays = locations.map(Self.detachedCopy)
        healthVisits = existing.filter { $0.source.hasPrefix("health-") }
    }

    private static func detachedCopy(of stay: Visit) -> Visit {
        Visit(arrival: stay.arrival, departure: stay.departure,
             latitude: stay.latitude, longitude: stay.longitude,
             placeName: stay.placeName, source: stay.source)
    }

    func insertBatch(_ records: [ActivityImportRecord]) throws -> Int {
        // Before any stay is allowed to cut up an incoming record, withdraw the stays a
        // workout in this batch shows were walked past. Core Location is at its least
        // reliable moving through an area with businesses in it, and a drive-by arrival
        // that survives here goes on to split the very walk that disproves it.
        supersedeStaysPassedDuringWorkouts(in: records)
        var inserted = 0
        for record in records where record.end > record.start {
            let original = DateInterval(start: record.start, end: record.end)
            if record.source != "health-sleep" { boundStay(departedWith: original, record: record) }
            let segments = segments(for: record, original: original)

            for segment in segments {
                let sourceVisits = visitsBySource[record.source, default: []]
                if let existing = sourceVisits.first(where: {
                    abs($0.arrival.timeIntervalSince(segment.start)) < 120
                }) {
                    // Anchored queries can replay a changed sample. Update the
                    // existing visit instead of creating a second timeline row.
                    existing.departure = segment.end
                    existing.placeName = record.name
                    existing.inferredActivity = record.activity
                    if !record.healthKitSampleIDs.isEmpty {
                        existing.healthKitSampleIDs = record.healthKitSampleIDs
                    }
                    // Only refresh `userActivity` from the device sample if the person
                    // hasn't explicitly confirmed a label on this visit. Without this
                    // guard, a later replay of the same HealthKit/Motion anchor would
                    // silently overwrite a manual correction with the original device
                    // guess (recognitionConfidence == "confirmed" marks a person-picked
                    // activity; see TimelineView.select/applyQuickLabel).
                    if existing.recognitionConfidence != "confirmed" {
                        existing.userActivity = record.activity
                    }
                    // A replayed workout can carry a route the first import did not
                    // have, but an absent route never erases one already recorded.
                    if !record.route.isEmpty { existing.route = record.route }
                    collapseReplayedTravelFragments(inside: segment, keeping: existing, record: record)
                    continue
                }
                if record.source == "motion", overlaps(segment, visits: healthVisits) { continue }
                if record.source == "health-walking",
                   overlaps(segment, visits: visitsBySource["health-workout", default: []]) { continue }

                let visit = Visit(
                    arrival: segment.start, departure: segment.end,
                    latitude: 0, longitude: 0,
                    placeName: record.name,
                    inferredActivity: record.activity, userActivity: record.activity,
                    source: record.source, recognitionConfidence: "device",
                    healthKitSampleIDs: record.healthKitSampleIDs.isEmpty ? nil : record.healthKitSampleIDs
                )
                // Clipped to the segment, so a record split around a stay keeps only
                // the part of the path it actually covers.
                visit.route = record.route.filter { $0.time >= segment.start && $0.time <= segment.end }
                modelContext.insert(visit)
                visitsBySource[record.source, default: []].append(visit)
                if record.source.hasPrefix("health-") { healthVisits.append(visit) }
                inserted += 1
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return inserted
    }

    /// Core Motion is read from a rolling window. Once the reader learns that several
    /// automotive fragments were one drive, its replay must replace the old fragments
    /// instead of leaving them alongside the expanded first row. Confirmed edits are
    /// intentionally left untouched: the device is allowed to revise its own guess,
    /// never the person's correction.
    private func collapseReplayedTravelFragments(inside interval: DateInterval, keeping: Visit,
                                                  record: ActivityImportRecord) {
        guard record.source == "motion",
              ActivityLocationPolicy.describesTravel("\(record.activity) \(record.name)") else { return }
        let redundant = visitsBySource["motion", default: []].filter { visit in
            visit !== keeping && visit.recognitionConfidence != "confirmed" &&
                ActivityLocationPolicy.describesTravel("\(visit.activity) \(visit.placeName)") &&
                visit.arrival >= interval.start && (visit.departure ?? .distantFuture) <= interval.end
        }
        guard !redundant.isEmpty else { return }
        let IDs = Set(redundant.map(\.persistentModelID))
        for visit in redundant { modelContext.delete(visit) }
        visitsBySource["motion"]?.removeAll { IDs.contains($0.persistentModelID) }
    }

    /// Removes imported visits whose originating HealthKit sample was deleted in the
    /// Health app, so a stale entry does not linger in the timeline forever. A visit
    /// the person has manually confirmed is left in place rather than removed, since
    /// their correction stands on its own regardless of the source sample's fate.
    func deleteRemovedRecords(sampleIDs: [UUID]) throws -> Int {
        guard !sampleIDs.isEmpty else { return 0 }
        let deleted = Set(sampleIDs)
        func matches(_ visit: Visit) -> Bool {
            guard visit.recognitionConfidence != "confirmed", let ids = visit.healthKitSampleIDs else { return false }
            return !Set(ids).isDisjoint(with: deleted)
        }
        let toRemove = healthVisits.filter(matches)
        guard !toRemove.isEmpty else { return 0 }
        let removedIDs = Set(toRemove.map(\.persistentModelID))
        for visit in toRemove { modelContext.delete(visit) }
        healthVisits.removeAll { removedIDs.contains($0.persistentModelID) }
        for key in visitsBySource.keys {
            visitsBySource[key]?.removeAll { removedIDs.contains($0.persistentModelID) }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return toRemove.count
    }

    func finish() throws {
        updateTravelDescriptions()
        if modelContext.hasChanges { try modelContext.save() }
        clearSession()
    }

    func cancel() {
        modelContext.rollback()
        clearSession()
    }

    /// Used by the small Insights sleep refresh; the whole operation remains isolated
    /// so it cannot interleave session caches with a larger Settings import.
    func importStandalone(_ records: [ActivityImportRecord]) throws -> Int {
        try prepare()
        defer { clearSession() }
        return try insertBatch(records)
    }

    private func clearSession() {
        visitsBySource.removeAll(keepingCapacity: false)
        locations.removeAll(keepingCapacity: false)
        boundableStays.removeAll(keepingCapacity: false)
        healthVisits.removeAll(keepingCapacity: false)
    }

    /// A walk or drive is how the person left the place they were in, so it bounds
    /// that stay before the stay is subtracted from the record. Without this, a stay
    /// Core Location has not closed yet covers the whole walk and it is never written
    /// at all — the import path's equivalent of the deletion `reconcile` performs.
    ///
    /// Mutates `boundableStays`, never `locations` — see the property comment above.
    private func boundStay(departedWith interval: DateInterval, record: ActivityImportRecord) {
        let text = "\(record.activity) \(record.name)"
        guard ActivityLocationPolicy.describesWalking(record.activity) ||
                ActivityLocationPolicy.describesTravel(text) else { return }
        ActivityLocationPolicy.boundStay(departedWith: interval, stays: boundableStays)
    }

    /// The stretches of a record that survive the places it overlapped.
    ///
    /// Sleep is never subtracted, and neither is a started workout: it is the person's
    /// own account of what that time was, and no Core Location guess outranks it. The
    /// live path has held that position since `ActivityLocationPolicy.reconcile` learned
    /// it; this path had not, so a stay recorded mid-walk cut the workout into fragments
    /// as it was imported — 2.69 km stored as 709 m and 324 m with the middle deleted.
    private func segments(for record: ActivityImportRecord, original: DateInterval) -> [DateInterval] {
        guard record.source != "health-sleep" else { return [original] }
        if ActivityLocationPolicy.isDeclaredJourney(source: record.source, route: record.route,
                                                    stays: locations) {
            return [original]
        }
        return remainingSegments(for: original).filter {
            $0.duration >= minimumDuration(for: record.source)
        }
    }

    /// Applies the passing-stay rule for every workout in the batch, then drops the
    /// withdrawn stays from the cache the splitting reads, so they cannot cut anything.
    ///
    /// `passingStays` is asked against `locations`, never `boundableStays`: it reads
    /// `isIgnored`, which resolves against the ignore registry by `persistentModelID`
    /// and always reads as false for a detached copy that was never inserted into any
    /// context. `locations` and `boundableStays` are index-paired, so the same indices
    /// withdrawn from one are withdrawn from the other, keeping the pairing intact.
    private func supersedeStaysPassedDuringWorkouts(in records: [ActivityImportRecord]) {
        let sessions = records.compactMap { record -> WorkoutJourneys.WorkoutSession? in
            guard record.source == "health-workout", record.end > record.start else { return nil }
            return .init(interval: DateInterval(start: record.start, end: record.end),
                         route: record.route)
        }
        guard !sessions.isEmpty else { return }
        let passed = WorkoutJourneys.passingStays(during: sessions, stays: locations)
        guard !passed.isEmpty else { return }
        let withdrawn = Set(passed.map(\.stay.persistentModelID))
        let kept = locations.indices.filter { !withdrawn.contains(locations[$0].persistentModelID) }
        locations = kept.map { locations[$0] }
        boundableStays = kept.map { boundableStays[$0] }
    }

    private func remainingSegments(for activity: DateInterval) -> [DateInterval] {
        let occupied = boundableStays.compactMap { visit -> DateInterval? in
            let end = visit.departure ?? .now
            guard end > visit.arrival else { return nil }
            return DateInterval(start: visit.arrival, end: end)
        }.sorted { $0.start < $1.start }
        var remaining = [activity]
        for location in occupied {
            remaining = remaining.flatMap { interval in
                guard location.start < interval.end, location.end > interval.start else { return [interval] }
                var pieces: [DateInterval] = []
                if location.start > interval.start {
                    pieces.append(DateInterval(start: interval.start, end: min(location.start, interval.end)))
                }
                if location.end < interval.end {
                    pieces.append(DateInterval(start: max(location.end, interval.start), end: interval.end))
                }
                return pieces
            }
        }
        return remaining
    }

    private func overlaps(_ interval: DateInterval, visits: [Visit]) -> Bool {
        visits.contains {
            $0.arrival < interval.end && ($0.departure ?? .now) > interval.start
        }
    }

    private func minimumDuration(for source: String) -> TimeInterval {
        switch source {
        case "health-sleep": 20 * 60
        case "motion", "health-walking": 2 * 60
        default: 60
        }
    }

    private func updateTravelDescriptions() {
        let travel = visitsBySource["motion", default: []].filter {
            $0.activity.localizedCaseInsensitiveContains("travel")
        }
        for visit in travel {
            let end = visit.departure ?? .now
            guard let destination = locations.filter({ $0.arrival >= end }).min(by: { $0.arrival < $1.arrival }),
                  let label = destinationLabel(destination) else { continue }
            visit.inferredActivity = "Travelling to \(label)"
            if visit.userActivity == nil || visit.userActivity == "Travelling" || visit.userActivity == "In transit" {
                visit.userActivity = "Travelling to \(label)"
            }
            visit.recognitionConfidence = label == "Home" || label == "Work" ? "learned" : "medium"
        }
    }

    private func destinationLabel(_ destination: Visit) -> String? {
        let text = destination.placeName.lowercased()
        if text.contains("work") || text.contains("office") { return "Work" }
        if text.contains("home") { return "Home" }
        let name = destination.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Visit.isPlaceholderName(name) else { return nil }
        let matching = locations.filter { $0.placeName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        let days = Set(matching.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        return matching.count >= 3 && days >= 2 ? name : nil
    }
}
