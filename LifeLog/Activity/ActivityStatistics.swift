import Foundation

/// Everything the Activities screen reports about one label, worked out in one place
/// so the sparkline, the comparisons and the totals can never disagree.
///
/// An occasion is one visit, because that is what a person counts: fourteen occasions
/// of "Beers" means fourteen nights out, whatever LifeLog had to merge to record them.
struct ActivityStatistics: Sendable {
    struct DayTotal: Identifiable, Sendable {
        let day: Date
        let hours: Double
        let occasions: Int
        var id: Date { day }
    }

    struct PlaceTally: Identifiable, Sendable {
        let name: String
        let occasions: Int
        var id: String { name }
    }

    let activity: String
    let occasions: Int
    let totalTime: TimeInterval
    /// Average length of one occasion, not an average per day: "how long do I usually
    /// stay" is the question the shortest and longest sit either side of.
    let averageTime: TimeInterval
    let shortestTime: TimeInterval
    let longestTime: TimeInterval
    let firstUsed: Date?
    let lastUsed: Date?
    /// Newest last, so a chart reads left to right.
    let recentDays: [DayTotal]
    let places: [PlaceTally]
    /// This period against the one before it, for the comparison the detail view shows.
    let currentPeriodTime: TimeInterval
    let previousPeriodTime: TimeInterval

    var averagePerDay: TimeInterval {
        recentDays.isEmpty ? 0 : recentDays.reduce(0) { $0 + $1.hours } * 3_600 / Double(recentDays.count)
    }
    var averagePerWeek: TimeInterval { averagePerDay * 7 }
    var isEmpty: Bool { occasions == 0 }
    /// Nil when there is nothing to compare against, rather than a fabricated 0%.
    var changeFraction: Double? {
        guard previousPeriodTime > 0 else { return nil }
        return (currentPeriodTime - previousPeriodTime) / previousPeriodTime
    }

    static let empty = ActivityStatistics(
        activity: "", occasions: 0, totalTime: 0, averageTime: 0, shortestTime: 0,
        longestTime: 0, firstUsed: nil, lastUsed: nil, recentDays: [], places: [],
        currentPeriodTime: 0, previousPeriodTime: 0
    )

    /// What the Activities list needs, and nothing else.
    ///
    /// The full statistics cost far more than the list shows: top locations alone
    /// reads `displayPlaceName` for every visit — which trims and compares strings to
    /// decide whether the place was ever identified — and the shortest, longest,
    /// first, last and previous-period figures are each another walk over the same
    /// visits. None of that is on screen until an activity is opened.
    struct Summary: Sendable, Identifiable {
        let activity: String
        let occasions: Int
        let totalTime: TimeInterval
        let recentDays: [DayTotal]
        var id: String { activity }
        var isEmpty: Bool { occasions == 0 }
    }

    /// One pass over the timeline for every activity at once, accumulating as it goes
    /// rather than grouping first and walking each group again.
    static func summaries(named names: [String], visits: [Visit], days: Int = 7,
                          now: Date = .now, calendar: Calendar = .current) -> [Summary] {
        // Day boundaries worked out once. Calendar arithmetic is expensive and gets
        // the awkward cases right — a day is not always 86,400 seconds — so it is
        // done `days` times rather than once per visit.
        let today = calendar.startOfDay(for: now)
        var boundaries: [Date] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            boundaries.append(day)
        }
        let windowStart = boundaries.first ?? today

        var totals: [String: (occasions: Int, time: TimeInterval)] = [:]
        var buckets: [String: [Double]] = [:]
        var bucketOccasions: [String: [Int]] = [:]
        var spelling: [String: String] = [:]

        for visit in visits {
            let raw = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let key = raw.lowercased()
            let duration = visit.duration
            let running = totals[key] ?? (0, 0)
            totals[key] = (running.occasions + 1, running.time + duration)
            if spelling[key] == nil { spelling[key] = raw }

            // Most of an archive is older than the window, so this is one comparison
            // for nearly every visit and the bucket search runs only for recent ones.
            guard visit.arrival >= windowStart else { continue }
            guard let index = boundaries.lastIndex(where: { visit.arrival >= $0 }) else { continue }
            var seconds = buckets[key] ?? Array(repeating: 0, count: boundaries.count)
            var counts = bucketOccasions[key] ?? Array(repeating: 0, count: boundaries.count)
            // Seconds accumulated and converted once, matching how the full figures
            // are worked out. Dividing per visit instead adds up differently in
            // floating point, and the two paths must not disagree by a rounding tail.
            seconds[index] += duration
            counts[index] += 1
            buckets[key] = seconds
            bucketOccasions[key] = counts
        }

        func summary(for name: String, key: String) -> Summary {
            let total = totals[key] ?? (0, 0)
            let seconds = buckets[key] ?? Array(repeating: 0, count: boundaries.count)
            let counts = bucketOccasions[key] ?? Array(repeating: 0, count: boundaries.count)
            var recent: [DayTotal] = []
            for (index, day) in boundaries.enumerated() {
                recent.append(DayTotal(day: day, hours: seconds[index] / 3_600,
                                       occasions: counts[index]))
            }
            return Summary(activity: name, occasions: total.occasions,
                           totalTime: total.time, recentDays: recent)
        }

