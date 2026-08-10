import Foundation
import Testing
@testable import LifeLog

struct CommuteDetectionTests {
    @Test("An overlapping visit does not crash commute detection")
    func overlappingVisitsDoNotCrash() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let home = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic")
        // Arrives 5 minutes before Home's departure — stays are sorted by arrival,
        // not departure, so this candidate still comes after `home` in that order
        // despite overlapping it. DateInterval.init(start:end:) traps on end < start;
        // this is the exact shape that crashed on-device 2026-08-10 adding a
        // backfilled manual Work visit that overlapped the stay before it.
        let work = Visit(arrival: start.addingTimeInterval(55 * 60), departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "manual")
        let commutes = CommuteDetection.commutes(in: [home, work])
        #expect(commutes.isEmpty)
    }

    @Test("A normal gap between Home and Work is recognised as a commute")
    func normalCommuteIsDetected() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let home = Visit(arrival: start, departure: start.addingTimeInterval(60 * 60),
                         latitude: 0, longitude: 0, placeName: "Home",
                         inferredActivity: "At home", source: "automatic")
        let work = Visit(arrival: start.addingTimeInterval(90 * 60), departure: start.addingTimeInterval(9 * 60 * 60),
                         latitude: 0, longitude: 0, placeName: "Work",
                         inferredActivity: "Working", source: "automatic")
        let commutes = CommuteDetection.commutes(in: [home, work])
        let commute = try #require(commutes.first)
        #expect(commutes.count == 1)
        #expect(commute.direction == .toWork)
        let expectedDuration: TimeInterval = 30 * 60
        #expect(commute.duration == expectedDuration)
    }
}
