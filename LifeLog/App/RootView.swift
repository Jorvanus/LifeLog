import SwiftUI
import SwiftData
import UIKit

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
    /// Set at tab selection, not when Timeline disappeared: the latter measures how
    /// long the person was reading Settings rather than how long Timeline took back.
    @State private var timelineReturnStartedAt: Date?
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
    /// Deep links exist only for UI tests so long, accessibility-sized Settings forms
    /// can exercise their lower-level screens without coordinate-based taps.
    @State private var uiTestDestination: UITestDestination? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-diagnostics") { return .diagnostics }
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-journal-storage") { return .journalStorage }
        if arguments.contains("-uiTesting"), arguments.contains("-ui-test-open-archive-repair") { return .archiveRepair }
        return nil
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Timeline", systemImage: "clock", value: 0) {
                TimelineView(recorder: recorder, returnStartedAt: $timelineReturnStartedAt)
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
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { timelineReturnStartedAt = .now }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                activityData.refreshAutomatically()
                // Health access can be changed in the Health app while LifeLog is in the
                // background, and the import throttle above can skip a launch entirely.
                // Re-reading the status on every activation is what keeps Settings from
                // showing a stale "Not connected".
                Task { await activityData.refreshHealthStatus() }
            case .background:
                // Nothing else in Diagnostics can say what happens after this: if the
                // process is killed from here, by the system or by the person, the next
                // line in the log is whatever eventually relaunches it, with no record of
                // the gap between. Background App Refresh and Low Power Mode are the two
                // settings that silently stop Core Location from relaunching the app on
                // its own, so this is the one moment to write them down.
                Diagnostics.record(context, subsystem: "Launch",
                                   message: "Entered background; Background App Refresh "
                                          + "\(backgroundRefreshDescription), Low Power Mode "
                                          + "\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off").",
                                   severity: "info")
            default:
                break
            }
        }
        .accessibilityIdentifier("root-tab-view")
        .task {
            ExportFileCleanup.removeExpired()
            // Whatever a background save could not record about itself is written here,
            // where the store has just opened and is known to be accepting writes.
            Diagnostics.flushPending(context)
            // V10 deliberately links old activity labels in small pages. Launch must
            // remain responsive even when an older timeline contains years of visits;
            // later launches continue from the remaining unlinked snapshots.
            do {
                let activityMigration = try ActivityIdentityMigration.backfillNextBatch(context: context)
                if activityMigration.adoptedDefinitions > 0 || activityMigration.linkedVisits > 0 || activityMigration.linkedPlaces > 0 {
                    Diagnostics.record(context, subsystem: "Activities",
                                       message: "Adopted \(activityMigration.adoptedDefinitions) activity definitions; linked \(activityMigration.linkedVisits) visits and \(activityMigration.linkedPlaces) Saved Places\(activityMigration.hasMore ? "; more history remains." : ".")",
                                       severity: "info")
                }
            } catch {
                // Identity linking is an optimisation/migration aid, never a reason
                // to block the Timeline from opening with its original label snapshots.
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Activity identity migration will retry: \(error.localizedDescription)",
                                   severity: "warning")
            }
            // One-time, off the main actor, so a large backlog cannot delay this
            // `.task` or the interaction budget that follows it — see
            // `ActivityLinkingCatchUp`'s own doc comment for why this exists
            // alongside the paged migration above rather than replacing it.
            Task {
                if let linked = try? await ActivityLinkingCatchUp.runIfNeeded(modelContainer: modelContainer),
                   linked > 0 {
                    await MainActor.run {
                        Diagnostics.record(context, subsystem: "Activities",
                                           message: "Linked \(linked) visits and Saved Places to the catalogue in one pass.",
                                           severity: "info")
                    }
                }
            }
            // The one place this runs unconditionally at launch. Without it, nothing
            // ever persists the seeded catalogue to UserDefaults until the person
            // happens to visit Settings → Activities, the place-activity picker, or
            // Settings' own `.task` — and until one of those runs, `ActivityCatalog
            // .load()`'s empty-storage fallback rebuilds `defaults` fresh on every
            // call, each with new random `ActivityDefinition.id`s. Any code that
            // captures an ID from one `load()` and looks it up in a later `load()`
            // (editing, merging) silently fails to find it in that window — this is
            // what made a same-session Activities-tab edit look like it "reverted."
            ActivityCatalog.seed()
            // Needs a context, so it cannot live in `seed()` alongside the other
            // catalogue setup — the visits holding the old wording move with it.
            if let moved = try? ActivityCatalog.mergeWorkingIntoWork(context: context), moved > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Renamed the seeded Working label to Work across \(moved) visits.",
                                   severity: "info")
            }
            if let moved = try? ActivityCatalog.mergeHomeTimeIntoAtHome(context: context), moved > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Renamed the seeded Home time label to At home across \(moved) visits.",
                                   severity: "info")
            }
            // Same reason as the two merges above: needs a context. Insights is only
            // invalidated when this actually adopted something, which is once.
            if let adopted = try? ActivityCatalog.adoptHistoryLabels(context: context), adopted > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Adopted \(adopted) labels from recorded history into the activity catalogue.",
                                   severity: "info")
                InsightsInvalidation.invalidate(reason: "History labels adopted", context: context)
            }
            let startedAt = Date.now
            recorder.connect(context)
            activityData.connect(context, container: modelContainer)
            // Core Motion discards history about a week old, so it is collected
            // whenever LifeLog runs rather than only when Settings is visited.
            activityData.refreshAutomatically()
            // One record of one measurement. `budget` below reports this same elapsed
            // time on every launch, so a `performance` sample from the same `startedAt`
            // only added a second row — and a contradictory one, calling 150 ms "Slow"
            // beside a "pass" against the 250 ms budget.
            Diagnostics.budget(context, subsystem: "Launch", operation: "responsive first screen",
                               startedAt: startedAt,
                               budget: Diagnostics.PerformanceBudget.responsiveFirstScreen)
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

    private var backgroundRefreshDescription: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }
}
