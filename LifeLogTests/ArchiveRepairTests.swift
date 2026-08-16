import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// The shapes these cover are the ones actually present in the owner's archive on
/// 2026-08-15/16: an unclosed 500+ hour "At home" stay, and gaps between visits
/// that either border the one-time CSV import or a live Health-tracked visit.
///
/// This file used to also cover duplicate records, nested journeys, coordinate
/// backfill, sleep/walking placeholder renaming, and duplicate activity
/// definitions — all six removed from `ArchiveRepair` on 2026-08-16 once a real
/// export confirmed each found zero rows, permanently: every one of them only
/// ever scanned `imported-journal`-sourced data, a pool that can never grow
/// again now that the one-time import is done. Their tests went with them;
/// `git log` has the record if that shape of damage is ever reintroduced.
struct ArchiveRepairTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(_ offsetHours: Double, _ durationHours: Double, place: String,
                       activity: String, source: String = "imported-journal") -> Visit {
        let arrival = start.addingTimeInterval(offsetHours * 3600)
        return Visit(arrival: arrival, departure: arrival.addingTimeInterval(durationHours * 3600),
                     latitude: 0, longitude: 0, placeName: place,
                     inferredActivity: activity, userActivity: activity, source: source)
    }

    // MARK: - Runaway stays

    @Test("A runaway stay closes at the next visit somewhere else")
    func closesRunawayAtDifferentPlace() throws {
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        let elsewhere = visit(30, 2, place: "Woolworths Gracemere", activity: "Groceries")

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, elsewhere])

        #expect(result.closed == 1)
        #expect(result.needingReview == 0)
        #expect(runaway.departure == elsewhere.arrival)
    }

    @Test("Movement inside a stay does not close it")
    func nestedMovementDoesNotCloseStay() throws {
        // The whole safety property: a Walking or Sleeping row inside a home stay
        // is movement within it, not evidence of leaving. Closing here would
        // invent a departure that never happened.
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        let sleep = visit(10, 8, place: "8 Justin St", activity: "Sleeping")
        let walk = visit(25, 1, place: "Imported journal", activity: "Walking")
        let originalEnd = runaway.departure

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, sleep, walk])

        #expect(result.closed == 0)
        #expect(result.needingReview == 1)
        #expect(runaway.departure == originalEnd)
    }

    @Test("A placeholder place name cannot close a runaway stay")
    func placeholderNameIsNotABoundary() throws {
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        let unnamed = visit(30, 2, place: Visit.identifyingPlaceName, activity: "Visiting")

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, unnamed])

        #expect(result.closed == 0)
        #expect(result.needingReview == 1)
    }

    @Test("A long but legitimate stay under the threshold is untouched")
    func leavesNormalStaysAlone() throws {
        let weekend = visit(0, 20, place: "8 Justin St", activity: "At home")
        let shop = visit(21, 1, place: "Woolworths Gracemere", activity: "Groceries")
        let originalEnd = weekend.departure

        let result = ArchiveRepair.closeRunawayStays(in: [weekend, shop])

        #expect(result.closed == 0)
        #expect(weekend.departure == originalEnd)
    }

    @Test("Place-name matching ignores case and surrounding whitespace")
    func boundaryMatchingIsCaseInsensitive() throws {
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        let sameePlace = visit(30, 2, place: "  8 JUSTIN ST ", activity: "Eating")

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, sameePlace])

        #expect(result.closed == 0)
        #expect(result.needingReview == 1)
    }

    // MARK: - Activity linking

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("A label differing only in case links to its definition")
    func linksCaseOnlyMismatch() throws {
        let context = try makeContext()
        let coffee = ActivityDefinitionRecord(stableID: UUID(), name: "Coffee",
                                              category: "Food & Drink", symbol: "cup.and.saucer.fill")
        context.insert(coffee)
        // 177 rows in the real archive carry this label.
        let lowercased = visit(0, 0.5, place: "Coffee Society", activity: "coffee")
        context.insert(lowercased)
        try context.save()

        let linked = try ActivityIdentityMigration.linkAll(context: context)

        #expect(linked == 1)
        #expect(lowercased.activityDefinitionID == coffee.stableID)
    }

    @Test("Labels differing by more than case stay separate")
    func doesNotFoldDiacritics() throws {
        let context = try makeContext()
        let plain = ActivityDefinitionRecord(stableID: UUID(), name: "Cafe",
                                             category: "Food & Drink", symbol: "cup.and.saucer.fill")
        let accented = ActivityDefinitionRecord(stableID: UUID(), name: "Café",
                                                category: "Food & Drink", symbol: "cup.and.saucer.fill")
        context.insert(plain)
        context.insert(accented)
        let visit = visit(0, 0.5, place: "Giddy Goat", activity: "Café")
        context.insert(visit)
        try context.save()

        _ = try ActivityIdentityMigration.linkAll(context: context)

        // Exact match wins; the two remain two activities, which is the documented
        // reason linking is not simply normalised.
        #expect(visit.activityDefinitionID == accented.stableID)
    }

    @Test("Linking finishes the whole archive rather than one page")
    func linksEveryRemainingRow() throws {
        let context = try makeContext()
        let walking = ActivityDefinitionRecord(stableID: UUID(), name: "Walking",
                                               category: "Fitness", symbol: "figure.walk")
        context.insert(walking)
        // More than `batchSize`, so a paged backfill would leave a remainder.
        for index in 0..<(ActivityIdentityMigration.batchSize + 25) {
            context.insert(visit(Double(index), 0.25, place: "Imported journal", activity: "Walking"))
        }
        try context.save()

        let linked = try ActivityIdentityMigration.linkAll(context: context)

        #expect(linked == ActivityIdentityMigration.batchSize + 25)
        let remaining = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.activityDefinitionID == nil }
        ))
        #expect(remaining.isEmpty)
    }

    // MARK: - Routine gap fill

    /// A UTC calendar, fixed regardless of the machine running the tests —
    /// `templateSegments`' weekday/weekend split must not depend on where the
    /// test happens to run.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2024-01-01 00:00 UTC, a Monday. `weekday(offsetDays:)` builds a date at
    /// a chosen number of whole days from this anchor, so a test can say
    /// "the following Saturday" without depending on the environment's
    /// calendar for the arithmetic.
    private var mondayMidnight: Date { utc.date(from: DateComponents(year: 2024, month: 1, day: 1))! }

    @Test("A gap between two visits with nothing between them is found")
    func findsAGapBetweenTwoVisits() throws {
        let first = visit(0, 1, place: "Rockhampton Grammar School", activity: "Eating")
        let second = visit(3, 1, place: "Imported journal", activity: "Walking")

        let gaps = ArchiveRepair.unloggedGaps(in: [first, second])

        #expect(gaps.count == 1)
        #expect(gaps.first?.start == first.departure)
        #expect(gaps.first?.end == second.arrival)
    }

    @Test("Overlapping or touching visits leave no gap")
    func overlappingVisitsLeaveNoGap() throws {
        let first = visit(0, 2, place: "8 Justin St", activity: "At home")
        let second = visit(1, 2, place: "8 Justin St", activity: "Sleeping")

        #expect(ArchiveRepair.unloggedGaps(in: [first, second]).isEmpty)
    }

    @Test("A gap shorter than the minimum is not reported")
    func shortGapIsNotReported() throws {
        let first = visit(0, 1, place: "Imported journal", activity: "Walking")
        let second = visit(1 + 0.1, 1, place: "Imported journal", activity: "Eating")

        #expect(ArchiveRepair.unloggedGaps(in: [first, second], minimumHours: 0.5).isEmpty)
    }

    @Test("A superseded visit does not count as coverage")
    func supersededVisitDoesNotCoverAGap() throws {
        let first = visit(0, 1, place: "Imported journal", activity: "Walking")
        let phantom = Visit(arrival: start.addingTimeInterval(1 * 3600),
                            departure: start.addingTimeInterval(3 * 3600),
                            latitude: 0, longitude: 0, placeName: "Identifying…",
                            inferredActivity: "Visiting", source: "automatic-superseded",
                            resolutionState: .superseded)
        let second = visit(3, 1, place: "Imported journal", activity: "Eating")

        let gaps = ArchiveRepair.unloggedGaps(in: [first, phantom, second])

        #expect(gaps.count == 1, "the superseded row must not be treated as covering its own span")
        #expect(gaps.first?.start == first.departure)
        #expect(gaps.first?.end == second.arrival)
    }

    @Test("A gap longer than a day is not fillable")
    func longGapIsNotFillable() throws {
        let first = visit(0, 1, place: "Imported journal", activity: "Walking")
        let second = visit(1 + 30, 1, place: "Imported journal", activity: "Eating")

        #expect(ArchiveRepair.fillableGaps(in: [first, second]).isEmpty)
        #expect(ArchiveRepair.unloggedGaps(in: [first, second]).count == 1,
               "still found and reported, just not eligible to fill")
    }

    @Test("A gap touching a live-tracked visit on either side is not fillable")
    func liveBorderedGapIsNotFillable() throws {
        let importedBefore = visit(0, 1, place: "Imported journal", activity: "Walking")
        let liveAfter = Visit(arrival: start.addingTimeInterval(4 * 3600),
                              departure: start.addingTimeInterval(5 * 3600),
                              latitude: 0, longitude: 0, placeName: "Regional Office",
                              inferredActivity: "Work", source: "automatic")

        #expect(ArchiveRepair.fillableGaps(in: [importedBefore, liveAfter]).isEmpty)

        let liveBefore = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                               latitude: 0, longitude: 0, placeName: "Regional Office",
                               inferredActivity: "Work", source: "automatic")
        let importedAfter = visit(4, 1, place: "Imported journal", activity: "Eating")

        #expect(ArchiveRepair.fillableGaps(in: [liveBefore, importedAfter]).isEmpty)
    }

    @Test("A gap bordered on both sides by a Health walking fragment is fillable")
    func walkingFragmentBorderedGapIsFillable() throws {
        let before = visit(0, 1, place: "Walking", activity: "Walking", source: "health-walking")
        let after = visit(3, 1, place: "Walking", activity: "Walking", source: "health-walking")

        #expect(ArchiveRepair.fillableGaps(in: [before, after]).count == 1)
    }

    @Test("A gap with only one side a Health walking fragment is not fillable")
    func oneSidedWalkingFragmentIsNotFillable() throws {
        let walkingBefore = visit(0, 1, place: "Walking", activity: "Walking", source: "health-walking")
        let importedAfter = visit(3, 1, place: "Imported journal", activity: "Eating")

        #expect(ArchiveRepair.fillableGaps(in: [walkingBefore, importedAfter]).isEmpty)
    }

    @Test("A gap between a walk and sleep, in either order, is fillable as a single At home segment")
    func walkingSleepTransitionFillsAsHome() throws {
        // Placed inside what would otherwise be the midnight-7am "Sleeping" band,
        // to prove the override bypasses the clock entirely.
        let gapStart = mondayMidnight.addingTimeInterval(1 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(2 * 3600)

        let walk = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        let sleep = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Sleep",
                          inferredActivity: "Sleeping", source: "health-sleep")

        let walkThenSleep = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: walk, after: sleep)
        let walkThenSleepSegments = ArchiveRepair.templateSegments(for: walkThenSleep, calendar: utc)
        #expect(walkThenSleepSegments.map(\.activity) == ["At home"])
        #expect(ArchiveRepair.fillableGaps(in: [walk, sleep]).count == 1)

        let sleepThenWalk = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: sleep, after: walk)
        let sleepThenWalkSegments = ArchiveRepair.templateSegments(for: sleepThenWalk, calendar: utc)
        #expect(sleepThenWalkSegments.map(\.activity) == ["At home"])
    }

    @Test("A gap between Work and a walking fragment, in either order, is fillable as a single Work segment")
    func workWalkingTransitionFillsAsWork() throws {
        // Placed inside what would otherwise be the 5pm-midnight "At home" band,
        // to prove the override bypasses the clock entirely.
        let gapStart = mondayMidnight.addingTimeInterval(18 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(19 * 3600)

        let work = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                         latitude: 0, longitude: 0, placeName: "Regional Office",
                         inferredActivity: "Work", source: "automatic")
        let walk = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")

        let workThenWalk = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: work, after: walk)
        #expect(ArchiveRepair.templateSegments(for: workThenWalk, calendar: utc).map(\.activity) == ["Work"])
        #expect(ArchiveRepair.fillableGaps(in: [work, walk]).count == 1)

        let walkThenWork = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: walk, after: work)
        #expect(ArchiveRepair.templateSegments(for: walkThenWork, calendar: utc).map(\.activity) == ["Work"])
    }

    @Test("A gap between Travelling and sleep, in either order, is fillable as a single At home segment")
    func travellingSleepTransitionFillsAsHome() throws {
        let gapStart = mondayMidnight.addingTimeInterval(22 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(23 * 3600)

        let travelling = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                               latitude: 0, longitude: 0, placeName: "Imported journal",
                               inferredActivity: "Travelling", source: "imported-journal")
        let sleep = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Sleep",
                          inferredActivity: "Sleeping", source: "health-sleep")

        let travelThenSleep = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: travelling, after: sleep)
        #expect(ArchiveRepair.templateSegments(for: travelThenSleep, calendar: utc).map(\.activity) == ["At home"])
        #expect(ArchiveRepair.fillableGaps(in: [travelling, sleep]).count == 1)

        let sleepThenTravel = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: sleep, after: travelling)
        #expect(ArchiveRepair.templateSegments(for: sleepThenTravel, calendar: utc).map(\.activity) == ["At home"])
    }

    @Test("A short gap entirely within one band produces a single segment")
    func shortGapWithinOneBandIsOneSegment() throws {
        // Monday 18:00 -> 19:00: entirely inside the 5pm-midnight "At home" band.
        let gapStart = mondayMidnight.addingTimeInterval(18 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(19 * 3600)
        let before = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                           latitude: 0, longitude: 0, placeName: "Imported journal",
                           inferredActivity: "Walking", source: "imported-journal")
        let after = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Imported journal",
                          inferredActivity: "Eating", source: "imported-journal")
        let gap = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: before, after: after)

        let segments = ArchiveRepair.templateSegments(for: gap, calendar: utc)

        #expect(segments.count == 1)
        #expect(segments.first?.activity == "At home")
        #expect(segments.first?.start == gapStart)
        #expect(segments.first?.end == gapEnd)
    }

    @Test("An evening-to-early-morning gap splits into home then sleep")
    func eveningIntoSleepSplitsCorrectly() throws {
        let gapStart = mondayMidnight.addingTimeInterval(17 * 3600 + 15 * 60) // Mon 17:15
        let gapEnd = mondayMidnight.addingTimeInterval(26 * 3600 + 33 * 60)   // Tue 02:33
        let before = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                           latitude: 0, longitude: 0, placeName: "Rockhampton Grammar School",
                           inferredActivity: "At home", source: "imported-journal")
        let after = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Rockhampton Grammar School",
                          inferredActivity: "Sleeping", source: "imported-journal")
        let gap = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: before, after: after)

        let segments = ArchiveRepair.templateSegments(for: gap, calendar: utc)

        #expect(segments.map(\.activity) == ["At home", "Sleeping"])
        #expect(segments[0].start == gapStart)
        #expect(segments[0].end == mondayMidnight.addingTimeInterval(24 * 3600))
        #expect(segments[1].start == mondayMidnight.addingTimeInterval(24 * 3600))
        #expect(segments[1].end == gapEnd)
    }

    @Test("9am-5pm is Work on a weekday and At home on a weekend")
    func nineToFiveDependsOnWeekday() throws {
        let mondayGap = ArchiveRepair.UnloggedGap(
            start: mondayMidnight.addingTimeInterval(10 * 3600), end: mondayMidnight.addingTimeInterval(11 * 3600),
            before: visit(0, 1, place: "Imported journal", activity: "Walking"),
            after: visit(0, 1, place: "Imported journal", activity: "Walking")
        )
        let saturdayMidnight = mondayMidnight.addingTimeInterval(5 * 24 * 3600)
        let saturdayGap = ArchiveRepair.UnloggedGap(
            start: saturdayMidnight.addingTimeInterval(10 * 3600), end: saturdayMidnight.addingTimeInterval(11 * 3600),
            before: visit(0, 1, place: "Imported journal", activity: "Walking"),
            after: visit(0, 1, place: "Imported journal", activity: "Walking")
        )

        #expect(ArchiveRepair.templateSegments(for: mondayGap, calendar: utc).map(\.activity) == ["Work"])
        #expect(ArchiveRepair.templateSegments(for: saturdayGap, calendar: utc).map(\.activity) == ["At home"])
    }

    @Test("A full-day gap tiles all four bands with no remainder")
    func fullDayGapTilesEveryBand() throws {
        let gap = ArchiveRepair.UnloggedGap(
            start: mondayMidnight, end: mondayMidnight.addingTimeInterval(24 * 3600),
            before: visit(0, 1, place: "Imported journal", activity: "Walking"),
            after: visit(0, 1, place: "Imported journal", activity: "Walking")
        )

        let segments = ArchiveRepair.templateSegments(for: gap, calendar: utc)

        #expect(segments.map(\.activity) == ["Sleeping", "At home", "Work", "At home"])
        #expect(segments.first?.start == mondayMidnight)
        #expect(segments.last?.end == mondayMidnight.addingTimeInterval(24 * 3600))
        // No gap between consecutive segments, and none overlap.
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test("Created visits are imported-journal, carry the fill note, and link to Saved Place roles")
    func createdVisitsCarryTheRightFieldsAndCoordinates() throws {
        let home = SavedPlace(name: "Home", latitude: -23.445, longitude: 150.452, radius: 100,
                              defaultActivity: "At home")
        home.role = SavedPlaceRole.home.rawValue
        // Monday 16:00 -> 18:00: 16:00-17:00 falls in the weekday Work band,
        // 17:00-18:00 in the At home band, so this one gap guarantees both.
        let gapStart = mondayMidnight.addingTimeInterval(16 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(18 * 3600)
        let before = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                           latitude: 0, longitude: 0, placeName: "Imported journal",
                           inferredActivity: "Walking", source: "imported-journal")
        let after = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Imported journal",
                          inferredActivity: "Eating", source: "imported-journal")

        let created = ArchiveRepair.routineGapFillVisits(in: [before, after], savedPlaces: [home], calendar: utc)

        #expect(!created.isEmpty)
        for visit in created {
            #expect(visit.source == "imported-journal")
            #expect(visit.note == ArchiveRepair.routineGapFillNote)
        }
        let homeSegment = created.first { $0.inferredActivity == "At home" }
        #expect(homeSegment?.placeName == "Home")
        #expect(homeSegment?.latitude == home.latitude)
        #expect(homeSegment?.longitude == home.longitude)
        let workSegment = created.first { $0.inferredActivity == "Work" }
        #expect(workSegment?.placeName == "Work", "no Work-role Saved Place exists, so it falls back to a plain label")
        #expect(workSegment?.latitude == 0)
    }

    @Test("A Sleeping segment is always named Sleep, matching the sleep-placeholder rename")
    func sleepingSegmentUsesTheCanonicalSleepName() throws {
        // Monday 23:00 -> 01:00: crosses straight into the midnight-7am band.
        let gapStart = mondayMidnight.addingTimeInterval(23 * 3600)
        let gapEnd = mondayMidnight.addingTimeInterval(25 * 3600)
        let before = Visit(arrival: gapStart.addingTimeInterval(-3600), departure: gapStart,
                           latitude: 0, longitude: 0, placeName: "Imported journal",
                           inferredActivity: "Walking", source: "imported-journal")
        let after = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600),
                          latitude: 0, longitude: 0, placeName: "Imported journal",
                          inferredActivity: "Eating", source: "imported-journal")

        let created = ArchiveRepair.routineGapFillVisits(in: [before, after], savedPlaces: [], calendar: utc)

        let sleepSegment = created.first { $0.inferredActivity == "Sleeping" }
        #expect(sleepSegment?.placeName == ArchiveRepair.sleepPlaceName)
    }

    @Test("Scan surfaces fillable gaps and applying creates the visits")
    func scanAndApplyResolveRoutineGaps() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let before = visit(0, 1, place: "Imported journal", activity: "Walking")
        let after = visit(1 + 9, 1, place: "Imported journal", activity: "Eating")
        context.insert(before)
        context.insert(after)
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let findings = try await actor.scan()
        #expect(findings.unloggedGapCount == 1)
        #expect(findings.fillableGapCount == 1)
        #expect(findings.routineGapFillRows > 0)

        let report = try await actor.apply(steps: [.fillRoutineGaps])
        #expect(report.routineGapsFilled == findings.routineGapFillRows)

        let allVisits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(allVisits.count == 2 + report.routineGapsFilled)

        let rescanned = try await actor.scan()
        #expect(rescanned.unloggedGapCount == 0, "the archive is now fully covered")
    }

    @Test("Gap listings mark eligibility and preview correctly, newest first")
    func gapListingsReportEligibilityAndOrder() throws {
        // Two gaps back to back, with no gap between them: older -> olderAfter
        // (fillable), then liveBefore -> newerAfter (not, since liveBefore is
        // automatic-sourced). liveBefore starts exactly where olderAfter ends,
        // so there is no accidental third gap between the two pairs.
        let older = visit(0, 1, place: "Imported journal", activity: "Walking")
        let olderAfter = visit(1 + 9, 1, place: "Imported journal", activity: "Eating")
        let liveBefore = Visit(arrival: olderAfter.departure!, departure: olderAfter.departure!.addingTimeInterval(3600),
                               latitude: 0, longitude: 0, placeName: "Regional Office",
                               inferredActivity: "Work", source: "automatic")
        let newerAfter = Visit(arrival: liveBefore.departure!.addingTimeInterval(3600),
                               departure: liveBefore.departure!.addingTimeInterval(7200),
                               latitude: 0, longitude: 0, placeName: "Imported journal",
                               inferredActivity: "Eating", source: "imported-journal")

        let listings = ArchiveRepair.gapListings(in: [older, olderAfter, liveBefore, newerAfter])

        #expect(listings.count == 2)
        // Newest first.
        #expect(listings[0].start > listings[1].start)
        let fillable = listings.first { $0.beforeActivity == "Walking" }
        #expect(fillable?.isFillable == true)
        #expect(fillable?.fillPreview.isEmpty == false)
        let liveBordered = listings.first { $0.beforeActivity == "Work" }
        #expect(liveBordered?.isFillable == false)
        #expect(liveBordered?.fillPreview.isEmpty == true)
    }

    @Test("Filling a single gap by its start and end creates only that gap's visits")
    func fillSingleGapCreatesOnlyThatGap() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let firstBefore = visit(0, 1, place: "Imported journal", activity: "Walking")
        let firstAfter = visit(1 + 9, 1, place: "Imported journal", activity: "Eating")
        // Starts exactly where `firstAfter` ends, so there is no accidental
        // third gap between the two pairs this test cares about.
        let secondBefore = Visit(arrival: firstAfter.departure!, departure: firstAfter.departure!.addingTimeInterval(3600),
                                 latitude: 0, longitude: 0, placeName: "Imported journal",
                                 inferredActivity: "Walking", source: "imported-journal")
        let secondAfter = Visit(arrival: secondBefore.departure!.addingTimeInterval(9 * 3600),
                                departure: secondBefore.departure!.addingTimeInterval(10 * 3600),
                                latitude: 0, longitude: 0, placeName: "Imported journal",
                                inferredActivity: "Eating", source: "imported-journal")
        [firstBefore, firstAfter, secondBefore, secondAfter].forEach(context.insert)
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let before = try await actor.listGaps()
        #expect(before.count == 2)
        let target = before.first { $0.start == firstBefore.departure }!

        let created = try await actor.fillSingleGap(start: target.start, end: target.end)

        #expect(created > 0)
        let after = try await actor.listGaps()
        #expect(after.count == 1, "only the targeted gap was filled")
        #expect(after.first?.start == secondBefore.departure)
    }

    @Test("Filling a gap that no longer exists creates nothing and does not throw")
    func fillingAStaleGapIsANoOp() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(visit(0, 1, place: "Imported journal", activity: "Walking"))
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let created = try await actor.fillSingleGap(start: start, end: start.addingTimeInterval(999_999))

        #expect(created == 0)
        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1, "no phantom visit was inserted for a gap that was never real")
    }

    // MARK: - Actor

    @Test("Scan reports counts without changing anything")
    func scanIsReadOnly() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        context.insert(runaway)
        context.insert(visit(30, 2, place: "Woolworths Gracemere", activity: "Groceries"))
        try context.save()
        let originalEnd = runaway.departure

        let findings = try await ArchiveRepairActor(modelContainer: container).scan()

        #expect(findings.runawayStays == 1)
        #expect(findings.runawayStaysClosable == 1)
        #expect(runaway.departure == originalEnd)
    }

    @Test("Applying only the selected step leaves the other untouched")
    func appliesOnlySelectedSteps() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        context.insert(runaway)
        context.insert(visit(30, 2, place: "Woolworths Gracemere", activity: "Groceries"))
        // Also fillable, but `fillRoutineGaps` is deliberately not selected below.
        context.insert(visit(60, 1, place: "Imported journal", activity: "Walking"))
        context.insert(visit(70, 1, place: "Imported journal", activity: "Eating"))
        try context.save()

        let report = try await ArchiveRepairActor(modelContainer: container)
            .apply(steps: [.closeRunawayStays])

        #expect(report.staysClosed == 1)
        #expect(report.routineGapsFilled == 0)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 4, "no gap-fill visits were inserted")
    }

    @Test("A full apply closes runaways and fills gaps together")
    func appliesEveryStepTogether() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(visit(0, 500, place: "8 Justin St", activity: "At home"))
        // Inside the runaway's span, so it can actually act as the boundary.
        context.insert(visit(300, 2, place: "Woolworths Gracemere", activity: "Groceries"))
        context.insert(visit(700, 1, place: "Imported journal", activity: "Walking"))
        context.insert(visit(710, 1, place: "Imported journal", activity: "Eating"))
        try context.save()

        let report = try await ArchiveRepairActor(modelContainer: container)
            .apply(steps: Set(ArchiveRepair.Step.allCases))

        #expect(report.staysClosed == 1)
        #expect(report.routineGapsFilled > 0)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 4 + report.routineGapsFilled)
    }

    // MARK: - Source scoping

    /// Every one of these reproduces a real bug: the first shipped version of
    /// this file matched and rewrote visits across every source, and on the
    /// owner's device it deleted nine genuine `health-workout` visits -- each
    /// carrying its own `healthKitSampleIDs` -- because they happened to share
    /// an exact timestamp with an unrelated `imported-journal` row for the same
    /// walk. Two different sources agreeing on one event is corroboration, not
    /// a duplicate. `closeRunawayStays` must still treat a live-sourced visit
    /// as untouchable, full stop, regardless of what it happens to resemble.

    @Test("A live runaway stay is never closed by this repair")
    func liveRunawayStayIsNeverClosed() throws {
        let runaway = Visit(arrival: start, departure: start.addingTimeInterval(500 * 3600),
                            latitude: 0, longitude: 0, placeName: "8 Justin St",
                            inferredActivity: "At home", source: "automatic")
        let boundary = visit(30, 2, place: "Woolworths Gracemere", activity: "Groceries")
        let originalEnd = runaway.departure

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, boundary])

        #expect(result.closed == 0)
        #expect(runaway.departure == originalEnd)
    }

    @Test("A runaway import can still close against a boundary from a live source")
    func importedRunawayClosesAgainstALiveBoundary() throws {
        // The one place a live-sourced visit *should* participate: proving an
        // old imported stay ended. Only the row being closed is restricted to
        // imported-journal, not the evidence that it ended.
        let runaway = visit(0, 500, place: "8 Justin St", activity: "At home")
        let liveBoundary = Visit(arrival: start.addingTimeInterval(30 * 3600),
                                 departure: start.addingTimeInterval(32 * 3600),
                                 latitude: 0, longitude: 0, placeName: "Regional Office",
                                 inferredActivity: "Work", source: "automatic")

        let result = ArchiveRepair.closeRunawayStays(in: [runaway, liveBoundary])

        #expect(result.closed == 1)
        #expect(runaway.departure == liveBoundary.arrival)
    }
}
