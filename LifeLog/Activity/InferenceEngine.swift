import Foundation

enum InferenceEngine {
    /// Infers an activity from the place name. `mapsHint` carries the Apple Maps
    /// point-of-interest wording during a lookup so a business whose name has no
    /// keyword ("Kōhi") can still be classified. It is a transient signal only —
    /// LifeLog does not store or display a place type.
    static func activity(placeName: String, defaultActivity: String? = nil,
                         arrival: Date = .now, mapsHint: String = "") -> String {
        if let defaultActivity, !defaultActivity.isEmpty { return defaultActivity }
        let text = "\(placeName) \(mapsHint)".lowercased()
        let rules: [(String, [String])] = [
            ("Watching a movie", ["cinema", "movie theater", "movie theatre", "film theatre", "event cinemas", "reading cinemas"]),
            ("Working", ["work", "office", "cowork"]),
            ("Exercising", ["gym", "fitness", "pool", "sport", "park"]),
            ("Shopping", ["shop", "store", "market", "mall", "supermarket"]),
            ("Eating", ["restaurant", "cafe", "coffee", "food", "bar"]),
            ("Healthcare", ["hospital", "doctor", "medical", "dentist", "pharmacy"]),
            ("Travelling", ["airport", "station", "transit", "hotel"]),
            ("Studying", ["school", "university", "library"])
        ]
        // The rules describe a concept; the catalogue decides the wording. Without
        // this a recognised workplace is written up as "Working" when the person's
        // own timeline says "Work" — correct, but a label they would have to fix,
        // and one Insights groups under "Other" rather than Work.
        if let match = rules.first(where: { rule in rule.1.contains { text.contains($0) } }) {
            return ActivityCatalog.preferredLabel(for: match.0)
        }
        let hour = Calendar.current.component(.hour, from: arrival)
        if text.contains("home") {
            return ActivityCatalog.preferredLabel(for: hour < 8 || hour >= 18 ? "At home" : "Home time")
        }
        return ActivityCatalog.preferredLabel(for: "Visiting")
    }
}
