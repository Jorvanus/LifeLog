import SwiftUI
import CoreLocation
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Settings only needs the current recorded location; imported journal history
    // is intentionally kept out of this screen's query so controls stay responsive.
    @Query(filter: #Predicate<Visit> { $0.source == "automatic" || $0.source == "manual" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]
    @Query(sort: \DiagnosticEvent.createdAt, order: .reverse) private var diagnostics: [DiagnosticEvent]
    @State private var importingJournal = false
    @State private var importingBackup = false
    @State private var backupURL: URL?
    @State private var importMessage: String?
    @AppStorage(LocationDiagnostics.detailKey) private var detailedLocationDiagnostics = false
    let recorder: LocationRecorder
    let activityData: ActivityDataService
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    locationLoggingControls
                } header: {
                    Text("Location logging")
                } footer: {
                    Text(locationLoggingExplanation)
                }
                Section {
                    // "Edit Current Location" lived here and opened `VisitEditor` on the
                    // open stay — the same editor, on the same visit, that tapping the
                    // current activity card on Timeline opens. Timeline is where the
                    // current activity is already in front of you, and it surfaces an
                    // uncategorised one more plainly besides, with its own card and the
                    // review queue. Settings is for places you have saved, not for the
                    // visit happening now.
                    NavigationLink { PlacesView(recorder: recorder) } label: {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Locations", systemImage: "house.and.flag.fill")
                                Text("\(savedPlaces.count)").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LabeledContent {
                                Text("\(savedPlaces.count)")
                            } label: {
                                Label("Locations", systemImage: "house.and.flag.fill")
                            }
                        }
                    }.accessibilityIdentifier("saved-places-link")
                    // "Activity Labels", not "Activities": the Activities tab reports on
                    // how much you do each thing, while this edits the vocabulary — the
                    // names, groups and icons. Two screens called the same thing, showing
                    // different lists, read as one of them being wrong.
                    NavigationLink { ActivitiesView() } label: {
                        Label("Activity Labels", systemImage: "list.bullet.clipboard")
                    }.accessibilityIdentifier("activities-link")
                    NavigationLink { ActivityGroupsView() } label: {
                        Label("Groups", systemImage: "square.grid.2x2")
                    }.accessibilityIdentifier("activity-groups-link")
                } header: {
                    Text("Places")
                } footer: {
                    Text("Save places with a label, category, and activity. LifeLog will reuse those details whenever you return.")
                }
                Section {
                    appleHealthControls
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Reads sleep, Apple Watch workouts, workout routes, and steps. LifeLog never writes to Apple Health.")
                }
                Section {
                    motionActivityControls
                } header: {
                    Text("Motion Activity")
                } footer: {
                    Text("Reads the iPhone’s walking, running, cycling, and vehicle history. The iPhone retains roughly one week, so LifeLog collects it regularly.")
                }
                Section {
                    if let progress = activityData.importProgress {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(progress.title).font(.subheadline.weight(.medium))
                                Spacer()
                                if progress.total > 0 {
                                    Text("\(Int((progress.fraction * 100).rounded()))%")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            if progress.isActive {
                                if progress.total > 0 {
                                    ProgressView(value: progress.fraction)
                                } else {
                                    ProgressView()
                                }
                                if progress.total > 0 {
                                    Text("\(progress.completed) of \(progress.total) activity records processed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if progress.state != .cancelling {
                                    Button("Cancel Import", role: .destructive) { activityData.cancelImport() }
                                        .accessibilityIdentifier("cancel-activity-import")
                                }
                            } else {
                                Label(progress.title, systemImage: progress.state == .complete
                                      ? "checkmark.circle.fill" : "info.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(progress.state == .complete ? Color.green : Color.gray)
                            }
                        }
                        .accessibilityIdentifier("activity-import-progress")
                    }
                    if let imported = activityData.lastImport {
                        adaptiveValue("Last import", value: imported.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Activity imports")
                }
                Section {
                    adaptiveToggle("Detailed location diagnostics", isOn: $detailedLocationDiagnostics)
                        .onChange(of: detailedLocationDiagnostics) { _, enabled in
                            LocationDiagnostics.isDetailed = enabled
                        }
                        .accessibilityIdentifier("detailed-location-diagnostics")
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Records why each location was merged, closed or renamed, which places Apple Maps offered for it, and a journal of the raw Core Location callbacks behind them — including their coordinates and accuracy. That is a precise record of where you have been, so it stays on this iPhone, is trimmed like the rest of Diagnostics, and is off unless you turn it on. The journal is under Diagnostics, where it can also be emptied.")
                }
                Section {
                    adaptiveValue("On-device model", value: SmartActivityClassifier.availabilityDescription)
                } header: {
                    Text("Smart classification")
                } footer: {
                    Text("When available, Apple Intelligence classifies a public place label into an activity entirely on this iPhone. Coordinates and notes are never provided to the model.")
                }
                Section("Privacy") {
                    Text("Your timeline and imported activity are encrypted and stored locally. LifeLog does not sync them, and has no analytics, advertising, third-party SDKs, or cloud account. iOS may include app data in your encrypted device backup.")
                    Text("To identify an unfamiliar public place, LifeLog sends the nearby coordinate to Apple Maps and stores only the returned suggestions on this device.")
                    Text("Health and Motion access is read-only. LifeLog never writes to Apple Health.")
                }
                Section {
                    Button {
                        importingJournal = true
                    } label: {
                        Label("Import Journal CSV", systemImage: "square.and.arrow.down")
                    }
                    Text("Imports Life Cycle CSV exports on this iPhone. Existing imported rows are skipped when you import the same file again.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { JournalCompactionView() } label: { Label("Manage imported journal storage", systemImage: "arrow.triangle.2.circlepath") }
                        .accessibilityIdentifier("journal-storage-link")
                } header: {
                    Text("Data import")
                }
                Section("Local backup") {
                    Button {
                        ExportFileCleanup.removeExpired()
                        do {
                            let data = try LocalBackupService.makeBackup(context: context, diagnostics: diagnostics)
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeLog-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
                            try data.write(to: url, options: .atomic)
                            backupURL = url
                        } catch { importMessage = "LifeLog couldn’t create a backup." }
                    } label: { Label("Create backup", systemImage: "externaldrive.badge.timemachine") }
                        .accessibilityIdentifier("create-backup")
                    if let backupURL {
                        ShareLink(item: backupURL) { Label("Share backup", systemImage: "square.and.arrow.up") }
                    }
                    Button { importingBackup = true } label: { Label("Restore backup", systemImage: "arrow.clockwise.icloud") }
                    Text("Backups include visits, Saved Places, corrections, ignored state, activities, category colours, and LifeLog preferences. Restore into an empty store for a complete replacement.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = recorder.lastError ?? activityData.lastError { Section("Last issue") { Text(error) } }
                Section {
                    NavigationLink { DiagnosticsView() } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("diagnostics-link")
                } footer: {
                    Text("View service timing and failure diagnostics in a separate screen.")
                }
                Section("About") {
                    adaptiveValue("Version", value: appVersion)
                }
            }.navigationTitle("Settings").accessibilityIdentifier("settings-screen")
                .task { ActivityCatalog.seed() }
                .fileImporter(isPresented: $importingJournal,
                              allowedContentTypes: [.commaSeparatedText, .text],
                              allowsMultipleSelection: false) { result in
                    importJournal(result)
                }
                .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    do {
                        guard let url = try result.get().first else { return }
                        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        try LocalBackupService.restore(Data(contentsOf: url), into: context)
                        importMessage = "Backup restored. Restart LifeLog to refresh all screens."
                    } catch { importMessage = "LifeLog couldn’t restore that backup. No changes were applied if validation failed." }
                }
                .alert("Journal import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK", role: .cancel) { importMessage = nil }
                } message: {
                    Text(importMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var locationLoggingControls: some View {
        switch recorder.authorization {
        case .notDetermined:
            Button {
                recorder.requestPermission()
            } label: {
                Label("Enable location logging", systemImage: "location.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("enable-location-logging")

        case .authorizedWhenInUse, .authorizedAlways:
            adaptiveValue("Location access", value: permissionName)
            adaptiveToggle("Background location logging", isOn: backgroundLoggingBinding)
            Button("Refresh current location") { recorder.refreshCurrentLocation() }

        case .denied:
            adaptiveValue("Location access", value: permissionName)
            Button(action: openAppSettings) {
                Label("Open iPhone Settings", systemImage: "gear")
            }
            .accessibilityIdentifier("open-location-settings")

        case .restricted:
            adaptiveValue("Location access", value: permissionName)

        @unknown default:
            adaptiveValue("Location access", value: permissionName)
        }
    }

    private var locationLoggingExplanation: String {
        switch recorder.authorization {
        case .notDetermined:
            "LifeLog first asks to use your location while the app is open. Background recording remains off until you choose it separately."
        case .authorizedWhenInUse where recorder.isBackgroundLoggingEnabled:
            "Background visits require Always Location access. LifeLog has requested it; if iOS does not offer the upgrade, open iPhone Settings → Privacy & Security → Location Services → LifeLog."
        case .authorizedWhenInUse:
            "LifeLog can refresh while it is open. Turn on background logging to record arrivals and departures when the app is not open; iOS will then ask for Always Location access."
        case .authorizedAlways:
            "Always Location access lets background logging record arrivals and departures when LifeLog is not open. Turn the switch off whenever you want foreground-only location use."
        case .denied:
            "Location access is off. Open iPhone Settings to allow it before LifeLog can identify where visits happened."
        case .restricted:
            "Location access is restricted by this iPhone’s settings and cannot be enabled from LifeLog."
        @unknown default:
            "Location access controls whether LifeLog can identify where visits happened."
        }
    }

    @ViewBuilder
    private var appleHealthControls: some View {
        adaptiveValue("Status", value: activityData.healthStatus)
        if !activityData.unaskedHealthTypes.isEmpty {
            Button("Connect Apple Health") {
                Task { await activityData.requestHealthAccess() }
            }
            .accessibilityIdentifier("connect-health")
            Text("Not yet asked for: \(activityData.unaskedHealthTypes.formatted(.list(type: .and))). Only these appear on the permission sheet — iOS does not re-ask for the rest.")
                .font(.caption).foregroundStyle(.secondary)
        } else if activityData.healthStatus != "Connected"
                    && activityData.healthStatus != "Unavailable on this device" {
            Button("Open Apple Health") { openAppleHealth() }
                .accessibilityIdentifier("open-health")
            Text("In Health, go to Sharing → Apps → LifeLog to review what LifeLog can read.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !activityData.isImporting {
            Button("Re-import Health history") { activityData.reimportHealthHistory() }
                .accessibilityIdentifier("reimport-health")
            Text("Reads the last 30 days again. Use it after granting Workout Routes to add paths to walks already imported without one; existing entries are updated, not duplicated.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var motionActivityControls: some View {
        adaptiveValue("Status", value: activityData.motionStatus)
        switch activityData.motionStatus {
        case "Not requested":
            Button("Enable Motion Activity") { activityData.requestMotionAccess() }
                .accessibilityIdentifier("enable-motion-activity")
            Text("iOS asks when LifeLog first reads this history.")
                .font(.caption).foregroundStyle(.secondary)
        case "Denied":
            Button("Open iPhone Settings") { openAppSettings() }
                .accessibilityIdentifier("open-motion-settings")
            Text("Turn on Motion & Fitness for LifeLog in iPhone Settings before it can add movement to your timeline.")
                .font(.caption).foregroundStyle(.secondary)
        case "Restricted":
            Text("Motion & Fitness is restricted by this iPhone’s settings and cannot be enabled from LifeLog.")
                .font(.caption).foregroundStyle(.secondary)
        case "Connected":
            if !activityData.isImporting {
                Button("Refresh Motion Activity") { activityData.refreshMotionHistory() }
                    .accessibilityIdentifier("refresh-motion-activity")
            }
        default:
            Text("Motion Activity status is unavailable right now. Try reopening LifeLog or check iPhone Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openAppleHealth() {
        guard let healthURL = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(healthURL) { opened in
            if !opened { openAppSettings() }
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    @ViewBuilder
    private func adaptiveValue(_ label: String, value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                Text(value).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent(label, value: value)
        }
    }

    @ViewBuilder
    private func adaptiveToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                Toggle(label, isOn: isOn)
                    .labelsHidden()
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .accessibilityLabel(label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Toggle(label, isOn: isOn)
        }
    }

    private var backgroundLoggingBinding: Binding<Bool> {
        Binding(
            get: { recorder.isBackgroundLoggingEnabled },
            set: { enabled in
                if enabled { recorder.enableBackgroundLogging() }
                else { recorder.disableBackgroundLogging() }
            }
        )
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

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func importJournal(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let summary = try JournalCSVImporter.importData(data, into: context)
            importMessage = "Imported \(summary.inserted) of \(summary.rows) journal entries. \(summary.skipped) duplicates skipped and \(summary.malformed) malformed rows ignored."
        } catch {
            importMessage = "LifeLog couldn’t import that file. Choose a Life Cycle CSV export and try again."
        }
    }
}
