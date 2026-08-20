import Foundation
import SwiftData

struct ActivityDefinition: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var category: String
    var symbol: String
    var colorHex: String?
    /// Historical display labels which still point to this definition. This is a
    /// compatibility alias, not a normalised search key: two separately-created
    /// labels are never combined merely because their spelling looks alike.
    var legacyNames: [String]

    init(id: UUID = UUID(), name: String, category: String = "Other", symbol: String = "circle.fill") {
        self.id = id
        self.name = TextSafety.clean(name, maximumLength: 80)
        self.category = TextSafety.clean(category, maximumLength: 40)
        self.symbol = TextSafety.clean(symbol, maximumLength: 60)
        self.colorHex = nil
        self.legacyNames = []
    }

    // `lifeArea` was a second grouping stored alongside `category`. It is gone, and
    // its key is absent here on purpose: an older backup still carrying one decodes
    // fine, because a JSON key with no matching property is ignored, and re-encodes
    // without it. No format version change, and nothing to migrate.
    private enum CodingKeys: String, CodingKey { case id, name, category, symbol, colorHex, legacyNames }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let name = try values.decode(String.self, forKey: .name)
        let category = try values.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        let symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "circle.fill"
        self.init(id: id, name: name, category: category, symbol: symbol)
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
    /// `nonisolated` because it is an immutable constant that the off-main-actor
    /// `linkAll` path and its tests need to reason about page size without hopping
    /// to the main actor for a number that can never change.
    nonisolated static let batchSize = 500

    struct Progress: Sendable, Equatable {
        let adoptedDefinitions: Int
        let linkedVisits: Int
        let linkedPlaces: Int
        let hasMore: Bool
    }

    /// Imports each legacy definition by its pre-existing UUID. IDs, not names, are
    /// the deduplication key: two similar labels remain two activities by design.
    ///
    /// `save` defaults to `true` for every existing caller's own transaction
    /// boundary. `LocalBackupService.restore` passes `false`: it folds this
    /// insert into a later, single commit shared with the rest of the restore,
    /// so a failure anywhere in that commit rolls this back too instead of
    /// leaving an adopted definition behind a restore that never completed.
    @discardableResult
    nonisolated static func adoptLegacyDefinitions(context: ModelContext,
                                                   definitions: [ActivityDefinition],
                                                   save: Bool = true) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let existingIDs = Set(existing.map(\.stableID))
        var adopted = 0
        for definition in definitions where !existingIDs.contains(definition.id) {
            context.insert(ActivityDefinitionRecord(
                stableID: definition.id, name: definition.name, category: definition.category,
                symbol: definition.symbol, colorHex: definition.colorHex,
                legacyNames: definition.legacyNames
            ))
            adopted += 1
        }
        if save, adopted > 0 { try context.save() }
        return adopted
    }

    /// Resolves a label to one definition ID.
    ///
    /// Exact display label first, for the reason documented on the type: two
    /// separately-created activities such as `Cafe` and `Café` must not collapse
    /// into one. A case-only fallback follows, and only when exactly one active
    /// definition matches case-insensitively — which is what `Cafe`/`Café` do
    /// *not* do, since they differ by a diacritic rather than by case, so the
    /// concern that motivated exact matching is left intact.
    ///
    /// Without the fallback a label differing only in capitalisation can never
    /// link. The archive carries 177 visits labelled `coffee` against a catalogue
    /// entry named `Coffee`, and every other free-text activity comparison in the
    /// app — `matchesSnapshot`, `ActivityRenameActor.mergeActivity` — is already
    /// case-insensitive, so those rows were reachable by rename but not by
    /// linking.
    struct LabelIndex {
        let exact: [String: UUID]
        let folded: [String: UUID]

        init(definitions: [ActivityDefinitionRecord]) {
            let active = definitions.filter(\.isActive)
            let labelled = active.flatMap { record in
                ([record.name] + record.legacyNames).map { ($0, record.stableID) }
            }
            exact = Dictionary(grouping: labelled, by: \.0)
                .compactMapValues { matches in
                    let ids = Set(matches.map(\.1))
                    return ids.count == 1 ? ids.first : nil
                }
            folded = Dictionary(grouping: labelled, by: { $0.0.lowercased() })
                .compactMapValues { matches in
                    let ids = Set(matches.map(\.1))
                    return ids.count == 1 ? ids.first : nil
                }
        }

        func id(for label: String) -> UUID? {
            exact[label] ?? folded[label.lowercased()]
        }
    }

    /// Links one bounded page of old rows. A completed label must match one
    /// persisted definition; ambiguous or imported labels remain snapshots until the
    /// owner explicitly adopts/categorises them.
    static func backfillNextBatch(context: ModelContext, limit: Int = batchSize) throws -> Progress {
        // Catalogue adoption is a one-time lifecycle/restore step. This bounded
        // linker must never read a retired settings snapshot while opening a day.
        let adopted = 0
        let definitions = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let exactIDs = LabelIndex(definitions: definitions)

        var visitDescriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.activityDefinitionID == nil },
                                                      sortBy: [SortDescriptor(\.arrival)])
        visitDescriptor.fetchLimit = limit
        let visits = try context.fetch(visitDescriptor)
        var linkedVisits = 0
        for visit in visits {
            if let id = exactIDs.id(for: visit.activity) {
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
            if let id = exactIDs.id(for: place.defaultActivity) {
                place.activityDefinitionID = id
                linkedPlaces += 1
            }
        }
        if linkedVisits > 0 || linkedPlaces > 0 { try context.save() }
        return Progress(adoptedDefinitions: adopted, linkedVisits: linkedVisits,
                        linkedPlaces: linkedPlaces,
                        hasMore: visits.count == limit || places.count == limit)
    }

    /// Links every remaining unlinked row in one pass, for the attended repair in
    /// Settings.
    ///
    /// The paged `backfillNextBatch` is sized for launch, where the only budget
    /// that matters is time-to-first-screen — but it links at most one page per
    /// launch, so an archive of 25,000 visits needs roughly fifty cold launches to
    /// finish, and rows whose label never matches are re-fetched on every one of
    /// them. That is fine as a background trickle and useless as a way to actually
    /// complete the migration, which is what this is for. `nonisolated` so
    /// `ArchiveRepairActor` can run it off the main actor, where a whole-archive
    /// rewrite belongs; it saves nothing itself, leaving the caller's transaction
    /// to commit the whole repair at once.
    nonisolated static func linkAll(context: ModelContext) throws -> Int {
        let definitions = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let index = LabelIndex(definitions: definitions)
        var linked = 0
        for visit in try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        )) {
            guard let id = index.id(for: visit.activity) else { continue }
            visit.activityDefinitionID = id
            linked += 1
        }
        for place in try context.fetch(FetchDescriptor<SavedPlace>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        )) {
            guard let id = index.id(for: place.defaultActivity) else { continue }
            place.activityDefinitionID = id
            linked += 1
        }
        return linked
    }

}

