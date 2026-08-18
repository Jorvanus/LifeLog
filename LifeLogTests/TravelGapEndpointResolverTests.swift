import Foundation
import Testing
@testable import LifeLog

struct TravelGapEndpointResolverTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(offset: TimeInterval, duration: TimeInterval?, name: String,
                       latitude: Double, longitude: Double, source: String = "automatic") -> Visit {
        let arrival = start.addingTimeInterval(offset)
        return Visit(arrival: arrival, departure: duration.map { arrival.addingTimeInterval($0) },
                     latitude: latitude, longitude: longitude, placeName: name,
                     inferredActivity: "Visiting", source: source)
    }

    @Test("A trailing Health walking fragment still exposes the surrounding places as travel endpoints")
    func skipsTrailingWalkingFragment() {
        let work = visit(offset: 0, duration: 60 * 60, name: "Work", latitude: -23.3762, longitude: 150.5111)
        let walking = visit(offset: 60 * 60, duration: 7 * 60, name: "Walking", latitude: 0, longitude: 0, source: "health-walking")
        let shop = visit(offset: 79 * 60, duration: 20 * 60, name: "Gracemere Shoppingworld", latitude: -23.4336, longitude: 150.4530)
        let gap = DateInterval(start: start.addingTimeInterval(67 * 60), end: start.addingTimeInterval(79 * 60))

        let endpoints = TravelGapEndpointResolver.endpoints(for: gap, in: [work, walking, shop])

        #expect(endpoints?.before === work)
        #expect(endpoints?.after === shop)
    }

    @Test("Nearby places do not present a likely-travel draft")
    func rejectsShortDistance() {
        let before = visit(offset: 0, duration: 60 * 60, name: "Cafe", latitude: -23.3762, longitude: 150.5111)
        let after = visit(offset: 72 * 60, duration: 10 * 60, name: "Office", latitude: -23.3765, longitude: 150.5112)
        let gap = DateInterval(start: start.addingTimeInterval(60 * 60), end: start.addingTimeInterval(72 * 60))

        #expect(TravelGapEndpointResolver.endpoints(for: gap, in: [before, after]) == nil)
    }

    @Test("An old place does not become a travel endpoint after a long unrecorded lead-in")
    func rejectsDistantPrecedingStay() {
        let before = visit(offset: 0, duration: 60 * 60, name: "Work", latitude: -23.3762, longitude: 150.5111)
        let after = visit(offset: 90 * 60, duration: 10 * 60, name: "Shop", latitude: -23.4336, longitude: 150.4530)
        let gap = DateInterval(start: start.addingTimeInterval(85 * 60), end: start.addingTimeInterval(90 * 60))

        #expect(TravelGapEndpointResolver.endpoints(for: gap, in: [before, after]) == nil)
    }
}
