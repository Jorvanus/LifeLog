import Foundation
import SwiftData

/// Finishes linking every already-existing visit and Saved Place to its
/// catalogue activity in one pass, the first launch after this shipped —
/// instead of waiting for `ActivityCatalog.backfillNextBatch`'s paged,
/// 500-row-per-launch migration to work through years of backlog.
///
/// This used to be a step on the archive repair screen ("Link activities to
/// the catalogue"), but it never belonged there: unlike every other step in
/// `ArchiveRepair`, it was never fixing damage the CSV import left behind — it
/// is the exact same job `backfillNextBatch` already does automatically, every
/// launch, for every visit regardless of source. The only thing worth a
/// one-time push is clearing the *existing* backlog faster than the paged
/// migration would on its own; `backfillNextBatch` staying in place afterwards
/// is what keeps this true forever, for the small trickle of genuinely new
/// visits and for any future large import that recreates a backlog.
///
/// Runs off the main actor, unlike `backfillNextBatch` (which runs directly in
/// `RootView`'s `.task`) — that method is deliberately bounded to 500 rows
/// specifically so it stays cheap enough for the main actor; an unbounded pass
/// over years of backlog has no such guarantee and must not risk the
/// responsive-launch budget the way running it synchronously would.
@ModelActor
actor ActivityLinkingCatchUp {
    private static let caughtUpFlagKey = "LifeLog.ActivityIdentityMigration.linkedAllAtOnce.v1"

    /// Idempotent by the flag, not merely by there being nothing left to link:
    /// once this has run, it never runs again, so a rescan finding zero rows on
    /// a later launch is not mistaken for "still needs to catch up."
    @discardableResult
    static func runIfNeeded(modelContainer: ModelContainer, defaults: UserDefaults = .standard) async throws -> Int {
        guard !defaults.bool(forKey: caughtUpFlagKey) else { return 0 }
        let actor = ActivityLinkingCatchUp(modelContainer: modelContainer)
        let linked = try await actor.run()
        defaults.set(true, forKey: caughtUpFlagKey)
        return linked
    }

    /// A restore replaces the archive the one-time flag describes. Run the same
    /// complete pass again after that restore commits, even if this device linked a
    /// previous archive long ago.
    @discardableResult
    static func runAfterRestore(modelContainer: ModelContainer,
                                defaults: UserDefaults = .standard) async throws -> Int {
        let actor = ActivityLinkingCatchUp(modelContainer: modelContainer)
        let linked = try await actor.run()
        defaults.set(true, forKey: caughtUpFlagKey)
        return linked
    }

    private func run() throws -> Int {
        let linked = try ActivityIdentityMigration.linkAll(context: modelContext)
        if modelContext.hasChanges { try modelContext.save() }
        return linked
    }
}
