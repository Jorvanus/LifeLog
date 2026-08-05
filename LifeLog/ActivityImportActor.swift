import CoreMotion
import Foundation
import HealthKit
import SwiftData

/// Collects a workout route delivered in batches on HealthKit's queue.
///
/// Unchecked because the compiler cannot see the lock, which is the whole point:
/// every access to the two stored properties goes through it. `finish` is the
/// single gate on resuming the continuation — it hands back the route once and
/// returns nil to every later caller, whether the query finished or failed.
private final class RouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [RoutePoint] = []
    private var hasFinished = false

    func append(_ newPoints: [RoutePoint]) {
        lock.lock()
        defer { lock.unlock() }
        points += newPoints
    }

    func finish() -> [RoutePoint]? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished else { return nil }
        hasFinished = true
        return points
    }
}

/// A value-only import payload. HealthKit and Core Motion objects never cross into
/// the SwiftData writer, keeping framework objects and model instances isolated.
struct ActivityImportRecord: Sendable {
    let name: String
    let activity: String
    let source: String
    let start: Date
    let end: Date
    /// The HealthKit sample(s) this record was built from, so a later anchored-query
    /// deletion can be matched back to the visit it produced. Empty for non-HealthKit
    /// sources (motion, walking).
    var healthKitSampleIDs: [UUID] = []
    /// The path this movement followed, where the source recorded one. Only workouts
    /// carry a route; step counts and Core Motion inferences have no coordinates at all.
    var route: [RoutePoint] = []
}

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

struct ActivityAnchorResult: Sendable {
    let records: [ActivityImportRecord]
    let anchorData: Data
    /// HealthKit sample UUIDs removed since the previous anchor. Matched against
    /// each Visit's `healthKitSampleIDs` so a deleted Health record no longer
    /// leaves a stale imported entry in the timeline.
    let deletedSampleIDs: [UUID]
}

