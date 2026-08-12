import Foundation
import SwiftData
import CoreLocation

/// The visit and correction history relevant to scoring a set of place candidates.
///
/// `PlaceScoringPipeline.score` reads independent signals out of the archive for each
/// candidate: has this exact Maps identifier come up before, has this exact name come
/// up before, anywhere, and has this exact spot (within a small radius) come up
/// before, under any name. It used to answer all of these by handing the scorer a
/// fetch of every `Visit` and every `VisitCorrection` ever recorded — `rescore` runs
/// on every automatic arrival, departure and correction, so on a real archive that
/// fully hydrated the whole table into memory on every one of those events.
///
/// This narrows in the store first, the same way `PlaceVisitLookup` and
/// `PlaceEvidence.nearbyPlaces` already do: a coarse `localizedStandardContains` per
/// candidate name covers the name signal (case/diacritic-insensitive, so it is a
/// superset of what `NameKey` would call the same), and a `SpatialBounds` box around
/// every candidate location covers the proximity signal. `PlaceScoringPipeline.score`
/// still applies its own exact `NameKey`/distance filter to whatever comes back, so
/// the scoring logic itself — and its result — is unchanged; only how much of the
/// archive gets loaded to run it is.
///
/// No separate query narrows by `mapsIdentifier`: a Maps identifier names one
/// physical POI, so a visit sharing a candidate's identifier already sits inside the
/// same proximity box the name/distance signal is scoped by — there is no case where
/// an identifier match could fall outside it.
enum PlaceHistoryLookup {
    @MainActor
    static func visits(near candidates: [PlaceSuggestion], context: ModelContext) -> [Visit] {
        guard !candidates.isEmpty else { return [] }
        var seen = Set<PersistentIdentifier>()
        var found: [Visit] = []
        func add(_ fetched: [Visit]) {
            for visit in fetched where seen.insert(visit.persistentModelID).inserted {
                found.append(visit)
            }
        }

        // Proximity signal: "this exact spot before, under any name" — 60 m matches
        // the "same physical place" radius PlaceScoringPipeline.score itself applies.
        if let box = SpatialBounds.box(around: candidates.map(\.coordinate), radius: 60) {
            let minLatitude = box.minLatitude, maxLatitude = box.maxLatitude
            let minLongitude = box.minLongitude, maxLongitude = box.maxLongitude
            add((try? context.fetch(FetchDescriptor<Visit>(
                predicate: #Predicate {
                    $0.latitude >= minLatitude && $0.latitude <= maxLatitude &&
                    $0.longitude >= minLongitude && $0.longitude <= maxLongitude
                }
            ))) ?? [])
        }

        // Name signal: "this exact name before, anywhere" — one narrow fetch per
        // distinct candidate name, not one fetch of the whole table.
        for name in candidateNames(candidates) {
            add((try? context.fetch(FetchDescriptor<Visit>(
                predicate: #Predicate { $0.placeName.localizedStandardContains(name) }
            ))) ?? [])
        }
        return found
    }

    @MainActor
    static func corrections(near candidates: [PlaceSuggestion], context: ModelContext) -> [VisitCorrection] {
        guard !candidates.isEmpty else { return [] }
        var seen = Set<PersistentIdentifier>()
        var found: [VisitCorrection] = []
        func add(_ fetched: [VisitCorrection]) {
            for correction in fetched where seen.insert(correction.persistentModelID).inserted {
                found.append(correction)
            }
        }

        // Matches PlaceScoringPipeline.score's own 100 m correction radius.
        if let box = SpatialBounds.box(around: candidates.map(\.coordinate), radius: 100) {
            let minLatitude = box.minLatitude, maxLatitude = box.maxLatitude
            let minLongitude = box.minLongitude, maxLongitude = box.maxLongitude
            add((try? context.fetch(FetchDescriptor<VisitCorrection>(
                predicate: #Predicate {
                    $0.latitude >= minLatitude && $0.latitude <= maxLatitude &&
                    $0.longitude >= minLongitude && $0.longitude <= maxLongitude
                }
            ))) ?? [])
        }

        for name in candidateNames(candidates) {
            add((try? context.fetch(FetchDescriptor<VisitCorrection>(
                predicate: #Predicate { $0.newPlaceName.localizedStandardContains(name) }
            ))) ?? [])
        }
        return found
    }

    /// One representative raw name per distinct `NameKey`, so candidates that are the
    /// same place under slightly different casing only cost one fetch, not several.
    /// `localizedStandardContains` is itself case/diacritic-insensitive, so which
    /// candidate supplies the representative spelling does not change what matches.
    private static func candidateNames(_ candidates: [PlaceSuggestion]) -> [String] {
        Dictionary(grouping: candidates, by: { NameKey.matching($0.name) })
            .compactMap { key, group -> String? in
                let trimmed = group[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !Visit.isPlaceholderName(trimmed) else { return nil }
                return trimmed
            }
    }
}

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
        let candidates = PlaceScoringPipeline.candidates(suggestions: visit.placeSuggestions, savedPlaces: places, visit: visit)
        let visits = PlaceHistoryLookup.visits(near: candidates, context: context)
        let corrections = PlaceHistoryLookup.corrections(near: candidates, context: context)
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
