import Foundation
import SwiftData
import Observation

/// Drives one Ask LifeLog sheet: sends a question to a planner, resolves and
/// executes the plan it returns, and holds whatever should be on screen next.
///
/// Every asynchronous step is guarded by `runID`: starting a new question, or
/// invalidating the current one, changes the token, and any earlier step that
/// finishes after that change discards its result instead of publishing it.
/// This is what keeps a stale plan or answer from ever reaching the screen
/// after the question, period, scope, date, or store generation moves on.
@MainActor
@Observable
final class AskLifeLogViewModel {
    enum State: Equatable {
        case idle
        case unavailable(AskLifeLogAvailability)
        case working
        case unsupported
        case invalidOutput
        case ambiguousPlace([AskLifeLogPlaceCandidate], plan: AskLifeLogQueryPlan)
        case ambiguousActivity([AskLifeLogActivityCandidate], plan: AskLifeLogQueryPlan)
        case noMatch(phrase: String)
        case noData(periodTitle: String)
        case noBaseline(periodTitle: String)
        case answer(AskLifeLogAnswer)
    }

    var question = ""
    private(set) var state: State = .idle

    private let planner: AskLifeLogPlanning
    private var runID = UUID()
    /// Held only so a test can `await` a run to completion instead of polling
    /// `state` — the UI never reads this, since `ask`/`chooseAmbiguousCandidate`
    /// are fire-and-forget from a button tap by design.
    private var inFlightTask: Task<Void, Never>?

    init(planner: AskLifeLogPlanning) {
        self.planner = planner
    }

    var availability: AskLifeLogAvailability { planner.availability() }

    /// Abandons whatever is in flight without changing what's currently shown —
    /// used when the sheet is about to close.
    func cancel() {
        runID = UUID()
    }

    /// Test-only: waits for the most recently started `ask`/
    /// `chooseAmbiguousCandidate` run to finish publishing (or discarding) its
    /// result, so a test can assert on `state` deterministically instead of
    /// polling or sleeping.
    func waitForCompletion() async {
        await inFlightTask?.value
    }

    /// Called whenever the period, date, source scope, filters, or store
    /// generation changes while this view model is alive. A shown answer
    /// described a specific selection; once that selection has moved on, the
    /// answer must not keep being shown as if it still applied.
    func invalidateIfShowingResult() {
        cancel()
        guard case .answer = state else { return }
        state = .idle
    }

    func ask(context: AskLifeLogQuestionContext, reader: VisitArchiveReader, repairActor: ArchiveRepairActor,
            catalogue: [ActivityDefinition], diagnosticsContext: ModelContext?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let token = UUID()
        runID = token
        state = .working

        inFlightTask = Task { [planner] in
            let startedAt = Date.now
            // Foundation Models availability and session setup can synchronously
            // consult system services before their first suspension. Run the whole
            // planner call detached so opening the sheet and typing stay responsive.
            let outcome = await Task.detached(priority: .userInitiated) {
                await planner.plan(question: trimmed, context: context)
            }.value
            let planDurationMs = Int(Date.now.timeIntervalSince(startedAt) * 1000)
            Diagnostics.askLifeLogPlan(diagnosticsContext, durationMs: planDurationMs,
                                      planKind: outcome.diagnosticPlanKind, outcome: outcome.diagnosticOutcome)
            guard runID == token else {
                Diagnostics.record(diagnosticsContext, subsystem: DiagnosticSubsystem.askLifeLog.rawValue,
                                   message: "stale plan rejected", severity: "info")
                return
            }
            switch outcome {
            case .unavailable(let availability): state = .unavailable(availability)
            case .unsupported: state = .unsupported
            case .invalidOutput: state = .invalidOutput
            case .plan(let plan):
                await execute(plan, token: token, context: context, reader: reader, repairActor: repairActor,
                            catalogue: catalogue, diagnosticsContext: diagnosticsContext)
            }
        }
    }

    /// A person picked one candidate from a disambiguation list. The chosen name
    /// is substituted into the original plan and re-run directly — the model
    /// already chose the query type and parameters; only the ambiguous phrase
    /// needed a person to resolve it, so planning does not repeat.
    func chooseAmbiguousCandidate(_ name: String, context: AskLifeLogQuestionContext, reader: VisitArchiveReader,
                                  repairActor: ArchiveRepairActor, catalogue: [ActivityDefinition],
                                  diagnosticsContext: ModelContext?) {
        let originalPlan: AskLifeLogQueryPlan?
        switch state {
        case .ambiguousPlace(_, let plan), .ambiguousActivity(_, let plan): originalPlan = plan
        default: originalPlan = nil
        }
        guard let originalPlan, let resolvedPlan = Self.substituting(name, into: originalPlan) else { return }
        let token = UUID()
        runID = token
        state = .working
        inFlightTask = Task {
            await execute(resolvedPlan, token: token, context: context, reader: reader, repairActor: repairActor,
                        catalogue: catalogue, diagnosticsContext: diagnosticsContext)
        }
    }

    func dismissAmbiguity() {
        invalidateIfShowingResult()
        state = .idle
    }

    private func execute(_ plan: AskLifeLogQueryPlan, token: UUID, context: AskLifeLogQuestionContext,
                         reader: VisitArchiveReader, repairActor: ArchiveRepairActor,
                         catalogue: [ActivityDefinition], diagnosticsContext: ModelContext?) async {
        let startedAt = Date.now
        let result = try? await AskLifeLogQueryExecutor.execute(plan, context: context, reader: reader,
                                                                 repairActor: repairActor, catalogue: catalogue)
        let durationMs = Int(Date.now.timeIntervalSince(startedAt) * 1000)
        guard runID == token else {
            Diagnostics.record(diagnosticsContext, subsystem: DiagnosticSubsystem.askLifeLog.rawValue,
                               message: "stale result rejected", severity: "info")
            return
        }
        guard let result else {
            Diagnostics.askLifeLogQuery(diagnosticsContext, durationMs: durationMs, resultCategory: "error")
            state = .invalidOutput
            return
        }
        Diagnostics.askLifeLogQuery(diagnosticsContext, durationMs: durationMs, resultCategory: result.diagnosticCategory)
        switch result {
        case .answer(let answer): state = .answer(answer)
        case .ambiguousPlace(let candidates, let plan): state = .ambiguousPlace(candidates, plan: plan)
        case .ambiguousActivity(let candidates, let plan): state = .ambiguousActivity(candidates, plan: plan)
        case .noMatch(let phrase): state = .noMatch(phrase: phrase)
        case .noData(let periodTitle): state = .noData(periodTitle: periodTitle)
        case .noBaseline(let periodTitle): state = .noBaseline(periodTitle: periodTitle)
        }
    }

    /// `nil` for a plan shape that can never actually reach a disambiguation
    /// state (only activity/place/lastVisit/navigation references do).
    private static func substituting(_ name: String, into plan: AskLifeLogQueryPlan) -> AskLifeLogQueryPlan? {
        switch plan {
        case .activityTotal(_, let window): return .activityTotal(activity: .init(name), window: window)
        case .placeTotal(_, let window): return .placeTotal(place: .init(name), window: window)
        case .lastVisitToPlace: return .lastVisitToPlace(place: .init(name))
        case .navigation(.activity): return .navigation(.activity(.init(name)))
        case .navigation(.place): return .navigation(.place(.init(name)))
        default: return nil
        }
    }
}
