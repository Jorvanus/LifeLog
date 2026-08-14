import Foundation
import Testing
@testable import LifeLog

@MainActor
struct InsightsWeekdayPatternTests {
    private let calendar = Calendar.current
    private let day = insightsFixtureDay

    private func snapshot(_ visits: [Visit]) -> InsightsSnapshot {
        InsightsSnapshot.make(visits: visits, window: .day, anchorDate: day,
                              now: day.addingTimeInterval(24 * 3600))
    }

    /// Sleep is the largest and steadiest block of almost every day, so leaving it in
    /// flattened the seven bars into near-identical columns and hid the differences
    /// the chart exists to show.
    @Test("Sleep is left out of the weekly rhythm")
    func weekdayPatternsExcludeSleep() {
        let sleeping = Visit(arrival: day, departure: day.addingTimeInterval(7 * 3600),
                             latitude: -23.378, longitude: 150.511,
                             placeName: "Sleep", inferredActivity: "Sleeping",
                             userActivity: "Sleeping", source: "health-sleep",
                             recognitionConfidence: "device")
        let visits = [insightsStay(8, 12, place: "Gracemere Shopping World", activity: "Shopping"), sleeping]
        let weekday = calendar.component(.weekday, from: day)
        let pattern = snapshot(visits).weekdayPatterns.first { $0.weekday == weekday }

        #expect(pattern?.activities.contains { $0.category == "Sleep" } == false)
        #expect(pattern?.hours == 4)
    }

    /// The bars are drawn from this breakdown, so a day's bands must add up to the
    /// total printed beside it.
    @Test("A weekday's activities add up to its total")
    func weekdayBreakdownSumsToTotal() {
        let visits = [insightsStay(8, 12, place: "Gracemere Shopping World", activity: "Shopping"),
                      insightsStay(13, 15, place: "Rockhampton Hospital", activity: "Donate Blood")]
        let weekday = calendar.component(.weekday, from: day)
        let pattern = snapshot(visits).weekdayPatterns.first { $0.weekday == weekday }
        let summed = pattern?.activities.reduce(0) { $0 + $1.hours } ?? 0

        #expect(pattern?.activities.count == 2)
        #expect(abs(summed - (pattern?.hours ?? 0)) < 0.001)
    }

    @Test("Weekly rhythm averages matching weekdays across its history")
    func weekdayPatternsAverageAcrossHistory() {
        let nextWeek = day.addingTimeInterval(7 * 24 * 3600)
        let visits = [
            insightsStay(8, 12, place: "Gracemere Shopping World", activity: "Shopping"),
            Visit(arrival: nextWeek.addingTimeInterval(8 * 3600),
                  departure: nextWeek.addingTimeInterval(12 * 3600),
                  latitude: -23.378, longitude: 150.511,
                  placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                  userActivity: "Shopping", source: "automatic", recognitionConfidence: "learned")
        ]
        let range = DateInterval(start: day, duration: 14 * 24 * 3600)
        let weekday = calendar.component(.weekday, from: day)
        let pattern = InsightsSnapshot.weekdayPatterns(visits: visits, range: range, now: range.end)
            .first { $0.weekday == weekday }

        #expect(abs((pattern?.hours ?? 0) - 4) < 0.001)
        #expect(abs((pattern?.activities.first?.hours ?? 0) - 4) < 0.001)
    }

    /// A Monday-first region must not be told its week begins on Sunday.
    @Test("The week is ordered from the calendar's own first day")
    func weekOrderStartsAtFirstWeekday() {
        let ordered = WeekdayPattern.empty.inWeekOrder

        #expect(ordered.count == 7)
        #expect(ordered.first?.weekday == calendar.firstWeekday)
        #expect(Set(ordered.map(\.weekday)) == Set(1...7))
    }
}
