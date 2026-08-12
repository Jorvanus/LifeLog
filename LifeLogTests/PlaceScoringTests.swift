import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct PlaceScoringTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    @Test("An approximate fix loses its Apple Maps distance credit")
    func approximateFixLosesDistanceCredit() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -27.4698, longitude: 153.0251, source: "automatic")
        context.insert(visit)
        let nearby = PlaceSuggestion(name: "Corner Cafe", latitude: -27.4698, longitude: 153.0251,
                                     suggestedActivity: "Eating", distance: 10)

        let accurate = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [], suggestions: [nearby], accuracy: 10,
            geofenceTriggered: false, visits: [], corrections: []
        )
        let approximate = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [], suggestions: [nearby], accuracy: 500,
            geofenceTriggered: false, visits: [], corrections: []
        )

        #expect(accurate.breakdown.poiDistance > 0)
        #expect(approximate.breakdown.poiDistance == 0)
    }

    @Test("An approximate fix cannot claim geofence credit by raw coordinate distance")
    func approximateFixLosesGeofenceDistanceCredit() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -27.4698, longitude: 153.0251, source: "automatic")
        context.insert(visit)
        let place = SavedPlace(name: "Home", latitude: -27.4698, longitude: 153.0251, radius: 100)
        let suggestion = PlaceSuggestion(name: "Home", latitude: -27.4698, longitude: 153.0251,
                                         suggestedActivity: "At home", distance: 5)

        let accurate = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [place], suggestions: [suggestion], accuracy: 10,
            geofenceTriggered: false, visits: [], corrections: []
        )
        let approximate = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [place], suggestions: [suggestion], accuracy: 500,
            geofenceTriggered: false, visits: [], corrections: []
        )

        #expect(accurate.breakdown.savedPlaceGeofence == 35)
        #expect(approximate.breakdown.savedPlaceGeofence == 0)
    }

    @Test("A real geofence-entry event keeps full credit even on an approximate fix")
    func triggeredGeofenceSurvivesApproximateFix() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -27.4698, longitude: 153.0251, source: "automatic")
        context.insert(visit)
        let place = SavedPlace(name: "Home", latitude: -27.4698, longitude: 153.0251, radius: 100)
        let suggestion = PlaceSuggestion(name: "Home", latitude: -27.4698, longitude: 153.0251,
                                         suggestedActivity: "At home", distance: 5)

        let approximate = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [place], suggestions: [suggestion], accuracy: 500,
            geofenceTriggered: true, visits: [], corrections: []
        )

        #expect(approximate.breakdown.savedPlaceGeofence == 35)
    }
}
