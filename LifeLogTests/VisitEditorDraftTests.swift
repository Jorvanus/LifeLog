import Foundation
import Testing
@testable import LifeLog

struct VisitEditorDraftTests {
    @Test("Visit drafts normalize text and never save a departure before arrival")
    func normalizesBeforePersistence() {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = VisitEditorDraft(placeName: "  Cafe  ", activity: "  ", note: String(repeating: "n", count: 2_100),
                                     arrival: arrival, departure: arrival.addingTimeInterval(-60),
                                     latitude: -23.37, longitude: 150.51, recognitionConfidence: nil)
        let normalized = draft.normalized()
        #expect(normalized.placeName == "Cafe")
        #expect(normalized.storedActivity == nil)
        #expect(normalized.note.count == 2_000)
        #expect(normalized.departure == arrival)
    }
}
