import HealthKit
import Testing
@testable import LifeLog

/// Guards `HealthKitTypeCatalog` from the exact drift that motivated it: the
/// read-authorization set (`ActivityDataService.healthTypes`) and the
/// background-delivery observer set (`configureBackgroundDelivery`) were once
/// two independently hand-maintained lists, and the read set silently
/// omitted four types — walking/running distance, active energy, exercise
/// time, stand time — that `ActivitySampleReader` already queried for
/// Insights and the observer set already asked to be notified about.
///
/// `HKQuantityTypeIdentifier`/`HKCategoryTypeIdentifier` are plain
/// `RawRepresentable` string values with no HealthKit store or authorization
/// behind them, so this suite runs as an ordinary unit test with no device or
/// simulator Health data required — only `HKObjectType.quantityType(forIdentifier:)`
/// (a pure lookup) needs the framework loaded, which the simulator provides
/// regardless of authorization state.
struct HealthKitTypeCatalogTests {
    /// Mirrors exactly what `ActivitySampleReader.healthInsightsFixtures`
    /// queries by name, plus `HealthTrendMetric.allCases` — the real
    /// summary-query set Insights is built from. If a future query is added
    /// to `ActivitySampleReader` without also adding its identifier to
    /// `HealthKitTypeCatalog`, this pinned list stops matching the catalog
    /// and this test fails, the same way `SchemaFingerprintTests` pins a
    /// frozen schema version.
    private static let summaryQuantityIdentifiers: Set<HKQuantityTypeIdentifier> = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
        .appleExerciseTime, .appleStandTime,
        .restingHeartRate, .walkingHeartRateAverage,
        .heartRateRecoveryOneMinute, .respiratoryRate,
    ]
    private static let summaryCategoryIdentifiers: Set<HKCategoryTypeIdentifier> = [.sleepAnalysis]

    @Test("The catalog matches every identifier Insights actually queries")
    func catalogMatchesInsightsQueries() {
        #expect(Set(HealthKitTypeCatalog.quantityIdentifiers) == Self.summaryQuantityIdentifiers)
        #expect(Set(HealthKitTypeCatalog.categoryIdentifiers) == Self.summaryCategoryIdentifiers)
    }

    @Test("HealthTrendMetric's four identifiers are a subset of the catalog")
    func trendMetricsAreInTheCatalog() {
        let trendIdentifiers = Set(HealthTrendMetric.allCases.map(\.identifier))
        #expect(trendIdentifiers.isSubset(of: Set(HealthKitTypeCatalog.quantityIdentifiers)))
    }

    @Test("The observer set is exactly every quantity and category type plus the workout")
    func observedTypesMatchTheCatalog() {
        let expected = Set(HealthKitTypeCatalog.quantityTypes.map { $0 as HKObjectType })
            .union(HealthKitTypeCatalog.categoryTypes.map { $0 as HKObjectType })
            .union([HKWorkoutType.workoutType()])
        let observed = Set(HealthKitTypeCatalog.observedTypes.map { $0 as HKObjectType })
        #expect(observed == expected)
    }

    @Test("The read-authorization set is everything observed plus the workout route")
    func readTypesCoverEverythingObservedPlusTheRoute() {
        let observed = Set(HealthKitTypeCatalog.observedTypes.map { $0 as HKObjectType })
        let read = Set(HealthKitTypeCatalog.readTypes.map { $0 as HKObjectType })
        #expect(read == observed.union([HKSeriesType.workoutRoute()]))
    }

    /// The bug this whole suite exists to catch: before `HealthKitTypeCatalog`,
    /// these four identifiers were in the observer set but not in
    /// `healthTypes`, so a person who had granted everything they were asked
    /// for still had these four silently missing from every Insights query.
    @Test("The read set covers walking distance, active energy, exercise time, and stand time")
    func readSetCoversThePreviouslyOmittedActivityRingMetrics() {
        let missingBefore: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime, .appleStandTime,
        ]
        let readIdentifiers = Set(HealthKitTypeCatalog.readTypes.compactMap { $0 as? HKQuantityType }
            .map(\.identifier))
        for identifier in missingBefore {
            #expect(readIdentifiers.contains(identifier.rawValue),
                   "\(identifier.rawValue) must be in the read-authorization set")
        }
    }
}
