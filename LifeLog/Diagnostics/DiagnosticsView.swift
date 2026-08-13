import SwiftUI
import SwiftData

struct DiagnosticsView: View {
    let recorder: LocationRecorder
    @Environment(\.modelContext) private var context
    @Query(sort: \DiagnosticEvent.createdAt, order: .reverse) private var diagnostics: [DiagnosticEvent]
    /// Counted from the store rather than handed over by Insights, so this screen does
    /// not depend on that one having been opened first.
    // SwiftData's property-wrapper predicate macro cannot capture a static value.
    @Query(filter: #Predicate<Visit> { $0.source == "automatic-superseded" })
    private var supersededVisits: [Visit]
    @Query(filter: #Predicate<Visit> { $0.source == "automatic" })
    private var automaticVisits: [Visit]
    @Query private var locationEvents: [LocationEvent]
    @State private var reportURL: URL?
    @State private var confirmingClear = false
    @State private var message: String?

    private var visibleDiagnostics: [DiagnosticEvent] {
        UITestFailureInjection.shouldShowEmptyDiagnostics ? [] : diagnostics
    }

    /// A stay Core Location named but nobody has agreed with. The same test the review
    /// queue uses, so the two cannot report different numbers.
    private var provisionalCount: Int {
        automaticVisits.count { $0.needsReview }
    }

    private var resolutionInspectableVisits: [Visit] {
        (automaticVisits + supersededVisits).filter {
            $0.locationResolutionCandidates != nil || $0.locationResolutionExplanation != nil
        }
    }

    /// Automatic arrivals whose measured fix was too fuzzy to trust for a distance
    /// comparison -- these never taught a Saved Place and never won a fine-distance
    /// comparison against a better candidate. Visits nothing ever scored are not
    /// counted; only fixes actually measured as approximate are.
    private var approximateVisitCount: Int {
        automaticVisits.count {
            LocationQuality.isApproximate(recordedAccuracyMeters: $0.placeScoreBreakdown?.accuracyMeters)
        }
    }

    var body: some View {
        List {
            // Moved off Insights, which answers "where did my time go" and had no
            // business reporting the app's own plumbing. A resolved duplicate callback
            // is a fact about the recorder, and this is where the recorder accounts
            // for itself.
            Section("Timeline quality") {
                LabeledContent("Stays needing review", value: "\(provisionalCount)")
                LabeledContent("Duplicate callbacks resolved", value: "\(supersededVisits.count)")
            }
            Section {
                LabeledContent("Precise location", value: recorder.accuracyAuthorization == .reducedAccuracy ? "Off" : "On")
                    .accessibilityIdentifier("diagnostics-precise-location")
                LabeledContent("Approximate arrivals", value: "\(approximateVisitCount)")
                    .accessibilityIdentifier("diagnostics-approximate-arrivals")
            } header: {
                Text("Location quality")
            } footer: {
                Text("An approximate arrival's fix was too fuzzy to trust for a distance comparison — it never taught a Saved Place and never won a fine-distance comparison against a better candidate.")
            }
            Section("Summary") {
                LabeledContent("Events retained", value: "\(visibleDiagnostics.count)")
                    .accessibilityIdentifier("diagnostics-events-count")
                LabeledContent("Subsystems", value: "\(Set(visibleDiagnostics.map(\.subsystem)).count)")
                LabeledContent("Slow or over-budget", value: "\(visibleDiagnostics.filter { $0.message.localizedCaseInsensitiveContains("slow") || $0.message.localizedCaseInsensitiveContains("over budget") }.count)")
            }
            // Both actions sit above the event list. The store keeps hundreds of
            // events, so anything below it is effectively unreachable without
            // scrolling the whole history first.
            Section {
                Button {
                    createReport()
                } label: { Label("Create performance report", systemImage: "chart.bar.doc.horizontal") }
                    .accessibilityIdentifier("create-performance-report")
                if let reportURL {
                    ShareLink(item: reportURL) { Label("Share performance report", systemImage: "square.and.arrow.up") }
                }
                Button("Clear diagnostics", role: .destructive) { confirmingClear = true }
                    .disabled(visibleDiagnostics.isEmpty)
                    .accessibilityIdentifier("clear-diagnostics")
            } footer: {
                Text("Reports contain only aggregate timings, counts, app version, and device/OS class—not coordinates, place names, notes, or Health values.")
            }
            // Its own screen rather than mixed into the list below: these are raw
            // inputs, there are several per arrival, and they carry coordinates that
            // the rest of this screen is careful not to.
            Section {
                NavigationLink {
                    LocationJournalView()
                } label: {
                    LabeledContent("Location journal", value: "\(locationEvents.count)")
                }
                .accessibilityIdentifier("location-journal-link")
            } footer: {
                Text(LocationDiagnostics.isDetailed
                     ? "The Core Location callbacks behind your timeline, with their coordinates and accuracy. Recording now."
                     : "Empty unless detailed location diagnostics are on, in Settings.")
            }
            Section {
                NavigationLink {
                    LocationResolutionChoicesView()
                } label: {
                    LabeledContent("Location resolution choices", value: "\(resolutionInspectableVisits.count)")
                }
                .accessibilityIdentifier("location-resolution-choices-link")
            } footer: {
                Text("The candidate chosen for each automatic repair and the alternatives rejected. This never adds raw callbacks or coordinates to Timeline.")
            }
            Section("Events") {
                if visibleDiagnostics.isEmpty {
                    Text("No diagnostic events recorded.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics-empty-state")
                }
                ForEach(visibleDiagnostics) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(event.subsystem).font(.caption.bold()); Spacer(); Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                        Text(event.message).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("diagnostics-screen")
        .confirmationDialog("Clear diagnostics?", isPresented: $confirmingClear) {
            Button("Clear \(diagnostics.count) events", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Diagnostics are how a background problem is traced after the fact. Clearing them cannot be undone, and a performance report made afterwards will have nothing to describe.")
        }
        .alert("Diagnostics", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func createReport() {
        ExportFileCleanup.removeExpired()
        let data = Diagnostics.makePerformanceReport(events: visibleDiagnostics)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeLog-Performance-Report.json")
        do {
            if UITestFailureInjection.shouldFailProtectedReport {
                throw CocoaError(.fileWriteNoPermission)
            }
            // Written with complete protection: the report is aggregate-only, but it
            // still describes this device and stays in the temporary directory until
            // it is shared or expires.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            reportURL = url
        } catch {
            message = "LifeLog couldn’t write the performance report."
        }
    }

    private func clear() {
        for event in diagnostics { context.delete(event) }
        do {
            // The deletes were previously left to autosave, so a clear could appear to
            // work and then reappear on the next launch.
            try context.save()
        } catch {
            message = "LifeLog couldn’t clear the diagnostics."
        }
    }
}

/// A durable account of the resolver's named options. Unlike `LocationJournalView`,
/// this is not a callback log: it contains no raw callback timing or coordinates and
/// remains useful after detailed location diagnostics have been turned off.
struct LocationResolutionChoicesView: View {
    @Query(filter: #Predicate<Visit> { $0.source == "automatic" })
    private var automaticVisits: [Visit]
    @Query(filter: #Predicate<Visit> { $0.source == "automatic-superseded" })
    private var supersededVisits: [Visit]

    private var visits: [Visit] {
        (automaticVisits + supersededVisits)
            .filter { $0.locationResolutionCandidates != nil || $0.locationResolutionExplanation != nil }
            .sorted { $0.arrival > $1.arrival }
    }

    var body: some View {
        List {
            if visits.isEmpty {
                ContentUnavailableView(
                    "No resolution choices yet",
                    systemImage: "checkmark.circle.badge.questionmark",
                    description: Text("Automatic arrivals will appear here after the resolver records a decision.")
                )
            } else {
                ForEach(visits) { visit in
                    Section {
                        Text(visit.locationResolutionExplanation?.diagnosticLabel ?? "No recorded resolution")
                            .font(.subheadline.weight(.semibold))
                        if let candidates = visit.locationResolutionCandidates {
                            if let chosen = candidates.chosen {
                                CandidateChoiceRow(title: "Chosen", candidate: chosen, tint: .green)
                            } else {
                                Label("No candidate was accepted", systemImage: "minus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            if !candidates.rejected.isEmpty {
                                ForEach(candidates.rejected) { candidate in
                                    CandidateChoiceRow(title: "Rejected", candidate: candidate, tint: .secondary)
                                }
                            }
                        } else {
                            Text("This repair did not use a named Maps or Saved Place candidate.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("Resolution Choices")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("location-resolution-choices-screen")
    }
}

private struct CandidateChoiceRow: View {
    let title: String
    let candidate: PlaceSuggestion
    let tint: Color

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(candidate.name)
                Text("\(Int(candidate.distance.rounded())) m away")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
                .foregroundStyle(tint)
        }
    }
}

/// The raw Core Location callbacks, newest first.
///
/// Every other screen in LifeLog shows a conclusion. This shows the evidence: what the
/// phone reported, how accurately, how late it arrived, and which branch the resolver
/// took. A stay in the wrong place is usually one bad row here, and until now that row
/// existed only in the moment it was handled.
struct LocationJournalView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LocationEvent.recordedAt, order: .reverse) private var events: [LocationEvent]
    @State private var confirmingClear = false

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView(
                    "No location callbacks recorded",
                    systemImage: "location.slash",
                    description: Text(LocationDiagnostics.isDetailed
                                      ? "Recording is on. Callbacks will appear here as Core Location delivers them."
                                      : "Turn on detailed location diagnostics in Settings to start recording.")
                )
            } else {
                Section {
                    Button("Clear location journal", role: .destructive) { confirmingClear = true }
                        .accessibilityIdentifier("clear-location-journal")
                } footer: {
                    Text("These rows hold precise coordinates. They stay on this iPhone, and the oldest are dropped past \(LocationJournal.retentionLimit).")
                }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.callbackType).font(.caption.bold())
                            Spacer()
                            Text(event.transition)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(event.resolverTransition == .ignored ? .orange : .secondary)
                        }
                        Text(detail(for: event)).font(.footnote).foregroundStyle(.secondary)
                        Text(position(of: event)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Location Journal")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("location-journal-screen")
        .confirmationDialog("Clear the location journal?", isPresented: $confirmingClear) {
            Button("Clear \(events.count) events", role: .destructive) { LocationJournal.clear(context) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This is the only record of the callbacks behind your timeline. Clearing it cannot be undone.")
        }
    }

    /// Times first, because lateness is the fault this screen exists to expose: a stay
    /// that looks mistimed is usually a callback that was delivered long after the
    /// moment it describes.
    private func detail(for event: LocationEvent) -> String {
        var parts: [String] = [event.callbackAt.formatted(date: .abbreviated, time: .standard)]
        let delay = event.deliveryDelay
        if delay >= 60 { parts.append("delivered \(Int(delay / 60)) min later") }
        if let arrival = event.arrival {
            parts.append("arrived \(arrival.formatted(date: .omitted, time: .standard))")
        }
        if let departure = event.departure {
            parts.append("left \(departure.formatted(date: .omitted, time: .standard))")
        }
        if let distance = event.distanceFromCurrentVisit {
            parts.append("\(Int(distance.rounded())) m from the open stay")
        }
        return parts.joined(separator: " · ")
    }

    private func position(of event: LocationEvent) -> String {
        var accuracy = event.accuracy >= 0 ? "±\(Int(event.accuracy.rounded())) m" : "accuracy unknown"
        if LocationQuality.isApproximate(event.accuracy) { accuracy += " (approximate)" }
        return String(format: "%.5f, %.5f · %@", event.latitude, event.longitude, accuracy)
    }
}
