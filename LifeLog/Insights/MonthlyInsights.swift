import Foundation
import SwiftUI

/// The small, deliberately conservative facts Month Insights is allowed to say.
/// All values come from the same resolved segments as the donut, so imported journal
/// rows and device records follow the existing Insights visibility policy.
struct MonthlyInsights {
    struct ActivityChange: Identifiable {
        let category: String
        let hours: Double
        let previousHours: Double
        var id: String { category }
        var delta: Double { hours - previousHours }
        var percentage: Double? {
            guard previousHours > 0 else { return nil }
            return delta / previousHours
        }
    }

    struct PlaceStory: Identifiable {
        let name: String
        let category: String
        let activity: String
        let hours: Double
        let visits: Int
        let previousHours: Double
        var id: String { name }
        var delta: Double { hours - previousHours }
        var isNew: Bool { previousHours == 0 }
    }

    struct Balance: Identifiable {
        let name: String
        let symbol: String
        let hours: Double
        let color: Color
        var id: String { name }
    }

    struct Day: Identifiable {
        let date: Date
        let dominantCategory: String?
        let hours: Double
        let awayFraction: Double
        var id: Date { date }
    }

    static let minimumLoggedHours = 8.0
    static let minimumAbsoluteChange = 1.0
    static let minimumPercentageChange = 0.20
    static let minimumNewCategoryHours = 2.0

    let headline: String?
    let changes: [ActivityChange]
    let placesByTime: [PlaceStory]
    let placesByVisits: [PlaceStory]
    let newPlaces: [PlaceStory]
    let biggestPlaceChange: PlaceStory?
    let balance: [Balance]

    /// `current` and `previous` are already post-resolution. This is intentionally
    /// not a second catalogue: the eight presentation groups are derived from each
    /// activity's existing `ActivityCatalog.category(for:)` definition.
    static func make(current: [InsightSegment], previous: [InsightSegment],
                     currentInterval: DateInterval, previousInterval: DateInterval,
                     now: Date = .now) -> MonthlyInsights {
        let currentHours = categoryHours(current)
        let previousHours = categoryHours(previous)
        let changes = meaningfulChanges(current: currentHours, previous: previousHours)
        let currentPlaces = placeStories(current: current, previous: previous)
        let previousPlaceNames = Set(previousPlaces(previous).map(\.name))
        let newPlaces = currentPlaces.filter { !previousPlaceNames.contains($0.name) }
        let logged = current.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let previousLogged = previous.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let headline = headline(changes: changes, newPlaces: newPlaces,
                                current: currentHours, previous: previousHours,
                                logged: logged, previousLogged: previousLogged)
        return MonthlyInsights(
            headline: headline,
            changes: changes,
            placesByTime: Array(currentPlaces.sorted { $0.hours > $1.hours }.prefix(5)),
            placesByVisits: Array(currentPlaces.sorted { $0.visits > $1.visits || ($0.visits == $1.visits && $0.hours > $1.hours) }.prefix(5)),
            newPlaces: Array(newPlaces.sorted { $0.hours > $1.hours }.prefix(5)),
            biggestPlaceChange: currentPlaces
                .filter { meaningfulPlaceChange($0) }
                .max { abs($0.delta) < abs($1.delta) },
            balance: balances(from: current)
        )
    }

    static func daySummaries(segments: [InsightSegment], interval: DateInterval,
                             now: Date = .now, calendar: Calendar = .current) -> [Day] {
        var result: [Day] = []
        var date = interval.start
        while date < interval.end {
            let end = min(calendar.date(byAdding: .day, value: 1, to: date) ?? interval.end, interval.end)
            let day = segments.filter { $0.start < end && $0.end > date }
            let logged = day.filter { !$0.isUnlogged }
            let hours = logged.reduce(0) { $0 + $1.hours }
            let dominant = Dictionary(grouping: logged, by: \.category)
                .map { ($0.key, $0.value.reduce(0) { $0 + $1.hours }) }
                .max { $0.1 < $1.1 }?.0
            let away = day.filter { !$0.isUnlogged && $0.category != "Home" }
                .reduce(0) { $0 + $1.hours }
            result.append(Day(date: date, dominantCategory: dominant, hours: hours,
                              awayFraction: away / max(hours, 0.01)))
            date = end
        }
        return result
    }

