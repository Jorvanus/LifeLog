import Foundation
import Testing
@testable import LifeLog

/// Guards the cost of rebuilding a snapshot at archive scale, not just on a handful
/// of fixture rows.
@MainActor
struct ResolverPerformanceTests {
    private let day = Calendar(identifier: .gregorian)
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    /// The aggregation was once O(boundaries × visits) and took several seconds on a
    /// few thousand rows. Nothing has exercised it at archive scale since, so this is
    /// the guard against it quietly becoming quadratic again. The bound is loose on
    /// purpose — it is there to catch a collapse, not to police milliseconds.
    @Test("A year of archive aggregates without becoming quadratic")
    func aYearOfArchiveAggregates() {
        let labels = ["Working", "At home", "Shopping", "Eating", "Sleeping"]
        // Spread across the window actually being analysed. Built from a fixed spacing
        // instead, the rows landed outside it, and the test passed through in 0.2s
        // having aggregated nothing at all — proving neither correctness nor speed.
        let year = InsightWindow.year.interval(containing: day)
        let now = year.end.addingTimeInterval(-1)
        let count = 32_000
        let spacing = year.duration / Double(count)
        let visits = (0..<count).map { index -> Visit in
            let arrival = year.start.addingTimeInterval(Double(index) * spacing)
            return Visit(arrival: arrival, departure: arrival.addingTimeInterval(spacing * 0.8),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         userActivity: labels[index % labels.count],
                         source: "imported-journal")
        }

        let began = Date.now
        let snapshot = InsightsSnapshot.make(visits: visits, window: .year, anchorDate: day, now: now)
        let elapsed = Date.now.timeIntervalSince(began)

        #expect(snapshot.loggedHours > 0, "the fixture has to land inside the window to test anything")
        #expect(!snapshot.slices.isEmpty)
        #expect(snapshot.totalHours > 0)
        #expect(elapsed < Diagnostics.PerformanceBudget.insightsYear,
                "32,000 rows took \(String(format: "%.1f", elapsed))s — the aggregation has collapsed")
    }
}
