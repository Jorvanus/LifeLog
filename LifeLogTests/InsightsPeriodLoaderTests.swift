import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// Regression coverage for the fetch predicate in `InsightsPeriodLoader.reload`.
///
/// `InsightsSnapshot.makeSegments` selects and clips visits with `Visit.overlaps`,
/// which counts a visit as belonging to a range even when its `arrival` predates
/// the range's start -- as long as it hasn't departed yet by then. The SwiftData
/// fetch that supplies `makeSegments` with its candidate visits used to enforce a
/// stricter `arrival >= fetchStart`, silently dropping any visit that started
/// before the previous comparison period but ran into it, such as an overnight
/// sleep entry that began before local midnight. The missing visit read as a
/// missing category rather than a smaller one, turning "1h33m less sleep" into
/// "5h27m more" -- the previous total wasn't reduced, it vanished, so the whole
/// current total looked like the gain.
@MainActor
struct InsightsPeriodLoaderTests {
    @Test("A completed visit that starts before the previous period's fetch boundary but overlaps it is still counted")
    func overnightVisitStraddlingTheFetchBoundaryIsNotDropped() throws {
        // `.current`, not a freshly constructed `.gregorian` calendar: the loader
        // and `InsightsPeriodComparison` both default to `Calendar.current` when
        // resolving window boundaries, and a mismatched time zone here would shift
        // this test's synthetic boundary away from the one they actually compute.
        let calendar = Calendar.current
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, configurations: configuration)
        let context = ModelContext(container)

        // "Today" is 09:17 in, so the previous-day comparison window is
        // [yesterday 00:00, yesterday 09:17] -- the same elapsed-window pairing
        // `InsightsPeriodComparison` builds for a Day in progress.
        var nowComponents = DateComponents()
        nowComponents.year = 2026; nowComponents.month = 8; nowComponents.day = 22
        nowComponents.hour = 9; nowComponents.minute = 17; nowComponents.second = 51
        let now = calendar.date(from: nowComponents)!

        // Started 14 minutes before yesterday's midnight boundary, ran until 07:00
        // -- almost entirely inside the previous period, but its `arrival` sits
        // just outside it.
        var arrivalComponents = DateComponents()
        arrivalComponents.year = 2026; arrivalComponents.month = 8; arrivalComponents.day = 20
        arrivalComponents.hour = 23; arrivalComponents.minute = 46
        let arrival = calendar.date(from: arrivalComponents)!
        var departureComponents = DateComponents()
        departureComponents.year = 2026; departureComponents.month = 8; departureComponents.day = 21
        departureComponents.hour = 7
        let departure = calendar.date(from: departureComponents)!

        let sleepID = UUID()
        let sleep = Visit(arrival: arrival, departure: departure, latitude: 0, longitude: 0,
                          placeName: "Sleep", inferredActivity: "Sleeping",
                          source: "manual-sleep", recognitionConfidence: "manual", stableID: sleepID)
        context.insert(sleep)
        try context.save()

        // `InsightsPeriodLoader.reload` reads `RecordingObservation.startedAt()` off
        // `UserDefaults.standard` with no injection point, and the app's own launch
        // path (`AppLifecycleCoordinator`) writes a real "recording started" marker
        // there the moment this test bundle's host app comes up -- clamping both
        // periods to zero duration regardless of what this test actually fetched.
        // Push it far enough into the past to be a no-op, and restore it after.
        let observationDefaults = UserDefaults.standard
        let previousObservationStart = RecordingObservation.startedAt(defaults: observationDefaults)
        RecordingObservation.setStartedAt(arrival.addingTimeInterval(-86_400), defaults: observationDefaults)
        defer {
            if let previousObservationStart {
                RecordingObservation.setStartedAt(previousObservationStart, defaults: observationDefaults)
            } else {
                observationDefaults.removeObject(forKey: RecordingObservation.startedAtKey)
            }
        }

        let loader = InsightsPeriodLoader()
        loader.reload(window: .day, anchorDate: now, scope: .allHistory, now: now,
                     home: nil, savedPlaces: [], aggregationGeneration: 0, context: context)

        #expect(loader.visits.contains { $0.stableID == sleepID },
               "a visit overlapping the fetch window must be fetched even though its arrival predates it")

        let sleepComparison = try #require(
            loader.snapshot.comparisons.first { $0.name.localizedCaseInsensitiveContains("sleep") },
            "the previous period actually had sleep logged, so it must show up as a comparison"
        )
        #expect(sleepComparison.previousHours > 0,
               "the previous period's sleep total must not silently read as zero")
        #expect(sleepComparison.delta <= 0,
               "today logged less sleep than the previous period, so the delta must not read as a gain")
    }
}
