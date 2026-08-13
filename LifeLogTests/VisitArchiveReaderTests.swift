import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct VisitArchiveReaderTests {
    @Test("Activity usage is cached by store generation and returns values, not models")
    func activityUsageCacheRespectsGeneration() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: .now, departure: .now.addingTimeInterval(60), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "Work", userActivity: "Work"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let first = try await reader.activityUsage(generation: 1)
        #expect(first["work"] == 1)

        context.insert(Visit(arrival: .now.addingTimeInterval(120), departure: .now.addingTimeInterval(180),
                             latitude: 0, longitude: 0, placeName: "Home", inferredActivity: "Work", userActivity: "Work"))
        try context.save()
        #expect(try await reader.activityUsage(generation: 1)["work"] == 1)
        #expect(try await reader.activityUsage(generation: 2)["work"] == 2)
    }

    @Test("Place detail uses Maps identity before its bounded legacy name fallback")
    func mapsIdentityWinsOverLegacyName() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(SavedPlace(name: "Cafe", latitude: 0, longitude: 0, mapsIdentifier: "maps-cafe"))
        context.insert(Visit(arrival: .now, departure: .now.addingTimeInterval(60), latitude: 0, longitude: 0,
                             placeName: "Renamed cafe", inferredActivity: "Coffee", mapsIdentifier: "maps-cafe"))
        context.insert(Visit(arrival: .now.addingTimeInterval(120), departure: .now.addingTimeInterval(180),
                             latitude: 0, longitude: 0, placeName: "Cafe", inferredActivity: "Coffee", mapsIdentifier: "maps-other"))
        try context.save()

        let entries = try await VisitArchiveReader(modelContainer: container).placeEntries(named: "Cafe")
        #expect(entries.count == 1)
        #expect(entries.first?.placeName == "Renamed cafe")
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
