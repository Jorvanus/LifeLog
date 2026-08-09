import Foundation
import SwiftData

/// Owns the lifetime of a place score. A stay's dwell time changes after arrival,
/// so a score is evidence that must be refreshed rather than a one-off verdict.
@MainActor
enum PlaceScoreLifecycle {
    static let suggestionThreshold = 75

    enum Stage: String {
        case arrival
        case mapsLookup = "Maps lookup"
        case departure
        case correction
    }

    @discardableResult
    static func rescore(_ visit: Visit, stage: Stage, context: ModelContext,
                        savedPlaces: [SavedPlace]? = nil,
                        accuracy: Double? = nil,
                        geofenceTriggered: Bool? = nil) -> PlaceScoreEvaluation? {
        guard ActivityLocationPolicy.isLocationVisit(visit),
              visit.latitude != 0 || visit.longitude != 0 else { return nil }
        let previous = visit.placeScoreBreakdown
        let places = savedPlaces ?? (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
        let visits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        let corrections = (try? context.fetch(FetchDescriptor<VisitCorrection>())) ?? []
        let measuredAccuracy = accuracy ?? previous?.accuracyMeters.map(Double.init) ?? -1
        let usedGeofence = geofenceTriggered ?? previous?.geofenceTriggered ?? false
        let evaluation = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: places, suggestions: visit.placeSuggestions,
            accuracy: measuredAccuracy, geofenceTriggered: usedGeofence,
            visits: visits, corrections: corrections, stage: stage.rawValue,
            decisionThreshold: suggestionThreshold
        )
        visit.placeScoreBreakdown = evaluation.breakdown

        let oldScore = previous?.total
        let delta = oldScore.map { evaluation.breakdown.total - $0 }
        let change = delta.map { $0 == 0 ? "unchanged" : ($0 > 0 ? "+\($0)" : "\($0)") } ?? "new"
        Diagnostics.record(context, subsystem: "Place scoring",
                           message: "\(stage.rawValue) score \(oldScore.map(String.init) ?? "none") → \(evaluation.breakdown.total) (\(change)); threshold \(suggestionThreshold), \(evaluation.breakdown.candidateCount ?? 0) candidates, dwell \((evaluation.breakdown.observedDwellSeconds ?? 0) / 60) min.",
                           severity: "info", category: LocationDiagnostics.category)
        LocationDiagnostics.record(.promoted, subject: "Place score", reason: "\(stage.rawValue) \(oldScore.map(String.init) ?? "none") to \(evaluation.breakdown.total), threshold \(suggestionThreshold)",
                                   evidence: "selected \(evaluation.selected?.name ?? "no candidate"); dwell \((evaluation.breakdown.observedDwellSeconds ?? 0) / 60) min; accuracy \(evaluation.breakdown.accuracyMeters.map(String.init) ?? "unknown") m",
                                   context: context)
        return evaluation
    }

    /// A score can rank candidates, but never changes a visit a person has already
    /// confirmed. Callers may show or apply the returned suggestion only for an
    /// unresolved automatic visit.
    static func canSuggest(for visit: Visit, evaluation: PlaceScoreEvaluation) -> Bool {
        visit.recognitionConfidence?.lowercased() != "confirmed" &&
            evaluation.breakdown.total >= suggestionThreshold &&
            evaluation.selected != nil
    }
}
