import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// What actually invalidates a cached Insights snapshot vs. what is presentation-only
/// and must leave the cache alone.
struct CacheInvalidationTests {
    @Test("Insights invalidation actor advances its generation")
    func invalidationAdvancesGeneration() async {
        let cache = InsightsAggregationActor()
        let initial = await cache.currentGeneration()
        await cache.invalidate()
        #expect(await cache.currentGeneration() == initial + 1)
    }

    @Test("A minute tick never rebuilds an Insights snapshot")
    func minuteTickIsPresentationOnlyForEveryWindow() {
        for window in InsightWindow.allCases {
            #expect(InsightsSnapshotRefreshReason.minuteClockTick.rebuildsSnapshot == false,
                    "\(window.title) should retain its cached snapshot when only the clock changes")
        }
    }

    @Test("Selected period and data changes remain explicit snapshot inputs")
    func selectedPeriodAndDataChangesRebuildSnapshots() {
        let invalidatingReasons: [InsightsSnapshotRefreshReason] = [
            .initial, .selectedWindowChanged, .selectedDateChanged, .scopeChanged,
            .storeGenerationChanged, .healthGenerationChanged, .currentDayForeground
        ]
        for reason in invalidatingReasons {
            #expect(reason.rebuildsSnapshot)
        }
    }
}
