import Foundation
import CoreLocation
import Testing
@testable import LifeLog

struct WalkBreadcrumbStoreTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        WalkBreadcrumbStore.clear()
    }

    @Test("Recording is a no-op unless tracking is turned on")
    func recordingRequiresTrackingEnabled() {
        WalkRouteTracking.isEnabled = false
        defer { WalkRouteTracking.isEnabled = false }
        WalkBreadcrumbStore.record(location(at: base))
        #expect(WalkBreadcrumbStore.breadcrumbs(in: wideInterval).isEmpty)
    }

    @Test("A recorded breadcrumb is returned for an interval it falls inside")
    func breadcrumbInsideIntervalIsReturned() {
        WalkRouteTracking.isEnabled = true
        defer { WalkRouteTracking.isEnabled = false }
        WalkBreadcrumbStore.record(location(at: base.addingTimeInterval(300)))
        let interval = DateInterval(start: base, end: base.addingTimeInterval(600))
        let found = WalkBreadcrumbStore.breadcrumbs(in: interval)
        #expect(found.count == 1)
        #expect(found.first?.latitude == -27.47)
    }

    @Test("A breadcrumb outside the queried interval is excluded")
    func breadcrumbOutsideIntervalIsExcluded() {
        WalkRouteTracking.isEnabled = true
        defer { WalkRouteTracking.isEnabled = false }
        WalkBreadcrumbStore.record(location(at: base.addingTimeInterval(-3_600)))
        let interval = DateInterval(start: base, end: base.addingTimeInterval(600))
        #expect(WalkBreadcrumbStore.breadcrumbs(in: interval).isEmpty)
    }

    @Test("Breadcrumbs come back sorted oldest first regardless of recording order")
    func breadcrumbsAreSortedByTime() {
        WalkRouteTracking.isEnabled = true
        defer { WalkRouteTracking.isEnabled = false }
        WalkBreadcrumbStore.record(location(at: base.addingTimeInterval(400)))
        WalkBreadcrumbStore.record(location(at: base.addingTimeInterval(100)))
        WalkBreadcrumbStore.record(location(at: base.addingTimeInterval(250)))
        let found = WalkBreadcrumbStore.breadcrumbs(in: wideInterval)
        #expect(found.map(\.recordedAt) == found.map(\.recordedAt).sorted())
    }

    @Test("A breadcrumb older than the retention window is pruned on the next write")
    func agedOutBreadcrumbIsPruned() {
        WalkRouteTracking.isEnabled = true
        defer { WalkRouteTracking.isEnabled = false }
        let old = base.addingTimeInterval(-10 * 24 * 60 * 60)
        WalkBreadcrumbStore.record(location(at: old), now: old)
        // A later write is what actually triggers the trim, mirroring how it runs
        // on the live location-callback path.
        WalkBreadcrumbStore.record(location(at: base), now: base)
        let found = WalkBreadcrumbStore.breadcrumbs(in: DateInterval(start: old.addingTimeInterval(-1),
                                                                      end: base.addingTimeInterval(1)))
        #expect(found.count == 1)
        #expect(found.first?.recordedAt == base)
    }

    @Test("A routed passive walk never becomes a place to review, confirm, or learn")
    func routedWalkNeverSurfacesAsAPlace() {
        // The guarantee this whole feature depends on: attaching a route must never
        // make a Walking visit eligible for the Review Queue, place confirmation, or
        // geofence learning -- all of that is gated on `visitSource`, never on having
        // coordinates, and this visit's own latitude/longitude stay at 0 throughout.
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(600),
                          latitude: 0, longitude: 0, placeName: "Walking",
                          inferredActivity: "Walking", source: "health-walking")
        visit.route = [RoutePoint(latitude: -27.47, longitude: 153.03, time: base.addingTimeInterval(120)),
                       RoutePoint(latitude: -27.471, longitude: 153.031, time: base.addingTimeInterval(300))]

        #expect(visit.latitude == 0)
        #expect(visit.longitude == 0)
        #expect(visit.hasRoute)
        #expect(!visit.needsCategorisation)
        #expect(!visit.needsConfirmation)
        #expect(ReviewQueue.reason(for: visit, visitCount: 1) == nil)
        #expect(!ActivityLocationPolicy.isLocationVisit(visit))
    }

    private var wideInterval: DateInterval {
        DateInterval(start: base.addingTimeInterval(-3_600), end: base.addingTimeInterval(3_600))
    }

    private func location(at time: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03),
                  altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: time)
    }
}
