import CoreLocation

/// One place-name definition of "too fuzzy to trust for a distance comparison" —
/// reduced-accuracy authorization (the OS "Precise Location" toggle) and a
/// genuinely poor GPS fix (indoors, urban canyon) both end up here, since both are
/// equally untrustworthy for "which candidate is closest" logic even though only
/// the former has a user-facing switch.
enum LocationQuality {
    /// Past this, a fix is closer to iOS's reduced-accuracy fuzzing (city-block
    /// scale) than a real outdoor GPS fix. Matches the ceiling `PlaceScoring`
    /// already used for its own accuracy component.
    static let approximateAccuracyMeters: CLLocationDistance = 200

    static func isApproximate(_ accuracy: CLLocationAccuracy) -> Bool {
        accuracy < 0 || accuracy > approximateAccuracyMeters
    }

    /// Persisted per-visit accuracy is best-effort and often absent (manually
    /// created visits, history predating `PlaceScoreLifecycle`) — missing evidence
    /// is treated as trustworthy rather than retroactively blocking history
    /// nothing ever measured as approximate.
    static func isApproximate(recordedAccuracyMeters accuracyMeters: Int?) -> Bool {
        guard let accuracyMeters, accuracyMeters >= 0 else { return false }
        return Double(accuracyMeters) > approximateAccuracyMeters
    }
}
