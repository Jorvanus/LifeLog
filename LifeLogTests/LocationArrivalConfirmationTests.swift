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
