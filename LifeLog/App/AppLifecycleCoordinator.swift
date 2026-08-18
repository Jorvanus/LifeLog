import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// Owns startup and scene-lifecycle work that needs an open store. RootView only
/// forwards lifecycle events; a tab appearing must never be what repairs the archive.
@MainActor @Observable
final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()

    enum Status: Equatable {
        case idle
        case starting
        case ready
    }

    private(set) var status: Status = .idle
    private var hasStarted = false

    func startIfNeeded(context: ModelContext, modelContainer: ModelContainer,
                       recorder: LocationRecorder, activityData: ActivityDataService) async {
        guard !hasStarted else { return }
        hasStarted = true
        status = .starting
        let startedAt = Date.now

        ExportFileCleanup.removeExpired()
        // A background operation cannot rely on being able to save its own diagnostic.
        // Flush its queued note at the first known-good store transaction instead.
        Diagnostics.flushPending(context)
        prepareActivityCatalogue(context: context, modelContainer: modelContainer)

        recorder.connect(context)
        activityData.connect(context, container: modelContainer)
        await MaintenanceCoordinator.shared.runIfNeeded(context: context)
        // Core Motion retains only a short history, so collection belongs to app
        // lifecycle rather than to a Settings screen being opened.
        activityData.refreshAutomatically()

        Diagnostics.budget(context, subsystem: "Launch", operation: "responsive first screen",
                           startedAt: startedAt,
                           budget: Diagnostics.PerformanceBudget.responsiveFirstScreen)
        status = .ready
    }

    func handleScenePhase(_ phase: ScenePhase, context: ModelContext,
                          activityData: ActivityDataService) {
        switch phase {
        case .active:
            activityData.refreshAutomatically()
            // Health access can change while LifeLog is backgrounded. Refreshing this
            // service state keeps the status hub current without a Settings-triggered read.
            Task { await activityData.refreshHealthStatus() }
        case .background:
            Diagnostics.record(context, subsystem: "Launch",
                               message: "Entered background; Background App Refresh "
                                      + "\(backgroundRefreshDescription), Low Power Mode "
                                      + "\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off").",
                               severity: "info")
        default:
            break
        }
    }

    private func prepareActivityCatalogue(context: ModelContext, modelContainer: ModelContainer) {
        // This bounded page retains the migration's gradual, launch-safe behaviour.
        do {
            let migration = try ActivityIdentityMigration.backfillNextBatch(context: context)
            if migration.adoptedDefinitions > 0 || migration.linkedVisits > 0 || migration.linkedPlaces > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Adopted \(migration.adoptedDefinitions) activity definitions; linked \(migration.linkedVisits) visits and \(migration.linkedPlaces) Saved Places\(migration.hasMore ? "; more history remains." : ".")",
                                   severity: "info")
            }
        } catch {
            Diagnostics.record(context, subsystem: "Activities",
                               message: "Activity identity migration will retry: \(error.localizedDescription)",
                               severity: "warning")
        }

        // The complete pass has its own model actor, so an old archive cannot consume
        // the first-screen interaction budget.
        Task {
            if let linked = try? await ActivityLinkingCatchUp.runIfNeeded(modelContainer: modelContainer), linked > 0 {
                Diagnostics.record(context, subsystem: "Activities",
                                   message: "Linked \(linked) visits and Saved Places to the catalogue in one pass.",
                                   severity: "info")
            }
        }

        ActivityCatalog.seed()
        if let moved = try? ActivityCatalog.mergeWorkingIntoWork(context: context), moved > 0 {
            Diagnostics.record(context, subsystem: "Activities",
                               message: "Renamed the seeded Working label to Work across \(moved) visits.", severity: "info")
        }
        if let moved = try? ActivityCatalog.mergeHomeTimeIntoAtHome(context: context), moved > 0 {
            Diagnostics.record(context, subsystem: "Activities",
                               message: "Renamed the seeded Home time label to At home across \(moved) visits.", severity: "info")
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
