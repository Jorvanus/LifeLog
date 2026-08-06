import Foundation
import SwiftUI

/// One week's total for one category, which is a single point on a trend line.
struct TrendPoint: Identifiable, Equatable {
    let weekStart: Date
    let hours: Double
    var id: Date { weekStart }
}

/// Every category's hours for one week, resolved once and read many times.
struct WeeklyTotals: Identifiable, Equatable {
    let weekStart: Date
    let hours: [String: Double]
    var id: Date { weekStart }
}

/// Something the recent weeks say about a habit: a return, a run, or a new high.
struct InsightsHabit: Identifiable, Equatable {
    let id: String
    let category: String
    let symbol: String
    let headline: String
    let detail: String
}

/// A category's hours week by week over recent history, and the one sentence
/// worth saying about where it has ended up.
///
/// Weekly rather than daily on purpose. A day of "hours at home" swings between
/// nothing and twenty-four depending only on whether the person went to work, so a
/// daily line is a picture of the calendar rather than of a habit. A week absorbs
/// that and still moves when something real changes.
struct InsightsTrendSeries: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let points: [TrendPoint]
    /// The most recent complete week.
    let latest: Double
    /// The mean of the weeks before it.
    let baseline: Double
    let message: String

    var isEmpty: Bool { points.allSatisfy { $0.hours == 0 } }
    var peak: Double { points.map(\.hours).max() ?? 0 }
}

@MainActor
enum InsightsTrends {
    /// How many weeks of history the charts show, and therefore how far back the
    /// fetch has to reach. Deliberately a season rather than the whole archive: this
    /// runs on the main actor beside a nine-year journal, and twelve weeks is enough
    /// to see a trend without loading years to draw one line.
    static let weeks = 12

    /// A difference smaller than this is not a change, it is a week.
    static let noticeableChange = 0.1

