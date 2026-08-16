import SwiftUI
import SwiftData

/// The "Help me classify this gap" section of `ManualVisitView` — a
/// confirmation-first Apple Intelligence helper for exactly the selected gap.
///
/// Never creates, edits, merges, or deletes a `Visit` on its own: every path
/// through this view only ever offers to populate `ManualVisitView`'s own
/// editable fields via `useAsDraft`, which still requires the person to review
/// and tap Save themselves. Identifiers are attached to the specific leaf
/// Text/Button in each state rather than a wrapping container — a nested
/// identifier on a container silently overwrites a child Button's own identity
/// on the iOS 27 beta SDK this was built and tested against.
struct GapSuggestionSection: View {
    @Environment(\.modelContext) private var context
    let range: DateInterval
    let viewModel: GapSuggestionViewModel
    let useAsDraft: (GapSuggestionCandidate) -> Void

    var body: some View {
        Section {
            content
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("A suggestion based on nearby records and prior patterns for this one gap — not a fact. You always review and save.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            Button("Help me classify this gap", action: request)
                .accessibilityIdentifier("gap-suggestion-request-button")

        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking it over…")
                    .accessibilityIdentifier("gap-suggestion-working")
            }

        case .unavailable(let availability):
            Text(availability.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gap-suggestion-unavailable")

        case .invalidOutput, .noReliableSuggestion:
            Text(GapSuggestionOutcome.noReliableSuggestionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gap-suggestion-no-reliable")

        case .result(let outcome):
            resultCard(outcome)
        }
    }

    @ViewBuilder
    private func resultCard(_ outcome: GapSuggestionOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline(outcome))
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("gap-suggestion-headline")
            Text("Confidence: \(outcome.confidence.rawValue.capitalized)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gap-suggestion-confidence")
            Text(outcome.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gap-suggestion-explanation")
            if let uncertaintyNote = outcome.uncertaintyNote {
                Text(uncertaintyNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("Use as draft") { accept(outcome) }
                    .accessibilityIdentifier("gap-suggestion-use-as-draft")
                Button("Edit manually") { decline(recording: nil) }
                    .accessibilityIdentifier("gap-suggestion-edit-manually")
                Button("Not right") { decline(recording: "rejected") }
                    .accessibilityIdentifier("gap-suggestion-not-right")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    /// "Possibly still at Home." / "Possible transition between Home and
    /// Regional Office." — the two cautious phrasings the product spec itself
    /// gives as examples, built here from the same context already shown in
    /// the explanation rather than any new text the model produced.
    private func headline(_ outcome: GapSuggestionOutcome) -> String {
        guard let candidate = viewModel.candidate(for: outcome) else {
            return GapSuggestionOutcome.noReliableSuggestionText
        }
        switch outcome.kind {
        case .possibleStay:
            return "Possibly still at \(candidate.placeName ?? "the same place")."
        case .possibleTravel:
            if let before = viewModel.lastContext?.before?.displayLabel,
               let after = viewModel.lastContext?.after?.displayLabel {
                return "Possible transition between \(before) and \(after)."
            }
            return "Possible travel time."
        case .noSuggestion, .needsManualReview:
            return GapSuggestionOutcome.noReliableSuggestionText
        }
    }

    private func request() {
        let actor = ArchiveRepairActor(modelContainer: context.container)
        viewModel.requestSuggestion(gapStart: range.start, gapEnd: range.end, repairActor: actor, diagnosticsContext: context)
    }

    private func accept(_ outcome: GapSuggestionOutcome) {
        guard let candidate = viewModel.candidate(for: outcome) else { return }
        useAsDraft(candidate)
        viewModel.recordUserAction("accepted", diagnosticsContext: context)
        // The draft now lives in the ordinary, editable form fields below —
        // the card collapses back to its starting state rather than keep
        // showing a decision that's already been acted on.
        viewModel.invalidateIfShowingResult()
    }

    private func decline(recording event: String?) {
        if let event { viewModel.recordUserAction(event, diagnosticsContext: context) }
        viewModel.invalidateIfShowingResult()
    }
}
