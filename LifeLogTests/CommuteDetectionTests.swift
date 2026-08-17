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
}