        var result: [Summary] = []
        var seen = Set<String>()
        for name in names {
            let key = NameKey.matching(name)
            guard seen.insert(key).inserted else { continue }
            result.append(summary(for: name, key: key))
        }
        for key in totals.keys where !seen.contains(key) {
            result.append(summary(for: spelling[key] ?? key, key: key))
        }
        return result
    }

    /// Every activity from one pass over the timeline.
    ///
    /// Computing them one at a time meant normalising every visit once per activity:
    /// with a large imported archive that is hundreds of thousands of string
    /// operations to draw a single screen, which is exactly what made the Activities
    /// tab slow to open. Grouping first makes it one pass regardless of how many
    /// activities exist.
    ///
    /// Labels the timeline uses that `names` does not contain are included, because
    /// an activity nobody has added to the catalogue is the one worth seeing.
    static func makeAll(named names: [String], visits: [Visit], days: Int = 7,
                        now: Date = .now, calendar: Calendar = .current) -> [ActivityStatistics] {
        var grouped: [String: [Visit]] = [:]
        var spelling: [String: String] = [:]
        for visit in visits {
            let raw = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let key = raw.lowercased()
            grouped[key, default: []].append(visit)
            if spelling[key] == nil { spelling[key] = raw }
        }

        var result: [ActivityStatistics] = []
        var seen = Set<String>()
        for name in names {
            let key = NameKey.matching(name)
            guard seen.insert(key).inserted else { continue }
            result.append(make(activity: name, matching: grouped[key] ?? [],
                               days: days, now: now, calendar: calendar))
        }
        for (key, group) in grouped where !seen.contains(key) {
            result.append(make(activity: spelling[key] ?? key, matching: group,
                               days: days, now: now, calendar: calendar))
        }
        return result
    }

    /// - Parameter days: how far back the sparkline and the period comparison reach.
    static func make(activity: String, visits: [Visit], days: Int = 7,
                     now: Date = .now, calendar: Calendar = .current) -> ActivityStatistics {
        let key = NameKey.matching(activity)
        return make(activity: activity, matching: visits.filter { NameKey.matching($0.activity) == key },
                    days: days, now: now, calendar: calendar)
    }

    private static func make(activity: String, matching: [Visit], days: Int,
                             now: Date, calendar: Calendar) -> ActivityStatistics {
        // Named even when nothing uses it, so a never-recorded activity can still be
        // listed and say so rather than being dropped from the screen.
        guard !matching.isEmpty else {
            return ActivityStatistics(
                activity: activity, occasions: 0, totalTime: 0, averageTime: 0,
                shortestTime: 0, longestTime: 0, firstUsed: nil, lastUsed: nil,
                recentDays: [], places: [], currentPeriodTime: 0, previousPeriodTime: 0
            )
        }

        let durations = matching.map(\.duration)
        let total = durations.reduce(0, +)
        let arrivals = matching.map(\.arrival)

        // Whole days ending today, so the newest column is the day in progress rather
        // than a partial window that shifts with the time of day.
        let today = calendar.startOfDay(for: now)
        var dayTotals: [DayTotal] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let onDay = matching.filter { $0.arrival >= day && $0.arrival < end }
            dayTotals.append(DayTotal(day: day,
                                      hours: onDay.reduce(0) { $0 + $1.duration } / 3_600,
                                      occasions: onDay.count))
        }

        let windowStart = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        let previousStart = calendar.date(byAdding: .day, value: -days, to: windowStart) ?? windowStart
        let current = matching.filter { $0.arrival >= windowStart }.reduce(0) { $0 + $1.duration }
        let previous = matching
            .filter { $0.arrival >= previousStart && $0.arrival < windowStart }
            .reduce(0) { $0 + $1.duration }

        // Grouped case-insensitively but shown as the person's own spelling, taking
        // whichever form appears most so one stray capitalisation cannot rename a place.
        var placeCounts: [String: (name: String, count: Int)] = [:]
        for visit in matching {
            let name = visit.displayPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let placeKey = name.lowercased()
            let existing = placeCounts[placeKey]
            let existingName: String = existing?.name ?? name
            let existingCount: Int = existing?.count ?? 0
            placeCounts[placeKey] = (name: existingName, count: existingCount + 1)
        }
        var places: [PlaceTally] = []
        for tally in placeCounts.values {
            places.append(PlaceTally(name: tally.name, occasions: tally.count))
        }
        places.sort { (left: PlaceTally, right: PlaceTally) -> Bool in
            if left.occasions != right.occasions { return left.occasions > right.occasions }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        return ActivityStatistics(
            activity: activity,
            occasions: matching.count,
            totalTime: total,
            averageTime: total / Double(matching.count),
            shortestTime: durations.min() ?? 0,
            longestTime: durations.max() ?? 0,
            firstUsed: arrivals.min(),
            lastUsed: arrivals.max(),
            recentDays: dayTotals,
            places: places,
            currentPeriodTime: current,
            previousPeriodTime: previous
        )
    }
}
