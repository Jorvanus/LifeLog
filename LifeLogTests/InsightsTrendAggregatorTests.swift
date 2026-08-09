import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct InsightsTrendAggregatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    @Test("The aggregator fetches a year, resolves it off the main actor, and habits sees the whole span")
    func loadsAndAggregatesAYearInOnePass() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let span = InsightsTrends.range(endingAt: now, calendar: calendar)
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: span.end)!
        let twentyWeeksBack = calendar.date(byAdding: .weekOfYear, value: -20, to: span.end)!

        let setupContext = ModelContext(container)
        setupContext.insert(Visit(
            arrival: lastWeek.addingTimeInterval(3600), departure: lastWeek.addingTimeInterval(4 * 3600),
            latitude: -23.378, longitude: 150.511, placeName: "Cinema",
            inferredActivity: "Watching a movie", userActivity: "Watching a movie",
            source: "automatic", recognitionConfidence: "confirmed"
        ))
        setupContext.insert(Visit(
            arrival: twentyWeeksBack.addingTimeInterval(3600), departure: twentyWeeksBack.addingTimeInterval(4 * 3600),
            latitude: -23.378, longitude: 150.511, placeName: "Cinema",
            inferredActivity: "Watching a movie", userActivity: "Watching a movie",
            source: "automatic", recognitionConfidence: "confirmed"
        ))
        try setupContext.save()

        let aggregator = InsightsTrendAggregator(modelContainer: container)
        let data = try await aggregator.load(endingAt: now, calendar: calendar)

        #expect(data.itemCount == 2, "both visits sit inside habitWeeks, so both are fetched")
        #expect(data.weeklyTotals.count == InsightsTrends.habitWeeks)

        let habits = InsightsTrends.habits(from: data.weeklyTotals, calendar: calendar)
        #expect(habits.first?.headline == "Back to entertainment",
                "the return 20 weeks back is only visible with the full year in hand")
    }
}
