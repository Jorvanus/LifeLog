import Foundation
import Testing
@testable import LifeLog

/// The activity catalogue: how inference chooses wording, how a shipped or
/// adopted label resolves to its group, and how the person's own edits to
/// groups and categories carry through.
@MainActor
struct CatalogueAndGroupingTests {
    @Test("Inference speaks the vocabulary in the catalogue")
    func inferenceUsesCatalogueWording() {
        // A catalogue that says "Work", the way a real timeline usually does.
        let catalogue = [
            ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Seeing Doctor", category: "Healthcare", symbol: "cross.case.fill"),
            ActivityDefinition(name: "Eating", category: "Food & Drink", symbol: "fork.knife"),
            ActivityDefinition(name: "Beers", category: "Food & Drink", symbol: "mug.fill")
        ]
        // Shared stem: "Working" resolves to "Work".
        #expect(ActivityCatalog.preferredLabel(for: "Working", in: catalogue) == "Work")
        // Sole activity in its category resolves even without a shared stem.
        #expect(ActivityCatalog.preferredLabel(for: "Healthcare", in: catalogue) == "Seeing Doctor")
        // Two candidates in one category is ambiguous, so the original wording stands
        // rather than guessing between "Eating" and "Beers".
        #expect(ActivityCatalog.preferredLabel(for: "Eating", in: catalogue) == "Eating")
        // Nothing to map to leaves the label untouched.
        #expect(ActivityCatalog.preferredLabel(for: "Studying", in: catalogue) == "Studying")
    }

    /// The case that shipped broken: each label alone had a test, both together did
    /// not. An exact match is taken before the stem rule is reached, so a catalogue
    /// still holding the seeded "Working" answered with itself and the adopted "Work"
    /// was unreachable — the shadowing the stem rule exists to prevent.
    @Test("An adopted Work is not shadowed by a seeded Working")
    func adoptedWorkIsNotShadowedBySeededWorking() {
        let both = [
            ActivityDefinition(name: "Working", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
        ]
        // Holding both is the state the migration exists to clear: whichever way this
        // resolves, one of the two entries is wording nothing can reach.
        #expect(ActivityCatalog.preferredLabel(for: "Working", in: both) == "Working")

        // The catalogue once the seeded entry has been retired.
        let migrated = [ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")]
        #expect(ActivityCatalog.preferredLabel(for: "Working", in: migrated) == "Work",
                "inference produces the canonical Working and must reach the person's wording")
    }

    @Test("The seeded catalogue no longer ships the label that did the shadowing")
    func seededCatalogueUsesWork() {
        let names = ActivityCatalog.defaults.map(\.name)
        #expect(names.contains("Work"))
        #expect(!names.contains("Working"))
    }

    /// The test that makes the drift impossible rather than merely fixed. A shipped
    /// activity used to keep its group after deletion only if someone had typed it into
    /// a hand-written switch; eight never were, so deleting `Work` moved 2,732 visits
    /// to "Other" while deleting `Eating` did nothing. Nothing checked the two lists
    /// agreed, so renaming a shipped activity silently stranded its group.
    @Test("Every shipped activity keeps its group after it is deleted")
    func deletingAShippedActivityKeepsItsGroup() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        ActivityCatalog.withStorage(defaults) {
            // A catalogue with none of the shipped entries in it: the state that
            // deleting one puts that name into.
            ActivityCatalog.save([ActivityDefinition(name: "Zzz placeholder", category: "Other",
                                                     symbol: "circle")])
            var stranded: [String] = []
            for entry in ActivityCatalog.defaults
            where ActivityCatalog.category(for: entry.name) != entry.category {
                stranded.append("\(entry.name) → \(ActivityCatalog.category(for: entry.name)), expected \(entry.category)")
            }
            #expect(stranded.isEmpty, "lost their group: \(stranded.joined(separator: "; "))")

            // The wording an older build shipped, and what the inference rules call the
            // concept, both still resolve — an archive is full of "Working".
            #expect(ActivityCatalog.category(for: "Working") == "Work")
            #expect(ActivityCatalog.category(for: "Traveling") == "Travel")
        }
    }

