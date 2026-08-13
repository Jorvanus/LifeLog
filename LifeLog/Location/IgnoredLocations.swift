import Foundation
import SwiftData

/// The legacy home for ignore state, before the V9 migration gave every `Visit`
/// its own persisted `resolutionState`. Kept only as the source
/// `VisitResolutionMigration`'s one-time conversion reads from: a key built from
/// `String(describing: persistentModelID)` was never portable through backup and
/// restore, since restoring rebuilds the store with entirely new identifiers —
/// which is exactly why a restored store silently forgot every ignored visit.
enum IgnoredLocations {
    private static let storageKey = "LifeLog.IgnoredLocations.v1"

    static func storedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    /// Retained for `LocalBackupService`: an old backup's `ignoredVisitKeys`
    /// still decode, and importing them here lets `VisitResolutionMigration`
    /// convert them on the very next store open exactly as it would a key
    /// written by this device.
    static func exportKeys(defaults: UserDefaults = .standard) -> [String] {
        Array(storedKeys(defaults: defaults))
    }
    static func importKeys(_ keys: [String], defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: storageKey)
    }

    /// SwiftData assigns this identifier from the store's own row identity, which
    /// a `.custom` migration preserves in place — so immediately after the V8→V9
    /// migration, before anything else touches the store, it still matches what
    /// was recorded against the same row before the schema changed.
    ///
    /// The full description is not itself stable, though the row identity inside
    /// it is: `String(describing:)` on a `PersistentIdentifier` also embeds the
    /// underlying `NSManagedObjectID`'s in-memory pointer, which is different on
    /// every fetch — confirmed by direct testing to change across a plain reopen
    /// with no migration involved at all, let alone one that runs a stage. Only
    /// the `x-coredata://<store>/<entity>/p<n>` fragment inside the parentheses
    /// is the part that survives, which is why matching goes through
    /// `stableURIFragment` rather than comparing this whole string.
    static func legacyStableKey(for visit: Visit) -> String {
        "persistent:\(String(describing: visit.persistentModelID))"
    }

    /// Pulls the `<x-coredata://...>` fragment out of a key built by
    /// `legacyStableKey`, on either side of a comparison — the already-stored
    /// legacy text and a freshly computed one are both full descriptions, and
    /// only this fragment is safe to compare between them.
    static func stableURIFragment(_ key: String) -> String? {
        guard let start = key.firstIndex(of: "<"), let end = key.firstIndex(of: ">"), start < end else { return nil }
        return String(key[start...end])
    }

    /// The key format used before `persistentModelID` became the identity —
    /// checked as a fallback so a visit ignored that far back, and never opened
    /// since (which would have healed it onto the stable key), still converts.
    static func legacyCoordinateKey(for visit: Visit) -> String {
        "\(visit.arrival.timeIntervalSinceReferenceDate)|\(visit.latitude)|\(visit.longitude)|\(visit.source)"
    }
}
