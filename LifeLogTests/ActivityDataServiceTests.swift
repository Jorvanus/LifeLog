import Foundation
import Testing
@testable import LifeLog

struct ActivityDataServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("No prior successful read floors at two days")
    func floorsAtTwoDaysWhenNeverRefreshed() {
        #expect(ActivityDataService.healthImportWindowDays(since: nil, now: now) == 2)
    }

    @Test("Frequent use stays at the two-day floor")
    func staysAtFloorForFrequentUse() {
        let recentlyRefreshed = now.addingTimeInterval(-5 * 60)
        #expect(ActivityDataService.healthImportWindowDays(since: recentlyRefreshed, now: now) == 2)
    }

    @Test("A multi-day absence widens the window to cover the real gap")
    func widensToCoverARealGap() {
        let aWeekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(ActivityDataService.healthImportWindowDays(since: aWeekAgo, now: now) == 7)
    }

    @Test("A very long absence is capped rather than left unbounded")
    func capsAVeryLongAbsence() {
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 24 * 60 * 60)
        #expect(ActivityDataService.healthImportWindowDays(since: sixtyDaysAgo, now: now) == 30)
    }

    @Test("A gap under a day still rounds up to the two-day floor")
    func roundsUpAPartialDayGap() {
        let twelveHoursAgo = now.addingTimeInterval(-12 * 60 * 60)
        #expect(ActivityDataService.healthImportWindowDays(since: twelveHoursAgo, now: now) == 2)
    }
}
