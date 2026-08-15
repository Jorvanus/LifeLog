import Foundation
import SwiftData

/// One-off repairs for damage the Life Cycle import left in the archive, and for
/// duplicate rows the automatic pipeline produced before its own dedup landed.
///
/// This is deliberately *not* a launch migration. Every step here rewrites or
/// deletes recorded history on a judgement call, and a judgement call belongs to
/// the owner rather than to a `.task` that runs before the Timeline appears —
/// `SleepSessionRepair` runs unattended precisely because folding two identical
/// HealthKit rows needs no judgement, and nothing in this file has that property.
/// So the whole pass is scan-then-apply, driven from Settings, with a backup taken
/// first, matching `JournalCompactionView`'s shape.
///
/// The analysis functions are pure and take `[Visit]` so they can be tested
/// without a store; `ArchiveRepairActor` owns the fetching and saving.
enum ArchiveRepair {
    /// A stay longer than this is treated as never having been closed rather than
    /// as a genuinely long stay. Chosen because the archive's real runaways start
    /// at several days (the worst is 23.6 days) while legitimate long stays — a
    /// weekend at home, a hospital admission — sit well under it, and because a
    /// visit that spans more than a day already breaks every per-day aggregate
    /// that buckets by `arrival`.
    static let runawayThreshold: TimeInterval = 24 * 60 * 60

    /// Two rows whose arrival *and* departure both land within this of each other
    /// are the same event recorded twice. The imported journal's duplicates are
    /// mostly exact or one second apart; five seconds covers the rounding without
    /// reaching far enough to swallow two genuinely consecutive short journeys.
    static let duplicateTolerance: TimeInterval = 5

    // MARK: - Findings

    /// What a scan found, in counts only. `Sendable` so it can cross back out of
    /// `ArchiveRepairActor` to SwiftUI; `Visit` never leaves the actor.
    struct Findings: Sendable, Equatable {
        var runawayStays = 0
        var runawayStaysClosable = 0
        var runawayHours: Double = 0
        var duplicateRows = 0
        var nestedJourneys = 0
        var coordinateBackfills = 0
        var unlinkedActivityRows = 0
        var caseOnlyMismatches = 0
        /// Rows still without coordinates after the backfill, and the place names
        /// that would fix the most of them.
        var uncoordinatedRows = 0
        var unmatchedPlaces: [UnmatchedPlace] = []
        /// Extra `ActivityDefinitionRecord` rows sharing a name with another active
        /// definition. See `duplicateDefinitionGroups` for why these exist and why
        /// they silently block activity linking until merged.
        var duplicateDefinitionNames = 0
        var duplicateDefinitionRows = 0

        var isEmpty: Bool {
            runawayStays == 0 && duplicateRows == 0 && nestedJourneys == 0
                && coordinateBackfills == 0 && unlinkedActivityRows == 0
                && duplicateDefinitionRows == 0
        }

        /// Rows a step would touch, for the preview list. Kept beside the step
        /// definition so a new step cannot be added without a count to show.
        func count(for step: Step) -> Int {
            switch step {
            case .closeRunawayStays: runawayStaysClosable
            case .mergeDuplicates: duplicateRows
            case .collapseNestedJourneys: nestedJourneys
            case .backfillCoordinates: coordinateBackfills
            case .mergeDuplicateDefinitions: duplicateDefinitionRows
            case .linkActivities: unlinkedActivityRows
            }
        }
    }

    /// The repairs the owner can choose between. Ordered as they must run: closing
    /// runaways first means the duplicate and journey passes see corrected spans,
    /// duplicate definitions are folded before linking so an ambiguous name no
    /// longer blocks it, and linking activities runs last so it sees the final
    /// surviving row set.
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case closeRunawayStays
        case mergeDuplicates
        case collapseNestedJourneys
        case backfillCoordinates
        case mergeDuplicateDefinitions
        case linkActivities

        var id: Self { self }

        var title: String {
            switch self {
            case .closeRunawayStays: "Close runaway stays"
            case .mergeDuplicates: "Merge duplicate records"
            case .collapseNestedJourneys: "Collapse nested journeys"
            case .backfillCoordinates: "Add coordinates from Saved Places"
            case .mergeDuplicateDefinitions: "Merge duplicate activity definitions"
            case .linkActivities: "Link activities to the catalogue"
            }
        }

