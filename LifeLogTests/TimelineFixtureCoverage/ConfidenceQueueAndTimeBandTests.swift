import Foundation
import Testing
@testable import LifeLog

/// Presentation policy for review queues: which visits need a person's
/// confirmation or categorisation versus which are settled, and which time
/// band a bulk edit's scope falls into.
@MainActor
struct ConfidenceQueueAndTimeBandTests {
    private let base = TimelineFixtureBuilders.referenceDate()

    @Test("A weak Apple Maps guess is queued for confirmation rather than accepted silently")
    func lowConfidenceGuessNeedsConfirmation() {
        // Mirrors a real capture: Maps matched a workplace onto a home coordinate
        // and returned it with low confidence.
        let guessed = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "atWork Australia - Gracemere",
                            inferredActivity: "Working",
                            source: "automatic", recognitionConfidence: "low")

        // It has a name, so it is not "uncategorised" — but it still needs a person.
        #expect(guessed.needsCategorisation == false)
        #expect(guessed.needsConfirmation)
        #expect(guessed.needsReview)
    }

    @Test("Confident and person-labelled places are not queued for review")
    func settledPlacesAreNotQueued() {
        let confident = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                              latitude: -23.37, longitude: 150.51, placeName: "Gracemere Shopping World",
                              inferredActivity: "Shopping", source: "automatic",
                              recognitionConfidence: "high")
        #expect(confident.needsReview == false)

        // A weak guess the person has already answered for.
        let answered = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                             latitude: -23.37, longitude: 150.51, placeName: "atWork Australia - Gracemere",
                             inferredActivity: "Working", userActivity: "At home",
                             source: "automatic", recognitionConfidence: "low")
        #expect(answered.needsConfirmation == false)
        #expect(answered.needsReview == false)

        // Learned Saved Places and manual entries are settled by definition.
        let learned = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51, placeName: "Home",
                            inferredActivity: "At home", source: "automatic",
                            recognitionConfidence: "learned")
        #expect(learned.needsReview == false)
        let manual = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                           latitude: -23.37, longitude: 150.51, placeName: "Somewhere",
                           inferredActivity: "Visiting", source: "manual",
                           recognitionConfidence: "low")
        #expect(manual.needsReview == false)
    }

    @Test("An unidentified place still needs categorising, not confirming")
    func unidentifiedPlaceStillNeedsCategorising() {
        let unknown = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51,
                            placeName: Visit.unknownPlaceName, inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "low")
        #expect(unknown.needsCategorisation)
        #expect(unknown.needsConfirmation == false)
        #expect(unknown.needsReview)
    }

    @Test("Time bands scope a bulk change to the right entries")
    func timeBandsScopeCorrectly() {
        let calendar = Calendar.current
        func at(_ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 30, second: 0, of: base)!
        }
        #expect(PlaceTimeBand.night.contains(at(3)))
        #expect(PlaceTimeBand.night.contains(at(7)) == false)
        #expect(PlaceTimeBand.morning.contains(at(7)))
        #expect(PlaceTimeBand.day.contains(at(13)))
        #expect(PlaceTimeBand.evening.contains(at(19)))
        #expect(PlaceTimeBand.lateNight.contains(at(23)))
        // "Any time" must cover every hour, or a bulk change would silently skip rows.
        for hour in 0..<24 { #expect(PlaceTimeBand.allDay.contains(at(hour))) }
        // The bands must not overlap, so an entry is only ever changed once.
        for hour in 0..<24 {
            let matches = PlaceTimeBand.allCases
                .filter { $0 != .allDay && $0.contains(at(hour)) }
            #expect(matches.count == 1, "hour \(hour) matched \(matches.count) bands")
        }
    }
}
