import Foundation
import SwiftData

struct ActivityDefinition: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var category: String
    var symbol: String
    var colorHex: String?

    init(id: UUID = UUID(), name: String, category: String = "Other", symbol: String = "circle.fill") {
        self.id = id
        self.name = TextSafety.clean(name, maximumLength: 80)
        self.category = TextSafety.clean(category, maximumLength: 40)
        self.symbol = TextSafety.clean(symbol, maximumLength: 60)
        self.colorHex = nil
    }
}

enum ActivityCatalog {
    private static let storageKey = "LifeLog.ActivityCatalog.v1"

    /// Where the catalogue lives. Swappable so tests can exercise group edits — which
    /// rewrite every activity's grouping — without touching the app's real defaults.
    /// Only ever reassigned by `withStorage`, and `UserDefaults` is itself thread-safe.
    nonisolated(unsafe) static var storage: UserDefaults = .standard

    static func withStorage(_ defaults: UserDefaults, _ body: () -> Void) {
        let previous = storage
        storage = defaults
        defer { storage = previous }
        body()
    }
    static let defaults: [(name: String, category: String, symbol: String)] = [
        ("At home", "Home", "house.fill"), ("Working", "Work", "briefcase.fill"),
        ("Coffee", "Food & Drink", "cup.and.saucer.fill"), ("Beers", "Food & Drink", "mug.fill"),
        ("Breakfast", "Food & Drink", "sunrise.fill"), ("Lunch", "Food & Drink", "fork.knife"),
        ("Dining out", "Food & Drink", "fork.knife"), ("Eating", "Food & Drink", "fork.knife"),
        ("Shopping", "Shopping", "bag.fill"),
        ("Concert", "Entertainment", "music.mic"), ("Football", "Entertainment", "sportscourt.fill"),
        ("Exercising", "Fitness", "figure.run"), ("Healthcare", "Healthcare", "cross.case.fill"),
        ("Studying", "Education", "book.fill"), ("Travelling", "Travel", "car.fill"),
        ("Socialising", "Social", "person.2.fill"), ("Visiting", "Other", "mappin.and.ellipse"),
        ("Watching a movie", "Entertainment", "film.fill")
    ] + generatedDefaults

    /// Activities the app produces for itself, from Apple Health, the iPhone's motion
    /// history, and its own journey detection. They were missing from the catalogue
    /// entirely, so a walk, a night's sleep or a commute arrived with the fallback grey
    /// dot, no colour of its own and no group — and the Sleep and Commute groups sat
    /// empty while the timeline was full of both.
    static let generatedDefaults: [(name: String, category: String, symbol: String)] = [
        ("Sleeping", "Sleep", "bed.double.fill"),
        ("Walking", "Fitness", "figure.walk"),
        ("Running", "Fitness", "figure.run"),
        ("Cycling", "Fitness", "bicycle"),
        ("Swimming", "Fitness", "figure.pool.swim"),
        ("Yoga", "Fitness", "figure.yoga"),
        ("Strength training", "Fitness", "dumbbell.fill"),
        ("Commuting", "Commute", "car.fill"),
        ("In transit", "Travel", "bus.fill"),
        ("Home time", "Home", "house.fill")
    ]

    private static let adoptedGeneratedKey = "LifeLog.ActivityCatalog.generatedAdopted.v1"

    /// Adds those to a catalogue written before they existed, once.
    ///
    /// Only ever adds what is absent, and only ever runs once — so an activity deleted
    /// deliberately after this stays deleted, rather than reappearing at every launch.
    static func adoptGeneratedActivities() {
        guard !storage.bool(forKey: adoptedGeneratedKey) else { return }
        var activities = load()
        let existing = Set(activities.map { $0.name.lowercased() })
        for entry in generatedDefaults where !existing.contains(entry.name.lowercased()) {
            activities.append(ActivityDefinition(name: entry.name, category: entry.category,
                                                 symbol: entry.symbol))
        }
        save(activities)
        storage.set(true, forKey: adoptedGeneratedKey)
    }

