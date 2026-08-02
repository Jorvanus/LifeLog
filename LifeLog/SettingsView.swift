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
    @State private var importMessage: String?
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
                    NavigationLink { PlacesView() } label: {
                        LabeledContent {
                            Text("\(savedPlaces.count)")
                        } label: {
                            Label("Locations", systemImage: "house.and.flag.fill")
                        }
                    }.accessibilityIdentifier("saved-places-link")
                    NavigationLink { ActivitiesView() } label: {
                        Label("Activities", systemImage: "list.bullet.clipboard")
                    }.accessibilityIdentifier("activities-link")
                } header: {
                    Text("Places")
                } footer: {
                    Text("Set locations as Home, Work, or another place. LifeLog will reuse the label, category, and activity whenever you return.")
                }
                Section {
                    LabeledContent("Apple Health", value: activityData.healthStatus)
                    Button("Connect Apple Health") { activityData.requestHealthAccess() }
                    LabeledContent("Motion Activity", value: activityData.motionStatus)
                    Button("Connect Walking & Travel") { activityData.requestMotionAccess() }
                    Button("Import Recent Activity") { activityData.importAll() }
                    if let imported = activityData.lastImport {
                        LabeledContent("Last import", value: imported.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("iPhone & Apple Watch")
                } footer: {
                    Text("Sleep, Apple Watch workouts, and Watch walking come from Apple Health. Walking, running, cycling, and vehicle travel also use the iPhone’s motion history. iOS has no dedicated airplane signal; flight-labelled records are still grouped under Travel.")
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
                if let error = recorder.lastError ?? activityData.lastError { Section("Last issue") { Text(error) } }
                Section {
                    if diagnostics.isEmpty {
                        Text("No diagnostic events recorded.").foregroundStyle(.secondary)
                    } else {
                        ForEach(diagnostics.prefix(10)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.subsystem).font(.caption.bold())
                                    Spacer()
                                    Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(event.message).font(.footnote)
                            }
                        }
                        Button("Clear Diagnostics", role: .destructive) { clearDiagnostics() }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Diagnostics contain generic service timing and failure messages only. Precise locations and Health data are never recorded here.")
                }
                Section {
                    Button {
                        importingJournal = true
                    } label: {
                        Label("Import Journal CSV", systemImage: "square.and.arrow.down")
                    }
                    Text("Imports Life Cycle CSV exports on this iPhone. Existing imported rows are skipped when you import the same file again.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Data import")
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

    private func clearDiagnostics() {
        for event in diagnostics { context.delete(event) }
        try? context.save()
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
