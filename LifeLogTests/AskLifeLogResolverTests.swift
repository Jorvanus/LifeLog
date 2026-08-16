import Foundation
import Testing
@testable import LifeLog

/// Bounded, deterministic local matching of a phrase the model only ever
/// echoes back — never resolved by the model itself. Covers exact matches,
/// genuine ambiguity, no match at all, and activities that were renamed,
/// merged, or exist only as a history-only (never-adopted) label.
struct AskLifeLogResolverTests {
    private func summary(_ name: String, count: Int = 1) -> PlaceHistorySummary {
        PlaceHistorySummary(name: name, count: count, dominantActivity: "Visiting", dominantShare: 100)
    }

    @Test("An exact (case/accent-insensitive) place phrase resolves to one candidate")
    func exactPlaceMatchResolves() {
        let summaries = [summary("Café Rouge"), summary("Gym")]
        let result = AskLifeLogResolver.resolvePlace(.init("cafe rouge"), among: summaries)
        #expect(result == .resolved(.init(name: "Café Rouge")))
    }

    @Test("A phrase matching several distinct places is ambiguous, capped and sorted")
    func multiplePlaceMatchesAreAmbiguous() {
        let summaries = [summary("Riverside Cafe"), summary("Riverside Gym"), summary("Riverside Pharmacy")]
        let result = AskLifeLogResolver.resolvePlace(.init("Riverside"), among: summaries)
        #expect(result == .ambiguous(["Riverside Cafe", "Riverside Gym", "Riverside Pharmacy"].map { .init(name: $0) }))
    }

    @Test("A phrase matching nothing in scoped history resolves to none")
    func noMatchResolvesToNone() {
        let result = AskLifeLogResolver.resolvePlace(.init("Nonexistent Place"), among: [summary("Home")])
        #expect(result == .none)
    }

    @Test("An empty phrase never matches anything")
    func emptyPhraseResolvesToNone() {
        #expect(AskLifeLogResolver.resolvePlace(.init(""), among: [summary("Home")]) == .none)
    }

    @Test("A renamed activity's old label still resolves to its current name")
    func renamedActivityResolvesToCurrentLabel() {
        var definition = ActivityDefinition(name: "Deep Work", category: "Work")
        definition.legacyNames = ["Working"]
        let result = AskLifeLogResolver.resolveActivity(.init("Working"), among: [definition])
        #expect(result == .resolved(.init(name: "Deep Work")))
    }

    @Test("A merged activity's absorbed label resolves to the surviving definition")
    func mergedActivityAliasResolvesToSurvivor() {
        var survivor = ActivityDefinition(name: "Home Time", category: "Home")
        survivor.legacyNames = ["At home", "Working from home"]
        let result = AskLifeLogResolver.resolveActivity(.init("working from home"), among: [survivor])
        #expect(result == .resolved(.init(name: "Home Time")))
    }

    @Test("A phrase with no catalogue or legacy match resolves to none, including a deleted activity's old name")
    func deletedActivityNameResolvesToNone() {
        let definitions = [ActivityDefinition(name: "Shopping", category: "Errands")]
        let result = AskLifeLogResolver.resolveActivity(.init("Discontinued Hobby"), among: definitions)
        #expect(result == .none)
    }

    @Test("A custom (non-default) activity resolves the same as any other catalogue entry")
    func customActivityResolvesNormally() {
        let definitions = [ActivityDefinition(name: "Volunteering at Shelter", category: "Community")]
        let result = AskLifeLogResolver.resolveActivity(.init("Volunteering at Shelter"), among: definitions)
        #expect(result == .resolved(.init(name: "Volunteering at Shelter")))
    }

    @Test("Ambiguous candidates are capped at maxAmbiguousCandidates")
    func ambiguousCandidatesAreBounded() {
        let summaries = (0..<10).map { summary("Riverside Place \($0)") }
        let result = AskLifeLogResolver.resolvePlace(.init("Riverside"), among: summaries)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("Expected ambiguous result")
            return
        }
        #expect(candidates.count == AskLifeLogResolver.maxAmbiguousCandidates)
    }
}
