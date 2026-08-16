import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `GapSuggestionViewModel`: the state machine behind "Help me classify this
/// gap". The deterministic context is always built for real, through a real
/// `ArchiveRepairActor` over an in-memory store — only the model's own ranking
/// step is faked with `FakeGapSuggestionService`, so these tests exercise the
/// whole local pipeline (gap lookup, candidate generation, historical
/// matching) and not just the state machine in isolation.
@MainActor
struct GapSuggestionViewModelTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A Home stay followed by a gap followed by a Coffee Society stay —
    /// exactly the shape `homeToDestinationOffersContinuation` in
    /// `GapSuggestionCandidateGeneratorTests` covers deterministically, reused
    /// here as the seeded fixture the view model runs its whole pipeline over.
    @discardableResult
    private func seedHomeToDestinationGap(in container: ModelContainer) throws -> (gapStart: Date, gapEnd: Date) {
        let context = ModelContext(container)
        let home = SavedPlace(name: "Home", latitude: -23.378, longitude: 150.511, defaultActivity: "At home")
        home.homeWorkRole = .home
        context.insert(home)
        let before = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                           latitude: home.latitude, longitude: home.longitude, placeName: "Home",
                           inferredActivity: "At home", userActivity: "At home", source: "automatic")
        let after = Visit(arrival: start.addingTimeInterval(3 * 3600), departure: start.addingTimeInterval(4 * 3600),
                          latitude: 0, longitude: 0, placeName: "Coffee Society",
                          inferredActivity: "Eating", userActivity: "Eating", source: "automatic")
        context.insert(before); context.insert(after)
        try context.save()
        return (before.departure!, after.arrival)
    }

    @Test("Apple Intelligence unavailable is surfaced without ever building a suggestion")
    func unavailableSurfacedDirectly() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        let service = FakeGapSuggestionService.unavailable(.appleIntelligenceNotEnabled)
        let viewModel = GapSuggestionViewModel(service: service)
        #expect(viewModel.availability == .appleIntelligenceNotEnabled)

        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .unavailable(.appleIntelligenceNotEnabled))
    }

    @Test("A gap that no longer exists resolves to idle, never a stale suggestion")
    func vanishedGapResolvesToIdle() async throws {
        let container = try makeContainer()
        // No fixture inserted — this exact start/end never existed as a gap.
        let service = FakeGapSuggestionService(result: .init(
            kind: .noSuggestion, candidateKind: nil, confidence: .low, explanation: "x", uncertaintyNote: nil))
        let viewModel = GapSuggestionViewModel(service: service)

        viewModel.requestSuggestion(gapStart: start, gapEnd: start.addingTimeInterval(3600),
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .idle)
    }

    @Test("A validated possibleStay outcome with real confidence is shown as a result")
    func validOutcomeShownAsResult() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        let service = FakeGapSuggestionService(responses: [
            gap.gapStart: .init(kind: .possibleStay, candidateKind: .continuationOfBeforeStay, confidence: .medium,
                               explanation: "Bordering stay was Home.", uncertaintyNote: nil),
        ])
        let viewModel = GapSuggestionViewModel(service: service)

        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()

        guard case .result(let outcome) = viewModel.state else {
            Issue.record("Expected .result, got \(viewModel.state)")
            return
        }
        #expect(outcome.kind == .possibleStay)
        #expect(viewModel.candidate(for: outcome)?.placeName == "Home")
    }

    @Test("Low confidence collapses to the cautious 'no reliable suggestion' state, even for a real candidate")
    func lowConfidenceCollapsesToNoReliableSuggestion() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        let service = FakeGapSuggestionService(responses: [
            gap.gapStart: .init(kind: .possibleStay, candidateKind: .continuationOfBeforeStay, confidence: .low,
                               explanation: "Weak signal.", uncertaintyNote: "Could easily be wrong."),
        ])
        let viewModel = GapSuggestionViewModel(service: service)

        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .noReliableSuggestion)
    }

    @Test("needsManualReview and noSuggestion both collapse to the same cautious state")
    func manualReviewAndNoSuggestionCollapse() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)

        let reviewService = FakeGapSuggestionService(result: .init(
            kind: .needsManualReview, candidateKind: nil, confidence: .medium, explanation: "Not sure.", uncertaintyNote: nil))
        let reviewViewModel = GapSuggestionViewModel(service: reviewService)
        reviewViewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                          repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await reviewViewModel.waitForCompletion()
        #expect(reviewViewModel.state == .noReliableSuggestion)

        let noneService = FakeGapSuggestionService(result: .init(
            kind: .noSuggestion, candidateKind: nil, confidence: .low, explanation: "Nothing usable.", uncertaintyNote: nil))
        let noneViewModel = GapSuggestionViewModel(service: noneService)
        noneViewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                        repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await noneViewModel.waitForCompletion()
        #expect(noneViewModel.state == .noReliableSuggestion)
    }

    @Test("A scripted response naming a candidate kind the real context never produced surfaces as invalid, not a guess")
    func mismatchedScriptedCandidateSurfacesAsInvalid() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        // This fixture never produces a homeWorkTransition candidate — only
        // continuation-of-before — so scripting one here mirrors a model
        // response (or a drifted fixture) naming something it wasn't given.
        let service = FakeGapSuggestionService(responses: [
            gap.gapStart: .init(kind: .possibleTravel, candidateKind: .homeWorkTransition, confidence: .high,
                               explanation: "x", uncertaintyNote: nil),
        ])
        let viewModel = GapSuggestionViewModel(service: service)

        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .invalidOutput)
    }

    @Test("A cancelled request never publishes its result, however late it arrives")
    func cancelledRequestNeverPublishesLateResult() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        let service = FakeGapSuggestionService(
            result: .init(kind: .possibleStay, candidateKind: .continuationOfBeforeStay, confidence: .high,
                         explanation: "Strong match.", uncertaintyNote: nil),
            delayNanoseconds: 100_000_000)
        let viewModel = GapSuggestionViewModel(service: service)
        let repairActor = ArchiveRepairActor(modelContainer: container)

        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd, repairActor: repairActor, diagnosticsContext: nil)
        #expect(viewModel.state == .working, "state flips to working synchronously, before the service call resolves")

        viewModel.cancel()
        #expect(viewModel.state == .working, "cancel alone doesn't change what's currently shown, only what may still publish")

        await viewModel.waitForCompletion()
        #expect(viewModel.state == .working, "the cancelled request's own result must never reach the screen")
    }

    @discardableResult
    private func seedNoCandidateGap(in container: ModelContainer) throws -> (gapStart: Date, gapEnd: Date) {
        let context = ModelContext(container)
        let farStart = start.addingTimeInterval(30 * 24 * 3600)
        let before = Visit(arrival: farStart, departure: farStart.addingTimeInterval(3600), latitude: 0, longitude: 0,
                           placeName: "Coffee Society", inferredActivity: "Eating", userActivity: "Eating", source: "automatic")
        let after = Visit(arrival: farStart.addingTimeInterval(3 * 3600), departure: farStart.addingTimeInterval(4 * 3600),
                          latitude: 0, longitude: 0, placeName: "Woolworths Gracemere",
                          inferredActivity: "Groceries", userActivity: "Groceries", source: "automatic")
        context.insert(before); context.insert(after)
        try context.save()
        return (before.departure!, after.arrival)
    }

    @Test("A request for a different gap supersedes one still in flight for a previous gap, regardless of completion order")
    func requestForNewGapSupersedesPrevious() async throws {
        let container = try makeContainer()
        let gapA = try seedHomeToDestinationGap(in: container)
        let gapB = try seedNoCandidateGap(in: container)
        let service = FakeGapSuggestionService(responses: [
            gapA.gapStart: .init(kind: .possibleStay, candidateKind: .continuationOfBeforeStay, confidence: .high,
                                explanation: "A", uncertaintyNote: nil),
        ], delayNanoseconds: 100_000_000)
        let viewModel = GapSuggestionViewModel(service: service)
        let repairActor = ArchiveRepairActor(modelContainer: container)

        viewModel.requestSuggestion(gapStart: gapA.gapStart, gapEnd: gapA.gapEnd, repairActor: repairActor, diagnosticsContext: nil)
        #expect(viewModel.state == .working)

        viewModel.requestSuggestion(gapStart: gapB.gapStart, gapEnd: gapB.gapEnd, repairActor: repairActor, diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        // Give the now-stale first call's delayed completion a chance to land too.
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(viewModel.state == .noReliableSuggestion, "gap B's result must win, regardless of gap A's delayed completion")
    }

    @Test("invalidateIfShowingResult clears a shown result, and is a no-op when nothing is shown")
    func invalidateClearsShownResultOnly() async throws {
        let container = try makeContainer()
        let gap = try seedHomeToDestinationGap(in: container)
        let service = FakeGapSuggestionService(responses: [
            gap.gapStart: .init(kind: .possibleStay, candidateKind: .continuationOfBeforeStay, confidence: .high,
                               explanation: "Strong match.", uncertaintyNote: nil),
        ])
        let viewModel = GapSuggestionViewModel(service: service)
        viewModel.requestSuggestion(gapStart: gap.gapStart, gapEnd: gap.gapEnd,
                                    repairActor: ArchiveRepairActor(modelContainer: container), diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        guard case .result = viewModel.state else { Issue.record("Expected a result"); return }

        viewModel.invalidateIfShowingResult()
        #expect(viewModel.state == .idle)

        viewModel.invalidateIfShowingResult()
        #expect(viewModel.state == .idle)
    }
}
