import Foundation
import CoreLocation
import MapKit

struct PlaceSuggestion: Codable, Identifiable, Hashable {
    var id: String { "\(name)-\(latitude)-\(longitude)" }
    let name: String
    let latitude: Double
    let longitude: Double
    let category: String
    let suggestedActivity: String
    let distance: Double
}

struct PlaceLookupResult {
    enum Confidence: String { case high, medium, low }
    let confidence: Confidence
    let suggestions: [PlaceSuggestion]
}

@MainActor
enum PlaceLookupService {
    static func nearbyPlaces(at coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 150,
                             arrival: Date = .now) async throws -> PlaceLookupResult {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return PlaceLookupResult(confidence: .low, suggestions: [])
        }
        let boundedRadius = min(max(radius, 75), 500)
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: boundedRadius)
        let response = try await MKLocalSearch(request: request).start()
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var suggestions = response.mapItems.compactMap { item -> PlaceSuggestion? in
            guard let rawName = item.name else { return nil }
            let name = TextSafety.clean(rawName, maximumLength: 100)
            guard !name.isEmpty else { return nil }
            let location = item.location
            let category = placeCategory(from: item.pointOfInterestCategory)
            return PlaceSuggestion(
                name: name,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                category: category,
                suggestedActivity: InferenceEngine.activity(placeName: name, category: category),
                distance: origin.distance(from: location)
            )
        }
        .filter { $0.distance <= boundedRadius }
        .sorted { $0.distance < $1.distance }
        .prefix(5)
        .map { $0 }

        if let first = suggestions.first,
           let smart = await SmartActivityClassifier.classify(
               placeName: first.name,
               mapCategory: first.category,
               arrival: arrival
           ), smart.confidence >= 60 {
            suggestions[0] = PlaceSuggestion(
                name: first.name,
                latitude: first.latitude,
                longitude: first.longitude,
                category: first.category == "Other" ? smart.category : first.category,
                suggestedActivity: smart.activity,
                distance: first.distance
            )
        }
        suggestions = Array(suggestions.prefix(3))

        guard let first = suggestions.first else {
            return PlaceLookupResult(confidence: .low, suggestions: [])
        }

        let secondDistance = suggestions.dropFirst().first?.distance
        let clearlyAhead = secondDistance.map { ($0 - first.distance) >= 30 || $0 >= max(1, first.distance) * 1.8 } ?? true
        let confidence: PlaceLookupResult.Confidence
        if first.distance <= 45 && clearlyAhead {
            confidence = .high
        } else if first.distance <= 100 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return PlaceLookupResult(confidence: confidence, suggestions: suggestions)
    }

    private static func placeCategory(from category: MKPointOfInterestCategory?) -> String {
        let value = category?.rawValue.lowercased() ?? ""
        if value.contains("restaurant") || value.contains("cafe") || value.contains("bakery") || value.contains("brewery") {
            return "Food & Drink"
        }
        if value.contains("store") || value.contains("market") || value.contains("laundry") || value.contains("bank") {
            return "Shopping"
        }
        if value.contains("fitness") || value.contains("stadium") || value.contains("park") || value.contains("beach") {
            return "Fitness"
        }
        if value.contains("hospital") || value.contains("pharmacy") || value.contains("health") {
            return "Healthcare"
        }
        if value.contains("school") || value.contains("university") || value.contains("library") {
            return "Education"
        }
        if value.contains("airport") || value.contains("transport") || value.contains("hotel") || value.contains("marina") {
            return "Travel"
        }
        if value.contains("nightlife") || value.contains("theater") || value.contains("museum") || value.contains("music") {
            return "Social"
        }
        return "Other"
    }
}
