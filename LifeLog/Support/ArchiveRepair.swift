import Foundation
import SwiftData

/// One-off repairs for damage the Life Cycle import left in the archive.
///
/// This is deliberately *not* a launch migration. Every step here rewrites,
/// deletes, or — `fillRoutineGaps` — invents recorded history on a judgement
/// call, and a judgement call belongs to the owner rather than to a `.task`
/// that runs before the Timeline appears —
/// `SleepSessionRepair` runs unattended precisely because folding two identical
/// HealthKit rows needs no judgement, and nothing in this file has that property.
/// So the whole pass is scan-then-apply, driven from Settings, with a backup taken
/// first, matching `JournalCompactionView`'s shape.
///
/// Every step here is additionally scoped to `source == "imported-journal"` —
/// see `isImportOnly`. This is not a convenience filter, it is the whole reason
/// the type exists: repairing damage the one-time CSV import left behind is a
/// closed, bounded problem, while anything the live app has recorded since is a
/// different question entirely — if the live pipeline is genuinely producing
/// bad data, the fix belongs in the code that records it, not in a repair pass
/// run by hand from Settings. The one exception is `mergeDuplicateDefinitions`,
/// which never touches a `Visit` at all — it corrects catalogue metadata left
/// behind by a since-fixed ID-instability bug (`ActivityCatalog.seed()`), not
/// anything the live pipeline is still doing.
///
/// The archive did briefly get this wrong: the first shipped version of
/// `duplicateRows`/`nestedJourneyRows` matched across every source, and on the
/// owner's device it deleted nine genuine `health-workout` visits — each
/// carrying its own `healthKitSampleIDs` — because they happened to share an
/// exact timestamp with an unrelated `imported-journal` row for the same walk.
/// Two different sources agreeing on one event is corroboration, not a
/// duplicate; only the same source recording the same event twice is. Every
/// analysis function here now filters to `isImportOnly` before doing anything
/// else, so a live-sourced visit can never be a candidate for deletion, rename,
/// or rewrite by any step, regardless of what it happens to resemble.
///
/// The analysis functions are pure and take `[Visit]` so they can be tested
/// without a store; `ArchiveRepairActor` owns the fetching and saving.
enum ArchiveRepair {
    /// The only source every step in this file is allowed to touch. See the
    /// type's own doc comment for why this exists and what it already prevented
    /// from happening a second time.
    static func isImportOnly(_ visit: Visit) -> Bool {
        visit.visitSource == .importedJournal
    }

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
        /// Rows still without coordinates after the backfill, and the place names
        /// that would fix the most of them.
        var uncoordinatedRows = 0
        var unmatchedPlaces: [UnmatchedPlace] = []
        /// Extra `ActivityDefinitionRecord` rows sharing a name with another active
        /// definition. See `duplicateDefinitionGroups` for why these exist and why
        /// they silently block activity linking (`ActivityIdentityMigration
        /// .linkAll`, run automatically by `ActivityLinkingCatchUp` and by the
        /// ongoing per-launch migration — neither is a step here) until merged.
        var duplicateDefinitionNames = 0
        var duplicateDefinitionRows = 0
        /// Sleep visits whose place is still a placeholder rather than the
        /// canonical `sleepPlaceName` every other sleep source already uses.
        var sleepPlaceholderRows = 0
        var walkingPlaceholderRows = 0
        /// Every stretch of unlogged time found, regardless of whether it is
        /// eligible to fill — mirrors `runawayStays` vs `runawayStaysClosable`:
        /// the total names the scale of the problem, `routineGapFillRows` names
        /// what this step can actually do about it.
        var unloggedGapCount = 0
        var unloggedGapHours: Double = 0
        var fillableGapCount = 0
        var routineGapFillRows = 0

        var isEmpty: Bool {
            runawayStays == 0 && duplicateRows == 0 && nestedJourneys == 0
                && coordinateBackfills == 0 && unloggedGapCount == 0
                && duplicateDefinitionRows == 0 && sleepPlaceholderRows == 0 && walkingPlaceholderRows == 0
        }