/// The presentation catalogue is a read-through cache of active
/// `ActivityDefinitionRecord` rows. It deliberately has no durable writes of its
/// own: callers save through a `ModelContext`, then refresh this small value cache
/// for synchronous rendering helpers such as timeline artwork.
enum ActivityCatalog {
    /// Categories use UserDefaults because an intentionally empty group has no
    /// activity record to carry it; activity identity itself is durable SwiftData.
    nonisolated(unsafe) static var storage: UserDefaults = .standard

    /// Unsafe only to let pure rendering helpers read it without an actor hop. All
    /// assignments happen after a successful ModelContext save on the main actor.
    nonisolated(unsafe) private static var cached = sorted(defaults.map {
        ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol)
    })

    /// `rethrows`, so a body that can fail — a catalogue migration that touches the
    /// store, say — can be scoped to test storage without swallowing its error. The
    /// `defer` restores the real storage whether the body returns or throws.
    static func withStorage(_ defaults: UserDefaults, _ body: () throws -> Void) rethrows {
        let previous = storage
        let previousCache = cached
        storage = defaults
        defer {
            storage = previous
            cached = previousCache
        }
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
        ("Shopping", "Errands", "bag.fill"),
        ("Concert", "Entertainment", "music.mic"), ("Football", "Entertainment", "sportscourt.fill"),
        ("Exercising", "Fitness", "figure.run"), ("Healthcare", "Health", "cross.case.fill"),
        ("Studying", "Work", "book.fill"), ("Travelling", "Travel", "car.fill"),
        ("Socialising", "Social", "person.2.fill"), ("Visiting", "Social", "mappin.and.ellipse"),
        ("Watching a movie", "Entertainment", "film.fill")
    ] + generatedDefaults

    /// Activities the app produces for itself, from Apple Health, the iPhone's motion
    /// history, and its own journey detection. They were missing from the catalogue
    /// entirely, so a walk, a night's sleep or a commute arrived with the fallback grey
    /// dot, no colour of its own and no group — and the Sleep and Commute groups sat
    /// empty while the timeline was full of both.
    static let generatedDefaults: [(name: String, category: String, symbol: String)] = [
        ("Sleeping", "Sleep", "bed.double.fill"),
        // An iPhone schedule estimates this without measuring sleep. It sits in Sleep
        // for grouping -- it is rest either way -- which is safe because every sleep
        // *duration* Insights reports comes from HealthKit (`sleepSummary`,
        // `averageNightlySleep`), never from a group total. It was "Other" only while
        // "Other" was the dumping ground this release exists to empty.
        ("In bed", "Sleep", "bed.double.fill"),
        ("Walking", "Fitness", "figure.walk"),
        ("Running", "Fitness", "figure.run"),
        ("Cycling", "Fitness", "bicycle"),
        ("Swimming", "Fitness", "figure.pool.swim"),
        ("Yoga", "Fitness", "figure.yoga"),
        ("Strength training", "Fitness", "dumbbell.fill"),
        ("Commuting", "Commute", "car.fill"),
        ("In transit", "Travel", "bus.fill"),
        ("Dog walk", "Pets", "pawprint.fill")
    ]

    /// Alphabetical, ignoring case and accents. A list of labels is scanned by name
    /// and nothing else, and storage order put each newly added entry wherever it
    /// happened to land — so the one just added was the hardest to find again.
    static func sorted(_ activities: [ActivityDefinition]) -> [ActivityDefinition] {
        activities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns one row per exact display name for selectors. A short-lived
    /// compatibility path once allowed the same activity to be adopted more than
    /// once under different IDs; those records still need to remain addressable for
    /// archive repair, but showing every copy makes choosing an activity ambiguous.
    /// Do not use `NameKey` here: `Cafe` and `Café` are intentionally distinct
    /// activity identities.
    static func uniqueForPresentation(
        _ activities: [ActivityDefinition],
        excludingIDs: Set<UUID> = [],
        excludingNames: Set<String> = []
    ) -> [ActivityDefinition] {
        var seenNames = Set<String>()
        let excludedNames = Set(excludingNames.map { $0.lowercased() })
        return sorted(activities).filter { activity in
            guard !excludingIDs.contains(activity.id),
                  !excludedNames.contains(activity.name.lowercased()) else { return false }
            return seenNames.insert(activity.name.lowercased()).inserted
        }
    }

    /// Active records are the source of truth once the store is open. `load()` stays
    /// synchronous because icon, colour and inference fallbacks are used in hot view
    /// paths; it never touches UserDefaults or fetches SwiftData.
    nonisolated static func load() -> [ActivityDefinition] { cached }

    /// Makes the durable table authoritative before normal navigation begins.
    /// Built-in definitions seed an empty store; no UserDefaults catalogue snapshot
    /// is decoded or merged here.
    @MainActor
    static func prepareDurableCatalogue(context: ModelContext) throws -> Int {
        var records = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        var changed = 0

        if records.isEmpty {
            let seed = defaults.map {
                ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol)
            }
            for definition in seed {
                context.insert(ActivityDefinitionRecord(stableID: definition.id, name: definition.name,
                                                        category: definition.category, symbol: definition.symbol,
                                                        colorHex: definition.colorHex,
                                                        legacyNames: definition.legacyNames))
            }
            changed = seed.count
            records = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        }
        do {
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
        try refresh(context: context)
        return changed
    }

    @MainActor
    static func refresh(context: ModelContext) throws {
        refresh(try context.fetch(FetchDescriptor<ActivityDefinitionRecord>()))
    }

    private static func refresh(_ records: [ActivityDefinitionRecord]) {
        cached = sorted(records.filter(\.isActive).map { record in
            var definition = ActivityDefinition(id: record.stableID, name: record.name,
                                                category: record.category, symbol: record.symbol)
            definition.colorHex = record.colorHex
            definition.legacyNames = record.legacyNames
            return definition
        })
    }

    /// Replaces the active catalogue in one durable transaction. Omitted IDs are
    /// deactivated rather than deleted, preserving old visits' stable identity and
    /// allowing an explicit future reactivation without guessing by display name.
    @MainActor
    static func save(_ activities: [ActivityDefinition], context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.stableID, $0) })
        let activeIDs = Set(activities.map(\.id))
        for record in records where record.isActive && !activeIDs.contains(record.stableID) {
            record.isActive = false
            record.modifiedAt = .now
        }
        for definition in activities {
            if let record = byID[definition.id] {
                record.name = definition.name
                record.category = definition.category
                record.symbol = definition.symbol
                record.colorHex = definition.colorHex
                record.legacyNames = definition.legacyNames
                record.lifeArea = definition.category
                record.isActive = true
                record.modifiedAt = .now
            } else {
                context.insert(ActivityDefinitionRecord(stableID: definition.id, name: definition.name,
                                                        category: definition.category, symbol: definition.symbol,
                                                        colorHex: definition.colorHex,
                                                        legacyNames: definition.legacyNames))
            }
        }
        do {
            if context.hasChanges { try context.save() }
            refresh(try context.fetch(FetchDescriptor<ActivityDefinitionRecord>()))
        } catch {
            // A failed edit must not remain as pending context state and leak into an
            // unrelated later save (for example, a manual visit correction).
            context.rollback()
            throw error
        }
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
        return inferredCategory(for: key)
    }

    /// The symbol to use when rendering a label from either the catalogue or the
    /// archive. History can contain an alias, a label that has not been adopted, or
    /// an older definition whose symbol was the generic dot. Resolve those cases to
    /// the definition's category instead of making every list invent its own lookup.
    /// A deliberately chosen dot remains valid for an activity in Other.
    static func symbol(for activity: String,
                       in catalogue: [ActivityDefinition]? = nil) -> String {
        let activities = catalogue ?? load()
        if let definition = activities.first(where: { $0.matchesSnapshot(activity) }) {
            let symbol = definition.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = definition.category
            if ActivityIcons.contains(symbol),
               !(symbol == "circle.fill" && category.caseInsensitiveCompare(fallbackCategory) != .orderedSame) {
                return symbol
            }
            return ActivityIcons.symbol(forCategory: category)
        }

        return ActivityIcons.symbol(forCategory: category(for: activity))
    }

    /// The group a label belongs to when nothing else knows it: an imported journal
    /// entry, or anything typed straight onto a visit. This used to be four rules
    /// wide (sleep/walk/travel), which is why an archive full of real labels --
    /// CrossFit, Holiday, Dentist, Fuel up -- collapsed into "Other" and stayed
    /// there. Widened deliberately: every rule below is a word that already appears
    /// in recorded history, and the fallback is the last resort rather than the
    /// common case.
    ///
    /// Order matters. The more specific word wins, so "Dog walk" is Pets rather than
    /// Fitness and "Work trip" is Work rather than Travel.
    static func inferredCategory(for label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return fallbackCategory }
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if any(["nala", "dog walk", "vet", "puppy", "kennel"]) { return "Pets" }
        if any(["sleep", "nap", "in bed"]) { return "Sleep" }
        // Ahead of Work on purpose: "Strength training" contains "training", and Work
        // claims that word. Nothing filed under Work contains a word from here, so
        // reading Fitness first costs nothing and keeps a gym session out of the office.
        if any(["crossfit", "gym", "walk", "run", "cycl", "swim", "rowing", "yoga",
                "exercis", "fitness", "netball", "race", "strength", "sport"]) { return "Fitness" }
        if any(["work", "meeting", "conference", "training", "study", "studying",
                "shift", "rostered", "office"]) { return "Work" }
        if any(["doctor", "dentist", "physio", "hospital", "health", "massage",
                "cryo", "covid", "blood", "medical", "chemist", "pharmacy",
                "specialist", "surgery"]) { return "Health" }
        if any(["eat", "food", "beer", "coffee", "lunch", "dinner", "breakfast",
                "snack", "takeaway", "brunch", "cafe", "café", "pub", "drink",
                "restaurant"]) { return "Food & Drink" }
        if any(["shop", "grocer", "fuel", "carwash", "car service", "mail",
                "errand", "bank", "post", "library", "books", "boarder",
                "haircut", "laundry"]) { return "Errands" }
        if any(["commut", "bus", "train station", "catch bus"]) { return "Commute" }
        if any(["holiday", "flight", "travel", "transit", "cruise", "layover",
                "airport", "trip", "drive to"]) { return "Travel" }
        if any(["cinema", "movie", "film", "concert", "football", "bowling",
                "golf", "gig", "theatre"]) { return "Entertainment" }
        if any(["friend", "family", "mum", "dad", "wedding", "birthday", "funeral",
                "party", "social", "visit", "dnd", "trivia", "catch up", "niece", "nephew",
                "confraternity"]) { return "Social" }
        if any(["sex", "hookup", "toilet", "time out", "shower", "personal"]) { return "Personal" }
        if any(["home"]) { return "Home" }
        return fallbackCategory
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
    /// The groups LifeLog ships with, and the only vocabulary Insights counts by.
    ///
    /// There used to be a second, fixed taxonomy on top of this one -- "life areas" --
    /// which Month's balance, Week's breakdown and the Year chart grouped by while the
    /// rest of Insights grouped by these. It bought one merged row on real data and
    /// cost three colours (its names were not in `CategoryPalette`, so 57% of a year
    /// drew grey), an unmapped Education, and two names for the same hours on one
    /// screen -- "Sleep" above "Sleep & Rest". Groups already do the job, and unlike
    /// life areas a person can edit them.
    static let defaultCategories = ["Home", "Sleep", "Work", "Fitness", "Food & Drink",
                                    "Health", "Social", "Entertainment", "Travel",
                                    "Commute", "Errands", "Pets", "Personal", "Other"]

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
    @MainActor
    @discardableResult
    static func renameCategory(from previous: String, to updated: String,
                               context: ModelContext) throws -> Int {
        let clean = TextSafety.clean(updated, maximumLength: 40)
        guard !clean.isEmpty, clean.caseInsensitiveCompare(previous) != .orderedSame else { return 0 }
        var activities = load()
        var moved = 0
        for index in activities.indices
        where activities[index].category.caseInsensitiveCompare(previous) == .orderedSame {
            activities[index].category = clean
            moved += 1
        }
        try save(activities, context: context)
        saveCategories(loadCategories().map {
            $0.caseInsensitiveCompare(previous) == .orderedSame ? clean : $0
        })
        return moved
    }

    /// Removes a group. Its activities fall back to "Other" rather than losing their
    /// grouping entirely, which would drop them out of Insights until noticed.
    @MainActor
    @discardableResult
    static func deleteCategory(_ name: String, context: ModelContext) throws -> Int {
        guard name.caseInsensitiveCompare(fallbackCategory) != .orderedSame else { return 0 }
        var activities = load()
        var orphaned = 0
        for index in activities.indices
        where activities[index].category.caseInsensitiveCompare(name) == .orderedSame {
            activities[index].category = fallbackCategory
            orphaned += 1
        }
        try save(activities, context: context)
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
    ///
    /// Delegates to `inferredCategory` rather than keeping its own keyword table.
    /// There were two tables, and they disagreed: this one sent "fuel" to Travel
    /// while the other had no rule for it at all, so the same label was grouped one
    /// way when adopted and another way when read straight from history. One table
    /// is the only way they cannot drift — the same lesson `category(for:)` records
    /// about the hand-written switch that used to sit in front of it.
    static func suggestedCategory(for activity: String) -> String {
        let key = activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inferredCategory(for: key)
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

    /// Folds `source` into `target`: every visit and Saved Place carrying source's
    /// name or any of its legacy aliases is rewritten to target's name, target
    /// gains those as its own legacy aliases (so an old export or backup naming
    /// source still resolves), and source is removed from the catalogue and
    /// deactivated in the durable record.
    ///
    /// This is what rename-into-an-existing-name used to do before the identity
    /// migration made that unsafe — two definitions can no longer share a display
    /// name, since visits are gradually moving from text matching to
    /// `activityDefinitionID`, and silently leaving a second live definition under
    /// the winning name would corrupt that migration rather than complete it.
    @MainActor
    @discardableResult
    static func mergeActivity(_ source: ActivityDefinition, into target: ActivityDefinition,
                              context: ModelContext) async throws -> Int {
        guard source.id != target.id else { return 0 }
        let sourceNames = [source.name] + source.legacyNames
        let changed = try await ActivityRenameActor(modelContainer: context.container).mergeActivity(
            sourceID: source.id, sourceNames: sourceNames, targetID: target.id, targetName: target.name
        )
        var activities = load()
        activities.removeAll { $0.id == source.id }
        if let index = activities.firstIndex(where: { $0.id == target.id }) {
            var updated = activities[index]
            var aliases = updated.legacyNames
            for candidate in sourceNames where
                candidate.caseInsensitiveCompare(updated.name) != .orderedSame &&
                !aliases.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                aliases.append(candidate)
            }
            updated.legacyNames = aliases
            activities[index] = updated
        }
        try save(activities, context: context)
        return changed
    }

    /// Adds a label the archive already uses to the catalogue, so it can be renamed,
    /// grouped and given an icon — and so Insights stops counting it under "Other".
    ///
    /// One implementation for what is now three ways in: the bulk "Add from your
    /// history" sheet, the swipe on the Activities tab, and the button on an activity's
    /// own page. The same label must not come out looking different depending on which
    /// was used. Returns whether anything was added, so the caller knows whether to
    /// invalidate Insights.
    @MainActor
    @discardableResult
    static func adoptFromHistory(_ name: String, context: ModelContext) throws -> Bool {
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
        try save(catalogue, context: context)
        return true
    }

    /// Whether a label is already in the catalogue, matched the way adoption matches.
    static func isAdopted(_ name: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && load().contains { $0.matchesSnapshot(label) }
    }

    /// Clears only retired compatibility data for isolated seeded UI tests. The test
    /// store itself remains responsible for its durable records.
    static func resetForTesting() {
        storage.removeObject(forKey: categoryStorageKey)
        cached = sorted(defaults.map {
            ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol)
        })
    }

