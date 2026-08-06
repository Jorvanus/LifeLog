import Foundation

/// One plain sentence about how this day compares with the days like it.
///
/// The point is the comparison, not the number. "8h 10m of sleep" says nothing on
/// its own; "more than your usual Thursday" is the part worth reading, so every
/// highlight is built from a measurement *and* the baseline it is measured against,
/// and none is offered when there is no baseline to speak of.
struct DayHighlight: Identifiable, Equatable {
    let id: String
    let symbol: String
    let headline: String
    let detail: String
    /// Whether this is worth congratulating. Only ever used for tone — a day with
    /// fewer steps than usual is still reported, just without the confetti.
    let isCelebration: Bool
}

enum DayHighlights {
    /// How far from the baseline a day has to land before it is worth remarking on.
    ///
    /// Everything moves a little. Below this a day is "about the same", which is
    /// itself worth saying — it is the honest answer, and inventing a trend out of
    /// three percent would make every other highlight less believable.
    static let noticeableChange = 0.1

    /// A baseline built from too little history is not a habit, it is one day
    /// wearing a lab coat. Under this many prior samples nothing is claimed.
    static let minimumBaselineSamples = 2

    static func percentage(_ value: Double, against baseline: Double) -> Int {
        guard baseline > 0 else { return 0 }
        return Int((abs(value - baseline) / baseline * 100).rounded())
    }

    /// Steps today against the same weekday in recent weeks.
    ///
    /// Compared with the same weekday rather than with every day, because the
    /// weekdays genuinely differ: a Saturday measured against a Monday-heavy average
    /// would read as a triumph every week and mean nothing.
    static func steps(today: Double, weekdayBaseline: [Double], weekdayName: String) -> DayHighlight? {
        guard weekdayBaseline.count >= minimumBaselineSamples else { return nil }
        let average = weekdayBaseline.reduce(0, +) / Double(weekdayBaseline.count)
        guard average > 0, today > 0 else { return nil }
        let change = (today - average) / average
        let percent = percentage(today, against: average)
        let headline = "\(formatSteps(today)) steps"
        if change >= noticeableChange {
            return DayHighlight(id: "steps", symbol: "figure.walk.motion",
                                headline: headline,
                                detail: "\(percent)% more than your usual \(weekdayName).",
                                isCelebration: true)
        }
        if change <= -noticeableChange {
            return DayHighlight(id: "steps", symbol: "figure.walk",
                                headline: headline,
                                detail: "\(percent)% fewer than your usual \(weekdayName).",
                                isCelebration: false)
        }
        return DayHighlight(id: "steps", symbol: "figure.walk",
                            headline: headline,
                            detail: "About the same as your usual \(weekdayName).",
                            isCelebration: false)
    }

    /// Last night's sleep against the recent nightly average.
    ///
    /// Not split by weekday. Sleep debt carries across a week in a way step counts
    /// do not, so the useful question is how this night compares with the nights
    /// around it rather than with the same night a fortnight ago.
    static func sleep(lastNight: TimeInterval, averageNight: TimeInterval) -> DayHighlight? {
        guard lastNight > 0, averageNight > 0 else { return nil }
        let hours = lastNight / 3600
        let change = (lastNight - averageNight) / averageNight
        let percent = percentage(lastNight, against: averageNight)
        let headline = "\(formatHours(hours)) asleep"
        if change >= noticeableChange {
            return DayHighlight(id: "sleep", symbol: "bed.double.fill",
                                headline: headline,
                                detail: "\(percent)% more than you usually sleep.",
                                isCelebration: true)
        }
        if change <= -noticeableChange {
            return DayHighlight(id: "sleep", symbol: "bed.double",
                                headline: headline,
                                detail: "\(percent)% less than you usually sleep.",
                                isCelebration: false)
        }
        return DayHighlight(id: "sleep", symbol: "bed.double.fill",
                            headline: headline,
                            detail: "About as much as you usually sleep.",
                            isCelebration: false)
    }

    /// The largest shift in how the time itself was spent.
    ///
    /// This one needs no Health access at all, which is the reason it exists: it is
    /// built from the visits LifeLog recorded itself, so the card still has something
    /// true to say on a phone that never granted Health permission.
    ///
    /// Never marked as a celebration. Steps and sleep have a direction everyone
    /// agrees on; time does not. Eleven hours more at home is a fact about a day,
    /// and congratulating someone for it — or commiserating — would be the app
    /// deciding how they ought to have spent it.
    static func activity(from comparisons: [TrendComparison], window: InsightWindow) -> DayHighlight? {
        guard let largest = comparisons.max(by: { abs($0.delta) < abs($1.delta) }),
              abs(largest.delta) > 0.25 else { return nil }
        return DayHighlight(
            id: "activity-\(largest.name)",
            symbol: insightSymbol(for: largest.name),
            headline: "\(formatHours(abs(largest.delta))) \(largest.delta >= 0 ? "more" : "less") on \(largest.name.lowercased())",
            detail: "Compared with the previous \(window.title.lowercased()).",
            isCelebration: false
        )
    }
}
