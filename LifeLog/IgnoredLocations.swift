import Foundation

/// Ignore state is deliberately kept outside SwiftData so adding this feature
/// does not require migrating the user's protected Visit store.
enum IgnoredLocations {
    private static let storageKey = "LifeLog.IgnoredLocations.v1"

    static func contains(_ visit: Visit) -> Bool {
        storedKeys.contains(key(for: visit))
    }

    static func setIgnored(_ ignored: Bool, for visit: Visit) {
        var keys = storedKeys
        let visitKey = key(for: visit)
        if ignored { keys.insert(visitKey) } else { keys.remove(visitKey) }
        UserDefaults.standard.set(Array(keys), forKey: storageKey)
    }

    private static var storedKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    private static func key(for visit: Visit) -> String {
        "\(visit.arrival.timeIntervalSinceReferenceDate)|\(visit.latitude)|\(visit.longitude)|\(visit.source)"
    }
}

extension Visit {
    var isIgnored: Bool {
        get { IgnoredLocations.contains(self) }
        set { IgnoredLocations.setIgnored(newValue, for: self) }
    }
}
