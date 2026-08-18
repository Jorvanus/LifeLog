import CoreLocation
import SwiftUI
import SwiftData
import UIKit

/// The Settings root intentionally contains only the current state and six clear
/// routes. Operational detail lives here so an uncommon repair cannot bury a
/// permission failure or an active import on the main Settings screen.
struct RecordingStatusSection: View {
    let recorder: LocationRecorder
    let activityData: ActivityDataService

    private var locationStatus: String {
        switch recorder.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
        case .denied: "Needs attention"
        case .restricted: "Restricted"
        default: "Not enabled"
        }
    }

    var body: some View {
        Section("Recording status") {
            SettingsStatusRow(title: "Location", value: locationStatus,
                               symbol: "location.fill", isProblem: recorder.authorization == .denied || recorder.authorization == .restricted)
            SettingsStatusRow(title: "Motion", value: activityData.ui.motionStatus,
                               symbol: "figure.walk", isProblem: activityData.ui.motionStatus == "Denied" || activityData.ui.motionStatus == "Restricted")
            SettingsStatusRow(title: "Apple Health", value: activityData.ui.authorizationStatus,
                               symbol: "heart.fill", isProblem: activityData.ui.authorizationStatus != "Connected")

            if let progress = activityData.ui.progress {
                ActivityImportStatus(progress: progress, cancel: activityData.cancelImport)
            }
            if let error = recorder.lastError ?? activityData.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-recording-issue")
            }
        }
        .accessibilityIdentifier("recording-status-section")
    }
}

struct SettingsHubRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

