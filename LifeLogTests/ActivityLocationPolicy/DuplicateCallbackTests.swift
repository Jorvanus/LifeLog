import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Deduplicating and repairing repeated automatic callbacks: collapsing repeated
/// arrivals for the same place, trimming a departure that overlaps a later arrival,
/// closing superseded duplicates so their duration cannot grow, healing rows an
/// earlier build left stranded open, and merging an identifying callback into a
/// learned match — including the same behavior driven through the live
/// `LocationCallbackReplay` DSL rather than a single deduplication call.
@MainActor
struct DuplicateCallbackTests {
    private let base = ActivityLocationPolicyFixtures.defaultBase

    @Test("Repeated automatic callbacks collapse into one location visit")
    func deduplicatesRepeatedAutomaticLocations() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        for offset in [0.0, 0.5, 1.0] {
            context.insert(Visit(
                arrival: base.addingTimeInterval(offset), departure: nil,
                latitude: -27.47, longitude: 153.03,
                placeName: "Home", inferredActivity: "At home", source: "automatic"
            ))
        }
        context.insert(Visit(
            arrival: base.addingTimeInterval(1_800), departure: nil,
            latitude: -27.471, longitude: 153.031,
            placeName: "Shopping", inferredActivity: "Shopping", source: "automatic"
        ))
        try context.save()

