import Foundation
import SwiftData
import CoreLocation

/// Why LifeLog believes a visit happened where it says it did.
///
/// The editor could already say how sure it was — "Confirmed", "Learned", "Medium" —
/// which is a verdict without the reasoning. When a name is wrong, the useful question
/// is not how confident the app was but what it was reading: a geofence it had been
/// taught, a business Apple Maps offered from some distance away, or simply that the
/// same name has been recorded here many times before.
///
/// **No coordinates, ever.** Every line here is a name, a count, or a distance in
/// metres. A visit's coordinate is already on the map above it, and restating it as
/// digits would put a precise record of somewhere the owner has been into a screen
/// that exists to be read, screenshotted and pasted into a bug report.
enum PlaceEvidence {
    /// How far out a Saved Place is still worth mentioning as the nearest one. Beyond
    /// this it explains nothing: "the nearest place you saved is two suburbs away" is
    /// not evidence about anywhere.
    static let mentionableRadius: CLLocationDistance = 500

    /// Saved Places close enough to be worth comparing against, fetched with the same
    /// bounding-box pre-filter the resolver uses so this cannot become a full scan.
    @MainActor
    static func nearbyPlaces(of visit: Visit, context: ModelContext) throws -> [SavedPlace] {
        guard visit.latitude != 0 || visit.longitude != 0 else { return [] }
        let box = SpatialBounds.box(around: visit.coordinate, radius: mentionableRadius)
        let minLatitude = box.minLatitude, maxLatitude = box.maxLatitude
        let minLongitude = box.minLongitude, maxLongitude = box.maxLongitude
        return try context.fetch(FetchDescriptor<SavedPlace>(
            predicate: #Predicate {
                $0.latitude >= minLatitude && $0.latitude <= maxLatitude &&
                $0.longitude >= minLongitude && $0.longitude <= maxLongitude
            }
        ))
    }

    /// The reasoning, in the order it was applied: what was already known about this
    /// spot, then what Apple Maps said about it, then how often it has come up before.
    static func reasons(for visit: Visit, savedPlaces: [SavedPlace], recurrence: Int) -> [String] {
        var reasons: [String] = []
        if let line = savedPlaceReason(for: visit, savedPlaces: savedPlaces) { reasons.append(line) }
        if let line = mapsReason(for: visit) { reasons.append(line) }
        if recurrence > 0 {
            reasons.append("Recorded here \(recurrence) time\(recurrence == 1 ? "" : "s") before")
        }
        if let score = visit.placeScoreBreakdown {
            reasons.append(contentsOf: score.lines)
        }
        return reasons
    }

    private static func savedPlaceReason(for visit: Visit, savedPlaces: [SavedPlace]) -> String? {
        guard visit.latitude != 0 || visit.longitude != 0 else { return nil }
        let origin = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let measured = savedPlaces
            .map { (place: $0, metres: origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .sorted { $0.metres < $1.metres }
        guard let nearest = measured.first, nearest.metres <= mentionableRadius else {
            return savedPlaces.isEmpty ? nil : "No Saved Place within \(Int(mentionableRadius)) m"
        }
        let distance = "\(Int(nearest.metres.rounded())) m from its centre"
        // Inside the geofence is the case that actually names a visit; outside it, the
        // place is being reported as context and must not read as the reason.
        if nearest.metres <= nearest.place.radius {
            return "Saved Place: \(nearest.place.name) — \(distance), inside its \(Int(nearest.place.radius)) m radius"
        }
        return "Nearest Saved Place: \(nearest.place.name) — \(distance), outside its \(Int(nearest.place.radius)) m radius"
    }

    private static func mapsReason(for visit: Visit) -> String? {
        let candidates = visit.placeSuggestions
        guard !candidates.isEmpty else { return nil }
        guard let chosen = candidates.first(where: { NameKey.same($0.name, visit.placeName) }) else {
            // The stored candidates are what Maps offered; none of them is the name on
            // the visit, so the name came from somewhere else — a correction, a Saved
            // Place, or a hand-typed one. Saying so is the point.
            return "Apple Maps offered \(candidates.count) other place\(candidates.count == 1 ? "" : "s"); this name came from elsewhere"
        }
        var line = "Apple Maps: \(chosen.name) — \(Int(chosen.distance.rounded())) m from the recorded point"
        // An identifier is the difference between "a business with this name" and
        // "this business", which is what makes a match survive a rename.
        if chosen.mapsIdentifier != nil { line += ", matched by Maps identifier" }
        return line
    }
}
