import Foundation
import CoreLocation

/// The explainable inputs behind a place decision. Components add to 100 so the
/// stored result can be inspected later without reconstructing the live context
/// that produced it.
struct PlaceScoreBreakdown: Codable, Equatable, Sendable {
    let recordedAt: Date
    let total: Int
    let savedPlaceGeofence: Int
    let poiDistance: Int
    let poiCategory: Int
    let dwellDuration: Int
    let horizontalAccuracy: Int
    let recurrence: Int
    let timeOfDay: Int
    let priorCorrections: Int
    let selectedPlaceName: String?
    let mapsIdentifier: String?

    var confidence: String {
        switch total {
        case 75...: "high"
        case 50..<75: "medium"
        default: "low"
        }
    }

    var lines: [String] {
        [
            "Place score: \(total)/100 (\(confidence))",
            "Saved Place/geofence \(savedPlaceGeofence)/35 · Apple Maps distance \(poiDistance)/15",
            "Apple Maps category \(poiCategory)/10 · dwell \(dwellDuration)/15",
            "Location accuracy \(horizontalAccuracy)/10 · recurrence \(recurrence)/10",
            "Time of day \(timeOfDay)/5 · prior corrections \(priorCorrections)/10"
        ]
    }
}

struct PlaceScoreEvaluation: Sendable {
    let selected: PlaceSuggestion?
    let breakdown: PlaceScoreBreakdown
}

/// One pipeline for all place evidence. It deliberately scores candidates rather
/// than letting each caller invent its own "nearest Maps result" rule.
enum PlaceScoringPipeline {
    static func evaluate(visit: Visit, savedPlaces: [SavedPlace],
                         suggestions: [PlaceSuggestion], accuracy: CLLocationAccuracy,
                         geofenceTriggered: Bool, visits: [Visit],
                         corrections: [VisitCorrection], now: Date = .now) -> PlaceScoreEvaluation {
        let candidates = suggestions.isEmpty
            ? savedPlaces.map {
                PlaceSuggestion(name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                                suggestedActivity: $0.defaultActivity, distance: distance(from: visit, to: $0),
                                mapsIdentifier: $0.mapsIdentifier)
            }
            : suggestions

        let scored = candidates.map { candidate in
            score(candidate: candidate, visit: visit, savedPlaces: savedPlaces,
                  accuracy: accuracy, geofenceTriggered: geofenceTriggered,
                  visits: visits, corrections: corrections, now: now)
        }
        guard let best = scored.max(by: { $0.breakdown.total < $1.breakdown.total }) else {
            return PlaceScoreEvaluation(selected: nil, breakdown: score(candidate: nil,
                visit: visit, savedPlaces: savedPlaces, accuracy: accuracy,
                geofenceTriggered: geofenceTriggered, visits: visits,
                corrections: corrections, now: now).breakdown)
        }
        return best
    }

    private static func score(candidate: PlaceSuggestion?, visit: Visit,
                              savedPlaces: [SavedPlace], accuracy: CLLocationAccuracy,
                              geofenceTriggered: Bool, visits: [Visit],
                              corrections: [VisitCorrection], now: Date) -> PlaceScoreEvaluation {
        let candidateLocation = candidate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let saved = candidate.flatMap { candidate in
            savedPlaces.first { place in
                if let lhs = candidate.mapsIdentifier, let rhs = place.mapsIdentifier, lhs == rhs { return true }
                return NameKey.same(candidate.name, place.name) ||
                    candidateLocation.map { $0.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= place.radius } == true
            }
        }
        let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let savedDistance = saved.map {
            visitLocation.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        let insideGeofence = savedDistance.map { $0 <= (saved?.radius ?? 0) } ?? false
        let geofence = min(35, geofenceTriggered || insideGeofence ? 35 :
            Int(max(0, 35 * (1 - min(savedDistance ?? 500, 500) / 500))))
        let poiDistance = candidate.map { Int(max(0, 15 * (1 - min($0.distance, 250) / 250))) } ?? 0
        let poiCategory = candidate?.mapsCategory.map { $0.isEmpty ? 0 : 10 } ?? 0
        let dwell = min(15, Int(max(0, visit.duration / 1_800 * 15).rounded()))
        let horizontalAccuracy: Int
        if accuracy < 0 { horizontalAccuracy = 0 }
        else { horizontalAccuracy = min(10, Int(max(0, 10 * (1 - min(accuracy, 200) / 200)).rounded())) }

        let prior = visits.filter { other in
            other !== visit && !other.isIgnored && candidate.map { NameKey.same(other.placeName, $0.name) } == true
        }
        let recurrence = min(10, prior.count)
        let arrivalHour = Calendar.current.component(.hour, from: visit.arrival)
        let timeMatches = prior.filter { Calendar.current.component(.hour, from: $0.arrival) == arrivalHour }.count
        let timeOfDay = min(5, timeMatches * 2)
        let correctionMatches = corrections.filter { correction in
            candidate.map { NameKey.same(correction.newPlaceName, $0.name) } == true ||
            candidateLocation.map {
                $0.distance(from: CLLocation(latitude: correction.latitude, longitude: correction.longitude)) <= 100
            } == true
        }.count
        let priorCorrections = min(10, correctionMatches * 5)
        let total = geofence + poiDistance + poiCategory + dwell + horizontalAccuracy + recurrence + timeOfDay + priorCorrections
        return PlaceScoreEvaluation(
            selected: candidate,
            breakdown: PlaceScoreBreakdown(
                recordedAt: now, total: total, savedPlaceGeofence: geofence,
                poiDistance: poiDistance, poiCategory: poiCategory,
                dwellDuration: dwell, horizontalAccuracy: horizontalAccuracy,
                recurrence: recurrence, timeOfDay: timeOfDay,
                priorCorrections: priorCorrections,
                selectedPlaceName: candidate?.name, mapsIdentifier: candidate?.mapsIdentifier
            )
        )
    }

    private static func distance(from visit: Visit, to place: SavedPlace) -> CLLocationDistance {
        CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
    }
}
