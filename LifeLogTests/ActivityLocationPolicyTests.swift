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
        // A stray sample either side of a stay still stays out of the card list.
        #expect(ActivityLocationPolicy.shouldShowInTimeline(walk(minutes: 3),
                                                           locationVisits: [home, park], now: now) == false)
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
        context.insert(work)
        context.insert(travel)
        try context.save()

        try ActivityLocationPolicy.updateTravelDescriptions(context: context)

        #expect(travel.activity == "Travelling to Work")
        #expect(travel.recognitionConfidence == "learned")
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

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            VisitCorrection.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
