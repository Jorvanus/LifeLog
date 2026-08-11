import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `PlaceScoreLifecycle.rescore` used to fetch every `Visit` and every
/// `VisitCorrection` ever recorded so its recurrence/priorCorrections signals had
/// something to search. These tests prove the scoped fetch that replaced it still
/// finds both kinds of match it depends on — same name anywhere, same spot under any
/// name — and does not accidentally pull in a visit or correction that matches
/// neither.
@MainActor
struct PlaceHistoryLookupTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Recurrence survives the scoped fetch: same name far away, same spot under a different name")
    func rescoreFindsRecurrenceWithoutLoadingWholeArchive() throws {
        let context = try makeContext()
        context.insert(SavedPlace(name: "Home", latitude: -27.4698, longitude: 153.0251, radius: 100))

        // Same physical spot, recorded under a different name before it was learned.
        context.insert(Visit(arrival: base.addingTimeInterval(-86_400), departure: base.addingTimeInterval(-86_400 + 600),
                             latitude: -27.46981, longitude: 153.02511, placeName: "Front porch",
                             inferredActivity: "Visiting", source: "automatic"))

        // Same name, recorded a long way from here.
        context.insert(Visit(arrival: base.addingTimeInterval(-172_800), departure: base.addingTimeInterval(-172_800 + 600),
                             latitude: -33.8688, longitude: 151.2093, placeName: "Home",
                             inferredActivity: "Visiting", source: "automatic"))

        // Neither name nor spot matches — must not contribute.
        context.insert(Visit(arrival: base.addingTimeInterval(-259_200), departure: base.addingTimeInterval(-259_200 + 600),
                             latitude: 51.5074, longitude: -0.1278, placeName: "Museum",
                             inferredActivity: "Visiting", source: "automatic"))

        let visit = Visit(arrival: base, latitude: -27.4698, longitude: 153.0251,
                          inferredActivity: "Visiting", source: "automatic")
        context.insert(visit)
        try context.save()

        let evaluation = PlaceScoreLifecycle.rescore(visit, stage: .arrival, context: context)

        #expect(evaluation?.selected?.name == "Home")
        #expect(evaluation?.breakdown.recurrence == 2)
    }

    @Test("Prior corrections survive the scoped fetch the same way")
    func rescoreFindsCorrectionsWithoutLoadingWholeArchive() throws {
        let context = try makeContext()
        context.insert(SavedPlace(name: "Home", latitude: -27.4698, longitude: 153.0251, radius: 100))

        // Same name, corrected a long way from here.
        context.insert(VisitCorrection(visitArrival: base.addingTimeInterval(-86_400),
                                       latitude: -33.8688, longitude: 151.2093,
                                       previousPlaceName: "Unknown place", newPlaceName: "Home",
                                       previousActivity: "Visiting", newActivity: "At home"))

        // Same spot, corrected to a different name.
        context.insert(VisitCorrection(visitArrival: base.addingTimeInterval(-172_800),
                                       latitude: -27.46982, longitude: 153.02512,
                                       previousPlaceName: "Unknown place", newPlaceName: "Porch",
                                       previousActivity: "Visiting", newActivity: "Sitting"))

        // Neither name nor spot matches — must not contribute.
        context.insert(VisitCorrection(visitArrival: base.addingTimeInterval(-259_200),
                                       latitude: 51.5074, longitude: -0.1278,
                                       previousPlaceName: "Unknown place", newPlaceName: "Museum",
                                       previousActivity: "Visiting", newActivity: "Sightseeing"))

        let visit = Visit(arrival: base, latitude: -27.4698, longitude: 153.0251,
                          inferredActivity: "Visiting", source: "automatic")
        context.insert(visit)
        try context.save()

        let evaluation = PlaceScoreLifecycle.rescore(visit, stage: .arrival, context: context)

        #expect(evaluation?.breakdown.priorCorrections == 10)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
