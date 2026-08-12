import Foundation
import Testing
@testable import LifeLog

@MainActor
struct TravelInsightsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Home to destination to Home becomes two travel trips")
    func roundTripCountsTransitionsNotDestinations() {
        let home = stay(from: 0, to: 60, name: "Home", activity: "At home")
        let outbound = movement(from: 60, to: 90, activity: "Travelling")
        let destination = stay(from: 90, to: 150, name: "Park", activity: "Visiting")
        let inbound = movement(from: 150, to: 180, activity: "Travelling")
        let returned = stay(from: 180, to: 240, name: "Home", activity: "At home")

        let result = snapshot([home, outbound, destination, inbound, returned]).travel

        #expect(result.tripCount == 2)
        #expect(result.totalHours == 1)
        #expect(result.medianTripMinutes == 30)
        #expect(result.nonCommuteHours == 1)
        #expect(result.commuteHours == 0)
    }

    @Test("A long Home to Work gap is a long commute")
    func longCommuteIsSeparatedFromOtherTravel() {
        let homePlace = SavedPlace(name: "Home", latitude: 0, longitude: 0, mapsIdentifier: "home")
        homePlace.homeWorkRole = .home
        let workPlace = SavedPlace(name: "Office", latitude: 0, longitude: 0, mapsIdentifier: "work")
        workPlace.homeWorkRole = .work
        let home = stay(from: 0, to: 60, name: "Home", activity: "At home", mapsID: "home")
        let work = stay(from: 180, to: 240, name: "Office", activity: "Working", mapsID: "work")

        let result = InsightsSnapshot.make(
            visits: [home, work], window: .day, anchorDate: base,
            now: base.addingTimeInterval(8 * 3600),
            savedPlaces: [homePlace, workPlace]
        ).travel

        #expect(result.tripCount == 1)
        #expect(result.commuteHours == 2)
        #expect(result.nonCommuteHours == 0)
        #expect(result.longTripCount == 1)
    }

    @Test("Walking inside Home is not travel")
    func movementInsideResolvedPlaceIsExcluded() {
        let home = stay(from: 0, to: 180, name: "Home", activity: "At home")
        let walking = movement(from: 60, to: 120, activity: "Walking")

        let result = snapshot([home, walking]).travel

        #expect(result.tripCount == 0)
        #expect(result.totalHours == 0)
    }

    @Test("A delayed destination callback does not duplicate a travel interval")
    func delayedCallbackKeepsOverlapResolution() {
        let home = stay(from: 0, to: 60, name: "Home", activity: "At home")
        let movement = movement(from: 60, to: 120, activity: "Travelling")
        let delayedDestination = stay(from: 90, to: 180, name: "Cafe", activity: "Eating")

        let result = snapshot([home, movement, delayedDestination]).travel

        #expect(result.tripCount == 0)
        #expect(result.totalHours == 0)
    }

    @Test("An explicit flight is a long non-commute trip with a confident mode")
    func flightModeAndLongTrip() {
        let flight = Visit(arrival: base, departure: base.addingTimeInterval(3 * 3600),
                           latitude: 0, longitude: 0, placeName: "Flight",
                           inferredActivity: "Flight", source: "manual")
        let segment = InsightSegment.visit(flight, visibleFrom: base,
                                           visibleTo: base.addingTimeInterval(3 * 3600), now: base)

        let result = TravelInsights.make(from: [segment])

        #expect(result.tripCount == 1)
        #expect(result.longTripCount == 1)
        #expect(result.modeCounts[.flight] == 1)
        #expect(result.nonCommuteHours == 3)
    }

    @Test("Short vehicle travel stays out of Timeline while long travel can appear")
    func timelineKeepsShortTravelQuiet() {
        let home = stay(from: 0, to: 60, name: "Home", activity: "At home")
        let destination = stay(from: 180, to: 240, name: "Work", activity: "Working")
        let shortDrive = movement(from: 60, to: 90, activity: "Travelling")
        let longDrive = movement(from: 60, to: 180, activity: "Travelling")

        #expect(!ActivityLocationPolicy.shouldShowInTimeline(shortDrive,
                                                              locationVisits: [home, destination],
                                                              now: base.addingTimeInterval(5 * 3600)))
        #expect(ActivityLocationPolicy.shouldShowInTimeline(longDrive,
                                                             locationVisits: [home, destination],
                                                             now: base.addingTimeInterval(5 * 3600)))
    }

    private func snapshot(_ visits: [Visit]) -> InsightsSnapshot {
        InsightsSnapshot.make(visits: visits, window: .day, anchorDate: base,
                              now: base.addingTimeInterval(8 * 3600))
    }

    private func stay(from startMinutes: Double, to endMinutes: Double,
                      name: String, activity: String, mapsID: String? = nil) -> Visit {
        Visit(arrival: base.addingTimeInterval(startMinutes * 60),
              departure: base.addingTimeInterval(endMinutes * 60),
              latitude: 0, longitude: 0, placeName: name,
              inferredActivity: activity, source: "automatic", mapsIdentifier: mapsID)
    }

    private func movement(from startMinutes: Double, to endMinutes: Double,
                          activity: String) -> Visit {
        Visit(arrival: base.addingTimeInterval(startMinutes * 60),
              departure: base.addingTimeInterval(endMinutes * 60),
              latitude: 0, longitude: 0, placeName: "In transit",
              inferredActivity: activity, userActivity: activity, source: "motion")
    }
}