    /// The interval the trend charts need loaded, ending at the most recently
    /// completed week so a part-finished week cannot masquerade as a collapse.
    static func range(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, duration: 0)
        let end = currentWeek.start
        let start = calendar.date(byAdding: .weekOfYear, value: -weeks, to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    /// Every category's hours, week by week, resolved once.
    ///
    /// Segmenting a week is the expensive part, so it happens here and every line and
    /// habit is read back out of the result. Asking per category instead re-resolved
    /// the same twelve weeks once for each thing being drawn.
    static func weeklyTotals(visits: [Visit], now: Date,
                             calendar: Calendar = .current) -> [WeeklyTotals] {
        let span = range(endingAt: now, calendar: calendar)
        var weeks: [WeeklyTotals] = []
        var weekStart = span.start
        while weekStart < span.end {
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? span.end
            let bounded = min(weekEnd, span.end)
            guard bounded > weekStart else { break }
            weeks.append(WeeklyTotals(
                weekStart: weekStart,
                hours: InsightsSnapshot.categoryHours(
                    visits: visits,
                    range: DateInterval(start: weekStart, end: bounded),
                    now: now
                )
            ))
            weekStart = weekEnd
        }
        return weeks
    }

    static func series(for category: String, title: String, symbol: String,
                       weeks: [WeeklyTotals]) -> InsightsTrendSeries {
        let points = weeks.map { TrendPoint(weekStart: $0.weekStart, hours: $0.hours[category] ?? 0) }
        let latest = points.last?.hours ?? 0
        let earlier = points.dropLast().map(\.hours).filter { $0 > 0 }
        let baseline = earlier.isEmpty ? 0 : earlier.reduce(0, +) / Double(earlier.count)
        return InsightsTrendSeries(
            id: category, title: title, symbol: symbol, points: points,
            latest: latest, baseline: baseline,
            message: message(title: title, latest: latest, baseline: baseline)
        )
    }

    /// Says what the line means, or admits there is not yet enough of it to say.
    ///
    /// The comparison is always spelled out in hours as well as in words. "Less than
    /// usual" on its own invites the reader to imagine how much less, and the honest
    /// answer is often "forty minutes".
    static func message(title: String, latest: Double, baseline: Double) -> String {
        let subject = title.lowercased()
        guard baseline > 0 else {
            return "Not enough history yet to compare your \(subject) week with a usual one."
        }
        guard latest > 0 else {
            return "Nothing recorded for \(subject) last week, against a usual \(formatHours(baseline))."
        }
        let change = (latest - baseline) / baseline
        let comparison = "\(formatHours(latest)) against a usual \(formatHours(baseline))."
        if change >= noticeableChange { return "More \(subject) than usual last week — \(comparison)" }
        if change <= -noticeableChange { return "Less \(subject) than usual last week — \(comparison)" }
        return "About as much \(subject) as usual last week — \(comparison)"
    }

    /// Categories that are true of nearly every week and so can never be news.
    ///
    /// "You slept every week for twelve weeks" is not an observation about a habit,
    /// it is an observation about being alive; the same goes for being at home. They
    /// have their own cards, where the question is how much rather than whether.
    static let habitExclusions: Set<String> = ["Sleep", "Home", "Unlogged", "Uncategorised", "Other"]

    /// How many weeks in a row something has to happen before it is a run worth
    /// mentioning. Three is a coincidence.
    static let streakWeeks = 4

    /// The two or three things the recent weeks actually say, most striking first.
    ///
    /// Every claim here is scoped to the weeks that were loaded and says so. It would
    /// be easy to write "the first time this year" and much harder to mean it — with
    /// twelve weeks in hand the honest phrase is "in twelve weeks", and a card that
    /// overstates what it knows is worse than one that says less.
    static func habits(from weeks: [WeeklyTotals], limit: Int = 2,
                       calendar: Calendar = .current) -> [InsightsHabit] {
        guard let latest = weeks.last, weeks.count >= 2 else { return [] }
        let earlier = weeks.dropLast()
        let candidates = latest.hours
            .filter { $0.value > 0.25 && !habitExclusions.contains($0.key) }
            .sorted { $0.value > $1.value }

        var returns: [InsightsHabit] = []
        var highs: [InsightsHabit] = []
        var streaks: [InsightsHabit] = []

        for (category, hours) in candidates {
            let history = earlier.map { $0.hours[category] ?? 0 }
            let symbol = insightSymbol(for: category)
            let subject = category.lowercased()

            // Back after a gap. The strongest thing a run of weeks can tell you, and
            // the one the card was asked for.
            if history.allSatisfy({ $0 == 0 }) {
                returns.append(InsightsHabit(
                    id: "return-\(category)", category: category, symbol: symbol,
                    headline: "First \(subject) in \(weeks.count) weeks",
                    detail: "You spent \(formatHours(hours)) on it last week."
                ))
                continue
            }
            if let lastSeen = earlier.last(where: { ($0.hours[category] ?? 0) > 0 }),
               let gap = calendar.dateComponents([.weekOfYear], from: lastSeen.weekStart,
                                                 to: latest.weekStart).weekOfYear, gap >= streakWeeks {
                returns.append(InsightsHabit(
                    id: "return-\(category)", category: category, symbol: symbol,
                    headline: "Back to \(subject)",
                    detail: "First time since \(lastSeen.weekStart.formatted(.dateTime.month(.wide))), after \(gap) weeks away."
                ))
                continue
            }
            // A new high, but only against weeks that actually happened.
            let recorded = history.filter { $0 > 0 }
            if recorded.count >= 3, let previousBest = recorded.max(), hours > previousBest {
                highs.append(InsightsHabit(
                    id: "high-\(category)", category: category, symbol: symbol,
                    headline: "Most \(subject) in \(weeks.count) weeks",
                    detail: "\(formatHours(hours)) last week, beating \(formatHours(previousBest))."
                ))
                continue
            }
            let streak = runLength(of: category, in: weeks)
            if streak >= streakWeeks {
                streaks.append(InsightsHabit(
                    id: "streak-\(category)", category: category, symbol: symbol,
                    headline: "\(streak) weeks of \(subject)",
                    detail: "Every week since \(weeks[weeks.count - streak].weekStart.formatted(.dateTime.month(.wide).day()))."
                ))
            }
        }
        return Array((returns + highs + streaks).prefix(limit))
    }

    /// How many weeks up to and including the most recent one contain this category.
    static func runLength(of category: String, in weeks: [WeeklyTotals]) -> Int {
        var count = 0
        for week in weeks.reversed() {
            guard (week.hours[category] ?? 0) > 0 else { break }
            count += 1
        }
        return count
    }
}
