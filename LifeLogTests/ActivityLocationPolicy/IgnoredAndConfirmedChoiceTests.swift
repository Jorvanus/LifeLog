import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// The review queue: confident-but-brief drive-bys are still queued, entries are
/// ranked by how much answering them would fix, and a stay the person already
/// labelled or ignored is never queued again.
@MainActor
struct IgnoredAndConfirmedChoiceTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    /// Built from a captured day: two "high confidence" stays of 3m46s and 5m46s on a
    /// commute, which the old confidence-only test could never queue.
    @Test("A brief stay never returned to is queued however sure Apple Maps was")
    func queuesConfidentDriveBys() {
        let drivePast = Visit(arrival: base, departure: base.addingTimeInterval(226),
                              latitude: -23.39, longitude: 150.49,
                              placeName: "Riverside Precinct", inferredActivity: "Visiting",
                              source: "automatic", recognitionConfidence: "high")
        // Home is brief here too, but it recurs, so it is not a passing stay.
        let homeMorning = Visit(arrival: base.addingTimeInterval(-3_600), departure: base,
                                latitude: -23.37, longitude: 150.51,
                                placeName: "Home", inferredActivity: "At home",
                                source: "automatic", recognitionConfidence: "learned")
        let homeEvening = Visit(arrival: base.addingTimeInterval(600), departure: base.addingTimeInterval(700),
                                latitude: -23.37, longitude: 150.51,
                                placeName: "Home", inferredActivity: "At home",
                                source: "automatic", recognitionConfidence: "learned")
        // Long enough to be somewhere they actually went.
        let shop = Visit(arrival: base.addingTimeInterval(2_000), departure: base.addingTimeInterval(4_400),
                         latitude: -23.44, longitude: 150.46,
                         placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                         source: "automatic", recognitionConfidence: "high")

        let entries = ReviewQueue.entries(in: [drivePast, homeMorning, homeEvening, shop],
                                          now: base.addingTimeInterval(7_200))

        #expect(entries.count == 1)
        #expect(entries.first?.visit === drivePast)
        #expect(entries.first?.reason == .passingStay)
    }

    @Test("The review queue leads with what is worth answering first")
    func ranksReviewQueueByImpact() {
        let current = Visit(arrival: base.addingTimeInterval(9_000),
                            latitude: -23.41, longitude: 150.53,
                            placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                            source: "automatic")
        // Unidentified, and the same coordinate keeps coming back: worth more than a
        // one-off because answering it corrects every visit there.
        let repeatedUnknown = (0..<3).map { index in
            Visit(arrival: base.addingTimeInterval(Double(index) * 3_600),
                  departure: base.addingTimeInterval(Double(index) * 3_600 + 1_800),
                  latitude: -23.38, longitude: 150.52,
                  placeName: Visit.unknownPlaceName, inferredActivity: "Visiting",
                  source: "automatic", recognitionConfidence: "low")
        }
        let weakGuess = Visit(arrival: base.addingTimeInterval(20_000),
                              departure: base.addingTimeInterval(23_600),
                              latitude: -23.42, longitude: 150.55,
                              placeName: "atWork Australia", inferredActivity: "Working",
                              source: "automatic", recognitionConfidence: "low")
        let drivePast = Visit(arrival: base.addingTimeInterval(30_000),
                              departure: base.addingTimeInterval(30_226),
                              latitude: -23.39, longitude: 150.49,
                              placeName: "Riverside Precinct", inferredActivity: "Visiting",
                              source: "automatic", recognitionConfidence: "high")

        let entries = ReviewQueue.entries(in: [weakGuess, drivePast, current] + repeatedUnknown,
                                          now: base.addingTimeInterval(40_000))

        #expect(entries.map(\.reason) == [.unidentified, .unidentified, .unidentified,
                                          .unidentified, .uncertainMatch, .passingStay])
        // The place they are standing in right now leads: it is the only one still
        // answerable from memory of being there.
        #expect(entries.first?.visit === current)
        // Then the repeated unknown, which accounts for an hour and a half across
        // three visits, ahead of the weak guess and the drive-by. Read without
        // subscripting: an unexpected count should fail the test, not trap and take
        // every other suite in the process down with it.
        #expect(entries.dropFirst().first?.impact == 5_400)
        #expect(entries.last?.visit === drivePast)
    }

    @Test("A place the person has already labelled or hidden is not queued again")
    func answeredStaysAreNotQueued() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let answered = Visit(arrival: base, departure: base.addingTimeInterval(200),
                             latitude: -23.39, longitude: 150.49,
                             placeName: "Riverside Precinct", inferredActivity: "Visiting",
                             userActivity: "Visiting", source: "automatic",
                             recognitionConfidence: "high")
        let ignored = Visit(arrival: base.addingTimeInterval(400), departure: base.addingTimeInterval(600),
                            latitude: -23.45, longitude: 150.41,
                            placeName: "Somewhere", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "high")
        // Inserted and saved first: an ignore is only recorded for a visit that
        // belongs to a store. Cleared afterwards because the registry is a
        // process-wide UserDefaults list shared with every other test.
        [answered, ignored].forEach(context.insert)
        try context.save()
        ignored.isIgnored = true
        defer { ignored.isIgnored = false }

        #expect(ignored.isIgnored)
        #expect(ReviewQueue.entries(in: [answered, ignored], now: base.addingTimeInterval(3_600)).isEmpty)

        // A visit that is not in the timeline yet has no ignore state at all, so it
        // cannot write a key that later matches a different unsaved visit.
        let unsaved = Visit(arrival: base, departure: base.addingTimeInterval(200),
                            latitude: -23.39, longitude: 150.49,
                            placeName: "Elsewhere", inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "high")
        unsaved.isIgnored = true
        #expect(unsaved.isIgnored == false)
    }
}