        /// Rows a step would touch, for the preview list. Kept beside the step
        /// definition so a new step cannot be added without a count to show.
        func count(for step: Step) -> Int {
            switch step {
            case .closeRunawayStays: runawayStaysClosable
            case .mergeDuplicates: duplicateRows
            case .collapseNestedJourneys: nestedJourneys
            case .backfillCoordinates: coordinateBackfills
            case .renameSleepPlaceholders: sleepPlaceholderRows
            case .renameWalkingPlaceholders: walkingPlaceholderRows
            case .fillRoutineGaps: routineGapFillRows
            case .mergeDuplicateDefinitions: duplicateDefinitionRows
            }
        }
    }

    /// The repairs the owner can choose between. Ordered as they must run: closing
    /// runaways first means the duplicate and journey passes see corrected spans.
    /// Linking activities to the catalogue is deliberately not one of these steps
    /// — see `ActivityLinkingCatchUp`'s doc comment for why that runs
    /// automatically instead.
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case closeRunawayStays
        case mergeDuplicates
        case collapseNestedJourneys
        case backfillCoordinates
        case renameSleepPlaceholders
        case renameWalkingPlaceholders
        case fillRoutineGaps
        case mergeDuplicateDefinitions

        var id: Self { self }

        var title: String {
            switch self {
            case .closeRunawayStays: "Close runaway stays"
            case .mergeDuplicates: "Merge duplicate records"
            case .collapseNestedJourneys: "Collapse nested journeys"
            case .backfillCoordinates: "Add coordinates from Saved Places"
            case .renameSleepPlaceholders: "Name imported sleep entries \"Sleep\""
            case .renameWalkingPlaceholders: "Name imported walking entries \"Walking\""
            case .fillRoutineGaps: "Fill evening and overnight gaps"
            case .mergeDuplicateDefinitions: "Merge duplicate activity definitions"
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
            case .renameSleepPlaceholders:
                "Sleep visits imported without a place currently show as \"Imported journal\", splitting your sleep history into two places wherever it's grouped by name. Naming them \"Sleep\" merges them with every other night."
            case .renameWalkingPlaceholders:
                "Walking visits imported without a place currently show as \"Imported journal\" too. Naming them \"Walking\" merges them with every other walk recorded by Health."
            case .fillRoutineGaps:
                "Nothing logged, midnight–7am becomes Sleeping, 7–9am and 5pm–midnight become At home, and 9am–5pm becomes Work on a weekday or At home on a weekend. Only gaps of a day or less, bordered on both sides by imported history, are filled — anything longer is left alone, since it's more likely a real absence than an unlogged evening."
            case .mergeDuplicateDefinitions:
                "Activities in your catalogue that share an identical name under different identities, most likely created by a past ID-stability bug. Every visit or Saved Place pointing at a duplicate is repointed to the earliest one before the duplicate is removed."
            }
        }

        /// Whether the step deletes rows. Drives the destructive styling and the
        /// wording of the confirmation, so a person can tell "this rewrites a
        /// field" from "this removes history" before agreeing to it.
        var deletesRows: Bool {
            switch self {
            case .mergeDuplicates, .collapseNestedJourneys, .mergeDuplicateDefinitions: true
            case .closeRunawayStays, .backfillCoordinates, .renameSleepPlaceholders,
                 .renameWalkingPlaceholders, .fillRoutineGaps: false
            }
        }

        /// Whether the step invents new visits describing time nobody
        /// recorded, rather than correcting something that already exists.
        /// Distinct from `deletesRows` — nothing is destroyed, but asserting
        /// "this is what happened" for a stretch of time this step never
        /// observed deserves its own confirmation wording, not the generic
        /// "no records are removed."
        var createsInferredRows: Bool {
            self == .fillRoutineGaps
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
        var sleepPlaceholdersRenamed = 0
        var walkingPlaceholdersRenamed = 0
        var routineGapsFilled = 0
        var definitionsMerged = 0
        var stillNeedingReview = 0

        var totalChanges: Int {
            staysClosed + duplicatesMerged + journeysCollapsed + coordinatesAdded
                + sleepPlaceholdersRenamed + walkingPlaceholdersRenamed + routineGapsFilled + definitionsMerged
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
    ///
    /// Only an `imported-journal` visit can be the runaway being closed —
    /// `isImportOnly` guards that below. Its *boundary*, though, is deliberately
    /// searched across every source: a later `automatic` visit is real evidence
    /// that an old imported stay ended, and excluding it would only shrink how
    /// often a safe boundary can be found.
    static func runawayClosures(in visits: [Visit], now: Date = .now) -> [RunawayClosure] {
        let ordered = visits
            .filter { $0.resolutionState != .superseded }
            .sorted { $0.arrival < $1.arrival }
        var closures: [RunawayClosure] = []
        for (index, visit) in ordered.enumerated() {
            guard isImportOnly(visit) else { continue }
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

    /// Case- and whitespace-insensitive, matching how every other free-text place
    /// and activity comparison in the app is done. `nil` for a placeholder, so
    /// "unnamed" never compares equal to "unnamed". Treats the imported
    /// journal's own placeholder the same as a genuinely empty name — see
    /// `Visit.isUninformativePlaceName` for why: 9,791 of the rows carrying it
    /// are journeys with no coordinates, and treating that text as a distinct
    /// place would close nearly every long stay at the first journey recorded
    /// inside it.
    private static func comparableName(_ name: String) -> String? {
        guard !Visit.isUninformativePlaceName(name) else { return nil }
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
    ///
    /// The comparison pool itself is filtered to `isImportOnly` first, not just
    /// the removal — this is what makes a cross-source pairing structurally
    /// impossible, on either side of the match. See the type's own doc comment
    /// for the shape of visit this already destroyed once, before that filter
    /// existed: a genuine `health-workout` visit sharing an exact timestamp with
    /// an unrelated `imported-journal` row for the same walk.
    static func duplicateRows(in visits: [Visit]) -> [Visit] {
        let ordered = visits
            .filter { isImportOnly($0) && $0.departure != nil && $0.resolutionState != .superseded }
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
    ///
    /// Filtered to `isImportOnly` for the same reason `duplicateRows` is: a
    /// live-sourced journey (a `motion` fragment, say) must never be treated as
    /// nested inside — or itself contain — an imported one.
    static func nestedJourneyRows(in visits: [Visit]) -> [Visit] {
        let journeys = visits
            .filter { isImportOnly($0) && $0.departure != nil && $0.resolutionState != .superseded && isJourney($0) }
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
    ///
    /// Scoped to `isImportOnly`: a live-sourced visit with zero coordinates is a
    /// tracking problem worth its own investigation, not something to paper over
    /// with an inferred position.
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
            guard isImportOnly(visit) else { return nil }
            guard visit.latitude == 0, visit.longitude == 0 else { return nil }
            guard !Visit.isUninformativePlaceName(visit.placeName) else { return nil }
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
        for visit in visits where isImportOnly(visit) && visit.latitude == 0 && visit.longitude == 0 {
            guard !Visit.isUninformativePlaceName(visit.placeName) else { continue }
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

    // MARK: - Placeholder places for a single-place activity

    /// The place name every genuine device-tracked source of this activity
    /// already uses — `health-sleep` visits carry `placeName: "Sleep"`,
    /// `health-walking` visits carry `placeName: "Walking"`. Renaming to that
    /// specific string, rather than anything else, is what makes an imported
    /// occurrence merge with every device-tracked one wherever the app groups
    /// history by place name.
    ///
    /// This exists because nothing downstream treats "Imported journal" as
    /// equivalent to "no place" once a visit reaches Insights or Timeline: both
    /// read `displayPlaceName`, which only substitutes for `needsCategorisation`
    /// rows, and an imported visit with its own `userActivity` already set does
    /// not need categorising. So "Imported journal" sits there as if it were a
    /// real, distinct place — competing with, rather than joining, every other
    /// occurrence wherever the app groups history by place (Insights' place
    /// totals, Timeline, Activities' "Top locations").
    ///
    /// Sleep and walking are the only activities this applies to: both have one
    /// genuine device source whose own placeName is already the obvious
    /// canonical value, so merging loses no information. Nothing else in the
    /// archive has that property — an unrecorded meal or errand did not happen
    /// at one repeatable place, and inventing a shared name for those would
    /// misrepresent them (see `AnnualInsights.placeRows`, which instead simply
    /// excludes an uninformative place name from that kind of grouping rather
    /// than trying to invent one).
    ///
    /// Only a visit whose *current* place is already a placeholder is touched.
    /// One genuinely recorded at a real place — an automatic callback that
    /// resolved to "8 Justin St", say — keeps that name; this never overwrites
    /// a place someone or something actually captured.
    /// Exact, case-insensitive match against the activity text — not a
    /// substring test. "Walking" must not also catch "Dog walk": that is a
    /// distinct catalog activity someone chose deliberately, not the same
    /// occurrence under a different label, and folding it in would be exactly
    /// the kind of unasked-for merge this function exists to avoid elsewhere.
    private static func placeholderVisits(in visits: [Visit], activityNamed name: String) -> [Visit] {
        visits.filter { visit in
            isImportOnly(visit) && Visit.isUninformativePlaceName(visit.placeName)
                && visit.activity.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static let sleepPlaceName = "Sleep"
    static func sleepPlaceholderVisits(in visits: [Visit]) -> [Visit] {
        placeholderVisits(in: visits, activityNamed: "Sleeping")
    }

    @discardableResult
    static func renameSleepPlaceholders(in visits: [Visit]) -> Int {
        let matches = sleepPlaceholderVisits(in: visits)
        for visit in matches { visit.placeName = sleepPlaceName }
        return matches.count
    }

    static let walkingPlaceName = "Walking"
    static func walkingPlaceholderVisits(in visits: [Visit]) -> [Visit] {
        placeholderVisits(in: visits, activityNamed: "Walking")
    }

    @discardableResult
    static func renameWalkingPlaceholders(in visits: [Visit]) -> Int {
        let matches = walkingPlaceholderVisits(in: visits)
        for visit in matches { visit.placeName = walkingPlaceName }
        return matches.count
    }

    // MARK: - Routine gap fill

    /// One stretch of time nothing at all covers, and the two visits it sits
    /// between. `before`/`after` are what decide eligibility below — a gap
    /// touching a live-tracked visit on either side is never filled, the same
    /// `isImportOnly` boundary as every other step here.
    struct UnloggedGap {
        let start: Date
        let end: Date
        let before: Visit
        let after: Visit
        var hours: TimeInterval { end.timeIntervalSince(start) / 3600 }
    }

    /// Every stretch where no visit at all covers the time, found by sweeping
    /// the archive once and tracking how far coverage currently reaches.
    ///
    /// Deliberately not `InsightsSnapshot`'s own gap detection: that also
    /// infers commute time, which has no `Visit` behind it to build a gap
    /// around here, and the day/night/work template this repair fills with is
    /// already a coarse approximation — a few minutes of an actual commute
    /// landing in "At home" instead is well inside its own margin of error.
    static func unloggedGaps(in visits: [Visit], now: Date = .now, minimumHours: Double = 0.5) -> [UnloggedGap] {
        let active = visits
            .filter { $0.resolutionState != .superseded && $0.resolutionState != .ignored }
            .filter { ($0.departure ?? now) > $0.arrival }
            .sorted { $0.arrival < $1.arrival }
        guard var coverageEndVisit = active.first else { return [] }
        var coverageEnd = coverageEndVisit.departure ?? now
        var gaps: [UnloggedGap] = []
        for visit in active.dropFirst() {
            if visit.arrival > coverageEnd {
                let hours = visit.arrival.timeIntervalSince(coverageEnd) / 3600
                if hours >= minimumHours {
                    gaps.append(UnloggedGap(start: coverageEnd, end: visit.arrival,
                                            before: coverageEndVisit, after: visit))
                }
            }
            let end = visit.departure ?? now
            if end > coverageEnd {
                coverageEnd = end
                coverageEndVisit = visit
            }
        }
        return gaps
    }

    /// A gap longer than this is far more likely to be a real absence — a
    /// trip, a hospital stay — than a night nobody logged, and this repair
    /// must never assert that a whole missing multi-day stretch was quietly
    /// spent at home. Left for manual review instead, like an unclosed
    /// runaway stay with no boundary.
    static let gapFillCap: TimeInterval = 24 * 60 * 60

    static func fillableGaps(in visits: [Visit], now: Date = .now) -> [UnloggedGap] {
        unloggedGaps(in: visits, now: now).filter { gap in
            isImportOnly(gap.before) && isImportOnly(gap.after) && gap.hours * 3600 <= gapFillCap
        }
    }

    /// One piece of a gap, labelled by the daily routine template: sleeping
    /// overnight, home either side of it, and — on a weekday — work in
    /// between. Every hour of every day a gap spans gets exactly one label;
    /// there is no unlabelled remainder within the cap `fillableGaps` applies.
    struct GapFillSegment {
        let start: Date
        let end: Date
        let activity: String
    }

    private static func isWeekday(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }

    static func templateSegments(for gap: UnloggedGap, calendar: Calendar = .current) -> [GapFillSegment] {
        var segments: [GapFillSegment] = []
        var cursor = gap.start
        while cursor < gap.end {
            let dayStart = calendar.startOfDay(for: cursor)
            let bands: [(start: Date, end: Date, activity: String)] = [
                (dayStart, dayStart.addingTimeInterval(7 * 3600), "Sleeping"),
                (dayStart.addingTimeInterval(7 * 3600), dayStart.addingTimeInterval(9 * 3600), "At home"),
                (dayStart.addingTimeInterval(9 * 3600), dayStart.addingTimeInterval(17 * 3600),
                 isWeekday(dayStart, calendar: calendar) ? "Work" : "At home"),
                (dayStart.addingTimeInterval(17 * 3600), dayStart.addingTimeInterval(24 * 3600), "At home"),
            ]
            guard let band = bands.first(where: { $0.start <= cursor && cursor < $0.end }) else { break }
            let segmentEnd = min(gap.end, band.end)
            segments.append(GapFillSegment(start: cursor, end: segmentEnd, activity: band.activity))
            cursor = segmentEnd
        }
        return segments
    }

    /// Left on every visit this step creates, so a later reader — or a revert
    /// — can tell an inferred routine fill from anything actually recorded.
    static let routineGapFillNote =
        "Filled by archive repair: inferred from your routine schedule, not recorded."

    /// Builds the fill for one gap, but does not insert it — the caller
    /// decides how the new rows join the model context, matching every other
    /// step here. Shared by the batch repair step and by a single gap's
    /// one-tap "fill as suggested" action in `UnloggedGapsView`, so the two
    /// can never disagree about what a gap becomes.
    ///
    /// A "Work" segment takes its place from the Saved Place with `homeWorkRole
    /// == .work`, and "At home" from the one with `.home`, when either exists —
    /// carrying real coordinates forward the same way `backfillCoordinates`
    /// does, rather than inventing a placeholder this repair would have to
    /// clean up again later. Without a matching Saved Place, the segment still
    /// gets a plain, honest label ("At home", "Work") instead of one more
    /// "Imported journal".
    static func fillVisits(for gap: UnloggedGap, savedPlaces: [SavedPlace],
                           calendar: Calendar = .current) -> [Visit] {
        let home = savedPlaces.first { $0.homeWorkRole == .home }
        let work = savedPlaces.first { $0.homeWorkRole == .work }
        return templateSegments(for: gap, calendar: calendar).map { segment in
            let place: SavedPlace? = switch segment.activity {
            case "Work": work
            case "At home": home
            default: nil
            }
            let placeName: String = segment.activity == "Sleeping" ? sleepPlaceName
                : (place?.name ?? segment.activity)
            return Visit(
                arrival: segment.start, departure: segment.end,
                latitude: place?.latitude ?? 0, longitude: place?.longitude ?? 0,
                placeName: placeName, inferredActivity: segment.activity,
                userActivity: segment.activity, note: routineGapFillNote,
                source: VisitSource.importedJournalRaw
            )
        }
    }

    static func routineGapFillVisits(in visits: [Visit], savedPlaces: [SavedPlace], now: Date = .now,
                                     calendar: Calendar = .current) -> [Visit] {
        fillableGaps(in: visits, now: now).flatMap { gap in
            fillVisits(for: gap, savedPlaces: savedPlaces, calendar: calendar)
        }
    }

    /// One gap, described for browsing rather than for repair — every field
    /// is a plain value so it can cross back out of `ArchiveRepairActor` to
    /// SwiftUI, unlike `UnloggedGap` itself, which holds live `Visit`
    /// references that cannot leave the actor that fetched them.
    struct GapListing: Sendable, Identifiable, Equatable {
        /// A gap's own start is unique within one scan — gaps never overlap,
        /// by construction of `unloggedGaps`.
        var id: Date { start }
        let start: Date
        let end: Date
        var hours: Double { end.timeIntervalSince(start) / 3600 }
        let beforePlaceName: String
        let beforeActivity: String
        let afterPlaceName: String
        let afterActivity: String
        let isFillable: Bool
        /// What `fillVisits` would create, as plain activity labels in order —
        /// empty when `isFillable` is false, since nothing would be created.
        let fillPreview: [String]
    }

    static func gapListings(in visits: [Visit], now: Date = .now, calendar: Calendar = .current) -> [GapListing] {
        unloggedGaps(in: visits, now: now).map { gap in
            let fillable = isImportOnly(gap.before) && isImportOnly(gap.after) && gap.hours * 3600 <= gapFillCap
            let preview = fillable ? templateSegments(for: gap, calendar: calendar).map(\.activity) : []
            return GapListing(
                start: gap.start, end: gap.end,
                beforePlaceName: gap.before.displayPlaceName, beforeActivity: gap.before.activity,
                afterPlaceName: gap.after.displayPlaceName, afterActivity: gap.after.activity,
                isFillable: fillable, fillPreview: preview
            )
        }.sorted { $0.start > $1.start }
    }

    // MARK: - Duplicate activity definitions

    /// One name shared by more than one active `ActivityDefinitionRecord`, and
    /// which of them should survive.
    ///
    /// This exists because `ActivityIdentityMigration.LabelIndex` — used by the
    /// ongoing per-launch backfill and by `ActivityLinkingCatchUp` alike —
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
        findings.sleepPlaceholderRows = ArchiveRepair.sleepPlaceholderVisits(in: visits).count
        findings.walkingPlaceholderRows = ArchiveRepair.walkingPlaceholderVisits(in: visits).count
        let allGaps = ArchiveRepair.unloggedGaps(in: visits, now: now)
        findings.unloggedGapCount = allGaps.count
        findings.unloggedGapHours = allGaps.reduce(0) { $0 + $1.hours }
        findings.fillableGapCount = ArchiveRepair.fillableGaps(in: visits, now: now).count
        findings.routineGapFillRows = ArchiveRepair.routineGapFillVisits(in: visits, savedPlaces: savedPlaces,
                                                                         now: now).count
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
            case .renameSleepPlaceholders:
                report.sleepPlaceholdersRenamed = ArchiveRepair.renameSleepPlaceholders(in: visits)
            case .renameWalkingPlaceholders:
                report.walkingPlaceholdersRenamed = ArchiveRepair.renameWalkingPlaceholders(in: visits)
            case .fillRoutineGaps:
                let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
                let created = ArchiveRepair.routineGapFillVisits(in: visits, savedPlaces: savedPlaces, now: now)
                created.forEach(modelContext.insert)
                report.routineGapsFilled = created.count
                visits += created
            case .mergeDuplicateDefinitions:
                let places = try modelContext.fetch(FetchDescriptor<SavedPlace>())
                let definitions = try modelContext.fetch(FetchDescriptor<ActivityDefinitionRecord>())
                let removable = ArchiveRepair.mergeDuplicateDefinitions(in: visits, places: places,
                                                                        definitions: definitions)
                removable.forEach(modelContext.delete)
                report.definitionsMerged = removable.count
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

    /// Every unlogged gap in the archive, for `UnloggedGapsView` — read-only,
    /// same as `scan()`, and independent of it: browsing the full list must
    /// not require having already scanned for the batch repair.
    func listGaps(now: Date = .now) throws -> [ArchiveRepair.GapListing] {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        return ArchiveRepair.gapListings(in: visits, now: now)
    }

    /// Fills exactly one gap, identified by its own start and end — a `Visit`
    /// fetched into this actor's context cannot be handed a `GapListing` built
    /// in a different one, so the gap is re-found here rather than passed in.
    /// Returns 0, changing nothing, if the gap no longer exists or is no
    /// longer eligible (something else already filled or touched it since the
    /// list was last shown).
    @discardableResult
    func fillSingleGap(start: Date, end: Date, now: Date = .now) throws -> Int {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        guard let gap = ArchiveRepair.fillableGaps(in: visits, now: now)
            .first(where: { $0.start == start && $0.end == end }) else { return 0 }
        let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        let created = ArchiveRepair.fillVisits(for: gap, savedPlaces: savedPlaces)
        created.forEach(modelContext.insert)
        try modelContext.save()
        return created.count
    }
}
