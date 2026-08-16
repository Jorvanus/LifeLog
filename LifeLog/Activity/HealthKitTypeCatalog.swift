import HealthKit

/// The one list of HealthKit types LifeLog cares about. Every other set —
/// read-authorization request, background-delivery observers, and the
/// per-type status/name lookups in `ActivityDataService` — is derived from
/// this rather than declaring its own, independent literal.
///
/// Before this existed, `ActivityDataService.healthTypes` (the authorization
/// request set) and `configureBackgroundDelivery()`'s own inline type list
/// (the observer set) were two separately hand-maintained arrays that had
/// already drifted: the observer set asked for walking/running distance,
/// active energy, exercise time, and stand time — the four metrics
/// `ActivitySampleReader.healthInsightsFixtures` queries for Insights — but
/// the authorization set never asked the person for them, so those queries
/// silently returned nothing on a device that had granted everything the
/// app actually prompted for.
enum HealthKitTypeCatalog {
    /// Every quantity type `ActivitySampleReader` queries: steps and the four
    /// Activity-ring metrics read by `healthInsightsFixtures`, plus the four
    /// heart/breathing trend metrics read by `healthTrendFixtures` — see
    /// `HealthTrendMetric.allCases`.
    static let quantityIdentifiers: [HKQuantityTypeIdentifier] =
        [.stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime, .appleStandTime]
        + HealthTrendMetric.allCases.map(\.identifier)

    /// Every category type read. Sleep is the only one today —
    /// `ActivitySampleReader.sleepRecords`/`anchoredSleepRecords`.
    static let categoryIdentifiers: [HKCategoryTypeIdentifier] = [.sleepAnalysis]

    static var quantityTypes: [HKQuantityType] {
        quantityIdentifiers.compactMap(HKObjectType.quantityType(forIdentifier:))
    }
    static var categoryTypes: [HKCategoryType] {
        categoryIdentifiers.compactMap(HKObjectType.categoryType(forIdentifier:))
    }

    /// Sample types worth an `HKObserverQuery`/background-delivery
    /// registration: every quantity and category type above, plus the
    /// workout itself. A workout route rides along with its owning workout
    /// and has no samples of its own to observe, so it is requested for read
    /// access below but never registered here.
    static var observedTypes: [HKSampleType] {
        var types: [HKSampleType] = quantityTypes
        types += categoryTypes
        types.append(HKWorkoutType.workoutType())
        return types
    }

    /// Every sample type LifeLog requests read authorization for: everything
    /// observed, plus the workout route series HealthKit tracks under its
    /// own permission — see `ActivityDataService.authorizationProbe(for:)`
    /// for why a route's status can only be checked alongside its parent
    /// workout type.
    static var readTypes: Set<HKSampleType> {
        var types = Set(observedTypes)
        types.insert(HKSeriesType.workoutRoute())
        return types
    }
}
