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
        // A duplicate-definition name blocking linking, so the full apply proves
        // the merge step actually unblocks the linking step that follows it.
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
        // The "Groceries" visit could only link once the duplicate definition
        // was folded — this is the regression this step exists to fix.
        #expect(report.activitiesLinked >= 1)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 3)
        let groceriesVisit = remaining.first { $0.activity == "Groceries" }
        #expect(groceriesVisit?.activityDefinitionID == older.stableID)
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
}
