import SwiftData

enum ActivityCatalog {
    static let defaults: [(name: String, category: String, symbol: String)] = [
        ("At home", "Home", "house.fill"), ("Working", "Work", "briefcase.fill"),
        ("Eating", "Food & Drink", "fork.knife"), ("Shopping", "Shopping", "bag.fill"),
        ("Exercising", "Fitness", "figure.run"), ("Healthcare", "Healthcare", "cross.case.fill"),
        ("Studying", "Education", "book.fill"), ("Travelling", "Travel", "car.fill"),
        ("Socialising", "Social", "person.2.fill"), ("Visiting", "Other", "mappin.and.ellipse")
    ]

    @MainActor
    static func seed(_ context: ModelContext) {
        guard (try? context.fetch(FetchDescriptor<ActivityDefinition>()).isEmpty) == true else { return }
        for item in defaults {
            context.insert(ActivityDefinition(name: item.name, category: item.category, symbol: item.symbol))
        }
        try? context.save()
    }
}
