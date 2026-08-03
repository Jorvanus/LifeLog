import Foundation
import SwiftData

/// Ignore state is deliberately kept outside SwiftData so adding this feature
/// does not require migrating the user's protected Visit store.
enum IgnoredLocations {
    private static let storageKey = "LifeLog.IgnoredLocations.v1"

    static func contains(_ visit: Visit) -> Bool {
        let stable = stableKey(for: visit)
        if storedKeys.contains(stable) { return true }
        // Preserve existing ignores while migrating from the old coordinate key.
        let legacy = legacyKey(for: visit)
        guard storedKeys.contains(legacy) else { return false }
        var keys = storedKeys
        keys.remove(legacy)
        keys.insert(stable)
        UserDefaults.standard.set(Array(keys), forKey: storageKey)
        return true
    }

    static func setIgnored(_ ignored: Bool, for visit: Visit) {
        var keys = storedKeys
        let visitKey = stableKey(for: visit)
        if ignored { keys.insert(visitKey) } else { keys.remove(visitKey) }
        UserDefaults.standard.set(Array(keys), forKey: storageKey)
    }

    private static var storedKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func exportKeys() -> [String] { Array(storedKeys) }
    static func importKeys(_ keys: [String]) { UserDefaults.standard.set(keys, forKey: storageKey) }

    /// SwiftData assigns this identifier independently of mutable visit fields,
    /// so edits to arrival time or coordinates cannot orphan an ignore state.
    private static func stableKey(for visit: Visit) -> String {
        "persistent:\(String(describing: visit.persistentModelID))"
    }

    private static func legacyKey(for visit: Visit) -> String {
        "\(visit.arrival.timeIntervalSinceReferenceDate)|\(visit.latitude)|\(visit.longitude)|\(visit.source)"
    }
}

extension Visit {
    var isIgnored: Bool {
        get { IgnoredLocations.contains(self) }
        set { IgnoredLocations.setIgnored(newValue, for: self) }
    }

    /// Derived from persisted source/confidence fields and the stable ignore
    /// registry, so resolution survives relaunch without another schema field.
    var resolutionState: VisitResolutionState {
        if isIgnored { return .ignored }
        if ActivityLocationPolicy.isSupersededLocation(self) { return .superseded }
        if source == "automatic" && (placeCategory == "Other" || recognitionConfidence == nil) {
            return .provisional
        }
        return .resolved
    }
}
