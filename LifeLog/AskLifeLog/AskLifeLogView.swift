import SwiftUI
import SwiftData

/// A compact, privacy-first question-answering sheet. A person asks a
/// plain-language question about their own history; Apple's on-device Foundation
/// Models framework only ever chooses which of LifeLog's own supported queries
/// to run — every figure on screen comes from LifeLog's existing deterministic
/// aggregation, never from the model. See `AskLifeLogQueryPlan`'s doc comment for
/// the full contract.
struct AskLifeLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let context: AskLifeLogQuestionContext
    let reader: VisitArchiveReader
    let repairActor: ArchiveRepairActor
    let catalogue: [ActivityDefinition]
    let onDrillDown: (InsightsRoute) -> Void

    @State private var viewModel: AskLifeLogViewModel

    init(context: AskLifeLogQuestionContext, reader: VisitArchiveReader, repairActor: ArchiveRepairActor,
        catalogue: [ActivityDefinition], planner: AskLifeLogPlanning, onDrillDown: @escaping (InsightsRoute) -> Void) {
        self.context = context
        self.reader = reader
        self.repairActor = repairActor
        self.catalogue = catalogue
        self.onDrillDown = onDrillDown
        _viewModel = State(initialValue: AskLifeLogViewModel(planner: planner))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ask LifeLog")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            viewModel.cancel()
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("ask-lifelog-sheet")
        // A background import or edit landing while this sheet is open must not
        // leave a stale answer on screen -- the same generation bump every other
        // Insights reader already watches for.
        .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
            viewModel.invalidateIfShowingResult()
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.availability {
        case .available: askForm
        case let unavailable: unavailableState(unavailable)
        }
    }

    private var askForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ask a plain-language question about your recorded history. LifeLog answers only from your own data on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("\(context.selectedWindow.title(for: context.selectedInterval)) · \(context.scope.title)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Where did I spend most Friday evenings?", text: $viewModel.question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("ask-lifelog-question-field")
                    Button("Ask") { ask() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || viewModel.state == .working)
                        .accessibilityIdentifier("ask-lifelog-submit")
                }

                stateView
            }
            .padding(18)
        }
    }

    @ViewBuilder private var stateView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .unavailable(let availability):
            unavailableState(availability)

        case .working:
            HStack(spacing: 10) {
                ProgressView()
                Text("Thinking…")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ask-lifelog-working")

        case .unsupported:
            AskLifeLogMessageCard(
                systemImage: "questionmark.circle",
                title: "I can't answer that yet",
                message: "Ask LifeLog answers totals, rankings, comparisons, last visits, patterns, and unlogged time. Try rephrasing, or use Archive Search for anything else."
            )

        case .invalidOutput:
            AskLifeLogMessageCard(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't understand that",
                message: "Try asking again, or rephrase the question."
            )

        case .noMatch(let phrase):
            AskLifeLogMessageCard(
                systemImage: "magnifyingglass",
                title: "No match for \u{201C}\(phrase)\u{201D}",
                message: "Nothing in the current scope matches that name. Try Archive Search, or a different phrase."
            )

        case .noData(let periodTitle):
            AskLifeLogMessageCard(
                systemImage: "tray",
                title: "No matching data",
                message: "Nothing is recorded for \(periodTitle) in the current scope."
            )

        case .noBaseline(let periodTitle):
            AskLifeLogMessageCard(
                systemImage: "chart.bar",
                title: "Not enough history to compare",
                message: "There isn't a comparable baseline for \(periodTitle) yet."
            )

        case .ambiguousPlace(let candidates, _):
            AskLifeLogDisambiguationList(title: "Which place did you mean?", names: candidates.map(\.name),
                                         onChoose: choose, onCancel: { viewModel.dismissAmbiguity() })

        case .ambiguousActivity(let candidates, _):
            AskLifeLogDisambiguationList(title: "Which activity did you mean?", names: candidates.map(\.name),
                                         onChoose: choose, onCancel: { viewModel.dismissAmbiguity() })

        case .answer(let answer):
            AskLifeLogAnswerCard(answer: answer) {
                guard let route = answer.drillDown else { return }
                viewModel.cancel()
                // Record the destination and dismiss; the presenting view pushes
                // it from the sheet's own `onDismiss`, once the dismissal has
                // actually completed. Pushing onto the presenter's navigation
                // path in the same step as `dismiss()` races the sheet-dismiss
                // transition against the stack-push transition.
                onDrillDown(route)
                dismiss()
            }
        }
    }

    private func unavailableState(_ availability: AskLifeLogAvailability) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "apple.intelligence")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(availability.description)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Insights and Archive Search work as usual without it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ask-lifelog-unavailable")
    }

    private func ask() {
        viewModel.ask(context: context, reader: reader, repairActor: repairActor, catalogue: catalogue,
                      diagnosticsContext: modelContext)
    }

    private func choose(_ name: String) {
        viewModel.chooseAmbiguousCandidate(name, context: context, reader: reader, repairActor: repairActor,
                                           catalogue: catalogue, diagnosticsContext: modelContext)
    }
}

private struct AskLifeLogMessageCard: View {
    let systemImage: String
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lifeCard()
        .accessibilityIdentifier("ask-lifelog-message")
    }
}

private struct AskLifeLogDisambiguationList: View {
    let title: String
    let names: [String]
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The identifier lives on this Text, not the surrounding VStack: SwiftUI
            // propagates a container's own `.accessibilityIdentifier` onto every
            // descendant accessibility element that lacks a stronger identity of its
            // own, which silently overwrote each candidate Button's own identifier
            // below when it was set here instead.
            Text(title).font(.headline).accessibilityIdentifier("ask-lifelog-disambiguation")
            ForEach(names, id: \.self) { name in
                Button { onChoose(name) } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("ask-lifelog-candidate")
            }
            Button("None of these", role: .cancel, action: onCancel)
                .font(.subheadline)
        }
        .padding(16)
        .lifeCard()
    }
}

private struct AskLifeLogAnswerCard: View {
    let answer: AskLifeLogAnswer
    let onDrillDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(answer.interpretedQuestion).font(.subheadline).foregroundStyle(.secondary)
            // The identifier lives on this Text, not the surrounding VStack -- see
            // the matching comment in `AskLifeLogDisambiguationList`.
            Text(answer.headline).font(.title2.weight(.semibold)).accessibilityIdentifier("ask-lifelog-answer")
            if let detail = answer.detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if !answer.supportingRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(answer.supportingRows, id: \.self) { row in
                        Text(row).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Text("\(answer.periodTitle) · \(answer.scopeTitle)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let label = answer.drillDownLabel {
                Button(action: onDrillDown) {
                    HStack {
                        Text(label)
                        if answer.drillDown != nil { Image(systemName: "chevron.right").font(.caption) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(answer.drillDown == nil)
                .accessibilityIdentifier("ask-lifelog-drill-down")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lifeCard()
    }
}