/// Health and Motion history is read away from the main actor and converted into
/// small Sendable records before any database work begins.
actor ActivitySampleReader {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()

    func sleepRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        try await anchoredSleepRecords(in: interval, anchorData: nil).records
    }

    func anchoredSleepRecords(in interval: DateInterval, anchorData: Data?) async throws -> ActivityAnchorResult {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ActivityAnchorResult(records: [], anchorData: Data(), deletedSampleIDs: [])
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let anchor = decodeAnchor(anchorData)
        let descriptor = HKAnchoredObjectQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: type, predicate: predicate)], anchor: anchor)
        let result = try await descriptor.result(for: healthStore)
        let samples = result.addedSamples
        try Task.checkCancellation()
        let asleep = samples.compactMap { sample -> (interval: DateInterval, id: UUID)? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  value == .asleepCore || value == .asleepDeep ||
                  value == .asleepREM || value == .asleepUnspecified else { return nil }
            return (DateInterval(start: sample.startDate, end: sample.endDate), sample.uuid)
        }
        let records = mergeWithIdentifiers(asleep, maximumGap: 15 * 60)
            .filter { $0.interval.duration >= 20 * 60 }
            .map {
                ActivityImportRecord(name: "Sleep", activity: "Sleeping",
                                     source: "health-sleep", start: $0.interval.start, end: $0.interval.end,
                                     healthKitSampleIDs: $0.ids)
            }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedSampleIDs: result.deletedObjects.map(\.uuid))
    }

    func anchoredWorkoutRecords(in interval: DateInterval, anchorData: Data?) async throws -> ActivityAnchorResult {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let anchor = decodeAnchor(anchorData)
        let descriptor = HKAnchoredObjectQueryDescriptor<HKWorkout>(
            predicates: [.workout(predicate)], anchor: anchor)
        let result = try await descriptor.result(for: healthStore)
        let workouts = result.addedSamples
        try Task.checkCancellation()
        var records: [ActivityImportRecord] = []
        for workout in workouts {
            let activity = workoutActivity(workout.workoutActivityType)
            records.append(ActivityImportRecord(name: "\(activity) workout", activity: activity,
                                               source: "health-workout",
                                               start: workout.startDate, end: workout.endDate,
                                               healthKitSampleIDs: [workout.uuid],
                                               route: try await route(for: workout)))
            try Task.checkCancellation()
        }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedSampleIDs: result.deletedObjects.map(\.uuid))
    }

    /// The path a workout followed, if one was recorded. A watch or phone workout
    /// stores its GPS track alongside the sample, so this is a walk LifeLog already
    /// has the route for — no extra recording, and no battery cost, only the asking.
    /// Workouts done indoors, or on a device without GPS, simply have no route.
    private func route(for workout: HKWorkout) async throws -> [RoutePoint] {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            anchor: nil
        )
        let routes = try await descriptor.result(for: healthStore).addedSamples
        var points: [RoutePoint] = []
        for route in routes {
            points += try await locations(in: route)
        }
        guard points.count > 1 else { return [] }
        return RouteSimplification.simplify(points.sorted { $0.time < $1.time })
    }

    /// `HKWorkoutRouteQuery` predates async/await and delivers a route in batches, so
    /// the locations are accumulated across callbacks and returned once it reports done.
    ///
    /// The batches arrive on HealthKit's own queue rather than this actor, so the
    /// partial route and the resumed flag live behind a lock. Resuming a continuation
    /// twice is a crash rather than a warning, and `finish()` can only succeed once.
    private func locations(in route: HKWorkoutRoute) async throws -> [RoutePoint] {
        let accumulator = RouteAccumulator()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    guard accumulator.finish() != nil else { return }
                    continuation.resume(throwing: error)
                    return
                }
                accumulator.append((locations ?? []).map(RoutePoint.init))
                guard done, let points = accumulator.finish() else { return }
                continuation.resume(returning: points)
            }
            healthStore.execute(query)
        }
    }

    private func encodeAnchor(_ anchor: HKQueryAnchor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)) ?? Data()
    }

    private func decodeAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data, !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func walkingRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictEndDate
        )
        let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: healthStore)
        try Task.checkCancellation()
        let watchSamples = samples.filter {
            $0.device?.model?.localizedCaseInsensitiveContains("watch") == true ||
            $0.sourceRevision.source.name.localizedCaseInsensitiveContains("watch")
        }
        let preferred = watchSamples.isEmpty ? samples : watchSamples
        let intervals = preferred.compactMap { sample -> DateInterval? in
            guard sample.quantity.doubleValue(for: .count()) >= 10 else { return nil }
            return DateInterval(start: sample.startDate,
                                end: max(sample.endDate, sample.startDate.addingTimeInterval(60)))
        }
        return merge(intervals, maximumGap: 5 * 60)
            .filter { $0.duration >= 2 * 60 }
            .map {
                ActivityImportRecord(name: "Walking", activity: "Walking",
                                     source: "health-walking", start: $0.start, end: $0.end)
            }
    }

    func motionRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        let records: [ActivityImportRecord] = try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.qualityOfService = .utility
            motionManager.queryActivityStarting(from: interval.start, to: interval.end, to: queue) { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: Self.makeMotionRecords(values ?? [], interval: interval)) }
            }
        }
        try Task.checkCancellation()
        return records
    }

    /// Motion framework objects stay on the callback queue; only Sendable value
    /// records cross back into the ingestion actor under Swift 6 concurrency.
    private nonisolated static func makeMotionRecords(
        _ activities: [CMMotionActivity], interval: DateInterval
    ) -> [ActivityImportRecord] {
        var segments: [(activity: String, start: Date, end: Date)] = []
        for (index, event) in activities.enumerated() {
            guard event.confidence != .low, let activity = motionActivity(event) else { continue }
            let end = index + 1 < activities.count ? activities[index + 1].startDate : interval.end
            let minimumDuration: TimeInterval = activity == "Travelling" ? 3 * 60 : 2 * 60
            guard end.timeIntervalSince(event.startDate) >= minimumDuration else { continue }
            if let last = segments.last,
               last.activity == activity,
               event.startDate.timeIntervalSince(last.end) <= 90 {
                segments[segments.count - 1].end = end
            } else {
                segments.append((activity, event.startDate, end))
            }
        }
        return segments.map { segment in
            let isTravel = segment.activity == "Travelling"
            return ActivityImportRecord(
                name: isTravel ? "In transit" : segment.activity,
                activity: segment.activity,
                source: "motion", start: segment.start, end: segment.end
            )
        }
    }

    private func merge(_ intervals: [DateInterval], maximumGap: TimeInterval) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start.timeIntervalSince(last.end) <= maximumGap {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Same merge as above, but keeps track of which sample UUIDs contributed to
    /// each merged interval, so a merged sleep session can still be matched back
    /// to every underlying HealthKit sample if one of them is later deleted.
    private func mergeWithIdentifiers(
        _ items: [(interval: DateInterval, id: UUID)], maximumGap: TimeInterval
    ) -> [(interval: DateInterval, ids: [UUID])] {
        let sorted = items.sorted { $0.interval.start < $1.interval.start }
        var result: [(interval: DateInterval, ids: [UUID])] = []
        for item in sorted {
            if let last = result.last, item.interval.start.timeIntervalSince(last.interval.end) <= maximumGap {
                let merged = DateInterval(start: last.interval.start,
                                          end: max(last.interval.end, item.interval.end))
                result[result.count - 1] = (merged, last.ids + [item.id])
            } else {
                result.append((item.interval, [item.id]))
            }
        }
        return result
    }

    private nonisolated static func motionActivity(_ activity: CMMotionActivity) -> String? {
        if activity.automotive { return "Travelling" }
        if activity.cycling { return "Cycling" }
        if activity.running { return "Running" }
        if activity.walking { return "Walking" }
        return nil
    }

    private func workoutActivity(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking, .hiking: "Walking"
        case .running: "Running"
        case .cycling, .handCycling: "Cycling"
        case .swimming: "Swimming"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength training"
        default: "Exercising"
        }
    }
}

