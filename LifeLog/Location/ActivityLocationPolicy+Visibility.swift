import Foundation
import SwiftData
import CoreLocation

/// What Timeline and Insights each put on screen. Rules about presentation only: nothing
/// here changes a record, and the two screens deliberately answer differently.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {

    /// Movement shorter than this stays out of the daily card list, though Insights
    /// still counts it. Motion segments are already filtered at two to three minutes
    /// when they are recorded, so this mainly suppresses a stray sample either side
    /// of a stay rather than a real outing: a walk to the park and back is a journey
    /// worth seeing, and requiring an hour of it hid every one of them.
    ///
    /// Three minutes rather than five because a real capture walked to a park in
    /// 11m25s and home again in 4m18s. At five minutes the outbound leg appeared and
    /// the return did not, which reads as an unfinished trip rather than a tidier one.
    nonisolated static let minimumTimelineMovementDuration: TimeInterval = 3 * 60


    /// Movement is useful as a travel segment only when it sits between two destinations.
    /// This also hides stale records that were imported before Core Location delivered
    /// the surrounding visits.
    nonisolated static func isBetweenDestinations(_ activity: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard isMovementActivity(activity) else { return true }
        let activityEnd = activity.departure ?? now
        guard activityEnd > activity.arrival else { return false }
        let overlapsDestination = locationVisits.contains { location in
            let locationEnd = location.departure ?? now
            return location.arrival < activityEnd && locationEnd > activity.arrival
        }
        guard !overlapsDestination else { return false }
        let hasPreviousDestination = locationVisits.contains { location in
            let locationEnd = location.departure ?? now
            return locationEnd <= activity.arrival
        }
        let hasNextDestination = locationVisits.contains { $0.arrival >= activityEnd }
        return hasPreviousDestination && hasNextDestination
    }

    nonisolated static func shouldShow(_ visit: Visit, alongside allVisits: [Visit], now: Date = .now) -> Bool {
        shouldShow(
            visit,
            locationVisits: allVisits.filter(isLocationVisit),
            now: now
        )
    }


    /// Use this overload in batch processing so the caller can filter locations once
    /// instead of rescanning the entire timeline for every movement record.
    nonisolated static func shouldShow(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        // A started workout does not need a destination either side to be believed.
        // The person said it happened, and its route has not said otherwise.
        if isDeclaredJourney(visit, stays: locationVisits) { return true }
        guard isMovementActivity(visit) else { return true }
        return isBetweenDestinations(
            visit,
            locationVisits: locationVisits,
            now: now
        )
    }


    /// Timeline stays location-first: momentary movement between destinations is
    /// retained for Insights but omitted from the daily card list. A real journey
    /// — the walk to the park, the drive to work — is an event in its own right.
    static func shouldShowInTimeline(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard !isSupersededLocation(visit) else { return false }
        // Timeline is destination-first: device activity that occurs inside a
        // recorded place is retained for Insights but does not become another
        // simultaneous card. Sleep is the intentional exception.
        // A started workout and sleep are both exceptions: each is an account of what
        // the time was, not the phone guessing from movement, so neither is folded into
        // a stay that happens to overlap it.
        if isDeviceActivity(visit), !visit.source.hasPrefix("health-sleep"),
           !isDeclaredJourney(visit, stays: locationVisits) {
            let end = visit.departure ?? now
            let overlapsDestination = locationVisits.contains { location in
                let locationEnd = location.departure ?? now
                guard location.arrival < end && locationEnd > visit.arrival else { return false }
                // A journey whose own path left the place is not activity inside it,
                // however the surrounding stay happens to be timed.
                return leftStay(visit, stay: location) != true
            }
            if overlapsDestination { return false }
        }
        guard isMovementActivity(visit) else { return true }
        let duration = (visit.departure ?? now).timeIntervalSince(visit.arrival)
        guard duration >= minimumTimelineMovementDuration else { return false }
        // A recorded route is its own evidence of a journey: it shows where the walk
        // went, so it does not also need a destination on either side to be believed.
        if visit.hasRoute { return true }
        // Neither does a started workout, which is the person saying the same thing.
        if isDeclaredJourney(visit, stays: locationVisits) { return true }
        return isBetweenDestinations(visit, locationVisits: locationVisits, now: now)
    }


    /// Insights retains every valid between-destination travel segment, including
    /// short commutes, so time spent travelling is not lost from the day total.
    nonisolated static func shouldShowInInsights(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard !isSupersededLocation(visit) else { return false }
        return shouldShow(visit, locationVisits: locationVisits, now: now)
    }
}
