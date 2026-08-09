import Foundation
import MapKit
import Testing
@testable import LifeLog

struct InferenceEngineTests {
    @Test("Maps categories classify venues without name keywords")
    func mapsCategoryClassifiesAnonymousVenue() {
        #expect(InferenceEngine.canonicalActivity(placeName: "Chemist Warehouse", mapsCategory: .pharmacy) == "Healthcare")
        #expect(InferenceEngine.canonicalActivity(placeName: "Bean Lab", mapsCategory: .cafe) == "Eating")
        #expect(InferenceEngine.canonicalActivity(placeName: "BCC Cinemas", mapsCategory: .movieTheater) == "Watching a movie")
    }

    @Test("Maps category hints and deterministic activities share one source")
    func mapsHintUsesTheSameCategoryTable() {
        #expect(InferenceEngine.mapsHint(for: .pharmacy) == "Healthcare")
        #expect(InferenceEngine.mapsHint(for: .cafe) == "Food & Drink")
        #expect(InferenceEngine.mapsHint(for: .airportTerminal) == "Travel")
        #expect(InferenceEngine.mapsHint(for: nil) == "Other")
    }

    @Test("Name keywords still classify entries without a Maps category")
    func nameFallbackStillWorksWithoutMapsCategory() {
        #expect(InferenceEngine.canonicalActivity(placeName: "Corner Pharmacy") == "Healthcare")
        #expect(InferenceEngine.canonicalActivity(placeName: "Reading Cinemas") == "Watching a movie")
    }

    @Test("Explicit default activity still wins over Maps category")
    func defaultActivityWins() {
        #expect(InferenceEngine.canonicalActivity(placeName: "Anything", defaultActivity: "Working", mapsCategory: .cafe) == "Working")
    }
}
