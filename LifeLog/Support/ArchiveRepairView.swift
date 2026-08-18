import SwiftUI
import SwiftData

/// Scan-then-apply for `ArchiveRepair`, following `JournalCompactionView`: show
/// what would change, take a full backup, then change it. Nothing here runs on its
/// own — every step rewrites recorded history on a judgement call, so each one is
/// individually selectable and off until chosen.
struct ArchiveRepairView: View {
    @Environment(\.modelContext) private var context
    @State private var findings: ArchiveRepair.Findings?
    @State private var selection: Set<ArchiveRepair.Step> = []
    @State private var scanning = false
    @State private var creatingBackup = false
    @State private var applying = false
    @State private var confirming = false
    @State private var backupURL: URL?
    @State private var report: ArchiveRepair.Report?
    @State private var message: String?
    @State private var applyTask: Task<Void, Never>?

    private var selectedStepsWithWork: [ArchiveRepair.Step] {
        guard let findings else { return [] }
        return ArchiveRepair.Step.allCases.filter { selection.contains($0) && findings.count(for: $0) > 0 }
    }

    private var affectedRows: Int {
        guard let findings else { return 0 }
        return selectedStepsWithWork.reduce(0) { $0 + findings.count(for: $1) }
    }

    /// Two distinct things a person can be agreeing to here, and each gets its
    /// own sentence: inventing history for time nobody recorded, or a plain
    /// field-level rewrite. A step can only ever be one of these
    /// (`deletesRows` and `createsInferredRows` are mutually exclusive across
    /// `Step`), so this never needs to combine two warnings.
    private var confirmationMessage: String {
        if selectedStepsWithWork.contains(where: \.deletesRows) {
            return "LifeLog will create a complete local backup first. This removes records permanently."
        }
        if selectedStepsWithWork.contains(where: \.createsInferredRows) {
            return "LifeLog will create a complete local backup first. This adds new visits describing time you didn't record, inferred from your routine schedule — it does not change or remove anything that already exists."
        }
        return "LifeLog will create a complete local backup first. No records are removed by these steps."
    }

