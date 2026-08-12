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
    /// Lifecycle metadata is optional so score payloads written before the
    /// lifecycle existed remain readable without a SwiftData migration.
    let lifecycleStage: String?
    let decisionThreshold: Int?
    let candidateCount: Int?
    let observedDwellSeconds: Int?
    let accuracyMeters: Int?
    let geofenceTriggered: Bool?

    init(recordedAt: Date, total: Int, savedPlaceGeofence: Int, poiDistance: Int,
         poiCategory: Int, dwellDuration: Int, horizontalAccuracy: Int,
         recurrence: Int, timeOfDay: Int, priorCorrections: Int,
         selectedPlaceName: String?, mapsIdentifier: String?,
         lifecycleStage: String? = nil, decisionThreshold: Int? = nil,
         candidateCount: Int? = nil, observedDwellSeconds: Int? = nil,
         accuracyMeters: Int? = nil, geofenceTriggered: Bool? = nil) {
        self.recordedAt = recordedAt
        self.total = total
        self.savedPlaceGeofence = savedPlaceGeofence
        self.poiDistance = poiDistance
        self.poiCategory = poiCategory
        self.dwellDuration = dwellDuration
        self.horizontalAccuracy = horizontalAccuracy
        self.recurrence = recurrence
        self.timeOfDay = timeOfDay
        self.priorCorrections = priorCorrections
        self.selectedPlaceName = selectedPlaceName
        self.mapsIdentifier = mapsIdentifier
        self.lifecycleStage = lifecycleStage
        self.decisionThreshold = decisionThreshold
        self.candidateCount = candidateCount
        self.observedDwellSeconds = observedDwellSeconds
        self.accuracyMeters = accuracyMeters
        self.geofenceTriggered = geofenceTriggered
    }

    var confidence: String {
        switch total {
        case 75...: "high"
        case 50..<75: "medium"
        default: "low"
        }
    }

    var lines: [String] {
        var values = [
            "Place score: \(total)/100 (\(confidence))",
            "Saved Place/geofence \(savedPlaceGeofence)/35 · Apple Maps distance \(poiDistance)/15",
            "Apple Maps category \(poiCategory)/10 · dwell \(dwellDuration)/15",
            "Location accuracy \(horizontalAccuracy)/10 · recurrence \(recurrence)/10",
            "Time of day \(timeOfDay)/5 · prior corrections \(priorCorrections)/10"
        ]
        if let lifecycleStage, let decisionThreshold {
            values.append("Scored at \(lifecycleStage) · suggestion threshold \(decisionThreshold)/100")
        }
        if let candidateCount, let observedDwellSeconds, let accuracyMeters {
            values.append("Inputs: \(candidateCount) candidate(s) · dwell \(observedDwellSeconds / 60) min · accuracy \(accuracyMeters) m\(geofenceTriggered == true ? " · geofence event" : "")")
        }
        return values
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
                         corrections: [VisitCorrection], stage: String = "arrival",
                         // Keep this literal nonisolated so score-only callers can run
                         // outside the UI actor; PlaceScoreLifecycle owns the shared value.
                         decisionThreshold: Int = 75,
                         now: Date = .now) -> PlaceScoreEvaluation {
        let candidates = Self.candidates(suggestions: suggestions, savedPlaces: savedPlaces, visit: visit)

        let scored = candidates.map { candidate in
            score(candidate: candidate, visit: visit, savedPlaces: savedPlaces,
                  accuracy: accuracy, geofenceTriggered: geofenceTriggered,
                  visits: visits, corrections: corrections, stage: stage,
                  decisionThreshold: decisionThreshold, candidateCount: candidates.count, now: now)
        }
        guard let best = scored.max(by: { $0.breakdown.total < $1.breakdown.total }) else {
            return PlaceScoreEvaluation(selected: nil, breakdown: score(candidate: nil,
                visit: visit, savedPlaces: savedPlaces, accuracy: accuracy,
                geofenceTriggered: geofenceTriggered, visits: visits,
                corrections: corrections, stage: stage, decisionThreshold: decisionThreshold,
                candidateCount: candidates.count, now: now).breakdown)
        }
        return best
    }

    /// The places actually in contention for this visit: Apple Maps' own results when
    /// it has any, otherwise every Saved Place recast as a candidate. Exposed so a
    /// caller can learn which names and locations are about to be scored *before*
    /// `evaluate` runs — `PlaceScoreLifecycle` uses this to scope its history fetch to
    /// what these candidates could actually match, instead of loading every visit.
    static func candidates(suggestions: [PlaceSuggestion], savedPlaces: [SavedPlace], visit: Visit) -> [PlaceSuggestion] {
        suggestions.isEmpty
            ? savedPlaces.map {
                PlaceSuggestion(name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                                suggestedActivity: $0.defaultActivity, distance: distance(from: visit, to: $0),
                                mapsIdentifier: $0.mapsIdentifier)
            }
            : suggestions
    }

    private static func score(candidate: PlaceSuggestion?, visit: Visit,
                              savedPlaces: [SavedPlace], accuracy: CLLocationAccuracy,
                              geofenceTriggered: Bool, visits: [Visit],
                              corrections: [VisitCorrection], stage: String,
                              decisionThreshold: Int, candidateCount: Int,
                              now: Date) -> PlaceScoreEvaluation {
        let candidateLocation = candidate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let saved = candidate.flatMap { candidate in
            savedPlaces.first { place in
                if let lhs = candidate.mapsIdentifier, let rhs = place.mapsIdentifier, lhs == rhs { return true }
                return NameKey.same(candidate.name, place.name) ||
                    candidateLocation.map { $0.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= place.radius } == true
            }
        }
        // A fuzzed or genuinely poor fix can't be trusted to say which nearby
        // candidate is actually closest. `geofenceTriggered` survives untouched --
        // it's a real OS region-crossing event, not a coordinate comparison -- and
        // so does identity matching above (Maps identifier / saved-place radius
        // membership already found `saved`); only the continuous distance credit
        // below is gated.
        let isApproximate = LocationQuality.isApproximate(accuracy)
        let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let savedDistance = saved.map {
            visitLocation.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        let insideGeofence = !isApproximate && (savedDistance.map { $0 <= (saved?.radius ?? 0) } ?? false)
        let geofence = min(35, geofenceTriggered || insideGeofence ? 35 :
            isApproximate ? 0 : Int(max(0, 35 * (1 - min(savedDistance ?? 500, 500) / 500))))
        let poiDistance = isApproximate ? 0 :
            (candidate.map { Int(max(0, 15 * (1 - min($0.distance, 250) / 250))) } ?? 0)
        let poiCategory = candidate?.mapsCategory.map { $0.isEmpty ? 0 : 10 } ?? 0
        // A new arrival does not yet prove a dwell. Its eventual duration is
        // deliberately re-evaluated at departure by PlaceScoreLifecycle.
        let observedDwell = stage == "arrival" ? 0 : max(0, visit.duration)
        let dwell = min(15, Int((observedDwell / 1_800 * 15).rounded()))
        let horizontalAccuracy: Int
        if accuracy < 0 { horizontalAccuracy = 0 }
        else { horizontalAccuracy = min(10, Int(max(0, 10 * (1 - min(accuracy, 200) / 200)).rounded())) }

        // Maps identity wins whenever both sides have it, the same priority order
        // used for the SavedPlace link above -- two visits can only share a Maps
        // identifier by being the same physical place, so this can't misfire the
        // way a coincidental name match could. A name match is the next-strongest
        // case, but requiring it entirely missed a spot visited daily where Apple
        // Maps keeps picking a different (or simply wrong) nearby POI each time --
        // arriving home, most of all, since a bus stop or a neighbour's business
        // can sit closer to the door than anything actually named "Home". 60 m
        // matches the existing "same physical place" convention used to fold in a
        // recent duplicate arrival elsewhere in this pipeline: tight enough that a
        // genuinely different nearby address doesn't borrow this spot's history.
        let prior = visits.filter { other in
            guard other !== visit, !other.isIgnored else { return false }
            if let lhs = other.mapsIdentifier, let rhs = candidate?.mapsIdentifier, lhs == rhs { return true }
            if candidate.map({ NameKey.same(other.placeName, $0.name) }) == true { return true }
            guard let candidateLocation, other.latitude != 0 || other.longitude != 0 else { return false }
            return CLLocation(latitude: other.latitude, longitude: other.longitude)
                .distance(from: candidateLocation) <= 60
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
                selectedPlaceName: candidate?.name, mapsIdentifier: candidate?.mapsIdentifier,
                lifecycleStage: stage, decisionThreshold: decisionThreshold,
                candidateCount: candidateCount,
                observedDwellSeconds: Int(observedDwell.rounded()),
                accuracyMeters: accuracy < 0 ? nil : Int(accuracy.rounded()),
                geofenceTriggered: geofenceTriggered
            )
        )
    }

    private static func distance(from visit: Visit, to place: SavedPlace) -> CLLocationDistance {
        CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
    }
}
