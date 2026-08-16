import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Merging and rejoining stays: overlapping callbacks for the same place become one
/// stay, a stay is held open until whatever left it, evidence in the gap blocks the
/// inference, and a stay split by an intervening walk is rejoined only when nothing
/// else happened in between.
@MainActor
struct OverlapResolutionTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    /// The exact shape of a captured day: one working day held as three overlapping
    /// stays, and a morning at home held as two.
    @Test("A day held as overlapping stays at one place becomes one stay")
    func mergesOverlappingStaysAtOnePlace() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        func work(_ fromMinutes: Double, _ toMinutes: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(fromMinutes * 60),
                  departure: base.addingTimeInterval(toMinutes * 60),
                  latitude: -23.40, longitude: 150.50,
                  placeName: "Work", inferredActivity: "Working", source: "automatic",
                  recognitionConfidence: "learned")
        }
        // 9:09am–3:49pm, with 10:17–11:04 and 11:17–12:42 sitting inside it.
        let day = work(0, 400)
        let middle = work(68, 115)
        let afternoon = work(128, 213)
        // A separate stay elsewhere must survive untouched.
        let shops = Visit(arrival: base.addingTimeInterval(420 * 60),
                          departure: base.addingTimeInterval(450 * 60),
                          latitude: -23.44, longitude: 150.46,
                          placeName: "Shops", inferredActivity: "Shopping", source: "automatic")
        [day, middle, afternoon, shops].forEach(context.insert)
        try context.save()

        let merged = try ActivityLocationPolicy.mergeOverlappingStays(context: context)
        try context.save()

        #expect(merged == 2)
        let live = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter { ActivityLocationPolicy.isLocationVisit($0) }
        #expect(live.count == 2)
        #expect(live[0].arrival == base)
        #expect(live[0].departure == base.addingTimeInterval(400 * 60))
        #expect(live[1].placeName == "Shops")
        // The absorbed rows are kept but closed, so no duration can grow on them.
        let superseded = try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isSupersededLocation)
        #expect(superseded.count == 2)
        #expect(superseded.allSatisfy { $0.duration == 0 })
    }

    @Test("Overlapping stays merge into the union of their times")
    func mergedStayCoversBothIntervals() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Home 7:47–8:51 and Home 8:13–9:05, as captured: the second starts inside
        // the first and ends after it, so neither contains the other.
        let first = Visit(arrival: base, departure: base.addingTimeInterval(64 * 60),
                          latitude: -23.37, longitude: 150.51,
                          placeName: "Home", inferredActivity: "At home", source: "automatic")
        let second = Visit(arrival: base.addingTimeInterval(26 * 60),
                           departure: base.addingTimeInterval(78 * 60),
                           latitude: -23.37, longitude: 150.51,
                           placeName: "Home", inferredActivity: "At home", source: "automatic")
        [first, second].forEach(context.insert)
        try context.save()

        #expect(try ActivityLocationPolicy.mergeOverlappingStays(context: context) == 1)
        #expect(first.arrival == base)
        #expect(first.departure == base.addingTimeInterval(78 * 60))
    }

    /// The morning of 2026-08-16, as captured: a walk's route proved it left Home, so
    /// `separateStay` opened a continuation at the walk's end (07:51:43) -- the exact
    /// instant Core Location's own geofence had already recorded arriving home, one
    /// minute forty-one seconds earlier, having stood still for the tail of the walk.
    /// Two rows for the same return, meeting with no gap between them. Neither
    /// `isDuplicateArrival` (arrivals over a minute apart) nor the old strict-overlap
    /// `describesSameStay` (they touch, they do not overlap) caught this, so it
    /// recurred on every walk home and left Home split into extra rows on Timeline.
    @Test("Two Home stays that exactly meet, with no gap, merge into one")
    func mergesStaysThatExactlyAbut() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let arrivedWhileWalking = Visit(
            arrival: base, departure: base.addingTimeInterval(101),
            latitude: -23.37, longitude: 150.51,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        )
        let continuationAfterWalk = Visit(
            arrival: base.addingTimeInterval(101), departure: base.addingTimeInterval(3_692),
            latitude: -23.37, longitude: 150.51,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        )
        [arrivedWhileWalking, continuationAfterWalk].forEach(context.insert)
        try context.save()

        #expect(try ActivityLocationPolicy.mergeOverlappingStays(context: context) == 1)
        let live = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter { ActivityLocationPolicy.isLocationVisit($0) }
        #expect(live.count == 1)
        #expect(live[0].arrival == base)
        #expect(live[0].departure == base.addingTimeInterval(3_692))
    }

    /// The boundary this must not cross: a stay that genuinely ends and a different
    /// stay that genuinely begins later, with unrecorded time between them, must not
    /// be folded together just because nothing else happened in the gap. `Visit` has
    /// no representation for "nothing recorded here" other than the gap itself, so
    /// merging on proximity instead of an exact meeting point would erase it.
    @Test("Stays with a real gap between them are not merged as if they touched")
    func doesNotMergeStaysSeparatedByAGap() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let morning = Visit(arrival: base, departure: base.addingTimeInterval(101),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "Home", inferredActivity: "At home", source: "automatic")
        let later = Visit(arrival: base.addingTimeInterval(102), departure: base.addingTimeInterval(3_692),
                          latitude: -23.37, longitude: 150.51,
                          placeName: "Home", inferredActivity: "At home", source: "automatic")
        [morning, later].forEach(context.insert)
        try context.save()

        #expect(try ActivityLocationPolicy.mergeOverlappingStays(context: context) == 0)
        #expect(morning.departure == base.addingTimeInterval(101))
        #expect(later.arrival == base.addingTimeInterval(102))
    }

    @Test("Returning to a place later is not merged into the earlier stay")
    func doesNotMergeASeparateReturn() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let morning = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "Home", inferredActivity: "At home", source: "automatic")
        let evening = Visit(arrival: base.addingTimeInterval(4 * 60 * 60),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "Home", inferredActivity: "At home", source: "automatic")
        // Two unnamed stays overlapping tells us nothing about whether it is one place.
        let unknownA = Visit(arrival: base.addingTimeInterval(90 * 60),
                             departure: base.addingTimeInterval(150 * 60),
                             latitude: -23.41, longitude: 150.52,
                             placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                             source: "automatic")
        let unknownB = Visit(arrival: base.addingTimeInterval(100 * 60),
                             departure: base.addingTimeInterval(140 * 60),
                             latitude: -23.41, longitude: 150.52,
                             placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                             source: "automatic")
        [morning, evening, unknownA, unknownB].forEach(context.insert)
        try context.save()

        #expect(try ActivityLocationPolicy.mergeOverlappingStays(context: context) == 0)
        #expect(morning.departure == base.addingTimeInterval(60 * 60))
        #expect(evening.departure == nil)
    }

    /// The morning of 8 August: Home closed at 07:02:44, the walk began at 07:16:22, and
    /// the fourteen minutes of getting up between them belonged to nothing. Insights was
    /// right to call it unlogged — nothing had recorded it.
    @Test("A stay closed shortly before the walk that left it holds until the walk")
    func stayHoldsUntilTheWalkThatLeftIt() {
        let home = Visit(arrival: base.addingTimeInterval(-9 * 3600),
                         departure: base, latitude: -23.4454, longitude: 150.4581,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let walkStart = base.addingTimeInterval(13.6 * 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(48 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", source: "health-workout")

        let extended = ActivityLocationPolicy.extendStay(
            upTo: DateInterval(start: walk.arrival, end: walk.departure!),
            stays: [home], activities: [walk]
        )

        #expect(extended)
        #expect(home.departure == walkStart, "the gap belonged to the stay the walk left")
    }

    /// The inference is only sound across silence. Anything recorded in the gap is
    /// evidence of what happened in it, and the stay must not be stretched over it.
    @Test("A stay is not stretched over minutes something else already claims")
    func stayIsNotStretchedOverOtherRecords() {
        let home = Visit(arrival: base.addingTimeInterval(-9 * 3600),
                         departure: base, latitude: -23.4454, longitude: 150.4581,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        // A shop stop between leaving home and setting off.
        let shop = Visit(arrival: base.addingTimeInterval(2 * 60),
                         departure: base.addingTimeInterval(6 * 60),
                         latitude: -23.38, longitude: 150.52, placeName: "Gracemere Shopping World",
                         inferredActivity: "Shopping", source: "automatic")
        let walkStart = base.addingTimeInterval(10 * 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(30 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", source: "health-workout")

        let extended = ActivityLocationPolicy.extendStay(
            upTo: DateInterval(start: walk.arrival, end: walk.departure!),
            stays: [home], activities: [shop, walk]
        )

        #expect(!extended)
        #expect(home.departure == base, "the shop says where those minutes went")
    }

    /// The same shape as the test above, with the shop where the caller actually puts
    /// it. `reconcileAll` builds its `activities` list as movement records only, so a
    /// *stay* in the gap arrives in `stays` and never in `activities` — the test above
    /// passes it as an activity and so could never catch this.
    ///
    /// Left unguarded, this was a permanent repair loop rather than a one-off error:
    /// `resolveLocationCallbacks` trims Home back to the shop's arrival, then
    /// `reconcileAll` stretches it forward to the walk again, both inside one audit.
    /// A real overlap from 2026-08-07 reported itself trimmed on every launch for nine
    /// days while the store never actually changed.
    @Test("A stay is not stretched over another place the caller passed as a stay")
    func stayIsNotStretchedOverAStayInTheGap() {
        let home = Visit(arrival: base.addingTimeInterval(-9 * 3600),
                         departure: base, latitude: -23.4454, longitude: 150.4581,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let shop = Visit(arrival: base.addingTimeInterval(2 * 60),
                         departure: base.addingTimeInterval(6 * 60),
                         latitude: -23.38, longitude: 150.52, placeName: "Gracemere Shopping World",
                         inferredActivity: "Shopping", source: "automatic")
        let walkStart = base.addingTimeInterval(10 * 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(30 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", source: "health-workout")

        ActivityLocationPolicy.extendStay(
            upTo: DateInterval(start: walk.arrival, end: walk.departure!),
            stays: [home, shop], activities: [walk]
        )

        #expect(home.departure == base,
                "stretching Home to the walk would re-open the overlap with the shop")
        // The shop is a different matter, and extending it is right: it is the last
        // place before the walk, so the minutes between belong to it. The bug was never
        // that something got held open — it was Home reaching across the shop to do it.
        #expect(shop.departure == walk.arrival,
                "the shop is the place the walk actually set off from")
    }

    @Test("Stays split by a walk at the same place are rejoined")
    func rejoinsStaysSplitByMovement() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // The shape an earlier build wrote: one stay at home, cut in two by a walk.
        let first = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                          latitude: -23.37, longitude: 150.51,
                          placeName: "Home", inferredActivity: "At home", source: "automatic",
                          recognitionConfidence: "learned")
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(70 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        let second = Visit(arrival: base.addingTimeInterval(70 * 60),
                           latitude: -23.37, longitude: 150.51,
                           placeName: "Home", inferredActivity: "At home", source: "automatic",
                           recognitionConfidence: "learned")
        [first, walk, second].forEach(context.insert)
        try context.save()

        let rejoined = try ActivityLocationPolicy.rejoinStaysSplitByMovement(context: context)
        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isLocationVisit)
        #expect(rejoined == 1)
        #expect(stays.count == 1)
        #expect(first.departure == nil, "The rejoined stay carries on as the current one")
        // Reconciliation then reabsorbs the walk that sat between the two halves.
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-walking" }.isEmpty)
    }

    @Test("A real outing between two places is never rejoined")
    func doesNotRejoinAcrossADifferentPlace() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let home = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let park = Visit(arrival: base.addingTimeInterval(70 * 60),
                         departure: base.addingTimeInterval(100 * 60),
                         latitude: -23.40, longitude: 150.50,
                         placeName: "Park", inferredActivity: "Exercising", source: "automatic")
        let backHome = Visit(arrival: base.addingTimeInterval(110 * 60),
                             latitude: -23.37, longitude: 150.51,
                             placeName: "Home", inferredActivity: "At home", source: "automatic")
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(70 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        [home, park, backHome, walk].forEach(context.insert)
        try context.save()

        let rejoined = try ActivityLocationPolicy.rejoinStaysSplitByMovement(context: context)

        #expect(rejoined == 0)
        #expect(try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isLocationVisit).count == 3)
    }

    @Test("A hand-entered visit keeps the times the person gave it")
    func manualStayIsNeverBoundedByMovement() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let entered = Visit(arrival: base, departure: base.addingTimeInterval(2 * 60 * 60),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "Friend's house", inferredActivity: "Visiting", source: "manual")
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(75 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        [entered, walk].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        #expect(entered.departure == base.addingTimeInterval(2 * 60 * 60))
        #expect(try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isLocationVisit).count == 1)
    }

    /// Two hand-entered visits claiming the same minutes at different places — the
    /// shape the audit of cross-visit `DateInterval` construction went looking for.
    /// `mergeOverlappingStays` only ever touches `source == "automatic"` rows, so a
    /// manual overlap like this survives untouched rather than being resolved; the
    /// point of the test is that nothing downstream traps building an interval from
    /// the pair of them.
    @Test("Overlapping manual visits survive reconciliation without crashing")
    func overlappingManualVisitsDoNotCrashReconciliation() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Backfilled Work 9:00–5:00, with a second manual entry for a dentist
        // appointment logged 1:00–1:45 that the person forgot they had already
        // covered by the Work entry — arrival for the second sits before the
        // first's departure, so any code assuming visits are non-overlapping by
        // arrival order builds an inverted interval from this pair.
        let work = Visit(arrival: base, departure: base.addingTimeInterval(8 * 60 * 60),
                         latitude: -23.40, longitude: 150.50,
                         placeName: "Work", inferredActivity: "Working", source: "manual")
        let dentist = Visit(arrival: base.addingTimeInterval(4 * 60 * 60),
                            departure: base.addingTimeInterval(4.75 * 60 * 60),
                            latitude: -23.41, longitude: 150.52,
                            placeName: "Dentist", inferredActivity: "Appointment", source: "manual")
        [work, dentist].forEach(context.insert)
        try context.save()

        // Neither the archive-wide merge nor a full reconciliation pass may trap
        // building a `DateInterval` from this pair, and a manual entry's times are
        // never rewritten by either.
        let merged = try ActivityLocationPolicy.mergeOverlappingStays(context: context)
        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(9 * 60 * 60))
        try context.save()

        #expect(merged == 0)
        #expect(work.arrival == base)
        #expect(work.departure == base.addingTimeInterval(8 * 60 * 60))
        #expect(dentist.arrival == base.addingTimeInterval(4 * 60 * 60))
        #expect(dentist.departure == base.addingTimeInterval(4.75 * 60 * 60))
    }

    /// The exact regression `CommuteDetection` hit on-device: a movement record's
    /// `remainingSegments` must not build a `DateInterval` assuming the manual stay
    /// it overlaps starts after the movement's own start.
    @Test("A movement record overlapping a manual visit does not crash segment subtraction")
    func movementOverlappingManualVisitDoesNotCrash() {
        let manual = Visit(arrival: base.addingTimeInterval(30 * 60),
                           departure: base.addingTimeInterval(90 * 60),
                           latitude: -23.37, longitude: 150.51,
                           placeName: "Friend's house", inferredActivity: "Visiting", source: "manual")
        // Starts before the manual visit and ends inside it.
        let movement = DateInterval(start: base, end: base.addingTimeInterval(60 * 60))

        let remaining = ActivityLocationPolicy.remainingSegments(for: movement, locationVisits: [manual])

        #expect(remaining.count == 1)
        #expect(remaining[0].start == base)
        #expect(remaining[0].end == manual.arrival)
    }
}
