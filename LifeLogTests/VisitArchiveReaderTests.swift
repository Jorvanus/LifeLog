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

    @Test("Timeline preview is a recent slice of Locations' complete review queue")
    func reviewQueueScopesAgree() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previewStart = now.addingTimeInterval(-7 * 86_400)
        let oldCafe = Visit(arrival: previewStart.addingTimeInterval(-86_400),
                            departure: previewStart.addingTimeInterval(-86_100),
                            latitude: 0, longitude: 0, placeName: "Cafe",
                            inferredActivity: "Visiting", source: "automatic",
                            resolutionState: .resolved)
        let recentCafe = Visit(arrival: previewStart.addingTimeInterval(3_600),
                               departure: previewStart.addingTimeInterval(3_900),
                               latitude: 0, longitude: 0, placeName: "Cafe",
                               inferredActivity: "Visiting", source: "automatic",
                               resolutionState: .resolved)
        let recentUnknown = Visit(arrival: previewStart.addingTimeInterval(7_200),
                                  departure: previewStart.addingTimeInterval(8_200),
                                  latitude: 1, longitude: 1,
                                  inferredActivity: "Visiting", source: "automatic",
                                  resolutionState: .provisional)
        [oldCafe, recentCafe, recentUnknown].forEach(context.insert)
        try context.save()

        let complete = try await VisitArchiveReader(modelContainer: container)
            .completeReviewQueue(generation: 1, now: now).result
        let preview = complete.recentClosedPreview(since: previewStart)
        let expected = complete.rows.filter { $0.departure != nil && $0.arrival >= previewStart }

        #expect(preview.rows == expected)
        #expect(preview.count == expected.count)
        #expect(preview.rows.map(\.stableID) == [recentUnknown.stableID])
        #expect(!preview.rows.contains { $0.stableID == recentCafe.stableID },
                "the older Cafe return must keep the recent Cafe out of both queue scopes")
    }

    @Test("Complete review queue cache advances only with store generation")
    func reviewQueueCacheRespectsGeneration() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(Visit(arrival: now.addingTimeInterval(-7_200),
                             departure: now.addingTimeInterval(-6_200),
                             latitude: 0, longitude: 0, source: "automatic"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        #expect(try await reader.completeReviewQueue(generation: 1, now: now).result.count == 1)

        context.insert(Visit(arrival: now.addingTimeInterval(-3_600),
                             departure: now.addingTimeInterval(-2_600),
                             latitude: 1, longitude: 1, source: "automatic"))
        try context.save()
        #expect(try await reader.completeReviewQueue(generation: 1, now: now).result.count == 1)
        #expect(try await reader.completeReviewQueue(generation: 2, now: now).result.count == 2)
    }

    @Test("Complete review queue stays within budget against a 32,000-row archive")
    func reviewQueueBudgetOnLargeArchive() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<32_000 {
            let arrival = now.addingTimeInterval(Double(index - 32_000) * 1_800)
            context.insert(Visit(arrival: arrival,
                                 departure: arrival.addingTimeInterval(1_200),
                                 latitude: -27.47, longitude: 153.03,
                                 placeName: "Place \(index % 500)",
                                 inferredActivity: "Visiting", source: "automatic",
                                 recognitionConfidence: "low",
                                 resolutionState: .provisional))
        }
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let startedAt = Date.now
        let prepared = try await reader.completeReviewQueue(generation: 1, now: now)
        let elapsed = Date.now.timeIntervalSince(startedAt)

        #expect(prepared.itemCount == 32_000)
        #expect(prepared.result.count == 32_000)
        #expect(elapsed < Diagnostics.PerformanceBudget.reviewQueuePreparation,
                "completeReviewQueue took \(elapsed)s for the 32,000-row fixture")
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

