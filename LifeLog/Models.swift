import Foundation
import SwiftData
import CoreLocation

enum VisitResolutionState: String, Codable, Sendable {
    case provisional
    case resolved
    case superseded
    case ignored
}

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
    /// Presentation values keep a recorded-but-unknown place visibly logged without
    /// exposing placeholder names such as “Identifying…” in Timeline and Insights.
    var displayPlaceName: String {
        needsCategorisation ? "Uncategorised location" : placeName
    }
    var suspectedActivity: String {
        needsCategorisation ? inferredActivity : activity
    }
    /// Groups time by what the person did, independent of the place type.
    /// The persisted placeCategory remains available for map/place recognition.
    var activityCategory: String {
        ActivityCatalog.category(for: suspectedActivity)
    }
    var insightCategory: String {
        if needsCategorisation { return "Uncategorised" }
        return activityCategory
    }
    var placeSuggestions: [PlaceSuggestion] {
        get {
            guard let candidateData else { return [] }
            return (try? JSONDecoder().decode([PlaceSuggestion].self, from: candidateData)) ?? []
        }
        set { candidateData = try? JSONEncoder().encode(newValue) }
    }

    var confidenceLabel: String {
        switch recognitionConfidence?.lowercased() {
        case "confirmed": "Confirmed"
        case "learned": "Learned"
        case "high": "High"
        case "medium": "Medium"
        case "low": "Low"
        case "device": "Device"
        default: "Pending"
        }
    }

    /// Privacy-safe provenance for the displayed activity inference. This is
    /// derived from existing local fields so no new persisted schema is needed.
    var inferenceEvidence: [String] {
        var evidence: [String] = []
        if recognitionConfidence == "learned" { evidence.append("Saved place") }
        if placeCategory != "Other" && !placeCategory.isEmpty {
            evidence.append("Maps/place type: \(placeCategory)")
        }
        let hour = Calendar.current.component(.hour, from: arrival)
        if hour < 11 { evidence.append("Morning time") }
        else if hour < 17 { evidence.append("Afternoon time") }
        else { evidence.append("Evening time") }
        if source == "motion" || source == "health-walking" || source == "health-workout" {
            evidence.append("Device movement")
        }
        if source == "automatic" && recognitionConfidence != "learned" {
            evidence.append("On-device inference")
        }
        return evidence
    }

    var inferenceSummary: String {
        let evidence = inferenceEvidence
        return evidence.isEmpty ? "No inference evidence recorded" : evidence.joined(separator: " · ")
    }
}


/// Immutable audit entry for a user correction or a learned Saved Place update.
/// It stores labels and confidence only; precise coordinates remain in the visit.
@Model
final class VisitCorrection {
    var changedAt: Date
    var visitArrival: Date
    var latitude: Double
    var longitude: Double
    var previousPlaceName: String
    var newPlaceName: String
    var previousActivity: String
    var newActivity: String
    var previousConfidence: String
    var newConfidence: String
    var reason: String

    init(changedAt: Date = .now, visitArrival: Date, latitude: Double, longitude: Double,
         previousPlaceName: String, newPlaceName: String, previousActivity: String,
         newActivity: String, previousConfidence: String = "pending",
         newConfidence: String = "confirmed", reason: String = "Manual correction") {
        self.changedAt = changedAt
        self.visitArrival = visitArrival
        self.latitude = latitude
        self.longitude = longitude
        self.previousPlaceName = TextSafety.clean(previousPlaceName, maximumLength: 120)
        self.newPlaceName = TextSafety.clean(newPlaceName, maximumLength: 120)
        self.previousActivity = TextSafety.clean(previousActivity, maximumLength: 80)
        self.newActivity = TextSafety.clean(newActivity, maximumLength: 80)
        self.previousConfidence = TextSafety.clean(previousConfidence, maximumLength: 20)
        self.newConfidence = TextSafety.clean(newConfidence, maximumLength: 20)
        self.reason = TextSafety.clean(reason, maximumLength: 80)
    }
}
