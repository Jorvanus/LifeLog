import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]
    @State private var importingBackup = false
    @State private var backupURL: URL?
    @State private var backupSummary: BackupPresentation?
    @State private var creatingBackup = false
    @State private var backupTask: Task<Void, Never>?
    @State private var importMessage: String?
    @State private var addingManualSleep = false
    @State private var confirmingErase = false
    @State private var erasingData = false
    @State private var dataRecoveryGeneration = 0
    let recorder: LocationRecorder
    let activityData: ActivityDataService

    var body: some View {
        NavigationStack {
            Form {
                RecordingStatusSection(recorder: recorder, activityData: activityData)

                Section("Settings") {
                    NavigationLink { RecordingSettingsView(recorder: recorder, activityData: activityData) } label: {
                        SettingsHubRow(title: "Recording", detail: "Location and Motion", symbol: "location.fill")
                    }
                    .accessibilityIdentifier("recording-settings-link")

                    NavigationLink { AppleHealthSettingsView(activityData: activityData, addingManualSleep: $addingManualSleep) } label: {
                        SettingsHubRow(title: "Apple Health", detail: activityData.ui.authorizationStatus, symbol: "heart.text.square.fill")
                    }
                    .accessibilityIdentifier("apple-health-settings-link")

                    NavigationLink { PlacesActivitiesSettingsView(recorder: recorder, savedPlaceCount: savedPlaces.count) } label: {
                        SettingsHubRow(title: "Places & Activities", detail: "\(savedPlaces.count) saved places", symbol: "house.and.flag.fill")
                    }
                    .accessibilityIdentifier("places-activities-settings-link")

                    NavigationLink {
                        DataRecoverySettingsView(importingBackup: $importingBackup,
                                                 backupURL: $backupURL, backupSummary: $backupSummary, creatingBackup: creatingBackup,
                                                 erasingData: erasingData, createBackup: createBackup,
                                                 cancelBackup: { backupTask?.cancel() }, eraseAllData: { confirmingErase = true },
                                                 reloadGeneration: dataRecoveryGeneration)
                    } label: {
                        SettingsHubRow(title: "Data & Recovery", detail: "Import, backup, and repair", symbol: "externaldrive.fill")
                    }
                    .accessibilityIdentifier("data-recovery-settings-link")

                    NavigationLink { DiagnosticsSettingsView(recorder: recorder) } label: {
                        SettingsHubRow(title: "Diagnostics", detail: "Service history and location journal", symbol: "stethoscope")
                    }
                    .accessibilityIdentifier("diagnostics-link")

                    NavigationLink { AboutSettingsView() } label: {
                        SettingsHubRow(title: "About", detail: appVersion, symbol: "info.circle")
                    }
                    .accessibilityIdentifier("about-settings-link")
                }
            }
            .navigationTitle("Settings")
            .accessibilityIdentifier("settings-screen")
                .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    Task {
                        do {
                            guard let url = try result.get().first else { return }
                            let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                            try await activityData.withStoreReplacement {
                                try LocalBackupService.restore(Data(contentsOf: url), into: context)
                            }
                            importMessage = "Backup restored. Restart LifeLog to refresh all screens."
                        } catch let error as RestoreError {
                            importMessage = error.errorDescription
                        } catch { importMessage = "LifeLog couldn’t restore that backup. No changes were applied." }
                    }
                }
                .alert("Data & Recovery", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK", role: .cancel) { importMessage = nil }
                } message: {
                    Text(importMessage ?? "")
                }
                .sheet(isPresented: $addingManualSleep) { ManualSleepEntryView() }
                .confirmationDialog("Erase all data?", isPresented: $confirmingErase, titleVisibility: .visible) {
                    Button("Erase everything", role: .destructive) { eraseAllData() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes every visit, Saved Place, correction, diagnostic, and location callback on this device. There is no undo other than a backup you made beforehand.")
                }
        }
    }

    private func createBackup() {
        backupTask?.cancel()
        creatingBackup = true
        let startedAt = Date.now
        backupTask = Task {
            defer { creatingBackup = false }
            ExportFileCleanup.removeExpired()
            do {
                let data = try await BackupExportActor(modelContainer: context.container).makeBackup()
                try Task.checkCancellation()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LifeLog-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
                try ExportFileStaging.write(data, to: url)
                Diagnostics.budget(context, subsystem: "Data & Recovery", operation: "backup setup",
                                   startedAt: startedAt, budget: Diagnostics.PerformanceBudget.backupSetup)
                guard !Task.isCancelled else { return }
                backupURL = url
                backupSummary = BackupPresentation(data: data)
            } catch is CancellationError {
                return
            } catch {
            importMessage = error.localizedDescription
            }
        }
    }

    /// Wipes exactly the model types `LocalBackupService.restore` fully repopulates
    /// (Visit, SavedPlace, VisitCorrection, DiagnosticEvent, LocationEvent), so
    /// "Erase all data" then "Restore backup" round-trips cleanly into the empty
    /// store the restore footer already says it expects. `ActivityCatalog` and
    /// portable preferences are left alone: restore overwrites both unconditionally
    /// regardless of what was here before, so erasing them first buys nothing.
    private func eraseAllData() {
        erasingData = true
        Task {
            defer { erasingData = false }
            do {
                try await activityData.withStoreReplacement {
                    try context.delete(model: Visit.self)
                    try context.delete(model: SavedPlace.self)
                    try context.delete(model: VisitCorrection.self)
                    try context.delete(model: DiagnosticEvent.self)
                    try context.delete(model: LocationEvent.self)
                    try context.save()
                }
                InsightsInvalidation.invalidate(reason: "All data erased", context: context)
                dataRecoveryGeneration += 1
                importMessage = "All data erased. Restart LifeLog to refresh all screens."
            } catch {
                context.rollback()
                importMessage = "LifeLog couldn’t erase all data."
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

}
