import SwiftUI
import SwiftData

struct RootView: View {
    private enum UITestDestination: String, Identifiable {
        case diagnostics
        case journalStorage
        case archiveRepair
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    let modelContainer: ModelContainer
    @State private var recorder = LocationRecorder()
    @State private var activityData = ActivityDataService()
    @State private var lifecycle = AppLifecycleCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Opens straight to a tab, so a screen can be inspected without driving the tab
    /// bar. `-showInsights` predates this and still works; `-showTab N` reaches any of
    /// them, which is what checking layout at accessibility sizes needs — the live
    /// simulator panel does not run on this machine's Xcode beta, so screens have to be
    /// reachable from a launch argument to be screenshotted at all.
    @State private var selectedTab: Int = {
        if InternalLaunchArguments.contains("-showInsights") { return 1 }
        let requested = UserDefaults.standard.integer(forKey: "showTab")
        return (0...3).contains(requested) ? requested : 0
    }()
    /// Deep links exist only for UI tests so long, accessibility-sized Settings forms
    /// can exercise their lower-level screens without coordinate-based taps.
    @State private var uiTestDestination: UITestDestination? = {
        let arguments = InternalLaunchArguments.all
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-diagnostics") { return .diagnostics }
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-journal-storage") { return .journalStorage }
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-archive-repair") { return .archiveRepair }
        return nil
    }()
    /// A UI test seeds or clears its own state and must never see a sheet it did not
    /// ask for; `RecordingObservation.startedAt()` is otherwise a reliable "has this
    /// install ever completed a real launch" signal, since it is written on every
    /// `startIfNeeded` and, unlike a dedicated flag, is already preserved across an
    /// upgrade or a restored backup rather than something this feature could forget.
    @State private var showOnboarding = !InternalLaunchArguments.contains("-uiTesting")
        && RecordingObservation.startedAt() == nil

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
            lifecycle.handleScenePhase(phase, context: context, activityData: activityData)
        }
        .accessibilityIdentifier("root-tab-view")
        .task {
            // Onboarding calls this itself once dismissed, so permission prompts wait
            // for LifeLog's own explanation instead of firing behind the welcome screen.
            guard !showOnboarding else { return }
            await lifecycle.startIfNeeded(context: context, modelContainer: modelContainer,
                                          recorder: recorder, activityData: activityData)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                Task {
                    await lifecycle.startIfNeeded(context: context, modelContainer: modelContainer,
                                                  recorder: recorder, activityData: activityData)
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $uiTestDestination) { destination in
            NavigationStack {
                switch destination {
                case .diagnostics: DiagnosticsView(recorder: recorder)
                case .journalStorage: JournalCompactionView()
                case .archiveRepair: ArchiveRepairView()
                }
            }
        }
    }
}
