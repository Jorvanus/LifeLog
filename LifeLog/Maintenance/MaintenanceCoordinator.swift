import Foundation
import Observation
import SwiftData

/// The only owner of versioned, store-wide repair work. Views may observe its
/// state, but never decide whether opening a screen should mutate the archive.
@MainActor @Observable
final class MaintenanceCoordinator {
    static let shared = MaintenanceCoordinator()

    enum Status: Equatable {
        case idle
        case running(phase: String)
        case complete
        case failed(message: String)
    }

    /// Bump this when a new archive-wide prerequisite is added. Completion is
    /// persisted only after the one transaction containing every prerequisite
    /// saves, so a protected-store failure always retries on a later launch.
    static let version = 14
    private static let completedVersionKey = "LifeLog.maintenance.completedVersion"

    private(set) var status: Status = .idle
    func runIfNeeded(context: ModelContext) async {
        guard UserDefaults.standard.integer(forKey: Self.completedVersionKey) < Self.version else {
            status = .complete
            return
        }
        await run(context: context)
    }

    /// A restored archive replaces the rows the completed marker described. It
    /// therefore must receive the current maintenance version before screens read it.
    func runAfterRestore(context: ModelContext) {
        UserDefaults.standard.removeObject(forKey: Self.completedVersionKey)
        Task { await run(context: context) }
    }

    /// Importers call this after their own save lands. This remains deliberately
    /// unversioned: it repairs only the imported lookback, while `runIfNeeded` owns
    /// the archive-wide migration work above.
    func reconcileRecentImport(context: ModelContext, lookback: TimeInterval) throws {
        status = .running(phase: "Reconciling recent activity")
        _ = try ActivityLocationPolicy.reapplyRecentMovementAbsorption(context: context, lookback: lookback)
        _ = try ActivityLocationPolicy.reapplyRecentJourneyTiming(context: context, lookback: lookback)
        _ = try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(context: context, lookback: lookback)
        try context.save()
        status = .complete
    }

    private func run(context: ModelContext) async {
        await Task.yield()
        do {
            status = .running(phase: "Preparing recorded places")
            _ = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
            _ = try ActivityLocationPolicy.rejoinStaysSplitByMovement(context: context)

            status = .running(phase: "Repairing recorded activity")
            _ = try WorkoutJourneys.repairSplitWorkouts(context: context)
            _ = try SleepSessionRepair.mergeDuplicates(context: context, save: false)

            status = .running(phase: "Reconciling travel")
            try ActivityLocationPolicy.reconcileAll(context: context)
            try ActivityLocationPolicy.updateTravelDescriptions(context: context)

            // Keep the ordering shared with post-import reconciliation: timing
            // depends on movement absorption seeing its untrimmed source first.
            _ = try ActivityLocationPolicy.reapplyRecentMovementAbsorption(context: context)
            _ = try ActivityLocationPolicy.reapplyRecentJourneyTiming(context: context)
            _ = try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(context: context)

            status = .running(phase: "Saving maintenance")
            Diagnostics.record(context, subsystem: "Maintenance",
                               message: "Completed archive maintenance v\(Self.version).", severity: "info")
            try context.save()
            UserDefaults.standard.set(Self.version, forKey: Self.completedVersionKey)
            status = .complete
        } catch is CancellationError {
            status = .idle
        } catch {
            context.rollback()
            status = .failed(message: error.localizedDescription)
            Diagnostics.record(context, subsystem: "Maintenance",
                               message: "Archive maintenance will retry: \(error.localizedDescription)", severity: "warning")
        }
    }
}
