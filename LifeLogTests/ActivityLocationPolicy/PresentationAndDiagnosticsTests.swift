import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Simple, mostly pure-function checks that do not fit any of the scenario-driven
/// suites: how a visit presents itself, manual map resolution confidence, activity/
/// location time subtraction, diagnostics opt-in, and sleep scoring.
@MainActor
struct PresentationAndDiagnosticsTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    @Test("An active unknown visit is logged as an uncategorised location")
    func presentsUnknownCurrentLocation() {
        let visit = Visit(
            arrival: base,
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Identifying…",
            inferredActivity: "Visiting",
            source: "automatic"
        )

        #expect(visit.needsCategorisation)
        #expect(visit.displayPlaceName == "Uncategorised location")
        #expect(visit.insightCategory == "Uncategorised")
        #expect(visit.suspectedActivity == "Visiting")
    }

    @Test("Manual map selection distinguishes a pin fallback from a business match")
    func manualMapResolutionConfidence() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let pin = ManualPlaceResolution.pinned(coordinate)
        let match = ManualPlaceResolution.matched(name: "Coffee", coordinate: coordinate)

        #expect(pin.confidence == "low")
        #expect(pin.coordinate?.latitude == coordinate.latitude)
        #expect(match.confidence == "confirmed")
        #expect(ManualPlaceResolution.none.coordinate == nil)
    }

    @Test("Activity imported after a location visit excludes the occupied time")
    func subtractsLocationTimeFromImportedActivity() {
        let location = Visit(
            arrival: base.addingTimeInterval(60 * 60),
            departure: base.addingTimeInterval(2 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        let activity = DateInterval(start: base, end: base.addingTimeInterval(3 * 60 * 60))

        let remaining = ActivityLocationPolicy.remainingSegments(
            for: activity,
            locationVisits: [location],
            now: base.addingTimeInterval(4 * 60 * 60)
        )

        #expect(remaining.count == 2)
        #expect(remaining[0] == DateInterval(start: base, end: base.addingTimeInterval(60 * 60)))
        #expect(remaining[1] == DateInterval(
            start: base.addingTimeInterval(2 * 60 * 60),
            end: base.addingTimeInterval(3 * 60 * 60)
        ))
    }

    /// The reason a callback was acted on is always safe to record. The evidence —
    /// which places were offered and how far away they were — is a record of where the
    /// owner has been, and must not be written unless they asked for it.
    @Test("Place names are only recorded when detailed diagnostics are on")
    func detailedDiagnosticsAreOptIn() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let wasDetailed = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = wasDetailed }

        LocationDiagnostics.isDetailed = false
        LocationDiagnostics.record(.merged, subject: "Duplicate callback",
                                   reason: "same arrival", evidence: "Corner Cafe folded into Home",
                                   context: context)
        LocationDiagnostics.recordLookup(
            radius: 150, cacheHit: false,
            candidates: [PlaceSuggestion(name: "Corner Cafe", latitude: -23.37, longitude: 150.51,
                                         suggestedActivity: "Eating", distance: 22)],
            selected: nil, confidence: "medium", fallback: nil, context: context)
        try context.save()

        var events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.count == 2)
        // The decision and the numbers survive; the place names do not.
        #expect(events.contains { $0.message.contains("merged") })
        #expect(events.contains { $0.message.contains("1 candidates") })
        #expect(events.allSatisfy { !$0.message.contains("Corner Cafe") })

        LocationDiagnostics.isDetailed = true
        LocationDiagnostics.record(.merged, subject: "Duplicate callback",
                                   reason: "same arrival", evidence: "Corner Cafe folded into Home",
                                   context: context)
        try context.save()
        events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.contains { $0.message.contains("Corner Cafe") })
        #expect(events.allSatisfy { $0.category == LocationDiagnostics.category })
    }

    @Test("LifeLog sleep estimate reflects duration, stages, and interruptions")
    func estimatesSleepQuality() {
        let summary = SleepSummary(
            totalSleep: 8 * 60 * 60,
            timeInBed: 8.5 * 60 * 60,
            awake: 30 * 60,
            rem: 90 * 60,
            core: 4 * 60 * 60,
            deep: 2.5 * 60 * 60,
            interruptions: 2
        )

        #expect(summary.estimatedScore == 94)
    }
}
