import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

@MainActor
struct ActivityLocationPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An active unknown visit is logged as an uncategorised location")
    func presentsUnknownCurrentLocation() {
        let visit = Visit(
            arrival: base,
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Identifying…",
            inferredActivity: "Visiting",
            source: "automatic"
        )

        #expect(visit.needsCategorisation)
        #expect(visit.displayPlaceName == "Uncategorised location")
        #expect(visit.insightCategory == "Uncategorised")
        #expect(visit.suspectedActivity == "Visiting")
    }

    @Test("Manual map selection distinguishes a pin fallback from a business match")
    func manualMapResolutionConfidence() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let pin = ManualPlaceResolution.pinned(coordinate)
        let match = ManualPlaceResolution.matched(name: "Coffee", coordinate: coordinate)

        #expect(pin.confidence == "low")
        #expect(pin.coordinate?.latitude == coordinate.latitude)
        #expect(match.confidence == "confirmed")
        #expect(ManualPlaceResolution.none.coordinate == nil)
    }

    @Test("Activity imported after a location visit excludes the occupied time")
    func subtractsLocationTimeFromImportedActivity() {
        let location = Visit(
            arrival: base.addingTimeInterval(60 * 60),
            departure: base.addingTimeInterval(2 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        let activity = DateInterval(start: base, end: base.addingTimeInterval(3 * 60 * 60))

        let remaining = ActivityLocationPolicy.remainingSegments(
            for: activity,
            locationVisits: [location],
            now: base.addingTimeInterval(4 * 60 * 60)
        )

        #expect(remaining.count == 2)
        #expect(remaining[0] == DateInterval(start: base, end: base.addingTimeInterval(60 * 60)))
        #expect(remaining[1] == DateInterval(
            start: base.addingTimeInterval(2 * 60 * 60),
            end: base.addingTimeInterval(3 * 60 * 60)
        ))
    }

    @Test("Opening an existing timeline removes activity inside a location visit")
    func removesExistingActivityAtLocation() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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

    /// The exact shape of a captured day: one working day held as three overlapping
    /// stays, and a morning at home held as two.
    @Test("A day held as overlapping stays at one place becomes one stay")
    func mergesOverlappingStaysAtOnePlace() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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

    @Test("Returning to a place later is not merged into the earlier stay")
    func doesNotMergeASeparateReturn() throws {
        let context = try makeContext()
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

    @Test("Repeated automatic callbacks collapse into one location visit")
    func deduplicatesRepeatedAutomaticLocations() throws {
        let context = try makeContext()
        for offset in [0.0, 0.5, 1.0] {
            context.insert(Visit(
                arrival: base.addingTimeInterval(offset), departure: nil,
                latitude: -27.47, longitude: 153.03,
                placeName: "Home", inferredActivity: "At home", source: "automatic"
            ))
        }
        context.insert(Visit(
            arrival: base.addingTimeInterval(1_800), departure: nil,
            latitude: -27.471, longitude: 153.031,
            placeName: "Shopping", inferredActivity: "Shopping", source: "automatic"
        ))
        try context.save()

        let removed = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()
        let locations = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)

        #expect(removed == 2)
        #expect(locations.count == 2)
        #expect(locations[0].departure == base.addingTimeInterval(1_800))
        #expect(locations[1].departure == nil)
    }

    @Test("A departure delayed past a different place's arrival is trimmed, not left overlapping")
    func trimsADepartureThatOverlapsALaterArrival() throws {
        let context = try makeContext()
        // Mirrors a real capture: Home's departure callback was delayed and clamped
        // against `.now`, landing after Gracemere had already been recorded arriving —
        // the two stays claimed the same two minutes at different places.
        context.insert(Visit(
            arrival: base, departure: base.addingTimeInterval(5_900),
            latitude: -27.47, longitude: 153.03,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        ))
        context.insert(Visit(
            arrival: base.addingTimeInterval(5_760), departure: base.addingTimeInterval(5_900),
            latitude: -27.50, longitude: 153.06,
            placeName: "Gracemere Shopping World", inferredActivity: "Shopping", source: "automatic"
        ))
        try context.save()

        _ = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()
        let locations = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)

        #expect(locations.count == 2)
        #expect(locations[0].placeName == "Home")
        #expect(locations[0].departure == base.addingTimeInterval(5_760))
        #expect(locations[1].placeName == "Gracemere Shopping World")
        #expect(locations[1].departure == base.addingTimeInterval(5_900))
    }

    @Test("A superseded duplicate is closed so its duration cannot grow forever")
    func supersededDuplicatesAreClosed() throws {
        let context = try makeContext()
        let winner = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                           placeName: "Home", inferredActivity: "At home", source: "automatic",
                           recognitionConfidence: "learned")
        // A second open callback for the same arrival, as Core Location replays.
        let duplicate = Visit(arrival: base.addingTimeInterval(20), latitude: -23.3702, longitude: 150.5101,
                              placeName: "Identifying…", inferredActivity: "Visiting", source: "automatic")
        context.insert(winner)
        context.insert(duplicate)
        try context.save()

        _ = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()

        let superseded = try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isSupersededLocation)
        #expect(superseded.count == 1)
        // The interval moved to the winner, so the loser must not stay open.
        #expect(superseded.first?.departure != nil)
        #expect(superseded.first?.duration == 0)
        // The surviving visit keeps the open stay.
        let live = try context.fetch(FetchDescriptor<Visit>())
            .filter { ActivityLocationPolicy.isLocationVisit($0) }
        #expect(live.count == 1)
        #expect(live.first?.departure == nil)
    }

    @Test("Superseded rows stranded open by earlier builds are healed")
    func healsStrandedSupersededRows() throws {
        let context = try makeContext()
        // Written as an earlier build left it: relabelled but never closed.
        let stranded = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                             placeName: "atWork Australia", inferredActivity: "Working",
                             source: "automatic-superseded", recognitionConfidence: "low")
        context.insert(stranded)
        try context.save()
        #expect(stranded.departure == nil)

        let repaired = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()

        #expect(repaired == 1, "The caller only saves when a repair is reported")
        #expect(stranded.departure == stranded.arrival)
        #expect(stranded.duration == 0)
    }

    @Test("A learned Home callback replaces a duplicate identifying arrival")
    func mergesIdentifyingCallbackIntoLearnedHome() throws {
        let context = try makeContext()
        let identifying = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                                placeName: "Identifying…", inferredActivity: "Visiting", source: "automatic")
        let home = Visit(arrival: base.addingTimeInterval(20), latitude: -23.3702, longitude: 150.5101,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        context.insert(identifying)
        context.insert(home)
        try context.save()

        let merged = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)

        #expect(merged == 1)
        #expect(identifying.placeName == "Home")
        #expect(identifying.recognitionConfidence == "learned")
        #expect(home.resolutionState == .superseded)
    }

    @Test("Walking is only shown between two destinations")
    func walkingRequiresTwoDestinations() {
        let previous = Visit(
            arrival: base,
            departure: base.addingTimeInterval(60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Work",
            inferredActivity: "Working",
            source: "automatic"
        )
        let walking = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(90 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        let next = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Cafe",
            inferredActivity: "Eating",
            source: "automatic"
        )

        #expect(ActivityLocationPolicy.shouldShow(walking, alongside: [previous, walking]) == false)
        #expect(ActivityLocationPolicy.shouldShow(walking, alongside: [previous, walking, next]) == true)
        // Batch consumers such as Insights pre-filter locations once for the same result.
        #expect(ActivityLocationPolicy.shouldShow(walking, locationVisits: [previous, next]) == true)

        let walkingAtHome = Visit(
            arrival: base.addingTimeInterval(15 * 60),
            departure: base.addingTimeInterval(30 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        #expect(ActivityLocationPolicy.shouldShow(walkingAtHome, alongside: [previous, walkingAtHome, next]) == false)

        let driving = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            inferredActivity: "Travelling",
            userActivity: "Travelling",
            source: "motion"
        )
        #expect(ActivityLocationPolicy.shouldShow(driving, alongside: [previous, driving]) == false)
        #expect(ActivityLocationPolicy.shouldShow(driving, alongside: [previous, driving, next]) == true)
    }

    @Test("A day's timeline covers the stay it woke up in")
    func dayIncludesOvernightStay() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let day = DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart)!)
        let overnight = Visit(arrival: dayStart.addingTimeInterval(-6 * 60 * 60),
                              departure: dayStart.addingTimeInterval(7 * 60 * 60),
                              latitude: -23.37, longitude: 150.51,
                              placeName: "Home", inferredActivity: "At home", source: "automatic")
        let yesterday = Visit(arrival: dayStart.addingTimeInterval(-10 * 60 * 60),
                              departure: dayStart.addingTimeInterval(-8 * 60 * 60),
                              latitude: -23.43, longitude: 150.45,
                              placeName: "Shops", inferredActivity: "Shopping", source: "automatic")
        let open = Visit(arrival: dayStart.addingTimeInterval(-2 * 60 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")

        #expect(ActivityLocationPolicy.covers(overnight, day: day))
        // A stay that finished before midnight belongs to the previous day only.
        #expect(ActivityLocationPolicy.covers(yesterday, day: day) == false)
        #expect(ActivityLocationPolicy.covers(open, day: day, now: dayStart.addingTimeInterval(8 * 60 * 60)))
    }

    @Test("A short walk between two places earns a timeline entry")
    func shortWalkBetweenDestinationsIsShown() {
        let home = Visit(arrival: base, departure: base.addingTimeInterval(60 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        let park = Visit(arrival: base.addingTimeInterval(72 * 60),
                         departure: base.addingTimeInterval(2 * 60 * 60),
                         latitude: -23.40, longitude: 150.50,
                         placeName: "Park", inferredActivity: "Exercising", source: "automatic")
        func walk(minutes: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(60 * 60),
                  departure: base.addingTimeInterval(60 * 60 + minutes * 60),
                  latitude: 0, longitude: 0, placeName: "Walking",
                  inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        }
        let now = base.addingTimeInterval(3 * 60 * 60)

        // Twelve minutes to the park is a journey; it used to need a full hour.
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walk(minutes: 12),
                                                           locationVisits: [home, park], now: now))
        // So is the four-minute walk home again, which a five-minute floor hid while
        // showing the walk out — a trip that appeared to have no return.
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walk(minutes: 4.3),
                                                           locationVisits: [home, park], now: now))
        // A stray sample either side of a stay still stays out of the card list.
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walk(minutes: 2),
                                                           locationVisits: [home, park], now: now) == false)
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
        let context = try makeContext()
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
        let context = try makeContext()
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

    @Test("A walk out the door bounds the stay instead of being deleted")
    func walkBoundsTheStayItLeft() throws {
        let context = try makeContext()
        // Core Location timed Home's departure from the park arrival, so Home looks
        // like it covered the walk out the door.
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

        let now = base.addingTimeInterval(3 * 60 * 60)
        try ActivityLocationPolicy.reconcileAll(context: context, now: now)
        try context.save()

        let walks = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-walking" }
        #expect(walks.count == 1)
        #expect(home.departure == base.addingTimeInterval(50 * 60))
        #expect(walks[0].arrival == base.addingTimeInterval(50 * 60))
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walks[0], locationVisits: [home, park], now: now))
    }

    @Test("Walking at a place LifeLog never saw you leave is not a journey")
    func walkInsideOpenStayIsNotAJourney() throws {
        let context = try makeContext()
        let home = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        let walk = Visit(arrival: base.addingTimeInterval(60 * 60),
                         departure: base.addingTimeInterval(75 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", userActivity: "Walking", source: "health-walking")
        [home, walk].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(2 * 60 * 60))
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isLocationVisit)
        let walks = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-walking" }

        // No departure was ever recorded, so the person is still at home. Reading the
        // walk as leaving and returning would invent an arrival they never made.
        #expect(stays.count == 1)
        #expect(home.departure == nil)
        #expect(walks.isEmpty)
    }

    /// The distinction the app could not make before: both of these are "walking,
    /// no departure recorded, no new arrival". Only the path separates them.
    @Test("A route decides whether a walk left the place or stayed in it")
    func routeSeparatesALoopFromPacing() throws {
        let context = try makeContext()
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        // Out about a kilometre and back to the doorstep.
        let loop = walk(from: 60, to: 80, path: [
            (-23.3700, 150.5100), (-23.3740, 150.5140), (-23.3790, 150.5190),
            (-23.3740, 150.5140), (-23.3701, 150.5101)
        ])
        [home, loop].forEach(context.insert)
        try context.save()

        let now = base.addingTimeInterval(3 * 60 * 60)
        try ActivityLocationPolicy.reconcileAll(context: context, now: now)
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)
        let walks = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-workout" }

        #expect(walks.count == 1, "A journey with a route must survive reconciliation")
        #expect(stays.count == 2, "Home ends at the walk and resumes when it returns")
        #expect(stays[0].departure == base.addingTimeInterval(60 * 60))
        #expect(stays[1].arrival == base.addingTimeInterval(80 * 60))
        #expect(stays[1].departure == nil)
        #expect(stays[1].placeName == "Home")
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walks[0], locationVisits: stays, now: now))
    }

    @Test("Walking about at home keeps its route and stays absorbed")
    func routeShowsPacingIsNotAJourney() throws {
        let context = try makeContext()
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        // Never more than a few dozen metres from the house.
        let pacing = walk(from: 60, to: 80, path: [
            (-23.3700, 150.5100), (-23.3701, 150.5102), (-23.3699, 150.5101), (-23.3700, 150.5100)
        ])
        [home, pacing].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isLocationVisit)
        let walks = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-workout" }

        #expect(stays.count == 1, "The person never left, so the stay is not split")
        #expect(home.departure == nil)
        #expect(walks.isEmpty, "Movement inside a place is absorbed, as it always was")
    }

    @Test("An explicit Home role never shortcuts the route-based absorption rule")
    func homeRoleDoesNotBypassRouteEvidence() throws {
        let context = try makeContext()
        // Named unlike "Home" on purpose — the role, not the name, is what's set.
        let cottage = SavedPlace(name: "The Cottage", latitude: -23.3700, longitude: 150.5100)
        cottage.homeWorkRole = .home
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "The Cottage", inferredActivity: "At home", source: "automatic")
        let pacing = walk(from: 60, to: 80, path: [
            (-23.3700, 150.5100), (-23.3701, 150.5102), (-23.3699, 150.5101), (-23.3700, 150.5100)
        ])
        context.insert(cottage)
        [home, pacing].forEach(context.insert)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context, now: base.addingTimeInterval(3 * 60 * 60))
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isLocationVisit)
        let walks = try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "health-workout" }

        // Identical outcome to the unroled case above: role is read only by commute
        // detection and travel labelling, never by stay/journey reconciliation.
        #expect(stays.count == 1, "The person never left, so the stay is not split")
        #expect(home.departure == nil)
        #expect(walks.isEmpty, "Movement inside a place is absorbed regardless of its role")
    }

    @Test("A recorded path is simplified without losing the shape of the walk")
    func simplifiesARecordedPath() {
        // A straight kilometre sampled every second, as Health delivers it.
        let straight = (0..<600).map { index in
            RoutePoint(latitude: -23.37 + Double(index) * 0.000015, longitude: 150.51,
                       time: base.addingTimeInterval(Double(index)))
        }
        let simplified = RouteSimplification.simplify(straight)
        #expect(simplified.count == 2, "A straight line needs only its ends")
        #expect(simplified.first == straight.first)
        #expect(simplified.last == straight.last)

        // A right-angle turn must survive.
        let corner = straight + (1..<300).map { index in
            RoutePoint(latitude: -23.37 + 599 * 0.000015, longitude: 150.51 + Double(index) * 0.000015,
                       time: base.addingTimeInterval(Double(599 + index)))
        }
        let keptCorner = RouteSimplification.simplify(corner)
        #expect(keptCorner.count == 3)
        #expect(keptCorner[1].latitude == -23.37 + 599 * 0.000015)
    }

    /// A workout-backed walk carrying a recorded path.
    private func walk(from startMinutes: Double, to endMinutes: Double,
                      path: [(Double, Double)]) -> Visit {
        let start = base.addingTimeInterval(startMinutes * 60)
        let end = base.addingTimeInterval(endMinutes * 60)
        let visit = Visit(arrival: start, departure: end,
                          latitude: 0, longitude: 0, placeName: "Walking workout",
                          inferredActivity: "Walking", userActivity: "Walking",
                          source: "health-workout", recognitionConfidence: "device")
        let step = end.timeIntervalSince(start) / Double(max(1, path.count - 1))
        visit.route = path.enumerated().map { index, point in
            RoutePoint(latitude: point.0, longitude: point.1,
                       time: start.addingTimeInterval(Double(index) * step))
        }
        return visit
    }

    @Test("Stays split by a walk at the same place are rejoined")
    func rejoinsStaysSplitByMovement() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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

    /// Built from a captured day: two "high confidence" stays of 3m46s and 5m46s on a
    /// commute, which the old confidence-only test could never queue.
    @Test("A brief stay never returned to is queued however sure Apple Maps was")
    func queuesConfidentDriveBys() {
        let drivePast = Visit(arrival: base, departure: base.addingTimeInterval(226),
                              latitude: -23.39, longitude: 150.49,
                              placeName: "Riverside Precinct", inferredActivity: "Visiting",
                              source: "automatic", recognitionConfidence: "high")
        // Home is brief here too, but it recurs, so it is not a passing stay.
        let homeMorning = Visit(arrival: base.addingTimeInterval(-3_600), departure: base,
                                latitude: -23.37, longitude: 150.51,
                                placeName: "Home", inferredActivity: "At home",
                                source: "automatic", recognitionConfidence: "learned")
        let homeEvening = Visit(arrival: base.addingTimeInterval(600), departure: base.addingTimeInterval(700),
                                latitude: -23.37, longitude: 150.51,
                                placeName: "Home", inferredActivity: "At home",
                                source: "automatic", recognitionConfidence: "learned")
        // Long enough to be somewhere they actually went.
        let shop = Visit(arrival: base.addingTimeInterval(2_000), departure: base.addingTimeInterval(4_400),
                         latitude: -23.44, longitude: 150.46,
                         placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                         source: "automatic", recognitionConfidence: "high")

        let entries = ReviewQueue.entries(in: [drivePast, homeMorning, homeEvening, shop],
                                          now: base.addingTimeInterval(7_200))

        #expect(entries.count == 1)
        #expect(entries.first?.visit === drivePast)
        #expect(entries.first?.reason == .passingStay)
    }

    @Test("The review queue leads with what is worth answering first")
    func ranksReviewQueueByImpact() {
        let current = Visit(arrival: base.addingTimeInterval(9_000),
                            latitude: -23.41, longitude: 150.53,
                            placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                            source: "automatic")
        // Unidentified, and the same coordinate keeps coming back: worth more than a
        // one-off because answering it corrects every visit there.
        let repeatedUnknown = (0..<3).map { index in
            Visit(arrival: base.addingTimeInterval(Double(index) * 3_600),
                  departure: base.addingTimeInterval(Double(index) * 3_600 + 1_800),
                  latitude: -23.38, longitude: 150.52,
                  placeName: Visit.unknownPlaceName, inferredActivity: "Visiting",
                  source: "automatic", recognitionConfidence: "low")
        }
        let weakGuess = Visit(arrival: base.addingTimeInterval(20_000),
                              departure: base.addingTimeInterval(23_600),
                              latitude: -23.42, longitude: 150.55,
                              placeName: "atWork Australia", inferredActivity: "Working",
                              source: "automatic", recognitionConfidence: "low")
        let drivePast = Visit(arrival: base.addingTimeInterval(30_000),
                              departure: base.addingTimeInterval(30_226),
                              latitude: -23.39, longitude: 150.49,
                              placeName: "Riverside Precinct", inferredActivity: "Visiting",
                              source: "automatic", recognitionConfidence: "high")

        let entries = ReviewQueue.entries(in: [weakGuess, drivePast, current] + repeatedUnknown,
                                          now: base.addingTimeInterval(40_000))

        #expect(entries.map(\.reason) == [.unidentified, .unidentified, .unidentified,
                                          .unidentified, .uncertainMatch, .passingStay])
        // The place they are standing in right now leads: it is the only one still
        // answerable from memory of being there.
        #expect(entries.first?.visit === current)
        // Then the repeated unknown, which accounts for an hour and a half across
        // three visits, ahead of the weak guess and the drive-by. Read without
        // subscripting: an unexpected count should fail the test, not trap and take
        // every other suite in the process down with it.
        #expect(entries.dropFirst().first?.impact == 5_400)
        #expect(entries.last?.visit === drivePast)
    }

    @Test("A place the person has already labelled or hidden is not queued again")
    func answeredStaysAreNotQueued() throws {
        let context = try makeContext()
        let answered = Visit(arrival: base, departure: base.addingTimeInterval(200),
                             latitude: -23.39, longitude: 150.49,
                             placeName: "Riverside Precinct", inferredActivity: "Visiting",
                             userActivity: "Visiting", source: "automatic",
                             recognitionConfidence: "high")
        let ignored = Visit(arrival: base.addingTimeInterval(400), departure: base.addingTimeInterval(600),
                            latitude: -23.45, longitude: 150.41,
                            placeName: "Somewhere", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "high")
        // Inserted and saved first: an ignore is only recorded for a visit that
        // belongs to a store. Cleared afterwards because the registry is a
        // process-wide UserDefaults list shared with every other test.
        [answered, ignored].forEach(context.insert)
        try context.save()
        ignored.isIgnored = true
        defer { ignored.isIgnored = false }

        #expect(ignored.isIgnored)
        #expect(ReviewQueue.entries(in: [answered, ignored], now: base.addingTimeInterval(3_600)).isEmpty)

        // A visit that is not in the timeline yet has no ignore state at all, so it
        // cannot write a key that later matches a different unsaved visit.
        let unsaved = Visit(arrival: base, departure: base.addingTimeInterval(200),
                            latitude: -23.39, longitude: 150.49,
                            placeName: "Elsewhere", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "high")
        unsaved.isIgnored = true
        #expect(unsaved.isIgnored == false)
    }

    /// Matches the coordinates `stay("Home", ...)`/`stay("Work", ...)` fixtures use
    /// throughout this file, so commute detection has an explicit role to resolve
    /// instead of guessing from the name.
    private var homeWorkPlaces: [SavedPlace] {
        let home = SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51)
        home.homeWorkRole = .home
        let work = SavedPlace(name: "Work", latitude: -23.42, longitude: 150.55)
        work.homeWorkRole = .work
        return [home, work]
    }

    /// Shaped like a captured day: work to home with a six-minute Apple Maps match in
    /// the middle, which is a business passed at speed rather than a destination.
    @Test("A commute survives a brief stop on the way")
    func detectsCommuteAcrossAShortStop() {
        let work = stay("Work", from: 0, to: 60, latitude: -23.42, longitude: 150.55)
        let drivePast = stay("Metal Recovery Industries", from: 72, to: 78,
                             latitude: -23.40, longitude: 150.52)
        let home = stay("Home", from: 81, to: 200, latitude: -23.37, longitude: 150.51)

        let commutes = CommuteDetection.commutes(in: [work, drivePast, home], savedPlaces: homeWorkPlaces,
                                                 now: base.addingTimeInterval(300 * 60))

        #expect(commutes.count == 1)
        #expect(commutes.first?.direction == .toHome)
        // Measured from leaving work to arriving home, stop included: that time was
        // spent getting home either way.
        #expect(commutes.first?.start == base.addingTimeInterval(60 * 60))
        #expect(commutes.first?.end == base.addingTimeInterval(81 * 60))
    }

    @Test("Only home and work make a commute")
    func commutesRequireBothEnds() {
        let now = base.addingTimeInterval(600 * 60)
        let home = stay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = stay("Work", from: 90, to: 400, latitude: -23.42, longitude: 150.55)
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: homeWorkPlaces, now: now).first?.direction == .toWork)

        // The gym to work is a journey, but it is not a commute.
        let gym = stay("Gracemere Gym", from: 0, to: 60, latitude: -23.44, longitude: 150.46)
        #expect(CommuteDetection.commutes(in: [gym, work], savedPlaces: homeWorkPlaces, now: now).isEmpty)

        // Leaving home and coming back to it is not a commute either.
        let homeAgain = stay("Home", from: 90, to: 200, latitude: -23.37, longitude: 150.51)
        #expect(CommuteDetection.commutes(in: [home, homeAgain], savedPlaces: homeWorkPlaces, now: now).isEmpty)

        // A real errand between the two ends breaks the journey in half.
        let shops = stay("Gracemere Shopping World", from: 65, to: 85,
                         latitude: -23.44, longitude: 150.46)
        #expect(CommuteDetection.commutes(in: [home, shops, work], savedPlaces: homeWorkPlaces, now: now).isEmpty)
    }

    @Test("Only home and work make a commute, by role rather than name")
    func commuteEndpointsAreRoleNotName() {
        let now = base.addingTimeInterval(600 * 60)
        // Named indistinguishably from an ordinary business, but explicitly roled.
        let cottage = SavedPlace(name: "The Cottage", latitude: -23.37, longitude: 150.51)
        cottage.homeWorkRole = .home
        let hq = SavedPlace(name: "Acme HQ", latitude: -23.42, longitude: 150.55)
        hq.homeWorkRole = .work
        let home = stay("The Cottage", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = stay("Acme HQ", from: 90, to: 400, latitude: -23.42, longitude: 150.55)
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: [cottage, hq], now: now).first?.direction == .toWork)

        // A place merely called "Home"/"Work", with no role saved, is not an endpoint
        // — the false positive the old keyword match would have produced.
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: [], now: now).isEmpty)
    }

    @Test("A commute is counted rather than reported as unlogged time")
    func commuteFillsTheGapBetweenHomeAndWork() {
        let home = stay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = stay("Work", from: 85, to: 400, latitude: -23.42, longitude: 150.55)
        let commutes = CommuteDetection.commutes(in: [home, work], savedPlaces: homeWorkPlaces,
                                                  now: base.addingTimeInterval(600 * 60))

        // The interval between the two arrivals, and nothing outside it.
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(70 * 60), in: commutes) != nil)
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(30 * 60), in: commutes) == nil)
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(200 * 60), in: commutes) == nil)
        #expect(commutes.first?.duration == TimeInterval(25 * 60))
        #expect(ActivityCatalog.suggestedCategory(for: "Commuting") == "Commute")
    }

    private func stay(_ name: String, from startMinutes: Double, to endMinutes: Double,
                      latitude: Double, longitude: Double) -> Visit {
        Visit(arrival: base.addingTimeInterval(startMinutes * 60),
              departure: base.addingTimeInterval(endMinutes * 60),
              latitude: latitude, longitude: longitude,
              placeName: name, inferredActivity: "Visiting",
              source: "automatic", recognitionConfidence: "learned")
    }

    /// The reason a callback was acted on is always safe to record. The evidence —
    /// which places were offered and how far away they were — is a record of where the
    /// owner has been, and must not be written unless they asked for it.
    @Test("Place names are only recorded when detailed diagnostics are on")
    func detailedDiagnosticsAreOptIn() throws {
        let context = try makeContext()
        let wasDetailed = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = wasDetailed }

        LocationDiagnostics.isDetailed = false
        LocationDiagnostics.record(.merged, subject: "Duplicate callback",
                                   reason: "same arrival", evidence: "Corner Cafe folded into Home",
                                   context: context)
        LocationDiagnostics.recordLookup(
            radius: 150, cacheHit: false,
            candidates: [PlaceSuggestion(name: "Corner Cafe", latitude: -23.37, longitude: 150.51,
                                         suggestedActivity: "Eating", distance: 22)],
            selected: nil, confidence: "medium", fallback: nil, context: context)
        try context.save()

        var events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.count == 2)
        // The decision and the numbers survive; the place names do not.
        #expect(events.contains { $0.message.contains("merged") })
        #expect(events.contains { $0.message.contains("1 candidates") })
        #expect(events.allSatisfy { !$0.message.contains("Corner Cafe") })

        LocationDiagnostics.isDetailed = true
        LocationDiagnostics.record(.merged, subject: "Duplicate callback",
                                   reason: "same arrival", evidence: "Corner Cafe folded into Home",
                                   context: context)
        try context.save()
        events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.contains { $0.message.contains("Corner Cafe") })
        #expect(events.allSatisfy { $0.category == LocationDiagnostics.category })
    }

    @Test("LifeLog sleep estimate reflects duration, stages, and interruptions")
    func estimatesSleepQuality() {
        let summary = SleepSummary(
            totalSleep: 8 * 60 * 60,
            timeInBed: 8.5 * 60 * 60,
            awake: 30 * 60,
            rem: 90 * 60,
            core: 4 * 60 * 60,
            deep: 2.5 * 60 * 60,
            interruptions: 2
        )

        #expect(summary.estimatedScore == 94)
    }

    @Test("Vehicle travel is classified toward a recurring work destination")
    func classifiesTravelToWork() throws {
        let context = try makeContext()
        let work = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Office",
            inferredActivity: "Working",
            source: "automatic"
        )
        let travel = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            inferredActivity: "Travelling",
            userActivity: "Travelling",
            source: "motion"
        )
        let office = SavedPlace(name: "Office", latitude: -27.46, longitude: 153.04)
        office.homeWorkRole = .work
        context.insert(office)
        context.insert(work)
        context.insert(travel)
        try context.save()

        try ActivityLocationPolicy.updateTravelDescriptions(context: context)

        #expect(travel.activity == "Travelling to Work")
        #expect(travel.recognitionConfidence == "learned")
    }

    @Test("Archive repair rejoins fragmented driving but respects a destination in the gap")
    func archiveRepairRejoinsTravelWithoutCrossingAStay() throws {
        let context = try makeContext()
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

    @Test("A manually named travel activity is preserved")
    func preservesManualTravelActivity() throws {
        let context = try makeContext()
        let work = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Office",
            inferredActivity: "Working",
            source: "automatic"
        )
        let travel = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            inferredActivity: "Travelling",
            userActivity: "Commuting",
            source: "motion"
        )
        let office = SavedPlace(name: "Office", latitude: -27.46, longitude: 153.04)
        office.homeWorkRole = .work
        context.insert(office)
        context.insert(work)
        context.insert(travel)
        try context.save()

        try ActivityLocationPolicy.updateTravelDescriptions(context: context)

        #expect(travel.activity == "Commuting")
        #expect(travel.inferredActivity == "Travelling to Work")
    }

    @Test("Home destination Home has one deterministic open visit")
    func resolvesHomeDestinationHomeSequence() throws {
        let context = try makeContext()
        let firstHome = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                              placeName: "Home", inferredActivity: "At home", source: "automatic")
        let destination = Visit(arrival: base.addingTimeInterval(60 * 60),
                                latitude: -23.43, longitude: 150.45,
                                placeName: "Shops", inferredActivity: "Shopping", source: "automatic")
        let secondHome = Visit(arrival: base.addingTimeInterval(2 * 60 * 60),
                               latitude: -23.37, longitude: 150.51,
                               placeName: "Home", inferredActivity: "At home", source: "automatic")
        [firstHome, destination, secondHome].forEach(context.insert)
        try context.save()

        let repaired = try ActivityLocationPolicy.closeSupersededOpenLocations(context: context)

        #expect(repaired == 2)
        #expect(firstHome.departure == destination.arrival)
        #expect(destination.departure == secondHome.arrival)
        #expect(secondHome.departure == nil)
    }

    @Test("Duplicate delayed callback is preserved and marked superseded")
    func preservesSupersededDelayedCallback() throws {
        let context = try makeContext()
        let learned = Visit(arrival: base, departure: base.addingTimeInterval(20 * 60),
                            latitude: -23.40, longitude: 150.50,
                            placeName: "Park", inferredActivity: "Exercising", source: "automatic",
                            recognitionConfidence: "learned")
        let corrected = Visit(arrival: base.addingTimeInterval(30), departure: base.addingTimeInterval(25 * 60),
                              latitude: -23.399, longitude: 150.50,
                              placeName: "Park", inferredActivity: "Exercising", userActivity: "Exercising",
                              source: "automatic", recognitionConfidence: "confirmed")
        context.insert(learned); context.insert(corrected); try context.save()

        let marked = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        let records = try context.fetch(FetchDescriptor<Visit>())

        #expect(marked == 1)
        #expect(records.count == 2)
        #expect(records.filter(ActivityLocationPolicy.isSupersededLocation).count == 1)
        #expect(records.first(where: { !ActivityLocationPolicy.isSupersededLocation($0) })?.recognitionConfidence == "confirmed")
    }

    @Test("Delayed departure matches its stored arrival, not the newest visit")
    func delayedDepartureMatchesCorrectVisit() {
        let park = Visit(arrival: base,
                         latitude: -23.40, longitude: 150.50,
                         placeName: "Park", inferredActivity: "Exercising", source: "automatic")
        let home = Visit(arrival: base.addingTimeInterval(30 * 60),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")

        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: CLLocationCoordinate2D(latitude: -23.4002, longitude: 150.5001),
            arrival: base,
            departure: base.addingTimeInterval(20 * 60),
            visits: [home, park]
        )

        #expect(matched === park)
    }

    @Test("Location callback replay keeps Home, destination, Home as three consecutive stays")
    func replaysHomeDestinationHomeCallbacks() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.arrive("Shops", at: 60, latitude: -23.4300, longitude: 150.4500, mapsIdentifier: "shops")
        try replay.arrive("Home", at: 120, latitude: -23.3701, longitude: 150.5101, mapsIdentifier: "home")

        let stays = try replay.liveStays()
        #expect(stays.map(\.placeName) == ["Home", "Shops", "Home"])
        #expect(stays.map(\.departure) == [replay.time(60), replay.time(120), nil])
    }

    @Test("A delayed departure replay closes its original stay after a newer arrival")
    func replaysDelayedDepartureAfterNewerArrival() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.arrive("Shops", at: 60, latitude: -23.4300, longitude: 150.4500, mapsIdentifier: "shops")
        try replay.depart(arrival: 0, departure: 45, latitude: -23.3701, longitude: 150.5101)

        let stays = try replay.liveStays()
        #expect(stays[0].placeName == "Home")
        #expect(stays[0].departure == replay.time(45))
        #expect(stays[0].locationResolutionExplanation == .coordinateTime)
        #expect(stays[1].placeName == "Shops")
        #expect(stays[1].departure == nil)
    }

    @Test("Repeated arrival callbacks replay as one live stay")
    func replaysDuplicateArrivals() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.arrive("Home", at: 0.5, latitude: -23.3702, longitude: 150.5101, mapsIdentifier: "home")

        let stays = try replay.liveStays()
        let superseded = try replay.supersededStays()
        #expect(stays.count == 1)
        #expect(superseded.count == 1)
    }

    @Test("A same-venue replay tolerates GPS drift when Maps identity agrees")
    func replaysSameVenueWithGPSDrift() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Rockhampton Mall", at: 0, latitude: -23.3740, longitude: 150.5110, mapsIdentifier: "mall")
        // Around 220 m away: too large for a raw-fix retry, but still one mall POI.
        try replay.arrive("Rockhampton Mall", at: 20.0 / 60, latitude: -23.3720, longitude: 150.5110, mapsIdentifier: "mall")

        let stays = try replay.liveStays()
        let superseded = try replay.supersededStays()
        #expect(stays.count == 1)
        #expect(superseded.count == 1)
    }

    @Test("Nearby named businesses replay as separate destinations")
    func preservesNearbyDifferentBusinessesDuringReplay() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Coffee House", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "coffee-house")
        // About 22 m away, so time and distance alone would look duplicate-like.
        try replay.arrive("Chemist", at: 30, latitude: -23.3702, longitude: 150.5100, mapsIdentifier: "chemist")

        let stays = try replay.liveStays()
        #expect(stays.map(\.placeName) == ["Coffee House", "Chemist"])
        #expect(stays[0].departure == replay.time(30))
        #expect(try replay.supersededStays().isEmpty)
    }

    @Test("Callback repairs persist why each row was retained or superseded")
    func persistsCallbackResolutionExplanation() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Cafe", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "cafe")
        try replay.arrive("Cafe", at: 0.5, latitude: -23.3702, longitude: 150.5101, mapsIdentifier: "cafe")

        let kept = try #require(replay.liveStays().first)
        let superseded = try #require(replay.supersededStays().first)
        #expect(kept.locationResolutionExplanation == .mapsIdentifier)
        #expect(superseded.locationResolutionExplanation == .duplicate)
    }

    @Test("A long journey replay followed by a destination preserves both records")
    func replaysLongTravelThenDestination() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.travel(from: 15, to: 375)
        try replay.arrive("Airport", at: 375, latitude: -23.3810, longitude: 150.4750, mapsIdentifier: "airport")

        let stays = try replay.liveStays()
        #expect(stays.map(\.placeName) == ["Home", "Airport"])
        #expect(stays[0].departure == replay.time(375))
        #expect(try replay.travelRecords().count == 1)
    }

    @Test("Departure coordinate distinguishes overlapping arrivals")
    func departureCoordinateDistinguishesOverlappingArrivals() {
        let cafe = Visit(arrival: base,
                         latitude: -23.38, longitude: 150.52,
                         placeName: "Cafe", inferredActivity: "Coffee", source: "automatic")
        let shops = Visit(arrival: base.addingTimeInterval(60),
                          latitude: -23.44, longitude: 150.46,
                          placeName: "Shops", inferredActivity: "Shopping", source: "automatic")

        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: CLLocationCoordinate2D(latitude: -23.4401, longitude: 150.4601),
            arrival: shops.arrival,
            departure: base.addingTimeInterval(25 * 60),
            visits: [cafe, shops]
        )

        #expect(matched === shops)
    }

    @Test("An implausible departure never falls back to the newest visit")
    func unmatchedDepartureDoesNotCloseNewestVisit() {
        let home = Visit(arrival: base,
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")

        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03),
            arrival: base.addingTimeInterval(-4 * 60 * 60),
            departure: base.addingTimeInterval(-3 * 60 * 60),
            visits: [home]
        )

        #expect(matched == nil)
        #expect(home.departure == nil)
    }

    @Test("A repeated departure matches the exact closed arrival before another open visit")
    func repeatedDepartureRemainsIdempotent() {
        let original = Visit(arrival: base,
                             departure: base.addingTimeInterval(20 * 60),
                             latitude: -23.40, longitude: 150.50,
                             placeName: "Park", inferredActivity: "Exercising", source: "automatic")
        let overlapping = Visit(arrival: base.addingTimeInterval(10 * 60),
                                latitude: -23.4001, longitude: 150.5001,
                                placeName: "Park", inferredActivity: "Exercising", source: "automatic")

        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: CLLocationCoordinate2D(latitude: -23.40, longitude: 150.50),
            arrival: base,
            departure: base.addingTimeInterval(20 * 60),
            visits: [overlapping, original]
        )

        #expect(matched === original)
        #expect(overlapping.departure == nil)
    }

    @Test("A started workout survives the stays that overlap it, even with no route")
    func startedWorkoutIsNeverAbsorbed() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        workout.route = straightRoute(from: base, to: base.addingTimeInterval(34 * 60),
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
        let context = try makeContext()
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
        workout.route = straightRoute(from: base, to: base.addingTimeInterval(34 * 60),
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
        let context = try makeContext()
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
        let context = try makeContext()
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

    // MARK: - Workout vs. weaker movement records

    // health-walking (step counts) and motion (Core Motion) are both weaker, inferred
    // guesses at the same real event a health-workout already declares. Cross-checked
    // against Life Cycle, run in parallel the whole time: it recorded one walk on every
    // morning these overlapped, never two.

    @Test("A health-walking record staggered against a workout is trimmed to what the workout does not cover")
    func staggeredWalkingRecordIsTrimmedAroundTheWorkout() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
        // The 7 August capture exactly: one 34-minute walk stored as 10.6m + 4.6m, cut
        // at the arrival and departure of a stay recorded partway round.
        let session = UUID()
        let first = Visit(arrival: base, departure: base.addingTimeInterval(11 * 60),
                          latitude: 0, longitude: 0, placeName: "Walking workout",
                          inferredActivity: "Walking", source: "health-workout",
                          recognitionConfidence: "device", healthKitSampleIDs: [session])
        first.route = straightRoute(from: base, to: base.addingTimeInterval(11 * 60),
                                    latitude: -23.441, longitude: 150.45, metresPerSecond: 1.3)
        let second = Visit(arrival: base.addingTimeInterval(28 * 60),
                           departure: base.addingTimeInterval(33 * 60),
                           latitude: 0, longitude: 0, placeName: "Walking workout",
                           inferredActivity: "Walking", source: "health-workout",
                           recognitionConfidence: "device", healthKitSampleIDs: [session])
        second.route = straightRoute(from: base.addingTimeInterval(28 * 60),
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

    /// A path along a line of longitude at a steady pace. Zero metres per second gives
    /// a path that stays exactly where it started, which is what a real stop looks like.
    private func straightRoute(from start: Date, to end: Date, latitude: Double,
                               longitude: Double, metresPerSecond: Double) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var time = start
        while time <= end {
            let metres = metresPerSecond * time.timeIntervalSince(start)
            points.append(RoutePoint(latitude: latitude + metres / 111_000,
                                     longitude: longitude, time: time))
            time = time.addingTimeInterval(60)
        }
        return points
    }

    @Test("A real stop during a walk keeps its place")
    func genuineStopDuringWorkoutSurvives() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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
        let context = try makeContext()
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

    @Test("Store mutation resolution leaves one non-overlapping current location")
    func resolvesAndValidatesLocationStoreAfterMutation() throws {
        let context = try makeContext()
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
        let context = try makeContext()
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

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            VisitCorrection.self,
            // The resolver records why it merged, closed or superseded a callback, so
            // its diagnostics have to be part of the store these tests write to.
            DiagnosticEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

/// Replays persisted Core Location facts in the same order they are delivered. The
/// recorder supplies coordinates and timestamps; the resolver remains the single
/// source of truth for closing, retaining, and superseding their timeline rows.
@MainActor
private final class LocationCallbackReplay {
    private let context: ModelContext
    private let base: Date

    init(base: Date) throws {
        self.base = base
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           DiagnosticEvent.self, configurations: configuration)
        context = ModelContext(container)
    }

    func time(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    func arrive(_ name: String, at minutes: Double, latitude: Double, longitude: Double,
                mapsIdentifier: String) throws {
        context.insert(Visit(arrival: time(minutes), latitude: latitude, longitude: longitude,
                             placeName: name, inferredActivity: "Visiting", source: "automatic",
                             recognitionConfidence: "learned", mapsIdentifier: mapsIdentifier))
        try resolve()
    }

    func depart(arrival: Double, departure: Double, latitude: Double, longitude: Double) throws {
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: coordinate, arrival: time(arrival), departure: time(departure), visits: visits
        )
        #expect(matched != nil, "The replayed departure must resolve to its original arrival")
        matched?.departure = time(departure)
        matched?.locationResolutionExplanation = .coordinateTime
        try resolve()
    }

    func travel(from start: Double, to end: Double) throws {
        context.insert(Visit(arrival: time(start), departure: time(end), latitude: 0, longitude: 0,
                             placeName: "In transit", inferredActivity: "Travelling", source: "motion"))
        try resolve()
    }

    func liveStays() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)
    }

    func supersededStays() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isSupersededLocation)
    }

    func travelRecords() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }
    }

    private func resolve() throws {
        try ActivityLocationPolicy.resolveLocationCallbacks(context: context)
        try context.save()
    }
}
