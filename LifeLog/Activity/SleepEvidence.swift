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
