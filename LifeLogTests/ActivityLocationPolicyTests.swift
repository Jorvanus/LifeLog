import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

@MainActor
struct ActivityLocationPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An active unknown visit is logged as an uncategorised location")
    func presentsUnknownCurrentLocation() {
        let visit = Visit(
            arrival: base,
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Identifying…",
            placeCategory: "Other",
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
            placeCategory: "Home",
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

    @Test("Opening an existing timeline removes activity inside a location visit")
    func removesExistingActivityAtLocation() throws {
        let context = try makeContext()
        let activity = Visit(
            arrival: base.addingTimeInterval(70 * 60),
            departure: base.addingTimeInterval(90 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            placeCategory: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        let location = Visit(
            arrival: base.addingTimeInterval(60 * 60),
            departure: base.addingTimeInterval(2 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            placeCategory: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        context.insert(activity)
        context.insert(location)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context)
        try context.save()
        let activities = try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isDeviceActivity)

        #expect(activities.isEmpty)
    }

    @Test("Sleep remains visible while the user is at Home")
    func preservesSleepAtLocation() throws {
        let context = try makeContext()
        let sleep = Visit(
            arrival: base,
            departure: base.addingTimeInterval(8 * 60 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Sleep",
            placeCategory: "Sleep",
            inferredActivity: "Sleeping",
            userActivity: "Sleeping",
            source: "health-sleep"
        )
        let home = Visit(
            arrival: base,
            departure: base.addingTimeInterval(9 * 60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Home",
            placeCategory: "Home",
            inferredActivity: "At home",
            source: "automatic"
        )
        context.insert(sleep)
        context.insert(home)
        try context.save()

        try ActivityLocationPolicy.reconcileAll(context: context)
        try context.save()

        let sleepVisits = try context.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-sleep" }
        #expect(sleepVisits.count == 1)
        #expect(sleepVisits[0].arrival == base)
        #expect(sleepVisits[0].departure == base.addingTimeInterval(8 * 60 * 60))
    }

    @Test("Repeated automatic callbacks collapse into one location visit")
    func deduplicatesRepeatedAutomaticLocations() throws {
        let context = try makeContext()
        for offset in [0.0, 0.5, 1.0] {
            context.insert(Visit(
                arrival: base.addingTimeInterval(offset), departure: nil,
                latitude: -27.47, longitude: 153.03,
                placeName: "Home", placeCategory: "Home",
                inferredActivity: "At home", source: "automatic"
            ))
        }
        context.insert(Visit(
            arrival: base.addingTimeInterval(1_800), departure: nil,
            latitude: -27.471, longitude: 153.031,
            placeName: "Shopping", placeCategory: "Shopping",
            inferredActivity: "Shopping", source: "automatic"
        ))
        try context.save()

        let removed = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()
        let locations = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)

        #expect(removed == 2)
        #expect(locations.count == 2)
        #expect(locations[0].departure == base.addingTimeInterval(1_800))
        #expect(locations[1].departure == nil)
    }

    @Test("Walking is only shown between two destinations")
    func walkingRequiresTwoDestinations() {
        let previous = Visit(
            arrival: base,
            departure: base.addingTimeInterval(60 * 60),
            latitude: -27.47,
            longitude: 153.03,
            placeName: "Work",
            placeCategory: "Work",
            inferredActivity: "Working",
            source: "automatic"
        )
        let walking = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(90 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            placeCategory: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        let next = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Cafe",
            placeCategory: "Food & Drink",
            inferredActivity: "Eating",
            source: "automatic"
        )

        #expect(ActivityLocationPolicy.shouldShow(walking, alongside: [previous, walking]) == false)
        #expect(ActivityLocationPolicy.shouldShow(walking, alongside: [previous, walking, next]) == true)
        // Batch consumers such as Insights pre-filter locations once for the same result.
        #expect(ActivityLocationPolicy.shouldShow(walking, locationVisits: [previous, next]) == true)

        let walkingAtHome = Visit(
            arrival: base.addingTimeInterval(15 * 60),
            departure: base.addingTimeInterval(30 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "Walking",
            placeCategory: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking",
            source: "health-walking"
        )
        #expect(ActivityLocationPolicy.shouldShow(walkingAtHome, alongside: [previous, walkingAtHome, next]) == false)

        let driving = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            placeCategory: "Travel",
            inferredActivity: "Travelling",
            userActivity: "Travelling",
            source: "motion"
        )
        #expect(ActivityLocationPolicy.shouldShow(driving, alongside: [previous, driving]) == false)
        #expect(ActivityLocationPolicy.shouldShow(driving, alongside: [previous, driving, next]) == true)
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

    @Test("Vehicle travel is classified toward a recurring work destination")
    func classifiesTravelToWork() throws {
        let context = try makeContext()
        let work = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Office",
            placeCategory: "Work",
            inferredActivity: "Working",
            source: "automatic"
        )
        let travel = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            placeCategory: "Travelling",
            inferredActivity: "Travelling",
            userActivity: "Travelling",
            source: "motion"
        )
        context.insert(work)
        context.insert(travel)
        try context.save()

        try ActivityLocationPolicy.updateTravelDescriptions(context: context)

        #expect(travel.placeCategory == "Travel")
        #expect(travel.activity == "Travelling to Work")
        #expect(travel.recognitionConfidence == "learned")
    }

    @Test("A manually named travel activity is preserved")
    func preservesManualTravelActivity() throws {
        let context = try makeContext()
        let work = Visit(
            arrival: base.addingTimeInterval(2 * 60 * 60),
            departure: base.addingTimeInterval(3 * 60 * 60),
            latitude: -27.46,
            longitude: 153.04,
            placeName: "Office",
            placeCategory: "Work",
            inferredActivity: "Working",
            source: "automatic"
        )
        let travel = Visit(
            arrival: base.addingTimeInterval(75 * 60),
            departure: base.addingTimeInterval(105 * 60),
            latitude: 0,
            longitude: 0,
            placeName: "In transit",
            placeCategory: "Travelling",
            inferredActivity: "Travelling",
            userActivity: "Commuting",
            source: "motion"
        )
        context.insert(work)
        context.insert(travel)
        try context.save()

        try ActivityLocationPolicy.updateTravelDescriptions(context: context)

        #expect(travel.placeCategory == "Travel")
        #expect(travel.activity == "Commuting")
        #expect(travel.inferredActivity == "Travelling to Work")
    }

    @Test("Home destination Home has one deterministic open visit")
    func resolvesHomeDestinationHomeSequence() throws {
        let context = try makeContext()
        let firstHome = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                              placeName: "Home", placeCategory: "Home",
                              inferredActivity: "At home", source: "automatic")
        let destination = Visit(arrival: base.addingTimeInterval(60 * 60),
                                latitude: -23.43, longitude: 150.45,
                                placeName: "Shops", placeCategory: "Shopping",
                                inferredActivity: "Shopping", source: "automatic")
        let secondHome = Visit(arrival: base.addingTimeInterval(2 * 60 * 60),
                               latitude: -23.37, longitude: 150.51,
                               placeName: "Home", placeCategory: "Home",
                               inferredActivity: "At home", source: "automatic")
        [firstHome, destination, secondHome].forEach(context.insert)
        try context.save()

        let repaired = try ActivityLocationPolicy.closeSupersededOpenLocations(context: context)

        #expect(repaired == 2)
        #expect(firstHome.departure == destination.arrival)
        #expect(destination.departure == secondHome.arrival)
        #expect(secondHome.departure == nil)
    }

    @Test("Duplicate delayed callback is preserved and marked superseded")
    func preservesSupersededDelayedCallback() throws {
        let context = try makeContext()
        let learned = Visit(arrival: base, departure: base.addingTimeInterval(20 * 60),
                            latitude: -23.40, longitude: 150.50,
                            placeName: "Park", placeCategory: "Fitness",
                            inferredActivity: "Exercising", source: "automatic",
                            recognitionConfidence: "learned")
        let corrected = Visit(arrival: base.addingTimeInterval(30), departure: base.addingTimeInterval(25 * 60),
                              latitude: -23.399, longitude: 150.50,
                              placeName: "Park", placeCategory: "Fitness",
                              inferredActivity: "Exercising", userActivity: "Exercising",
                              source: "automatic", recognitionConfidence: "confirmed")
        context.insert(learned); context.insert(corrected); try context.save()

        let marked = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        let records = try context.fetch(FetchDescriptor<Visit>())

        #expect(marked == 1)
        #expect(records.count == 2)
        #expect(records.filter(ActivityLocationPolicy.isSupersededLocation).count == 1)
        #expect(records.first(where: { !ActivityLocationPolicy.isSupersededLocation($0) })?.recognitionConfidence == "confirmed")
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            VisitCorrection.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
