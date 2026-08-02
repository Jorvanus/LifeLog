import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// These tests deliberately write with the unversioned schema used by the current
/// on-device release, then reopen the same SQLite copy through the versioned plan.
/// Keep this fixture representative when the schema grows.
struct SchemaMigrationTests {
    @Test("A current store opens through V1 without data loss")
    func opensCurrentStoreThroughVersionedPlan() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-schema-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try seedCurrentStore(at: storeURL)
        let container = try openVersionedStore(at: storeURL)
        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        let diagnostics = try context.fetch(FetchDescriptor<DiagnosticEvent>())

        #expect(visits.count == 1)
        #expect(visits[0].placeName == "Home")
        #expect(visits[0].note == "Current store fixture")
        #expect(visits[0].candidateData == Data([1, 2, 3]))
        #expect(places.count == 1)
        #expect(places[0].name == "Home")
        #expect(corrections.count == 1)
        #expect(corrections[0].newActivity == "At home")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].subsystem == "Migration test")
    }

    private func seedCurrentStore(at url: URL) throws {
        let schema = Schema([Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self])
        let configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: schema, url: url,
            allowsSave: true, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(Visit(
            arrival: arrival, departure: arrival.addingTimeInterval(3600),
            latitude: -27.47, longitude: 153.03,
            placeName: "Home", placeCategory: "Home",
            inferredActivity: "At home", userActivity: "At home",
            note: "Current store fixture", source: "automatic",
            recognitionConfidence: "confirmed", candidateData: Data([1, 2, 3])
        ))
        context.insert(SavedPlace(
            name: "Home", latitude: -27.47, longitude: 153.03,
            category: "Home", defaultActivity: "At home"
        ))
        context.insert(VisitCorrection(
            visitArrival: arrival, latitude: -27.47, longitude: 153.03,
            previousPlaceName: "Unknown", newPlaceName: "Home",
            previousActivity: "Visiting", newActivity: "At home"
        ))
        context.insert(DiagnosticEvent(subsystem: "Migration test", message: "Fixture"))
        try context.save()
    }

    private func openVersionedStore(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LifeLogSchemaV1.self)
        let configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: schema, url: url,
            allowsSave: true, cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: LifeLogMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
