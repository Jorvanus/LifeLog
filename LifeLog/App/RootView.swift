import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    let modelContainer: ModelContainer
    @State private var recorder = LocationRecorder()
    @State private var activityData = ActivityDataService()
    @Environment(\.scenePhase) private var scenePhase
    /// Opens straight to a tab, so a screen can be inspected without driving the tab
    /// bar. `-showInsights` predates this and still works; `-showTab N` reaches any of
    /// them, which is what checking layout at accessibility sizes needs — the live
    /// simulator panel does not run on this machine's Xcode beta, so screens have to be
    /// reachable from a launch argument to be screenshotted at all.
    @State private var selectedTab: Int = {
        if ProcessInfo.processInfo.arguments.contains("-showInsights") { return 1 }
        let requested = UserDefaults.standard.integer(forKey: "showTab")
        return (0...3).contains(requested) ? requested : 0
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Timeline", systemImage: "clock", value: 0) {
                TimelineView(recorder: recorder)
            }
            // Next to Timeline: both are readings of the same days, one as it happened
            // and one totalled up, so they are what a person moves between.
            Tab("Insights", systemImage: "chart.bar.xaxis", value: 1) {
                InsightsView(activityData: activityData)
            }
            Tab("Activities", systemImage: "list.bullet.rectangle", value: 2) {
                ActivitiesTabView()
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
            // Whatever a background save could not record about itself is written here,
            // where the store has just opened and is known to be accepting writes.
            Diagnostics.flushPending(context)
            // Needs a context, so it cannot live in `seed()` alongside the other
            // catalogue setup — the visits holding the old wording move with it.
            if let moved = try? ActivityCatalog.mergeWorkingIntoWork(context: context), moved > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Renamed the seeded Working label to Work across \(moved) visits.",
                                   severity: "info")
            }
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
