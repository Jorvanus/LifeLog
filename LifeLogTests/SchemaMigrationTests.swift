import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// These tests deliberately write with the unversioned schema shipped immediately
/// before LifeLog adopted versioned schemas, then reopen the same SQLite copy through
/// the versioned plan. Keep this fixture representative when the schema grows.
// Historical schemas intentionally contain different model classes with the same
// entity names. SwiftData registers model metadata process-wide, so these fixture
// migrations must not be constructed concurrently by Swift Testing.
@Suite(.serialized)
@MainActor
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

    @Test("A V9 store gains optional activity identities without rewriting snapshots")
    func migratesV9StoreAddingActivityIdentity() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v9-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: LifeLogSchemaV9.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: schema, url: storeURL,
                                               allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(LifeLogSchemaV9.Visit(arrival: Date(timeIntervalSince1970: 1_800_000_000),
                                                  latitude: -23.4, longitude: 150.5,
                                                  placeName: "Cafe", inferredActivity: "Coffee",
                                                  note: "V9 snapshot", source: "automatic"))
            context.insert(LifeLogSchemaV9.SavedPlace(name: "Cafe", latitude: -23.4,
                                                       longitude: 150.5, radius: 80,
                                                       defaultActivity: "Coffee"))
            try context.save()
        }

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let visit = try context.fetch(FetchDescriptor<Visit>()).first
        let place = try context.fetch(FetchDescriptor<SavedPlace>()).first
        #expect(visit?.activity == "Coffee")
        #expect(visit?.activityDefinitionID == nil)
        #expect(place?.defaultActivity == "Coffee")
        #expect(place?.activityDefinitionID == nil)
        #expect(try context.fetch(FetchDescriptor<ActivityDefinitionRecord>()).isEmpty)
    }

    @Test("A V3 store gains Maps identity without losing its places")
    func migratesV3StoreAddingMapsIdentifier() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v3-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v3Schema = Schema(versionedSchema: LifeLogSchemaV3.self)
        let v3Configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: v3Schema, url: storeURL,
            allowsSave: true, cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: v3Schema, configurations: [v3Configuration])
            let context = ModelContext(container)
            let visit = LifeLogSchemaV3.Visit(
                arrival: arrival, latitude: -27.47, longitude: 153.03, placeName: "Corner Cafe",
                inferredActivity: "Eating", note: "V3 fixture", source: "automatic"
            )
            visit.departure = arrival.addingTimeInterval(1_800)
            visit.routeData = Data([9, 9])
            context.insert(visit)
            context.insert(LifeLogSchemaV3.SavedPlace(
                name: "Corner Cafe", latitude: -27.47, longitude: 153.03, radius: 85,
                defaultActivity: "Eating"
            ))
            try context.save()
        }

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let visits = try context.fetch(FetchDescriptor<Visit>())

        #expect(places.count == 1)
        #expect(places[0].name == "Corner Cafe")
        #expect(places[0].radius == 85)
        #expect(places[0].defaultActivity == "Eating")
        // A place saved before this existed has no Maps identity to restore.
        #expect(places[0].mapsIdentifier == nil)
        #expect(visits.count == 1)
        #expect(visits[0].note == "V3 fixture")
        #expect(visits[0].routeData == Data([9, 9]))

        places[0].mapsIdentifier = "I1234567890ABCDEF"
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SavedPlace>())[0].mapsIdentifier == "I1234567890ABCDEF")
    }

    @Test("A V4 store gains the location journal without losing anything it held")
    func migratesV4StoreAddingLocationJournal() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v4-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v4Schema = Schema(versionedSchema: LifeLogSchemaV4.self)
        let v4Configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: v4Schema, url: storeURL,
            allowsSave: true, cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: v4Schema, configurations: [v4Configuration])
            let context = ModelContext(container)
            let visit = LifeLogSchemaV4.Visit(
                arrival: arrival, latitude: -23.4455, longitude: 150.4522,
                placeName: "Home", inferredActivity: "At home",
                note: "V4 fixture", source: "automatic"
            )
            context.insert(visit)
            let place = LifeLogSchemaV4.SavedPlace(
                name: "Home", latitude: -23.4455, longitude: 150.4522,
                radius: 85, defaultActivity: "At home"
            )
            place.mapsIdentifier = "I1234567890ABCDEF"
            context.insert(place)
            try context.save()
        }

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        // Nothing gained or lost a property, so everything is carried over untouched.
        #expect(visits.count == 1)
        #expect(visits[0].note == "V4 fixture")
        #expect(places.count == 1)
        #expect(places[0].mapsIdentifier == "I1234567890ABCDEF")
        // The new table exists and is empty, which is the whole of this migration.
        #expect(try context.fetch(FetchDescriptor<LocationEvent>()).isEmpty)

        context.insert(LocationEvent(callbackType: "visit-arrival", callbackAt: arrival,
                                     arrival: arrival, latitude: -23.4455, longitude: 150.4522,
                                     accuracy: 12, transition: "created", visitArrival: arrival))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<LocationEvent>()).count == 1)
    }

    @Test("A V5 store gains Maps visit identity without losing anything it held")
    func migratesV5StoreAddingVisitIdentity() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v5-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v5Schema = Schema(versionedSchema: LifeLogSchemaV5.self)
        let v5Configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: v5Schema, url: storeURL,
            allowsSave: true, cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: v5Schema, configurations: [v5Configuration])
            let context = ModelContext(container)
            let visit = LifeLogSchemaV5.Visit(
                arrival: arrival, latitude: -23.4455, longitude: 150.4522,
                placeName: "Home", inferredActivity: "At home",
                note: "V5 fixture", source: "automatic"
            )
            context.insert(visit)
            let place = LifeLogSchemaV5.SavedPlace(
                name: "Home", latitude: -23.4455, longitude: 150.4522,
                radius: 85, defaultActivity: "At home"
            )
            place.mapsIdentifier = "I1234567890ABCDEF"
            context.insert(place)
            try context.save()
        }

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        // A visit recorded before V6 has no Maps identity of its own to restore --
        // it falls to the documented NameKey fallback until it is next resolved.
        #expect(visits.count == 1)
        #expect(visits[0].note == "V5 fixture")
        #expect(visits[0].mapsIdentifier == nil)
        #expect(visits[0].placeFieldProvenance == nil)
        #expect(places.count == 1)
        #expect(places[0].mapsIdentifier == "I1234567890ABCDEF")

        visits[0].mapsIdentifier = "I1234567890ABCDEF"
        visits[0].placeFieldProvenance = "maps"
        try context.save()
        let resaved = try context.fetch(FetchDescriptor<Visit>())
        #expect(resaved[0].mapsIdentifier == "I1234567890ABCDEF")
        #expect(resaved[0].placeFieldProvenance == "maps")
    }

    @Test("A V6 store gains an empty resolution explanation that then persists")
    func migratesV6StoreAddingResolutionExplanation() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v6-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v6Schema = Schema(versionedSchema: LifeLogSchemaV6.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: v6Schema,
                                               url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v6Schema, configurations: [configuration])
        let seed = ModelContext(container)
        seed.insert(LifeLogSchemaV6.Visit(arrival: arrival, latitude: -23.4455, longitude: 150.4522,
                                           placeName: "Home", inferredActivity: "At home",
                                           note: "V6 fixture", source: "automatic"))
        try seed.save()

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let visit = try #require(context.fetch(FetchDescriptor<Visit>()).first)
        #expect(visit.resolutionExplanation == nil)
        visit.locationResolutionExplanation = .mapsIdentifier
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Visit>()).first?.resolutionExplanation == "matched-maps-identifier")
    }

    @Test("A V7 store backfills the Home/Work role for exactly-named places, never a substring match")
    func migratesV7StoreAddingSavedPlaceRole() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v7-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let v7Schema = Schema(versionedSchema: LifeLogSchemaV7.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: v7Schema,
                                               url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v7Schema, configurations: [configuration])
        let seed = ModelContext(container)
        seed.insert(LifeLogSchemaV7.SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51,
                                               radius: 100, defaultActivity: "At home"))
        seed.insert(LifeLogSchemaV7.SavedPlace(name: "work", latitude: -23.42, longitude: 150.55,
                                               radius: 100, defaultActivity: "Working"))
        seed.insert(LifeLogSchemaV7.SavedPlace(name: "Gym", latitude: -23.44, longitude: 150.46,
                                               radius: 100, defaultActivity: "Exercising"))
        // Would have matched the old substring keyword test; must not be backfilled.
        seed.insert(LifeLogSchemaV7.SavedPlace(name: "Homemaker Centre", latitude: -23.40, longitude: 150.48,
                                               radius: 200, defaultActivity: "Shopping"))
        try seed.save()

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.count == 4)
        #expect(places.first { $0.name == "Home" }?.homeWorkRole == .home)
        // Case-insensitive exact match, and the name itself is never touched.
        #expect(places.first { $0.name == "work" }?.homeWorkRole == .work)
        #expect(places.first { $0.name == "work" }?.name == "work")
        #expect(places.first { $0.name == "Gym" }?.homeWorkRole == nil)
        #expect(places.first { $0.name == "Homemaker Centre" }?.homeWorkRole == nil)
    }

    @Test("A copy of the current V8 store gains a stable ID and a derived resolution state for every visit")
    func migratesV8StoreAddingResolutionState() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v8-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v8Schema = Schema(versionedSchema: LifeLogSchemaV8.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: v8Schema,
                                               url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: v8Schema, configurations: [configuration])
            let seed = ModelContext(container)
            // Still identifying: no place name and no confidence yet.
            let provisional = LifeLogSchemaV8.Visit(arrival: arrival, latitude: -23.37, longitude: 150.51,
                                                     placeName: "Identifying…", inferredActivity: "Visiting",
                                                     note: "provisional", source: "automatic")
            seed.insert(provisional)
            // Named and confident: an ordinary settled automatic stay.
            let resolved = LifeLogSchemaV8.Visit(arrival: arrival.addingTimeInterval(3_600), latitude: -23.37,
                                                  longitude: 150.51, placeName: "Home", inferredActivity: "At home",
                                                  note: "resolved", source: "automatic")
            resolved.recognitionConfidence = "learned"
            seed.insert(resolved)
            // A duplicate callback the pre-V9 resolver already folded away.
            let superseded = LifeLogSchemaV8.Visit(arrival: arrival.addingTimeInterval(3_660), latitude: -23.37,
                                                    longitude: 150.51, placeName: "Home", inferredActivity: "At home",
                                                    note: "superseded", source: "automatic-superseded")
            seed.insert(superseded)
            // A manual entry: never provisional regardless of place name, since only
            // an automatic stay waits on Core Location to identify itself.
            let manual = LifeLogSchemaV8.Visit(arrival: arrival.addingTimeInterval(7_200), latitude: -23.37,
                                                longitude: 150.51, placeName: "Corner Cafe",
                                                inferredActivity: "Eating", note: "manual", source: "manual")
            seed.insert(manual)
            try seed.save()
        }

        let context = ModelContext(try openVersionedStore(at: storeURL))
        let visits = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
        #expect(visits.count == 4)

        // Every visit gets its own stable ID -- not the single shared default the
        // structural step alone would have left every row with.
        let stableIDs = Set(visits.map(\.stableID))
        #expect(stableIDs.count == 4, "each visit must get a distinct stable ID, not one shared default")

        #expect(visits.first { $0.note == "provisional" }?.resolutionState == .provisional)
        #expect(visits.first { $0.note == "resolved" }?.resolutionState == .resolved)
        #expect(visits.first { $0.note == "superseded" }?.resolutionState == .superseded)
        #expect(visits.first { $0.note == "manual" }?.resolutionState == .resolved)
        // Nothing in a V8 store carried an ignore -- that only ever lived in
        // UserDefaults, matched separately by `VisitResolutionMigration`.
        #expect(visits.allSatisfy { $0.resolutionState != .ignored })
    }

    @Test("Reopening an already-migrated store leaves stable IDs and resolution state untouched")
    func migratingV9StoreTwiceIsIdempotent() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v8-relaunch-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v8Schema = Schema(versionedSchema: LifeLogSchemaV8.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: v8Schema,
                                               url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: v8Schema, configurations: [configuration])
            let seed = ModelContext(container)
            seed.insert(LifeLogSchemaV8.Visit(arrival: arrival, latitude: -23.37, longitude: 150.51,
                                              placeName: "Home", inferredActivity: "At home",
                                              note: "fixture", source: "automatic"))
            try seed.save()
        }

        // First "launch": migrates V8 -> V9 and backfills.
        let firstStableID: UUID
        let firstState: VisitResolutionState
        do {
            let context = ModelContext(try openVersionedStore(at: storeURL))
            let visit = try #require(context.fetch(FetchDescriptor<Visit>()).first)
            firstStableID = visit.stableID
            firstState = visit.resolutionState
            try ActivityLocationPolicy.runFullStoreAudit(context: context, reason: "test relaunch 1")
            try context.save()
        }

        // Second "launch" against the same file: the migration stage does not run
        // again (SwiftData tracks the store's own version), so this is exercising
        // that reopening and re-resolving is itself a no-op.
        do {
            let context = ModelContext(try openVersionedStore(at: storeURL))
            let visit = try #require(context.fetch(FetchDescriptor<Visit>()).first)
            #expect(visit.stableID == firstStableID)
            #expect(visit.resolutionState == firstState)
            let changed = try ActivityLocationPolicy.reconcileResolutionStates(context: context)
            #expect(changed == 0, "re-resolving an already-settled visit must not report a change")
        }
    }

    @Test("A visit ignored under the legacy UserDefaults registry stays ignored after migrating and converting")
    func convertsLegacyIgnoredVisitAcrossMigration() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-v8-ignored-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let v8Schema = Schema(versionedSchema: LifeLogSchemaV8.self)
        let configuration = ModelConfiguration("LifeLogMigrationFixture", schema: v8Schema,
                                               url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        var legacyKey = ""
        let untouchedArrival = arrival.addingTimeInterval(3_600)
        do {
            let container = try ModelContainer(for: v8Schema, configurations: [configuration])
            let seed = ModelContext(container)
            let ignored = LifeLogSchemaV8.Visit(arrival: arrival, latitude: -23.37, longitude: 150.51,
                                                placeName: "A misidentified drive-by", inferredActivity: "Visiting",
                                                note: "should stay ignored", source: "automatic")
            ignored.recognitionConfidence = "low"
            seed.insert(ignored)
            let kept = LifeLogSchemaV8.Visit(arrival: untouchedArrival, latitude: -23.42, longitude: 150.55,
                                             placeName: "Work", inferredActivity: "Working",
                                             note: "never ignored", source: "automatic")
            kept.recognitionConfidence = "learned"
            seed.insert(kept)
            try seed.save()
            // Written exactly as `IgnoredLocations.setIgnored(true, for:)` wrote it
            // before V9: a key built from this row's own `persistentModelID`.
            legacyKey = "persistent:\(String(describing: ignored.persistentModelID))"
        }
        IgnoredLocations.importKeys([legacyKey], defaults: defaults)

        let context = ModelContext(try openVersionedStore(at: storeURL))
        // Mirrors what `LifeLogApp.openContainer` does on a real launch: convert
        // before the resolver's own automation pass runs.
        let converted = try VisitResolutionMigration.convertLegacyIgnoredKeysIfNeeded(context: context, defaults: defaults)
        #expect(converted == 1)
        try ActivityLocationPolicy.runFullStoreAudit(context: context, reason: "test migration")
        try context.save()

        let visits = try context.fetch(FetchDescriptor<Visit>())
        let ignoredVisit = try #require(visits.first { $0.note == "should stay ignored" })
        let keptVisit = try #require(visits.first { $0.note == "never ignored" })
        #expect(ignoredVisit.isIgnored)
        #expect(ignoredVisit.resolutionState == .ignored)
        // The resolver's automatic pass, which runs immediately after conversion
        // in the same store open, must not have pulled it back to visible.
        #expect(!keptVisit.isIgnored)
        #expect(keptVisit.resolutionState == .resolved)
        #expect(IgnoredLocations.storedKeys(defaults: defaults).isEmpty, "the legacy registry is retired once converted")

        // A second "launch" against the same store and the same UserDefaults suite
        // must not re-scan or change anything -- the flag alone decides that.
        let secondConverted = try VisitResolutionMigration.convertLegacyIgnoredKeysIfNeeded(context: context, defaults: defaults)
        #expect(secondConverted == 0)
        #expect(try #require(context.fetch(FetchDescriptor<Visit>()).first { $0.note == "should stay ignored" }).isIgnored)
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
        // This is the exact unversioned model set used immediately before V1 was
        // introduced. Using today's live types here would create an unrecognisable
        // store and would not test the real upgrade path.
        let schema = Schema([
            LifeLogSchemaV1.Visit.self,
            LifeLogSchemaV1.SavedPlace.self,
            LifeLogSchemaV1.VisitCorrection.self,
            LifeLogSchemaV1.DiagnosticEvent.self
        ])
        let configuration = ModelConfiguration(
            "LifeLogMigrationFixture", schema: schema, url: url,
            allowsSave: true, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let visit = LifeLogSchemaV1.Visit(
            arrival: arrival,
            latitude: -27.47, longitude: 153.03,
            placeName: "Home",
            placeCategory: "Home", inferredActivity: "At home",
            note: "Current store fixture", source: "automatic"
        )
        visit.departure = arrival.addingTimeInterval(3600)
        visit.userActivity = "At home"
        visit.recognitionConfidence = "confirmed"
        visit.candidateData = Data([1, 2, 3])
        context.insert(visit)
        context.insert(LifeLogSchemaV1.SavedPlace(
            name: "Home", latitude: -27.47, longitude: 153.03,
            radius: 100, category: "Home", defaultActivity: "At home"
        ))
        context.insert(LifeLogSchemaV1.VisitCorrection(
            changedAt: arrival.addingTimeInterval(60), visitArrival: arrival,
            latitude: -27.47, longitude: 153.03,
            previousPlaceName: "Unknown", newPlaceName: "Home",
            previousActivity: "Visiting", newActivity: "At home",
            previousConfidence: "pending", newConfidence: "confirmed",
            reason: "Migration test"
        ))
        context.insert(LifeLogSchemaV1.DiagnosticEvent(
            createdAt: arrival, subsystem: "Migration test", severity: "info", message: "Fixture"
        ))
        try context.save()
    }

    /// Opens at the newest version, so every fixture in this file is carried all the
    /// way to what the app actually ships. Left at V5 while the app moved to V6, these
    /// tests would keep passing without once exercising the new stage.
    private func openVersionedStore(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LifeLogSchemaV11.self)
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
