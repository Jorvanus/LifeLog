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
    var defaultActivity: String

    init(name: String, latitude: Double, longitude: Double, radius: Double = 100,
         defaultActivity: String = "") {
        self.name = TextSafety.clean(name, maximumLength: 100)
        self.latitude = latitude; self.longitude = longitude
        self.radius = min(max(radius, 25), 500)
        self.defaultActivity = TextSafety.clean(defaultActivity, maximumLength: 80)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// One fix along a movement record's path. A journey is a sequence of these rather
/// than a single coordinate: a walk passes through many places and belongs to none
/// of them, which is why a movement `Visit` has always stored latitude 0, longitude 0.
struct RoutePoint: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let time: Date

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    init(latitude: Double, longitude: Double, time: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.time = time
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  time: location.timestamp)
    }
}

@Model
final class Visit {
    var arrival: Date
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var placeName: String
    var inferredActivity: String
    var userActivity: String?
    var note: String
    var source: String
    var recognitionConfidence: String?
    var candidateData: Data?
    /// The originating HealthKit sample UUID(s) for a health-imported visit (a merged
    /// sleep session can span several samples). Lets a later anchored-query deletion
    /// be matched back to the local visit it produced. Nil for non-HealthKit sources.
    var healthKitSampleIDs: [UUID]?
    /// The path a movement record followed, as JSON — the same storage approach as
    /// place candidates, so a journey needs no relationship and no cascade rules.
    /// Nil for stays, and for movement whose source recorded no coordinates.
    var routeData: Data?

    init(arrival: Date, departure: Date? = nil, latitude: Double, longitude: Double,
         placeName: String = Visit.identifyingPlaceName,
         inferredActivity: String = "Visiting", userActivity: String? = nil,
         note: String = "", source: String = "automatic",
         recognitionConfidence: String? = nil, candidateData: Data? = nil,
         healthKitSampleIDs: [UUID]? = nil, routeData: Data? = nil) {
        self.arrival = arrival; self.departure = departure
        self.latitude = latitude; self.longitude = longitude
        self.placeName = TextSafety.clean(placeName, maximumLength: 120)
        self.inferredActivity = TextSafety.clean(inferredActivity, maximumLength: 80)
        self.userActivity = userActivity.map { TextSafety.clean($0, maximumLength: 80) }
        self.note = TextSafety.clean(note, maximumLength: 2_000)
        self.source = TextSafety.clean(source, maximumLength: 40)
        self.recognitionConfidence = recognitionConfidence.map { TextSafety.clean($0, maximumLength: 20) }
        self.candidateData = candidateData
        self.healthKitSampleIDs = healthKitSampleIDs
        self.routeData = routeData
    }

    var activity: String {
        guard let userActivity, !userActivity.isEmpty else { return inferredActivity }
        return userActivity
    }
    var duration: TimeInterval { max(0, (departure ?? Date()).timeIntervalSince(arrival)) }

    /// Names LifeLog assigns before a place is known. They are not real labels, so
    /// a visit still carrying one has nothing recorded about where it happened.
    static let identifyingPlaceName = "Identifying…"
    static let unknownPlaceName = "Unknown place"
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == identifyingPlaceName || trimmed == unknownPlaceName
    }
    var hasPlaceholderName: Bool { Visit.isPlaceholderName(placeName) }

    /// A visit needs review when it was recorded automatically, LifeLog never
    /// resolved a place name for it, and the person has not said what they were
    /// doing. Place name is the signal here — LifeLog no longer models a place type.
    var needsCategorisation: Bool {
        source == "automatic" && hasPlaceholderName && userActivity?.isEmpty != false
    }

    /// A named guess LifeLog is not sure about. Apple Maps can return a nearby
    /// business with weak confidence — a workplace matched to a home address, say
    /// — and simply writing that name in would look like a settled fact. The place
    /// has a name, so it is not "uncategorised"; it still needs a person to agree.
    var needsConfirmation: Bool {
        guard source == "automatic", !hasPlaceholderName,
              userActivity?.isEmpty != false else { return false }
        switch recognitionConfidence?.lowercased() {
        case "low", "medium": return true
        default: return false
        }
    }

    /// Everything worth putting in front of a person: a place LifeLog could not
    /// identify, or one it guessed at without much certainty.
    var needsReview: Bool { needsCategorisation || needsConfirmation }

    /// Presentation values keep a recorded-but-unknown place visibly logged without
    /// exposing placeholder names such as “Identifying…” in Timeline and Insights.
    var displayPlaceName: String {
        needsCategorisation ? "Uncategorised location" : placeName
    }
    var suspectedActivity: String {
        needsCategorisation ? inferredActivity : activity
    }
    /// Groups time by what the person did, so repeated visits bundle by activity
    /// while "Top places" bundles by place name.
    var activityCategory: String {
        ActivityCatalog.category(for: suspectedActivity)
    }
    var insightCategory: String {
        if needsCategorisation { return "Uncategorised" }
        return activityCategory
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    var route: [RoutePoint] {
        get {
            guard let routeData else { return [] }
            return (try? JSONDecoder().decode([RoutePoint].self, from: routeData)) ?? []
        }
        set { routeData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var hasRoute: Bool { routeData != nil }

    /// Ground covered along the path, which is what a person means by how far they
    /// walked — not the distance between where they started and where they stopped.
    var routeDistance: CLLocationDistance {
        let points = route
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + pair.1.location.distance(from: pair.0.location)
        }
    }

    /// How far the journey got from a place. This is the question a stay cannot
    /// answer on its own: a loop around the block and pacing at home are both
    /// "walking with no departure recorded", and only the path separates them.
    func routeDistance(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        let points = route
        guard !points.isEmpty else { return nil }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return points.map { $0.location.distance(from: origin) }.max()
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
        if !hasPlaceholderName { evidence.append("Place name: \(placeName)") }
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