/// `DiagnosticsView` and `LocationResolutionChoicesView` used to keep two
/// whole-model `@Query`s (every `automatic` and `automatic-superseded` visit)
/// alive on the main actor just to count or filter them in Swift.
/// `diagnosticsSummary` replaces both with one bounded background read; these
/// tests confirm its four counts against a hand-built mix of visits, that its
/// cache respects generation the same way `completeReviewQueue`'s does, and
/// that it stays within budget on a large archive.
@MainActor
struct DiagnosticsSummaryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func scoreBreakdown(accuracyMeters: Int) -> PlaceScoreBreakdown {
        PlaceScoreBreakdown(recordedAt: base, total: 50, savedPlaceGeofence: 20, poiDistance: 10,
                            poiCategory: 5, dwellDuration: 5, horizontalAccuracy: 5, recurrence: 3,
                            timeOfDay: 1, priorCorrections: 1, selectedPlaceName: "Cafe",
                            mapsIdentifier: "cafe-id", accuracyMeters: accuracyMeters)
    }

    @Test("Each count reflects only the visits that actually meet its definition")
    func summaryCountsMatchDefinitions() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Needs review: automatic, placeholder name, no activity chosen.
        let needsReview = Visit(arrival: base, departure: base.addingTimeInterval(600),
                                latitude: 0, longitude: 0, placeName: Visit.identifyingPlaceName,
                                inferredActivity: "Visiting", source: "automatic")
        // Does not need review: automatic, but a real place and activity.
        let resolved = Visit(arrival: base.addingTimeInterval(1_200), departure: base.addingTimeInterval(1_800),
                             latitude: 0, longitude: 0, placeName: "Cafe",
                             inferredActivity: "Visiting", userActivity: "Coffee", source: "automatic")
        // Approximate accuracy, otherwise unremarkable.
        let approximate = Visit(arrival: base.addingTimeInterval(2_400), departure: base.addingTimeInterval(3_000),
                                latitude: 0, longitude: 0, placeName: "Cafe",
                                inferredActivity: "Visiting", userActivity: "Coffee", source: "automatic")
        approximate.placeScoreBreakdown = scoreBreakdown(accuracyMeters: 500)
        // Automatic with a recorded resolution candidate -- inspectable.
        let candidateVisit = Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(4_200),
                                   latitude: 0, longitude: 0, placeName: "Cafe",
                                   inferredActivity: "Visiting", userActivity: "Coffee", source: "automatic")
        candidateVisit.locationResolutionCandidates = LocationResolutionCandidates(
            chosen: PlaceSuggestion(name: "Cafe", latitude: 0, longitude: 0,
                                    suggestedActivity: "Coffee", distance: 12), rejected: [])
        // Superseded with a recorded explanation -- inspectable and counted as superseded.
        let supersededWithExplanation = Visit(arrival: base.addingTimeInterval(4_800), departure: base.addingTimeInterval(5_400),
                                              latitude: 0, longitude: 0, placeName: "Cafe",
                                              inferredActivity: "Visiting", source: "automatic-superseded")
        supersededWithExplanation.locationResolutionExplanation = .duplicate
        // Superseded with no payload -- counted as superseded only.
        let supersededBare = Visit(arrival: base.addingTimeInterval(6_000), departure: base.addingTimeInterval(6_600),
                                   latitude: 0, longitude: 0, placeName: "Cafe",
                                   inferredActivity: "Visiting", source: "automatic-superseded")
        // A manual visit, otherwise identical to `needsReview` -- excluded from everything.
        let manual = Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(7_800),
                           latitude: 0, longitude: 0, placeName: Visit.identifyingPlaceName,
                           inferredActivity: "Visiting", source: "manual")

        [needsReview, resolved, approximate, candidateVisit, supersededWithExplanation, supersededBare, manual]
            .forEach(context.insert)
        try context.save()

        let summary = try await VisitArchiveReader(modelContainer: container).diagnosticsSummary(generation: 1)
        #expect(summary.provisionalCount == 1, "only the placeholder-name, no-activity automatic visit")
        #expect(summary.approximateVisitCount == 1, "only the visit scored with a fuzzy fix")
        #expect(summary.supersededCount == 2, "both automatic-superseded visits, regardless of payload")
        #expect(summary.resolutionInspectableCount == 2, "the candidate visit plus the explained superseded visit")
    }

    @Test("Diagnostics summary cache advances only with store generation")
    func summaryCacheRespectsGeneration() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600),
                             latitude: 0, longitude: 0, placeName: "Cafe",
                             inferredActivity: "Visiting", userActivity: "Coffee",
                             source: "automatic-superseded"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        #expect(try await reader.diagnosticsSummary(generation: 1).supersededCount == 1)

        context.insert(Visit(arrival: base.addingTimeInterval(1_200), departure: base.addingTimeInterval(1_800),
                             latitude: 0, longitude: 0, placeName: "Cafe",
                             inferredActivity: "Visiting", userActivity: "Coffee",
                             source: "automatic-superseded"))
        try context.save()
        #expect(try await reader.diagnosticsSummary(generation: 1).supersededCount == 1,
                "same generation must answer from the cache")
        #expect(try await reader.diagnosticsSummary(generation: 2).supersededCount == 2,
                "a new generation must force a fresh read")
    }

    @Test("Diagnostics summary stays within budget against a 32,000-row archive")
    func summaryBudgetOnLargeArchive() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<32_000 {
            let arrival = base.addingTimeInterval(Double(index) * 900)
            let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(600),
                              latitude: -27.47, longitude: 153.03,
                              placeName: index.isMultiple(of: 3) ? Visit.identifyingPlaceName : "Place \(index % 200)",
                              inferredActivity: "Visiting",
                              userActivity: index.isMultiple(of: 3) ? nil : "Visiting",
                              source: index.isMultiple(of: 5) ? "automatic-superseded" : "automatic")
            if index.isMultiple(of: 7) { visit.placeScoreBreakdown = scoreBreakdown(accuracyMeters: 500) }
            context.insert(visit)
        }
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let startedAt = Date.now
        let summary = try await reader.diagnosticsSummary(generation: 1)
        let elapsed = Date.now.timeIntervalSince(startedAt)

        #expect(elapsed < Diagnostics.PerformanceBudget.diagnosticsSummary,
                "diagnosticsSummary took \(elapsed)s for the 32,000-row fixture")
        #expect(summary.provisionalCount > 0)
        #expect(summary.approximateVisitCount > 0)
        #expect(summary.supersededCount > 0)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

