import Foundation
import Testing
@testable import LifeLog

struct ActivityByPlaceAndTimeTests {
    private let calendar = Calendar.current
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func visit(hour: Int, activity: String, source: String, confidence: String?) -> Visit {
        let arrival = at(hour: hour)
        return Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_800),
                    latitude: 0, longitude: 0, placeName: "Cafe X",
                    inferredActivity: activity, userActivity: activity,
                    source: source, recognitionConfidence: confidence)
    }

    @Test("With no history at all, nothing is inferred")
    func noEvidenceInfersNothing() {
        #expect(ActivityByPlaceAndTime.infer(arrival: at(hour: 8), history: [], corrections: []) == nil)
    }

    @Test("A handful of bulk-imported rows alone is not enough evidence")
    func importedAloneIsNotEnough() {
        let history = (0..<3).map { _ in
            visit(hour: 8, activity: "Eating", source: "imported-journal", confidence: "imported")
        }
        #expect(ActivityByPlaceAndTime.infer(arrival: at(hour: 8), history: history, corrections: []) == nil)
    }

    @Test("Confirmed visits outweigh a larger pile of bulk-imported guesses")
    func confirmedOutweighsImported() {
        let imported = (0..<10).map { _ in
            visit(hour: 8, activity: "Eating", source: "imported-journal", confidence: "imported")
        }
        let confirmed = [
            visit(hour: 8, activity: "Reading", source: "automatic", confidence: "confirmed"),
            visit(hour: 8, activity: "Reading", source: "automatic", confidence: "confirmed"),
            visit(hour: 8, activity: "Reading", source: "automatic", confidence: "confirmed")
        ]
        #expect(ActivityByPlaceAndTime.infer(arrival: at(hour: 8), history: imported + confirmed,
                                             corrections: []) == "Reading")
    }

    @Test("Corrections alone can be enough evidence, without any matching visits")
    func correctionsCountAsStrongEvidence() {
        let corrections = [
            VisitCorrection(visitArrival: at(hour: 8), latitude: 0, longitude: 0,
                            previousPlaceName: "Cafe X", newPlaceName: "Cafe X",
                            previousActivity: "Eating", newActivity: "Reading"),
            VisitCorrection(visitArrival: at(hour: 8), latitude: 0, longitude: 0,
                            previousPlaceName: "Cafe X", newPlaceName: "Cafe X",
                            previousActivity: "Eating", newActivity: "Reading")
        ]
        #expect(ActivityByPlaceAndTime.infer(arrival: at(hour: 8), history: [], corrections: corrections) == "Reading")
    }

    @Test("Evidence from a different time of day does not count")
    func evidenceOutsideTheTimeBandIsIgnored() {
        // Evening (17:00-22:00), asked about morning (06:00-11:00) -- same place,
        // wrong band, so this is not evidence for what 8am at this place means.
        let eveningVisits = (0..<5).map { _ in
            visit(hour: 19, activity: "Working", source: "automatic", confidence: "learned")
        }
        #expect(ActivityByPlaceAndTime.infer(arrival: at(hour: 8), history: eveningVisits, corrections: []) == nil)
    }

    @Test("A weaker signal never counts for more than a confirmation")
    func weightOrdering() {
        #expect(ActivityByPlaceAndTime.weight(source: "imported-journal", recognitionConfidence: "imported") <
                ActivityByPlaceAndTime.weight(source: "automatic", recognitionConfidence: "learned"))
        #expect(ActivityByPlaceAndTime.weight(source: "automatic", recognitionConfidence: "learned") <
                ActivityByPlaceAndTime.weight(source: "automatic", recognitionConfidence: "confirmed"))
        // A person's confirmation outranks everything, whatever the source it landed on.
        #expect(ActivityByPlaceAndTime.weight(source: "imported-journal", recognitionConfidence: "confirmed") ==
                ActivityByPlaceAndTime.weight(source: "automatic", recognitionConfidence: "confirmed"))
    }
}
