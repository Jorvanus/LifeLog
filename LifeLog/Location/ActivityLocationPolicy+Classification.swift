import Foundation
import SwiftData
import CoreLocation

/// What a record *is*. Pure tests over one visit, shared by everything else here,
/// with no store access and no opinions about what to show.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {
    nonisolated static func isLocationVisit(_ visit: Visit) -> Bool {
        visit.source == "automatic" || visit.source == "manual"
    }

    nonisolated static func isSupersededLocation(_ visit: Visit) -> Bool {
        visit.source == "automatic-superseded"
    }

    /// What the resolver would derive for a visit's resolution state from its
    /// current fields alone — never `.ignored`, which is a person's decision and
    /// no combination of fields implies it. Shared by `Visit.init` (a fresh
    /// visit has nothing else to go on), the V8→V9 migration's backfill (before
    /// the legacy ignore registry can be converted), and `reconcileResolutionStates`
    /// (the resolver's own ongoing use, after every location-affecting mutation).
    ///
    /// Takes raw values rather than a `Visit` so `Visit.init` can call it before
    /// `self` exists; `derivedAutomaticResolutionState(for:)` below is the usual
    /// entry point once a visit is in hand.
    nonisolated static func derivedAutomaticResolutionState(
        source: String, placeName: String, recognitionConfidence: String?
    ) -> VisitResolutionState {
        if source == supersededLocationSource { return .superseded }
        if source == "automatic" && (Visit.isPlaceholderName(placeName) || recognitionConfidence == nil) {
            return .provisional
        }
        return .resolved
    }

    nonisolated static func derivedAutomaticResolutionState(for visit: Visit) -> VisitResolutionState {
        derivedAutomaticResolutionState(
            source: visit.source, placeName: visit.placeName,
            recognitionConfidence: visit.recognitionConfidence
        )
    }


    /// Whether a visit belongs on a given day's timeline. A stay counts for every day
    /// it covers rather than the day it began: Core Location records one arrival per
    /// stay, so a night at home arrives the evening before and is the only record of
    /// the following morning until the person next goes out.
    nonisolated static func covers(_ visit: Visit, day: DateInterval, now: Date = .now) -> Bool {
        visit.arrival < day.end && (visit.departure ?? now) > day.start
    }

    nonisolated static func isDeviceActivity(_ visit: Visit) -> Bool {
        visit.source == "motion" || visit.source.hasPrefix("health-")
    }


    /// A workout the person started themselves.
    ///
    /// Categorically different from the rest of device activity. `motion` and
    /// `health-walking` are the phone noticing movement, which is why they are absorbed
    /// into a stay unless a route proves they left it — movement inside an unclosed stay
    /// is pacing about, and reading it as a departure invents an arrival.
    ///
    /// A workout is someone pressing Start. It is a first-hand statement that this
    /// stretch of time was a walk, and no Core Location *guess* outranks it.
    nonisolated static func isWorkoutSession(_ visit: Visit) -> Bool {
        visit.source == "health-workout"
    }


    /// A started workout that nothing contradicts — believed, and kept as a row of its
    /// own even with no destination either side and no route.
    ///
    /// The one thing that does contradict it is its own path. A route that never got
    /// more than `departureRadius` from the place is proof the person did not leave,
    /// and proof outranks the claim: pacing about the house with a walking workout
    /// running is still pacing about the house, and splitting the stay there would
    /// invent an arrival that never happened.
    ///
    /// So the three cases are: route shows it left → journey; route shows it stayed →
    /// absorbed; no route at all → believe the person, because a deliberate session is
    /// evidence and passive movement detection is not.
    nonisolated static func isDeclaredJourney(_ visit: Visit, stays: [Visit]) -> Bool {
        isDeclaredJourney(source: visit.source, route: visit.route, stays: stays)
    }


    /// The same question asked of an import record, before it has become a `Visit`.
    ///
    /// The import path used to subtract every overlapping stay from an incoming record
    /// with none of this reasoning, so a Core Location arrival recorded mid-walk cut a
    /// workout into fragments as it was written — and the fragments no longer overlapped
    /// the stay, which is the evidence `supersedePassingStays` needs to remove it. The
    /// two faults locked each other in. Both paths ask the same question now.
    nonisolated static func isDeclaredJourney(source: String, route: [RoutePoint],
                                              stays: [Visit]) -> Bool {
        guard source == "health-workout" else { return false }
        return !stays.contains { leftStay(route: route, stay: $0) == false }
    }


    /// Text-only tests so the import actor can classify a record before it becomes
    /// a `Visit`, and so both paths agree on what counts as walking or travel.
    nonisolated static func describesWalking(_ text: String) -> Bool {
        text.lowercased().contains("walk")
    }

    nonisolated static func describesTravel(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["travel", "transit", "automotive", "vehicle", "driv", "car", "plane", "flight"]
            .contains { text.contains($0) }
    }

    nonisolated static func isWalkingActivity(_ visit: Visit) -> Bool {
        guard isDeviceActivity(visit) else { return false }
        return describesWalking(visit.activity)
    }

    nonisolated static func isTravelActivity(_ visit: Visit) -> Bool {
        guard isDeviceActivity(visit) else { return false }
        return describesTravel("\(visit.activity) \(visit.placeName)")
    }

    nonisolated static func isMovementActivity(_ visit: Visit) -> Bool {
        isWalkingActivity(visit) || isTravelActivity(visit)
    }

    nonisolated static func minimumRetainedDuration(for source: String) -> TimeInterval {
        switch source {
        case SleepEvidence.measuredSource, SleepEvidence.inBedSource: 20 * 60
        case "motion", "health-walking": 2 * 60
        default: 60
        }
    }
}
