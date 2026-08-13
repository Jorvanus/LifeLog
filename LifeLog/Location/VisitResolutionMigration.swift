import Foundation
import SwiftData

/// Converts the legacy `IgnoredLocations` UserDefaults registry onto each
/// matching `Visit`'s own persisted `resolutionState`, once, immediately after
/// the store opens — while the row identity the legacy keys were recorded
/// against can still be found in this store (see
/// `IgnoredLocations.stableURIFragment`; matching compares that fragment, not
/// the raw key text, since the key's own volatile pointer prefix never matches
/// between two separate reads regardless of migration).
///
/// This is deliberately not part of the V8→V9 schema migration itself. The
/// migration plan's `didMigrate` only has a `ModelContext` to work with, no
/// access to `UserDefaults`, and — more importantly — no guarantee it runs
/// exactly once per legacy key the way this does: a migration stage runs once
/// per store, but a store can be reopened many times before this conversion
/// has ever had the chance to run (a crash, a killed launch), so the two are
/// kept as separate, separately-idempotent steps.
enum VisitResolutionMigration {
    private static let convertedFlagKey = "LifeLog.IgnoredLocations.convertedToResolutionState.v1"

    /// Idempotent by construction, not merely by the flag: converting the same
    /// visit twice only writes `.ignored` twice, and a visit matching no legacy
    /// key is left untouched. The flag exists purely to skip the fetch-and-scan
    /// on every ordinary launch once there is nothing left to convert.
    @discardableResult
    @MainActor
    static func convertLegacyIgnoredKeysIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) throws -> Int {
        guard !defaults.bool(forKey: convertedFlagKey) else { return 0 }
        let legacyKeys = IgnoredLocations.storedKeys(defaults: defaults)
        guard !legacyKeys.isEmpty else {
            defaults.set(true, forKey: convertedFlagKey)
            return 0
        }
        // Compared as fragments, not whole strings — see `stableURIFragment`.
        let legacyFragments = Set(legacyKeys.compactMap(IgnoredLocations.stableURIFragment))
        let visits = try context.fetch(FetchDescriptor<Visit>())
        var converted = 0
        for visit in visits {
            let ownFragment = IgnoredLocations.stableURIFragment(IgnoredLocations.legacyStableKey(for: visit))
            let matchesStable = ownFragment.map(legacyFragments.contains) ?? false
            guard matchesStable || legacyKeys.contains(IgnoredLocations.legacyCoordinateKey(for: visit)) else { continue }
            // A person's own prior decision, carried forward — not automation
            // discovering a reason to ignore something, so this uses the actor
            // that is allowed to set `.ignored`.
            if visit.setResolutionState(.ignored, actor: .user) { converted += 1 }
        }
        if context.hasChanges { try context.save() }
        IgnoredLocations.removeAll(defaults: defaults)
        defaults.set(true, forKey: convertedFlagKey)
        return converted
    }
}
