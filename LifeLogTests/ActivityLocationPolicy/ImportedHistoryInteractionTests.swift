import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

// health-walking (step counts) and motion (Core Motion) are both weaker, inferred
// guesses at the same real event a health-workout already declares. Cross-checked
// against Life Cycle, run in parallel the whole time: it recorded one walk on every
// morning these overlapped, never two.

/// Workout sessions against overlapping stays and weaker movement records: a started
/// workout is never absorbed away, a stay a workout walked straight through is
/// superseded (with or without a route to prove no stop), health-walking/motion
/// records overlapping a workout are trimmed or removed, an orphaned walking burst
/// inside an open stay is retroactively absorbed, workout rows split at a stay
/// boundary are rejoined, and steps taken inside a stay never end it.
@MainActor
struct ImportedHistoryInteractionTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    @Test("A started workout survives the stays that overlap it, even with no route")
    func startedWorkoutIsNeverAbsorbed() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The real case from 2026-08-06: a walk from home, an Apple Watch workout
        // running, and a Maps guess recorded partway round. With no route — which is
        // every walk until Health grants route access — both stays occupied the walk,
        // nothing remained of it, and the workout was deleted rather than absorbed.
        let home = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let driveBy = Visit(arrival: base.addingTimeInterval(43 * 60),
                            departure: base.addingTimeInterval(52 * 60),
                            latitude: -23.38, longitude: 150.52,
                            placeName: "Gracemere Lake Golf Club", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "medium")
        let workout = Visit(arrival: base.addingTimeInterval(5 * 60),
                            departure: base.addingTimeInterval(50 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", source: "health-workout")
        [home, driveBy, workout].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))

        let remaining = try context.fetch(FetchDescriptor<Visit>())
        let walk = remaining.first { $0.source == "health-workout" }
        #expect(walk != nil, "a started workout must not be deleted by overlapping stays")
        #expect(walk?.arrival == base.addingTimeInterval(5 * 60))
        #expect(walk?.departure == base.addingTimeInterval(50 * 60))
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walk!, locationVisits: [home]))
        #expect(ActivityLocationPolicy.shouldShowInInsights(walk!, locationVisits: [home]))
    }

    @Test("A stay recorded while a workout was running is passed through, not visited")
    func passingStayDuringWorkoutIsSuperseded() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let driveBy = Visit(arrival: base.addingTimeInterval(43 * 60),
                            departure: base.addingTimeInterval(52 * 60),
                            latitude: -23.38, longitude: 150.52,
                            placeName: "Gracemere Lake Golf Club", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "medium")
        let workout = Visit(arrival: base.addingTimeInterval(5 * 60),
                            departure: base.addingTimeInterval(50 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", source: "health-workout")
        [driveBy, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [driveBy], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 1)
        #expect(driveBy.resolutionState == .superseded)
        #expect(driveBy.locationResolutionExplanation == .movement)
        #expect(!ActivityLocationPolicy.shouldShowInTimeline(driveBy, locationVisits: []))
    }

    @Test("A saved place walked straight through is superseded despite being learned")
    func learnedPlaceWalkedThroughIsSuperseded() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Cedric Archer Park, on the real 7 August capture: a place the person saved
        // themselves, so every confidence-based guard protects it — and the walk went
        // straight through it at 1.3 m/s without ever stopping.
        let park = Visit(arrival: base.addingTimeInterval(15 * 60),
                         departure: base.addingTimeInterval(23 * 60),
                         latitude: -23.44096, longitude: 150.45,
                         placeName: "Cedric Archer Park", inferredActivity: "Walking",
                         source: "automatic", recognitionConfidence: "learned")
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(34 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        workout.route = ActivityLocationPolicyFixtures.straightRoute(from: base, to: base.addingTimeInterval(34 * 60),
                                      latitude: -23.44096, longitude: 150.45, metresPerSecond: 1.3)
        [park, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [park], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 1, "a measured walking pace across the whole stay is proof of no stop")
        #expect(park.resolutionState == .superseded)
    }

    @Test("A stop inside a workout survives, however the workout is timed")
    func stationaryPathDuringWorkoutSurvives() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Same shape as above — the stay sits wholly inside the session — but the path
        // does not move while the stay claims to be holding the person, so they stopped.
        let shop = Visit(arrival: base.addingTimeInterval(15 * 60),
                         departure: base.addingTimeInterval(23 * 60),
                         latitude: -23.44096, longitude: 150.45,
                         placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                         source: "automatic", recognitionConfidence: "medium")
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(34 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        workout.route = ActivityLocationPolicyFixtures.straightRoute(from: base, to: base.addingTimeInterval(34 * 60),
                                      latitude: -23.44096, longitude: 150.45, metresPerSecond: 0)
        [shop, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [shop], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 0, "a path that goes nowhere is a stop, not a pass")
        #expect(shop.resolutionState != .superseded)
    }

    @Test("Without a route, a known place is still superseded unless the person answered")
    func learnedPlaceWithNoRouteIsStillSupersededWithoutAnAnswer() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Cedric Archer Park again, from the 9 August capture: sits on a walking route
        // and gets passed most mornings, so "learned" is true on every occurrence and
        // says nothing about whether this one was a stop. Until 2026-08-09 that
        // confidence alone protected it from the review queue every single time,
        // however brief the stay and however completely the workout covered it.
        let park = Visit(arrival: base.addingTimeInterval(15 * 60),
                         departure: base.addingTimeInterval(17 * 60),
                         latitude: -23.44096, longitude: 150.45,
                         placeName: "Cedric Archer Park", inferredActivity: "Walking",
                         source: "automatic", recognitionConfidence: "learned")
        // No route: the workout ended before Health had delivered one, which is the
        // ordinary case for a short stay near the start of a walk.
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(34 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [park, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [park], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 1, "a known place is not the same as a person confirming this visit")
        #expect(park.resolutionState == .superseded)
    }

    @Test("Without a path, a stay the person named or saved is left alone")
    func routelessWorkoutDoesNotWithdrawAnAgreedStay() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Touch Of Paradise Park, from the 3 August capture: two minutes, wholly inside
        // the walk, but the person confirmed it as Exercising. Nothing here can outrank
        // that without a route to measure, so it stands.
        let confirmed = Visit(arrival: base.addingTimeInterval(15 * 60),
                              departure: base.addingTimeInterval(17 * 60),
                              latitude: -23.44, longitude: 150.45,
                              placeName: "Touch Of Paradise Park", inferredActivity: "Visiting",
                              userActivity: "Exercising", source: "automatic",
                              recognitionConfidence: "confirmed")
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(34 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [confirmed, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [confirmed], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 0)
        #expect(confirmed.resolutionState != .superseded)
    }

    @Test("A health-walking record staggered against a workout is trimmed to what the workout does not cover")
    func staggeredWalkingRecordIsTrimmedAroundTheWorkout() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The 9 August capture: health-walking 06:36-07:27, health-workout 06:43-07:29,
        // neither containing the other, both "Device". Life Cycle showed one 45-minute
        // walk (06:43-07:29); the workout is the more precise account.
        let walking = Visit(arrival: base, departure: base.addingTimeInterval(51 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let workout = Visit(arrival: base.addingTimeInterval(7 * 60),
                            departure: base.addingTimeInterval(53 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [walking, workout].forEach(context.insert)
        try context.save()

        let sessions = [workout].compactMap { WorkoutJourneys.WorkoutSession($0, now: base.addingTimeInterval(2 * 60 * 60)) }
        let changed = WorkoutJourneys.recordAbsorbedMovement(
            during: sessions, activities: [walking, workout], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(changed == 1)
        // Only the part before the workout began survives — seven minutes, above the
        // two-minute floor for a health-walking record.
        #expect(walking.arrival == base)
        #expect(walking.departure == base.addingTimeInterval(7 * 60))
        // The workout itself is never a candidate for its own rule.
        #expect(workout.arrival == base.addingTimeInterval(7 * 60))
        #expect(workout.departure == base.addingTimeInterval(53 * 60))
    }

    @Test("A motion record fully inside a workout is removed rather than left as a duplicate")
    func motionRecordFullyInsideAWorkoutIsRemoved() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let motion = Visit(arrival: base.addingTimeInterval(10 * 60),
                           departure: base.addingTimeInterval(15 * 60),
                           latitude: 0, longitude: 0, placeName: "Walking",
                           inferredActivity: "Walking", userActivity: "Walking", source: "motion")
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(34 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [motion, workout].forEach(context.insert)
        try context.save()

        let sessions = [workout].compactMap { WorkoutJourneys.WorkoutSession($0, now: base.addingTimeInterval(2 * 60 * 60)) }
        let changed = WorkoutJourneys.recordAbsorbedMovement(
            during: sessions, activities: [motion, workout], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(changed == 1)
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }.isEmpty)
    }

    @Test("A health-walking record with no overlap at all is left untouched")
    func nonOverlappingWalkingRecordIsUntouched() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let walking = Visit(arrival: base, departure: base.addingTimeInterval(10 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let workout = Visit(arrival: base.addingTimeInterval(60 * 60),
                            departure: base.addingTimeInterval(90 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [walking, workout].forEach(context.insert)
        try context.save()

        let sessions = [workout].compactMap { WorkoutJourneys.WorkoutSession($0, now: base.addingTimeInterval(3 * 60 * 60)) }
        let changed = WorkoutJourneys.recordAbsorbedMovement(
            during: sessions, activities: [walking, workout], context: context,
            now: base.addingTimeInterval(3 * 60 * 60)
        )

        #expect(changed == 0)
        #expect(walking.arrival == base)
        #expect(walking.departure == base.addingTimeInterval(10 * 60))
    }

    @Test("An automatic location visit is never a candidate for movement absorption")
    func locationVisitsAreNeverAbsorbedAsMovement() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Only health-walking and motion are in scope. A Saved Place fully inside a
        // workout window is WorkoutJourneys.supersedePassingStays's question, not this
        // one, and must not be touched by this pass at all.
        let home = Visit(arrival: base, departure: base.addingTimeInterval(30 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let workout = Visit(arrival: base, departure: base.addingTimeInterval(30 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [home, workout].forEach(context.insert)
        try context.save()

        let sessions = [workout].compactMap { WorkoutJourneys.WorkoutSession($0, now: base.addingTimeInterval(2 * 60 * 60)) }
        let changed = WorkoutJourneys.recordAbsorbedMovement(
            during: sessions, activities: [home, workout], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(changed == 0)
        #expect(home.departure == base.addingTimeInterval(30 * 60))
    }

    @Test("The archive-wide reconciliation absorbs a stuck week-old duplicate without crashing on the rest of the pass")
    func reconcileAllAbsorbsMovementBeforeFurtherPasses() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The full pipeline: absorption must run and leave a clean, valid store behind
        // for boundStays/reconcile to keep working on, not a deleted object other
        // passes then try to mutate further.
        let walking = Visit(arrival: base, departure: base.addingTimeInterval(51 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let workout = Visit(arrival: base.addingTimeInterval(7 * 60),
                            departure: base.addingTimeInterval(53 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        let home = Visit(arrival: base.addingTimeInterval(53 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        [walking, workout, home].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.filter { $0.source == "health-walking" }.count == 1)
        #expect(remaining.first { $0.source == "health-walking" }?.departure == base.addingTimeInterval(7 * 60))
        #expect(remaining.filter { $0.source == "health-workout" }.count == 1)
        #expect(home.arrival == base.addingTimeInterval(53 * 60))
    }

    @Test("A walking burst orphaned inside an open stay by an earlier import is absorbed on the next appearance")
    func reappliesOpenStayAbsorptionToAnOrphanedBurst() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // HealthKit's walking query is not anchored — it re-scans a rolling window on
        // every import, so a burst can land in the store before the stay it happened
        // inside exists yet. Once Home does exist, nothing but this pass ever goes back
        // to retract it: `reconcile(locationVisit:)` only runs from a live Core Location
        // callback, and a stay that stays open all day with nothing else happening never
        // gets a further one.
        let home = Visit(arrival: base.addingTimeInterval(-2 * 60 * 60), departure: nil,
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let orphanedBurst = Visit(arrival: base.addingTimeInterval(-60 * 60),
                                  departure: base.addingTimeInterval(-55 * 60),
                                  latitude: 0, longitude: 0, placeName: "Walking",
                                  inferredActivity: "Walking", userActivity: "Walking",
                                  source: "health-walking")
        [home, orphanedBurst].forEach(context.insert)
        try context.save()

        let changed = try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(context: context, now: base)

        #expect(changed == true)
        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.filter { $0.source == "health-walking" }.isEmpty)
        #expect(remaining.contains { $0.placeName == "Home" && $0.departure == nil })
    }

    @Test("Steps taken at home before starting a workout stay at home, and the workout is the whole walk")
    func stepsBeforeAWorkoutStayAtHome() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The 9 August capture, and the owner's own account of it: wake up, move about
        // at home for a few minutes, then start an outdoor walk workout. Home's own
        // departure was originally timed from the CLVisit that closed it — 07:29, when
        // the workout ended and the next arrival was recorded — well past everything
        // here, which is exactly why boundStay pulls it back in the first place.
        let home = Visit(arrival: base.addingTimeInterval(-20 * 60 * 60),
                         departure: base.addingTimeInterval(53 * 60),
                         latitude: -23.445, longitude: 150.452,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let steps = Visit(arrival: base, departure: base.addingTimeInterval(7 * 60),
                          latitude: 0, longitude: 0, placeName: "Walking",
                          inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let workout = Visit(arrival: base.addingTimeInterval(7 * 60),
                            departure: base.addingTimeInterval(53 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [home, steps, workout].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))
        try context.save()

        // Home's departure sits at the workout's own start, not at the earlier steps —
        // the pre-workout time reads as time at home.
        #expect(home.departure == base.addingTimeInterval(7 * 60))
        // The steps taken before the workout began do not survive as a walk of their
        // own: Home now occupies that window, and the existing occupied-time
        // subtraction absorbs them the same way it absorbs any other movement inside
        // an open stay.
        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.filter { $0.source == "health-walking" }.isEmpty)
        #expect(remaining.filter { $0.source == "health-workout" }.count == 1)
    }

    @Test("A real gap before a workout is not swallowed as a lead-in")
    func aGenuineGapBeforeAWorkoutIsNotAbsorbed() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Same shape, but forty minutes of silence between the steps ending and the
        // workout beginning — past the fifteen-minute lead-in window, so this reads as
        // two separate things rather than one continuous excursion. Home's own
        // departure is set to exactly where the steps end, matching the established
        // "walk out the door" shape elsewhere in this file — boundStay only ever pulls
        // a departure back when it already falls at or before the movement's own end,
        // so setting it any later would leave boundStay refusing to fire at all here,
        // for a reason that has nothing to do with the rule under test.
        let home = Visit(arrival: base.addingTimeInterval(-20 * 60 * 60),
                         departure: base.addingTimeInterval(7 * 60),
                         latitude: -23.445, longitude: 150.452,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let steps = Visit(arrival: base, departure: base.addingTimeInterval(7 * 60),
                          latitude: 0, longitude: 0, placeName: "Walking",
                          inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let workout = Visit(arrival: base.addingTimeInterval(47 * 60),
                            departure: base.addingTimeInterval(90 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout")
        [home, steps, workout].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        // boundStay's ordinary behaviour, untouched by the lead-in exclusion: the steps
        // are not a lead-in to anything, so they bound Home themselves, at their own
        // start — not silently reassigned to the unrelated workout forty minutes later.
        #expect(home.departure == base)
        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.contains { $0.source == "health-walking" })
    }

    @Test("Workout rows split at a stay boundary are rejoined into one journey")
    func repairsWorkoutSplitByAStay() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The 7 August capture exactly: one 34-minute walk stored as 10.6m + 4.6m, cut
        // at the arrival and departure of a stay recorded partway round.
        let session = UUID()
        let first = Visit(arrival: base, departure: base.addingTimeInterval(11 * 60),
                          latitude: 0, longitude: 0, placeName: "Walking workout",
                          inferredActivity: "Walking", source: "health-workout",
                          recognitionConfidence: "device", healthKitSampleIDs: [session])
        first.route = ActivityLocationPolicyFixtures.straightRoute(from: base, to: base.addingTimeInterval(11 * 60),
                                    latitude: -23.441, longitude: 150.45, metresPerSecond: 1.3)
        let second = Visit(arrival: base.addingTimeInterval(28 * 60),
                           departure: base.addingTimeInterval(33 * 60),
                           latitude: 0, longitude: 0, placeName: "Walking workout",
                           inferredActivity: "Walking", source: "health-workout",
                           recognitionConfidence: "device", healthKitSampleIDs: [session])
        second.route = ActivityLocationPolicyFixtures.straightRoute(from: base.addingTimeInterval(28 * 60),
                                     to: base.addingTimeInterval(33 * 60),
                                     latitude: -23.45, longitude: 150.45, metresPerSecond: 1.3)
        let driveBy = Visit(arrival: base.addingTimeInterval(11 * 60),
                            departure: base.addingTimeInterval(28 * 60),
                            latitude: -23.44133, longitude: 150.45,
                            placeName: "Gracemere Pump Track", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "medium")
        [first, second, driveBy].forEach(context.insert)
        try context.save()
        // Read before the repair: the surviving row is `first`, so afterwards these
        // counts are the merged path rather than the halves it was made from.
        let recordedPoints = first.route.count + second.route.count

        let repaired = try WorkoutJourneys.repairSplitWorkouts(
            context: context, now: base.addingTimeInterval(2 * 60 * 60)
        )
        try context.save()

        let workouts = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-workout" }
        #expect(repaired == 2, "one row rejoined and one drive-by stay withdrawn")
        #expect(workouts.count == 1, "one HealthKit session is one timeline row")
        #expect(workouts.first?.arrival == base)
        #expect(workouts.first?.departure == base.addingTimeInterval(33 * 60))
        #expect(workouts.first?.route.count == recordedPoints, "both halves' paths are kept")
        // With the walk whole again, the stay it was cut at is explained by it.
        #expect(driveBy.resolutionState == .superseded)
    }

    @Test("A real stop during a walk keeps its place")
    func genuineStopDuringWorkoutSurvives() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Same golf club, but the person actually stopped: the stay reaches well past
        // the end of the session, so most of it is not explained by the workout.
        let realStay = Visit(arrival: base.addingTimeInterval(43 * 60),
                             departure: base.addingTimeInterval(120 * 60),
                             latitude: -23.38, longitude: 150.52,
                             placeName: "Gracemere Lake Golf Club", inferredActivity: "Visiting",
                             source: "automatic", recognitionConfidence: "medium")
        // A Saved Place is never superseded either, however the timing falls.
        let home = Visit(arrival: base.addingTimeInterval(10 * 60),
                         departure: base.addingTimeInterval(40 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let workout = Visit(arrival: base.addingTimeInterval(5 * 60),
                            departure: base.addingTimeInterval(50 * 60),
                            latitude: 0, longitude: 0, placeName: "Walking",
                            inferredActivity: "Walking", source: "health-workout")
        [realStay, home, workout].forEach(context.insert)
        try context.save()

        let superseded = WorkoutJourneys.supersedePassingStays(
            during: [workout], stays: [realStay, home], context: context,
            now: base.addingTimeInterval(3 * 60 * 60)
        )

        #expect(superseded == 0)
        #expect(realStay.resolutionState != .superseded)
        #expect(home.resolutionState != .superseded)
    }

    @Test("Passive walking with no route is still absorbed into an open stay")
    func passiveWalkingIsStillAbsorbed() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The exemption is for started workouts only. A phone noticing movement inside
        // an unclosed stay is still pacing about, and must not invent a departure.
        let home = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(75 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        [home, walk].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))

        let walking = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-walking" }
        #expect(walking.isEmpty, "movement inside an unclosed stay is not a journey")
    }

    @Test("Steps taken inside a shop do not end the shop visit")
    func stepsInsideAStayDoNotEndIt() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // 8 August, from the export. Core Location timed the shop's departure from the
        // arrival at the next shop 455 m away, and the steps taken walking around
        // inside began two minutes after arriving. Bounding the stay there left two
        // minutes of shopping and twenty-nine minutes of "Walking" across a short drive.
        let shop = Visit(arrival: base, departure: base.addingTimeInterval(31 * 60),
                         latitude: -23.4336, longitude: 150.4530,
                         placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                         source: "automatic", recognitionConfidence: "learned")
        let walk = Visit(arrival: base.addingTimeInterval(2 * 60),
                         departure: base.addingTimeInterval(33 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking",
                         source: "health-walking")
        let liquor = Visit(arrival: base.addingTimeInterval(31 * 60),
                           departure: base.addingTimeInterval(34 * 60),
                           latitude: -23.4368, longitude: 150.4558,
                           placeName: "Star Liquor", inferredActivity: "Shopping",
                           source: "automatic", recognitionConfidence: "learned")
        [shop, walk, liquor].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        #expect(shop.departure == base.addingTimeInterval(31 * 60),
                "the shop visit keeps the time Core Location recorded for it")
        let walking = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-walking" }
        #expect(walking.isEmpty, "walking about inside a stay is movement at that place")
    }

    @Test("A walk covering the tail of a stay still bounds it")
    func aWalkOverTheTailStillBoundsTheStay() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The counterpart the guard must not break: the walk out the door runs to the
        // end of the stay rather than consuming it, so it is still read as leaving.
        let home = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let walk = Visit(arrival: base.addingTimeInterval(50 * 60),
                         departure: base.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let park = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(90 * 60),
                         latitude: -23.40, longitude: 150.50,
                         placeName: "Park", inferredActivity: "Exercising", source: "automatic")
        [home, walk, park].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        #expect(home.departure == base.addingTimeInterval(50 * 60))
        let walking = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-walking" }
        #expect(walking.count == 1)
    }

    @Test("Archive repair rejoins fragmented driving but respects a destination in the gap")
    func archiveRepairRejoinsTravelWithoutCrossingAStay() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let first = Visit(
            arrival: base, departure: base.addingTimeInterval(8 * 60), latitude: 0, longitude: 0,
            placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling", source: "motion"
        )
        let second = Visit(
            arrival: base.addingTimeInterval(9 * 60), departure: base.addingTimeInterval(16 * 60), latitude: 0, longitude: 0,
            placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling", source: "motion"
        )
        let later = Visit(
            arrival: base.addingTimeInterval(22 * 60), departure: base.addingTimeInterval(30 * 60), latitude: 0, longitude: 0,
            placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling", source: "motion"
        )
        context.insert(first)
        context.insert(second)
        context.insert(later)
        try context.save()

        ActivityLocationPolicy.coalesceFragmentedTravel(in: [first, second, later], context: context, now: base.addingTimeInterval(60 * 60))
        try context.save()
        var travel = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }
        #expect(travel.count == 1)
        #expect(travel.first?.departure == base.addingTimeInterval(30 * 60))

        let next = Visit(
            arrival: base.addingTimeInterval(39 * 60), departure: base.addingTimeInterval(43 * 60), latitude: 0, longitude: 0,
            placeName: "In transit", inferredActivity: "Travelling", userActivity: "Travelling", source: "motion"
        )
        let shop = Visit(
            arrival: base.addingTimeInterval(32 * 60), departure: base.addingTimeInterval(38 * 60),
            latitude: -27.47, longitude: 153.03, placeName: "Shops", inferredActivity: "Shopping", source: "automatic"
        )
        context.insert(next)
        context.insert(shop)
        try context.save()

        travel = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }
        ActivityLocationPolicy.coalesceFragmentedTravel(in: travel + [shop], context: context,
                                                         now: base.addingTimeInterval(60 * 60))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }.count == 2,
                "a recorded destination keeps separate drives separate")
    }

    @Test("A coordinate-less Health walking fragment between two Home stays merges into one")
    func coalescesUnlocatedWalkingBetweenSamePlaceStays() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let firstHome = ActivityLocationPolicyFixtures.stay("Home", from: 0, to: 60, latitude: -23.44, longitude: 150.45, base: base)
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60), departure: base.addingTimeInterval(69 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let secondHome = ActivityLocationPolicyFixtures.stay("Home", from: 69, to: 130, latitude: -23.44, longitude: 150.45, base: base)
        [firstHome, walk, secondHome].forEach(context.insert)
        try context.save()

        ActivityLocationPolicy.coalesceStaysAcrossUnlocatedMovement(
            in: [firstHome, walk, secondHome], context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 1, "the fragment is folded away and the two stays become one")
        #expect(remaining.first?.arrival == firstHome.arrival)
        #expect(remaining.first?.departure == secondHome.departure)
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-walking" }.isEmpty)
    }

    @Test("A real visit or a located fragment between two same-place stays blocks the merge")
    func doesNotCoalesceAcrossARealVisitOrALocatedFragment() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let firstHome = ActivityLocationPolicyFixtures.stay("Home", from: 0, to: 60, latitude: -23.44, longitude: 150.45, base: base)
        let shop = ActivityLocationPolicyFixtures.stay("Shops", from: 65, to: 75, latitude: -23.40, longitude: 150.50, base: base)
        let secondHome = ActivityLocationPolicyFixtures.stay("Home", from: 75, to: 130, latitude: -23.44, longitude: 150.45, base: base)
        [firstHome, shop, secondHome].forEach(context.insert)
        try context.save()

        ActivityLocationPolicy.coalesceStaysAcrossUnlocatedMovement(
            in: [firstHome, shop, secondHome], context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Visit>()).count == 3, "a real destination in between is never folded away")

        // A walking fragment that does carry a coordinate is real evidence too, not
        // an absence of it — the same "nothing to place it anywhere" reasoning that
        // makes a coordinate-less fragment safe to fold away does not apply.
        let locatedWalk = Visit(arrival: base.addingTimeInterval(63 * 60), departure: base.addingTimeInterval(68 * 60),
                                latitude: -23.41, longitude: 150.49, placeName: "Walking",
                                inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        context.delete(shop)
        context.insert(locatedWalk)
        try context.save()
        let secondHomeAlone = ActivityLocationPolicyFixtures.stay("Home", from: 75, to: 130, latitude: -23.44, longitude: 150.45, base: base)
        context.delete(secondHome)
        context.insert(secondHomeAlone)
        try context.save()

        ActivityLocationPolicy.coalesceStaysAcrossUnlocatedMovement(
            in: [firstHome, locatedWalk, secondHomeAlone], context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-walking" }.count == 1,
                "a located fragment is left alone even though both sides are Home")
    }

    @Test("Several fragments strung between the same place all collapse in one pass")
    func coalescesAChainOfFragmentsInOnePass() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let first = ActivityLocationPolicyFixtures.stay("Home", from: 0, to: 30, latitude: -23.44, longitude: 150.45, base: base)
        let second = ActivityLocationPolicyFixtures.stay("Home", from: 34, to: 60, latitude: -23.44, longitude: 150.45, base: base)
        let third = ActivityLocationPolicyFixtures.stay("Home", from: 64, to: 90, latitude: -23.44, longitude: 150.45, base: base)
        func fragment(from startMinutes: Double, to endMinutes: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(startMinutes * 60), departure: base.addingTimeInterval(endMinutes * 60),
                 latitude: 0, longitude: 0, placeName: "Walking",
                 inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        }
        let gapOne = fragment(from: 30, to: 34)
        let gapTwo = fragment(from: 60, to: 64)
        [first, gapOne, second, gapTwo, third].forEach(context.insert)
        try context.save()

        ActivityLocationPolicy.coalesceStaysAcrossUnlocatedMovement(
            in: [first, gapOne, second, gapTwo, third], context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.arrival == first.arrival)
        #expect(remaining.first?.departure == third.departure)
    }
}
