import Foundation
import SwiftUI

/// The annual view's small, derived vocabulary. It is deliberately not an editable
/// catalogue: individual activities remain the source of truth and are mapped here
/// only when a year needs a readable life-area story.
struct AnnualInsights {
    struct LifeArea: Identifiable, Hashable {
        let name: String
        let category: String
        var id: String { name }
    }

    static let areas: [LifeArea] = [
        .init(name: "Home", category: "Home"),
        .init(name: "Work", category: "Work"),
        .init(name: "Health & Fitness", category: "Health & Fitness"),
        .init(name: "Social", category: "Social"),
        .init(name: "Food & Drink", category: "Food & Drink"),
        .init(name: "Errands", category: "Errands"),
        .init(name: "Travel", category: "Travel"),
        .init(name: "Sleep & Rest", category: "Sleep & Rest"),
        .init(name: "Other", category: "Other")
    ]

    struct Month: Identifiable {
        let date: Date
        let label: String
        let isPartial: Bool
        let hours: [String: Double]
        var id: Date { date }
    }

    struct Place: Identifiable {
        let name: String
        let category: String
        let hours: Double
        let visits: Int
        let isNew: Bool
        var id: String { name }
    }

    struct HealthMetrics {
        let monthlySleepHours: [Double?]
        let monthlySteps: [Double?]
        let monthlyWalkingKilometres: [Double?]
        let monthlyActiveEnergy: [Double?]
        let monthlyExerciseMinutes: [Double?]
        let monthlyWorkoutMinutes: [Double?]
        let monthlyStandHours: [Double?]
        let healthDataAvailable: Bool
    }

    struct Milestones {
        let leadingIncrease: String?
        let longestActivityStreak: (activity: String, days: Int)?
        let longestPlaceGap: (place: String, days: Int)?
        let mostVisitedNewPlace: Place?
    }

    let months: [Month]
    let placesByTime: [Place]
    let placesByVisits: [Place]
    let newPlaces: [Place]
    let placesNotVisited: [Place]
    let health: HealthMetrics
    let travel: TravelInsights.Summary
    let milestones: Milestones
    let comparisonSupported: Bool
    let currentLoggedHours: Double
    let priorLoggedHours: Double

    static func area(for segment: InsightSegment) -> LifeArea {
        let raw = ActivityCatalog.lifeArea(for: segment.activity, category: segment.category)
        return areas.first { $0.name == raw.rawValue } ?? areas.last!
    }

    static func make(current: [InsightSegment], previous: [InsightSegment],
                     yearInterval: DateInterval, now: Date,
                     historicalPlaceVisits: [Visit] = [],
                     health: HealthMetrics = .empty) -> AnnualInsights {
        let calendar = Calendar.current
        let currentLogged = current.filter { !$0.isUnlogged }
        let previousLogged = previous.filter { !$0.isUnlogged }
        let comparable = currentLogged.reduce(0) { $0 + $1.hours } >= 24 &&
            previousLogged.reduce(0) { $0 + $1.hours } >= 24
        let months = monthlyTotals(currentLogged, interval: yearInterval, now: now, calendar: calendar)
        let placeRows = placeRows(currentLogged, previous: previousLogged,
                                  historicalPlaceVisits: historicalPlaceVisits)
        let travel = TravelInsights.make(from: currentLogged)
        let milestones = milestones(current: currentLogged, previous: previousLogged,
                                    newPlaces: placeRows.new)
        return AnnualInsights(
            months: months,
            placesByTime: Array(placeRows.all.sorted { $0.hours > $1.hours }.prefix(8)),
            placesByVisits: Array(placeRows.all.sorted { $0.visits > $1.visits || ($0.visits == $1.visits && $0.hours > $1.hours) }.prefix(8)),
            newPlaces: Array(placeRows.new.sorted { $0.visits > $1.visits || ($0.visits == $1.visits && $0.hours > $1.hours) }.prefix(8)),
            placesNotVisited: comparable ? Array(placeRows.notVisited.sorted { $0.hours > $1.hours }.prefix(6)) : [],
            health: health,
            travel: travel,
            milestones: milestones,
            comparisonSupported: comparable,
            currentLoggedHours: currentLogged.reduce(0) { $0 + $1.hours },
            priorLoggedHours: previousLogged.reduce(0) { $0 + $1.hours }
        )
    }

