import Foundation

/// The source determines what LifeLog is entitled to say about a night. An iPhone
/// schedule can estimate time in bed, but only an asleep sample (from a Watch,
/// tracker, or manual Health entry) supports the word "sleep".
enum SleepEvidence {
    static let measuredSource = "health-sleep"
    static let inBedSource = "health-in-bed"
    static let manualSource = "manual-sleep"

    static func isSleepSource(_ source: String) -> Bool {
        source == measuredSource || source == inBedSource || source == manualSource
    }

    static func isMeasured(_ source: String) -> Bool {
        source == measuredSource
    }

    static func isAutomatic(_ source: String) -> Bool {
        source == measuredSource || source == inBedSource
    }
}

/// A same-morning empty sleep query and a genuinely sleep-free week look identical to
/// HealthKit, but they call for different UI: the first is expected while a Watch is
/// still handing last night off to the phone, the second is a real gap worth inviting
/// a manual entry for. `stillSyncing` covers the former so Settings does not invite a
/// manual entry that becomes a duplicate once the real data lands.
enum SleepEvidenceState: Equatable {
    case notYetChecked
    case measured
    case estimatedTimeInBed
    case stillSyncing(emptySince: Date)
    case confirmedEmpty

    var statusText: String {
        switch self {
        case .notYetChecked: "No sleep evidence imported yet"
        case .measured: "Measured sleep imported"
        case .estimatedTimeInBed: "Estimated time in bed imported"
        case .stillSyncing: "No sleep evidence yet — still checking"
        case .confirmedEmpty: "No recent measured sleep — wear Watch or add it manually"
        }
    }

    /// How long an empty query is treated as "still syncing" before it counts as a
    /// confirmed absence. Sized to comfortably outlast the delay observed between an
    /// Apple Watch waking and its overnight sleep reaching HealthKit on the phone.
    static let syncGracePeriod: TimeInterval = 45 * 60

    /// Pure so the grace-period boundary is testable without HealthKit or a running
    /// import. `emptySince` is when the current streak of empty queries first began;
    /// pass the value this returned last time, and persist what it returns now.
    static func afterQuery(
        measured: Int, inBed: Int, emptySince: Date?, now: Date
    ) -> (state: SleepEvidenceState, emptySince: Date?) {
        if measured > 0 { return (.measured, nil) }
        if inBed > 0 { return (.estimatedTimeInBed, nil) }
        let since = emptySince ?? now
        if now.timeIntervalSince(since) < syncGracePeriod {
            return (.stillSyncing(emptySince: since), since)
        }
        return (.confirmedEmpty, since)
    }
}
