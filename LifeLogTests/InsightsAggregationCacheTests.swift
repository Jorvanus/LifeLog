import Testing
@testable import LifeLog

struct InsightsAggregationCacheTests {
    @Test("Insights invalidation actor advances its generation")
    func invalidationAdvancesGeneration() async {
        let cache = InsightsAggregationActor()
        let initial = await cache.currentGeneration()
        await cache.invalidate()
        #expect(await cache.currentGeneration() == initial + 1)
    }
}