    @Test("A group chosen in Settings outranks the one LifeLog ships")
    func catalogueCategoryWinsOverTheShippedOne() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        ActivityCatalog.withStorage(defaults) {
            // Re-grouping a shipped activity used to do nothing: the hand-written switch
            // answered first and never consulted the catalogue at all.
            ActivityCatalog.save([ActivityDefinition(name: "Eating", category: "Social",
                                                     symbol: "fork.knife")])
            #expect(ActivityCatalog.category(for: "Eating") == "Social")
        }
    }

    @Test("The activities list reads alphabetically whatever order it was built in")
    func activitiesSortByName() {
        let unsorted = [
            ActivityDefinition(name: "work", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Éating", category: "Food & Drink", symbol: "fork.knife"),
            ActivityDefinition(name: "Beers", category: "Food & Drink", symbol: "mug.fill"),
            ActivityDefinition(name: "At home", category: "Home", symbol: "house.fill")
        ]

        let names = ActivityCatalog.sorted(unsorted).map(\.name)

        // Case and accents must not decide the order: an accented label belongs with
        // its unaccented neighbours, and "work" is not filed after every capital.
        #expect(names == ["At home", "Beers", "Éating", "work"])
    }

    /// Groups are only a string on each activity, so the risk in editing one is that
    /// history quietly stops being counted. These assert it never does.
    @Test("Renaming a group carries its activities; deleting one leaves them counted")
    func groupEditsKeepActivitiesGrouped() {
        let suite = "LifeLogGroupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ActivityCatalog.withStorage(defaults) {
            ActivityCatalog.save([
                ActivityDefinition(name: "CrossFit", category: "Fitness", symbol: "figure.run"),
                ActivityDefinition(name: "Swimming", category: "Fitness", symbol: "figure.pool.swim"),
                ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
            ])

            #expect(ActivityCatalog.addCategory("Fitness") == false, "A duplicate group would split the same time in two")
            #expect(ActivityCatalog.addCategory("Volunteering"))
            #expect(ActivityCatalog.categories.contains("Volunteering"))

            // Renaming moves the activities, so their visits keep being counted under
            // the new name rather than falling out of the group.
            #expect(ActivityCatalog.renameCategory(from: "Fitness", to: "Training") == 2)
            #expect(ActivityCatalog.activities(inCategory: "Training").map(\.name) == ["CrossFit", "Swimming"])
            #expect(ActivityCatalog.categories.contains("Training"))
            #expect(ActivityCatalog.categories.contains("Fitness") == false)

            // Deleting drops them to the fallback rather than nowhere.
            #expect(ActivityCatalog.deleteCategory("Training") == 2)
            #expect(ActivityCatalog.categories.contains("Training") == false)
            #expect(ActivityCatalog.activities(inCategory: ActivityCatalog.fallbackCategory)
                .map(\.name) == ["CrossFit", "Swimming"])
            #expect(ActivityCatalog.category(for: "CrossFit") == ActivityCatalog.fallbackCategory)

            // The fallback itself must survive, or a later deletion has nowhere to go.
            #expect(ActivityCatalog.deleteCategory(ActivityCatalog.fallbackCategory) == 0)
            #expect(ActivityCatalog.categories.contains(ActivityCatalog.fallbackCategory))
        }
    }

    @Test("Adopted activities are grouped, not dumped into Other")
    func suggestedCategoriesCoverRealVocabulary() {
        #expect(ActivityCatalog.suggestedCategory(for: "Work") == "Work")
        #expect(ActivityCatalog.suggestedCategory(for: "Work Trip") == "Work")
        #expect(ActivityCatalog.suggestedCategory(for: "Groceries") == "Shopping")
        #expect(ActivityCatalog.suggestedCategory(for: "CrossFit") == "Fitness")
        #expect(ActivityCatalog.suggestedCategory(for: "Seeing Doctor") == "Healthcare")
        #expect(ActivityCatalog.suggestedCategory(for: "Donate Blood") == "Healthcare")
        #expect(ActivityCatalog.suggestedCategory(for: "Sleeping") == "Sleep")
        #expect(ActivityCatalog.suggestedCategory(for: "Flight") == "Travel")
        #expect(ActivityCatalog.suggestedCategory(for: "Holiday") == "Travel")
        #expect(ActivityCatalog.suggestedCategory(for: "Visit. Friends") == "Social")
        #expect(ActivityCatalog.suggestedCategory(for: "Beers") == "Food & Drink")
        // Every suggestion must be a category the picker offers, or it cannot be
        // corrected afterwards.
        for label in ["Work", "Groceries", "CrossFit", "Flight", "Nonsense xyzzy"] {
            #expect(ActivityCatalog.categories.contains(ActivityCatalog.suggestedCategory(for: label)))
        }
    }
}
