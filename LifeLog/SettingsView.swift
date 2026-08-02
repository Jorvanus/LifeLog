import SwiftUI
import CoreLocation

struct SettingsView: View {
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
                }
                Section {
                    LabeledContent("Apple Health", value: activityData.healthStatus)
                    Button("Connect Sleep & Workouts") { activityData.requestHealthAccess() }
                    LabeledContent("Motion Activity", value: activityData.motionStatus)
                    Button("Connect Walking & Travel") { activityData.requestMotionAccess() }
                    Button("Import Recent Activity") { activityData.importAll() }
                    if let imported = activityData.lastImport {
                        LabeledContent("Last import", value: imported.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("iPhone & Apple Watch")
                } footer: {
                    Text("Sleep, Apple Watch workouts, and Watch walking come from Apple Health. Walking, running, cycling, and vehicle travel also use the iPhone’s motion history.")
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
            }.navigationTitle("Settings")
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
}