        var detail: String {
            switch self {
            case .closeRunawayStays:
                "Stays over 24 hours that were never closed and swallowed later visits. Each is closed where a visit at a different place begins; anything with no such boundary is left alone for you to edit."
            case .mergeDuplicates:
                "Records with the same activity whose start and end both match within five seconds. The earliest is kept and absorbs the rest."
            case .collapseNestedJourneys:
                "Journeys recorded wholly inside another journey, from the same import running twice."
            case .backfillCoordinates:
                "Imported visits whose place name matches a Saved Place get that place's coordinates, marked as derived from the name rather than recorded by GPS."
            case .mergeDuplicateDefinitions:
                "Activities in your catalogue that share an identical name under different identities, most likely created by a past ID-stability bug. Every visit or Saved Place pointing at a duplicate is repointed to the earliest one before the duplicate is removed."
            case .linkActivities:
                "Visits still carrying only a text label are linked to their catalogue activity, so renaming or merging reaches them."
            }
        }

        /// Whether the step deletes rows. Drives the destructive styling and the
        /// wording of the confirmation, so a person can tell "this rewrites a
        /// field" from "this removes history" before agreeing to it.
        var deletesRows: Bool {
            switch self {
            case .mergeDuplicates, .collapseNestedJourneys, .mergeDuplicateDefinitions: true
            case .closeRunawayStays, .backfillCoordinates, .linkActivities: false
            }
        }
    }

    /// What an apply actually did. Separate from `Findings` because a step can
    /// legitimately touch fewer rows than the scan predicted — an earlier step in
    /// the same run may have already removed or reshaped them.
    struct Report: Sendable, Equatable {
        var staysClosed = 0
        var duplicatesMerged = 0
        var journeysCollapsed = 0
        var coordinatesAdded = 0
        var definitionsMerged = 0
        var activitiesLinked = 0
        var stillNeedingReview = 0

        var totalChanges: Int {
            staysClosed + duplicatesMerged + journeysCollapsed + coordinatesAdded
                + definitionsMerged + activitiesLinked
        }
    }

    // MARK: - Runaway stays

    /// A runaway stay and the boundary it should be closed at, or `nil` when no
    /// safe boundary exists.
    struct RunawayClosure {
        let visit: Visit
        let closeAt: Date?
    }

    /// Finds stays that outran their own departure and works out where each should
    /// end.
    ///
    /// The boundary is the arrival of the next visit at a *different, named* place
    /// — not simply the next visit. That distinction is the whole point: a Walking
    /// or Sleeping row nested inside a home stay is movement *within* the stay, not
    /// evidence of leaving it, and closing the stay there would invent a departure
    /// the person never made. The same reasoning already governs how movement
    /// inside an unclosed stay is read elsewhere in the app.
    ///
    /// A placeholder name ("Identifying…", "Imported journal") is not a different
    /// place, it is an absent one, so it can never act as a boundary. Where nothing
    /// qualifies, the closure is `nil` and the row is reported as needing manual
    /// review rather than closed at a guess.
    static func runawayClosures(in visits: [Visit], now: Date = .now) -> [RunawayClosure] {
        let ordered = visits
            .filter { $0.resolutionState != .superseded }
            .sorted { $0.arrival < $1.arrival }
        var closures: [RunawayClosure] = []
        for (index, visit) in ordered.enumerated() {
            let end = visit.departure ?? now
            guard end.timeIntervalSince(visit.arrival) > runawayThreshold else { continue }
            let ownName = comparableName(visit.placeName)
            // Only rows starting inside the runaway can bound it, and the first
            // qualifying one wins — a later boundary would leave the stay still
            // covering a visit somewhere else.
            let boundary = ordered[(index + 1)...]
                .prefix { $0.arrival < end }
                .first { candidate in
                    guard let otherName = comparableName(candidate.placeName) else { return false }
                    return otherName != ownName
                }
            closures.append(RunawayClosure(visit: visit, closeAt: boundary?.arrival))
        }
        return closures
    }

    /// The Life Cycle import's stand-in for "no place was recorded". It is not in
    /// `Visit.isPlaceholderName` because that governs app-wide presentation —
    /// `displayPlaceName`, `needsCategorisation` — and reclassifying 11,237 rows
    /// there is a much larger change than this repair. For deciding whether a
    /// visit proves the owner went *somewhere else*, though, it is exactly as
    /// empty as "Identifying…": 9,791 of the rows carrying it are journeys with
    /// no coordinates, and treating them as a distinct place would close nearly
    /// every long stay at the first journey recorded inside it.
    static let importPlaceholderName = "Imported journal"

    static func isUnnamedPlace(_ name: String) -> Bool {
        Visit.isPlaceholderName(name)
            || name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(importPlaceholderName) == .orderedSame
    }

    /// Case- and whitespace-insensitive, matching how every other free-text place
    /// and activity comparison in the app is done. `nil` for a placeholder, so
    /// "unnamed" never compares equal to "unnamed".
    private static func comparableName(_ name: String) -> String? {
        guard !isUnnamedPlace(name) else { return nil }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Applies the closures that have a boundary. A closure whose boundary is at or
    /// before the arrival cannot be applied — that would produce a zero-length or
    /// reversed visit, which is worse than the runaway it replaces.
    @discardableResult
    static func closeRunawayStays(in visits: [Visit], now: Date = .now) -> (closed: Int, needingReview: Int) {
        var closed = 0
        var needingReview = 0
        for closure in runawayClosures(in: visits, now: now) {
            guard let closeAt = closure.closeAt, closeAt > closure.visit.arrival else {
                needingReview += 1
                continue
            }
            closure.visit.departure = closeAt
            closed += 1
        }
        return (closed, needingReview)
    }

    // MARK: - Duplicates

    /// Rows that record the same event twice: same activity, and both endpoints
    /// within `duplicateTolerance`. Returns the rows to delete, never the ones to
    /// keep, so a caller cannot accidentally delete a whole cluster.
    ///
    /// The survivor is the earliest-starting row in each cluster, the same
    /// "keep the first, absorb the rest" rule `SleepSessionRepair` uses. This pass
    /// is the general form of that one — it is not restricted to `health-sleep`,
    /// because the imported journal produced the same shape in far greater volume.
    static func duplicateRows(in visits: [Visit]) -> [Visit] {
        let ordered = visits
            .filter { $0.departure != nil && $0.resolutionState != .superseded }
            .sorted { $0.arrival < $1.arrival }
        var removable: [Visit] = []
        // Membership by identity rather than a linear scan of `removable`: on this
        // archive the removable set reaches ~1,000 rows out of ~26,000, and a
        // `contains(where:)` per candidate turns the pass quadratic for no reason.
        var removedIdentities: Set<ObjectIdentifier> = []
        var clusterStart = 0
        for index in ordered.indices {
            let candidate = ordered[index]
            // Walk back only as far as the tolerance reaches, so this stays linear
            // rather than comparing every row against every earlier one.
            while clusterStart < index,
                  candidate.arrival.timeIntervalSince(ordered[clusterStart].arrival) > duplicateTolerance {
                clusterStart += 1
            }
            for earlier in ordered[clusterStart..<index] where isDuplicate(earlier, candidate) {
                // A row already claimed by an earlier survivor is not offered twice.
                if removedIdentities.insert(ObjectIdentifier(candidate)).inserted {
                    removable.append(candidate)
                }
                break
            }
        }
        return removable
    }

    private static func isDuplicate(_ left: Visit, _ right: Visit) -> Bool {
        guard left.activity.caseInsensitiveCompare(right.activity) == .orderedSame else { return false }
        guard abs(right.arrival.timeIntervalSince(left.arrival)) <= duplicateTolerance else { return false }
        guard let leftEnd = left.departure, let rightEnd = right.departure else { return false }
        return abs(rightEnd.timeIntervalSince(leftEnd)) <= duplicateTolerance
    }

    // MARK: - Nested journeys

    /// Journeys recorded wholly inside another journey. Distinct from
    /// `duplicateRows` because these are not near-identical: the import split one
    /// trip into an outer leg and an inner leg covering part of the same minutes,
    /// so the inner row adds no information the outer one does not already carry.
    ///
    /// Only the strictly-contained row is removed, and only when both rows are
    /// journeys. A shop stop inside a journey is real and is left alone.
    static func nestedJourneyRows(in visits: [Visit]) -> [Visit] {
        let journeys = visits
            .filter { $0.departure != nil && $0.resolutionState != .superseded && isJourney($0) }
            .sorted { $0.arrival < $1.arrival }
        var removable: [Visit] = []
        var removedIdentities: Set<ObjectIdentifier> = []
        for (index, outer) in journeys.enumerated() {
            guard let outerEnd = outer.departure else { continue }
            // An outer row that is itself being removed cannot justify removing
            // anything nested inside it — otherwise a chain of three overlapping
            // legs could delete the only row covering those minutes.
            guard !removedIdentities.contains(ObjectIdentifier(outer)) else { continue }
            for inner in journeys[(index + 1)...] {
                guard inner.arrival < outerEnd else { break }
                guard let innerEnd = inner.departure, innerEnd <= outerEnd else { continue }
                if removedIdentities.insert(ObjectIdentifier(inner)).inserted {
                    removable.append(inner)
                }
            }
        }
        return removable
    }

    /// The labels the archive uses for time spent moving. Matched by name rather
    /// than by category so a person who recategorises "Travelling" does not
    /// silently change what this pass will delete.
    private static let journeyLabels: Set<String> = ["travelling", "in transit", "commuting"]

    private static func isJourney(_ visit: Visit) -> Bool {
        journeyLabels.contains(visit.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // MARK: - Coordinate backfill

    /// Visits with no coordinates whose place name matches a Saved Place, paired
    /// with the place to take coordinates from.
    ///
    /// Name matching is the only signal available: 99% of the imported archive has
    /// no coordinates at all, so there is nothing to match geographically. That
    /// makes the result a strong inference rather than a recorded fact, which is
    /// why applying it stamps `.nameBackfill` provenance — a later reader can tell
    /// these apart from a genuine fix, and undo them as a set if the inference
    /// turns out wrong.
    static func coordinateBackfills(in visits: [Visit], savedPlaces: [SavedPlace]) -> [(visit: Visit, place: SavedPlace)] {
        var byName: [String: SavedPlace] = [:]
        for place in savedPlaces {
            let key = place.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            // Two Saved Places sharing a name would make the match ambiguous, and
            // an ambiguous coordinate is worse than none.
            if byName[key] != nil { byName[key] = nil } else { byName[key] = place }
        }
        return visits.compactMap { visit in
            guard visit.latitude == 0, visit.longitude == 0 else { return nil }
            guard !isUnnamedPlace(visit.placeName) else { return nil }
            let key = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let place = byName[key] else { return nil }
            return (visit, place)
        }
    }

    /// One place name the archive uses often that no Saved Place matches.
    struct UnmatchedPlace: Sendable, Equatable, Identifiable {
        let name: String
        let visits: Int
        var id: String { name }
    }

    /// The place names that would gain coordinates if a Saved Place existed for
    /// them, most-used first.
    ///
    /// This exists because the backfill's reach is set by the Saved Place list,
    /// not by the archive: the owner's Saved Place for home is named "Home" while
    /// nine years of imported journal call the same address "8 Justin St", so
    /// name matching reaches 158 rows out of 25,624 with no coordinates. Nothing
    /// is wrong with the matching — there is simply nothing to match against. The
    /// only way to widen it is to add Saved Places, so the screen names the ones
    /// worth adding rather than reporting a small number with no explanation.
    static func unmatchedPlaces(in visits: [Visit], savedPlaces: [SavedPlace],
                                limit: Int = 8) -> [UnmatchedPlace] {
        let known = Set(savedPlaces.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var counts: [String: (display: String, count: Int)] = [:]
        for visit in visits where visit.latitude == 0 && visit.longitude == 0 {
            guard !isUnnamedPlace(visit.placeName) else { continue }
            let trimmed = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !known.contains(key) else { continue }
            counts[key] = (trimmed, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { UnmatchedPlace(name: $0.display, visits: $0.count) }
    }

    @discardableResult
    static func backfillCoordinates(in visits: [Visit], savedPlaces: [SavedPlace]) -> Int {
        let matches = coordinateBackfills(in: visits, savedPlaces: savedPlaces)
        for (visit, place) in matches {
            visit.latitude = place.latitude
            visit.longitude = place.longitude
            visit.placeFieldProvenance = PlaceFieldProvenance.nameBackfill.rawValue
        }
        return matches.count
    }

    /// Reverses a coordinate backfill, for the case the name-based inference turns
    /// out to be wrong. Only rows still carrying `.nameBackfill` provenance are
    /// touched, so a visit whose position was corrected by hand since — which
    /// would have overwritten the provenance — keeps the better value.
    @discardableResult
    static func revertCoordinateBackfill(in visits: [Visit]) -> Int {
        var reverted = 0
        for visit in visits where visit.placeProvenance == .nameBackfill {
            visit.latitude = 0
            visit.longitude = 0
            visit.placeFieldProvenance = nil
            reverted += 1
        }
        return reverted
    }

    // MARK: - Duplicate activity definitions

    /// One name shared by more than one active `ActivityDefinitionRecord`, and
    /// which of them should survive.
    ///
    /// This exists because `ActivityIdentityMigration.LabelIndex` — both the
    /// existing per-launch backfill and this repair's own `linkActivities` step —
    /// refuses to link a name that matches more than one active definition. That
    /// refusal is deliberate for `Cafe` versus `Café`: two definitions with
    /// different names are almost certainly two real activities, and folding them
    /// would be irreversible data loss. But two definitions with the *exact same*
    /// name text are not that case — nothing distinguishes them, so they are far
    /// more likely to be one activity accidentally split into two identities, the
    /// shape `ActivityCatalog.load()` produced while it could hand out a fresh
    /// random ID for what a person experienced as renaming or re-picking an
    /// existing activity (fixed by `ActivityCatalog.seed()` running at launch).
    /// Until the duplicates are folded, every visit and Saved Place carrying that
    /// name is permanently unlinkable, however many times linking runs.
    struct DuplicateDefinitionGroup {
        let name: String
        let canonical: ActivityDefinitionRecord
        let duplicates: [ActivityDefinitionRecord]
    }

    static func duplicateDefinitionGroups(in definitions: [ActivityDefinitionRecord]) -> [DuplicateDefinitionGroup] {
        let grouped = Dictionary(grouping: definitions.filter(\.isActive), by: \.name)
        return grouped.compactMap { name, records in
            guard records.count > 1 else { return nil }
            // The earliest-created record is the one existing visits and Saved
            // Places are most likely to already point at, so it keeps its
            // identity and the newer rows fold into it. `stableID` breaks a tie
            // between records created at the same instant, so the choice is
            // deterministic rather than depending on fetch order.
            let sorted = records.sorted {
                $0.createdAt != $1.createdAt
                    ? $0.createdAt < $1.createdAt
                    : $0.stableID.uuidString < $1.stableID.uuidString
            }
            return DuplicateDefinitionGroup(name: name, canonical: sorted[0], duplicates: Array(sorted.dropFirst()))
        }
    }

    /// Folds every duplicate definition into its group's canonical record:
    /// repoints any visit or Saved Place pointing at a duplicate's `stableID`,
    /// then returns the now-orphaned duplicates for the caller to delete.
    ///
    /// Never rewrites `userActivity`/`inferredActivity` text, unlike
    /// `ActivityRenameActor.mergeActivity` — the display label is already
    /// identical between duplicates by construction, so only the identity a
    /// visit or place points at needs to change, never what it says.
    @discardableResult
    static func mergeDuplicateDefinitions(in visits: [Visit], places: [SavedPlace],
                                          definitions: [ActivityDefinitionRecord]) -> [ActivityDefinitionRecord] {
        let groups = duplicateDefinitionGroups(in: definitions)
        guard !groups.isEmpty else { return [] }
        var canonicalID: [UUID: UUID] = [:]
        for group in groups {
            for duplicate in group.duplicates { canonicalID[duplicate.stableID] = group.canonical.stableID }
        }
        for visit in visits {
            if let id = visit.activityDefinitionID, let replacement = canonicalID[id] {
                visit.activityDefinitionID = replacement
            }
        }
        for place in places {
            if let id = place.activityDefinitionID, let replacement = canonicalID[id] {
                place.activityDefinitionID = replacement
            }
        }
        return groups.flatMap(\.duplicates)
    }
}

/// Runs the repair off the main actor. A whole-archive scan is exactly the shape
/// `ActivitySummaryAggregator` already keeps off the interaction path, and the
/// apply is heavier still — it rewrites thousands of rows in one transaction.
/// `Visit` never crosses back out; only the `Sendable` counts do.
@ModelActor
actor ArchiveRepairActor {
    /// Read-only. Nothing here mutates or saves, so a scan can run while the owner
    /// is still deciding whether to apply anything.
    func scan(now: Date = .now) throws -> ArchiveRepair.Findings {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        let definitions = try modelContext.fetch(FetchDescriptor<ActivityDefinitionRecord>())

        var findings = ArchiveRepair.Findings()
        let closures = ArchiveRepair.runawayClosures(in: visits, now: now)
        findings.runawayStays = closures.count
        findings.runawayStaysClosable = closures.filter { closure in
            closure.closeAt.map { $0 > closure.visit.arrival } ?? false
        }.count
        findings.runawayHours = closures.reduce(0) {
            $0 + ($1.visit.departure ?? now).timeIntervalSince($1.visit.arrival) / 3600
        }
        findings.duplicateRows = ArchiveRepair.duplicateRows(in: visits).count
        findings.nestedJourneys = ArchiveRepair.nestedJourneyRows(in: visits).count
        findings.coordinateBackfills = ArchiveRepair.coordinateBackfills(in: visits, savedPlaces: savedPlaces).count
        findings.uncoordinatedRows = visits.filter { $0.latitude == 0 && $0.longitude == 0 }.count
        findings.unmatchedPlaces = ArchiveRepair.unmatchedPlaces(in: visits, savedPlaces: savedPlaces)
        findings.unlinkedActivityRows = visits.filter { $0.activityDefinitionID == nil }.count
        findings.caseOnlyMismatches = ActivityIdentityMigration.caseOnlyMatchCount(visits: visits,
                                                                                   definitions: definitions)
        let dupDefGroups = ArchiveRepair.duplicateDefinitionGroups(in: definitions)
        findings.duplicateDefinitionNames = dupDefGroups.count
        findings.duplicateDefinitionRows = dupDefGroups.reduce(0) { $0 + $1.duplicates.count }
        return findings
    }

    /// Applies the selected steps in `Step.allCases` order and saves once. One
    /// transaction because these steps interact — closing a runaway changes which
    /// rows read as duplicates — and a partial apply would leave the archive in a
    /// state neither the old nor the new scan describes.
    func apply(steps: Set<ArchiveRepair.Step>, now: Date = .now) throws -> ArchiveRepair.Report {
        var report = ArchiveRepair.Report()
        guard !steps.isEmpty else { return report }
        var visits = try modelContext.fetch(FetchDescriptor<Visit>())

        for step in ArchiveRepair.Step.allCases where steps.contains(step) {
            try Task.checkCancellation()
            switch step {
            case .closeRunawayStays:
                let result = ArchiveRepair.closeRunawayStays(in: visits, now: now)
                report.staysClosed = result.closed
                report.stillNeedingReview = result.needingReview
            case .mergeDuplicates:
                let removable = ArchiveRepair.duplicateRows(in: visits)
                removable.forEach(modelContext.delete)
                report.duplicatesMerged = removable.count
                visits = surviving(visits, without: removable)
            case .collapseNestedJourneys:
                let removable = ArchiveRepair.nestedJourneyRows(in: visits)
                removable.forEach(modelContext.delete)
                report.journeysCollapsed = removable.count
                visits = surviving(visits, without: removable)
            case .backfillCoordinates:
                let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
                report.coordinatesAdded = ArchiveRepair.backfillCoordinates(in: visits, savedPlaces: savedPlaces)
            case .mergeDuplicateDefinitions:
                let places = try modelContext.fetch(FetchDescriptor<SavedPlace>())
                let definitions = try modelContext.fetch(FetchDescriptor<ActivityDefinitionRecord>())
                let removable = ArchiveRepair.mergeDuplicateDefinitions(in: visits, places: places,
                                                                        definitions: definitions)
                removable.forEach(modelContext.delete)
                report.definitionsMerged = removable.count
            case .linkActivities:
                // Deliberately the whole remainder rather than one page: the paged
                // launch backfill exists to keep launch responsive, and this is an
                // explicit, attended action where finishing is the point.
                report.activitiesLinked = try ActivityIdentityMigration.linkAll(context: modelContext)
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return report
    }

    /// Identity comparison, not `Equatable` — two distinct visits can hold equal
    /// field values, and deleting one must not drop the other from the working set.
    private func surviving(_ visits: [Visit], without removed: [Visit]) -> [Visit] {
        let removedIDs = Set(removed.map(\.persistentModelID))
        return visits.filter { !removedIDs.contains($0.persistentModelID) }
    }
}
