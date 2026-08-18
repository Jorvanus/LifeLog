import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct ActivityLinkingCatchUpTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Isolates `ActivityCatalog`'s storage for the whole async `body`, not just a
    /// synchronous scope. `ActivityCatalog.withStorage` cannot wrap an `await`, and
    /// `ActivityLinkingCatchUp.run()` calls `adoptLegacyDefinitions` with its
    /// default `ActivityCatalog.load()` argument — a fresh suite with nothing saved
    /// yet falls back to the app's real built-in defaults, which already contain
    /// their own "Walking" and "Work". Without this, a test's own hand-created
    /// definition of either name collides with the auto-adopted one and makes the
    /// name ambiguous, silently blocking every link this test expects to see.
    private func withIsolatedCatalog<T>(seeding seed: [ActivityDefinition] = [],
                                        _ body: () async throws -> T) async throws -> T {
        let defaultsSuite = "ActivityLinkingCatchUp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let previousStorage = ActivityCatalog.storage
        ActivityCatalog.storage = defaults
        defer { ActivityCatalog.storage = previousStorage }
        if !seed.isEmpty { ActivityCatalog.save(seed) }
        return try await body()
    }

    @Test("Runs once and links every existing unlinked visit")
    func linksEverythingOnFirstRun() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(ActivityDefinitionRecord(stableID: UUID(), name: "Walking",
                                                 category: "Fitness", symbol: "figure.walk"))
        for index in 0..<40 {
            context.insert(Visit(arrival: start.addingTimeInterval(Double(index) * 3600),
                                 departure: start.addingTimeInterval(Double(index) * 3600 + 900),
                                 latitude: 0, longitude: 0, placeName: "Imported journal",
                                 inferredActivity: "Walking", source: "imported-journal"))
        }
        try context.save()

        // Seeded with an unrelated name so `adoptLegacyDefinitions` has something
        // harmless to adopt instead of falling back to the built-in "Walking".
        let linked = try await withIsolatedCatalog(
            seeding: [ActivityDefinition(name: "Unrelated", category: "Other", symbol: "circle.fill")]
        ) {
            let defaultsSuite = "ActivityLinkingCatchUp.flag.\(UUID().uuidString)"
            let flagDefaults = UserDefaults(suiteName: defaultsSuite)!
            defer { flagDefaults.removePersistentDomain(forName: defaultsSuite) }
            return try await ActivityLinkingCatchUp.runIfNeeded(modelContainer: container, defaults: flagDefaults)
        }

        #expect(linked == 40)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        ))
        #expect(remaining.isEmpty)
    }

    @Test("Adopts legacy definitions itself, so it works even before any launch migration has run")
    func adoptsLegacyDefinitionsBeforeLinking() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: start, departure: start.addingTimeInterval(3600),
                             latitude: 0, longitude: 0, placeName: "Imported journal",
                             inferredActivity: "Work", source: "imported-journal"))
        try context.save()
        let workDefinition = ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")

        // Deliberately no prior call to `adoptLegacyDefinitions` or
        // `backfillNextBatch` — the catch-up must not depend on either having
        // already run this session.
        let linked = try await withIsolatedCatalog(seeding: [workDefinition]) {
            let defaultsSuite = "ActivityLinkingCatchUp.flag.\(UUID().uuidString)"
            let flagDefaults = UserDefaults(suiteName: defaultsSuite)!
            defer { flagDefaults.removePersistentDomain(forName: defaultsSuite) }
            return try await ActivityLinkingCatchUp.runIfNeeded(modelContainer: container, defaults: flagDefaults)
        }

        #expect(linked == 1)
        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(visits.first?.activityDefinitionID == workDefinition.id)
    }

    @Test("Never runs a second time, even if new unlinked visits appear afterwards")
    func onlyEverRunsOnce() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(ActivityDefinitionRecord(stableID: UUID(), name: "Work",
                                                 category: "Work", symbol: "briefcase.fill"))
        try context.save()
        let defaultsSuite = "ActivityLinkingCatchUp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        try await withIsolatedCatalog(
            seeding: [ActivityDefinition(name: "Unrelated", category: "Other", symbol: "circle.fill")]
        ) {
            let firstRun = try await ActivityLinkingCatchUp.runIfNeeded(modelContainer: container, defaults: defaults)
            #expect(firstRun == 0, "nothing to link yet, but the flag must still be set")

            // A visit that shows up only after the one-time catch-up already ran.
            context.insert(Visit(arrival: start, departure: start.addingTimeInterval(3600),
                                 latitude: 0, longitude: 0, placeName: "Regional Office",
                                 inferredActivity: "Work", source: "automatic"))
            try context.save()

            let secondRun = try await ActivityLinkingCatchUp.runIfNeeded(modelContainer: container, defaults: defaults)
            #expect(secondRun == 0, "the flag must prevent a second pass — the ongoing per-launch backfill owns this now")
        }

        let stillUnlinked = try ModelContext(container).fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        ))
        #expect(stillUnlinked.count == 1)
    }

    @Test("Restored archive linking handles the 32,000-row fixture even after an earlier archive set the flag")
    func restoredArchiveRelinksLargeHistory() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let definition = ActivityDefinitionRecord(stableID: UUID(), name: "At home",
                                                  category: "Home", symbol: "house.fill")
        context.insert(definition)
        for index in 0..<32_000 {
            let arrival = start.addingTimeInterval(Double(index) * 1_800)
            context.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                                 latitude: -23.38, longitude: 150.51, placeName: "Home",
                                 inferredActivity: "At home", source: "imported-journal"))
        }
        try context.save()

        try await withIsolatedCatalog(
            seeding: [ActivityDefinition(name: "Unrelated", category: "Other", symbol: "circle.fill")]
        ) {
            let defaultsSuite = "ActivityLinkingCatchUp.restore.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsSuite)!
            defer { defaults.removePersistentDomain(forName: defaultsSuite) }
            defaults.set(true, forKey: "LifeLog.ActivityIdentityMigration.linkedAllAtOnce.v1")
            let linked = try await ActivityLinkingCatchUp.runAfterRestore(modelContainer: container, defaults: defaults)
            #expect(linked == 32_000)
        }

        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        ))
        #expect(remaining.isEmpty)
    }
}
