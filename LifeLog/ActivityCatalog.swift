import Foundation

struct ActivityDefinition: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var category: String
    var symbol: String

    init(id: UUID = UUID(), name: String, category: String = "Other", symbol: String = "circle.fill") {
        self.id = id
        self.name = TextSafety.clean(name, maximumLength: 80)
        self.category = TextSafety.clean(category, maximumLength: 40)
        self.symbol = TextSafety.clean(symbol, maximumLength: 60)
    }
}

enum ActivityCatalog {
    private static let storageKey = "LifeLog.ActivityCatalog.v1"
    static let defaults: [(name: String, category: String, symbol: String)] = [
        ("At home", "Home", "house.fill"), ("Working", "Work", "briefcase.fill"),
        ("Eating", "Food & Drink", "fork.knife"), ("Shopping", "Shopping", "bag.fill"),
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

    static func seed() {
        guard UserDefaults.standard.data(forKey: storageKey) == nil else { return }
        save(load())
    }
}
