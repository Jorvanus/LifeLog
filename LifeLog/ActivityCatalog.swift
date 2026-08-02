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
        ("Socialising", "Social", "person.2.fill"), ("Visiting", "Other", "mappin.and.ellipse")
    ]

    static func load() -> [ActivityDefinition] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([ActivityDefinition].self, from: data),
              !values.isEmpty else {
            return defaults.map { ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol) }
        }
        return values
    }

    static func save(_ activities: [ActivityDefinition]) {
        guard let data = try? JSONEncoder().encode(activities) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func seed() {
        guard UserDefaults.standard.data(forKey: storageKey) == nil else { return }
        save(load())
    }
}
