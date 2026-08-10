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
}