    private static func categoryHours(_ segments: [InsightSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments where !segment.isUnlogged {
            result[segment.category, default: 0] += segment.hours
        }
        return result
    }

    private static func meaningfulChanges(current: [String: Double], previous: [String: Double]) -> [ActivityChange] {
        Set(current.keys).union(previous.keys).compactMap { category in
            let hours = current[category, default: 0]
            let prior = previous[category, default: 0]
            let delta = abs(hours - prior)
            let meaningful = prior > 0
                ? delta >= minimumAbsoluteChange && delta / prior >= minimumPercentageChange
                : hours >= minimumNewCategoryHours
            guard meaningful, category != "Unlogged" else { return nil }
            return ActivityChange(category: category, hours: hours, previousHours: prior)
        }.sorted { abs($0.delta) > abs($1.delta) }
    }

    private static func placeStories(current: [InsightSegment], previous: [InsightSegment]) -> [PlaceStory] {
        let previousByName = Dictionary(grouping: previousPlaces(previous), by: \.name)
        let grouped = Dictionary(grouping: current.filter { !$0.isUnlogged && $0.placeName != nil }) { $0.placeName! }
        return grouped.compactMap { (name, segments) -> PlaceStory? in
            guard let first = segments.first else { return nil }
            let visits = Set<ObjectIdentifier>(segments.compactMap { segment -> ObjectIdentifier? in
                guard let visit = segment.visit else { return nil }
                return ObjectIdentifier(visit)
            }).count
            let prior = previousByName[name]?.reduce(0) { $0 + $1.hours } ?? 0
            return PlaceStory(name: name, category: first.category, activity: first.activity,
                              hours: segments.reduce(0) { $0 + $1.hours }, visits: visits,
                              previousHours: prior)
        }
    }

    private static func previousPlaces(_ segments: [InsightSegment]) -> [PlaceStory] {
        let grouped = Dictionary(grouping: segments.filter { !$0.isUnlogged && $0.placeName != nil }) { $0.placeName! }
        return grouped.compactMap { (name, segments) -> PlaceStory? in
            guard let first = segments.first else { return nil }
            let visits = Set<ObjectIdentifier>(segments.compactMap { $0.visit.map(ObjectIdentifier.init) }).count
            return PlaceStory(name: name, category: first.category, activity: first.activity,
                              hours: segments.reduce(0) { $0 + $1.hours }, visits: visits, previousHours: 0)
        }
    }

    private static func meaningfulPlaceChange(_ place: PlaceStory) -> Bool {
        guard place.previousHours > 0 else { return false }
        return abs(place.delta) >= minimumAbsoluteChange && abs(place.delta) / place.previousHours >= minimumPercentageChange
    }

    private static func headline(changes: [ActivityChange], newPlaces: [PlaceStory],
                                 current: [String: Double], previous: [String: Double],
                                 logged: Double, previousLogged: Double) -> String? {
        guard logged >= minimumLoggedHours, previousLogged >= minimumLoggedHours else { return nil }
        let away = logged - current["Home", default: 0]
        let previousAway = previousLogged - previous["Home", default: 0]
        let awayDelta = away - previousAway
        if abs(awayDelta) >= minimumAbsoluteChange,
           previousAway > 0,
           abs(awayDelta) / previousAway >= minimumPercentageChange {
            let direction = awayDelta >= 0 ? "more" : "less"
            return "\(formatHours(abs(awayDelta))) \(direction) away from Home than last month"
        }
        if let change = changes.first {
            let direction = change.delta >= 0 ? "more" : "less"
            return "\(change.category) was \(direction) \(formatHours(abs(change.delta))) than last month"
        }
        if newPlaces.count >= 2 {
            return "You visited \(newPlaces.count) new places"
        }
        return nil
    }

    private static func balances(from segments: [InsightSegment]) -> [Balance] {
        let groups: [(String, String, [String])] = [
            ("Home", "house.fill", ["Home"]),
            ("Work", "briefcase.fill", ["Work"]),
            ("Social", "person.2.fill", ["Social", "Entertainment"]),
            ("Health/Fitness", "figure.run", ["Fitness", "Healthcare"]),
            ("Food & drink", "fork.knife", ["Food & Drink"]),
            ("Errands", "cart.fill", ["Shopping"]),
            ("Travel", "car.fill", ["Travel", "Commute"]),
            ("Rest/Sleep", "bed.double.fill", ["Sleep"])
        ]
        // ActivityCatalog loads editable definitions from UserDefaults. Resolve each
        // distinct activity once per snapshot rather than once per resolved time slice.
        let definedCategories = Dictionary(uniqueKeysWithValues: Set(segments.compactMap { $0.visit?.activity })
            .map { ($0, ActivityCatalog.category(for: $0)) })
        return groups.compactMap { name, symbol, categories in
            let hours = segments.filter {
                guard !$0.isUnlogged else { return false }
                let category = $0.visit.map { definedCategories[$0.activity] ?? ActivityCatalog.category(for: $0.activity) } ?? $0.category
                return categories.contains(category)
            }
                .reduce(0) { $0 + $1.hours }
            guard hours > 0.01 else { return nil }
            return Balance(name: name, symbol: symbol, hours: hours,
                           color: categories.map { insightColor(for: $0) }.first ?? .secondary)
        }
    }

    /// Read the activity's live definition for ordinary visits so a user-edited
    /// category affects the balance immediately. Synthetic commute segments have no
    /// catalogue entry, so their already-resolved category is the correct source.
    private static func definedCategory(for segment: InsightSegment) -> String {
        guard segment.visit != nil else { return segment.category }
        return ActivityCatalog.category(for: segment.activity)
    }
}
