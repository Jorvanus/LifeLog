import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// The "Merge into another place" feature reachable from a place's Insights
/// drill-down: folding one place name into another moves every matching visit's
/// `placeName`, case-insensitively, and leaves Saved Places untouched -- see
/// `PlaceRenameActor`.
@MainActor
struct PlaceMergeTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Merging rewrites every matching visit's placeName, case-insensitively, and leaves unrelated visits alone")
    func mergeRewritesMatchingVisitsOnly() async throws {
        let context = try makeContext()

        let matching = Visit(arrival: base, departure: base.addingTimeInterval(600),
                             latitude: 0, longitude: 0, placeName: "3 Tanner Court, Gracemere",
                             inferredActivity: "At home")
        let differentCase = Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(4_200),
                                  latitude: 0, longitude: 0, placeName: "3 TANNER COURT, GRACEMERE",
                                  inferredActivity: "At home")
        let unrelated = Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(7_800),
                              latitude: 0, longitude: 0, placeName: "Regional Office", inferredActivity: "Work")
        let matchingID = matching.stableID
        let differentCaseID = differentCase.stableID
        let unrelatedID = unrelated.stableID
        context.insert(matching); context.insert(differentCase); context.insert(unrelated)

        let home = SavedPlace(name: "Home", latitude: -23.44, longitude: 150.45, defaultActivity: "At home")
        home.role = "home"
        context.insert(home)
        try context.save()

        let changed = try await PlaceRenameActor(modelContainer: context.container)
            .mergePlace(sourceNames: ["3 Tanner Court, Gracemere"], targetName: "Home")
        #expect(changed == 2)

        // The merge runs on its own isolated `ModelContext` against the same
        // store, so the test's original objects stay stale in memory the same
        // way a different screen's would -- verify through a fresh context.
        let verify = ModelContext(context.container)
        func visit(_ id: UUID) throws -> Visit {
            try #require(try verify.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.stableID == id })).first)
        }
        #expect(try visit(matchingID).placeName == "Home")
        #expect(try visit(differentCaseID).placeName == "Home")
        #expect(try visit(unrelatedID).placeName == "Regional Office")
        // Saved Places are never touched by a merge -- only the visit text.
        let places = try verify.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.first?.name == "Home")
    }

    @Test("Merging into a place with no matching visits changes nothing")
    func mergeWithNoMatchesChangesNothing() async throws {
        let context = try makeContext()
        let unrelated = Visit(arrival: base, departure: base.addingTimeInterval(600),
                              latitude: 0, longitude: 0, placeName: "Regional Office", inferredActivity: "Work")
        context.insert(unrelated)
        try context.save()

        let changed = try await PlaceRenameActor(modelContainer: context.container)
            .mergePlace(sourceNames: ["Imported journal"], targetName: "Home")
        #expect(changed == 0)
        #expect(unrelated.placeName == "Regional Office")
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
