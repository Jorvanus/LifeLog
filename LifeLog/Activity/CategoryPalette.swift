import SwiftUI

/// The one place a group's colour is decided.
///
/// There were two: a `switch` returning SwiftUI colours and a separate dictionary of
/// hex strings for exports and accessibility. They had already drifted — Entertainment
/// was purple in the chart and grey everywhere else — and Work and Entertainment were
/// both plain purple, indistinguishable in a donut where they sit side by side.
///
/// The groups a day is mostly made of get widely separated hues, so the chart can be
/// read at a glance. The rest are deliberately variations on their neighbours: they
/// appear in small slices, and spending scarce distinct hues on them would blur the
/// ones that matter.
enum CategoryPalette {
    /// Hue-separated, because these are most of every day.
    static let prominent: [String: String] = [
        "Home": "34C759",          // green
        "Work": "AF52DE",          // purple
        "Sleep": "3E5A76",         // slate — dark, so nights read as quiet
        "Commute": "00C7BE",       // teal
        "Food & Drink": "FF9500",  // orange
        "Fitness": "FF2D55"        // pink
    ]

    /// Variations on the above. Each is close to one prominent colour but never to
    /// another variation, so two small slices are still told apart.
    static let secondary: [String: String] = [
        "Travel": "007AFF",        // blue, away from Commute's teal
        "Errands": "5856D6",       // indigo, between Work and Travel
        "Social": "30B0C7",        // cyan, a lighter cousin of Commute
        "Health": "E5342A",        // true red, deeper than Fitness pink
        "Entertainment": "C87BE8", // violet, a lighter Work
        "Pets": "A2845E",          // brown, unlike anything else here
        "Personal": "B07AA1",      // plum, quieter than Work's purple
        "Uncategorised": "FF9F0A", // amber: a state, not a category
        "Other": "8E8E93",         // grey, and the fallback
        // Superseded group names. Kept so history still filed under one draws its own
        // colour instead of dropping to grey -- the exact failure that made three
        // life areas indistinguishable before groups became the only vocabulary.
        "Shopping": "5856D6",
        "Healthcare": "E5342A",
        "Education": "FFCC00"
    ]

    static let fallbackHex = "8E8E93"

    static var all: [String: String] { prominent.merging(secondary) { current, _ in current } }

    /// Matched without case or padding, so "food & drink" and "Food & Drink" agree —
    /// the two old lookups did not.
    static func hex(for category: String) -> String {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all[key] { return exact }
        let lowered = key.lowercased()
        for (name, hex) in all where name.lowercased() == lowered { return hex }
        return fallbackHex
    }
}
