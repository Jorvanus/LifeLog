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

    /// Shaped like a captured day: work to home with a six-minute Apple Maps match in
    /// the middle, which is a business passed at speed rather than a destination.
    @Test("A commute survives a brief stop on the way")
    func detectsCommuteAcrossAShortStop() {
        let work = stay("Work", from: 0, to: 60, latitude: -23.42, longitude: 150.55)
        let drivePast = stay("Metal Recovery Industries", from: 72, to: 78,
                             latitude: -23.40, longitude: 150.52)
        let home = stay("Home", from: 81, to: 200, latitude: -23.37, longitude: 150.51)

        let commutes = CommuteDetection.commutes(in: [work, drivePast, home],
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
        #expect(CommuteDetection.commutes(in: [home, work], now: now).first?.direction == .toWork)

        // The gym to work is a journey, but it is not a commute.
        let gym = stay("Gracemere Gym", from: 0, to: 60, latitude: -23.44, longitude: 150.46)
        #expect(CommuteDetection.commutes(in: [gym, work], now: now).isEmpty)

        // Leaving home and coming back to it is not a commute either.
        let homeAgain = stay("Home", from: 90, to: 200, latitude: -23.37, longitude: 150.51)
        #expect(CommuteDetection.commutes(in: [home, homeAgain], now: now).isEmpty)

        // A real errand between the two ends breaks the journey in half.
        let shops = stay("Gracemere Shopping World", from: 65, to: 85,
                         latitude: -23.44, longitude: 150.46)
        #expect(CommuteDetection.commutes(in: [home, shops, work], now: now).isEmpty)
    }

    @Test("A commute is counted rather than reported as unlogged time")
    func commuteFillsTheGapBetweenHomeAndWork() {
        let home = stay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = stay("Work", from: 85, to: 400, latitude: -23.42, longitude: 150.55)
        let commutes = CommuteDetection.commutes(in: [home, work], now: base.addingTimeInterval(600 * 60))

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

        let superseded = ActivityLocationPolicy.supersedePassingStays(
            during: [workout], stays: [driveBy], context: context,
            now: base.addingTimeInterval(2 * 60 * 60)
        )

        #expect(superseded == 1)
        #expect(driveBy.resolutionState == .superseded)
        #expect(!ActivityLocationPolicy.shouldShowInTimeline(driveBy, locationVisits: []))
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

        let superseded = ActivityLocationPolicy.supersedePassingStays(
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
