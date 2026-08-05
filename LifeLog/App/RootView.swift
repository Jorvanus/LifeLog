import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    let modelContainer: ModelContainer
    @State private var recorder = LocationRecorder()
    @State private var activityData = ActivityDataService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("-showInsights") ? 2 : 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Timeline", systemImage: "clock", value: 0) {
                TimelineView(recorder: recorder)
            }
            Tab("Activities", systemImage: "list.bullet.rectangle", value: 1) {
                ActivitiesTabView()
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: 2) {
                TrendsView(activityData: activityData)
            }
            Tab("Settings", systemImage: "gear", value: 3) {
                SettingsView(recorder: recorder, activityData: activityData)
            }
        }
        .tint(.blue)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            activityData.refreshAutomatically()
            // Health access can be changed in the Health app while LifeLog is in the
            // background, and the import throttle above can skip a launch entirely.
            // Re-reading the status on every activation is what keeps Settings from
            // showing a stale "Not connected".
            Task { await activityData.refreshHealthStatus() }
        }
        .accessibilityIdentifier("root-tab-view")
        .task {
            ExportFileCleanup.removeExpired()
            let startedAt = Date.now
            recorder.connect(context)
            activityData.connect(context, container: modelContainer)
            // Core Motion discards history about a week old, so it is collected
            // whenever LifeLog runs rather than only when Settings is visited.
            activityData.refreshAutomatically()
            Diagnostics.performance(context, subsystem: "Launch", operation: "service setup",
                                    startedAt: startedAt, threshold: 0.1)
            Diagnostics.budget(context, subsystem: "Launch", operation: "responsive first screen",
                               startedAt: startedAt,
                               budget: Diagnostics.PerformanceBudget.responsiveFirstScreen)
        }
    }
}