/// Owns an isolated SwiftData context. Each call saves only one small batch so the
/// main context can continue serving Timeline, Insights, and Settings interactions.
@ModelActor
actor ActivityImportActor {
    private var visitsBySource: [String: [Visit]] = [:]
    private var locations: [Visit] = []
    private var healthVisits: [Visit] = []

    func prepare() throws {
        modelContext.autosaveEnabled = false
        let existing = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" }
        ))
        visitsBySource = Dictionary(grouping: existing, by: \.source)
        locations = existing.filter { $0.source == "automatic" || $0.source == "manual" }
        healthVisits = existing.filter { $0.source.hasPrefix("health-") }
    }

    func insertBatch(_ records: [ActivityImportRecord]) throws -> Int {
        var inserted = 0
        for record in records where record.end > record.start {
            let original = DateInterval(start: record.start, end: record.end)
            if record.source != "health-sleep" { boundStay(departedWith: original, record: record) }
            let segments = record.source == "health-sleep"
                ? [original]
                : remainingSegments(for: original).filter {
                    $0.duration >= minimumDuration(for: record.source)
                }

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
        healthVisits.removeAll(keepingCapacity: false)
    }

    /// A walk or drive is how the person left the place they were in, so it bounds
    /// that stay before the stay is subtracted from the record. Without this, a stay
    /// Core Location has not closed yet covers the whole walk and it is never written
    /// at all — the import path's equivalent of the deletion `reconcile` performs.
    private func boundStay(departedWith interval: DateInterval, record: ActivityImportRecord) {
        let text = "\(record.activity) \(record.name)"
        guard ActivityLocationPolicy.describesWalking(record.activity) ||
                ActivityLocationPolicy.describesTravel(text) else { return }
        ActivityLocationPolicy.boundStay(departedWith: interval, stays: locations)
    }

    private func remainingSegments(for activity: DateInterval) -> [DateInterval] {
        let occupied = locations.compactMap { visit -> DateInterval? in
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
