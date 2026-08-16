import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `AskLifeLogViewModel`: the state machine driving one Ask LifeLog sheet.
/// Uses `FakeAskLifeLogPlanner` throughout — nothing here depends on live Apple
/// Intelligence. Covers unavailability, unsupported questions, stale-result
/// rejection, and the disambiguation round trip.
@MainActor
struct AskLifeLogViewModelTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func askContext(now: Date = .now, window: InsightWindow = .week) -> AskLifeLogQuestionContext {
        .current(window: window, interval: window.interval(containing: now), now: now, scope: .allHistory)
    }

    @Test("Apple Intelligence unavailable is surfaced without ever running a query")
    func unavailableSurfacedDirectly() async throws {
        let planner = FakeAskLifeLogPlanner.unavailable(.appleIntelligenceNotEnabled)
        let viewModel = AskLifeLogViewModel(planner: planner)
        #expect(viewModel.availability == .appleIntelligenceNotEnabled)

        let container = try makeContainer()
        viewModel.question = "anything"
        viewModel.ask(context: askContext(), reader: VisitArchiveReader(modelContainer: container),
                      repairActor: ArchiveRepairActor(modelContainer: container), catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .unavailable(.appleIntelligenceNotEnabled))
    }

    @Test("An unsupported question is reported, not improvised into a plan")
    func unsupportedQuestionReported() async throws {
        let planner = FakeAskLifeLogPlanner(result: .unsupported)
        let viewModel = AskLifeLogViewModel(planner: planner)
        let container = try makeContainer()
        viewModel.question = "what's my favourite colour?"
        viewModel.ask(context: askContext(), reader: VisitArchiveReader(modelContainer: container),
                      repairActor: ArchiveRepairActor(modelContainer: container), catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .unsupported)
    }

    @Test("Invalid model output is reported as such, not shown as an answer")
    func invalidOutputReported() async throws {
        let planner = FakeAskLifeLogPlanner(result: .invalidOutput)
        let viewModel = AskLifeLogViewModel(planner: planner)
        let container = try makeContainer()
        viewModel.question = "garbled"
        viewModel.ask(context: askContext(), reader: VisitArchiveReader(modelContainer: container),
                      repairActor: ArchiveRepairActor(modelContainer: container), catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        #expect(viewModel.state == .invalidOutput)
    }

    @Test("A newer question supersedes an older one still in flight, even if the older one resolves later")
    func newerAskSupersedesOlder() async throws {
        let planner = FakeAskLifeLogPlanner(responses: [
            "slow question": .unsupported,
            "fast question": .invalidOutput,
        ], delayNanoseconds: 100_000_000)
        let viewModel = AskLifeLogViewModel(planner: planner)
        let container = try makeContainer()
        let reader = VisitArchiveReader(modelContainer: container)
        let repairActor = ArchiveRepairActor(modelContainer: container)

        viewModel.question = "slow question"
        viewModel.ask(context: askContext(), reader: reader, repairActor: repairActor, catalogue: [], diagnosticsContext: nil)
        #expect(viewModel.state == .working, "state flips to working synchronously, before the planner call resolves")

        viewModel.question = "fast question"
        viewModel.ask(context: askContext(), reader: reader, repairActor: repairActor, catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        // Give the now-stale first call's delayed completion a chance to land too.
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(viewModel.state == .invalidOutput, "the later call's result must win regardless of completion order")
    }

    @Test("Choosing a disambiguation candidate resolves and re-runs without re-planning")
    func choosingCandidateResolvesAndExecutes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: .now, departure: .now.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        context.insert(Visit(arrival: .now.addingTimeInterval(1_000), departure: .now.addingTimeInterval(1_600),
                             latitude: 0, longitude: 0, placeName: "Riverside Gym", inferredActivity: "Exercising"))
        try context.save()

        let plan = AskLifeLogQueryPlan.placeTotal(place: .init("Riverside"), window: .thisWeek)
        let viewModel = AskLifeLogViewModel(planner: FakeAskLifeLogPlanner(result: .plan(plan)))
        let reader = VisitArchiveReader(modelContainer: container)
        let repairActor = ArchiveRepairActor(modelContainer: container)
        let ctx = askContext()

        viewModel.question = "how much time at riverside?"
        viewModel.ask(context: ctx, reader: reader, repairActor: repairActor, catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()

        guard case .ambiguousPlace(let candidates, _) = viewModel.state else {
            Issue.record("Expected ambiguousPlace, got \(viewModel.state)")
            return
        }
        #expect(Set(candidates.map(\.name)) == ["Riverside Cafe", "Riverside Gym"])

        viewModel.chooseAmbiguousCandidate("Riverside Cafe", context: ctx, reader: reader, repairActor: repairActor,
                                          catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()

        guard case .answer(let answer) = viewModel.state else {
            Issue.record("Expected an answer, got \(viewModel.state)")
            return
        }
        #expect(answer.drillDown == .place(name: "Riverside Cafe"))
    }

    @Test("Dismissing ambiguity returns to idle without executing anything")
    func dismissingAmbiguityReturnsToIdle() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: .now, departure: .now.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        context.insert(Visit(arrival: .now.addingTimeInterval(1_000), departure: .now.addingTimeInterval(1_600),
                             latitude: 0, longitude: 0, placeName: "Riverside Gym", inferredActivity: "Exercising"))
        try context.save()

        let plan = AskLifeLogQueryPlan.placeTotal(place: .init("Riverside"), window: .thisWeek)
        let viewModel = AskLifeLogViewModel(planner: FakeAskLifeLogPlanner(result: .plan(plan)))
        viewModel.question = "how much time at riverside?"
        viewModel.ask(context: askContext(), reader: VisitArchiveReader(modelContainer: container),
                      repairActor: ArchiveRepairActor(modelContainer: container), catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        guard case .ambiguousPlace = viewModel.state else { Issue.record("Expected ambiguousPlace"); return }

        viewModel.dismissAmbiguity()
        #expect(viewModel.state == .idle)
    }

    @Test("invalidateIfShowingResult clears a shown answer, and is a no-op when nothing is shown")
    func invalidateClearsShownAnswerOnly() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: .now, departure: .now.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "At home"))
        try context.save()

        let plan = AskLifeLogQueryPlan.placeTotal(place: .init("Home"), window: .thisWeek)
        let viewModel = AskLifeLogViewModel(planner: FakeAskLifeLogPlanner(result: .plan(plan)))
        viewModel.question = "time at home?"
        viewModel.ask(context: askContext(), reader: VisitArchiveReader(modelContainer: container),
                      repairActor: ArchiveRepairActor(modelContainer: container), catalogue: [], diagnosticsContext: nil)
        await viewModel.waitForCompletion()
        guard case .answer = viewModel.state else { Issue.record("Expected an answer"); return }

        viewModel.invalidateIfShowingResult()
        #expect(viewModel.state == .idle)

        viewModel.invalidateIfShowingResult()
        #expect(viewModel.state == .idle)
    }
}
