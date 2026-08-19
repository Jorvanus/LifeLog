import Foundation
import Testing
@testable import LifeLog

/// Groups are the only vocabulary Insights counts by, so the rules that put a label
/// in one are worth pinning. The labels below are all real -- they come from an
/// imported journal that left 52 of them, and 77 days, permanently under "Other"
/// because the fallback only knew four words.
struct ActivityGroupingTests {
    @Test("Real imported labels land somewhere better than Other")
    func importedLabelsAreClassified() {
        let expected: [String: String] = [
            "CrossFit": "Fitness", "Gym": "Fitness", "Races": "Fitness", "Netball": "Fitness",
            "Rowing": "Fitness", "Swim": "Fitness", "Cycle": "Fitness",
            "Holiday": "Travel", "Flight": "Travel", "Cruise": "Travel", "Layover": "Travel",
            "Doctor": "Health", "Dentist": "Health", "Physio": "Health", "Hospital": "Health",
            "Massage": "Health", "Cryo": "Health", "Covid": "Health", "Donate Blood": "Health",
            "Meeting": "Work", "Meeting - conference": "Work", "Studying": "Work",
            "Visit. Friends": "Social", "Visiting mum": "Social", "Wedding": "Social",
            "Birthday Party": "Social", "Funeral": "Social", "DnD": "Social", "Trivia": "Social",
            "Fuel up": "Errands", "Carwash": "Errands", "Car service": "Errands",
            "Collect mail": "Errands", "Borrow Books": "Errands", "Groceries": "Errands",
            "Bowling": "Entertainment", "Mini golf": "Entertainment", "Cinema": "Entertainment",
            "Takeaway": "Food & Drink", "Snack": "Food & Drink",
            "Catch bus": "Commute",
            "Park with Nala": "Pets", "Vet": "Pets", "Dog walk": "Pets",
            "Toilet break": "Personal", "Time out": "Personal"
        ]
        for (label, group) in expected {
            #expect(ActivityCatalog.inferredCategory(for: label) == group,
                    "\"\(label)\" was grouped as \(ActivityCatalog.inferredCategory(for: label))")
        }
    }

    /// The more specific word has to win, or a dog's walk becomes exercise and a
    /// work trip becomes a holiday.
    @Test("A more specific word beats a more general one")
    func specificRulesWinOverGeneralOnes() {
        #expect(ActivityCatalog.inferredCategory(for: "Dog walk") == "Pets")
        #expect(ActivityCatalog.inferredCategory(for: "Work Trip") == "Work")
        #expect(ActivityCatalog.inferredCategory(for: "Training") == "Work")
    }

    /// One rule set, reached two ways. These were separate keyword tables that
    /// disagreed -- the same label grouped one way when adopted from history and
    /// another when read straight off a visit.
    @Test("Adoption and lookup agree on where a label belongs")
    func suggestionMatchesInference() {
        for label in ["CrossFit", "Holiday", "Fuel up", "Dentist", "Park with Nala", "Trivia"] {
            #expect(ActivityCatalog.suggestedCategory(for: label)
                    == ActivityCatalog.inferredCategory(for: label))
        }
    }

    /// Only a genuinely meaningless label should reach the fallback.
    @Test("Other is the last resort, not the common case")
    func otherIsRare() {
        #expect(ActivityCatalog.inferredCategory(for: "zzqqxx") == "Other")
        #expect(ActivityCatalog.inferredCategory(for: "") == "Other")
    }

    /// Every group the classifier can return has to be one a person can actually
    /// see and edit, or time lands in a group missing from the Groups screen.
    @Test("Every group the rules produce is a shipped group")
    func producedGroupsAreAllShipped() {
        let shipped = Set(ActivityCatalog.defaultCategories)
        let labels = ["CrossFit", "Holiday", "Doctor", "Meeting", "Visit. Friends", "Fuel up",
                      "Bowling", "Takeaway", "Catch bus", "Park with Nala", "Toilet break",
                      "Sleeping", "At home", "zzqqxx"]
        for label in labels {
            #expect(shipped.contains(ActivityCatalog.inferredCategory(for: label)),
                    "\"\(label)\" produced an unshipped group")
        }
    }

    @Test("Groups show one row per activity label")
    func groupPresentationCollapsesDuplicateDefinitions() {
        let activities = [
            ActivityDefinition(name: "At home", category: "Home", symbol: "house.fill"),
            ActivityDefinition(name: "At home", category: "Home", symbol: "house.fill"),
            ActivityDefinition(name: "Travelling", category: "Travel", symbol: "car.fill")
        ]

        let visible = ActivityCatalog.uniqueForPresentation(activities)
        #expect(visible.map(\.name) == ["At home", "Travelling"])
    }
}
