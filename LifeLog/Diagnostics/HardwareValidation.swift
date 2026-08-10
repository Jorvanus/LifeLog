import Foundation
import SwiftData

/// Retains the first real-device event that proves an otherwise simulator-only path.
///
/// A validation is evidence, not another stream of telemetry: one successful event is
/// enough to settle each claim, so it is written once and the marker then prevents
/// ordinary use from filling Diagnostics with duplicates. Both the marker and the
/// diagnostic survive a local backup — the marker is a string preference, and the
/// diagnostic is already part of the backup document.
@MainActor
enum HardwareValidation {
    enum Check: String {
        case namedGeofenceEntry = "named-geofence-entry-v1"
        case geofenceExit = "geofence-exit-v1"
        case motionHistory = "motion-history-v1"
        case wifiDepartureAnchor = "wifi-departure-anchor-v1"
        case monitoredPlaces = "monitored-places-v1"
        case liveBurstBackgroundFallback = "live-burst-background-fallback-v1"
    }

    private static let keyPrefix = "LifeLog.HardwareValidation."

    static func recordFirst(_ check: Check, context: ModelContext?, message: String,
                            defaults: UserDefaults = .standard) {
        let key = keyPrefix + check.rawValue
        guard defaults.string(forKey: key) == nil else { return }
        // Write the marker first. A protected store can refuse this diagnostic, but a
        // retry after its next successful save must not turn one real-world event into
        // an unbounded stream of copies.
        defaults.set(Date.now.ISO8601Format(), forKey: key)
        Diagnostics.recordDurable(context, subsystem: "Hardware validation",
                                  message: message, severity: "info")
    }

    /// Monitoring membership changes when a place is added, renamed, or its history
    /// changes. Retain each distinct ranking, rather than just the first one, so the
    /// backup says which side of iOS's twenty-region boundary the current places fell.
    static func recordRanking(signature: String, context: ModelContext?, message: String,
                              defaults: UserDefaults = .standard) {
        let key = keyPrefix + Check.monitoredPlaces.rawValue
        guard defaults.string(forKey: key) != signature else { return }
        defaults.set(signature, forKey: key)
        Diagnostics.recordDurable(context, subsystem: "Hardware validation",
                                  message: message, severity: "info")
    }
}
