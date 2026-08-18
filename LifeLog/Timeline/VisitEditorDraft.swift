import Foundation

/// Owns draft normalization for VisitEditor. The view owns when a draft is
/// committed; this value owns what a valid commit contains, so validation can be
/// tested without SwiftUI, SwiftData, or a live map.
struct VisitEditorDraft: Equatable, Sendable {
    var placeName: String
    var activity: String
    var note: String
    var arrival: Date
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var recognitionConfidence: String?

    func normalized() -> VisitEditorDraft {
        let cleanArrival = arrival
        let cleanDeparture = departure.map { max($0, cleanArrival) }
        let cleanActivity = TextSafety.clean(activity, maximumLength: 80)
        return VisitEditorDraft(
            placeName: TextSafety.clean(placeName, maximumLength: 120),
            activity: cleanActivity,
            note: TextSafety.clean(note, maximumLength: 2_000),
            arrival: cleanArrival,
            departure: cleanDeparture,
            latitude: latitude,
            longitude: longitude,
            recognitionConfidence: recognitionConfidence
        )
    }

    var storedActivity: String? {
        let clean = TextSafety.clean(activity, maximumLength: 80)
        return clean.isEmpty ? nil : clean
    }
}
