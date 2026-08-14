import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// The explicit "Merge into another activity" feature: folding one catalogue
/// activity into another moves visits, Saved Places, and any already-staged
/// `activityDefinitionID`, then removes the source from the catalogue and
/// deactivates its durable record. This replaces the old rename-into-an-
/// existing-name trick, which the activity-identity migration made unsafe —
/// see `ActivityCatalog.mergeActivity`.
@MainActor
struct ActivityMergeTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Merging moves visit text, activityDefinitionID, and Saved Place, then removes the source")
    func mergeMovesEverythingAndRemovesSource() async throws {
        let context = try makeContext()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))

        let source = ActivityDefinition(name: "Doctor", category: "Healthcare", symbol: "cross.case.fill")
        let target = ActivityDefinition(name: "Seeing Doctor", category: "Healthcare", symbol: "stethoscope")

        // A visit matched by explicit label, one matched only by its inferred
        // label, and one already carrying the source's staged ID.
        let explicit = Visit(arrival: base, departure: base.addingTimeInterval(600),
                             latitude: 0, longitude: 0, placeName: "Clinic",
                             inferredActivity: "Visiting", userActivity: "Doctor")
        let inferredOnly = Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(4_200),
                                 latitude: 0, longitude: 0, placeName: "Clinic",
                                 inferredActivity: "Doctor", userActivity: nil)
        let idLinked = Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(7_800),
                             latitude: 0, longitude: 0, placeName: "Clinic",
                             inferredActivity: "Visiting", userActivity: "Doctor",
                             activityDefinitionID: source.id)
        let unrelated = Visit(arrival: base.addingTimeInterval(10_800), departure: base.addingTimeInterval(11_400),
                              latitude: 0, longitude: 0, placeName: "Home", inferredActivity: "At home")
        context.insert(explicit); context.insert(inferredOnly); context.insert(idLinked); context.insert(unrelated)

        let place = SavedPlace(name: "Clinic", latitude: 0, longitude: 0, defaultActivity: "Doctor")
        context.insert(place)
        try context.save()

        // `ActivityCatalog.withStorage` takes a synchronous closure, but merging
        // awaits a background actor — so the swap is done by hand here, with the
        // same restore-on-exit `withStorage` itself relies on.
        let previousStorage = ActivityCatalog.storage
        ActivityCatalog.storage = defaults
        defer { ActivityCatalog.storage = previousStorage }

        ActivityCatalog.save([source, target])
        _ = try ActivityIdentityMigration.adoptLegacyDefinitions(context: context, definitions: [source, target])

        let explicitID = explicit.stableID
        let inferredOnlyID = inferredOnly.stableID
        let idLinkedID = idLinked.stableID

        let moved = try await ActivityCatalog.mergeActivity(source, into: target, context: context)

        #expect(moved == 3, "the three visits touching the source label all move")

        // The merge actually runs on its own isolated `ModelContext` against the
        // same store, so the test's original objects stay stale in memory the
        // same way a different screen's would — verify through a fresh context,
        // the same as any other screen would see the change via a fresh `@Query`.
        let verify = ModelContext(context.container)
        func visit(_ id: UUID) throws -> Visit {
            try #require(try verify.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.stableID == id })).first)
        }
        #expect(try visit(explicitID).userActivity == "Seeing Doctor")
        #expect(try visit(inferredOnlyID).inferredActivity == "Seeing Doctor")
        #expect(try visit(idLinkedID).activityDefinitionID == target.id, "a staged ID must not dangle on the removed source")
        #expect(try visit(unrelated.stableID).activity == "At home", "an unrelated visit is untouched")

        let places = try verify.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.first?.defaultActivity == "Seeing Doctor")

        let catalogue = ActivityCatalog.load()
        #expect(!catalogue.contains { $0.id == source.id }, "the source entry is removed, not left as a duplicate")
        #expect(catalogue.contains { $0.id == target.id })
        let survivor = try #require(catalogue.first { $0.id == target.id })
        #expect(survivor.legacyNames.contains { $0.caseInsensitiveCompare("Doctor") == .orderedSame },
                "an old export or backup naming the source must still resolve to the survivor")

        let record = try #require(verify.fetch(
            FetchDescriptor<ActivityDefinitionRecord>(predicate: #Predicate { $0.stableID == source.id })
        ).first)
        #expect(!record.isActive, "the source's durable record is deactivated, not left active and orphaned")
    }

    @Test("Merging into itself is a no-op")
    func mergeIntoSelfDoesNothing() async throws {
        let context = try makeContext()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let activity = ActivityDefinition(name: "Doctor", category: "Healthcare", symbol: "cross.case.fill")

        let previousStorage = ActivityCatalog.storage
        ActivityCatalog.storage = defaults
        defer { ActivityCatalog.storage = previousStorage }

        ActivityCatalog.save([activity])
        let moved = try await ActivityCatalog.mergeActivity(activity, into: activity, context: context)
        #expect(moved == 0)
        #expect(ActivityCatalog.load().contains { $0.id == activity.id })
    }

    /// The bug that made merging silently do nothing the first time it was tried
    /// on a device: before anything ever calls `seed()`, `ActivityCatalog.load()`'s
    /// empty-storage fallback rebuilds the default catalogue fresh on every call,
    /// and `ActivityDefinition.init`'s default `id: UUID = UUID()` means each
    /// rebuild hands out different IDs for the same-named activity. Any code that
    /// captures an ID from one `load()` and looks it up in a later `load()` — the
    /// merge picker does exactly this — silently finds nothing. `seed()` (called
    /// once, unconditionally, from `RootView`'s launch `.task`) is what closes
    /// that window; this pins the postcondition so a future change can't reopen it.
    @Test("Seeding makes repeated load() calls agree on IDs")
    func seedingStabilizesLoadIDs() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let previousStorage = ActivityCatalog.storage
        ActivityCatalog.storage = defaults
        defer { ActivityCatalog.storage = previousStorage }

        ActivityCatalog.seed()
        let first = try #require(ActivityCatalog.load().first { $0.name == "Work" })
        let second = try #require(ActivityCatalog.load().first { $0.name == "Work" })
        #expect(first.id == second.id, "an ID captured from one load() must still resolve in the next")
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            ActivityDefinitionRecord.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
