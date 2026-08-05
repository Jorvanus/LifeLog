import SwiftUI
import CoreLocation
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
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
                Section("Location logging") {
                    LabeledContent("Permission", value: permissionName)
                    Toggle("Background location logging", isOn: backgroundLoggingBinding)
                    if recorder.authorization == .notDetermined {
                        Button("Allow while using") { recorder.requestPermission() }
                    }
                    if recorder.authorization == .authorizedAlways || recorder.authorization == .authorizedWhenInUse {
                        Button("Refresh Current Location") { recorder.refreshCurrentLocation() }
                    }
                }
                Section {
                    if let currentLocation {
                        NavigationLink { VisitEditor(visit: currentLocation) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(currentLocation.needsCategorisation ? "Label Current Location" : "Edit Current Location")
                                    Text(currentLocation.displayPlaceName)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: currentLocation.needsCategorisation ? "flag.badge.ellipsis" : "location.fill")
                                    .foregroundStyle(currentLocation.needsCategorisation ? .orange : .blue)
                            }
                        }.accessibilityIdentifier("current-location-label")
                    }
                    NavigationLink { PlacesView(recorder: recorder) } label: {
                        LabeledContent {
                            Text("\(savedPlaces.count)")
                        } label: {
                            Label("Locations", systemImage: "house.and.flag.fill")
                        }
                    }.accessibilityIdentifier("saved-places-link")
                    NavigationLink { ActivitiesView() } label: {
                        Label("Activities", systemImage: "list.bullet.clipboard")
                    }.accessibilityIdentifier("activities-link")
                    NavigationLink { ActivityGroupsView() } label: {
                        Label("Groups", systemImage: "square.grid.2x2")
                    }.accessibilityIdentifier("activity-groups-link")
                } header: {
                    Text("Places")
                } footer: {
                    Text("Set locations as Home, Work, or another place. LifeLog will reuse the label, category, and activity whenever you return.")
                }
                Section {
                    LabeledContent("Apple Health", value: activityData.healthStatus)
                    LabeledContent("Motion Activity", value: activityData.motionStatus)
                    // Both sources are asked for on first run and collected from then
                    // on, so there is no connect button in the ordinary case. It
                    // appears only when Health is not connected, because that state
                    // used to be a dead end: the label said "Not connected" and
                    // nothing on the screen could do anything about it.
                    if activityData.healthStatus != "Connected"
                        && activityData.healthStatus != "Unavailable on this device" {
                        Button("Connect Apple Health") {
                            Task { await activityData.requestHealthAccess() }
                        }
                        .accessibilityIdentifier("connect-health")
                        Text("If no sheet appears, iOS has already asked. Open the Health app → Sharing → Apps → LifeLog to turn the categories back on.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if activityData.motionStatus == "Denied" || activityData.motionStatus == "Restricted" {
                        Text("Turn Motion & Fitness back on in the iPhone Settings app, under Privacy & Security.")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("data-access-denied")
                    }
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
                        LabeledContent("Last import", value: imported.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("iPhone & Apple Watch")
                } footer: {
                    Text("Collected automatically, in small batches, while you use LifeLog and when Apple Health has something new. Sleep, Apple Watch workouts, and Watch walking come from Apple Health. Walking, running, cycling, and vehicle travel come from the iPhone’s motion history, which the iPhone keeps for about a week — so LifeLog gathers it regularly rather than waiting to be asked.")
                }
                Section {
                    Toggle("Detailed location diagnostics", isOn: $detailedLocationDiagnostics)
                        .onChange(of: detailedLocationDiagnostics) { _, enabled in
                            LocationDiagnostics.isDetailed = enabled
                        }
                        .accessibilityIdentifier("detailed-location-diagnostics")
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Records why each location was merged, closed or renamed, and which places Apple Maps offered for it. That includes place names and distances — a detailed record of where you have been — so it stays on this iPhone, expires with the rest of Diagnostics, and is off unless you turn it on.")
                }
                Section {
                    LabeledContent("On-device model", value: SmartActivityClassifier.availabilityDescription)
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
                    LabeledContent("Version", value: appVersion)
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

    private var backgroundLoggingBinding: Binding<Bool> {
        Binding(
            get: { recorder.isBackgroundLoggingEnabled },
            set: { enabled in
                if enabled { recorder.enableBackgroundLogging() }
                else { recorder.disableBackgroundLogging() }
            }
        )
    }

    private var currentLocation: Visit? {
        visits.first { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored && $0.departure == nil }
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
