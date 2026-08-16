import Foundation
import SwiftData

/// Repairs for archive damage that cannot be fixed unattended.
///
/// This is deliberately *not* a launch migration. Every step here rewrites or
/// — `fillRoutineGaps` — invents recorded history on a judgement call, and a
/// judgement call belongs to the owner rather than to a `.task` that runs
/// before the Timeline appears — `SleepSessionRepair` runs unattended
/// precisely because folding two identical HealthKit rows needs no judgement,
/// and nothing in this file has that property. So the whole pass is
/// scan-then-apply, driven from Settings, with a backup taken first, matching
/// `JournalCompactionView`'s shape.
///
/// This file used to hold eight steps. Six of them — merging duplicate
/// records, collapsing nested journeys, backfilling coordinates, renaming
/// sleep and walking placeholders, and merging duplicate activity
/// definitions — existed solely to repair damage the one-time Life Cycle CSV
/// import left behind, all scoped to `source == "imported-journal"`. That
/// import happened once; no visit can ever get that source again, so once
/// every row of that fixed, closed pool was clean, those six steps could
/// never find anything again. Confirmed against a real archive on
/// 2026-08-16 — all six at zero — and removed rather than left as permanent
/// dead code a person has to keep reading past. Their tests, doc comments,
/// and `git log` are the record of what they did and why, if this shape of
/// damage is ever reintroduced by a future import or restore.
///
/// The two that remain are different in kind. `closeRunawayStays` still scans
/// `isImportOnly` visits only — its pool is exactly as closed as the six that
/// were removed — but it reports every row it *cannot* close as well as the
/// ones it can, which is a genuinely durable signal: those rows have no
/// boundary in the data and need a person's judgement, not a rerun. And
/// `fillRoutineGaps` is not import-scoped at all any more — see
/// `gapBordersEligibleForFill` — it also resolves gaps between *live*
/// Health-tracked visits, a pool that keeps growing every day the app is
/// used, so unlike the other six its count is not expected to stay at zero.
///
/// The archive did briefly get the cross-source matching wrong: the first
/// shipped version of the now-removed `duplicateRows`/`nestedJourneyRows`
/// matched across every source, and on the owner's device it deleted nine
/// genuine `health-workout` visits — each carrying its own
/// `healthKitSampleIDs` — because they happened to share an exact timestamp
/// with an unrelated `imported-journal` row for the same walk. Two different
/// sources agreeing on one event is corroboration, not a duplicate; only the
/// same source recording the same event twice is. `isImportOnly` existed to
/// make that structurally impossible, and `closeRunawayStays` still honours
/// it for the row being closed (its boundary search is deliberately wider —
/// see that function's own doc comment).
///
/// The analysis functions are pure and take `[Visit]` so they can be tested
/// without a store; `ArchiveRepairActor` owns the fetching and saving.
enum ArchiveRepair {
    /// The only source `closeRunawayStays` closes. See the type's own doc
    /// comment for why this scope exists and what it already prevented from
    /// happening a second time.
    static func isImportOnly(_ visit: Visit) -> Bool {
        visit.visitSource == .importedJournal
    }

    /// The one deliberate crack in the `isImportOnly` boundary above: Health's
    /// walking detector regularly fragments a single stay-at-a-place into a
    /// burst of short `.healthWalking` visits with gaps between them — not
    /// missed history, but the *same* stay getting reported in pieces. A gap
    /// bordered on both sides by one of these fragments is therefore not "an
    /// unlogged evening" in the sense the rest of this file means; it is
    /// almost certainly still whatever place both fragments were recorded at.
    /// Confirmed against a real archive: every sampled instance fell inside
    /// the owner's own routine hours (home or work), never inside what would
    /// read as a multi-hour walk. Routed through the same routine-schedule
    /// template as an import-bordered gap, never through anything that would
    /// label it "Walking" — this fixes the fragmentation, it does not
    /// legitimise the phantom gap as movement.
    static func isWalkingFragment(_ visit: Visit) -> Bool {
        visit.visitSource == .healthWalking
    }

