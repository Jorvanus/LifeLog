import Foundation

/// The point from which LifeLog can honestly describe time as unlogged.
///
/// A calendar period starts before a new installation exists, so treating the
/// whole period as missing data makes a fresh archive look broken. This marker
/// is local app state rather than a Visit: HealthKit can backfill older samples,
/// but that must not move the boundary backwards and manufacture historical gaps.
enum RecordingObservation {
    static let startedAtKey = "LifeLog.RecordingObservation.StartedAt"

    static func ensureStarted(now: Date = .now,
                              existingHistoryStart: Date? = nil,
                              defaults: UserDefaults = .standard) -> Date {
        if let startedAt = startedAt(defaults: defaults) {
            return startedAt
        }
        // An upgrade or backup restore can open an archive that predates this
        // marker. Preserve that archive's real beginning; only a genuinely empty
        // installation should start observing at the current launch.
        let boundary = existingHistoryStart ?? now
        defaults.set(String(boundary.timeIntervalSinceReferenceDate), forKey: startedAtKey)
        return boundary
    }

    static func startedAt(defaults: UserDefaults = .standard) -> Date? {
        if let value = defaults.object(forKey: startedAtKey) as? Date {
            return value
        }
        if let value = defaults.object(forKey: startedAtKey) as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: value.doubleValue)
        }
        if let value = defaults.string(forKey: startedAtKey),
           let interval = TimeInterval(value) {
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return nil
    }

    static func setStartedAt(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(String(date.timeIntervalSinceReferenceDate), forKey: startedAtKey)
    }
}
