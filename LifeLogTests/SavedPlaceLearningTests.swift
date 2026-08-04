import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct SavedPlaceLearningTests {
    @Test("A corrected located visit creates a reusable geofence")
    func createsSavedPlace() throws {
        let context = try makeContext()
        let visit = Visit(
            arrival: .now,
            departure: .now.addingTimeInterval(1_800),
            latitude: -27.4698,
            longitude: 153.0251,
            placeName: "Corner Café",
            inferredActivity: "Visiting",
            userActivity: "Eating"
        )
        context.insert(visit)

        let result = try SavedPlaceLearning.upsert(
            from: visit,
            previousPlaceName: "Unknown place",
            context: context
        )
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(result?.change == .created)
        #expect(places.count == 1)
        #expect(places.first?.name == "Corner Café")
        #expect(places.first?.radius == 100)
        #expect(places.first?.defaultActivity == "Eating")
        #expect(visit.recognitionConfidence == "learned")
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        #expect(corrections.count == 1)
        #expect(corrections.first?.newPlaceName == "Corner Café")
        #expect(corrections.first?.newConfidence == "learned")
    }

    @Test("Renaming a visit updates the matching geofence without duplicating it")
    func updatesExistingSavedPlace() throws {
        let context = try makeContext()
        let saved = SavedPlace(
            name: "Old Office",
            latitude: -27.4698,
            longitude: 153.0251,
            radius: 90,
            defaultActivity: "Working"
        )
        context.insert(saved)
        try context.save()

        let visit = Visit(
            arrival: .now,
            latitude: -27.4697,
            longitude: 153.0252,
            placeName: "Design Studio",
            inferredActivity: "Working",
            userActivity: "Collaborating"
        )
        context.insert(visit)

        let result = try SavedPlaceLearning.upsert(
            from: visit,
            previousPlaceName: "Old Office",
            context: context
        )
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(result?.change == .updated)
        #expect(places.count == 1)
        #expect(places.first?.name == "Design Studio")
        #expect(places.first?.radius == 100)
        #expect(places.first?.defaultActivity == "Collaborating")
    }

    @Test("Editing a saved place updates matching location history")
    func appliesSavedPlaceToHistory() throws {
        let context = try makeContext()
        let saved = SavedPlace(
            name: "Home",
            latitude: -27.4698,
            longitude: 153.0251,
            radius: 125,
            defaultActivity: "At home"
        )
        let current = Visit(
            arrival: .now,
            latitude: -27.4697,
            longitude: 153.0252,
            placeName: "Unknown place",
            inferredActivity: "Visiting",
            source: "automatic"
        )
        let distant = Visit(
            arrival: .now.addingTimeInterval(-3_600),
            departure: .now.addingTimeInterval(-1_800),
            latitude: -27.5,
            longitude: 153.1,
            placeName: "Another place",
            inferredActivity: "Visiting",
            source: "automatic"
        )
        context.insert(saved)
        context.insert(current)
        context.insert(distant)

        try SavedPlaceLearning.apply(saved, context: context)
        try context.save()

        #expect(current.placeName == "Home")
        #expect(current.activity == "At home")
        #expect(current.needsCategorisation == false)
        #expect(distant.placeName == "Another place")
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        #expect(corrections.count == 1)
        #expect(corrections.first?.reason == "Saved Place learned")
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
