import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Invariants about the current/live visit and the store as a whole: device activity
/// inside a location visit is removed, sleep survives being at home, long silences are
/// left alone while short gaps before a walk are closed, and the store-wide validator
/// reports what it finds after a mutation pass.
@MainActor
struct CurrentVisitInvariantTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    @Test("Opening an existing timeline removes activity inside a location visit")
    func removesExistingActivityAtLocation() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let activity = Visit(
            arrival: base.addingTimeInterval(70 * 60),
            departure: base.addingTimeInterval(90 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        let location = Visit(
            arrival: base.addingTimeInterval(60 * 60),
            departure: base.addingTimeInterval(2 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        context.insert(activity)
        context.insert(location)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context)
        try context.save()
        let activities = try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isDeviceActivity)

        #expect(activities.isEmpty)
    }

    @Test("Sleep remains visible while the user is at Home")
    func preservesSleepAtLocation() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let sleep = Visit(
            arrival: base,
            departure: base.addingTimeInterval(8 * 60 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Sleep",
            inferredActivity: "Sleeping",
            userActivity: "Sleeping",
            source: "health-sleep"
        )
        let home = Visit(
            arrival: base,
            departure: base.addingTimeInterval(9 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        context.insert(sleep)
        context.insert(home)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context)
        try context.save()

        let sleepVisits = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-sleep" }
        #expect(sleepVisits.count == 1)
        #expect(sleepVisits[0].arrival == base)
        #expect(sleepVisits[0].departure == base.addingTimeInterval(8 * 60 * 60))
    }

    /// Minutes after a departure the person is almost certainly still there. Hours after
    /// it they could be anywhere, and claiming otherwise would be invention.
    @Test("A long silence is not filled in")
    func aLongGapIsLeftAlone() {
        let home = Visit(arrival: base.addingTimeInterval(-9 * 3600),
                         departure: base, latitude: -23.4454, longitude: 150.4581,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let walkStart = base.addingTimeInterval(ActivityLocationPolicy.departureCatchUp + 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(30 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", source: "health-workout")

        #expect(!ActivityLocationPolicy.extendStay(
            upTo: DateInterval(start: walk.arrival, end: walk.departure!),
            stays: [home], activities: [walk]
        ))
        #expect(home.departure == base)
    }

    /// The whole path, not just the rule. The first test written for `extendStay`
    /// called it directly, which proved the rule worked and said nothing about whether
    /// anything reaches it — and when the fix appeared not to work on a real phone,
    /// that test could not tell us where the failure was. This drives the exact records
    /// of 8 August through `reconcileAll`, the way Timeline drives it.
    @Test("Reconciliation closes a gap between a stay and the walk that left it")
    func reconciliationClosesTheGapBeforeAWalk() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let home = Visit(arrival: base.addingTimeInterval(-9.86 * 3600), departure: base,
                         latitude: -23.4454, longitude: 150.4581, placeName: "Home",
                         inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let walkStart = base.addingTimeInterval(13.6 * 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(48.4 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", userActivity: "Walking",
                         source: "health-workout", recognitionConfidence: "device")
        let later = Visit(arrival: base.addingTimeInterval(58.6 * 60), departure: nil,
                          latitude: -23.4454, longitude: 150.4581, placeName: "Home",
                          inferredActivity: "At home", source: "automatic",
                          recognitionConfidence: "learned")
        [home, walk, later].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 3600))

        #expect(home.departure == walkStart,
                "expected \(walkStart) but Home departs \(String(describing: home.departure))")
    }

    /// Not three tidy rows: several days of stays and movement either side of the gap,
    /// the way a real store looks. Written because the narrow version of this passed
    /// while the fix demonstrably did nothing on a real phone — a store holding only the
    /// three visits in question is not what `reconcileAll` is ever handed.
    @Test("The gap closes in a store with days of history around it")
    func gapClosesAmongHistory() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        var all: [Visit] = []
        // Four earlier days, each a stay plus a walk, so `activities` is not a one-item
        // array and `stays` is not a two-item one.
        for day in 1...4 {
            let dayStart = base.addingTimeInterval(-Double(day) * 24 * 3600)
            all.append(Visit(arrival: dayStart.addingTimeInterval(-9 * 3600),
                             departure: dayStart, latitude: -23.4454, longitude: 150.4581,
                             placeName: "Home", inferredActivity: "At home",
                             source: "automatic", recognitionConfidence: "learned"))
            all.append(Visit(arrival: dayStart.addingTimeInterval(600),
                             departure: dayStart.addingTimeInterval(2400),
                             latitude: 0, longitude: 0, placeName: "Walking workout",
                             inferredActivity: "Walking", userActivity: "Walking",
                             source: "health-workout", recognitionConfidence: "device"))
            all.append(Visit(arrival: dayStart.addingTimeInterval(3600),
                             departure: dayStart.addingTimeInterval(7200),
                             latitude: -23.38, longitude: 150.52, placeName: "Work",
                             inferredActivity: "Working", source: "automatic",
                             recognitionConfidence: "learned"))
        }
        let home = Visit(arrival: base.addingTimeInterval(-9.86 * 3600), departure: base,
                         latitude: -23.4454, longitude: 150.4581, placeName: "Home",
                         inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let walkStart = base.addingTimeInterval(13.6 * 60)
        let walk = Visit(arrival: walkStart, departure: walkStart.addingTimeInterval(48.4 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking workout",
                         inferredActivity: "Walking", userActivity: "Walking",
                         source: "health-workout", recognitionConfidence: "device")
        let later = Visit(arrival: base.addingTimeInterval(58.6 * 60), departure: nil,
                          latitude: -23.4454, longitude: 150.4581, placeName: "Home",
                          inferredActivity: "At home", source: "automatic",
                          recognitionConfidence: "learned")
        all += [home, walk, later]
        all.forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 3600))

        #expect(home.departure == walkStart,
                "Home departs \(String(describing: home.departure)), expected \(walkStart)")
    }

    @Test("Store mutation resolution leaves one non-overlapping current location")
    func resolvesAndValidatesLocationStoreAfterMutation() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let home = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home",
                         source: "automatic", recognitionConfidence: "learned")
        let shops = Visit(arrival: base.addingTimeInterval(30 * 60), latitude: -23.43,
                          longitude: 150.46, placeName: "Shops", inferredActivity: "Shopping",
                          source: "automatic", recognitionConfidence: "learned")
        [home, shops].forEach(context.insert)

        _ = try ActivityLocationPolicy.runFullStoreAudit(context: context, reason: "fixture")
        try context.save()

        let report = try ActivityLocationPolicy.validateLocationResolution(context: context)
        #expect(report.isValid)
        #expect(home.departure == shops.arrival)
        #expect(report.currentResolvedVisits == 1)
    }

    @Test("Resolution validator reports an automation that replaced a manual correction")
    func reportsAutomationReplacingManualCorrection() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(30 * 60),
                          latitude: -23.37, longitude: 150.51, placeName: "Maps Guess",
                          inferredActivity: "Visiting", source: "automatic",
                          recognitionConfidence: "learned")
        context.insert(visit)
        context.insert(VisitCorrection(visitArrival: base, latitude: -23.37, longitude: 150.51,
                                       previousPlaceName: "Unknown place", newPlaceName: "Home",
                                       previousActivity: "Visiting", newActivity: "At home"))
        try context.save()

        let report = try ActivityLocationPolicy.validateLocationResolution(context: context)
        #expect(report.automationReplacements == 1)
        #expect(!report.isValid)
    }
}
