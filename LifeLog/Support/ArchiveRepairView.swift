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
    @State private var applying = false
    @State private var confirming = false
    @State private var backupURL: URL?
    @State private var report: ArchiveRepair.Report?
    @State private var message: String?

    private var selectedStepsWithWork: [ArchiveRepair.Step] {
        guard let findings else { return [] }
        return ArchiveRepair.Step.allCases.filter { selection.contains($0) && findings.count(for: $0) > 0 }
    }

    private var affectedRows: Int {
        guard let findings else { return 0 }
        return selectedStepsWithWork.reduce(0) { $0 + findings.count(for: $1) }
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
                    Text("Checks every visit for stays that were never closed, duplicate records, and history that can be improved. Nothing is changed by scanning.")
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
            Text(selectedStepsWithWork.contains(where: \.deletesRows)
                 ? "LifeLog will create a complete local backup first. This removes records permanently."
                 : "LifeLog will create a complete local backup first. No records are removed by these steps.")
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
                if findings.duplicateRows > 0 {
                    LabeledContent("Duplicate records", value: "\(findings.duplicateRows)")
                }
                if findings.nestedJourneys > 0 {
                    LabeledContent("Nested journeys", value: "\(findings.nestedJourneys)")
                }
                if findings.sleepPlaceholderRows > 0 {
                    LabeledContent("Sleep entries named \"Imported journal\"", value: "\(findings.sleepPlaceholderRows)")
                        .accessibilityIdentifier("repair-sleep-placeholder-count")
                }
                if findings.duplicateDefinitionRows > 0 {
                    LabeledContent("Duplicate activity definitions", value: "\(findings.duplicateDefinitionRows)")
                        .accessibilityIdentifier("repair-duplicate-definition-count")
                }
                if findings.unlinkedActivityRows > 0 {
                    LabeledContent("Unlinked activities", value: "\(findings.unlinkedActivityRows)")
                }
                if findings.uncoordinatedRows > 0 {
                    LabeledContent("Without coordinates", value: "\(findings.uncoordinatedRows)")
                }
            }
            Button("Rescan") { scan() }
                .disabled(scanning)
                .accessibilityIdentifier("repair-rescan")
        }
        if !findings.unmatchedPlaces.isEmpty {
            unmatchedPlacesSection(findings)
        }
    }

    /// Why the coordinate backfill reaches so few rows, and what would widen it.
    /// Without this the step reports a number a fraction of the "without
    /// coordinates" count directly above it, with no way to tell whether that is
    /// a bug or a limit.
    @ViewBuilder
    private func unmatchedPlacesSection(_ findings: ArchiveRepair.Findings) -> some View {
        Section {
            ForEach(findings.unmatchedPlaces) { place in
                LabeledContent(place.name, value: "\(place.visits)")
                    .accessibilityIdentifier("repair-unmatched-place")
            }
        } header: {
            Text("Places worth saving")
        } footer: {
            Text("Coordinates can only be filled in from a Saved Place with the same name. Adding a Saved Place for any of these would put that many more visits on the map the next time you repair.")
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
            // Explains why linking may stay small even after this step is
            // chosen: a name split across duplicate definitions needs the
            // duplicate merged first, which is a separate step above it.
            if findings.duplicateDefinitionRows > 0 {
                Text("\(findings.duplicateDefinitionNames) activity name\(findings.duplicateDefinitionNames == 1 ? "" : "s") in your catalogue currently point at more than one identity, which blocks linking for every visit using that name until the duplicate is merged.")
            }
        }
    }

    @ViewBuilder
    private var applySection: some View {
        Section {
            if applying {
                HStack {
                    ProgressView()
                    Text("Repairing…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("repair-progress")
            } else {
                Button("Apply repairs", role: selectedStepsWithWork.contains(where: \.deletesRows) ? .destructive : nil) {
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
            if report.duplicatesMerged > 0 { LabeledContent("Duplicates merged", value: "\(report.duplicatesMerged)") }
            if report.journeysCollapsed > 0 { LabeledContent("Journeys collapsed", value: "\(report.journeysCollapsed)") }
            if report.coordinatesAdded > 0 { LabeledContent("Coordinates added", value: "\(report.coordinatesAdded)") }
            if report.sleepPlaceholdersRenamed > 0 { LabeledContent("Sleep entries renamed", value: "\(report.sleepPlaceholdersRenamed)") }
            if report.definitionsMerged > 0 { LabeledContent("Duplicate definitions merged", value: "\(report.definitionsMerged)") }
            if report.activitiesLinked > 0 { LabeledContent("Activities linked", value: "\(report.activitiesLinked)") }
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
        applying = true
        let steps = Set(selectedStepsWithWork)
        let container = context.container
        Task {
            // The backup is taken on the main context before the actor touches
            // anything, so a failure here stops the repair rather than leaving
            // changes with no way back.
            do {
                let data = try LocalBackupService.makeBackup(context: context, diagnostics: [])
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LifeLog-Repair-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
                try data.write(to: url, options: .atomic)
                await MainActor.run { backupURL = url }
            } catch {
                await MainActor.run {
                    message = "The backup could not be created, so nothing was repaired."
                    applying = false
                }
                return
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
                                       message: "Closed \(result.staysClosed) runaway stays, merged \(result.duplicatesMerged) duplicates, collapsed \(result.journeysCollapsed) nested journeys, added \(result.coordinatesAdded) coordinates, renamed \(result.sleepPlaceholdersRenamed) sleep entries, merged \(result.definitionsMerged) duplicate definitions, linked \(result.activitiesLinked) activities.",
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
