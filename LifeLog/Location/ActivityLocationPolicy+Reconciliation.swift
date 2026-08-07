import Foundation
import SwiftData
import CoreLocation

/// Orchestration. Runs the rules above over the store: subtracting occupied time from
/// device activity, and repairing timelines earlier versions left behind.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {
    static func remainingSegments(for activity: DateInterval, locationVisits: [Visit], now: Date = .now) -> [DateInterval] {
        let occupied = locationVisits.compactMap { visit -> DateInterval? in
            guard isLocationVisit(visit) else { return nil }
            let end = visit.departure ?? now
            guard end > visit.arrival else { return nil }
            return DateInterval(start: visit.arrival, end: end)
        }
        return subtract(occupied, from: activity)
    }


    /// Reconciles activity imported before a location visit arrived from Core Location.
    static func reconcile(locationVisit: Visit, context: ModelContext, now: Date = .now) throws {
        guard isLocationVisit(locationVisit) else { return }
        let visits = try fetchPolicyVisits(context: context)
        let activities = visits.filter(isMovementActivity)
        // The arriving visit is what supplies the previous stay's departure, so
        // bounding runs against every stay rather than just this one. It is scoped to
        // the last day because this runs inside a Core Location callback; repairing
        // older history is `reconcileAll`'s job, once per installation.
        let recent = activities.filter { ($0.departure ?? now) >= now.addingTimeInterval(-24 * 60 * 60) }
        // Before any stay is allowed to absorb a journey, drop the stays that a running
        // workout explains. Otherwise the drive-by guess both survives and eats the walk.
        // Scoped to the same day's window as `recent`: this runs inside a Core Location
        // callback, and only a workout that could overlap the arriving stay matters.
        // Nine years of workouts would otherwise be compared against every callback.
        let recentWorkouts = visits.filter {
            isWorkoutSession($0) && ($0.departure ?? now) >= now.addingTimeInterval(-24 * 60 * 60)
        }
        WorkoutJourneys.supersedePassingStays(during: recentWorkouts,
                              stays: [locationVisit], context: context, now: now)
        let resumed = boundStays(around: recent, stays: visits.filter(isLocationVisit),
                                 context: context, now: now)
        try reconcile(
            activities: activities,
            against: ([locationVisit] + resumed).filter { !isSupersededLocation($0) },
            context: context,
            now: now
        )
    }


    /// Cleans timelines created by earlier app versions when the model container opens.
    static func reconcileAll(context: ModelContext, now: Date = .now) throws {
        let visits = try fetchPolicyVisits(context: context)
        let activities = visits.filter(isMovementActivity)
        let locations = visits.filter(isLocationVisit)
        WorkoutJourneys.supersedePassingStays(during: visits.filter(isWorkoutSession),
                              stays: locations, context: context, now: now)
        let live = locations.filter { !isSupersededLocation($0) }
        let resumed = boundStays(around: activities, stays: live, context: context, now: now)
        try reconcile(
            activities: activities,
            against: (live + resumed).filter { !isSupersededLocation($0) },
            context: context,
            now: now
        )
    }

    static func fetchPolicyVisits(context: ModelContext) throws -> [Visit] {
        // Imported journals already contain resolved activity/location pairs and never
        // participate in live movement reconciliation. Excluding them avoids loading a
        // large archive during location updates.
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" }
        )
        return try context.fetch(descriptor)
    }


    private static func reconcile(activities: [Visit], against locations: [Visit],
                                  context: ModelContext, now: Date) throws {
        for activity in activities {
            let activityEnd = activity.departure ?? now
            guard activityEnd > activity.arrival else { continue }
            let interval = DateInterval(start: activity.arrival, end: activityEnd)
            let minimumDuration = minimumRetainedDuration(for: activity.source)
            // A stay the journey's own path shows it left cannot also have occupied
            // that time. Subtracting it would delete the walk that proves the point.
            //
            // A started workout is never occupied at all. Without this, a walk with no
            // route — which is every walk until Health grants route access — is
            // subtracted by whatever stays overlap it, and `remaining` comes back empty:
            // `case 0` below then *deletes* the workout outright. A walk out of the
            // house and back, with a drive-by stay recorded partway round, disappears
            // from Timeline and Insights entirely rather than merely being absorbed.
            let occupying = isDeclaredJourney(activity, stays: locations)
                ? []
                : locations.filter { leftStay(activity, stay: $0) != true }
            let remaining = remainingSegments(for: interval, locationVisits: occupying, now: now)
                .filter { $0.duration >= minimumDuration }

            switch remaining.count {
            case 0:
                context.delete(activity)
            case 1:
                activity.arrival = remaining[0].start
                activity.departure = remaining[0].end
            default:
                activity.arrival = remaining[0].start
                activity.departure = remaining[0].end
                for segment in remaining.dropFirst() {
                    context.insert(copy(of: activity, interval: segment))
                }
            }
        }
    }

    private static func subtract(_ occupied: [DateInterval], from activity: DateInterval) -> [DateInterval] {
        occupied.sorted { $0.start < $1.start }.reduce([activity]) { segments, location in
            segments.flatMap { segment in subtract(location, from: segment) }
        }
    }

    private static func subtract(_ occupied: DateInterval, from activity: DateInterval) -> [DateInterval] {
        guard occupied.start < activity.end, occupied.end > activity.start else { return [activity] }
        var result: [DateInterval] = []
        if occupied.start > activity.start {
            result.append(DateInterval(start: activity.start, end: min(occupied.start, activity.end)))
        }
        if occupied.end < activity.end {
            result.append(DateInterval(start: max(occupied.end, activity.start), end: activity.end))
        }
        return result.filter { $0.duration > 0 }
    }

    private static func copy(of activity: Visit, interval: DateInterval) -> Visit {
        Visit(
            arrival: interval.start,
            departure: interval.end,
            latitude: activity.latitude,
            longitude: activity.longitude,
            placeName: activity.placeName,
            inferredActivity: activity.inferredActivity,
            userActivity: activity.userActivity,
            note: activity.note,
            source: activity.source,
            recognitionConfidence: activity.recognitionConfidence,
            candidateData: activity.candidateData
        )
    }
}