    /// A Health-tracked sleep visit. Paired with `isWalkingFragment` below to
    /// catch the other shape of gap the same fragmentation produces: a walk
    /// ending shortly before bed, or one starting shortly after waking, with
    /// nothing logged in between. That gap is not a stretch of actual sleep —
    /// the `Sleeping` visit itself already covers whenever sleep was
    /// recorded — and it is not a walk either; it is the ordinary business of
    /// being home before or after each. See `isWalkingSleepTransition`.
    static func isSleepFragment(_ visit: Visit) -> Bool {
        visit.visitSource == .healthSleep
    }

    /// A gap between a Health walking fragment and a Health sleep visit, in
    /// either order. Unlike `isWalkingFragment`-bordered gaps, which still go
    /// through the full day/night template, this shape is filled as a single
    /// "At home" visit regardless of the clock — see `templateSegments`.
    static func isWalkingSleepTransition(_ before: Visit, _ after: Visit) -> Bool {
        (isWalkingFragment(before) && isSleepFragment(after))
            || (isSleepFragment(before) && isWalkingFragment(after))
    }

    /// Exact, case-insensitive match against the activity text — not a
    /// substring test, so a person's own "Working from home" or similar
    /// stays a distinct choice.
    static func isWorkVisit(_ visit: Visit) -> Bool {
        visit.activity.caseInsensitiveCompare("Work") == .orderedSame
    }

    /// A gap between a Work visit and a Health walking fragment, in either
    /// order — most likely a walk taken during the working day (a coffee
    /// run, a walk to another building) that Health split off as its own
    /// fragment rather than folding back into the stay either side of it.
    /// Filled as a single "Work" visit for the whole gap, the same
    /// clock-independent treatment `isWalkingSleepTransition` gives its own
    /// pair — this is still the workday, not a stretch of actual walking and
    /// not whatever the day/night template's band would otherwise say.
    static func isWorkWalkingTransition(_ before: Visit, _ after: Visit) -> Bool {
        (isWorkVisit(before) && isWalkingFragment(after))
            || (isWalkingFragment(before) && isWorkVisit(after))
    }

    /// A gap between a journey (`isJourney` — Travelling, In transit,
    /// Commuting) and a Health sleep visit, in either order: travel recorded
    /// right up against a night's sleep, with nothing logged for the time
    /// between arriving home and actually going to bed, or between waking
    /// and setting off again. That gap is home time, not more travel and not
    /// sleep the `Sleeping` visit itself hasn't already covered. Filled as a
    /// single "At home" visit, same as `isWalkingSleepTransition`.
    static func isTravellingSleepTransition(_ before: Visit, _ after: Visit) -> Bool {
        (isJourney(before) && isSleepFragment(after))
            || (isSleepFragment(before) && isJourney(after))
    }

    /// The labels the archive uses for time spent moving. Matched by name
    /// rather than by category so a person who recategorises "Travelling"
    /// does not silently change what `isTravellingSleepTransition` matches.
    private static let journeyLabels: Set<String> = ["travelling", "in transit", "commuting"]

