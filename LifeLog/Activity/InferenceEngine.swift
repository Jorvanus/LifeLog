import Foundation
import MapKit

enum InferenceEngine {
    private struct CategoryMapping {
        let activity: String
        let mapsHint: String
    }

    private static let categoryMappings: [MKPointOfInterestCategory: CategoryMapping] = [
        .movieTheater: .init(activity: "Watching a movie", mapsHint: "Entertainment"),
        .theater: .init(activity: "Watching a movie", mapsHint: "Entertainment"),
        .restaurant: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .cafe: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .bakery: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .brewery: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .distillery: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .winery: .init(activity: "Eating", mapsHint: "Food & Drink"),
        .foodMarket: .init(activity: "Shopping", mapsHint: "Shopping"),
        .store: .init(activity: "Shopping", mapsHint: "Shopping"),
        .bank: .init(activity: "Shopping", mapsHint: "Shopping"),
        .atm: .init(activity: "Shopping", mapsHint: "Shopping"),
        .laundry: .init(activity: "Shopping", mapsHint: "Shopping"),
        .fitnessCenter: .init(activity: "Exercising", mapsHint: "Fitness"),
        .stadium: .init(activity: "Exercising", mapsHint: "Fitness"),
        .park: .init(activity: "Exercising", mapsHint: "Fitness"),
        .nationalPark: .init(activity: "Exercising", mapsHint: "Fitness"),
        .beach: .init(activity: "Exercising", mapsHint: "Fitness"),
        .baseball: .init(activity: "Exercising", mapsHint: "Fitness"),
        .basketball: .init(activity: "Exercising", mapsHint: "Fitness"),
        .bowling: .init(activity: "Exercising", mapsHint: "Fitness"),
        .golf: .init(activity: "Exercising", mapsHint: "Fitness"),
        .goKart: .init(activity: "Exercising", mapsHint: "Fitness"),
        .hiking: .init(activity: "Exercising", mapsHint: "Fitness"),
        .kayaking: .init(activity: "Exercising", mapsHint: "Fitness"),
        .miniGolf: .init(activity: "Exercising", mapsHint: "Fitness"),
        .rockClimbing: .init(activity: "Exercising", mapsHint: "Fitness"),
        .skatePark: .init(activity: "Exercising", mapsHint: "Fitness"),
        .skating: .init(activity: "Exercising", mapsHint: "Fitness"),
        .skiing: .init(activity: "Exercising", mapsHint: "Fitness"),
        .soccer: .init(activity: "Exercising", mapsHint: "Fitness"),
        .surfing: .init(activity: "Exercising", mapsHint: "Fitness"),
        .swimming: .init(activity: "Exercising", mapsHint: "Fitness"),
        .tennis: .init(activity: "Exercising", mapsHint: "Fitness"),
        .volleyball: .init(activity: "Exercising", mapsHint: "Fitness"),
        .hospital: .init(activity: "Healthcare", mapsHint: "Healthcare"),
        .pharmacy: .init(activity: "Healthcare", mapsHint: "Healthcare"),
        .school: .init(activity: "Studying", mapsHint: "Education"),
        .university: .init(activity: "Studying", mapsHint: "Education"),
        .library: .init(activity: "Studying", mapsHint: "Education"),
        .airport: .init(activity: "Travelling", mapsHint: "Travel"),
        .carRental: .init(activity: "Travelling", mapsHint: "Travel"),
        .gasStation: .init(activity: "Travelling", mapsHint: "Travel"),
        .hotel: .init(activity: "Travelling", mapsHint: "Travel"),
        .marina: .init(activity: "Travelling", mapsHint: "Travel"),
        .publicTransport: .init(activity: "Travelling", mapsHint: "Travel"),
        .rvPark: .init(activity: "Travelling", mapsHint: "Travel"),
        .amusementPark: .init(activity: "Visiting", mapsHint: "Social"),
        .aquarium: .init(activity: "Visiting", mapsHint: "Social"),
        .castle: .init(activity: "Visiting", mapsHint: "Social"),
        .conventionCenter: .init(activity: "Visiting", mapsHint: "Social"),
        .fairground: .init(activity: "Visiting", mapsHint: "Social"),
        .landmark: .init(activity: "Visiting", mapsHint: "Social"),
        .museum: .init(activity: "Visiting", mapsHint: "Social"),
        .musicVenue: .init(activity: "Visiting", mapsHint: "Social"),
        .nationalMonument: .init(activity: "Visiting", mapsHint: "Social"),
        .nightlife: .init(activity: "Visiting", mapsHint: "Social"),
        .planetarium: .init(activity: "Visiting", mapsHint: "Social"),
        .zoo: .init(activity: "Visiting", mapsHint: "Social")
    ]

    private static func categoryMapping(for category: MKPointOfInterestCategory) -> CategoryMapping? {
        return categoryMappings[category]
    }

    /// Infers an activity from the place name and, when Maps supplied one, the typed
    /// point-of-interest category. The category is a transient signal only — LifeLog
    /// does not store or display a place type.
    static func activity(placeName: String, defaultActivity: String? = nil,
                         arrival: Date = .now, mapsCategory: MKPointOfInterestCategory? = nil,
                         mapsHint: String = "") -> String {
        if let defaultActivity, !defaultActivity.isEmpty { return defaultActivity }
        return ActivityCatalog.preferredLabel(
            for: canonicalActivity(placeName: placeName, arrival: arrival,
                                   mapsCategory: mapsCategory, mapsHint: mapsHint))
    }

    static func mapsHint(for category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "Other" }
        return categoryMapping(for: category)?.mapsHint ?? "Other"
    }

    /// The concept the rules recognised, before the catalogue decides the wording.
    ///
    /// Anything asking a *question* about a place — is this a workplace? — has to use
    /// this rather than `activity`. Comparing the displayed label against a fixed
    /// string only ever worked because the label LifeLog shipped happened to be
    /// spelled the same as the concept behind it. The moment the person adopted their
    /// own wording, commute detection and travel labelling would have stopped
    /// recognising work and said nothing about it.
    static func canonicalActivity(placeName: String, defaultActivity: String? = nil,
                                  arrival: Date = .now,
                                  mapsCategory: MKPointOfInterestCategory? = nil,
                                  mapsHint: String = "") -> String {
        if let defaultActivity, !defaultActivity.isEmpty { return defaultActivity }
        if let mapsCategory, let mapped = categoryMapping(for: mapsCategory) {
            return mapped.activity
        }
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
        // The rules describe a concept; `activity` above lets the catalogue decide the
        // wording, so a recognised workplace reads as "Work" when that is what the
        // person's own timeline says rather than a label they would have to fix.
        if let match = rules.first(where: { rule in rule.1.contains { text.contains($0) } }) {
            return match.0
        }
        if text.contains("home") { return "At home" }
        return "Visiting"
    }
}
