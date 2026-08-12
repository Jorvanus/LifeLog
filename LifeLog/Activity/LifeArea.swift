import Foundation

/// A small, stable vocabulary for higher-level Insights only. This is not a place
/// taxonomy and it is not the user's editable activity list.
enum LifeArea: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case home = "Home"
    case work = "Work"
    case healthFitness = "Health & Fitness"
    case social = "Social"
    case foodDrink = "Food & Drink"
    case errands = "Errands"
    case travel = "Travel"
    case sleepRest = "Sleep & Rest"
    case other = "Other"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .healthFitness: "figure.run"
        case .social: "person.2.fill"
        case .foodDrink: "fork.knife"
        case .errands: "cart.fill"
        case .travel: "car.fill"
        case .sleepRest: "bed.double.fill"
        case .other: "ellipsis.circle.fill"
        }
    }

    /// The compatibility bridge from the existing editable activity category.
    /// Activity definitions can override this with their own life-area choice.
    static func `default`(for activity: String, category: String) -> LifeArea {
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch category {
        case "home": return .home
        case "work": return .work
        case "fitness", "healthcare": return .healthFitness
        case "social", "entertainment": return .social
        case "food & drink": return .foodDrink
        case "shopping", "errands": return .errands
        case "travel", "commute": return .travel
        case "sleep", "sleep & rest": return .sleepRest
        default:
            let text = activity.lowercased()
            if text.contains("sleep") || text.contains("nap") { return .sleepRest }
            if text.contains("travel") || text.contains("transit") || text.contains("commut") { return .travel }
            return .other
        }
    }

    static func totals(in segments: [InsightSegment]) -> [LifeArea: Double] {
        // Catalog names are user-editable, so build this map defensively instead
        // of assuming case-insensitive uniqueness in imported or older stores.
        var definitions: [String: ActivityDefinition] = [:]
        for definition in ActivityCatalog.load() {
            definitions[definition.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = definition
        }
        var totals: [LifeArea: Double] = [:]
        for segment in segments where !segment.isUnlogged {
            let area: LifeArea
            if let visit = segment.visit,
               let definition = definitions[visit.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
               let stored = LifeArea(rawValue: definition.lifeArea) {
                area = stored
            } else {
                area = LifeArea.default(for: segment.activity, category: segment.category)
            }
            totals[area, default: 0] += segment.hours
        }
        return totals
    }
}