    /// Alphabetical, ignoring case and accents. A list of labels is scanned by name
    /// and nothing else, and storage order put each newly added entry wherever it
    /// happened to land — so the one just added was the hardest to find again.
    static func sorted(_ activities: [ActivityDefinition]) -> [ActivityDefinition] {
        activities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load() -> [ActivityDefinition] {
        guard let data = storage.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ActivityDefinition].self, from: data),
              !decoded.isEmpty else {
            return sorted(defaults.map {
                ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol)
            })
        }
        return sorted(decoded)
    }

    static func save(_ activities: [ActivityDefinition]) {
        // Sorted on the way in as well, so what is stored matches what is shown and
        // a list edited by an older build is tidied the first time it is saved.
        guard let data = try? JSONEncoder().encode(sorted(activities)) else { return }
        storage.set(data, forKey: storageKey)
    }

    static func category(for activity: String) -> String {
        let key = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key.lowercased() {
        case "at home": return "Home"
        case "working": return "Work"
        case "eating": return "Food & Drink"
        case "coffee", "beers", "breakfast", "lunch", "dining out": return "Food & Drink"
        case "concert", "football": return "Entertainment"
        case "shopping": return "Shopping"
        case "exercising", "walking", "running", "cycling": return "Fitness"
        case "healthcare": return "Healthcare"
        case "studying": return "Education"
        case "travelling", "traveling", "in transit": return "Travel"
        case "socialising", "socializing": return "Social"
        case "watching a movie": return "Entertainment"
        case "sleeping": return "Sleep"
        default: break
        }
        if let match = load().first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return match.category
        }
        let text = key.lowercased()
        if text.contains("sleep") { return "Sleep" }
        if text.contains("walk") || text.contains("run") || text.contains("cycl") || text.contains("exercise") {
            return "Fitness"
        }
        if text.contains("travel") || text.contains("transit") { return "Travel" }
        return "Other"
    }

    /// The groups LifeLog ships with. A starting point, not the whole list: the
    /// person can add their own, so read `categories` rather than this.
    static let defaultCategories = ["Home", "Work", "Commute", "Food & Drink", "Shopping",
                                    "Fitness", "Healthcare", "Education", "Travel",
                                    "Entertainment", "Social", "Sleep", "Other"]

    /// The group every activity falls back to. It can never be removed, because
    /// deleting a group has to leave its activities somewhere.
    static let fallbackCategory = "Other"

    private static let categoryStorageKey = "LifeLog.ActivityCategories.v1"

    /// Groups Insights counts by, including any the person added. Read through one
    /// accessor so the picker, the add-from-history flow and the grouping logic
    /// cannot drift apart.
    static var categories: [String] { loadCategories() }

    static func loadCategories() -> [String] {
        guard let stored = storage.array(forKey: categoryStorageKey) as? [String],
              !stored.isEmpty else { return defaultCategories }
        // "Other" is always available even if an older list somehow lacks it, and any
        // group still in use by an activity is kept, so a group can never disappear
        // while something is filed under it.
        var names = stored
        for used in load().map(\.category) where !names.contains(used) { names.append(used) }
        if !names.contains(fallbackCategory) { names.append(fallbackCategory) }
        return names
    }

    static func saveCategories(_ names: [String]) {
        var cleaned: [String] = []
        for name in names {
            let clean = TextSafety.clean(name, maximumLength: 40)
            guard !clean.isEmpty,
                  !cleaned.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { continue }
            cleaned.append(clean)
        }
        if !cleaned.contains(fallbackCategory) { cleaned.append(fallbackCategory) }
        storage.set(cleaned, forKey: categoryStorageKey)
    }

    /// Renames a group and carries its activities with it. Visits are untouched:
    /// a visit records what the person did, and the group is derived from the
    /// activity, so moving the activities is what re-counts the history.
    @discardableResult
    static func renameCategory(from previous: String, to updated: String) -> Int {
        let clean = TextSafety.clean(updated, maximumLength: 40)
        guard !clean.isEmpty, clean.caseInsensitiveCompare(previous) != .orderedSame else { return 0 }
        var activities = load()
        var moved = 0
        for index in activities.indices
        where activities[index].category.caseInsensitiveCompare(previous) == .orderedSame {
            activities[index].category = clean
            moved += 1
        }
        save(activities)
        saveCategories(loadCategories().map {
            $0.caseInsensitiveCompare(previous) == .orderedSame ? clean : $0
        })
        return moved
    }

    /// Removes a group. Its activities fall back to "Other" rather than losing their
    /// grouping entirely, which would drop them out of Insights until noticed.
    @discardableResult
    static func deleteCategory(_ name: String) -> Int {
        guard name.caseInsensitiveCompare(fallbackCategory) != .orderedSame else { return 0 }
        var activities = load()
        var orphaned = 0
        for index in activities.indices
        where activities[index].category.caseInsensitiveCompare(name) == .orderedSame {
            activities[index].category = fallbackCategory
            orphaned += 1
        }
        save(activities)
        saveCategories(loadCategories().filter { $0.caseInsensitiveCompare(name) != .orderedSame })
        return orphaned
    }

    static func addCategory(_ name: String) -> Bool {
        let clean = TextSafety.clean(name, maximumLength: 40)
        let existing = loadCategories()
        guard !clean.isEmpty,
              !existing.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return false }
        saveCategories(existing + [clean])
        return true
    }

    static func activities(inCategory name: String) -> [ActivityDefinition] {
        sorted(load().filter { $0.category.caseInsensitiveCompare(name) == .orderedSame })
    }

    /// Best guess at where a label belongs, used to pre-fill the category when
    /// adopting an activity from history. Only a starting point — the person can
    /// change it, and a wrong guess only affects Insights grouping.
    static func suggestedCategory(for activity: String) -> String {
        let key = activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rules: [(String, [String])] = [
            ("Sleep", ["sleep", "nap"]),
            ("Home", ["home", "chores", "housework"]),
            ("Work", ["work", "office", "meeting", "conference", "shift", "roster"]),
            ("Food & Drink", ["eat", "food", "coffee", "beer", "breakfast", "lunch",
                              "dinner", "dining", "brunch", "cafe", "pub", "drinks"]),
            ("Shopping", ["shop", "groceries", "grocery", "market", "errand"]),
            ("Fitness", ["gym", "crossfit", "exercis", "walk", "run", "cycl", "swim",
                         "train", "sport", "yoga"]),
            ("Healthcare", ["doctor", "medical", "dentist", "hospital", "physio",
                            "blood", "health", "appointment"]),
            ("Education", ["study", "school", "class", "course", "library", "uni"]),
            ("Commute", ["commut"]),
            ("Travel", ["travel", "transit", "flight", "fly", "drive", "driving",
                        "holiday", "trip", "airport", "fuel"]),
            ("Entertainment", ["movie", "cinema", "concert", "football", "game",
                               "show", "gig", "theatre", "theater"]),
            ("Social", ["friend", "family", "social", "visit", "party", "catch"])
        ]
        for (category, keywords) in rules where keywords.contains(where: { key.contains($0) }) {
            return category
        }
        return "Other"
    }

    /// Resolves a label the inference rules produced into the wording the person
    /// actually uses. Only unambiguous correspondences are taken: an exact match, a
    /// shared stem ("Working" against "Work"), or a category with exactly one
    /// activity in it. Anything less certain keeps the original, because guessing by
    /// popularity would pick a label that means something different.
    static func preferredLabel(for canonical: String, in catalogue: [ActivityDefinition]? = nil) -> String {
        let activities = catalogue ?? load()
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return canonical }
        if let exact = activities.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact.name
        }
        let stem = stemmed(trimmed)
        let stemMatches = activities.filter { stemmed($0.name) == stem }
        if stemMatches.count == 1 { return stemMatches[0].name }

        let category = category(for: trimmed)
        guard category != "Other" else { return canonical }
        let inCategory = activities.filter { $0.category == category }
        return inCategory.count == 1 ? inCategory[0].name : canonical
    }

    /// Folds the common English endings that separate a noun from its verb form, so
    /// "Working" and "Work" collapse together without a stemming library.
    private static func stemmed(_ value: String) -> String {
        var key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["ing", "ed", "s"] where key.count > suffix.count + 2 && key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
            break
        }
        if key.hasSuffix("e") && key.count > 3 { key.removeLast() }
        return key
    }

    /// Carries an activity rename across the timeline. Visits store the activity as
    /// text, so without this a rename leaves every existing visit holding wording the
    /// catalogue no longer knows, which Insights then counts as "Other". Matching is
    /// case-insensitive because the label may have been typed by hand more than once.
    @MainActor
    @discardableResult
    static func renameActivity(from previous: String, to updated: String,
                               context: ModelContext) throws -> Int {
        let from = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = TextSafety.clean(updated, maximumLength: 80)
        guard !from.isEmpty, !to.isEmpty,
              from.caseInsensitiveCompare(to) != .orderedSame else { return 0 }
        let visits = try context.fetch(FetchDescriptor<Visit>())
        var changed = 0
        for visit in visits {
            var touched = false
            if visit.userActivity?.caseInsensitiveCompare(from) == .orderedSame {
                visit.userActivity = to
                touched = true
            }
            // The inferred value matters too: it is what shows when no explicit
            // activity was chosen, and what Insights groups in that case.
            if visit.inferredActivity.caseInsensitiveCompare(from) == .orderedSame {
                visit.inferredActivity = to
                touched = true
            }
            if touched { changed += 1 }
        }
        if changed > 0 { try context.save() }
        return changed
    }

    static func seed() {
        if storage.data(forKey: storageKey) == nil { save(load()) }
        adoptGeneratedActivities()
    }
}
