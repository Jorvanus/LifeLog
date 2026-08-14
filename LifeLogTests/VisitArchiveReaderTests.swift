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

/// The explicit archive search screen: place/activity matching, the notes
/// opt-in, paging, and — separately — whether a 32,000-row archive needs a
/// persisted index to stay fast. It does not: `localizedStandardContains`
/// compiles to `LIKE '%text%'`, which cannot use a btree index regardless of
/// what's indexed (a leading wildcard defeats a range scan), so the bound that
/// actually matters is `fetchLimit`, which every query here already has.
@MainActor
struct VisitArchiveSearchTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Search matches place name and either activity field, case-insensitively")
    func searchMatchesPlaceAndActivity() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Riverside Café", inferredActivity: "Visiting", userActivity: "Coffee"))
        context.insert(Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(4_200),
                             latitude: 0, longitude: 0, placeName: "Office", inferredActivity: "Working"))
        context.insert(Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(7_800),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let byPlace = try await reader.search("riverside", includeNotes: false, limit: 50, offset: 0)
        #expect(byPlace.entries.map(\.placeName) == ["Riverside Café"])

        let byUserActivity = try await reader.search("coffee", includeNotes: false, limit: 50, offset: 0)
        #expect(byUserActivity.entries.map(\.placeName) == ["Riverside Café"])

        let byInferredActivity = try await reader.search("working", includeNotes: false, limit: 50, offset: 0)
        #expect(byInferredActivity.entries.map(\.placeName) == ["Office"])
    }

    @Test("Notes are excluded unless the person opts in")
    func notesAreOptIn() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "At home",
                             note: "Left the spare key with the neighbour"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let withoutNotes = try await reader.search("spare key", includeNotes: false, limit: 50, offset: 0)
        #expect(withoutNotes.entries.isEmpty, "note text must not match unless explicitly opted into")

        let withNotes = try await reader.search("spare key", includeNotes: true, limit: 50, offset: 0)
        #expect(withNotes.entries.map(\.placeName) == ["Home"])
    }

    @Test("Paging reports whether another page exists without over-fetching")
    func pagingReportsHasMore() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<25 {
            context.insert(Visit(arrival: base.addingTimeInterval(Double(index) * 3_600),
                                 departure: base.addingTimeInterval(Double(index) * 3_600 + 600),
                                 latitude: 0, longitude: 0, placeName: "Landmark \(index)",
                                 inferredActivity: "Visiting"))
        }
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let firstPage = try await reader.search("landmark", includeNotes: false, limit: 10, offset: 0)
        #expect(firstPage.entries.count == 10)
        #expect(firstPage.hasMore)

        let thirdPage = try await reader.search("landmark", includeNotes: false, limit: 10, offset: 20)
        #expect(thirdPage.entries.count == 5)
        #expect(!thirdPage.hasMore)
    }

    @Test("Blank query returns nothing rather than the whole archive")
    func blankQueryReturnsNothing() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "At home"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let result = try await reader.search("   ", includeNotes: false, limit: 50, offset: 0)
        #expect(result.entries.isEmpty)
        #expect(!result.hasMore)
    }

    @Test("A page of search stays within budget against a 32,000-row archive, with or without notes")
    func searchBudgetOnLargeArchive() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<32_000 {
            let arrival = base.addingTimeInterval(Double(index) * 1_800)
            context.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                                 latitude: -27.47, longitude: 153.03,
                                 placeName: index.isMultiple(of: 2) ? "Home" : "Riverside Café",
                                 inferredActivity: index.isMultiple(of: 2) ? "At home" : "Coffee",
                                 note: "Ordinary day, nothing notable about visit \(index).",
                                 source: "automatic"))
        }
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)

        let startedAtPlaceAndActivity = Date.now
        let placeAndActivity = try await reader.search("riverside", includeNotes: false,
                                                        limit: VisitArchiveSearchTests.pageSize, offset: 0)
        let elapsedPlaceAndActivity = Date.now.timeIntervalSince(startedAtPlaceAndActivity)
        #expect(elapsedPlaceAndActivity < Diagnostics.PerformanceBudget.archiveSearch,
                "Place/activity search took \(elapsedPlaceAndActivity)s for the 32,000-row fixture")
        #expect(placeAndActivity.entries.count == VisitArchiveSearchTests.pageSize)

        let startedAtWithNotes = Date.now
        let withNotes = try await reader.search("visit 31999", includeNotes: true,
                                                 limit: VisitArchiveSearchTests.pageSize, offset: 0)
        let elapsedWithNotes = Date.now.timeIntervalSince(startedAtWithNotes)
        #expect(elapsedWithNotes < Diagnostics.PerformanceBudget.archiveSearch,
                "Note-inclusive search took \(elapsedWithNotes)s for the 32,000-row fixture")
        #expect(withNotes.entries.count == 1)
    }

    private static let pageSize = 100

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
