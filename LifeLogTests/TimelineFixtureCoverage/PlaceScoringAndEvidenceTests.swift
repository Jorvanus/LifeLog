import Foundation
import Testing
@testable import LifeLog

/// Evidence-based place policy: which Saved Places win a limited geofence
/// slot, and how the scoring pipeline weighs geofence, POI, dwell, accuracy,
/// recurrence, time-of-day and correction-history evidence into one
/// breakdown — including what survives edit-time cleanup for diagnostics.
@MainActor
struct PlaceScoringAndEvidenceTests {
    private let base = TimelineFixtureBuilders.referenceDate()

    /// iOS watches a limited number of regions, so which places get a slot decides
    /// which arrivals are recognised instantly and which wait for a delayed callback.
    @Test("The places watched are the ones actually used")
    func prioritisesMonitoredPlaces() {
        func place(_ name: String, _ latitude: Double) -> SavedPlace {
            SavedPlace(name: name, latitude: latitude, longitude: 150.51, radius: 100)
        }
        func visit(_ name: String, daysAgo: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(-daysAgo * 86_400),
                  departure: base.addingTimeInterval(-daysAgo * 86_400 + 3_600),
                  latitude: -23.37, longitude: 150.51, placeName: name,
                  inferredActivity: "Visiting", source: "automatic")
        }
        let home = place("Home", -23.37)
        let work = place("Work", -23.38)
        let cottage = place("Cottage", -23.39)
        let never = place("Never been", -23.40)
        let visits = (0..<20).map { visit("Home", daysAgo: Double($0)) }
            + (0..<10).map { visit("Work", daysAgo: Double($0)) }
            + [visit("Cottage", daysAgo: 0.5)]

        let ranked = MonitoredPlaces.prioritised([never, cottage, work, home], visits: visits)