    var body: some View {
        Form {
            if let findings {
                summarySection(findings)
                stepsSection(findings)
                applySection
            } else {
                Section {
                    if scanning {
                        HStack {
                            ProgressView()
                            Text("Scanning the archive…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("repair-scanning")
                    } else {
                        Button("Scan archive") { scan() }
                            .accessibilityIdentifier("repair-scan")
                    }
                } footer: {
                    Text("Checks every visit for stays that were never closed and unlogged time that can be filled in. Nothing is changed by scanning.")
                }
            }
            if let report { reportSection(report) }
            if let backupURL {
                Section("Backup created") {
                    ShareLink(item: backupURL) { Label("Share backup", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Repair Archive")
        .accessibilityIdentifier("archive-repair-screen")
        .confirmationDialog("Back up before repairing?", isPresented: $confirming) {
            Button("Create backup and repair \(affectedRows) records", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmationMessage)
        }
        .alert("Archive repair", isPresented: Binding(get: { message != nil },
                                                      set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    @ViewBuilder
    private func summarySection(_ findings: ArchiveRepair.Findings) -> some View {
        Section("Found") {
            if findings.isEmpty {
                Text("Nothing to repair. The archive is consistent.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("repair-clean")
            } else {
                if findings.runawayStays > 0 {
                    LabeledContent("Runaway stays", value: "\(findings.runawayStays)")
                        .accessibilityIdentifier("repair-runaway-count")
                    LabeledContent("Time they claim",
                                   value: formattedDuration(findings.runawayHours * 3600))
                }
                if findings.unloggedGapCount > 0 {
                    LabeledContent("Unlogged gaps", value: "\(findings.unloggedGapCount)")
                        .accessibilityIdentifier("repair-unlogged-gap-count")
                    LabeledContent("Time unaccounted for",
                                   value: formattedDuration(findings.unloggedGapHours * 3600))
                    NavigationLink("Review every gap") { UnloggedGapsView() }
                        .accessibilityIdentifier("review-unlogged-gaps-link")
                }
            }
            Button("Rescan") { scan() }
                .disabled(scanning)
                .accessibilityIdentifier("repair-rescan")
        }
    }

    @ViewBuilder
    private func stepsSection(_ findings: ArchiveRepair.Findings) -> some View {
        Section {
            ForEach(ArchiveRepair.Step.allCases) { step in
                let count = findings.count(for: step)
                Toggle(isOn: Binding(
                    get: { selection.contains(step) },
                    set: { if $0 { selection.insert(step) } else { selection.remove(step) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(step.title)
                            Spacer()
                            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(step.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .disabled(count == 0)
                .accessibilityIdentifier("repair-step-\(step.rawValue)")
            }
        } header: {
            Text("Repairs")
        } footer: {
            // The gap between "found" and "will be closed" is the whole safety
            // story for runaways, so it is stated rather than left to be inferred
            // from two numbers that do not match.
            if findings.runawayStays > findings.runawayStaysClosable {
                Text("\(findings.runawayStays - findings.runawayStaysClosable) runaway stays have no visit at a different place to close them against. Those are left unchanged for you to edit by hand.")
            }
            // Same shape as the runaway note above: the gap between "found" and
            // "fillable" is a longer-than-a-day cutoff or a live-tracked
            // boundary, not a bug, so it is stated rather than left to guesswork.
            if findings.unloggedGapCount > findings.fillableGapCount {
                Text("\(findings.unloggedGapCount - findings.fillableGapCount) unlogged gaps are either longer than a day or border something live-tracked, so they are left unfilled for you to review by hand.")
            }
        }
    }

    @ViewBuilder
    private var applySection: some View {
        Section {
            if creatingBackup {
                HStack {
                    ProgressView()
                    Text("Creating backup…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { applyTask?.cancel() }
                }
                .accessibilityIdentifier("repair-progress")
            } else if applying {
                HStack {
                    ProgressView()
                    Text("Repairing…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("repair-progress")
            } else {
                Button("Apply repairs", role: selectedStepsWithWork.contains(where: { $0.deletesRows || $0.createsInferredRows }) ? .destructive : nil) {
                    confirming = true
                }
                .disabled(selectedStepsWithWork.isEmpty)
                .accessibilityIdentifier("apply-archive-repair")
            }
        } footer: {
            Text("A complete local backup is created immediately before anything changes. That backup is the only way back.")
        }
    }

    @ViewBuilder
    private func reportSection(_ report: ArchiveRepair.Report) -> some View {
        Section("Repaired") {
            if report.staysClosed > 0 { LabeledContent("Stays closed", value: "\(report.staysClosed)") }
            if report.routineGapsFilled > 0 { LabeledContent("Gap visits added", value: "\(report.routineGapsFilled)") }
            if report.stillNeedingReview > 0 {
                LabeledContent("Still need review", value: "\(report.stillNeedingReview)")
                    .accessibilityIdentifier("repair-needs-review")
            }
        }
    }

    private func scan() {
        scanning = true
        let container = context.container
        Task {
            let actor = ArchiveRepairActor(modelContainer: container)
            do {
                let result = try await actor.scan()
                await MainActor.run {
                    findings = result
                    // Pre-select nothing: every step rewrites history, and a
                    // default-on checklist is a decision made for the owner.
                    selection = []
                    scanning = false
                }
            } catch {
                await MainActor.run {
                    message = "The archive could not be scanned. Nothing was changed."
                    scanning = false
                }
            }
        }
    }

    private func apply() {
        creatingBackup = true
        let steps = Set(selectedStepsWithWork)
        let container = context.container
        applyTask?.cancel()
        applyTask = Task {
            // The backup is read off the UI actor through `BackupExportActor` and
            // written before the repair actor touches anything, so a failure —
            // or a cancellation — here stops the repair rather than leaving
            // changes with no way back.
            let url: URL
            do {
                let data = try await BackupExportActor(modelContainer: container).makeBackup()
                try Task.checkCancellation()
                let candidateURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LifeLog-Repair-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
                try data.write(to: candidateURL, options: .atomic)
                try Task.checkCancellation()
                url = candidateURL
            } catch is CancellationError {
                await MainActor.run { creatingBackup = false }
                return
            } catch {
                await MainActor.run {
                    message = "The backup could not be created, so nothing was repaired."
                    creatingBackup = false
                }
                return
            }
            await MainActor.run {
                backupURL = url
                creatingBackup = false
                applying = true
            }
            let actor = ArchiveRepairActor(modelContainer: container)
            do {
                let result = try await actor.apply(steps: steps)
                let rescanned = try? await actor.scan()
                await MainActor.run {
                    report = result
                    findings = rescanned
                    selection = []
                    applying = false
                    Diagnostics.record(context, subsystem: "Archive repair",
                                       message: "Closed \(result.staysClosed) runaway stays, added \(result.routineGapsFilled) gap-fill visits.",
                                       severity: "info", repairCount: result.totalChanges)
                    message = "Repair complete. \(result.totalChanges) records changed. The backup is ready to share."
                }
            } catch {
                await MainActor.run {
                    message = "The repair did not finish. Your data was left as it was, and the backup is ready to share."
                    applying = false
                }
            }
        }
    }
}
