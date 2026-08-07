import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct SavedPlaceLearningTests {
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

        try SavedPlaceLearning.apply(saved, context: context)
        try context.save()

        #expect(current.placeName == "Home")
        #expect(current.activity == "At home")
        #expect(current.needsCategorisation == false)
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