        // Frequency first: the cottage was visited most recently but is used once.
        #expect(ranked.map(\.name) == ["Home", "Work", "Cottage", "Never been"])
        #expect(ranked.first?.visits == 20)
        #expect(ranked.last?.lastVisit == nil)
    }

    @Test("Only as many places are watched as iOS will allow")
    func limitsMonitoredPlaces() {
        let places = (0..<30).map {
            SavedPlace(name: "Place \($0)", latitude: -23.37 + Double($0) / 1_000,
                       longitude: 150.51, radius: 100)
        }
        let ranked = MonitoredPlaces.prioritised(places, visits: [])

        #expect(MonitoredPlaces.limit == 20)
        #expect(ranked.count == 20)
        // Each region needs an identifier that survives a relaunch and is its own.
        #expect(Set(ranked.map(\.identifier)).count == ranked.count)
        #expect(ranked.first?.identifier.hasPrefix("place|") == true)
    }

    @Test("A renamed place keeps the history that earned it a slot")
    func matchesVisitsByNameAndGeofence() {
        let place = SavedPlace(name: "Corner Cafe", latitude: -23.37, longitude: 150.51, radius: 100)
        // One recorded under the name, one recorded only as a coordinate inside it.
        let byName = Visit(arrival: base, departure: base.addingTimeInterval(600),
                           latitude: 0, longitude: 0, placeName: "Corner Cafe",
                           inferredActivity: "Eating", source: "manual")
        let byLocation = Visit(arrival: base.addingTimeInterval(3_600),
                               departure: base.addingTimeInterval(4_200),
                               latitude: -23.3701, longitude: 150.5101, placeName: "Identifying…",
                               inferredActivity: "Visiting", source: "automatic")
        let faraway = Visit(arrival: base, departure: base.addingTimeInterval(600),
                            latitude: -23.50, longitude: 150.90, placeName: "Elsewhere",
                            inferredActivity: "Visiting", source: "automatic")

        let ranked = MonitoredPlaces.prioritised([place], visits: [byName, byLocation, faraway])

        #expect(ranked.first?.visits == 2)
    }

    @Test("Monitored-place matching uses the shared name normalization")
    func matchesMonitoredPlacesByNormalizedName() {
        let place = SavedPlace(name: "Café Central", latitude: -23.37, longitude: 150.51, radius: 100)
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(600),
                          latitude: 0, longitude: 0, placeName: "  cafe central  ",
                          inferredActivity: "Eating", source: "automatic")

        let ranked = MonitoredPlaces.prioritised([place], visits: [visit])

        #expect(ranked.first?.visits == 1)
        #expect(ranked.first?.identifier == "place|cafe central|-23.37000,150.51000")
    }

    @Test("Place scoring keeps every evidence component")
    func scoresPlaceEvidenceAsOneBreakdown() {
        let place = SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51, radius: 100,
                               mapsIdentifier: "home-id")
        let arrival = base.addingTimeInterval(9 * 3_600)
        let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(3_600),
                          latitude: -23.37001, longitude: 150.51001, placeName: "Home",
                          inferredActivity: "At home", source: "automatic")
        let previous = (0..<3).map { offset in
            Visit(arrival: arrival.addingTimeInterval(Double(offset - 4) * 86_400),
                  departure: arrival.addingTimeInterval(Double(offset - 4) * 86_400 + 3_600),
                  latitude: -23.37, longitude: 150.51, placeName: "Home",
                  inferredActivity: "At home", source: "automatic")
        }
        let suggestion = PlaceSuggestion(name: "Home", latitude: -23.37001, longitude: 150.51001,
                                         suggestedActivity: "At home", distance: 8,
                                         mapsIdentifier: "home-id", mapsCategory: "home")
        let correction = VisitCorrection(visitArrival: arrival.addingTimeInterval(-86_400),
                                         latitude: -23.37, longitude: 150.51,
                                         previousPlaceName: "House", newPlaceName: "Home",
                                         previousActivity: "Visiting", newActivity: "At home")

        // "arrival" (the default stage) deliberately zeroes dwell — a new arrival
        // doesn't yet prove one. This fixture's visit already carries a departure, so
        // score it at the stage that actually reads dwell, matching PlaceScoringPipeline
        // .evaluate's own two-stage lifecycle (re-scored at departure).
        let evaluation = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [place], suggestions: [suggestion], accuracy: 8,
            geofenceTriggered: true, visits: previous + [visit], corrections: [correction],
            stage: "departure", now: base
        )

        #expect(evaluation.selected?.mapsIdentifier == "home-id")
        #expect(evaluation.breakdown.total > 80)
        #expect(evaluation.breakdown.savedPlaceGeofence == 35)
        #expect(evaluation.breakdown.poiDistance > 0)
        #expect(evaluation.breakdown.poiCategory == 10)
        #expect(evaluation.breakdown.dwellDuration > 0)
        #expect(evaluation.breakdown.horizontalAccuracy == 10)
        #expect(evaluation.breakdown.recurrence == 3)
        #expect(evaluation.breakdown.timeOfDay > 0)
        #expect(evaluation.breakdown.priorCorrections == 5)
    }

    @Test("Place scores gain dwell evidence when a stay closes without replacing confirmation")
    func rescoringClosedStayRaisesDwellWithoutOverwritingConfirmedChoice() {
        let arrival = base.addingTimeInterval(9 * 3_600)
        let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(3_600),
                          latitude: -23.37, longitude: 150.51, placeName: "Home",
                          inferredActivity: "At home", source: "automatic",
                          recognitionConfidence: "confirmed")
        let suggestion = PlaceSuggestion(name: "Home", latitude: -23.37, longitude: 150.51,
                                         suggestedActivity: "At home", distance: 5,
                                         mapsIdentifier: "home-id", mapsCategory: "home")

        let arrivalScore = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [], suggestions: [suggestion], accuracy: 10,
            geofenceTriggered: false, visits: [], corrections: [], stage: "arrival", now: arrival
        )
        let departureScore = PlaceScoringPipeline.evaluate(
            visit: visit, savedPlaces: [], suggestions: [suggestion], accuracy: 10,
            geofenceTriggered: false, visits: [], corrections: [], stage: "departure", now: arrival.addingTimeInterval(3_600)
        )

        #expect(arrivalScore.breakdown.dwellDuration == 0)
        #expect(departureScore.breakdown.dwellDuration == 15)
        #expect(departureScore.breakdown.total > arrivalScore.breakdown.total)
        #expect(departureScore.breakdown.lifecycleStage == "departure")
        #expect(departureScore.breakdown.decisionThreshold == PlaceScoreLifecycle.suggestionThreshold)
        #expect(PlaceScoreLifecycle.canSuggest(for: visit, evaluation: departureScore) == false)
    }

    @Test("Place score survives the existing candidate payload")
    func storesPlaceScoreAlongsideCandidates() {
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51)
        let suggestion = PlaceSuggestion(name: "Corner Cafe", latitude: -23.37, longitude: 150.51,
                                         suggestedActivity: "Eating", distance: 20,
                                         mapsIdentifier: "cafe-id", mapsCategory: "cafe")
        let score = PlaceScoreBreakdown(recordedAt: base, total: 84,
                                        savedPlaceGeofence: 35, poiDistance: 14,
                                        poiCategory: 10, dwellDuration: 10,
                                        horizontalAccuracy: 8, recurrence: 4,
                                        timeOfDay: 2, priorCorrections: 1,
                                        selectedPlaceName: "Corner Cafe", mapsIdentifier: "cafe-id")

        visit.placeSuggestions = [suggestion]
        visit.placeScoreBreakdown = score

        #expect(visit.placeSuggestions.first?.mapsIdentifier == "cafe-id")
        #expect(visit.placeSuggestions.first?.mapsCategory == "cafe")
        #expect(visit.placeScoreBreakdown == score)
    }

    @Test("Resolution candidate audit survives editor suggestion cleanup")
    func retainsResolutionCandidatesForDiagnostics() {
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51)
        let chosen = PlaceSuggestion(name: "Corner Cafe", latitude: -23.37, longitude: 150.51,
                                     suggestedActivity: "Eating", distance: 20,
                                     mapsIdentifier: "cafe-id")
        let rejected = PlaceSuggestion(name: "Bakery", latitude: -23.3702, longitude: 150.5101,
                                       suggestedActivity: "Eating", distance: 45,
                                       mapsIdentifier: "bakery-id")

        visit.placeSuggestions = [chosen, rejected]
        visit.locationResolutionCandidates = .init(chosen: chosen, rejected: [rejected])
        // Saved Place learning clears edit-time suggestions after applying a correction.
        visit.placeSuggestions = []

        #expect(visit.placeSuggestions.isEmpty)
        #expect(visit.locationResolutionCandidates?.chosen == chosen)
        #expect(visit.locationResolutionCandidates?.rejected == [rejected])
    }
}
