import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// These tests deliberately write with the unversioned schema used by the current
/// on-device release, then reopen the same SQLite copy through the versioned plan.
/// Keep this fixture representative when the schema grows.
struct SchemaMigrationTests {
    @Test("Store recovery exports do not modify the original files")
    func exportsRecoveryCopyWithoutDeletingSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("LifeLog.store")
        try Data("fixture".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        let failure = StoreOpenError(
            error: NSError(domain: "SwiftData", code: 11), storeURL: storeURL
        )

        let copy = try StoreRecoverySupport.makeStoreCopy(from: storeURL, failure: failure)
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("LifeLog.store").path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("LifeLog.store-wal").path))
    }

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
        // Nothing recorded before V3 has a path to restore, so the new field must
        // arrive empty rather than as an empty-but-present route.
        #expect(visits[0].routeData == nil)
        #expect(visits[0].route.isEmpty)
        #expect(visits[0].hasRoute == false)
    }

    @Test("A V2 store gains routes without losing anything it already held")
    func migratesV2StoreAddingRoutes() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v2-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        // Written exactly as the shipped V2 build writes it.
        let v2Schema = Schema(versionedSchema: LifeLogSchemaV2.self)
        let v2Configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: v2Schema, url: storeURL,
            allowsSave: true, cloudKitDatabase: .none
        )
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let container = try ModelContainer(for: v2Schema, configurations: [v2Configuration])
            let context = ModelContext(container)
            let visit = LifeLogSchemaV2.Visit(
                arrival: arrival, latitude: -27.47, longitude: 153.03, placeName: "Home",
                inferredActivity: "At home", note: "V2 fixture", source: "automatic"
            )
            visit.departure = arrival.addingTimeInterval(3_600)
            visit.userActivity = "At home"
            visit.recognitionConfidence = "confirmed"
            visit.healthKitSampleIDs = [UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!]
            context.insert(visit)
            context.insert(LifeLogSchemaV2.SavedPlace(
                name: "Home", latitude: -27.47, longitude: 153.03, radius: 100,
                defaultActivity: "At home"
            ))
            try context.save()
        }

        let container = try openVersionedStore(at: storeURL)
        let context = ModelContext(container)
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(visits.count == 1)
        #expect(visits[0].placeName == "Home")
        #expect(visits[0].note == "V2 fixture")
        #expect(visits[0].departure == arrival.addingTimeInterval(3_600))
        #expect(visits[0].healthKitSampleIDs?.count == 1)
        #expect(visits[0].routeData == nil, "An existing visit has no path to restore")
        #expect(places.count == 1)
        #expect(places[0].radius == 100)

        // And the new field round-trips once something writes one.
        visits[0].route = [
            RoutePoint(latitude: -27.470, longitude: 153.030, time: arrival),
            RoutePoint(latitude: -27.471, longitude: 153.031, time: arrival.addingTimeInterval(60))
        ]
        try context.save()
        let reread = try context.fetch(FetchDescriptor<Visit>())
        #expect(reread[0].route.count == 2)
        #expect(reread[0].hasRoute)
        #expect(reread[0].routeDistance > 0)
    }

    @Test("A V1 store carrying place types migrates to V2 without losing visits or places")
    func migratesV1StoreDroppingPlaceType() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v1-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        // Seed with the frozen V1 shape, which still has placeCategory/category.
        let v1Schema = Schema(versionedSchema: LifeLogSchemaV1.self)
        let v1Configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: v1Schema, url: storeURL,
            allowsSave: true, cloudKitDatabase: .none
        )
        let v1Container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
        let v1Context = ModelContext(v1Container)
        v1Context.insert(LifeLogSchemaV1.Visit(
            arrival: arrival, latitude: -27.47, longitude: 153.03,
            placeName: "Gracemere Shopping World", placeCategory: "Shopping",
            inferredActivity: "Shopping", note: "V1 fixture", source: "automatic"
        ))
        v1Context.insert(LifeLogSchemaV1.SavedPlace(
            name: "Home", latitude: -27.47, longitude: 153.03,
            radius: 120, category: "Home", defaultActivity: "At home"
        ))
        try v1Context.save()

        // Reopen the same file through the plan; V2 has no place type at all.
        let migrated = try openVersionedStore(at: storeURL)
        let context = ModelContext(migrated)
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(visits.count == 1)
        #expect(visits.first?.placeName == "Gracemere Shopping World")
        #expect(visits.first?.inferredActivity == "Shopping")
        #expect(visits.first?.note == "V1 fixture")
        #expect(places.count == 1)
        #expect(places.first?.name == "Home")
        #expect(places.first?.radius == 120)
        #expect(places.first?.defaultActivity == "At home")
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
            placeName: "Home",
            inferredActivity: "At home", userActivity: "At home",
            note: "Current store fixture", source: "automatic",
            recognitionConfidence: "confirmed", candidateData: Data([1, 2, 3])
        ))
        context.insert(SavedPlace(
            name: "Home", latitude: -27.47, longitude: 153.03,
            defaultActivity: "At home"
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
        let schema = Schema(versionedSchema: LifeLogSchemaV3.self)
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
