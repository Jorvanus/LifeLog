import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// The shapes these cover are the ones actually present in the owner's archive on
/// 2026-08-15, not invented cases: a 567-hour "At home" stay at 8 Justin St with
/// later visits nested inside it, ~1,000 near-identical rows one second apart,
/// 2,957 journeys wholly inside another journey, 25,624 rows with no coordinates,
/// and 177 visits labelled `coffee` against a catalogue entry named `Coffee`.
struct ArchiveRepairTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

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

    // MARK: - Duplicates

    @Test("Near-identical rows collapse to the earliest")
    func mergesNearIdenticalRows() throws {
        let first = visit(0, 0.25, place: "Imported journal", activity: "Travelling")
        // One second apart at both ends, the exact shape the import produced.
        let second = Visit(arrival: first.arrival.addingTimeInterval(1),
                           departure: first.departure!.addingTimeInterval(1),
                           latitude: 0, longitude: 0, placeName: "Imported journal",
                           inferredActivity: "Travelling", userActivity: "Travelling",
                           source: "imported-journal")

        let removable = ArchiveRepair.duplicateRows(in: [first, second])

        #expect(removable.count == 1)
        #expect(removable.first === second)
    }

    @Test("Three copies of one event leave one survivor")
    func collapsesClusterToOneSurvivor() throws {
        let base = visit(0, 0.25, place: "Imported journal", activity: "Travelling")
        let copies = (1...2).map { offset in
            Visit(arrival: base.arrival.addingTimeInterval(Double(offset)),
                  departure: base.departure!.addingTimeInterval(Double(offset)),
                  latitude: 0, longitude: 0, placeName: "Imported journal",
                  inferredActivity: "Travelling", userActivity: "Travelling",
                  source: "imported-journal")
        }

        let removable = ArchiveRepair.duplicateRows(in: [base] + copies)

        #expect(removable.count == 2)
        #expect(!removable.contains { $0 === base })
    }

    @Test("Two consecutive short journeys are not duplicates")
    func keepsConsecutiveDistinctJourneys() throws {
        let first = visit(0, 0.25, place: "Imported journal", activity: "Travelling")
        let second = visit(0.5, 0.25, place: "Imported journal", activity: "Travelling")

        #expect(ArchiveRepair.duplicateRows(in: [first, second]).isEmpty)
    }

    @Test("Rows sharing a span but not an activity are kept")
    func keepsDifferentActivitiesAtSameTime() throws {
        let home = visit(0, 8, place: "8 Justin St", activity: "At home")
        let sleep = visit(0, 8, place: "8 Justin St", activity: "Sleeping")

        #expect(ArchiveRepair.duplicateRows(in: [home, sleep]).isEmpty)
    }

    // MARK: - Nested journeys

    @Test("A journey inside a journey is collapsed")
    func collapsesNestedJourney() throws {
        let outer = visit(0, 1, place: "Imported journal", activity: "Travelling")
        let inner = visit(0.25, 0.5, place: "Imported journal", activity: "Travelling")

        let removable = ArchiveRepair.nestedJourneyRows(in: [outer, inner])

        #expect(removable.count == 1)
        #expect(removable.first === inner)
    }

    @Test("A shop stop inside a journey is real and survives")
    func keepsNonJourneyNestedInJourney() throws {
        let outer = visit(0, 2, place: "Imported journal", activity: "Travelling")
        let stop = visit(0.5, 0.5, place: "Woolworths Gracemere", activity: "Groceries")

        #expect(ArchiveRepair.nestedJourneyRows(in: [outer, stop]).isEmpty)
    }

    @Test("Journeys that merely overlap are both kept")
    func keepsPartiallyOverlappingJourneys() throws {
        let first = visit(0, 1, place: "Imported journal", activity: "Travelling")
        let second = visit(0.5, 1, place: "Imported journal", activity: "Travelling")

        #expect(ArchiveRepair.nestedJourneyRows(in: [first, second]).isEmpty)
    }

    // MARK: - Coordinate backfill

    @Test("Coordinates come from a Saved Place matching the visit's name")
    func backfillsFromSavedPlace() throws {
        let home = SavedPlace(name: "8 Justin St", latitude: -23.4455, longitude: 150.4523,
                              radius: 100, defaultActivity: "At home")
        let imported = visit(0, 8, place: "8 justin st", activity: "At home")

        let added = ArchiveRepair.backfillCoordinates(in: [imported], savedPlaces: [home])

        #expect(added == 1)
        #expect(imported.latitude == home.latitude)
        #expect(imported.longitude == home.longitude)
        // Marked as inferred, so it can never be mistaken for a recorded fix.
        #expect(imported.placeProvenance == .nameBackfill)
        #expect(imported.placeProvenance?.isInferredCoordinate == true)
    }

    @Test("A visit that already has coordinates is left alone")
    func doesNotOverwriteRecordedCoordinates() throws {
        let home = SavedPlace(name: "8 Justin St", latitude: -23.4455, longitude: 150.4523,
                              radius: 100, defaultActivity: "At home")
        let recorded = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                             latitude: -23.9, longitude: 150.9, placeName: "8 Justin St",
                             inferredActivity: "At home", source: "automatic")

        #expect(ArchiveRepair.backfillCoordinates(in: [recorded], savedPlaces: [home]) == 0)
        #expect(recorded.latitude == -23.9)
    }

    @Test("Two Saved Places sharing a name produce no coordinates")
    func ambiguousNameIsNotBackfilled() throws {
        let first = SavedPlace(name: "Work", latitude: -23.37, longitude: 150.51,
                               radius: 100, defaultActivity: "Work")
        let second = SavedPlace(name: "work", latitude: -23.38, longitude: 150.52,
                                radius: 100, defaultActivity: "Work")
        let imported = visit(0, 8, place: "Work", activity: "Work")

        #expect(ArchiveRepair.backfillCoordinates(in: [imported], savedPlaces: [first, second]) == 0)
        #expect(imported.latitude == 0)
    }

    @Test("Frequently used place names with no Saved Place are reported")
    func reportsPlacesWorthSaving() throws {
        // The real shape: the Saved Place is called "Home", nine years of journal
        // call the same address "8 Justin St", so almost nothing matches.
        let home = SavedPlace(name: "Home", latitude: -23.4455, longitude: 150.4523,
                              radius: 100, defaultActivity: "At home")
        let visits = (0..<5).map { visit(Double($0), 1, place: "8 Justin St", activity: "At home") }
            + [visit(10, 1, place: "Home", activity: "At home")]
            + (0..<2).map { visit(Double(20 + $0), 1, place: "Regional Office", activity: "Work") }

        let unmatched = ArchiveRepair.unmatchedPlaces(in: visits, savedPlaces: [home])

        #expect(unmatched.first?.name == "8 Justin St")
        #expect(unmatched.first?.visits == 5)
        // "Home" already has a Saved Place, so it is not something to add.
        #expect(!unmatched.contains { $0.name == "Home" })
        #expect(unmatched.contains { $0.name == "Regional Office" && $0.visits == 2 })
    }

    @Test("A backfill can be reverted, leaving hand-corrected rows alone")
    func revertsOnlyInferredCoordinates() throws {
        let home = SavedPlace(name: "8 Justin St", latitude: -23.4455, longitude: 150.4523,
                              radius: 100, defaultActivity: "At home")
        let inferred = visit(0, 8, place: "8 Justin St", activity: "At home")
        ArchiveRepair.backfillCoordinates(in: [inferred], savedPlaces: [home])
        let corrected = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                              latitude: -23.9, longitude: 150.9, placeName: "8 Justin St",
                              inferredActivity: "At home", source: "manual",
                              placeFieldProvenance: PlaceFieldProvenance.manualRaw)

        let reverted = ArchiveRepair.revertCoordinateBackfill(in: [inferred, corrected])

        #expect(reverted == 1)
        #expect(inferred.latitude == 0)
        #expect(corrected.latitude == -23.9)
    }

    // MARK: - Activity linking

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

    // MARK: - Sleep placeholder places

    @Test("A sleep visit named after the import placeholder is renamed to Sleep")
    func renamesImportedJournalSleepVisit() throws {
        let sleeping = visit(0, 8, place: "Imported journal", activity: "Sleeping")

        let renamed = ArchiveRepair.renameSleepPlaceholders(in: [sleeping])

        #expect(renamed == 1)
        #expect(sleeping.placeName == "Sleep")
    }

    @Test("A sleep visit already named Sleep is not touched")
    func leavesAlreadyNamedSleepVisitsAlone() throws {
        let sleeping = visit(0, 8, place: "Sleep", activity: "Sleeping")

        #expect(ArchiveRepair.renameSleepPlaceholders(in: [sleeping]) == 0)
        #expect(sleeping.placeName == "Sleep")
    }

    @Test("A sleep visit recorded at a real place keeps that place")
    func keepsARealPlaceForASleepVisit() throws {
        // The whole safety property: only a placeholder is overwritten, never a
        // place something or someone actually captured.
        let sleeping = visit(0, 8, place: "8 Justin St", activity: "Sleeping", source: "automatic")

        #expect(ArchiveRepair.renameSleepPlaceholders(in: [sleeping]) == 0)
        #expect(sleeping.placeName == "8 Justin St")
    }

    @Test("A non-sleep visit at the import placeholder is not renamed")
    func leavesNonSleepImportedJournalVisitsAlone() throws {
        let travelling = visit(0, 1, place: "Imported journal", activity: "Travelling")

        #expect(ArchiveRepair.renameSleepPlaceholders(in: [travelling]) == 0)
        #expect(travelling.placeName == "Imported journal")
    }

    @Test("Sleep placeholder matching is case-insensitive on both fields")
    func sleepPlaceholderMatchingIsCaseInsensitive() throws {
        let sleeping = Visit(arrival: start, departure: start.addingTimeInterval(8 * 3600),
                             latitude: 0, longitude: 0, placeName: "imported JOURNAL",
                             inferredActivity: "SLEEPING", source: "imported-journal")

        #expect(ArchiveRepair.renameSleepPlaceholders(in: [sleeping]) == 1)
        #expect(sleeping.placeName == "Sleep")
    }

    // MARK: - Walking placeholder places

    @Test("A walking visit named after the import placeholder is renamed to Walking")
    func renamesImportedJournalWalkingVisit() throws {
        let walking = visit(0, 1, place: "Imported journal", activity: "Walking")

        let renamed = ArchiveRepair.renameWalkingPlaceholders(in: [walking])

        #expect(renamed == 1)
        #expect(walking.placeName == "Walking")
    }

    @Test("A walking visit recorded at a real place keeps that place")
    func keepsARealPlaceForAWalkingVisit() throws {
        let walking = visit(0, 1, place: "Cedric Archer Park", activity: "Walking", source: "automatic")

        #expect(ArchiveRepair.renameWalkingPlaceholders(in: [walking]) == 0)
        #expect(walking.placeName == "Cedric Archer Park")
    }

    @Test("A dog walk is a distinct activity and is not folded into Walking")
    func dogWalkIsNotRenamedToWalking() throws {
        // "walk" is a substring of "Dog walk" too -- this is the case that rules
        // out substring matching and requires an exact activity-name match.
        let dogWalk = visit(0, 1, place: "Imported journal", activity: "Dog walk")

        #expect(ArchiveRepair.renameWalkingPlaceholders(in: [dogWalk]) == 0)
        #expect(dogWalk.placeName == "Imported journal")
    }

    @Test("Sleep and walking placeholders are independent")
    func sleepAndWalkingPlaceholdersDoNotCrossMatch() throws {
        let sleeping = visit(0, 8, place: "Imported journal", activity: "Sleeping")
        let walking = visit(9, 1, place: "Imported journal", activity: "Walking")

        #expect(ArchiveRepair.renameWalkingPlaceholders(in: [sleeping, walking]) == 1)
        #expect(sleeping.placeName == "Imported journal", "the walking pass must not touch a sleep visit")
        #expect(walking.placeName == "Walking")
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

    // MARK: - Duplicate activity definitions

    @Test("Two definitions with the exact same name are grouped, oldest first")
    func groupsDuplicateDefinitionsByExactName() throws {
        let older = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start)
        let newer = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start.addingTimeInterval(60))

        let groups = ArchiveRepair.duplicateDefinitionGroups(in: [newer, older])

        #expect(groups.count == 1)
        #expect(groups.first?.canonical.stableID == older.stableID)
        #expect(groups.first?.duplicates.map(\.stableID) == [newer.stableID])
    }

    @Test("A name held by only one active definition is not a duplicate")
    func singleDefinitionIsNotADuplicate() throws {
        let solo = ActivityDefinitionRecord(stableID: UUID(), name: "Work", category: "Work",
                                            symbol: "briefcase.fill")
        #expect(ArchiveRepair.duplicateDefinitionGroups(in: [solo]).isEmpty)
    }

    @Test("An inactive definition does not create a false duplicate")
    func inactiveDefinitionIsExcludedFromDuplicateDetection() throws {
        let active = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                              symbol: "dumbbell.fill", isActive: true)
        let retired = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                               symbol: "dumbbell.fill", isActive: false)
        #expect(ArchiveRepair.duplicateDefinitionGroups(in: [active, retired]).isEmpty)
    }

    @Test("Merging a duplicate definition repoints visits and places to the canonical one")
    func mergeDuplicateDefinitionsRepointsReferences() throws {
        let canonical = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                                  symbol: "dumbbell.fill", createdAt: start)
        let duplicate = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                                  symbol: "dumbbell.fill", createdAt: start.addingTimeInterval(60))
        let onCanonical = visit(0, 1, place: "CrossFit CQ", activity: "Gym")
        onCanonical.activityDefinitionID = canonical.stableID
        let onDuplicate = visit(1, 1, place: "CrossFit CQ", activity: "Gym")
        onDuplicate.activityDefinitionID = duplicate.stableID
        let unrelated = visit(2, 1, place: "Woolworths Gracemere", activity: "Groceries")
        let place = SavedPlace(name: "CrossFit CQ", latitude: 0, longitude: 0,
                               radius: 100, defaultActivity: "Gym")
        place.activityDefinitionID = duplicate.stableID

        let removed = ArchiveRepair.mergeDuplicateDefinitions(
            in: [onCanonical, onDuplicate, unrelated], places: [place],
            definitions: [canonical, duplicate]
        )

        #expect(removed.map(\.stableID) == [duplicate.stableID])
        #expect(onCanonical.activityDefinitionID == canonical.stableID, "already-canonical rows are untouched")
        #expect(onDuplicate.activityDefinitionID == canonical.stableID, "repointed to the survivor")
        #expect(unrelated.activityDefinitionID == nil, "a row pointing at neither definition is untouched")
        #expect(place.activityDefinitionID == canonical.stableID)
    }

    @Test("Merging duplicates unblocks linking for the name they shared")
    func mergingDuplicatesUnblocksLinking() throws {
        // The exact failure mode this exists for: two definitions named "Gym"
        // make the name ambiguous, so `linkAll` refuses every visit labelled
        // "Gym" until the duplicate is folded into one identity.
        let context = try makeContext()
        let older = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start)
        let newer = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        let gymVisit = visit(0, 1, place: "CrossFit CQ", activity: "Gym")
        context.insert(gymVisit)
        try context.save()

        #expect(try ActivityIdentityMigration.linkAll(context: context) == 0,
               "an ambiguous name must not link while the duplicate exists")

        let removed = ArchiveRepair.mergeDuplicateDefinitions(in: [gymVisit], places: [],
                                                               definitions: [older, newer])
        removed.forEach(context.delete)
        try context.save()

        #expect(try ActivityIdentityMigration.linkAll(context: context) == 1)
        #expect(gymVisit.activityDefinitionID == older.stableID)
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

    @Test("Applying only the selected step leaves the others untouched")
    func appliesOnlySelectedSteps() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let outer = visit(0, 1, place: "Imported journal", activity: "Travelling")
        let inner = visit(0.25, 0.5, place: "Imported journal", activity: "Travelling")
        context.insert(outer)
        context.insert(inner)
        try context.save()

        let report = try await ArchiveRepairActor(modelContainer: container)
            .apply(steps: [.backfillCoordinates])

        #expect(report.journeysCollapsed == 0)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 2)
    }

    @Test("A full apply closes, merges and collapses in one transaction")
    func appliesEveryStepTogether() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(SavedPlace(name: "8 Justin St", latitude: -23.4455, longitude: 150.4523,
                                  radius: 100, defaultActivity: "At home"))
        context.insert(visit(0, 500, place: "8 Justin St", activity: "At home"))
        // Inside the runaway's span, so it can actually act as the boundary.
        context.insert(visit(300, 2, place: "Woolworths Gracemere", activity: "Groceries"))
        let outer = visit(700, 1, place: "Imported journal", activity: "Travelling")
        context.insert(outer)
        context.insert(visit(700.25, 0.5, place: "Imported journal", activity: "Travelling"))
        let older = ActivityDefinitionRecord(stableID: UUID(), name: "Groceries", category: "Shopping",
                                             symbol: "cart.fill", createdAt: start)
        let newer = ActivityDefinitionRecord(stableID: UUID(), name: "Groceries", category: "Shopping",
                                             symbol: "cart.fill", createdAt: start.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        try context.save()

        let report = try await ArchiveRepairActor(modelContainer: container)
            .apply(steps: Set(ArchiveRepair.Step.allCases))

        #expect(report.staysClosed == 1)
        #expect(report.journeysCollapsed == 1)
        #expect(report.coordinatesAdded == 1)
        #expect(report.definitionsMerged == 1)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 3)
    }

    @Test("Scan surfaces duplicate activity definitions and applying merges them")
    func scanAndApplyResolveDuplicateDefinitions() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let older = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start)
        let newer = ActivityDefinitionRecord(stableID: UUID(), name: "Gym", category: "Fitness",
                                             symbol: "dumbbell.fill", createdAt: start.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let findings = try await actor.scan()
        #expect(findings.duplicateDefinitionNames == 1)
        #expect(findings.duplicateDefinitionRows == 1)

        let report = try await actor.apply(steps: [.mergeDuplicateDefinitions])
        #expect(report.definitionsMerged == 1)

        let remainingDefs = try ModelContext(container).fetch(FetchDescriptor<ActivityDefinitionRecord>())
        #expect(remainingDefs.map(\.stableID) == [older.stableID])

        let rescanned = try await actor.scan()
        #expect(rescanned.duplicateDefinitionRows == 0)
    }

    @Test("Scan surfaces sleep placeholders and applying renames them")
    func scanAndApplyResolveSleepPlaceholders() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(visit(0, 8, place: "Imported journal", activity: "Sleeping"))
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let findings = try await actor.scan()
        #expect(findings.sleepPlaceholderRows == 1)

        let report = try await actor.apply(steps: [.renameSleepPlaceholders])
        #expect(report.sleepPlaceholdersRenamed == 1)

        let rescanned = try await actor.scan()
        #expect(rescanned.sleepPlaceholderRows == 0)
    }

    @Test("Scan surfaces walking placeholders and applying renames them")
    func scanAndApplyResolveWalkingPlaceholders() async throws {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(visit(0, 1, place: "Imported journal", activity: "Walking"))
        try context.save()

        let actor = ArchiveRepairActor(modelContainer: container)
        let findings = try await actor.scan()
        #expect(findings.walkingPlaceholderRows == 1)

        let report = try await actor.apply(steps: [.renameWalkingPlaceholders])
        #expect(report.walkingPlaceholdersRenamed == 1)

        let rescanned = try await actor.scan()
        #expect(rescanned.walkingPlaceholderRows == 0)
    }

    // MARK: - Source scoping

    /// Every one of these reproduces a real bug: the first shipped version of
    /// this file matched and rewrote visits across every source, and on the
    /// owner's device it deleted nine genuine `health-workout` visits -- each
    /// carrying its own `healthKitSampleIDs` -- because they happened to share
    /// an exact timestamp with an unrelated `imported-journal` row for the same
    /// walk. Two different sources agreeing on one event is corroboration, not
    /// a duplicate. Every analysis function must treat a live-sourced visit as
    /// untouchable, full stop, regardless of what it happens to resemble.

    @Test("A live HealthKit workout is never matched as a duplicate of an imported row")
    func healthWorkoutSurvivesAnIdenticalImportedRow() throws {
        // The exact shape that was destroyed: same activity, same arrival, same
        // departure, different source.
        let imported = visit(0, 0.5, place: "Imported journal", activity: "Walking")
        let workout = Visit(arrival: imported.arrival, departure: imported.departure!,
                            latitude: 0, longitude: 0, placeName: "Walking workout",
                            inferredActivity: "Walking", source: "health-workout",
                            healthKitSampleIDs: [UUID()])

        let removable = ArchiveRepair.duplicateRows(in: [imported, workout])

        #expect(removable.isEmpty, "neither row may be removed -- a live source can never be a duplicate candidate")
    }

    @Test("A live automatic journey is never collapsed as nested inside an imported one")
    func automaticJourneySurvivesNestingInAnImportedOne() throws {
        let outer = visit(0, 2, place: "Imported journal", activity: "Travelling")
        let inner = Visit(arrival: start.addingTimeInterval(0.5 * 3600),
                          departure: start.addingTimeInterval(1 * 3600),
                          latitude: 0, longitude: 0, placeName: "",
                          inferredActivity: "Travelling", source: "automatic")

        #expect(ArchiveRepair.nestedJourneyRows(in: [outer, inner]).isEmpty)
    }

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

    @Test("A live visit at a Saved Place name still gets no inferred coordinates")
    func liveVisitIsNeverCoordinateBackfilled() throws {
        let home = SavedPlace(name: "8 Justin St", latitude: -23.4455, longitude: 150.4523,
                              radius: 100, defaultActivity: "At home")
        let liveVisit = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                              latitude: 0, longitude: 0, placeName: "8 Justin St",
                              inferredActivity: "At home", source: "manual")

        #expect(ArchiveRepair.backfillCoordinates(in: [liveVisit], savedPlaces: [home]) == 0)
        #expect(liveVisit.latitude == 0)
    }

    @Test("A live sleep visit is never renamed even with a placeholder place")
    func liveSleepVisitIsNeverRenamed() throws {
        let liveSleep = Visit(arrival: start, departure: start.addingTimeInterval(8 * 3600),
                              latitude: 0, longitude: 0, placeName: "Identifying…",
                              inferredActivity: "Sleeping", source: "manual")

        #expect(ArchiveRepair.renameSleepPlaceholders(in: [liveSleep]) == 0)
        #expect(liveSleep.placeName == "Identifying…")
    }

    @Test("A live walking visit is never renamed even with a placeholder place")
    func liveWalkingVisitIsNeverRenamed() throws {
        let liveWalk = Visit(arrival: start, departure: start.addingTimeInterval(3600),
                             latitude: 0, longitude: 0, placeName: "Identifying…",
                             inferredActivity: "Walking", source: "automatic")

        #expect(ArchiveRepair.renameWalkingPlaceholders(in: [liveWalk]) == 0)
        #expect(liveWalk.placeName == "Identifying…")
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
