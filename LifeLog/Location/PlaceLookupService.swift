import Foundation
import CoreLocation
import MapKit

struct PlaceSuggestion: Codable, Identifiable, Hashable {
    var id: String { "\(name)-\(latitude)-\(longitude)" }
    let name: String
    let latitude: Double
    let longitude: Double
    let suggestedActivity: String
    let distance: Double
    /// Raw Apple Maps POI category used by the shared place scorer.
    var mapsCategory: String?
    /// Apple Maps' identifier for this result, where it supplies one. Names collide
    /// and get reworded; this does not. Optional because suggestions stored before
    /// this existed have none, and Maps does not identify every result.
    var mapsIdentifier: String?

    // Older stored suggestions carried a place-type string. It is ignored on
    // decode so previously saved candidate payloads still read cleanly.
    private enum CodingKeys: String, CodingKey {
        case name, latitude, longitude, suggestedActivity, distance, mapsIdentifier, mapsCategory
    }

    init(name: String, latitude: Double, longitude: Double, suggestedActivity: String,
         distance: Double, mapsIdentifier: String? = nil, mapsCategory: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.suggestedActivity = suggestedActivity
        self.distance = distance
        self.mapsIdentifier = mapsIdentifier
        self.mapsCategory = mapsCategory
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct PlaceLookupResult {
    enum Confidence: String { case high, medium, low }
    let confidence: Confidence
    let suggestions: [PlaceSuggestion]
    let cacheHit: Bool
    let latencyMs: Int
    let candidateCount: Int
    let candidatePayloadBytes: Int
    /// The radius actually searched, after clamping. Reported so a diagnostic records
    /// what was asked of Maps rather than what the caller intended to ask.
    var searchRadius: CLLocationDistance = 0

    init(confidence: Confidence, suggestions: [PlaceSuggestion], cacheHit: Bool = false,
         latencyMs: Int = 0, candidateCount: Int = 0, candidatePayloadBytes: Int = 0,
         searchRadius: CLLocationDistance = 0) {
        self.confidence = confidence
        self.suggestions = suggestions
        self.cacheHit = cacheHit
        self.latencyMs = latencyMs
        self.candidateCount = candidateCount
        self.candidatePayloadBytes = candidatePayloadBytes
        self.searchRadius = searchRadius
    }
}

@MainActor
enum PlaceLookupService {
    private struct CachedResult { let createdAt: Date; let result: PlaceLookupResult }
    private static var cache: [String: CachedResult] = [:]
    private static var lookupGeneration = 0
    private static let cacheLifetime: TimeInterval = 15 * 60
    /// A coordinate with no nearby points of interest is worth remembering, but not
    /// for as long as a real match: a new business should become findable without
    /// waiting out the full expiry. Somewhere genuinely empty stays empty, and this
    /// keeps LifeLog from repeating a multi-second search on every callback there.
    private static let emptyResultLifetime: TimeInterval = 5 * 60

    /// Cancels every lookup in flight. This is deliberately all-or-nothing: it fires
    /// when a visit is edited, and a lookup that finishes afterwards would write a
    /// Maps name over the one the person just typed. Cancelling a single visit's
    /// lookup would be kinder to unrelated background work, but a per-visit
    /// mechanism existed here for a while without ever being called, so this is the
    /// behaviour that has actually been running.
    static func cancelAllLookups() {
        lookupGeneration += 1
    }

    static func nearbyPlaces(at coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 150,
                             arrival: Date = .now, category: String? = nil) async throws -> PlaceLookupResult {
        let startedAt = Date.now
        let boundedRadius = min(max(radius, 75), 500)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return PlaceLookupResult(confidence: .low, suggestions: [], searchRadius: boundedRadius)
        }
        let generation = lookupGeneration
        // A roughly 100 m cell avoids retaining exact user coordinates while
        // still reusing nearby results during repeated callback retries.
        let cell = "\(Int((coordinate.latitude * 900).rounded())):\(Int((coordinate.longitude * 900).rounded())):\(Int(boundedRadius)):\(category ?? "all")"
        let cachedLifetime = (cache[cell]?.result.suggestions.isEmpty ?? false)
            ? emptyResultLifetime : cacheLifetime
        if let cached = cache[cell], Date.now.timeIntervalSince(cached.createdAt) < cachedLifetime {
            return PlaceLookupResult(confidence: cached.result.confidence,
                                     suggestions: cached.result.suggestions,
                                     cacheHit: true,
                                     latencyMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                     candidateCount: cached.result.candidateCount,
                                     candidatePayloadBytes: cached.result.candidatePayloadBytes,
                                     searchRadius: boundedRadius)
        }
        try Task.checkCancellation()
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: boundedRadius)
        let response = try await MKLocalSearch(request: request).start()
        if generation != lookupGeneration { throw CancellationError() }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var suggestions = response.mapItems.compactMap { item -> PlaceSuggestion? in
            guard let rawName = item.name else { return nil }
            let name = TextSafety.clean(rawName, maximumLength: 100)
            guard !name.isEmpty else { return nil }
            let location = item.location
            // The Maps category only feeds inference here; it is never stored on the
            // suggestion or the visit.
            let mapsCategory = item.pointOfInterestCategory
            return PlaceSuggestion(
                name: name,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                suggestedActivity: InferenceEngine.activity(placeName: name, mapsCategory: mapsCategory),
                distance: origin.distance(from: location),
                mapsIdentifier: item.identifier?.rawValue,
                mapsCategory: mapsCategory?.rawValue
            )
        }
        .filter { $0.distance <= boundedRadius }
        .sorted { $0.distance < $1.distance }
        .prefix(5)
        .map { $0 }

        if let first = suggestions.first,
           let smart = await SmartActivityClassifier.classify(
               placeName: first.name,
               mapCategory: InferenceEngine.mapsHint(for: response.mapItems.first { $0.name == first.name }?.pointOfInterestCategory),
               arrival: arrival
           ), smart.confidence >= 60 {
            suggestions[0] = PlaceSuggestion(
                name: first.name,
                latitude: first.latitude,
                longitude: first.longitude,
                suggestedActivity: smart.activity,
                distance: first.distance,
                mapsIdentifier: first.mapsIdentifier,
                mapsCategory: first.mapsCategory
            )
        }
        suggestions = Array(suggestions.prefix(3))

        guard let first = suggestions.first else {
            // Previously this returned before the cache write below, so "no places
            // here" was never remembered and every later callback at the same
            // coordinate repeated the whole search — seconds of network work, then a
            // reverse-geocode fallback, for a result already known to be empty.
            let empty = PlaceLookupResult(confidence: .low, suggestions: [],
                                          latencyMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                          candidateCount: response.mapItems.count,
                                          candidatePayloadBytes: 0,
                                          searchRadius: boundedRadius)
            evictExpired()
            cache[cell] = CachedResult(createdAt: .now, result: empty)
            return empty
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
        let result = PlaceLookupResult(confidence: confidence, suggestions: suggestions,
                                       latencyMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                       candidateCount: response.mapItems.count,
                                       candidatePayloadBytes: (try? JSONEncoder().encode(suggestions).count) ?? 0,
                                       searchRadius: boundedRadius)
        evictExpired()
        cache[cell] = CachedResult(createdAt: .now, result: result)
        return result
    }

    /// Cache entries are only checked for expiry on read, so without this a
    /// long-running background session would accumulate one permanent entry
    /// per distinct ~100 m cell ever visited. Sweeping on every write bounds
    /// memory to whatever was looked up within the last `cacheLifetime`.
    private static func evictExpired() {
        let now = Date.now
        cache = cache.filter { entry in
            let lifetime = entry.value.result.suggestions.isEmpty ? emptyResultLifetime : cacheLifetime
            return now.timeIntervalSince(entry.value.createdAt) < lifetime
        }
    }

}
