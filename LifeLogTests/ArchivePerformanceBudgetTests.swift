import Foundation
import Testing
@testable import LifeLog

/// Executable device-class budgets for the archive-shaped interaction paths. The
/// fixture is deliberately 32,000 rows so a test cannot pass by accidentally doing
/// no work; the limits are generous enough to catch a collapse, not to claim that a
/// simulator is evidence of physical-device performance.
@MainActor
struct ArchivePerformanceBudgetTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func archiveFixture(count: Int = 32_000) -> [Visit] {
        let labels = ["At home", "Working", "Walking", "Shopping"]
        return (0..<count).map { index in
            let arrival = base.addingTimeInterval(Double(index) * 1_800)
            return Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         userActivity: labels[index % labels.count],
                         source: "imported-journal")
        }
    }

    @Test("Returning to Timeline stays within budget on the archive fixture")
    func timelineReturnBudget() {
        let visits = archiveFixture()
        let day = TimelineView.interval(of: base.addingTimeInterval(31_000 * 1_800))
        let began = Date.now
        let rows = TimelineView.rows(from: visits, day: day, now: day.end)
        let elapsed = Date.now.timeIntervalSince(began)
        #expect(!rows.isEmpty)
        #expect(elapsed < Diagnostics.PerformanceBudget.returnToTimeline,
                "Timeline return took \(elapsed)s for the 32,000-row fixture")
    }

    @Test("Day, Week, Month, and Year Insights stay within their budgets")
    func insightsWindowBudgets() {
        let visits = archiveFixture()
        let windows: [(InsightWindow, TimeInterval)] = [
            (.day, Diagnostics.PerformanceBudget.insightsDay),
            (.week, Diagnostics.PerformanceBudget.insightsWeek),
            (.month, Diagnostics.PerformanceBudget.insightsMonth),
            (.year, Diagnostics.PerformanceBudget.insightsYear)
        ]
        for (window, budget) in windows {
            let interval = window.interval(containing: base)
            let began = Date.now
            let snapshot = InsightsSnapshot.make(visits: visits, window: window,
                                                 anchorDate: base, now: interval.end)
            let elapsed = Date.now.timeIntervalSince(began)
            #expect(snapshot.totalHours > 0)
            #expect(elapsed < budget,
                    "\(window.rawValue) Insights took \(elapsed)s for the 32,000-row fixture")
        }
    }

    @Test("Settings activity preparation stays within its budget on the archive fixture")
    func settingsOpeningBudget() {
        let visits = archiveFixture()
        let began = Date.now
        let summaries = ActivityStatistics.summaries(named: ["At home", "Working", "Walking", "Shopping"],
                                                      visits: visits, now: base)
        let elapsed = Date.now.timeIntervalSince(began)
        #expect(summaries.count == 4)
        #expect(elapsed < Diagnostics.PerformanceBudget.settingsOpening,
                "Settings preparation took \(elapsed)s for the 32,000-row fixture")
    }

    @Test("Backup setup encoding stays within its attended archive budget")
    func backupSetupBudget() throws {
        let visits = archiveFixture()
        let began = Date.now
        let data = try LocalBackupService.encodeBackup(visits: visits, places: [], corrections: [],
                                                       diagnostics: [], locationEvents: [],
                                                       activityDefinitionRecords: [])
        let elapsed = Date.now.timeIntervalSince(began)
        #expect(!data.isEmpty)
        #expect(elapsed < Diagnostics.PerformanceBudget.backupSetup,
                "Backup setup took \(elapsed)s for the 32,000-row fixture")
    }
}