    private static func isJourney(_ visit: Visit) -> Bool {
        journeyLabels.contains(visit.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Whether a gap's two bordering visits qualify it for the routine
    /// template fill: both sides of the one-time import, both sides a Health
    /// walking fragment, or one of the fixed-label transitions above. See
    /// each transition's own doc comment for why it's let through; nothing
    /// else broadens this.
    static func gapBordersEligibleForFill(_ before: Visit, _ after: Visit) -> Bool {
        (isImportOnly(before) && isImportOnly(after))
            || (isWalkingFragment(before) && isWalkingFragment(after))
            || isWalkingSleepTransition(before, after)
            || isWorkWalkingTransition(before, after)
            || isTravellingSleepTransition(before, after)
    }

    /// A stay longer than this is treated as never having been closed rather than
    /// as a genuinely long stay. Chosen because the archive's real runaways start
    /// at several days (the worst is 23.6 days) while legitimate long stays — a
    /// weekend at home, a hospital admission — sit well under it, and because a
    /// visit that spans more than a day already breaks every per-day aggregate
    /// that buckets by `arrival`.
    static let runawayThreshold: TimeInterval = 24 * 60 * 60

    // MARK: - Findings

    /// What a scan found, in counts only. `Sendable` so it can cross back out of
    /// `ArchiveRepairActor` to SwiftUI; `Visit` never leaves the actor.
    struct Findings: Sendable, Equatable {
        var runawayStays = 0
        var runawayStaysClosable = 0
        var runawayHours: Double = 0
        /// Every stretch of unlogged time found, regardless of whether it is
        /// eligible to fill — mirrors `runawayStays` vs `runawayStaysClosable`:
        /// the total names the scale of the problem, `routineGapFillRows` names
        /// what this step can actually do about it.
        var unloggedGapCount = 0
        var unloggedGapHours: Double = 0
        var fillableGapCount = 0
        var routineGapFillRows = 0

        var isEmpty: Bool {
            runawayStays == 0 && unloggedGapCount == 0
        }

        /// Rows a step would touch, for the preview list. Kept beside the step
        /// definition so a new step cannot be added without a count to show.
        func count(for step: Step) -> Int {
            switch step {
            case .closeRunawayStays: runawayStaysClosable
            case .fillRoutineGaps: routineGapFillRows
            }
        }
    }

    /// The repairs the owner can choose between. Linking activities to the
    /// catalogue is deliberately not one of these steps — see
    /// `ActivityLinkingCatchUp`'s doc comment for why that runs automatically
    /// instead.
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case closeRunawayStays
        case fillRoutineGaps

        var id: Self { self }

        var title: String {
            switch self {
            case .closeRunawayStays: "Close runaway stays"
            case .fillRoutineGaps: "Fill evening and overnight gaps"
            }
        }

        var detail: String {
            switch self {
            case .closeRunawayStays:
                "Stays over 24 hours that were never closed and swallowed later visits. Each is closed where a visit at a different place begins; anything with no such boundary is left alone for you to edit."
            case .fillRoutineGaps:
                "Nothing logged, midnight–7am becomes Sleeping, 7–9am and 5pm–midnight become At home, and 9am–5pm becomes Work on a weekday or At home on a weekend. Only gaps of a day or less are filled — bordered on both sides by imported history, by a Health-tracked walk either side of a gap that's really the same stay reported in fragments, or by one of a few fixed-label pairs (a walk and a night's sleep, a walk and Work, travelling and a night's sleep) that always fill the same way rather than following the clock. Anything longer, or bordering anything else live-tracked, is left alone."
            }
        }

        /// Whether the step deletes rows. Drives the destructive styling and the
        /// wording of the confirmation, so a person can tell "this rewrites a
        /// field" from "this removes history" before agreeing to it.
        var deletesRows: Bool { false }

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
        var routineGapsFilled = 0
        var stillNeedingReview = 0

        var totalChanges: Int { staysClosed + routineGapsFilled }
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

    // MARK: - Routine gap fill

    /// One stretch of time nothing at all covers, and the two visits it sits
    /// between. `before`/`after` are what decide eligibility below — see
    /// `gapBordersEligibleForFill` for the two shapes of border this fills.
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
            gapBordersEligibleForFill(gap.before, gap.after) && gap.hours * 3600 <= gapFillCap
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

    /// The activity a gap's border shape dictates on its own, independent of
    /// the clock — `nil` when the gap should instead be tiled against the
    /// day/night bands below. Each of these transitions is a fragment being
    /// rejoined to what it was actually part of, not a real stretch of
    /// unlogged time, so the day/night template's band for that hour would be
    /// beside the point even where it happens to agree.
    private static func fixedTransitionLabel(for gap: UnloggedGap) -> String? {
        if isWalkingSleepTransition(gap.before, gap.after) { return "At home" }
        if isWorkWalkingTransition(gap.before, gap.after) { return "Work" }
        if isTravellingSleepTransition(gap.before, gap.after) { return "At home" }
        return nil
    }

    static func templateSegments(for gap: UnloggedGap, calendar: Calendar = .current) -> [GapFillSegment] {
        if let label = fixedTransitionLabel(for: gap) {
            return [GapFillSegment(start: gap.start, end: gap.end, activity: label)]
        }
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

    static let sleepPlaceName = "Sleep"

    /// Builds the fill for one gap, but does not insert it — the caller
    /// decides how the new rows join the model context, matching every other
    /// step here. Shared by the batch repair step and by a single gap's
    /// one-tap "fill as suggested" action in `UnloggedGapsView`, so the two
    /// can never disagree about what a gap becomes.
    ///
    /// A "Work" segment takes its place from the Saved Place with `homeWorkRole
    /// == .work`, and "At home" from the one with `.home`, when either exists —
    /// carrying real coordinates forward rather than inventing a placeholder
    /// this repair would have to clean up again later. Without a matching
    /// Saved Place, the segment still gets a plain, honest label ("At home",
    /// "Work") instead of one more "Imported journal".
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
            let fillable = gapBordersEligibleForFill(gap.before, gap.after) && gap.hours * 3600 <= gapFillCap
            let preview = fillable ? templateSegments(for: gap, calendar: calendar).map(\.activity) : []
            return GapListing(
                start: gap.start, end: gap.end,
                beforePlaceName: gap.before.displayPlaceName, beforeActivity: gap.before.activity,
                afterPlaceName: gap.after.displayPlaceName, afterActivity: gap.after.activity,
                isFillable: fillable, fillPreview: preview
            )
        }.sorted { $0.start > $1.start }
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

        var findings = ArchiveRepair.Findings()
        let closures = ArchiveRepair.runawayClosures(in: visits, now: now)
        findings.runawayStays = closures.count
        findings.runawayStaysClosable = closures.filter { closure in
            closure.closeAt.map { $0 > closure.visit.arrival } ?? false
        }.count
        findings.runawayHours = closures.reduce(0) {
            $0 + ($1.visit.departure ?? now).timeIntervalSince($1.visit.arrival) / 3600
        }
        let allGaps = ArchiveRepair.unloggedGaps(in: visits, now: now)
        findings.unloggedGapCount = allGaps.count
        findings.unloggedGapHours = allGaps.reduce(0) { $0 + $1.hours }
        findings.fillableGapCount = ArchiveRepair.fillableGaps(in: visits, now: now).count
        findings.routineGapFillRows = ArchiveRepair.routineGapFillVisits(in: visits, savedPlaces: savedPlaces,
                                                                         now: now).count
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
            case .fillRoutineGaps:
                let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
                let created = ArchiveRepair.routineGapFillVisits(in: visits, savedPlaces: savedPlaces, now: now)
                created.forEach(modelContext.insert)
                report.routineGapsFilled = created.count
                visits += created
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return report
    }

    /// Every unlogged gap in the archive, for `UnloggedGapsView` — read-only,
    /// same as `scan()`, and independent of it: browsing the full list must
    /// not require having already scanned for the batch repair.
    ///
    /// `scope` is `nil` by default so every existing caller keeps seeing gaps
    /// across all sources, exactly as before. Ask LifeLog passes its own
    /// selected scope: excluding a source can open gaps that would not exist
    /// under "all history", so the result must respect the same scope the rest
    /// of the answer does rather than silently mixing sources back in.
    func listGaps(now: Date = .now, scope: InsightsScope? = nil) throws -> [ArchiveRepair.GapListing] {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        let scoped = scope.map { s in visits.filter(s.includes) } ?? visits
        return ArchiveRepair.gapListings(in: scoped, now: now)
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
