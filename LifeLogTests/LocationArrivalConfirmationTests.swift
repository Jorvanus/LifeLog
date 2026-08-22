import CoreLocation
import Testing
@testable import LifeLog

struct LocationArrivalConfirmationTests {
    private func sample(_ offset: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 12,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A launch arrival needs consecutive stationary live updates")
    func requiresRecentStationaryUpdates() {
        var confirmation = LocationArrivalConfirmation()
        let moving = sample()
        confirmation.append(location: moving, stationary: false)
        #expect(confirmation.confirmedLocation == nil)

        confirmation.append(location: sample(1), stationary: true)
        #expect(confirmation.confirmedLocation == nil)

        let stationary = sample(2)
        confirmation.append(location: stationary, stationary: true)
        #expect(confirmation.confirmedLocation == stationary)
    }

    @Test("A confirmation burst has a hard sample cap")
    func stopsAcceptingSamplesAtLimit() {
        var confirmation = LocationArrivalConfirmation()
        for offset in 0...LocationArrivalConfirmation.maximumSamples {
            confirmation.append(location: sample(TimeInterval(offset)), stationary: true)
        }

        #expect(confirmation.samples.count == LocationArrivalConfirmation.maximumSamples)
        #expect(confirmation.hasReachedSampleLimit)
    }

    private func sample(_ offset: TimeInterval, latitudeOffset: Double, accuracy: CLLocationAccuracy = 12) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47 + latitudeOffset, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: accuracy,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A cluster that never reads stationary still confirms once it spans long enough")
    func clusteredSamplesConfirmWithoutTheStationaryFlag() {
        // The exact shape observed on-device 2026-08-10, indoors: every sample
        // reads stationary=false, but the phone never actually moved.
        var confirmation = LocationArrivalConfirmation()
        for offset in stride(from: 0, through: 8, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: 0), stationary: false)
        }
        #expect(confirmation.confirmedLocation != nil)
    }

    @Test("A cluster spanning less than the minimum time does not confirm")
    func briefClusterDoesNotConfirm() {
        var confirmation = LocationArrivalConfirmation()
        for offset in stride(from: 0, through: 5, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: 0), stationary: false)
        }
        #expect(confirmation.confirmedLocation == nil)
    }

    @Test("Real movement across the window does not confirm as stationary")
    func movingClusterDoesNotConfirm() {
        var confirmation = LocationArrivalConfirmation()
        // ~0.0009 degrees latitude is roughly 100 m -- comfortably past the
        // cluster tolerance even at this accuracy, over an 8-second span.
        for offset in stride(from: 0, through: 8, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: Double(offset) * 0.0009 / 8),
                                stationary: false)
        }
        #expect(confirmation.confirmedLocation == nil)
    }

    @Test("Typed callback adapter preserves delayed arrivals without touching Core Location state")
    func delayedArrivalIsAdaptedDeterministically() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = CoreLocationEventAdapter(now: { now })
        let visit = MockCLVisit(coordinate: .init(latitude: -27.47, longitude: 153.03),
                                horizontalAccuracy: 12,
                                arrivalDate: now.addingTimeInterval(-7 * 24 * 60 * 60),
                                departureDate: .distantFuture)
        guard case let .visitArrival(_, _, _, delay)? = adapter.event(for: visit) else {
            Issue.record("Expected an arrival event")
            return
        }
        #expect(delay == 7 * 24 * 60 * 60)
    }

    @Test("A newer place-resolution token rejects a stale Maps response")
    @MainActor
    func staleMapsLookupIsRejected() {
        let coordinator = PlaceResolutionCoordinator()
        let visit = Visit(arrival: .now, latitude: -27.47, longitude: 153.03,
                          placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting")
        let old = coordinator.begin(for: visit)
        let new = coordinator.begin(for: visit)
        #expect(coordinator.isCurrent(old, for: visit) == false)
        #expect(coordinator.isCurrent(new, for: visit))
    }

    @Test("A Core Location failure retains the framework's reason in diagnostics")
    @MainActor
    func locationFailureKeepsFrameworkDetails() {
        var recordedMessage: String?
        let recorder = LocationRecorder(diagnosticsRecorder: .init { _, message, _ in
            recordedMessage = message
        })
        let error = NSError(domain: "kCLErrorDomain", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Location permission denied"])

        recorder.locationManager(CLLocationManager(), didFailWithError: error)

        #expect(recorder.lastError == "Location updates are temporarily unavailable.")
        #expect(recordedMessage == "A location update failed (kCLErrorDomain 1): Location permission denied")
    }

    @Test("Relaunch recovery only starts the background workflow when it can be useful")
    func recoveryStartPolicyIsExplicit() {
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: true, authorization: .authorizedAlways
        ))
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: true, authorization: .notDetermined
        ) == false)
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: false, authorization: .authorizedAlways
        ) == false)
    }

    @Test("A restart rebuilds the location session when the held one is gone")
    func deadServiceSessionIsRebuiltRatherThanAssumedLive() {
        // The bug: the recorder kept `.always` as its requirement after the session
        // behind it ended, so restarting background recording matched the stale
        // requirement and did nothing. Recording stayed off until the app was quit.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .always, hasLiveSession: false, required: .always
        ))
        // A live session for the same requirement is the one case that must not be
        // torn down and rebuilt, or every restart would drop delivery for a moment.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .always, hasLiveSession: true, required: .always
        ) == false)
        // Upgrading from the when-in-use session `requestPermission` holds.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .whenInUse, hasLiveSession: true, required: .always
        ))
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: nil, hasLiveSession: false, required: .always
        ))
    }

    // MARK: - GeofenceMonitor.plan

    private func rankedPlace(_ name: String, latitude: Double = -27.47, longitude: Double = 153.03) -> MonitoredPlaces.Ranked {
        .init(name: name, latitude: latitude, longitude: longitude, radius: 100, visits: 1, lastVisit: .now)
    }

    @Test("A region synchronisation plan adds everything wanted when nothing is monitored yet")
    func planAddsEverythingFromEmpty() {
        let wanted = [rankedPlace("Home"), rankedPlace("Work")]
        let plan = GeofenceMonitor.plan(wanted: wanted, monitoredIdentifiers: [])
        #expect(Set(plan.toAdd.map(\.identifier)) == Set(wanted.map(\.identifier)))
        #expect(plan.toRemove.isEmpty)
    }

    @Test("A region synchronisation plan changes nothing once the monitored set already matches")
    func planIsEmptyWhenAlreadySynchronised() {
        let wanted = [rankedPlace("Home"), rankedPlace("Work")]
        let plan = GeofenceMonitor.plan(wanted: wanted, monitoredIdentifiers: Set(wanted.map(\.identifier)))
        #expect(plan.toAdd.isEmpty)
        #expect(plan.toRemove.isEmpty)
    }

    @Test("A region synchronisation plan only touches what actually changed")
    func planIsMinimalOnAMixedSet() {
        let home = rankedPlace("Home")
        let work = rankedPlace("Work")
        let stale = "place|stale-gym|-27.50000,153.05000"
        // Home is already monitored and still wanted -- neither added nor removed.
        // Work is wanted but not yet monitored -- added. `stale` is monitored but no
        // longer wanted -- removed.
        let plan = GeofenceMonitor.plan(wanted: [home, work], monitoredIdentifiers: [home.identifier, stale])
        #expect(plan.toAdd.map(\.identifier) == [work.identifier])
        #expect(plan.toRemove == [stale])
    }

    // MARK: - ArrivalConfirmationSession

    private func stationarySample(_ offset: TimeInterval) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 12,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A session folds a second begin into the running burst instead of starting another")
    @MainActor
    func sessionFoldsRepeatedBeginIntoRunningBurst() {
        let session = ArrivalConfirmationSession()
        #expect(session.begin(pendingArrival: nil))
        #expect(session.isActive)
        #expect(!session.begin(pendingArrival: nil), "a second begin while one is active must fold in, not restart")
    }

    @Test("A CLVisit arrival supersedes an in-flight launch check")
    @MainActor
    func sessionArrivalSupersedesBareLaunchCheck() {
        let session = ArrivalConfirmationSession()
        #expect(session.begin(pendingArrival: nil))
        let arrival = PendingArrival(coordinate: .init(latitude: -27.47, longitude: 153.03),
                                     arrival: .now, callbackType: .visitArrival, accuracy: 10)
        #expect(session.begin(pendingArrival: arrival), "an arrival must cancel and restart the bare launch check")
        #expect(session.pendingArrival?.arrival == arrival.arrival)
    }

    @Test("A finished session reports its samples' outcome and becomes inactive")
    @MainActor
    func sessionFinishReportsOutcomeAndClears() {
        let session = ArrivalConfirmationSession()
        _ = session.begin(pendingArrival: nil)
        _ = session.append(location: stationarySample(0), stationary: false)
        _ = session.append(location: stationarySample(1), stationary: true)
        let count = session.append(location: stationarySample(2), stationary: true)
        #expect(count == 3)

        let outcome = session.finish()
        #expect(outcome?.confirmedLocation != nil)
        #expect(outcome?.sampleCount == 3)
        #expect(!session.isActive)
        // A finished session can begin again immediately.
        #expect(session.begin(pendingArrival: nil))
    }

    @Test("Cancelling an inactive-again session is a no-op, not an outcome")
    @MainActor
    func sessionFinishIsNilWhenNothingIsActive() {
        let session = ArrivalConfirmationSession()
        #expect(session.finish() == nil)
    }

    @Test("A waiter resumes when the session finishes, not before")
    @MainActor
    func sessionAwaiterResumesOnFinish() async {
        let session = ArrivalConfirmationSession()
        _ = session.begin(pendingArrival: nil)
        let waiter = Task { await session.awaitCompletion() }
        // Give the waiter a chance to register before the session ends.
        await Task.yield()
        session.cancel()
        await waiter.value
    }
}

/// `CLVisit` has no public initializer -- CoreLocation only ever hands one to the
/// delegate itself -- so a test that needs one overrides its read-only properties
/// on a subclass instead.
private final class MockCLVisit: CLVisit {
    private let mockCoordinate: CLLocationCoordinate2D
    private let mockHorizontalAccuracy: CLLocationAccuracy
    private let mockArrivalDate: Date
    private let mockDepartureDate: Date

    init(coordinate: CLLocationCoordinate2D, horizontalAccuracy: CLLocationAccuracy,
         arrivalDate: Date, departureDate: Date) {
        self.mockCoordinate = coordinate
        self.mockHorizontalAccuracy = horizontalAccuracy
        self.mockArrivalDate = arrivalDate
        self.mockDepartureDate = departureDate
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("MockCLVisit does not support NSCoding")
    }

    override var coordinate: CLLocationCoordinate2D { mockCoordinate }
    override var horizontalAccuracy: CLLocationAccuracy { mockHorizontalAccuracy }
    override var arrivalDate: Date { mockArrivalDate }
    override var departureDate: Date { mockDepartureDate }
}