    private static func monthlyTotals(_ segments: [InsightSegment], interval: DateInterval,
                                      now: Date, calendar: Calendar) -> [Month] {
        var result: [Month] = []
        var cursor = interval.start
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        while cursor < interval.end {
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            let monthInterval = DateInterval(start: cursor, end: min(next, interval.end))
            var totals: [String: Double] = [:]
            for segment in segments {
                let start = max(segment.start, monthInterval.start)
                let end = min(segment.end, monthInterval.end)
                guard end > start else { continue }
                let area = area(for: segment).name
                totals[area, default: 0] += end.timeIntervalSince(start) / 3600
            }
            result.append(Month(date: cursor, label: formatter.string(from: cursor),
                                isPartial: monthInterval.end > now && monthInterval.start <= now,
                                hours: totals))
            cursor = next
        }
        return result
    }

    private static func placeRows(_ current: [InsightSegment], previous: [InsightSegment],
                                  historicalPlaceVisits: [Visit]) -> (all: [Place], new: [Place], notVisited: [Place]) {
        func rows(_ segments: [InsightSegment]) -> [String: Place] {
            var totals: [String: (category: String, hours: Double, ids: Set<InsightSegmentID>)] = [:]
            for segment in segments {
                guard let name = segment.placeName, !name.isEmpty else { continue }
                if totals[name] == nil { totals[name] = (segment.category, 0, []) }
                totals[name, default: (segment.category, 0, [])].hours += segment.hours
                totals[name, default: (segment.category, 0, [])].ids.insert(segment.id)
            }
            return Dictionary(uniqueKeysWithValues: totals.map { name, value in
                (name, Place(name: name, category: value.category, hours: value.hours, visits: value.ids.count, isNew: false))
            })
        }
        let currentRows = rows(current)
        let previousRows = rows(previous)
        let historicalNames = Set(historicalPlaceVisits.compactMap { $0.displayPlaceName }.filter { !$0.isEmpty })
        let new = currentRows.values.filter { !historicalNames.contains($0.name) }
            .map { Place(name: $0.name, category: $0.category, hours: $0.hours, visits: $0.visits, isNew: true) }
        let notVisited = previousRows.values.filter { $0.hours >= 8 && $0.visits >= 3 && currentRows[$0.name] == nil }
            .map { Place(name: $0.name, category: $0.category, hours: $0.hours, visits: $0.visits, isNew: false) }
        return (Array(currentRows.values), Array(new), Array(notVisited))
    }

    private static func milestones(current: [InsightSegment], previous: [InsightSegment],
                                   newPlaces: [Place]) -> Milestones {
        let currentTotals = Dictionary(grouping: current, by: { area(for: $0).name }).mapValues { $0.reduce(0) { $0 + $1.hours } }
        let previousTotals = Dictionary(grouping: previous, by: { area(for: $0).name }).mapValues { $0.reduce(0) { $0 + $1.hours } }
        let increase = currentTotals.compactMap { name, hours -> (String, Double)? in
            let old = previousTotals[name] ?? 0
            guard hours >= 4, old > 0, hours - old >= 1 else { return nil }
            return (name, hours - old)
        }.max { $0.1 < $1.1 }.map { $0.0 }

        let days = Dictionary(grouping: current, by: { Calendar.current.startOfDay(for: $0.start) })
        let activeDays = Set(days.keys).sorted()
        var longest = (activity: "", days: 0)
        var run = 0
        var previousDay: Date?
        for day in activeDays {
            if let previousDay, Calendar.current.dateComponents([.day], from: previousDay, to: day).day == 1 { run += 1 } else { run = 1 }
            if run > longest.days, let segment = days[day]?.max(by: { $0.hours < $1.hours }) {
                longest = (area(for: segment).name, run)
            }
            previousDay = day
        }

        var placeDates: [String: [Date]] = [:]
        for segment in current {
            guard let place = segment.placeName else { continue }
            placeDates[place, default: []].append(segment.start)
        }
        let longestGap = placeDates.compactMap { place, dates -> (String, Int)? in
            let ordered = dates.sorted()
            guard ordered.count >= 2 else { return nil }
            let gap = zip(ordered, ordered.dropFirst()).map { Int($1.timeIntervalSince($0) / 86_400) }.max() ?? 0
            return gap >= 14 ? (place, gap) : nil
        }.max { $0.1 < $1.1 }
        return Milestones(leadingIncrease: increase, longestActivityStreak: longest.days > 1 ? longest : nil,
                          longestPlaceGap: longestGap, mostVisitedNewPlace: newPlaces.max { $0.visits < $1.visits })
    }
}

extension AnnualInsights.HealthMetrics {
    static let empty = Self(monthlySleepHours: [], monthlySteps: [], monthlyWalkingKilometres: [],
                            monthlyActiveEnergy: [], monthlyExerciseMinutes: [], monthlyWorkoutMinutes: [],
                            monthlyStandHours: [], healthDataAvailable: false)
}
