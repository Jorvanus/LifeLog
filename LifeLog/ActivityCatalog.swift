import Foundation

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
    ]

    static func load() -> [ActivityDefinition] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ActivityDefinition].self, from: data),
              !decoded.isEmpty else {
            return defaults.map { ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol) }
        }
        return decoded
    }

    static func save(_ activities: [ActivityDefinition]) {
        guard let data = try? JSONEncoder().encode(activities) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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

    /// Categories LifeLog groups Insights by. Kept here so the picker, the add-from-
    /// history flow and the grouping logic cannot drift apart.
    static let categories = ["Home", "Work", "Food & Drink", "Shopping", "Fitness",
                             "Healthcare", "Education", "Travel", "Entertainment",
                             "Social", "Sleep", "Other"]

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
            ("Travel", ["travel", "transit", "flight", "fly", "drive", "driving",
                        "holiday", "trip", "airport", "fuel", "commut"]),
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

    static func seed() {
        guard UserDefaults.standard.data(forKey: storageKey) == nil else { return }
        save(load())
    }
}
