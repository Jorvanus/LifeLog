import Foundation
import Testing
@testable import LifeLog

struct SavedPlaceRoleTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A Maps identifier match wins over coordinates")
    func identifierMatchWins() {
        let nearWork = SavedPlace(name: "Work", latitude: -23.42, longitude: 150.55, mapsIdentifier: "work-id")
        nearWork.homeWorkRole = .work
        // Same coordinates as `nearWork`, so a coordinate-only lookup would find it
        // too -- the identifier on the visit must be checked first regardless.
        let elsewhere = SavedPlace(name: "Elsewhere", latitude: 0, longitude: 0, mapsIdentifier: "elsewhere-id")
        elsewhere.homeWorkRole = .home
        let visit = Visit(arrival: base, latitude: -23.42, longitude: 150.55, placeName: "Work",
                          inferredActivity: "Working", source: "automatic", mapsIdentifier: "elsewhere-id")

        #expect(SavedPlaceRole.of(visit, in: [nearWork, elsewhere]) == .home)
    }

    @Test("Geofence-radius membership resolves a visit with no Maps identifier")
    func coordinateFallbackResolves() {
        let home = SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51, radius: 100)
        home.homeWorkRole = .home
        let visit = Visit(arrival: base, latitude: -23.3701, longitude: 150.5101,
                          placeName: "Home", inferredActivity: "At home", source: "automatic")

        #expect(SavedPlaceRole.of(visit, in: [home]) == .home)
    }

    @Test("No matching Saved Place, or one with no role, resolves to nil")
    func unmatchedOrUnroledResolvesToNil() {
        let farAway = SavedPlace(name: "Somewhere Else", latitude: -40, longitude: 170, radius: 100)
        farAway.homeWorkRole = .home
        let unroled = SavedPlace(name: "Corner Cafe", latitude: -23.37, longitude: 150.51, radius: 100)
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: "Corner Cafe", inferredActivity: "Eating", source: "automatic")

        #expect(SavedPlaceRole.of(visit, in: [farAway]) == nil)
        #expect(SavedPlaceRole.of(visit, in: [unroled]) == nil)
    }

    @Test("A movement visit with no coordinate never resolves a role")
    func placelessVisitResolvesToNil() {
        let home = SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51, radius: 100)
        home.homeWorkRole = .home
        let walk = Visit(arrival: base, latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")

        #expect(SavedPlaceRole.of(walk, in: [home]) == nil)
    }
}
