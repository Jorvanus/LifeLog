import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct TimelineFixtureCoverageTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Overlapping destinations never expose movement inside an occupied interval")
    func overlappingVisitsAreLocationFirst() {
        let destinations = (0..<80).map { index in
            Visit(
                arrival: base.addingTimeInterval(Double(index) * 3_600),
                departure: base.addingTimeInterval(Double(index) * 3_600 + 2_400),
                latitude: -27.47 + Double(index) * 0.0001,
                longitude: 153.03,
                placeName: "Destination \(index)",
                inferredActivity: "Visiting",
                source: "automatic"
            )
        }
        let movement = Visit(
            arrival: base.addingTimeInterval(10 * 3_600 + 1_200),
            departure: base.addingTimeInterval(10 * 3_600 + 3_000),
            latitude: 0, longitude: 0, placeName: "Walking",
            inferredActivity: "Walking",
            userActivity: "Walking", source: "health-walking"
        )

        #expect(ActivityLocationPolicy.shouldShow(movement, locationVisits: destinations) == false)
    }

    @Test("Malformed visit fixtures are sanitized and invalid coordinates are not learned")
    func malformedSamplesRemainSafe() throws {
        let malformed = Visit(
            arrival: base, departure: base.addingTimeInterval(-60),
            latitude: .nan, longitude: .infinity,
            placeName: "  \u{0000}\nUnknown place  ",
            inferredActivity: "\u{000B}Visiting",
            userActivity: "\u{000D}Visiting", note: "\u{0000}note",
            source: "automatic"
        )

        #expect(malformed.placeName == "Unknown place")
        #expect(malformed.note == "note")
        #expect(malformed.duration == 0)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self,
                                            VisitCorrection.self, configurations: configuration)
        let context = ModelContext(container)
        context.insert(malformed)
        #expect(try SavedPlaceLearning.upsert(from: malformed, previousPlaceName: nil, context: context) == nil)
    }

    @Test("A long-running history remains stable across a deterministic fixture")
    func longHistoryFixture() {
        let visits = (0..<365).flatMap { day in
            (0..<4).map { slot in
                let start = base.addingTimeInterval(Double(day * 86_400 + slot * 3_600))
                return Visit(arrival: start, departure: start.addingTimeInterval(45 * 60),
                             latitude: -27.47, longitude: 153.03,
                             placeName: slot.isMultiple(of: 2) ? "Home" : "Work",
                             inferredActivity: slot.isMultiple(of: 2) ? "At home" : "Working",
                             source: "automatic")
            }
        }
        let movement = DateInterval(start: base.addingTimeInterval(12 * 86_400),
                                    end: base.addingTimeInterval(12 * 86_400 + 4 * 3_600))
        let remaining = ActivityLocationPolicy.remainingSegments(for: movement,
                                                                  locationVisits: visits)
        #expect(visits.count == 1_460)
        #expect(remaining.count == 4)
        #expect(remaining.allSatisfy { $0.duration >= 0 })
    }

    @Test("Date fixtures remain valid in extreme time zones")
    func unusualTimeZones() {
        let zones = ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York", "UTC"]
        for identifier in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1))!
            let end = calendar.date(byAdding: .hour, value: 6, to: start)!
            let interval = DateInterval(start: start, end: end)
            #expect(interval.duration == 6 * 3_600)
            #expect(calendar.startOfDay(for: start) <= start)
        }
    }

    @Test("Trend exports include safe visit fields in both formats")
    func trendExportFormats() throws {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(90 * 60),
                          latitude: -27.47, longitude: 153.03, placeName: "Corner, Cafe",
                          inferredActivity: "Eating",
                          source: "automatic", recognitionConfidence: "confirmed")
        let interval = DateInterval(start: base.addingTimeInterval(-60), end: base.addingTimeInterval(2 * 3_600))
        let csv = try #require(TrendExport.makeFile(format: "csv", visits: [visit], interval: interval, now: base.addingTimeInterval(2 * 3_600)))
        let json = try #require(TrendExport.makeFile(format: "json", visits: [visit], interval: interval, now: base.addingTimeInterval(2 * 3_600)))
        defer {
            try? FileManager.default.removeItem(at: csv.url)
            try? FileManager.default.removeItem(at: json.url)
        }

        let csvText = try String(contentsOf: csv.url, encoding: .utf8)
        let jsonText = try String(contentsOf: json.url, encoding: .utf8)
        #expect(csvText.contains("place,category,category_color,activity"))
        #expect(csvText.contains("Corner, Cafe"))
        #expect(jsonText.contains("Corner, Cafe"))
        #expect(jsonText.contains("Confirmed"))
    }

    @Test("A weak Apple Maps guess is queued for confirmation rather than accepted silently")
    func lowConfidenceGuessNeedsConfirmation() {
        // Mirrors a real capture: Maps matched a workplace onto a home coordinate
        // and returned it with low confidence.
        let guessed = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51,
                            placeName: "atWork Australia - Gracemere",
                            inferredActivity: "Working",
                            source: "automatic", recognitionConfidence: "low")

        // It has a name, so it is not "uncategorised" — but it still needs a person.
        #expect(guessed.needsCategorisation == false)
        #expect(guessed.needsConfirmation)
        #expect(guessed.needsReview)
    }

    @Test("Confident and person-labelled places are not queued for review")
    func settledPlacesAreNotQueued() {
        let confident = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                              latitude: -23.37, longitude: 150.51, placeName: "Gracemere Shopping World",
                              inferredActivity: "Shopping", source: "automatic",
                              recognitionConfidence: "high")
        #expect(confident.needsReview == false)

        // A weak guess the person has already answered for.
        let answered = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                             latitude: -23.37, longitude: 150.51, placeName: "atWork Australia - Gracemere",
                             inferredActivity: "Working", userActivity: "At home",
                             source: "automatic", recognitionConfidence: "low")
        #expect(answered.needsConfirmation == false)
        #expect(answered.needsReview == false)

        // Learned Saved Places and manual entries are settled by definition.
        let learned = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51, placeName: "Home",
                            inferredActivity: "At home", source: "automatic",
                            recognitionConfidence: "learned")
        #expect(learned.needsReview == false)
        let manual = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                           latitude: -23.37, longitude: 150.51, placeName: "Somewhere",
                           inferredActivity: "Visiting", source: "manual",
                           recognitionConfidence: "low")
        #expect(manual.needsReview == false)
    }

    @Test("An unidentified place still needs categorising, not confirming")
    func unidentifiedPlaceStillNeedsCategorising() {
        let unknown = Visit(arrival: base, departure: base.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51,
                            placeName: Visit.unknownPlaceName, inferredActivity: "Visiting",
                            source: "automatic", recognitionConfidence: "low")
        #expect(unknown.needsCategorisation)
        #expect(unknown.needsConfirmation == false)
        #expect(unknown.needsReview)
    }

    @Test("Time bands scope a bulk change to the right entries")
    func timeBandsScopeCorrectly() {
        let calendar = Calendar.current
        func at(_ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 30, second: 0, of: base)!
        }
        #expect(PlaceTimeBand.night.contains(at(3)))
        #expect(PlaceTimeBand.night.contains(at(7)) == false)
        #expect(PlaceTimeBand.morning.contains(at(7)))
        #expect(PlaceTimeBand.day.contains(at(13)))
        #expect(PlaceTimeBand.evening.contains(at(19)))
        #expect(PlaceTimeBand.lateNight.contains(at(23)))
        // "Any time" must cover every hour, or a bulk change would silently skip rows.
        for hour in 0..<24 { #expect(PlaceTimeBand.allDay.contains(at(hour))) }
        // The bands must not overlap, so an entry is only ever changed once.
        for hour in 0..<24 {
            let matches = PlaceTimeBand.allCases
                .filter { $0 != .allDay && $0.contains(at(hour)) }
            #expect(matches.count == 1, "hour \(hour) matched \(matches.count) bands")
        }
    }

    @Test("Inference speaks the vocabulary in the catalogue")
    func inferenceUsesCatalogueWording() {
        // A catalogue that says "Work", the way a real timeline usually does.
        let catalogue = [
            ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Seeing Doctor", category: "Healthcare", symbol: "cross.case.fill"),
            ActivityDefinition(name: "Eating", category: "Food & Drink", symbol: "fork.knife"),
            ActivityDefinition(name: "Beers", category: "Food & Drink", symbol: "mug.fill")
        ]
        // Shared stem: "Working" resolves to "Work".
        #expect(ActivityCatalog.preferredLabel(for: "Working", in: catalogue) == "Work")
        // Sole activity in its category resolves even without a shared stem.
        #expect(ActivityCatalog.preferredLabel(for: "Healthcare", in: catalogue) == "Seeing Doctor")
        // Two candidates in one category is ambiguous, so the original wording stands
        // rather than guessing between "Eating" and "Beers".
        #expect(ActivityCatalog.preferredLabel(for: "Eating", in: catalogue) == "Eating")
        // Nothing to map to leaves the label untouched.
        #expect(ActivityCatalog.preferredLabel(for: "Studying", in: catalogue) == "Studying")
    }

    @Test("The activities list reads alphabetically whatever order it was built in")
    func activitiesSortByName() {
        let unsorted = [
            ActivityDefinition(name: "work", category: "Work", symbol: "briefcase.fill"),
            ActivityDefinition(name: "Éating", category: "Food & Drink", symbol: "fork.knife"),
            ActivityDefinition(name: "Beers", category: "Food & Drink", symbol: "mug.fill"),
            ActivityDefinition(name: "At home", category: "Home", symbol: "house.fill")
        ]

        let names = ActivityCatalog.sorted(unsorted).map(\.name)

        // Case and accents must not decide the order: an accented label belongs with
        // its unaccented neighbours, and "work" is not filed after every capital.
        #expect(names == ["At home", "Beers", "Éating", "work"])
    }

    /// Groups are only a string on each activity, so the risk in editing one is that
    /// history quietly stops being counted. These assert it never does.
    @Test("Renaming a group carries its activities; deleting one leaves them counted")
    func groupEditsKeepActivitiesGrouped() {
        let suite = "LifeLogGroupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ActivityCatalog.withStorage(defaults) {
            ActivityCatalog.save([
                ActivityDefinition(name: "CrossFit", category: "Fitness", symbol: "figure.run"),
                ActivityDefinition(name: "Swimming", category: "Fitness", symbol: "figure.pool.swim"),
                ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
            ])

            #expect(ActivityCatalog.addCategory("Fitness") == false, "A duplicate group would split the same time in two")
            #expect(ActivityCatalog.addCategory("Volunteering"))
            #expect(ActivityCatalog.categories.contains("Volunteering"))

            // Renaming moves the activities, so their visits keep being counted under
            // the new name rather than falling out of the group.
            #expect(ActivityCatalog.renameCategory(from: "Fitness", to: "Training") == 2)
            #expect(ActivityCatalog.activities(inCategory: "Training").map(\.name) == ["CrossFit", "Swimming"])
            #expect(ActivityCatalog.categories.contains("Training"))
            #expect(ActivityCatalog.categories.contains("Fitness") == false)

            // Deleting drops them to the fallback rather than nowhere.
            #expect(ActivityCatalog.deleteCategory("Training") == 2)
            #expect(ActivityCatalog.categories.contains("Training") == false)
            #expect(ActivityCatalog.activities(inCategory: ActivityCatalog.fallbackCategory)
                .map(\.name) == ["CrossFit", "Swimming"])
            #expect(ActivityCatalog.category(for: "CrossFit") == ActivityCatalog.fallbackCategory)

            // The fallback itself must survive, or a later deletion has nowhere to go.
            #expect(ActivityCatalog.deleteCategory(ActivityCatalog.fallbackCategory) == 0)
            #expect(ActivityCatalog.categories.contains(ActivityCatalog.fallbackCategory))
        }
    }

    @Test("Adopted activities are grouped, not dumped into Other")
    func suggestedCategoriesCoverRealVocabulary() {
        #expect(ActivityCatalog.suggestedCategory(for: "Work") == "Work")
        #expect(ActivityCatalog.suggestedCategory(for: "Work Trip") == "Work")
        #expect(ActivityCatalog.suggestedCategory(for: "Groceries") == "Shopping")
        #expect(ActivityCatalog.suggestedCategory(for: "CrossFit") == "Fitness")
        #expect(ActivityCatalog.suggestedCategory(for: "Seeing Doctor") == "Healthcare")
        #expect(ActivityCatalog.suggestedCategory(for: "Donate Blood") == "Healthcare")
        #expect(ActivityCatalog.suggestedCategory(for: "Sleeping") == "Sleep")
        #expect(ActivityCatalog.suggestedCategory(for: "Flight") == "Travel")
        #expect(ActivityCatalog.suggestedCategory(for: "Holiday") == "Travel")
        #expect(ActivityCatalog.suggestedCategory(for: "Visit. Friends") == "Social")
        #expect(ActivityCatalog.suggestedCategory(for: "Beers") == "Food & Drink")
        // Every suggestion must be a category the picker offers, or it cannot be
        // corrected afterwards.
        for label in ["Work", "Groceries", "CrossFit", "Flight", "Nonsense xyzzy"] {
            #expect(ActivityCatalog.categories.contains(ActivityCatalog.suggestedCategory(for: label)))
        }
    }

    @Test("Life Cycle journal CSV maps activities and tolerates malformed rows")
    func journalImportParsing() {
        let csv = """
        START DATE(UTC), END DATE(UTC), START TIME(LOCAL), END TIME(LOCAL), DURATION, NAME, LOCATION, NOTE
        2026-08-01 00:00:00, 2026-08-01 01:00:00, 2026-08-01 10:00:00 AEST, 2026-08-01 11:00:00 AEST, 3600, Sleep, Home, Rested
        malformed,row
        2026-08-01 02:00:00, 2026-08-01 02:30:00, 2026-08-01 12:00:00 AEST, 2026-08-01 12:30:00 AEST, 1800, Transport, ,
        """.data(using: .utf8)!

        let parsed = JournalCSVImporter.parse(csv)
        #expect(parsed.rows.count == 2)
        #expect(parsed.malformed == 1)
        #expect(parsed.rows[0].name == "Sleep")
        #expect(parsed.rows[1].name == "Transport")
    }
}
