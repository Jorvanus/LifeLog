import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// `ActivityLocationPolicy.matchDeparture` on its own: matching a delayed departure to
/// the visit it belongs to (by stored arrival, not recency), distinguishing overlapping
/// arrivals by departure coordinate, refusing to guess when nothing plausible matches,
/// idempotently re-matching a repeated departure, and the same delayed-departure rule
/// exercised through the live `LocationCallbackReplay` DSL.
@MainActor
struct DepartureMatchingTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

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
}
