import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct SavedPlaceLearningTests {
    /// Shadowed by a local of the same name in the older tests here, which each
    /// declare their own; new tests use this one.
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A corrected located visit creates a reusable geofence")
    func createsSavedPlace() throws {
        let context = try makeContext()
        let visit = Visit(
            arrival: .now,
            departure: .now.addingTimeInterval(1_800),
            latitude: -27.4698,
            longitude: 153.0251,
            placeName: "Corner Café",
            inferredActivity: "Visiting",
            userActivity: "Eating"
        )
        context.insert(visit)

        let result = try SavedPlaceLearning.upsert(
            from: visit,
            previousPlaceName: "Unknown place",
            context: context
        )
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(result?.change == .created)
        #expect(places.count == 1)
        #expect(places.first?.name == "Corner Café")
        #expect(places.first?.radius == 100)
        #expect(places.first?.defaultActivity == "Eating")
        #expect(visit.recognitionConfidence == "learned")
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        #expect(corrections.count == 1)
        #expect(corrections.first?.newPlaceName == "Corner Café")
        #expect(corrections.first?.newConfidence == "learned")
    }

    @Test("Automatic Maps learning waits for three corroborating visits")
    func automaticLearningRequiresCorroboration() throws {
        let context = try makeContext()
        let candidate = PlaceSuggestion(name: "Corner Cafe", latitude: -27.4698, longitude: 153.0251,
                                        suggestedActivity: "Eating", distance: 12,
                                        mapsIdentifier: "corner-cafe")

        for index in 0..<SavedPlaceLearning.automaticCorroborationRequired {
            let visit = Visit(arrival: base.addingTimeInterval(Double(index) * 86_400),
                              latitude: -27.4698, longitude: 153.0251,
                              placeName: candidate.name, inferredActivity: candidate.suggestedActivity,
                              source: "automatic", mapsIdentifier: candidate.mapsIdentifier)
            context.insert(visit)
            visit.locationResolutionCandidates = .init(chosen: candidate, rejected: [])
            let learned = try SavedPlaceLearning.learnAutomatically(from: candidate, visit: visit, context: context)
            #expect((learned != nil) == (index == SavedPlaceLearning.automaticCorroborationRequired - 1))
        }

        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.count == 1)
        #expect(places.first?.name == "Corner Cafe")
    }

    @Test("Large venue alternatives coalesce into one automatic place cluster")
    func automaticLearningClustersVenueAliases() throws {
        let context = try makeContext()
        let mall = PlaceSuggestion(name: "Rivergate Shopping Centre", latitude: -27.4698, longitude: 153.0251,
                                   suggestedActivity: "Shopping", distance: 45,
                                   mapsIdentifier: "rivergate-mall", mapsCategory: "shoppingMall")

        for index in 0..<SavedPlaceLearning.automaticCorroborationRequired {
            let entrance = PlaceSuggestion(name: "Rivergate Entrance \(index + 1)",
                                           latitude: -27.4698 + Double(index) * 0.0006,
                                           longitude: 153.0251, suggestedActivity: "Shopping", distance: 8,
                                           mapsIdentifier: "rivergate-entrance-\(index)")
            let visit = Visit(arrival: base.addingTimeInterval(Double(index) * 86_400),
                              latitude: entrance.latitude, longitude: entrance.longitude,
                              placeName: entrance.name, inferredActivity: "Shopping", source: "automatic",
                              mapsIdentifier: entrance.mapsIdentifier)
            context.insert(visit)
            // Maps selected different entrance POIs, but showed the shared centre as
            // an alternative each time. The learning record makes that alias visible.
            visit.locationResolutionCandidates = .init(chosen: entrance, rejected: [mall])
            _ = try SavedPlaceLearning.learnAutomatically(from: entrance, visit: visit, context: context)
        }

        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.count == 1)
        #expect(places.first?.name == mall.name)
        #expect(places.first?.radius == 250)
    }

    @Test("Renaming a visit updates the matching geofence without duplicating it")
    func updatesExistingSavedPlace() throws {
        let context = try makeContext()
        let saved = SavedPlace(
            name: "Old Office",
            latitude: -27.4698,
            longitude: 153.0251,
            radius: 90,
            defaultActivity: "Working"
        )
        context.insert(saved)
        try context.save()

        let visit = Visit(
            arrival: .now,
            latitude: -27.4697,
            longitude: 153.0252,
            placeName: "Design Studio",
            inferredActivity: "Working",
            userActivity: "Collaborating"
        )
        context.insert(visit)

        let result = try SavedPlaceLearning.upsert(
            from: visit,
            previousPlaceName: "Old Office",
            context: context
        )
        let places = try context.fetch(FetchDescriptor<SavedPlace>())

        #expect(result?.change == .updated)
        #expect(places.count == 1)
        #expect(places.first?.name == "Design Studio")
        #expect(places.first?.radius == 100)
        #expect(places.first?.defaultActivity == "Collaborating")
    }

    @Test("Editing a saved place updates matching location history")
    func appliesSavedPlaceToHistory() throws {
        let context = try makeContext()
        let saved = SavedPlace(
            name: "Home",
            latitude: -27.4698,
            longitude: 153.0251,
            radius: 125,
            defaultActivity: "At home"
        )
        let current = Visit(
            arrival: .now,
            latitude: -27.4697,
            longitude: 153.0252,
            placeName: "Unknown place",
            inferredActivity: "Visiting",
            source: "automatic"
        )
        let distant = Visit(
            arrival: .now.addingTimeInterval(-3_600),
            departure: .now.addingTimeInterval(-1_800),
            latitude: -27.5,
            longitude: 153.1,
            placeName: "Another place",
            inferredActivity: "Visiting",
            source: "automatic"
        )
        context.insert(saved)
        context.insert(current)
        context.insert(distant)
        let competing = PlaceSuggestion(name: "Nearby Cafe", latitude: -27.4696, longitude: 153.0253,
                                        suggestedActivity: "Eating", distance: 25)
        current.placeSuggestions = [competing]

        try SavedPlaceLearning.apply(saved, context: context)
        try context.save()

        #expect(current.placeName == "Home")
        #expect(current.activity == "At home")
        #expect(current.needsCategorisation == false)
        #expect(current.placeSuggestions == [competing])
        #expect(distant.placeName == "Another place")
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        #expect(corrections.count == 1)
        #expect(corrections.first?.reason == "Saved Place learned")
    }

    @Test("A bulk activity change skips entries the person confirmed themselves")
    func bulkChangeKeepsConfirmedEntries() throws {
        let context = try makeContext()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func entry(hour: Int, activity: String, confidence: String) -> Visit {
            let arrival = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_800),
                              latitude: 0, longitude: 0, placeName: "Gracemere Shopping World",
                              inferredActivity: activity, userActivity: activity,
                              source: "imported-journal", recognitionConfidence: confidence)
            context.insert(visit)
            return visit
        }
        let importedA = entry(hour: 13, activity: "Eating", confidence: "imported")
        let importedB = entry(hour: 14, activity: "Eating", confidence: "imported")
        let confirmed = entry(hour: 15, activity: "Eating", confidence: "confirmed")
        let otherBand = entry(hour: 3, activity: "Eating", confidence: "imported")
        try context.save()

        // Mirrors PlaceHistoryDetail.apply: scope by band, never touch "confirmed".
        let name = "Gracemere Shopping World"
        let matching = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName == name }
        ))
        var changed = 0
        for visit in matching where PlaceTimeBand.day.contains(visit.arrival)
            && visit.recognitionConfidence != "confirmed" {
            visit.userActivity = "Shopping"
            changed += 1
        }
        try context.save()

        #expect(changed == 2)
        #expect(importedA.activity == "Shopping")
        #expect(importedB.activity == "Shopping")
        // The person's own choice survives.
        #expect(confirmed.activity == "Eating")
        // A different time of day is untouched.
        #expect(otherBand.activity == "Eating")
    }

    @Test("Renaming an activity carries its visits across, matching case-insensitively")
    func renamingAnActivityUpdatesItsVisits() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func visit(_ offset: Int, inferred: String, user: String?) -> Visit {
            let arrival = base.addingTimeInterval(TimeInterval(offset))
            let v = Visit(arrival: arrival, departure: arrival.addingTimeInterval(600),
                          latitude: 0, longitude: 0, placeName: "Regional Office",
                          inferredActivity: inferred, userActivity: user,
                          source: "imported-journal", recognitionConfidence: "imported")
            context.insert(v)
            return v
        }
        let explicit = visit(0, inferred: "Visiting", user: "Work")
        let inferredOnly = visit(700, inferred: "Work", user: nil)
        let differentCase = visit(1_400, inferred: "Visiting", user: "wOrK")
        let unrelated = visit(2_100, inferred: "Visiting", user: "Eating")
        try context.save()

        let changed = try ActivityCatalog.renameActivity(from: "Work", to: "Job", context: context)

        #expect(changed == 3)
        #expect(explicit.userActivity == "Job")
        // The inferred value has to move too, or a visit with no explicit choice keeps
        // wording the catalogue no longer knows and Insights counts it as Other.
        #expect(inferredOnly.inferredActivity == "Job")
        #expect(differentCase.userActivity == "Job")
        #expect(unrelated.userActivity == "Eating")
    }

    @Test("A rename that changes nothing is a no-op")
    func renamingToTheSameNameChangesNothing() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let v = Visit(arrival: base, departure: base.addingTimeInterval(600),
                      latitude: 0, longitude: 0, placeName: "Regional Office",
                      inferredActivity: "Visiting", userActivity: "Work",
                      source: "imported-journal")
        context.insert(v)
        try context.save()

        #expect(try ActivityCatalog.renameActivity(from: "Work", to: "work", context: context) == 0)
        #expect(try ActivityCatalog.renameActivity(from: "Work", to: "   ", context: context) == 0)
        #expect(try ActivityCatalog.renameActivity(from: "", to: "Job", context: context) == 0)
        #expect(v.userActivity == "Work")
    }

    @Test("Merging Work into Working leaves one entry and one label")
    func mergingIntoAnExistingActivityLeavesNoDuplicate() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<3 {
            let arrival = base.addingTimeInterval(TimeInterval(offset * 600))
            context.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(300),
                                 latitude: 0, longitude: 0, placeName: "Regional Office",
                                 inferredActivity: "Visiting", userActivity: "Work",
                                 source: "imported-journal"))
        }
        try context.save()

        // The catalogue state after adopting "Work" while the seeded "Working" remains.
        var catalogue = [
            ActivityDefinition(name: "Working", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
        ]
        let renamed = catalogue[1]

        // Merging is the rename plus dropping the entry that was renamed away.
        let moved = try ActivityCatalog.renameActivity(from: renamed.name, to: "Working", context: context)
        catalogue.removeAll { $0.id == renamed.id }

        #expect(moved == 3)
        #expect(catalogue.count == 1, "A merge must not leave two entries with the same name")
        #expect(catalogue.first?.name == "Working")
        let visits = try context.fetch(FetchDescriptor<Visit>())
        #expect(visits.allSatisfy { $0.activity == "Working" })
        // Grouping survives because the surviving entry still carries the category.
        #expect(ActivityCatalog.preferredLabel(for: "Working", in: catalogue) == "Working")
    }

    @Test("The seeded Working entry is merged into an adopted Work, visits and all")
    func mergesSeededWorkingIntoAdoptedWork() throws {
        let context = try makeContext()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<3 {
            context.insert(Visit(arrival: base.addingTimeInterval(Double(offset) * 3600),
                                 departure: base.addingTimeInterval(Double(offset) * 3600 + 1800),
                                 latitude: -23.38, longitude: 150.52, placeName: "atWork Australia",
                                 inferredActivity: "Working", userActivity: "Working",
                                 source: "imported-journal"))
        }
        try context.save()

        try ActivityCatalog.withStorage(defaults) {
            // The real catalogue: "Work" adopted from history, seeded "Working" still there.
            ActivityCatalog.save([
                ActivityDefinition(name: "Working", category: "Work", symbol: "briefcase.fill"),
                ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
            ])

            let moved = try ActivityCatalog.mergeWorkingIntoWork(context: context)
            #expect(moved == 3, "the visits move with the label rather than being stranded on it")

            let catalogue = ActivityCatalog.load()
            #expect(catalogue.filter { $0.category == "Work" }.count == 1, "no duplicate Work entries")
            #expect(catalogue.contains { $0.name == "Work" })
            #expect(!catalogue.contains { $0.name == "Working" })
            #expect(ActivityCatalog.preferredLabel(for: "Working", in: catalogue) == "Work")

            // Runs once: an entry named back to "Working" afterwards is left alone.
            ActivityCatalog.save(catalogue + [ActivityDefinition(name: "Working", category: "Work",
                                                                 symbol: "briefcase.fill")])
            #expect(try ActivityCatalog.mergeWorkingIntoWork(context: context) == 0)
            #expect(ActivityCatalog.load().contains { $0.name == "Working" })
        }

        let visits = try context.fetch(FetchDescriptor<Visit>())
        #expect(visits.allSatisfy { $0.activity == "Work" })
    }

    @Test("LocationRecorder loads and populates saved place cache when connected")
    func locationRecorderSavedPlaceCache() throws {
        let context = try makeContext()
        let place = SavedPlace(name: "Home Base", latitude: -27.4698, longitude: 153.0251, radius: 100, defaultActivity: "Home")
        context.insert(place)
        try context.save()

        let recorder = LocationRecorder()
        recorder.connect(context)
        #expect(recorder.savedPlaceCache.count == 1)
        #expect(recorder.savedPlaceCache.first?.name == "Home Base")
    }

    @Test("SavedPlaceLearning preview and applyIgnored use spatial bounding box filtering")
    func previewAndApplyIgnoredUseBoundingBox() throws {
        let context = try makeContext()
        let place = SavedPlace(name: "Studio", latitude: -27.4698, longitude: 153.0251, radius: 100, defaultActivity: "Working")
        context.insert(place)

        let nearby = Visit(arrival: .now, departure: .now.addingTimeInterval(1800),
                           latitude: -27.4698, longitude: 153.0251, placeName: "Studio",
                           inferredActivity: "Working", source: "automatic")
        let distant = Visit(arrival: .now, departure: .now.addingTimeInterval(1800),
                            latitude: -33.8688, longitude: 151.2093, placeName: "Sydney Harbour",
                            inferredActivity: "Visiting", source: "automatic")
        context.insert(nearby)
        context.insert(distant)
        try context.save()

        let preview = try SavedPlaceLearning.preview(place, context: context)
        #expect(preview.matchingVisits == 1)

        let updatedCount = try SavedPlaceLearning.applyIgnored(true, to: place, context: context)
        #expect(updatedCount == 1)
        #expect(nearby.isIgnored == true)
        #expect(distant.isIgnored == false)
    }

    // MARK: - Place history lookup

    // The editor's "activities used here before" and "N prior check-ins" used to be
    // filtered out of a query holding the whole archive. These cover the scoped fetch
    // that replaced it — in particular that narrowing in the store with a `contains`
    // predicate does not widen what counts as the same place.

    @Test("Prior visits to a place are found by name, ignoring case and accents")
    func findsPriorVisitsAtTheSamePlace() throws {
        let context = try makeContext()
        let editing = makeVisit(placeName: "Corner Café", activity: "Eating", in: context)
        makeVisit(placeName: "corner cafe", activity: "Coffee", in: context)
        makeVisit(placeName: "CORNER CAFÉ", activity: "Lunch", in: context)
        makeVisit(placeName: "Star Liquor", activity: "Shopping", in: context)
        try context.save()

        let found = try PlaceVisitLookup.visits(named: "Corner Café",
                                                excluding: editing.persistentModelID,
                                                context: context)

        #expect(found.count == 2)
        #expect(Set(found.map(\.activity)) == ["Coffee", "Lunch"])
    }

    @Test("A place whose name merely contains the typed one is a different place")
    func doesNotMatchOnSubstring() throws {
        let context = try makeContext()
        makeVisit(placeName: "Star Liquor Warehouse", activity: "Shopping", in: context)
        makeVisit(placeName: "Star Liquor", activity: "Shopping", in: context)
        try context.save()

        let found = try PlaceVisitLookup.visits(named: "Star Liquor", excluding: nil, context: context)

        #expect(found.count == 1)
        #expect(found.first?.placeName == "Star Liquor")
    }

    @Test("A placeholder name has no history of its own")
    func placeholderNamesReturnNothing() throws {
        let context = try makeContext()
        makeVisit(placeName: Visit.identifyingPlaceName, activity: "Visiting", in: context)
        makeVisit(placeName: Visit.unknownPlaceName, activity: "Visiting", in: context)
        try context.save()

        #expect(try PlaceVisitLookup.visits(named: Visit.identifyingPlaceName,
                                            excluding: nil, context: context).isEmpty)
        #expect(try PlaceVisitLookup.visits(named: Visit.unknownPlaceName,
                                            excluding: nil, context: context).isEmpty)
        #expect(try PlaceVisitLookup.visits(named: "   ", excluding: nil, context: context).isEmpty)
    }

    // MARK: - Why this place

    @Test("A visit inside a saved geofence says so, with the distance and the radius")
    func explainsASavedPlaceMatch() throws {
        let visit = Visit(arrival: base, latitude: -23.4455, longitude: 150.4522,
                          placeName: "Home", inferredActivity: "At home",
                          source: "automatic", recognitionConfidence: "learned")
        let home = SavedPlace(name: "Home", latitude: -23.4455, longitude: 150.4522,
                              radius: 100, defaultActivity: "At home")

        let reasons = PlaceEvidence.reasons(for: visit, savedPlaces: [home], recurrence: 12)

        #expect(reasons.contains { $0.contains("Saved Place: Home") && $0.contains("inside its 100 m radius") })
        #expect(reasons.contains { $0.contains("Recorded here 12 times before") })
    }

    @Test("A saved place the visit falls outside of is reported as context, not as the reason")
    func distinguishesOutsideTheGeofence() throws {
        // ~350 m north of the place, well beyond its 100 m radius.
        let visit = Visit(arrival: base, latitude: -23.4424, longitude: 150.4522,
                          placeName: "Somewhere else", inferredActivity: "Visiting",
                          source: "automatic")
        let home = SavedPlace(name: "Home", latitude: -23.4455, longitude: 150.4522,
                              radius: 100, defaultActivity: "At home")

        let reasons = PlaceEvidence.reasons(for: visit, savedPlaces: [home], recurrence: 0)

        #expect(reasons.contains { $0.hasPrefix("Nearest Saved Place: Home") && $0.contains("outside its") })
        #expect(!reasons.contains { $0.hasPrefix("Saved Place:") })
    }

    @Test("A name that is none of the offered candidates says it came from elsewhere")
    func namesFromElsewhereAreCalledOut() throws {
        var visit = Visit(arrival: base, latitude: -23.4368, longitude: 150.4558,
                          placeName: "Star Liquor", inferredActivity: "Shopping",
                          source: "automatic")
        visit.placeSuggestions = [
            PlaceSuggestion(name: "Coffee Kick’n", latitude: -23.4378, longitude: 150.4564,
                            suggestedActivity: "Eating", distance: 19, mapsIdentifier: "I1"),
            PlaceSuggestion(name: "Gracemere Property Solutions", latitude: -23.4378,
                            longitude: 150.4564, suggestedActivity: "Visiting", distance: 20)
        ]

        let reasons = PlaceEvidence.reasons(for: visit, savedPlaces: [], recurrence: 0)

        #expect(reasons.contains { $0.contains("offered 2 other places") && $0.contains("came from elsewhere") })
    }

    @Test("A chosen Maps candidate reports its distance and whether Maps identified it")
    func explainsAChosenMapsCandidate() throws {
        var visit = Visit(arrival: base, latitude: -23.4378, longitude: 150.4564,
                          placeName: "Coffee Kick’n", inferredActivity: "Eating",
                          source: "automatic", recognitionConfidence: "medium")
        visit.placeSuggestions = [
            PlaceSuggestion(name: "Coffee Kick’n", latitude: -23.4378, longitude: 150.4564,
                            suggestedActivity: "Eating", distance: 19, mapsIdentifier: "IF9A7716")
        ]

        let reasons = PlaceEvidence.reasons(for: visit, savedPlaces: [], recurrence: 0)

        #expect(reasons.contains { $0.contains("Apple Maps: Coffee Kick’n") && $0.contains("19 m") })
        #expect(reasons.contains { $0.contains("matched by Maps identifier") })
    }

    @Test("No reason ever contains a coordinate")
    func reasonsNeverCarryCoordinates() throws {
        var visit = Visit(arrival: base, latitude: -23.445470303380926, longitude: 150.45217746282592,
                          placeName: "Home", inferredActivity: "At home", source: "automatic")
        visit.placeSuggestions = [
            PlaceSuggestion(name: "Home", latitude: -23.445470303380926,
                            longitude: 150.45217746282592, suggestedActivity: "At home",
                            distance: 4, mapsIdentifier: "I1")
        ]
        let home = SavedPlace(name: "Home", latitude: -23.445470303380926,
                              longitude: 150.45217746282592, radius: 100)

        let reasons = PlaceEvidence.reasons(for: visit, savedPlaces: [home], recurrence: 3)

        // This screen exists to be read and pasted into a bug report. The map above it
        // already shows where the visit was; the words must not repeat it as digits.
        #expect(!reasons.isEmpty)
        for reason in reasons {
            #expect(!reason.contains("-23.4"), "a latitude reached the reasoning: \(reason)")
            #expect(!reason.contains("150.4"), "a longitude reached the reasoning: \(reason)")
        }
    }

    // MARK: - Surrounding stays

    // A Health walk carries no coordinate and no route, so the editor can only show
    // where it sits between. These cover that the neighbours found are the right ones.

    @Test("A walk with no position of its own is placed between the stays either side")
    func findsTheStaysEitherSideOfAWalk() throws {
        let context = try makeContext()
        let shop = Visit(arrival: base, departure: base.addingTimeInterval(30 * 60),
                         latitude: -23.4336, longitude: 150.4530,
                         placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                         source: "automatic")
        let walk = Visit(arrival: base.addingTimeInterval(30 * 60),
                         departure: base.addingTimeInterval(59 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        let liquor = Visit(arrival: base.addingTimeInterval(59 * 60),
                           departure: base.addingTimeInterval(62 * 60),
                           latitude: -23.4368, longitude: 150.4558,
                           placeName: "Star Liquor", inferredActivity: "Shopping",
                           source: "automatic")
        [shop, walk, liquor].forEach(context.insert)
        try context.save()

        let neighbours = try SurroundingStays.around(walk, context: context)

        #expect(neighbours.before?.placeName == "Gracemere Shopping World")
        #expect(neighbours.after?.placeName == "Star Liquor")
        #expect(neighbours.haveBoth)
    }

    @Test("A record with nothing recorded around it reports no neighbours")
    func reportsNoNeighboursWhenThereAreNone() throws {
        let context = try makeContext()
        let walk = Visit(arrival: base, departure: base.addingTimeInterval(20 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        // Far outside the window, and another movement record, which has no position
        // to offer either.
        let distant = Visit(arrival: base.addingTimeInterval(48 * 60 * 60),
                            departure: base.addingTimeInterval(49 * 60 * 60),
                            latitude: -23.4336, longitude: 150.4530,
                            placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                            source: "automatic")
        let otherWalk = Visit(arrival: base.addingTimeInterval(-30 * 60),
                              departure: base, latitude: 0, longitude: 0,
                              placeName: "Walking", inferredActivity: "Walking",
                              source: "health-walking")
        [walk, distant, otherWalk].forEach(context.insert)
        try context.save()

        let neighbours = try SurroundingStays.around(walk, context: context)

        #expect(neighbours.before == nil)
        #expect(neighbours.after == nil)
    }

    @Test("A superseded duplicate is not offered as the place either side")
    func skipsSupersededStays() throws {
        let context = try makeContext()
        let superseded = Visit(arrival: base, departure: base.addingTimeInterval(30 * 60),
                               latitude: -23.4336, longitude: 150.4530,
                               placeName: "Gracemere Shopping World", inferredActivity: "Shopping",
                               source: "automatic-superseded")
        let walk = Visit(arrival: base.addingTimeInterval(30 * 60),
                         departure: base.addingTimeInterval(59 * 60),
                         latitude: 0, longitude: 0, placeName: "Walking",
                         inferredActivity: "Walking", source: "health-walking")
        [superseded, walk].forEach(context.insert)
        try context.save()

        let neighbours = try SurroundingStays.around(walk, context: context)

        #expect(neighbours.before == nil, "a superseded row is not where the person was")
    }

    @discardableResult
    private func makeVisit(placeName: String, activity: String, in context: ModelContext) -> Visit {
        let visit = Visit(
            arrival: .now,
            departure: .now.addingTimeInterval(600),
            latitude: -27.4698,
            longitude: 153.0251,
            placeName: placeName,
            inferredActivity: "Visiting",
            userActivity: activity
        )
        context.insert(visit)
        return visit
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            VisitCorrection.self,
            DiagnosticEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
