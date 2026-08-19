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
        let first = InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit, commute: nil,
                                   category: "Food & Drink", activity: "Eating", placeName: "New Cafe",
                                   start: base, end: base.addingTimeInterval(1_800), hours: 0.5,
                                   color: insightColor(for: "Food & Drink"), symbol: "fork.knife",
                                   isUnlogged: false, isLive: false)
        let second = InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit, commute: nil,
                                    category: "Food & Drink", activity: "Eating", placeName: "New Cafe",
                                    start: base.addingTimeInterval(1_800), end: base.addingTimeInterval(3_600), hours: 0.5,
                                    color: insightColor(for: "Food & Drink"), symbol: "fork.knife",
                                    isUnlogged: false, isLive: false)
        let result = MonthlyInsights.make(current: [first, second], previous: [],
                                          currentInterval: interval, previousInterval: interval)
        #expect(result.newPlaces.first?.name == "New Cafe")
        #expect(result.newPlaces.first?.visits == 1)
        #expect(result.placesByTime.first?.hours == 1)
        #expect(result.allPlaces.map(\.name) == ["New Cafe"])
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

    @Test("Month calendar aligns its first day for every weekday")
    func calendarAlignsEveryWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        var seen = Set<Int>()

        for month in 1...12 {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 1))!
            let day = MonthlyInsights.Day(date: date, dominantCategory: "Home", hours: 1, awayFraction: 0)
            let cells = MonthlyInsights.calendarCells(days: [day], calendar: calendar)
            let weekday = calendar.component(.weekday, from: date)
            let expectedLeading = (weekday - calendar.firstWeekday + 7) % 7
            #expect(cells.count % 7 == 0)
            #expect(cells.prefix(expectedLeading).allSatisfy { $0.day == nil })
            #expect(cells[expectedLeading].day?.date == date)
            seen.insert(weekday)
        }
        #expect(seen == Set(1...7))
    }

    @Test("Sparse months retain empty days alongside recorded days")
    func sparseMonthRetainsEmptyDays() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let interval = calendar.dateInterval(of: .month, for: start)!
        let visit = Visit(arrival: calendar.date(byAdding: .day, value: 4, to: start)!,
                          departure: calendar.date(byAdding: .day, value: 4, to: start)!.addingTimeInterval(3_600),
                          latitude: -27.47, longitude: 153.03,
                          placeName: "Home", inferredActivity: "Home", source: "automatic")
        let segment = InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit, commute: nil,
                                     category: "Home", activity: "Home", placeName: "Home",
                                     start: visit.arrival, end: visit.departure!, hours: 1,
                                     color: insightColor(for: "Home"), symbol: "house.fill",
                                     isUnlogged: false, isLive: false)
        let days = MonthlyInsights.daySummaries(segments: [segment], interval: interval,
                                                now: start.addingTimeInterval(86_400 * 5), calendar: calendar)
        #expect(days.count == 31)
        #expect(days[4].dominantCategory == "Home")
        #expect(days.filter { $0.dominantCategory == nil }.count == 30)
    }

    @Test("Current partial month keeps future calendar days visible")
    func currentPartialMonthKeepsFutureDays() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let interval = calendar.dateInterval(of: .month, for: start)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let days = MonthlyInsights.daySummaries(segments: [], interval: interval, now: now, calendar: calendar)
        #expect(days.count == 31)
        #expect(days[11].date == calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!)
        #expect(days[12...].allSatisfy { $0.dominantCategory == nil && $0.hours == 0 })
    }

    private var interval: DateInterval { DateInterval(start: base, duration: 30 * 86_400) }

    private func segment(category: String, hours: Double) -> InsightSegment {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(hours * 3_600),
                          latitude: -27.47, longitude: 153.03,
                          placeName: "Test", inferredActivity: category, source: "manual")
        return InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit, commute: nil,
                              category: category, activity: category, placeName: "Test",
                              start: base, end: base.addingTimeInterval(hours * 3_600), hours: hours,
                              color: insightColor(for: category), symbol: insightSymbol(for: category),
                              isUnlogged: false, isLive: false)
    }
}