#if DEBUG
    /// Test fixtures sometimes need a small catalogue without constructing a store.
    /// This never writes UserDefaults and is unavailable from release builds; real
    /// app mutations must use the context-taking durable overload above.
    static func save(_ activities: [ActivityDefinition]) {
        cached = sorted(activities)
    }

    static func adoptFromHistory(_ name: String) -> Bool {
        var catalogue = load()
        let label = TextSafety.clean(name, maximumLength: 80)
        guard !label.isEmpty, !catalogue.contains(where: { $0.matchesSnapshot(label) }) else { return false }
        let category = suggestedCategory(for: label)
        catalogue.append(ActivityDefinition(name: label, category: category,
                                            symbol: ActivityIcons.symbol(forCategory: category)))
        save(catalogue)
        return true
    }

    static func seed() {
        if cached.isEmpty {
            cached = sorted(defaults.map {
                ActivityDefinition(name: $0.name, category: $0.category, symbol: $0.symbol)
            })
        }
    }

    @discardableResult
    static func renameCategory(from previous: String, to updated: String) -> Int {
        let clean = TextSafety.clean(updated, maximumLength: 40)
        guard !clean.isEmpty, clean.caseInsensitiveCompare(previous) != .orderedSame else { return 0 }
        var activities = load()
        var moved = 0
        for index in activities.indices where activities[index].category.caseInsensitiveCompare(previous) == .orderedSame {
            activities[index].category = clean
            moved += 1
        }
        save(activities)
        saveCategories(loadCategories().map { $0.caseInsensitiveCompare(previous) == .orderedSame ? clean : $0 })
        return moved
    }

    @discardableResult
    static func deleteCategory(_ name: String) -> Int {
        guard name.caseInsensitiveCompare(fallbackCategory) != .orderedSame else { return 0 }
        var activities = load()
        var orphaned = 0
        for index in activities.indices where activities[index].category.caseInsensitiveCompare(name) == .orderedSame {
            activities[index].category = fallbackCategory
            orphaned += 1
        }
        save(activities)
        saveCategories(loadCategories().filter { $0.caseInsensitiveCompare(name) != .orderedSame })
        return orphaned
    }
#endif
}
