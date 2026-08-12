import Foundation
import Testing
@testable import LifeLog

struct MonthlyInsightsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Month changes require both a meaningful hour and percentage difference")
    func suppressesTrivialChanges() {
        let current = [segment(category: "Travel", hours: 5)]
        let previous = [segment(category: "Travel", hours: 4.2)]
        let result = MonthlyInsights.make(current: current, previous: previous,
                                          currentInterval: interval, previousInterval: interval)
        #expect(result.changes.isEmpty)
        #expect(result.headline == nil)
    }

    @Test("Month reports a supported activity change and keeps its category colour")
    func reportsMeaningfulChange() {
        let current = [segment(category: "Travel", hours: 8), segment(category: "Home", hours: 8)]
        let previous = [segment(category: "Travel", hours: 3), segment(category: "Home", hours: 8)]
        let result = MonthlyInsights.make(current: current, previous: previous,
                                          currentInterval: interval, previousInterval: interval)
        #expect(result.changes.first?.category == "Travel")
        #expect(result.changes.first?.delta == 5)
        #expect(result.headline == "5h more away from Home than last month")
        #expect(result.balance.map(\.name).contains("Travel"))
    }

    @Test("Month place story exposes new places and counts a split visit once")
    func placeStory() {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                          latitude: -27.47, longitude: 153.03,
                          placeName: "New Cafe", inferredActivity: "Eating", source: "automatic")
        let first = InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit,
                                   category: "Food & Drink", activity: "Eating", placeName: "New Cafe",
                                   start: base, end: base.addingTimeInterval(1_800), hours: 0.5,
                                   color: insightColor(for: "Food & Drink"), symbol: "fork.knife",
                                   isUnlogged: false, isLive: false)
        let second = InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit,
                                    category: "Food & Drink", activity: "Eating", placeName: "New Cafe",
                                    start: base.addingTimeInterval(1_800), end: base.addingTimeInterval(3_600), hours: 0.5,
                                    color: insightColor(for: "Food & Drink"), symbol: "fork.knife",
                                    isUnlogged: false, isLive: false)
        let result = MonthlyInsights.make(current: [first, second], previous: [],
                                          currentInterval: interval, previousInterval: interval)
        #expect(result.newPlaces.first?.name == "New Cafe")
        #expect(result.newPlaces.first?.visits == 1)
        #expect(result.placesByTime.first?.hours == 1)
    }

    @Test("Month calendar retains every day, including future and empty days")
    func calendarKeepsEmptyDays() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let month = calendar.dateInterval(of: .month, for: start)!
        let days = MonthlyInsights.daySummaries(segments: [], interval: month, now: month.start)
        #expect(days.count == 31)
        #expect(days.allSatisfy { $0.dominantCategory == nil && $0.hours == 0 })
    }

    private var interval: DateInterval { DateInterval(start: base, duration: 30 * 86_400) }

    private func segment(category: String, hours: Double) -> InsightSegment {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(hours * 3_600),
                          latitude: -27.47, longitude: 153.03,
                          placeName: "Test", inferredActivity: category, source: "manual")
        return InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit,
                              category: category, activity: category, placeName: "Test",
                              start: base, end: base.addingTimeInterval(hours * 3_600), hours: hours,
                              color: insightColor(for: category), symbol: insightSymbol(for: category),
                              isUnlogged: false, isLive: false)
    }
}