/// Insights' three retrospectives that used to read the whole archive
/// synchronously on the main actor (`placeHistory(matching:)`,
/// `annualHistoricalPlaces()`, `yearOverYearHighlight()`): correctness of the
/// narrowed queries this actor now runs instead, and — for the one that is
/// genuinely archive-wide by nature — whether it needs a persisted index.
@MainActor
struct InsightsArchiveReaderTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("placeOccurrences matches by name identity, scoped and bounded to before the cutoff")
    func placeOccurrencesMatchesScopedAndBounded() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Exact match, before the cutoff.
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Café", inferredActivity: "Coffee"))
        // Same identity once diacritics/case fold, still before the cutoff.
        context.insert(Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(4_200),
                             latitude: 0, longitude: 0, placeName: "cafe", inferredActivity: "Coffee"))
        // On/after the cutoff -- excluded regardless of name.
        let cutoff = base.addingTimeInterval(10_000)
        context.insert(Visit(arrival: cutoff, departure: cutoff.addingTimeInterval(600),
                             latitude: 0, longitude: 0, placeName: "Café", inferredActivity: "Coffee"))
        // Imported-journal source, excluded by a device-and-manual scope.
        context.insert(Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(7_800),
                             latitude: 0, longitude: 0, placeName: "Café", inferredActivity: "Coffee",
                             source: "imported-journal"))
        // A different place entirely.
        context.insert(Visit(arrival: base.addingTimeInterval(1_800), departure: base.addingTimeInterval(2_400),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let occurrences = try await reader.placeOccurrences(matching: "Café", before: cutoff, scope: .deviceAndManual)
        #expect(occurrences.count == 2, "the matching-name/before-cutoff/device-scope visits only")
        #expect(Set(occurrences.map(\.arrival)) == [base, base.addingTimeInterval(3_600)])
    }

    @Test("loggedHours sums only visits touching the given interval, scoped")
    func loggedHoursIsScopedAndBounded() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let interval = DateInterval(start: base, end: base.addingTimeInterval(7 * 24 * 3_600))
        // Inside the interval, one hour.
        context.insert(Visit(arrival: base.addingTimeInterval(3_600), departure: base.addingTimeInterval(7_200),
                             latitude: 0, longitude: 0, placeName: "Office", inferredActivity: "Working"))
        // Entirely before the interval -- excluded.
        context.insert(Visit(arrival: base.addingTimeInterval(-7_200), departure: base.addingTimeInterval(-3_600),
                             latitude: 0, longitude: 0, placeName: "Office", inferredActivity: "Working"))
        // Imported-journal source -- excluded by a device-and-manual scope.
        context.insert(Visit(arrival: base.addingTimeInterval(10_800), departure: base.addingTimeInterval(14_400),
                             latitude: 0, longitude: 0, placeName: "Office", inferredActivity: "Working",
                             source: "imported-journal"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let hours = try await reader.loggedHours(in: interval, scope: .deviceAndManual, now: interval.end)
        #expect(hours == 1)
    }

    @Test("historicalPlaceNames returns distinct shown names before the cutoff, scoped")
    func historicalPlaceNamesIsScopedDistinctAndBounded() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = base.addingTimeInterval(30 * 24 * 3_600)
        // Two prior visits to the same place -- one distinct name.
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising", source: "automatic"))
        context.insert(Visit(arrival: base.addingTimeInterval(86_400), departure: base.addingTimeInterval(90_000),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising", source: "automatic"))
        // On/after the cutoff -- excluded.
        context.insert(Visit(arrival: cutoff, departure: cutoff.addingTimeInterval(3_600),
                             latitude: 0, longitude: 0, placeName: "New Café", inferredActivity: "Coffee", source: "automatic"))
        // Imported-journal source -- excluded by a device-and-manual scope.
        context.insert(Visit(arrival: base.addingTimeInterval(172_800), departure: base.addingTimeInterval(176_400),
                             latitude: 0, longitude: 0, placeName: "Old Office", inferredActivity: "Working",
                             source: "imported-journal"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let names = try await reader.historicalPlaceNames(before: cutoff, scope: .deviceAndManual, generation: 1)
        #expect(names == ["Gym"])

        let allHistoryNames = try await reader.historicalPlaceNames(before: cutoff, scope: .allHistory, generation: 1)
        #expect(allHistoryNames == ["Gym", "Old Office"])
    }

    @Test("historicalPlaceNames is cached by generation and cutoff together")
    func historicalPlaceNamesCacheRespectsGenerationAndCutoff() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = base.addingTimeInterval(30 * 24 * 3_600)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising"))
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        #expect(try await reader.historicalPlaceNames(before: cutoff, scope: .allHistory, generation: 1) == ["Gym"])

        context.insert(Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(10_800),
                             latitude: 0, longitude: 0, placeName: "Park", inferredActivity: "Visiting"))
        try context.save()
        // Same generation, same cutoff: the cache still answers with the stale set.
        #expect(try await reader.historicalPlaceNames(before: cutoff, scope: .allHistory, generation: 1) == ["Gym"])
        // A new generation forces a fresh read.
        #expect(try await reader.historicalPlaceNames(before: cutoff, scope: .allHistory, generation: 2) == ["Gym", "Park"])
        // A different cutoff at the same generation also forces a fresh read.
        let laterCutoff = cutoff.addingTimeInterval(3_600)
        #expect(try await reader.historicalPlaceNames(before: laterCutoff, scope: .allHistory, generation: 2) == ["Gym", "Park"])
    }

    /// `historicalPlaceNames` is genuinely archive-wide by nature -- a complete
    /// distinct-names answer has no natural early stop the way a paged search
    /// does, so this measures the whole-scan cost directly rather than the
    /// effect of a `fetchLimit`. Comfortably under budget here, running on the
    /// background archive-reader actor, is what justifies not adding a
    /// persisted index or a schema change for it.
    @Test("historicalPlaceNames stays within budget against a 32,000-row archive")
    func historicalPlaceNamesBudgetOnLargeArchive() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = base.addingTimeInterval(Double(32_000) * 1_800)
        for index in 0..<32_000 {
            let arrival = base.addingTimeInterval(Double(index) * 1_800)
            context.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                                 latitude: -27.47, longitude: 153.03,
                                 placeName: "Place \(index % 500)",
                                 inferredActivity: index.isMultiple(of: 2) ? "At home" : "Visiting",
                                 source: "automatic"))
        }
        try context.save()

        let reader = VisitArchiveReader(modelContainer: container)
        let startedAt = Date.now
        let names = try await reader.historicalPlaceNames(before: cutoff, scope: .allHistory, generation: 1)
        let elapsed = Date.now.timeIntervalSince(startedAt)
        #expect(elapsed < Diagnostics.PerformanceBudget.annualHistoricalPlaces,
                "historicalPlaceNames took \(elapsed)s for the 32,000-row fixture")
        #expect(names.count == 500)
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
