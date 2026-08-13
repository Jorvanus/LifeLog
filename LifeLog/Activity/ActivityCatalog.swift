import Foundation
import SwiftData

struct ActivityDefinition: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var category: String
    var symbol: String
    var colorHex: String?
    /// Stored per activity so a user can change Insights grouping without changing
    /// the existing editable activity category or any place data.
    var lifeArea: String
    /// Historical display labels which still point to this definition. This is a
    /// compatibility alias, not a normalised search key: two separately-created
    /// labels are never combined merely because their spelling looks alike.
    var legacyNames: [String]

    init(id: UUID = UUID(), name: String, category: String = "Other", symbol: String = "circle.fill",
         lifeArea: String? = nil) {
        self.id = id
        self.name = TextSafety.clean(name, maximumLength: 80)
        self.category = TextSafety.clean(category, maximumLength: 40)
        self.symbol = TextSafety.clean(symbol, maximumLength: 60)
        self.colorHex = nil
        self.lifeArea = lifeArea.flatMap { LifeArea(rawValue: $0)?.rawValue }
            ?? LifeArea.default(for: self.name, category: self.category).rawValue
        self.legacyNames = []
    }

    private enum CodingKeys: String, CodingKey { case id, name, category, symbol, colorHex, lifeArea, legacyNames }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let name = try values.decode(String.self, forKey: .name)
        let category = try values.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        let symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "circle.fill"
        let storedArea = try values.decodeIfPresent(String.self, forKey: .lifeArea)
        self.init(id: id, name: name, category: category, symbol: symbol, lifeArea: storedArea)
        colorHex = try values.decodeIfPresent(String.self, forKey: .colorHex)
        legacyNames = try values.decodeIfPresent([String].self, forKey: .legacyNames) ?? []
    }

    func matchesSnapshot(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.caseInsensitiveCompare(trimmed) == .orderedSame ||
            legacyNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

/// Staged bridge from the historic UserDefaults catalogue to the versioned store.
///
/// This deliberately uses exact display labels for legacy rows. Normalising names
/// here would make separately-created activities such as `Cafe` and `Café` share a
/// definition, which is irreversible data loss. New mutations should pass an ID
/// directly; the name lookup exists only for old snapshots waiting for a batch.
@MainActor
enum ActivityIdentityMigration {
    static let batchSize = 500

    struct Progress: Sendable, Equatable {
        let adoptedDefinitions: Int
        let linkedVisits: Int
        let linkedPlaces: Int
        let hasMore: Bool
    }

    /// Imports each legacy definition by its pre-existing UUID. IDs, not names, are
    /// the deduplication key: two similar labels remain two activities by design.
    static func adoptLegacyDefinitions(context: ModelContext,
                                       definitions: [ActivityDefinition] = ActivityCatalog.load()) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let existingIDs = Set(existing.map(\.stableID))
        var adopted = 0
        for definition in definitions where !existingIDs.contains(definition.id) {
            context.insert(ActivityDefinitionRecord(
                stableID: definition.id, name: definition.name, category: definition.category,
                symbol: definition.symbol, colorHex: definition.colorHex,
                lifeArea: definition.lifeArea
            ))
            adopted += 1
        }
        if adopted > 0 { try context.save() }
        return adopted
    }

    /// Links one bounded page of old rows. A completed label must exactly equal one
    /// persisted definition; ambiguous or imported labels remain snapshots until the
    /// owner explicitly adopts/categorises them.
    static func backfillNextBatch(context: ModelContext, limit: Int = batchSize) throws -> Progress {
        let adopted = try adoptLegacyDefinitions(context: context)
        let definitions = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let exactIDs = Dictionary(grouping: definitions.filter(\.isActive), by: \.name)
            .compactMapValues { $0.count == 1 ? $0[0].stableID : nil }

        var visitDescriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.activityDefinitionID == nil },
                                                      sortBy: [SortDescriptor(\.arrival)])
        visitDescriptor.fetchLimit = limit
        let visits = try context.fetch(visitDescriptor)
        var linkedVisits = 0
        for visit in visits {
            if let id = exactIDs[visit.activity] {
                visit.activityDefinitionID = id
                linkedVisits += 1
            }
        }

        var placeDescriptor = FetchDescriptor<SavedPlace>(predicate: #Predicate { $0.activityDefinitionID == nil },
                                                           sortBy: [SortDescriptor(\.name)])
        placeDescriptor.fetchLimit = limit
        let places = try context.fetch(placeDescriptor)
        var linkedPlaces = 0
        for place in places {
            if let id = exactIDs[place.defaultActivity] {
                place.activityDefinitionID = id
                linkedPlaces += 1
            }
        }
        if linkedVisits > 0 || linkedPlaces > 0 { try context.save() }
        return Progress(adoptedDefinitions: adopted, linkedVisits: linkedVisits,
                        linkedPlaces: linkedPlaces,
                        hasMore: visits.count == limit || places.count == limit)
    }

    /// A rename changes one definition. Visit and place snapshots stay untouched so
    /// old imports/export formats remain intelligible; migrated rows continue to
    /// point at the same ID and therefore require no archive rewrite.
    static func rename(id: UUID, to name: String, context: ModelContext) throws {
        let descriptor = FetchDescriptor<ActivityDefinitionRecord>(predicate: #Predicate { $0.stableID == id })
        guard let record = try context.fetch(descriptor).first else { return }
        let cleaned = TextSafety.clean(name, maximumLength: 80)
        guard !cleaned.isEmpty else { return }
        record.name = cleaned
        record.modifiedAt = .now
        try context.save()
    }

    /// Mirrors a catalogue edit into the durable record. The UserDefaults value is
    /// retained during the staged rollout for older backups and views not yet moved
    /// to IDs; the UUID is the only identity used when deciding which row to edit.
    static func upsert(_ definition: ActivityDefinition, context: ModelContext) throws {
        let descriptor = FetchDescriptor<ActivityDefinitionRecord>(predicate: #Predicate { $0.stableID == definition.id })
        if let record = try context.fetch(descriptor).first {
            record.name = definition.name
            record.category = definition.category
            record.symbol = definition.symbol
            record.colorHex = definition.colorHex
            record.lifeArea = definition.lifeArea
            record.isActive = true
            record.modifiedAt = .now
        } else {
            context.insert(ActivityDefinitionRecord(stableID: definition.id, name: definition.name,
                                                    category: definition.category, symbol: definition.symbol,
                                                    colorHex: definition.colorHex, lifeArea: definition.lifeArea))
        }
        try context.save()
    }

    static func deactivate(id: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<ActivityDefinitionRecord>(predicate: #Predicate { $0.stableID == id })
        guard let record = try context.fetch(descriptor).first else { return }
        record.isActive = false
        record.modifiedAt = .now
        try context.save()
    }
}

enum ActivityCatalog {
    private static let storageKey = "LifeLog.ActivityCatalog.v1"

    /// Where the catalogue lives. Swappable so tests can exercise group edits — which
    /// rewrite every activity's grouping — without touching the app's real defaults.
    /// Only ever reassigned by `withStorage`, and `UserDefaults` is itself thread-safe.
    nonisolated(unsafe) static var storage: UserDefaults = .standard

    /// `rethrows`, so a body that can fail — a catalogue migration that touches the
    /// store, say — can be scoped to test storage without swallowing its error. The
    /// `defer` restores the real storage whether the body returns or throws.
    static func withStorage(_ defaults: UserDefaults, _ body: () throws -> Void) rethrows {
        let previous = storage
        storage = defaults
        defer { storage = previous }
        try body()
    }
    static let defaults: [(name: String, category: String, symbol: String)] = [
        // "Work", not "Working": the inference rules produce the canonical "Working",
        // and `preferredLabel` takes an exact catalogue match before it reaches the
        // stem rule. A seeded entry named "Working" therefore matched itself and
        // shadowed an adopted "Work" forever — the exact case the stem rule exists for.
        ("At home", "Home", "house.fill"), ("Work", "Work", "briefcase.fill"),
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
        // An iPhone schedule estimates this without measuring sleep. Keep it out of
        // the Sleep category so Insights never treats time in bed as hours asleep.
        ("In bed", "Other", "bed.double.fill"),
        ("Walking", "Fitness", "figure.walk"),
        ("Running", "Fitness", "figure.run"),
        ("Cycling", "Fitness", "bicycle"),
        ("Swimming", "Fitness", "figure.pool.swim"),
        ("Yoga", "Fitness", "figure.yoga"),
        ("Strength training", "Fitness", "dumbbell.fill"),
        ("Commuting", "Commute", "car.fill"),
        ("In transit", "Travel", "bus.fill"),
        ("Dog walk", "Fitness", "pawprint.fill")
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

    /// The group an activity counts towards in Insights.
    ///
    /// Asked in three passes, most authoritative first.
    ///
    /// This used to open with a hand-written switch of two dozen names, ahead of the
    /// catalogue. It held the same facts as `defaults` in a second copy that nothing
    /// kept in step, so the two drifted: eight shipped activities were missing from it,
    /// and renaming the seeded `Working` to `Work` in 1.23.2 left it matching a name the
    /// app no longer ships while the live one was absent. Deleting `Eating` was harmless
    /// and deleting `Work` sent 2,732 visits to "Other", for no reason visible from the
    /// screen — which of the two had been typed into the switch was the whole difference.
    ///
    /// Being first was the other half of the fault: a name in the switch took its group
    /// from there whatever the catalogue said, so re-grouping `Eating` in Settings did
    /// nothing at all.
    static func category(for activity: String) -> String {
        let key = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        // The person's own list first. It is the one they edit, so a group they chose
        // has to outrank anything LifeLog assumes about the name.
        if let match = load().first(where: { $0.matchesSnapshot(key) }) {
            return match.category
        }
        // Then what LifeLog ships, read from `defaults` rather than restated. Reached
        // when the entry has been deleted, or when history holds a label the catalogue
        // never had — a name the app ships still means what it always meant.
        if let shipped = shippedCategory(for: key) { return shipped }
        let text = key.lowercased()
        if text.contains("sleep") { return "Sleep" }
        if text.contains("walk") || text.contains("run") || text.contains("cycl") || text.contains("exercise") {
            return "Fitness"
        }
        if text.contains("travel") || text.contains("transit") { return "Travel" }
        return "Other"
    }

    /// Resolves a visit label to the derived life area. A stored definition wins;
    /// imported/deleted labels use the same category/name fallback as Insights.
    static func lifeArea(for activity: String, category: String? = nil) -> LifeArea {
        let key = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        if let definition = load().first(where: { $0.matchesSnapshot(key) }),
           let area = LifeArea(rawValue: definition.lifeArea) {
            return area
        }
        return LifeArea.default(for: key, category: category ?? self.category(for: key))
    }

    /// The group a name LifeLog ships with belongs to, whether or not the catalogue
    /// still holds it. Derived from `defaults`, so adding or renaming a shipped
    /// activity cannot leave a stale second copy behind.
    private static func shippedCategory(for name: String) -> String? {
        let key = name.lowercased()
        if let entry = defaults.first(where: { $0.name.lowercased() == key }) { return entry.category }
        guard let shipped = alternativeSpellings[key] else { return nil }
        return defaults.first { $0.name.lowercased() == shipped.lowercased() }?.category
    }

    /// Other spellings of a shipped name, mapped to the shipped one rather than to a
    /// group — so these stay derived too and cannot disagree with `defaults`.
    ///
    /// `working` is here because it is what the inference rules call the concept
    /// (`InferenceEngine.canonicalActivity`), and because it was the shipped label
    /// before 1.23.2, so a long archive is full of it.
    private static let alternativeSpellings = [
        "traveling": "Travelling",
        "socializing": "Socialising",
        "working": "Work"
    ]

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

    /// UI-triggered renames use the isolated store context. The synchronous form
    /// above remains for one-time startup migrations before the interface exists.
    static func renameActivity(from previous: String, to updated: String,
                               container: ModelContainer) async throws -> Int {
        let from = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = TextSafety.clean(updated, maximumLength: 80)
        guard !from.isEmpty, !to.isEmpty,
              from.caseInsensitiveCompare(to) != .orderedSame else { return 0 }
        return try await ActivityRenameActor(modelContainer: container).renameActivity(from: from, to: to)
    }

    static func seed() {
        if storage.data(forKey: storageKey) == nil { save(load()) }
        adoptGeneratedActivities()
    }

    /// Adds a label the archive already uses to the catalogue, so it can be renamed,
    /// grouped and given an icon — and so Insights stops counting it under "Other".
    ///
    /// One implementation for what is now three ways in: the bulk "Add from your
    /// history" sheet, the swipe on the Activities tab, and the button on an activity's
    /// own page. The same label must not come out looking different depending on which
    /// was used. Returns whether anything was added, so the caller knows whether to
    /// invalidate Insights.
    @discardableResult
    static func adoptFromHistory(_ name: String) -> Bool {
        var catalogue = load()
        let label = TextSafety.clean(name, maximumLength: 80)
        // This is intentionally an exact (case-insensitive) label comparison, not
        // `NameKey.matching`: accent/punctuation folding is useful for finding a
        // place, but would turn two deliberately distinct activity definitions into
        // one identity before the person ever had a chance to choose.
        guard !label.isEmpty, !catalogue.contains(where: { $0.matchesSnapshot(label) }) else {
            return false
        }
        let category = suggestedCategory(for: label)
        catalogue.append(ActivityDefinition(name: label, category: category,
                                            symbol: ActivityIcons.symbol(forCategory: category)))
        save(catalogue)
        return true
    }

    /// Whether a label is already in the catalogue, matched the way adoption matches.
    static func isAdopted(_ name: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && load().contains { $0.matchesSnapshot(label) }
    }

    private static let workingRenamedKey = "LifeLog.ActivityCatalog.workingRenamed.v1"

    /// Retires a stored `Working` entry in favour of `Work`.
    ///
    /// Changing the seed above only helps a fresh install: an existing catalogue lives
    /// in `UserDefaults` and keeps whatever it was seeded with. So the entry is renamed
    /// where it is already stored, and the visits holding that wording are carried
    /// across with it — a rename that left them behind would strand every one of them
    /// on a label the catalogue no longer knows, which Insights counts as "Other".
    ///
    /// When `Work` has already been adopted from history the two are merged rather than
    /// duplicated: the visits move over and the `Working` entry is dropped, keeping the
    /// adopted entry's own category and symbol.
    ///
    /// Runs once. An entry deliberately renamed back to `Working` afterwards stays that
    /// way instead of being corrected again at every launch.
    @MainActor
    @discardableResult
    static func mergeWorkingIntoWork(context: ModelContext) throws -> Int {
        guard !storage.bool(forKey: workingRenamedKey) else { return 0 }
        var activities = load()
        guard let working = activities.first(where: {
            $0.name.caseInsensitiveCompare("Working") == .orderedSame
        }) else {
            storage.set(true, forKey: workingRenamedKey)
            return 0
        }

        let moved = try renameActivity(from: working.name, to: "Work", context: context)
        activities.removeAll { $0.id == working.id }
        // Only add one when the adoption has not already supplied it; that entry is the
        // person's own and keeps the category and symbol they gave it.
        if !activities.contains(where: { $0.name.caseInsensitiveCompare("Work") == .orderedSame }) {
            activities.append(ActivityDefinition(name: "Work", category: working.category,
                                                 symbol: working.symbol))
        }
        save(activities)
        storage.set(true, forKey: workingRenamedKey)
        return moved
    }

    private static let homeTimeRenamedKey = "LifeLog.ActivityCatalog.homeTimeRenamed.v1"

    /// Retires the generated `Home time` label in favour of `At home`.
    ///
    /// `InferenceEngine` used to split a "home" arrival by time of day — `At home`
    /// before 8am or after 6pm, `Home time` in between — which fragmented one
    /// place into two labels nothing asked for: "Set as Home" always wrote `At
    /// home` regardless of the hour, so the same place ended up split purely by
    /// when an automatic guess happened to land. Every visit already holding the
    /// old wording is carried across, the same way `mergeWorkingIntoWork` handles
    /// its own historical rename.
    ///
    /// Runs once. An entry deliberately renamed back to `Home time` afterwards
    /// stays that way instead of being corrected again at every launch.
    @MainActor
    @discardableResult
    static func mergeHomeTimeIntoAtHome(context: ModelContext) throws -> Int {
        guard !storage.bool(forKey: homeTimeRenamedKey) else { return 0 }
        let moved = try renameActivity(from: "Home time", to: "At home", context: context)
        var activities = load()
        if let homeTime = activities.first(where: {
            $0.name.caseInsensitiveCompare("Home time") == .orderedSame
        }) {
            activities.removeAll { $0.id == homeTime.id }
            if !activities.contains(where: { $0.name.caseInsensitiveCompare("At home") == .orderedSame }) {
                activities.append(ActivityDefinition(name: "At home", category: homeTime.category,
                                                     symbol: homeTime.symbol))
            }
            save(activities)
        }
        storage.set(true, forKey: homeTimeRenamedKey)
        return moved
    }

    /// Returns the catalogue to what a fresh install would have.
    ///
    /// Only for the seeded UI-test launch, which promises a known starting state and
    /// until now only delivered half of one: the store is in-memory and thrown away,
    /// but the catalogue lives in `UserDefaults` and survives. A test that adopted a
    /// label therefore changed the state every later run began from — it passed once
    /// on a clean simulator and failed on that simulator forever after, which reads
    /// as a broken app rather than a test that had polluted its own fixture.
    static func resetForTesting() {
        storage.removeObject(forKey: storageKey)
        storage.removeObject(forKey: categoryStorageKey)
        storage.removeObject(forKey: adoptedGeneratedKey)
    }
}
