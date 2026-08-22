import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Building and classifying travel/walk records: when a walk earns a timeline entry,
/// which days a stay counts toward, whether a route shows a journey or just pacing
/// about, route simplification, commute detection between saved home/work roles, and
/// labelling vehicle travel toward a recognised destination.
@MainActor
struct TravelConstructionTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

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
        let context = try ActivityLocationPolicyFixtures.makeContext()
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
        let context = try ActivityLocationPolicyFixtures.makeContext()
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
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        // Out about a kilometre and back to the doorstep.
        let loop = ActivityLocationPolicyFixtures.walk(from: 60, to: 80, path: [
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
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        // Never more than a few dozen metres from the house.
        let pacing = ActivityLocationPolicyFixtures.walk(from: 60, to: 80, path: [
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
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Named unlike "Home" on purpose — the role, not the name, is what's set.
        let cottage = SavedPlace(name: "The Cottage", latitude: -23.3700, longitude: 150.5100)
        cottage.homeWorkRole = .home
        let home = Visit(arrival: base, latitude: -23.3700, longitude: 150.5100,
                         placeName: "The Cottage", inferredActivity: "At home", source: "automatic")
        let pacing = ActivityLocationPolicyFixtures.walk(from: 60, to: 80, path: [
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
        let work = ActivityLocationPolicyFixtures.stay("Work", from: 0, to: 60, latitude: -23.42, longitude: 150.55)
        let drivePast = ActivityLocationPolicyFixtures.stay("Metal Recovery Industries", from: 72, to: 78,
                             latitude: -23.40, longitude: 150.52)
        let home = ActivityLocationPolicyFixtures.stay("Home", from: 81, to: 200, latitude: -23.37, longitude: 150.51)

        let commutes = CommuteDetection.commutes(in: [work, drivePast, home], savedPlaces: homeWorkPlaces,
                                                 now: base.addingTimeInterval(300 * 60))

        #expect(commutes.count == 1)
        #expect(commutes.first?.direction == .toHome)
        // Measured from leaving work to arriving home, stop included: that time was
        // spent getting home either way.
        #expect(commutes.first?.start == base.addingTimeInterval(60 * 60))
        #expect(commutes.first?.end == base.addingTimeInterval(81 * 60))
    }

    @Test("Only a Home/Work destination makes a commute — the origin can be anything real")
    func commutesRequireBothEnds() {
        let now = base.addingTimeInterval(600 * 60)
        let home = ActivityLocationPolicyFixtures.stay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = ActivityLocationPolicyFixtures.stay("Work", from: 90, to: 400, latitude: -23.42, longitude: 150.55)
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: homeWorkPlaces, now: now).first?.direction == .toWork)

        // The gym to work is still a commute — only the destination needs a role.
        let gym = ActivityLocationPolicyFixtures.stay("Gracemere Gym", from: 0, to: 60, latitude: -23.44, longitude: 150.46)
        let gymToWork = CommuteDetection.commutes(in: [gym, work], savedPlaces: homeWorkPlaces, now: now)
        #expect(gymToWork.count == 1)
        #expect(gymToWork.first?.direction == .toWork)

        // Leaving home and coming back to it is not a commute — same role both ends.
        let homeAgain = ActivityLocationPolicyFixtures.stay("Home", from: 90, to: 200, latitude: -23.37, longitude: 150.51)
        #expect(CommuteDetection.commutes(in: [home, homeAgain], savedPlaces: homeWorkPlaces, now: now).isEmpty)

        // A real errand between the two ends is a brief waypoint stop, not a new
        // origin: it gets absorbed into the same Home->Work commute as its own
        // step, exactly like `CommuteDetectionTests.briefWaypointStopChainsTheCommute`
        // pins for a Work->ALDI->Home trip. The commute still starts at Home's own
        // departure, not the shop's.
        let shops = ActivityLocationPolicyFixtures.stay("Gracemere Shopping World", from: 65, to: 85,
                         latitude: -23.44, longitude: 150.46)
        let shopsToWork = CommuteDetection.commutes(in: [home, shops, work], savedPlaces: homeWorkPlaces, now: now)
        #expect(shopsToWork.count == 1)
        #expect(shopsToWork.first?.start == home.departure)
        #expect(shopsToWork.first?.direction == .toWork)
    }

    @Test("Only home and work make a commute, by role rather than name")
    func commuteEndpointsAreRoleNotName() {
        let now = base.addingTimeInterval(600 * 60)
        // Named indistinguishably from an ordinary business, but explicitly roled.
        let cottage = SavedPlace(name: "The Cottage", latitude: -23.37, longitude: 150.51)
        cottage.homeWorkRole = .home
        let hq = SavedPlace(name: "Acme HQ", latitude: -23.42, longitude: 150.55)
        hq.homeWorkRole = .work
        let home = ActivityLocationPolicyFixtures.stay("The Cottage", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = ActivityLocationPolicyFixtures.stay("Acme HQ", from: 90, to: 400, latitude: -23.42, longitude: 150.55)
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: [cottage, hq], now: now).first?.direction == .toWork)

        // A place merely called "Home"/"Work", with no role saved, is not an endpoint
        // — the false positive the old keyword match would have produced.
        #expect(CommuteDetection.commutes(in: [home, work], savedPlaces: [], now: now).isEmpty)
    }

    @Test("A commute is counted rather than reported as unlogged time")
    func commuteFillsTheGapBetweenHomeAndWork() {
        let home = ActivityLocationPolicyFixtures.stay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51)
        let work = ActivityLocationPolicyFixtures.stay("Work", from: 85, to: 400, latitude: -23.42, longitude: 150.55)
        let commutes = CommuteDetection.commutes(in: [home, work], savedPlaces: homeWorkPlaces,
                                                  now: base.addingTimeInterval(600 * 60))

        // The interval between the two arrivals, and nothing outside it.
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(70 * 60), in: commutes) != nil)
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(30 * 60), in: commutes) == nil)
        #expect(CommuteDetection.commute(covering: base.addingTimeInterval(200 * 60), in: commutes) == nil)
        #expect(commutes.first?.duration == TimeInterval(25 * 60))
        #expect(ActivityCatalog.suggestedCategory(for: "Commuting") == "Commute")
    }

    @Test("Vehicle travel is classified toward a recurring work destination")
    func classifiesTravelToWork() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
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

    @Test("A manually named travel activity is preserved")
    func preservesManualTravelActivity() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
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

    @Test("A manually confirmed journey is movement, not a location")
    func manualJourneyDoesNotBecomePlace() {
        let journey = Visit(arrival: base, departure: base.addingTimeInterval(15 * 60),
                            latitude: 0, longitude: 0,
                            placeName: "State Government Building → ALDI",
                            inferredActivity: "Travelling", userActivity: "Travelling",
                            source: VisitSource.manualTravelRaw)

        #expect(journey.visitSource.isLocation == false)
        #expect(journey.visitSource.isDeviceActivity)
        #expect(ActivityLocationPolicy.isTravelActivity(journey))
        #expect(ActivityLocationPolicy.shouldShowInTimeline(journey, locationVisits: []))
    }
}
