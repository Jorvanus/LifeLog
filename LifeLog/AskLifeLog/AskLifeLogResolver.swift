import Foundation

/// What resolving a phrase against LifeLog's own catalogue/history produced.
enum AskLifeLogResolution<Candidate: Sendable & Equatable>: Sendable, Equatable {
    case resolved(Candidate)
    case ambiguous([Candidate])
    case none
}

struct AskLifeLogPlaceCandidate: Sendable, Equatable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct AskLifeLogActivityCandidate: Sendable, Equatable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

/// Bounded, deterministic matching of a phrase the model echoed back (never
/// chose) against LifeLog's own scoped catalogue/history. This is the only place
/// a named place or activity reference in a query plan becomes something LifeLog
/// will actually query for — the model never sees this list and never picks
/// between similarly named things itself.
enum AskLifeLogResolver {
    /// Caps how many candidates a disambiguation picker ever shows. A phrase that
    /// fuzzy-matches more than this is still bounded, never an unbounded list —
    /// the least-visited overflow is simply left out rather than shown.
    static let maxAmbiguousCandidates = 5

    static func resolvePlace(_ reference: AskLifeLogUnresolvedReference,
                             among summaries: [PlaceHistorySummary]) -> AskLifeLogResolution<AskLifeLogPlaceCandidate> {
        resolve(reference, candidates: summaries.map { (matchName: $0.name, resultName: $0.name, weight: $0.count) })
            .map(AskLifeLogPlaceCandidate.init)
    }

    static func resolveActivity(_ reference: AskLifeLogUnresolvedReference,
                                among definitions: [ActivityDefinition]) -> AskLifeLogResolution<AskLifeLogActivityCandidate> {
        // Every name a definition answers to -- its current label and any legacy
        // alias -- is matched against separately (`matchName`), but always
        // resolves back to the current label (`resultName`), so a phrase matching
        // a renamed activity's old name still resolves to the activity LifeLog
        // would actually total, not a dead end.
        var candidates: [(matchName: String, resultName: String, weight: Int)] = []
        var seenPairs: Set<String> = []
        for definition in definitions {
            for alias in [definition.name] + definition.legacyNames {
                let key = NameKey.matching(alias)
                guard !key.isEmpty else { continue }
                let pairKey = "\(key)|\(definition.name)"
                guard !seenPairs.contains(pairKey) else { continue }
                seenPairs.insert(pairKey)
                candidates.append((matchName: alias, resultName: definition.name, weight: 1))
            }
        }
        return resolve(reference, candidates: candidates).map(AskLifeLogActivityCandidate.init)
    }

    /// `weight` breaks ties when several distinct candidates collapse to the
    /// exact same `NameKey` (accent/case variants, or two aliases of one place) —
    /// the more historically common spelling wins rather than an arbitrary one.
    /// `matchName` is what the phrase is compared against; `resultName` is what
    /// gets returned — distinct so an activity's legacy alias can be matched
    /// while always resolving to its current label.
    private static func resolve(_ reference: AskLifeLogUnresolvedReference,
                                candidates: [(matchName: String, resultName: String, weight: Int)]) -> AskLifeLogResolution<String> {
        guard !reference.isEmpty else { return .none }
        let key = NameKey.matching(reference.phrase)
        let precise = candidates.filter { NameKey.matching($0.matchName) == key }
        if let best = precise.max(by: { $0.weight < $1.weight }) {
            return .resolved(best.resultName)
        }

        let tokens = NameKey.tokens(reference.phrase)
        guard !tokens.isEmpty else { return .none }
        let fuzzyNames = Set(candidates
            .filter { !NameKey.tokens($0.matchName).isDisjoint(with: tokens) }
            .map(\.resultName))
            .sorted()
        switch fuzzyNames.count {
        case 0: return .none
        case 1: return .resolved(fuzzyNames[0])
        default: return .ambiguous(Array(fuzzyNames.prefix(maxAmbiguousCandidates)))
        }
    }
}

private extension AskLifeLogResolution where Candidate == String {
    func map<T: Sendable & Equatable>(_ transform: (String) -> T) -> AskLifeLogResolution<T> {
        switch self {
        case .resolved(let name): return .resolved(transform(name))
        case .ambiguous(let names): return .ambiguous(names.map(transform))
        case .none: return .none
        }
    }
}
