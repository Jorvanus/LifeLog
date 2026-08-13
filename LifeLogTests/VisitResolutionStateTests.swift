import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `Visit.setResolutionState` is the single place `resolutionStateRaw` is ever
/// written, and the location resolver's `reconcileResolutionStates` is the single
/// place automation calls it. These tests cover the invariants that pairing is
/// supposed to guarantee: automation moves a visit between provisional, resolved
/// and superseded on its own, but never touches an ignored visit or a confirmed
/// correction, and re-running it is a no-op once a visit has settled.
@MainActor
struct VisitResolutionStateTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A provisional automatic visit resolves once it gains a real place and confidence")
    func provisionalVisitResolvesNormally() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                          source: "automatic")
        context.insert(visit)
        try context.save()
        #expect(visit.resolutionState == .provisional)

        visit.placeName = "Home"
        visit.recognitionConfidence = "learned"
        let changed = try ActivityLocationPolicy.reconcileResolutionStates(context: context)

        #expect(changed == 1)
        #expect(visit.resolutionState == .resolved)
    }

    @Test("Automation marks a superseded callback superseded and never reopens it")
    func supersededVisitStaysSuperseded() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: "Home", inferredActivity: "At home",
                          source: "automatic", recognitionConfidence: "learned")
        context.insert(visit)
        try context.save()
        #expect(visit.resolutionState == .resolved)

        visit.source = ActivityLocationPolicy.supersededLocationSource
        try ActivityLocationPolicy.reconcileResolutionStates(context: context)
        #expect(visit.resolutionState == .superseded)

        // A later pass, with nothing else changed, must not un-supersede it --
        // superseded is derived from `source`, and nothing here rewrites that.
        let changed = try ActivityLocationPolicy.reconcileResolutionStates(context: context)
        #expect(changed == 0)
        #expect(visit.resolutionState == .superseded)
    }

    @Test("Automation can never set or clear ignored")
    func automationCannotTouchIgnored() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: "A misidentified drive-by", inferredActivity: "Visiting",
                          source: "automatic", recognitionConfidence: "low")
        context.insert(visit)
        try context.save()

        #expect(visit.setResolutionState(.ignored, actor: .automation) == false,
                "only a person may set ignored")
        #expect(visit.resolutionState != .ignored)

        visit.isIgnored = true
        #expect(visit.resolutionState == .ignored)

        // Automation now finds a real place name for the same coordinate -- the
        // resolver runs unconditionally on every mutation, ignored visit or not.
        visit.placeName = "Corner Cafe"
        visit.recognitionConfidence = "learned"
        let changed = try ActivityLocationPolicy.reconcileResolutionStates(context: context)

        #expect(changed == 0, "automation must not silently un-ignore a visit")
        #expect(visit.resolutionState == .ignored)
        #expect(visit.isIgnored)
    }

    @Test("Unignoring hands a visit back to what the resolver would currently derive, not a blanket provisional")
    func unignoringRestoresTheDerivedState() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: "Home", inferredActivity: "At home",
                          source: "automatic", recognitionConfidence: "learned")
        context.insert(visit)
        try context.save()
        #expect(visit.resolutionState == .resolved)

        visit.isIgnored = true
        #expect(visit.resolutionState == .ignored)

        visit.isIgnored = false
        // The place was already resolved before it was ignored, and nothing about
        // it changed in between -- it must not reappear looking unresolved.
        #expect(visit.resolutionState == .resolved)
    }

    @Test("A confirmed correction survives subsequent automation even when its fields would derive differently")
    func confirmedCorrectionSurvivesAutomation() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                          placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                          source: "automatic")
        context.insert(visit)
        try context.save()
        #expect(visit.resolutionState == .provisional)

        // A person corrects it by hand: a real place, their own confirmation, and
        // (as `VisitEditor.persistChanges` does for the same correction) their own
        // explicit `.resolved` -- automation is about to be shut out of this visit
        // by the `recognitionConfidence` guard below, so nothing else would ever
        // move it off `.provisional` if this didn't.
        visit.placeName = "A friend's place"
        visit.recognitionConfidence = "confirmed"
        visit.setResolutionState(.resolved, actor: .user)
        #expect(visit.resolutionState == .resolved)

        // Automation later reverts the place name to a placeholder -- imagine a
        // conflicting callback replaying -- which would ordinarily derive
        // `.provisional`. The correction must hold anyway.
        visit.placeName = Visit.identifyingPlaceName
        let changed = try ActivityLocationPolicy.reconcileResolutionStates(context: context)

        #expect(changed == 0, "a confirmed visit's resolution state must not move under automation")
        #expect(visit.resolutionState == .resolved)
    }

    @Test("Reconciling an already-settled store twice in a row changes nothing the second time")
    func reconcileResolutionStatesIsIdempotent() throws {
        let context = try makeContext()
        let provisional = Visit(arrival: base, latitude: -23.37, longitude: 150.51,
                                placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting",
                                source: "automatic")
        let resolved = Visit(arrival: base.addingTimeInterval(3_600), latitude: -23.42, longitude: 150.55,
                             placeName: "Work", inferredActivity: "Working",
                             source: "automatic", recognitionConfidence: "learned")
        let superseded = Visit(arrival: base.addingTimeInterval(3_660), latitude: -23.42, longitude: 150.55,
                               placeName: "Work", inferredActivity: "Working",
                               source: ActivityLocationPolicy.supersededLocationSource)
        context.insert(provisional); context.insert(resolved); context.insert(superseded)
        try context.save()

        let firstPass = try ActivityLocationPolicy.reconcileResolutionStates(context: context)
        let secondPass = try ActivityLocationPolicy.reconcileResolutionStates(context: context)

        #expect(firstPass == 0, "each visit's own init already derived the right state")
        #expect(secondPass == 0)
        #expect(provisional.resolutionState == .provisional)
        #expect(resolved.resolutionState == .resolved)
        #expect(superseded.resolutionState == .superseded)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
