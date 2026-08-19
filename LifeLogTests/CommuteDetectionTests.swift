import Foundation
import Testing
@testable import LifeLog

struct CommuteDetectionTests {
    private var homePlace: SavedPlace {
        let place = SavedPlace(name: "Home", latitude: -27.4698, longitude: 153.0251, mapsIdentifier: "home-id")
        place.homeWorkRole = .home
        return place
    }
    private var workPlace: SavedPlace {
        let place = SavedPlace(name: "Work", latitude: -27.47, longitude: 153.03, mapsIdentifier: "work-id")
        place.homeWorkRole = .work
        return place
    }
    private var roledPlaces: [SavedPlace] { [homePlace, workPlace] }

    @Test("An overlapping visit does not crash commute detection")
    func overlappingVisitsDoNotCrash() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let home = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "home-id")
        // Arrives 5 minutes before Home's departure — stays are sorted by arrival,
        // not departure, so this candidate still comes after `home` in that order
        // despite overlapping it. DateInterval.init(start:end:) traps on end < start;
        // this is the exact shape that crashed on-device 2026-08-10 adding a
        // backfilled manual Work visit that overlapped the stay before it.
        let work = Visit(arrival: start.addingTimeInterval(55 * 60), departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "manual", mapsIdentifier: "work-id")
        let commutes = CommuteDetection.commutes(in: [home, work], savedPlaces: roledPlaces)
        #expect(commutes.isEmpty)
    }

    @Test("A normal gap between Home and Work is recognised as a commute")
    func normalCommuteIsDetected() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let home = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "home-id")
        let work = Visit(arrival: start.addingTimeInterval(90 * 60), departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "work-id")
        let commutes = CommuteDetection.commutes(in: [home, work], savedPlaces: roledPlaces)
        let commute = try #require(commutes.first)
        #expect(commutes.count == 1)
        #expect(commute.direction == .toWork)
        let expectedDuration: TimeInterval = 30 * 60
        #expect(commute.duration == expectedDuration)
    }

    @Test("A place named for its role is not required — the role is what matters")
    func commuteDetectionIsNameIndependent() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let base = SavedPlace(name: "Acme HQ", latitude: -27.47, longitude: 153.03, mapsIdentifier: "acme-hq")
        base.homeWorkRole = .work
        let cottage = SavedPlace(name: "The Cottage", latitude: -27.4698, longitude: 153.0251,
                                 mapsIdentifier: "cottage-id")
        cottage.homeWorkRole = .home

        let home = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "The Cottage",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "cottage-id")
        let work = Visit(arrival: start.addingTimeInterval(90 * 60), departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Acme HQ",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "acme-hq")
        let commutes = CommuteDetection.commutes(in: [home, work], savedPlaces: [base, cottage])
        #expect(commutes.count == 1)
        #expect(commutes.first?.direction == .toWork)
    }

    @Test("A place merely named for home or work, with no role set, is not a commute destination")
    func unroledPlaceIsNotACommuteEndpoint() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let work = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "work-id")
        // "Homeward Bound Café" would have matched the old keyword substring test.
        // No role is set on it, so — even leaving from a real endpoint — it must
        // never be treated as a Home arrival.
        let cafe = Visit(arrival: start.addingTimeInterval(90 * 60), departure: start.addingTimeInterval(2 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Homeward Bound Café",
                         inferredActivity: "Eating", source: "automatic", mapsIdentifier: "cafe-id")
        let commutes = CommuteDetection.commutes(in: [work, cafe], savedPlaces: [workPlace])
        #expect(commutes.isEmpty)
    }

    @Test("A commute only needs a Home/Work destination — the origin can be any real stay")
    func commuteDestinationAloneIsEnough() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Work, a real stay at the gym (no role), then Home — the classic
        // "not every trip home starts from work" case. Neither end of this
        // three-stay day is a Home<->Work pair, but the final leg still ends
        // at Home and should still count as a commute home.
        let work = Visit(arrival: start, departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "work-id")
        let gym = Visit(arrival: start.addingTimeInterval((9 * 60 + 20) * 60),
                        departure: start.addingTimeInterval((9 * 60 + 80) * 60),
                        latitude: 0, longitude: 0, placeName: "Gym",
                        inferredActivity: "Fitness", source: "automatic")
        let home = Visit(arrival: start.addingTimeInterval((9 * 60 + 95) * 60), departure: nil,
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "home-id")
        let commutes = CommuteDetection.commutes(in: [work, gym, home], savedPlaces: roledPlaces)
        #expect(commutes.count == 1)
        #expect(commutes.first?.direction == .toHome)
        #expect(commutes.first?.start == gym.departure)
        #expect(commutes.first?.end == home.arrival)
    }

    @Test("A brief real stop on the way is absorbed into one commute, with its own step")
    func briefWaypointStopChainsTheCommute() throws {
        // Reproduces a real 2026-08-19 trip: leave Work, a 12-minute drive to ALDI,
        // a 16m50s stop there, then 10 minutes on to Home. Lifecycle-style apps
        // capture this whole 38-minute door-to-door span as one "Commute home" with
        // the ALDI stop as a visible step; before this test, LifeLog only recorded
        // the last 10-minute leg and silently dropped the work->ALDI drive and the
        // stop itself.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let work = Visit(arrival: start, departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "work-id")
        let aldiArrival = work.departure!.addingTimeInterval(12 * 60)
        let aldiDeparture = aldiArrival.addingTimeInterval(16 * 60 + 50)
        let aldi = Visit(arrival: aldiArrival, departure: aldiDeparture,
                         latitude: 0, longitude: 0, placeName: "ALDI",
                         inferredActivity: "Shopping", source: "automatic")
        let home = Visit(arrival: aldiDeparture.addingTimeInterval(10 * 60), departure: nil,
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "home-id")
        let commutes = CommuteDetection.commutes(in: [work, aldi, home], savedPlaces: roledPlaces)
        let commute = try #require(commutes.first)
        #expect(commutes.count == 1)
        #expect(commute.direction == .toHome)
        #expect(commute.start == work.departure)
        #expect(commute.end == home.arrival)

        #expect(commute.legs.count == 3)
        guard commute.legs.count == 3 else { return }
        #expect(isTransport(commute.legs[0]))
        #expect(commute.legs[0].start == work.departure)
        #expect(commute.legs[0].end == aldiArrival)
        #expect(isStop(commute.legs[1], placeName: "ALDI", activityLabel: "Shopping"))
        #expect(commute.legs[1].start == aldiArrival)
        #expect(commute.legs[1].end == aldiDeparture)
        #expect(isTransport(commute.legs[2]))
        #expect(commute.legs[2].start == aldiDeparture)
        #expect(commute.legs[2].end == home.arrival)
    }

    @Test("A stop long enough to be its own errand still breaks the commute")
    func longStopStillBreaksTheCommute() throws {
        // Reproduces a real 2026-08-14 trip: a 38-minute grocery run is a separate
        // outing, not a quick stop on the way — only the leg after it should count
        // as the commute home, same as the existing gym case above.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let work = Visit(arrival: start, departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic", mapsIdentifier: "work-id")
        let groceriesArrival = work.departure!.addingTimeInterval(10 * 60)
        let groceriesDeparture = groceriesArrival.addingTimeInterval(38 * 60)
        let groceries = Visit(arrival: groceriesArrival, departure: groceriesDeparture,
                              latitude: 0, longitude: 0, placeName: "Gracemere Shoppingworld",
                              inferredActivity: "Groceries", source: "automatic")
        let home = Visit(arrival: groceriesDeparture.addingTimeInterval(10 * 60), departure: nil,
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic", mapsIdentifier: "home-id")
        let commutes = CommuteDetection.commutes(in: [work, groceries, home], savedPlaces: roledPlaces)
        let commute = try #require(commutes.first)
        #expect(commutes.count == 1)
        #expect(commute.direction == .toHome)
        #expect(commute.start == groceriesDeparture)
        #expect(commute.end == home.arrival)
        #expect(commute.legs.count == 1)
        if let leg = commute.legs.first { #expect(isTransport(leg)) }
    }

    private func isTransport(_ leg: Commute.Leg) -> Bool {
        if case .transport = leg.kind { return true }
        return false
    }

    private func isStop(_ leg: Commute.Leg, placeName: String, activityLabel: String) -> Bool {
        if case .stop(let name, let activity) = leg.kind {
            return name == placeName && activity == activityLabel
        }
        return false
    }
}
