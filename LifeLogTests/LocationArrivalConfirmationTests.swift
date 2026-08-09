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
}