/// Shared compact presentation for a status value. Actions are visually
/// separate below it, so the state remains easy to scan at any text size.
struct SettingsStatusRow: View {
    let title: String
    let value: String
    let symbol: String
    let isProblem: Bool

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isProblem ? .orange : .secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

private struct ActivityImportStatus: View {
    let progress: ActivityImportProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(progress.title, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if progress.total > 0 {
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if progress.isActive {
                if progress.total > 0 { ProgressView(value: progress.fraction) } else { ProgressView() }
                if progress.total > 0 {
                    Text("\(progress.completed) of \(progress.total) activity records processed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if progress.state != .cancelling {
                    Button("Cancel import", action: cancel)
                        .accessibilityIdentifier("cancel-activity-import")
                }
            } else {
                Text(progress.state == .complete ? "Complete" : progress.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("activity-import-progress")
    }
}

struct RecordingSettingsView: View {
    let recorder: LocationRecorder
    let activityData: ActivityDataService

    var body: some View {
        Form {
            Section {
                LocationRecordingControls(recorder: recorder)
            } header: {
                Text("Location")
            } footer: {
                Text(locationExplanation)
            }
            Section {
                SettingsStatusRow(title: "Motion access", value: activityData.ui.motionStatus,
                                  symbol: "figure.walk", isProblem: activityData.ui.motionStatus == "Denied" || activityData.ui.motionStatus == "Restricted")
                switch activityData.ui.motionStatus {
                case "Not requested":
                    Button("Enable motion activity") { activityData.requestMotionAccess() }
                        .accessibilityIdentifier("enable-motion-activity")
                case "Denied":
                    Button("Open iPhone Settings", action: openAppSettings)
                        .accessibilityIdentifier("open-motion-settings")
                case "Connected" where !activityData.ui.isImporting:
                    Button("Refresh motion activity") { activityData.refreshMotionHistory() }
                        .accessibilityIdentifier("refresh-motion-activity")
                case "Restricted":
                    Text("Motion & Fitness is restricted by this iPhone’s settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                default:
                    Text("Motion Activity status is unavailable right now. Try reopening LifeLog or check iPhone Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Motion Activity")
            } footer: {
                Text("What does Motion add? Walking, running, cycling, and vehicle history retained by the iPhone for roughly one week.")
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var locationExplanation: String {
        switch recorder.authorization {
        case .notDetermined: "Enable location access to start recording visits."
        case .authorizedAlways: "Always Location access lets LifeLog record arrivals and departures when it is not open."
        case .authorizedWhenInUse: "Enable background logging to ask iOS for Always Location access."
        case .denied: "Location access is off. Open iPhone Settings to allow LifeLog to identify visits."
        case .restricted: "Location access is restricted by this iPhone’s settings."
        @unknown default: "Location access controls whether LifeLog can identify where visits happened."
        }
    }
}

private struct LocationRecordingControls: View {
    let recorder: LocationRecorder

    var body: some View {
        switch recorder.authorization {
        case .notDetermined:
            Button("Enable location logging") { recorder.requestPermission() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("enable-location-logging")
        case .authorizedWhenInUse, .authorizedAlways:
            SettingsStatusRow(title: "Location access", value: permissionName,
                              symbol: "location.fill", isProblem: false)
            if recorder.accuracyAuthorization == .reducedAccuracy {
                Label("Precise location is off", systemImage: "location.slash")
                    .foregroundStyle(.orange)
                Button("Open iPhone Settings", action: openAppSettings)
                    .accessibilityIdentifier("open-precise-location-settings")
            }
            Toggle("Background location logging", isOn: backgroundLoggingBinding)
            Button("Refresh current location") { recorder.refreshCurrentLocation() }
        case .denied:
            SettingsStatusRow(title: "Location access", value: permissionName,
                              symbol: "location.fill", isProblem: true)
            Button("Open iPhone Settings", action: openAppSettings)
                .accessibilityIdentifier("open-location-settings")
        case .restricted:
            SettingsStatusRow(title: "Location access", value: permissionName,
                              symbol: "location.fill", isProblem: true)
        @unknown default:
            SettingsStatusRow(title: "Location access", value: permissionName,
                              symbol: "location.fill", isProblem: false)
        }
    }

    private var backgroundLoggingBinding: Binding<Bool> {
        Binding(get: { recorder.isBackgroundLoggingEnabled }, set: { enabled in
            if enabled { recorder.enableBackgroundLogging() } else { recorder.disableBackgroundLogging() }
        })
    }

    private var permissionName: String {
        switch recorder.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
        case .denied: "Denied"
        case .restricted: "Restricted"
        default: "Not requested"
        }
    }
}

struct AppleHealthSettingsView: View {
    let activityData: ActivityDataService
    @Binding var addingManualSleep: Bool

    var body: some View {
        Form {
            Section("Connection") {
                SettingsStatusRow(title: "Connection", value: activityData.ui.authorizationStatus,
                                  symbol: "heart.fill", isProblem: activityData.ui.authorizationStatus != "Connected")
                SettingsStatusRow(title: "Sleep evidence", value: activityData.ui.sleepEvidenceStatus,
                                  symbol: "bed.double.fill", isProblem: false)
                if !activityData.ui.unaskedTypes.isEmpty {
                    Button("Connect Apple Health") { Task { await activityData.requestHealthAccess() } }
                        .accessibilityIdentifier("connect-health")
                    Text("Not yet asked for: \(activityData.ui.unaskedTypes.formatted(.list(type: .and))).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if activityData.ui.authorizationStatus != "Connected" && activityData.ui.authorizationStatus != "Unavailable on this device" {
                    Button("Open Apple Health", action: openAppleHealth)
                        .accessibilityIdentifier("open-health")
                }
            }
            Section("Import") {
                if !activityData.ui.isImporting {
                    Button("Re-import Health history") { activityData.reimportHealthHistory() }
                        .accessibilityIdentifier("reimport-health")
                }
                if let imported = activityData.ui.lastImport {
                    LabeledContent("Last import", value: imported.formatted(date: .abbreviated, time: .shortened))
                }
                Text("What happens on re-import? LifeLog rereads the last 30 days and updates existing entries without duplicating them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sleep") {
                Button("Add sleep manually") { addingManualSleep = true }
                    .accessibilityIdentifier("add-manual-sleep")
                Text("What can this add? A sleep entry when Apple Health has no usable sleep evidence; LifeLog never infers sleep from a stationary phone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlacesActivitiesSettingsView: View {
    let recorder: LocationRecorder
    let savedPlaceCount: Int

    var body: some View {
        List {
            Section {
                NavigationLink { PlacesView(recorder: recorder) } label: {
                    SettingsHubRow(title: "Locations", detail: "\(savedPlaceCount) saved places", symbol: "house.and.flag.fill")
                }
                .accessibilityIdentifier("saved-places-link")
                NavigationLink { ActivitiesView() } label: {
                    SettingsHubRow(title: "Activity Labels", detail: "Names and icons", symbol: "list.bullet.clipboard")
                }
                .accessibilityIdentifier("activities-link")
                NavigationLink { ActivityGroupsView() } label: {
                    SettingsHubRow(title: "Groups", detail: "Organise activity labels", symbol: "square.grid.2x2")
                }
                .accessibilityIdentifier("activity-groups-link")
            } footer: {
                Text("What can I change here? Saved Places, the activity names LifeLog uses, and their groups.")
            }
        }
        .navigationTitle("Places & Activities")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A display-only decoding of the backup LifeLog just wrote. This confirms the
/// exact document available to save or share without retaining a second archive
/// in memory or suggesting that the temporary export is durable by itself.
struct BackupPresentation: Equatable {
    let createdAt: Date
    let visits: Int
    let savedPlaces: Int
    let corrections: Int
    let diagnostics: Int
    let locationEvents: Int
    let activityDefinitions: Int
    let byteCount: Int

    init(data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try? decoder.decode(LifeLogBackup.self, from: data)
        let counts = backup?.manifest?.recordCounts
        createdAt = backup?.createdAt ?? .now
        visits = counts?.visits ?? backup?.visits.count ?? 0
        savedPlaces = counts?.savedPlaces ?? backup?.savedPlaces.count ?? 0
        corrections = counts?.corrections ?? backup?.corrections.count ?? 0
        diagnostics = counts?.diagnostics ?? backup?.diagnostics.count ?? 0
        locationEvents = counts?.locationEvents ?? backup?.locationEvents?.count ?? 0
        activityDefinitions = counts?.activityDefinitionRecords ?? backup?.activityDefinitionRecords?.count ?? 0
        byteCount = data.count
    }

    var fileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

private struct BackupCreatedSummary: View {
    let summary: BackupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Backup ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            LabeledContent("Created", value: summary.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("File size", value: summary.fileSize)
            LabeledContent("Timeline visits", value: "\(summary.visits)")
            LabeledContent("Saved Places", value: "\(summary.savedPlaces)")
            LabeledContent("Corrections", value: "\(summary.corrections)")
            LabeledContent("Diagnostics", value: "\(summary.diagnostics)")
            LabeledContent("Location callbacks", value: "\(summary.locationEvents)")
            LabeledContent("Activity definitions", value: "\(summary.activityDefinitions)")
        }
        .accessibilityIdentifier("backup-created-summary")
    }
}

private struct DestinationStateSummary: View {
    let state: BackupDestinationState

    var body: some View {
        if state.isEmpty {
            Label("Empty — ready to restore", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(state.recordCount) records currently block restore", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                LabeledContent("Visits", value: "\(state.visits)")
                LabeledContent("Saved Places", value: "\(state.savedPlaces)")
                LabeledContent("Corrections", value: "\(state.corrections)")
                LabeledContent("Diagnostics", value: "\(state.diagnostics)")
                LabeledContent("Location callbacks", value: "\(state.locationEvents)")
            }
        }
    }
}

struct DataRecoverySettingsView: View {
    @Binding var importingJournal: Bool
    @Binding var importingBackup: Bool
    @Binding var backupURL: URL?
    @Binding var backupSummary: BackupPresentation?
    let creatingBackup: Bool
    let erasingData: Bool
    let createBackup: () -> Void
    let cancelBackup: () -> Void
    let eraseAllData: () -> Void
    let reloadGeneration: Int
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var destinationState: BackupDestinationState?
    @State private var destinationStateFailed = false

    var body: some View {
        Form {
            Section {
                Button { importingJournal = true } label: { Label("Import Journal CSV", systemImage: "square.and.arrow.down") }
                NavigationLink { JournalCompactionView() } label: {
                    SettingsHubRow(title: "Manage imported journal storage", detail: "Compact or remove imported CSV history", symbol: "arrow.triangle.2.circlepath")
                }
                    .accessibilityIdentifier("journal-storage-link")
                NavigationLink { ArchiveRepairView() } label: {
                    SettingsHubRow(title: "Review archive repairs", detail: "Imported runaway stays and eligible routine gaps", symbol: "bandage")
                }
                    .accessibilityIdentifier("archive-repair-link")
            } header: {
                Text("Import and repair")
            } footer: {
                Text("What happens here? Import adds new Journal rows; compaction and repair always preview their changes first.")
            }
            Section {
                Button { createBackup() } label: { Label("Create backup", systemImage: "externaldrive.badge.timemachine") }
                    .accessibilityIdentifier("create-backup").disabled(creatingBackup)
                if creatingBackup {
                    HStack { ProgressView(); Text("Preparing backup…").foregroundStyle(.secondary); Spacer(); Button("Cancel", action: cancelBackup) }
                        .accessibilityIdentifier("backup-progress")
                }
                if let backupURL, let backupSummary {
                    BackupCreatedSummary(summary: backupSummary)
                    ShareLink(item: backupURL) { Label("Save or share backup", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("share-backup")
                    Text("This is a temporary staging copy in LifeLog’s export area. It is eligible for cleanup after 24 hours, although iOS may remove it sooner. Save it through the share sheet to keep a copy in the destination you choose; LifeLog never deletes that saved copy.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Local backup")
            } footer: {
                Text("What is included? Your timeline, places, corrections, diagnostics, activity definitions, and portable preferences.")
            }
            Section {
                if let destinationState {
                    DestinationStateSummary(state: destinationState)
                } else if destinationStateFailed {
                    Label("Couldn’t check the restore destination", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    HStack { ProgressView(); Text("Checking destination…").foregroundStyle(.secondary) }
                }
                Button { importingBackup = true } label: { Label("Restore backup", systemImage: "arrow.clockwise.icloud") }
                    .accessibilityIdentifier("restore-backup")
                    .disabled(destinationState?.isEmpty != true)
                if destinationState?.isEmpty == false {
                    Text("Restore is unavailable until these five destination groups are empty.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Restore destination")
            } footer: {
                Text("What will Restore do? Replace an empty destination with the backup’s records and portable preferences.")
            }
            Section {
                Button(role: .destructive, action: eraseAllData) {
                    Label(destinationState?.recordCount == 0 ? "Erase all data" : "Erase \(destinationState?.recordCount ?? 0) records", systemImage: "trash")
                }
                    .accessibilityIdentifier("erase-all-data").disabled(erasingData || destinationState?.isEmpty != false)
                if erasingData { HStack { ProgressView(); Text("Erasing…").foregroundStyle(.secondary) } }
                if destinationState?.isEmpty == true {
                    Text("The restore destination is already empty.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("What will Erase remove? Visits, places, corrections, diagnostics, and location callbacks—not activity definitions or preferences.")
            }
        }
        .navigationTitle("Data & Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { clearStaleBackup() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clearStaleBackup() }
        }
        .task(id: reloadGeneration) {
            destinationStateFailed = false
            let actor = BackupExportActor(modelContainer: context.container)
            do {
                destinationState = try await actor.restoreDestinationState()
            } catch {
                destinationState = nil
                destinationStateFailed = true
            }
        }
    }

    private func clearStaleBackup() {
        guard let backupURL, !ExportFileStaging.isUsable(backupURL) else { return }
        self.backupURL = nil
        backupSummary = nil
    }
}

struct DiagnosticsSettingsView: View {
    @AppStorage(LocationDiagnostics.detailKey) private var detailedLocationDiagnostics = false
    let recorder: LocationRecorder

    var body: some View {
        Form {
            Section {
                Toggle("Detailed location diagnostics", isOn: $detailedLocationDiagnostics)
                    .onChange(of: detailedLocationDiagnostics) { _, enabled in LocationDiagnostics.isDetailed = enabled }
                    .accessibilityIdentifier("detailed-location-diagnostics")
            } header: {
                Text("Recording detail")
            } footer: {
                Text("When should I turn this on? Only while diagnosing a location problem; it records precise callbacks on this iPhone.")
            }
            Section {
                NavigationLink { DiagnosticsView(recorder: recorder) } label: { Label("Open diagnostics", systemImage: "stethoscope") }
            } footer: {
                Text("Where can I inspect a problem? Open Diagnostics for service history and the location journal.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("LifeLog") { LabeledContent("Version", value: appVersion) }
            Section("Privacy") {
                Text("Your timeline and imported activity are encrypted and stored locally. LifeLog does not sync them and has no analytics, advertising, third-party SDKs, or cloud account.")
                Text("To identify an unfamiliar public place, LifeLog sends the nearby coordinate to Apple Maps and stores only the returned suggestions on this device.")
                Text("Health and Motion access is read-only. LifeLog never writes to Apple Health.")
            }
            Section("Smart classification") {
                LabeledContent("On-device model", value: SmartActivityClassifier.availabilityDescription)
                Text("When available, Apple Intelligence classifies a public place label entirely on this iPhone. Coordinates and notes are never provided to the model.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

private func openAppleHealth() {
    guard let healthURL = URL(string: "x-apple-health://") else { return }
    UIApplication.shared.open(healthURL) { opened in if !opened { openAppSettings() } }
}

private func openAppSettings() {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(settingsURL)
}
