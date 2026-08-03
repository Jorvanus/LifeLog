import CoreMotion
import Foundation
import HealthKit
import SwiftData

/// A value-only import payload. HealthKit and Core Motion objects never cross into
/// the SwiftData writer, keeping framework objects and model instances isolated.
struct ActivityImportRecord: Sendable {
    let name: String
    let activity: String
    let category: String
    let source: String
    let start: Date
    let end: Date
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
    let deletedObjectCount: Int
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
            return ActivityAnchorResult(records: [], anchorData: Data(), deletedObjectCount: 0)
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
        let asleep = samples.compactMap { sample -> DateInterval? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  value == .asleepCore || value == .asleepDeep ||
                  value == .asleepREM || value == .asleepUnspecified else { return nil }
            return DateInterval(start: sample.startDate, end: sample.endDate)
        }
        let records = merge(asleep, maximumGap: 15 * 60)
            .filter { $0.duration >= 20 * 60 }
            .map {
                ActivityImportRecord(name: "Sleep", activity: "Sleeping", category: "Sleep",
                                     source: "health-sleep", start: $0.start, end: $0.end)
            }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedObjectCount: result.deletedObjects.count)
    }

    func workoutRecords(in interval: DateInterval) async throws -> [ActivityImportRecord] {
        try await anchoredWorkoutRecords(in: interval, anchorData: nil).records
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
        let records = workouts.map { workout in
            let activity = workoutActivity(workout.workoutActivityType)
            return ActivityImportRecord(name: "\(activity) workout", activity: activity,
                                        category: activity, source: "health-workout",
                                        start: workout.startDate, end: workout.endDate)
        }
        return ActivityAnchorResult(records: records, anchorData: encodeAnchor(result.newAnchor),
                                    deletedObjectCount: result.deletedObjects.count)
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
                ActivityImportRecord(name: "Walking", activity: "Walking", category: "Walking",
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
                category: isTravel ? "Travel" : segment.activity,
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
                    existing.placeCategory = record.category
                    existing.inferredActivity = record.activity
                    existing.userActivity = record.activity
                    continue
                }
                if record.source == "motion", overlaps(segment, visits: healthVisits) { continue }
                if record.source == "health-walking",
                   overlaps(segment, visits: visitsBySource["health-workout", default: []]) { continue }

                let visit = Visit(
                    arrival: segment.start, departure: segment.end,
                    latitude: 0, longitude: 0,
                    placeName: record.name, placeCategory: record.category,
                    inferredActivity: record.activity, userActivity: record.activity,
                    source: record.source, recognitionConfidence: "device"
                )
                modelContext.insert(visit)
                visitsBySource[record.source, default: []].append(visit)
                if record.source.hasPrefix("health-") { healthVisits.append(visit) }
                inserted += 1
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return inserted
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
            "\($0.activity) \($0.placeCategory)".localizedCaseInsensitiveContains("travel")
        }
        for visit in travel {
            let end = visit.departure ?? .now
            guard let destination = locations.filter({ $0.arrival >= end }).min(by: { $0.arrival < $1.arrival }),
                  let label = destinationLabel(destination) else { continue }
            visit.placeCategory = "Travel"
            visit.inferredActivity = "Travelling to \(label)"
            if visit.userActivity == nil || visit.userActivity == "Travelling" || visit.userActivity == "In transit" {
                visit.userActivity = "Travelling to \(label)"
            }
            visit.recognitionConfidence = label == "Home" || label == "Work" ? "learned" : "medium"
        }
    }

    private func destinationLabel(_ destination: Visit) -> String? {
        let text = "\(destination.placeName) \(destination.placeCategory)".lowercased()
        if destination.placeCategory.localizedCaseInsensitiveContains("work") || text.contains("office") { return "Work" }
        if destination.placeCategory.localizedCaseInsensitiveContains("home") || text.contains("home") { return "Home" }
        let name = destination.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Identifying…", name != "Unknown place" else { return nil }
        let matching = locations.filter { $0.placeName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        let days = Set(matching.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        return matching.count >= 3 && days >= 2 ? name : nil
    }
}