        let removed = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()
        let locations = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)

        // Three repairs, not two: the two folded duplicates, plus closing the surviving
        // open Home stay at Shopping's arrival — asserted on the next line but two. The
        // return value is the number of repairs the pass made, and callers save on it,
        // so the close belongs in the count. It went uncounted until 2026-08-16, which
        // meant a pass whose only work was a close or a trim reported nothing and had
        // its change dropped by any caller that saves conditionally.
        #expect(removed == 3)
        #expect(locations.count == 2)
        #expect(locations[0].departure == base.addingTimeInterval(1_800))
        #expect(locations[1].departure == nil)
    }

    @Test("A departure delayed past a different place's arrival is trimmed, not left overlapping")
    func trimsADepartureThatOverlapsALaterArrival() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Mirrors a real capture: Home's departure callback was delayed and clamped
        // against `.now`, landing after Gracemere had already been recorded arriving —
        // the two stays claimed the same two minutes at different places.
        context.insert(Visit(
            arrival: base, departure: base.addingTimeInterval(5_900),
            latitude: -27.47, longitude: 153.03,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        ))
        context.insert(Visit(
            arrival: base.addingTimeInterval(5_760), departure: base.addingTimeInterval(5_900),
            latitude: -27.50, longitude: 153.06,
            placeName: "Gracemere Shopping World", inferredActivity: "Shopping", source: "automatic"
        ))
        try context.save()

        _ = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()
        let locations = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)

        #expect(locations.count == 2)
        #expect(locations[0].placeName == "Home")
        #expect(locations[0].departure == base.addingTimeInterval(5_760))
        #expect(locations[1].placeName == "Gracemere Shopping World")
        #expect(locations[1].departure == base.addingTimeInterval(5_900))
    }

    @Test("A superseded duplicate is closed so its duration cannot grow forever")
    func supersededDuplicatesAreClosed() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let winner = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                           placeName: "Home", inferredActivity: "At home", source: "automatic",
                           recognitionConfidence: "learned")
        // A second open callback for the same arrival, as Core Location replays.
        let duplicate = Visit(arrival: base.addingTimeInterval(20), latitude: -23.3702, longitude: 150.5101,
                              placeName: "Identifying…", inferredActivity: "Visiting", source: "automatic")
        context.insert(winner)
        context.insert(duplicate)
        try context.save()

        _ = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()

        let superseded = try context.fetch(FetchDescriptor<Visit>())
            .filter(ActivityLocationPolicy.isSupersededLocation)
        #expect(superseded.count == 1)
        // The interval moved to the winner, so the loser must not stay open.
        #expect(superseded.first?.departure != nil)
        #expect(superseded.first?.duration == 0)
        // The surviving visit keeps the open stay.
        let live = try context.fetch(FetchDescriptor<Visit>())
            .filter { ActivityLocationPolicy.isLocationVisit($0) }
        #expect(live.count == 1)
        #expect(live.first?.departure == nil)
    }

    @Test("Superseded rows stranded open by earlier builds are healed")
    func healsStrandedSupersededRows() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        // Written as an earlier build left it: relabelled but never closed.
        let stranded = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                             placeName: "atWork Australia", inferredActivity: "Working",
                             source: "automatic-superseded", recognitionConfidence: "low")
        context.insert(stranded)
        try context.save()
        #expect(stranded.departure == nil)

        let repaired = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        try context.save()

        #expect(repaired == 1, "The caller only saves when a repair is reported")
        #expect(stranded.departure == stranded.arrival)
        #expect(stranded.duration == 0)
    }

    @Test("A learned Home callback replaces a duplicate identifying arrival")
    func mergesIdentifyingCallbackIntoLearnedHome() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let identifying = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                                placeName: "Identifying…", inferredActivity: "Visiting", source: "automatic")
        let home = Visit(arrival: base.addingTimeInterval(20), latitude: -23.3702, longitude: 150.5101,
                         placeName: "Home", inferredActivity: "At home", source: "automatic",
                         recognitionConfidence: "learned")
        context.insert(identifying)
        context.insert(home)
        try context.save()

        let merged = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)

        #expect(merged == 1)
        #expect(identifying.placeName == "Home")
        #expect(identifying.recognitionConfidence == "learned")
        #expect(home.resolutionState == .superseded)
    }

    @Test("Home destination Home has one deterministic open visit")
    func resolvesHomeDestinationHomeSequence() throws {
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let firstHome = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                              placeName: "Home", inferredActivity: "At home", source: "automatic")
        let destination = Visit(arrival: base.addingTimeInterval(60 * 60),
                                latitude: -23.43, longitude: 150.45,
                                placeName: "Shops", inferredActivity: "Shopping", source: "automatic")
        let secondHome = Visit(arrival: base.addingTimeInterval(2 * 60 * 60),
                               latitude: -23.37, longitude: 150.51,
                               placeName: "Home", inferredActivity: "At home", source: "automatic")
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
        let context = try ActivityLocationPolicyFixtures.makeContext()
        let learned = Visit(arrival: base, departure: base.addingTimeInterval(20 * 60),
                            latitude: -23.40, longitude: 150.50,
                            placeName: "Park", inferredActivity: "Exercising", source: "automatic",
                            recognitionConfidence: "learned")
        let corrected = Visit(arrival: base.addingTimeInterval(30), departure: base.addingTimeInterval(25 * 60),
                              latitude: -23.399, longitude: 150.50,
                              placeName: "Park", inferredActivity: "Exercising", userActivity: "Exercising",
                              source: "automatic", recognitionConfidence: "confirmed")
        context.insert(learned); context.insert(corrected); try context.save()

        let marked = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
        let records = try context.fetch(FetchDescriptor<Visit>())

        #expect(marked == 1)
        #expect(records.count == 2)
        #expect(records.filter(ActivityLocationPolicy.isSupersededLocation).count == 1)
        #expect(records.first(where: { !ActivityLocationPolicy.isSupersededLocation($0) })?.recognitionConfidence == "confirmed")
    }

    @Test("Location callback replay keeps Home, destination, Home as three consecutive stays")
    func replaysHomeDestinationHomeCallbacks() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.arrive("Shops", at: 60, latitude: -23.4300, longitude: 150.4500, mapsIdentifier: "shops")
        try replay.arrive("Home", at: 120, latitude: -23.3701, longitude: 150.5101, mapsIdentifier: "home")

        let stays = try replay.liveStays()
        #expect(stays.map(\.placeName) == ["Home", "Shops", "Home"])
        #expect(stays.map(\.departure) == [replay.time(60), replay.time(120), nil])
    }

    @Test("Repeated arrival callbacks replay as one live stay")
    func replaysDuplicateArrivals() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Home", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "home")
        try replay.arrive("Home", at: 0.5, latitude: -23.3702, longitude: 150.5101, mapsIdentifier: "home")

        let stays = try replay.liveStays()
        let superseded = try replay.supersededStays()
        #expect(stays.count == 1)
        #expect(superseded.count == 1)
    }

    @Test("A same-venue replay tolerates GPS drift when Maps identity agrees")
    func replaysSameVenueWithGPSDrift() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Rockhampton Mall", at: 0, latitude: -23.3740, longitude: 150.5110, mapsIdentifier: "mall")
        // Around 220 m away: too large for a raw-fix retry, but still one mall POI.
        try replay.arrive("Rockhampton Mall", at: 20.0 / 60, latitude: -23.3720, longitude: 150.5110, mapsIdentifier: "mall")

        let stays = try replay.liveStays()
        let superseded = try replay.supersededStays()
        #expect(stays.count == 1)
        #expect(superseded.count == 1)
    }

    @Test("Nearby named businesses replay as separate destinations")
    func preservesNearbyDifferentBusinessesDuringReplay() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Coffee House", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "coffee-house")
        // About 22 m away, so time and distance alone would look duplicate-like.
        try replay.arrive("Chemist", at: 30, latitude: -23.3702, longitude: 150.5100, mapsIdentifier: "chemist")

        let stays = try replay.liveStays()
        #expect(stays.map(\.placeName) == ["Coffee House", "Chemist"])
        #expect(stays[0].departure == replay.time(30))
        #expect(try replay.supersededStays().isEmpty)
    }

    @Test("Callback repairs persist why each row was retained or superseded")
    func persistsCallbackResolutionExplanation() throws {
        let replay = try LocationCallbackReplay(base: base)
        try replay.arrive("Cafe", at: 0, latitude: -23.3700, longitude: 150.5100, mapsIdentifier: "cafe")
        try replay.arrive("Cafe", at: 0.5, latitude: -23.3702, longitude: 150.5101, mapsIdentifier: "cafe")

        let kept = try #require(replay.liveStays().first)
        let superseded = try #require(replay.supersededStays().first)
        #expect(kept.locationResolutionExplanation == .mapsIdentifier)
        #expect(superseded.locationResolutionExplanation == .duplicate)
    }
}
