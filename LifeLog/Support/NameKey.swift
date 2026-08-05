import Foundation

/// One answer to "are these two names the same name?".
///
/// Place and activity names are compared all over LifeLog — learning a Saved
/// Place, rejoining a split stay, grouping a review queue, totalling an activity
/// — and until now each site rolled its own comparison. They disagreed. Three
/// folded away accents and one did not, so `Café` and `Cafe` were one place to
/// the resolver and two separate activities in Insights. Two trimmed surrounding
/// whitespace and two did not, so a name pasted with a trailing space matched in
/// one screen and not the next.
///
/// This is not a substitute for identity. A name is the *fallback* — Apple Maps'
/// own identifier is the reliable answer where both sides have one, and this is
/// what is left when they do not.
enum NameKey {
    /// Case- and accent-insensitive, whitespace-trimmed, length-bounded.
    /// Two names with the same key are treated as the same name everywhere.
    static func matching(_ value: String) -> String {
        TextSafety.clean(value, maximumLength: 120)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    /// Significant words of a name, for the looser "do these two names overlap?"
    /// test used when deciding whether nearby records describe one place. Words of
    /// one or two letters are dropped: matching on "at", "of" or "st" would join
    /// unrelated places.
    static func tokens(_ value: String) -> Set<String> {
        Set(matching(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 })
    }

    /// Whether two names refer to the same thing.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        matching(lhs) == matching(rhs)
    }
}
