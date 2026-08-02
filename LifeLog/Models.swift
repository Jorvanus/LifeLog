import Foundation
import SwiftData
import CoreLocation

@Model
final class SavedPlace {
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var category: String
    var defaultActivity: String

    init(name: String, latitude: Double, longitude: Double, radius: Double = 100,
         category: String = "Other", defaultActivity: String = "") {
        self.name = TextSafety.clean(name, maximumLength: 100)
        self.latitude = latitude; self.longitude = longitude
        self.radius = min(max(radius, 25), 500)
        self.category = TextSafety.clean(category, maximumLength: 40)
        self.defaultActivity = TextSafety.clean(defaultActivity, maximumLength: 80)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@Model
final class Visit {
    var arrival: Date
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var placeName: String
    var placeCategory: String
    var inferredActivity: String
    var userActivity: String?
    var note: String
    var source: String
    var recognitionConfidence: String?
    var candidateData: Data?

    init(arrival: Date, departure: Date? = nil, latitude: Double, longitude: Double,
         placeName: String = "Identifying…", placeCategory: String = "Other",
         inferredActivity: String = "Visiting", userActivity: String? = nil,
         note: String = "", source: String = "automatic",
         recognitionConfidence: String? = nil, candidateData: Data? = nil) {
        self.arrival = arrival; self.departure = departure
        self.latitude = latitude; self.longitude = longitude
        self.placeName = TextSafety.clean(placeName, maximumLength: 120)
        self.placeCategory = TextSafety.clean(placeCategory, maximumLength: 40)
        self.inferredActivity = TextSafety.clean(inferredActivity, maximumLength: 80)
        self.userActivity = userActivity.map { TextSafety.clean($0, maximumLength: 80) }
        self.note = TextSafety.clean(note, maximumLength: 2_000)
        self.source = TextSafety.clean(source, maximumLength: 40)
        self.recognitionConfidence = recognitionConfidence.map { TextSafety.clean($0, maximumLength: 20) }
        self.candidateData = candidateData
    }

    var activity: String {
        guard let userActivity, !userActivity.isEmpty else { return inferredActivity }
        return userActivity
    }
    var duration: TimeInterval { max(0, (departure ?? Date()).timeIntervalSince(arrival)) }
    var needsCategorisation: Bool {
        source == "automatic" && placeCategory == "Other" && userActivity?.isEmpty != false
    }
    var placeSuggestions: [PlaceSuggestion] {
        get {
            guard let candidateData else { return [] }
            return (try? JSONDecoder().decode([PlaceSuggestion].self, from: candidateData)) ?? []
        }
        set { candidateData = try? JSONEncoder().encode(newValue) }
    }
}
