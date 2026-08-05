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

    /// The figures the activity page reports, in the shape the sketch asked for:
    /// occasions, total, average, shortest, longest, and where it happened.
    @Test("An activity's totals, spread and top locations")
    func summarisesOneActivity() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func beers(daysAgo: Int, hours: Double, place: String) -> Visit {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return Visit(arrival: start, departure: start.addingTimeInterval(hours * 3_600),
                         latitude: -23.37, longitude: 150.51, placeName: place,
                         inferredActivity: "Beers", userActivity: "Beers", source: "manual")
        }
        let visits = [
            beers(daysAgo: 1, hours: 2, place: "O'Dowds"),
            beers(daysAgo: 2, hours: 6, place: "O'Dowds"),
            beers(daysAgo: 3, hours: 1, place: "Paddy's"),
            beers(daysAgo: 20, hours: 3, place: "O'Leary's"),
            // A different activity at the same place must not be counted.
            Visit(arrival: now, departure: now.addingTimeInterval(3_600),
                  latitude: -23.37, longitude: 150.51, placeName: "O'Dowds",
                  inferredActivity: "Coffee", userActivity: "Coffee", source: "manual")
        ]

        let stats = ActivityStatistics.make(activity: "Beers", visits: visits,
                                            days: 7, now: now, calendar: calendar)

        #expect(stats.occasions == 4)
        #expect(stats.totalTime == 12 * 3_600)
        #expect(stats.averageTime == 3 * 3_600)
        #expect(stats.shortestTime == 3_600)
        #expect(stats.longestTime == 6 * 3_600)
        // Ordered by how often, so the usual haunt leads.
        #expect(stats.places.map(\.name) == ["O'Dowds", "O'Leary's", "Paddy's"])
        #expect(stats.places.first?.occasions == 2)
        // Seven columns ending today, whether or not anything happened in them.
        #expect(stats.recentDays.count == 7)
        #expect(stats.recentDays.map(\.occasions).reduce(0, +) == 3, "The 20-day-old night is outside the week")
        // This week against the one before it: nothing in the previous week, so there
        // is no change to report rather than a fabricated one.
        #expect(stats.currentPeriodTime == 9 * 3_600)
        #expect(stats.previousPeriodTime == 0)
        #expect(stats.changeFraction == nil)
        #expect(stats.firstUsed == visits[3].arrival)
        #expect(stats.lastUsed == visits[0].arrival)
    }

    /// The Activities tab was slow to open because it walked the whole timeline once
    /// per activity. At archive size that is the difference between one pass and
    /// twenty, so this fixture is deliberately the size of a real import.
    @Test("Every activity's figures come from one pass over a full archive")
    func summarisesEveryActivityInOnePass() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = ["Beers", "Coffee", "Working", "At home", "Shopping"]
        let visits = (0..<32_000).map { index -> Visit in
            let start = now.addingTimeInterval(-Double(index) * 900)
            return Visit(arrival: start, departure: start.addingTimeInterval(600),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         source: "imported-journal")
        }

        let names = labels + ["Bowling"]
        let all = ActivityStatistics.makeAll(named: names, visits: visits, now: now, calendar: calendar)

        #expect(all.count == names.count)
        // Identical to computing one at a time, which is what this replaced.
        for name in labels {
            let bulk = all.first { $0.activity == name }
            let single = ActivityStatistics.make(activity: name, visits: visits,
                                                 now: now, calendar: calendar)
            #expect(bulk?.occasions == single.occasions)
            #expect(bulk?.totalTime == single.totalTime)
            #expect(bulk?.places.first?.occasions == single.places.first?.occasions)
        }
        // An activity in the catalogue that the archive never uses is still listed,
        // and still carries its own name rather than an empty one.
        let unused = all.first { $0.activity == "Bowling" }
        #expect(unused?.isEmpty == true)
        #expect(unused?.activity == "Bowling")
    }

    /// The list's summaries must agree with the full figures, and cost less: on a real
    /// archive the full version measured 380 ms on device, over the project's 250 ms
    /// main-thread budget.
    @Test("List summaries match the full figures and cost less to produce")
    func summariesAgreeWithFullStatistics() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = ["Beers", "Coffee", "Working", "At home", "Shopping"]
        let visits = (0..<25_000).map { index -> Visit in
            let start = now.addingTimeInterval(-Double(index) * 900)
            return Visit(arrival: start, departure: start.addingTimeInterval(600),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         source: "imported-journal")
        }

        let summaryStarted = Date.now
        let summaries = ActivityStatistics.summaries(named: labels, visits: visits,
                                                     now: now, calendar: calendar)
        let summaryElapsed = Date.now.timeIntervalSince(summaryStarted)

        let fullStarted = Date.now
        let full = ActivityStatistics.makeAll(named: labels, visits: visits,
                                              now: now, calendar: calendar)
        let fullElapsed = Date.now.timeIntervalSince(fullStarted)

        for label in labels {
            let summary = summaries.first { $0.activity == label }
            let complete = full.first { $0.activity == label }
            #expect(summary?.occasions == complete?.occasions)
            #expect(summary?.totalTime == complete?.totalTime)
            #expect(summary?.recentDays.map(\.occasions) == complete?.recentDays.map(\.occasions))
            #expect(summary?.recentDays.map(\.hours) == complete?.recentDays.map(\.hours))
        }
        #expect(summaryElapsed < fullElapsed,
                "summaries \(Int(summaryElapsed * 1000))ms vs full \(Int(fullElapsed * 1000))ms")
    }

    /// The anchor exists to sharpen a departure Core Location guessed, and must never
    /// manufacture one. These cover both halves.
    @Test("A network seen leaving sharpens the departure it was guessing at")
    func wifiAnchorCorrectsADeparture() {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: "aa:bb:cc:dd:ee:ff")

        // Joined at arrival, still joined half an hour later, gone by 8:40.
        var observation = WiFiAnchor.update(nil, sampled: home, at: arrival)
        observation = WiFiAnchor.update(observation, sampled: home, at: arrival.addingTimeInterval(1_800))
        observation = WiFiAnchor.update(observation, sampled: nil, at: arrival.addingTimeInterval(2_400))

        // Core Location would have timed this from the next arrival, 52 minutes later.
        let fallback = arrival.addingTimeInterval(3_120)
        #expect(WiFiAnchor.departure(for: observation, arrival: arrival, fallback: fallback)
                == arrival.addingTimeInterval(2_400))
    }

    @Test("A dropped network is not a departure")
    func wifiAnchorIgnoresADrop() {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: nil)
        let fallback = arrival.addingTimeInterval(3_600)

        // Off the network briefly — a reboot, a band switch — then back on it.
        var observation = WiFiAnchor.update(nil, sampled: home, at: arrival)
        observation = WiFiAnchor.update(observation, sampled: nil, at: arrival.addingTimeInterval(600))
        observation = WiFiAnchor.update(observation, sampled: home, at: arrival.addingTimeInterval(900))

        #expect(observation?.firstAbsent == nil, "Being back on the network unwrites the absence")
        #expect(WiFiAnchor.departure(for: observation, arrival: arrival, fallback: fallback) == nil)

        // Never on a network at all: nothing to say, so Core Location's timing stands.
        let unanchored = WiFiAnchor.update(nil, sampled: nil, at: arrival)
        #expect(unanchored == nil)
        #expect(WiFiAnchor.departure(for: unanchored, arrival: arrival, fallback: fallback) == nil)
    }

    @Test("A departure is never moved outside the stay it belongs to")
    func wifiAnchorStaysWithinBounds() {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: nil)
        let fallback = arrival.addingTimeInterval(3_600)

        // An absence recorded before the stay began belongs to the previous one.
        var stale = WiFiAnchor.update(nil, sampled: home, at: arrival.addingTimeInterval(-7_200))
        stale = WiFiAnchor.update(stale, sampled: nil, at: arrival.addingTimeInterval(-3_600))
        #expect(WiFiAnchor.departure(for: stale, arrival: arrival, fallback: fallback) == nil)

        // An absence after the next arrival would lengthen the stay, not shorten it.
        var late = WiFiAnchor.update(nil, sampled: home, at: arrival)
        late = WiFiAnchor.update(late, sampled: nil, at: fallback.addingTimeInterval(600))
        #expect(WiFiAnchor.departure(for: late, arrival: arrival, fallback: fallback) == nil)
    }

    @Test("A network is identified without being recorded")
    func wifiAnchorDoesNotStoreTheNetworkName() {
        let hash = WiFiAnchor.hash(ssid: "Baxter Home 5G", bssid: "aa:bb:cc:dd:ee:ff")
        #expect(!hash.localizedCaseInsensitiveContains("baxter"))
        #expect(hash.count == 16)
        // Same network, same answer; different network, different answer.
        #expect(hash == WiFiAnchor.hash(ssid: "baxter home 5g", bssid: "AA:BB:CC:DD:EE:FF"))
        #expect(hash != WiFiAnchor.hash(ssid: "Baxter Home 5G", bssid: "aa:bb:cc:dd:ee:00"))
    }

    @Test("A label the catalogue has never heard of is still counted")
    func includesLabelsMissingFromTheCatalogue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visit = Visit(arrival: now, departure: now.addingTimeInterval(3_600),
                          latitude: -23.37, longitude: 150.51, placeName: "O'Dowds",
                          inferredActivity: "Trivia night", source: "manual")

        let all = ActivityStatistics.makeAll(named: ["Beers"], visits: [visit], now: now)

        #expect(all.count == 2)
        #expect(all.contains { $0.activity == "Trivia night" && $0.occasions == 1 })
    }

    @Test("An activity nothing uses reports nothing rather than zeroes")
    func summarisesAnUnusedActivity() {
        let stats = ActivityStatistics.make(activity: "Bowling", visits: [])
        #expect(stats.isEmpty)
        #expect(stats.occasions == 0)
        #expect(stats.firstUsed == nil)
        #expect(stats.changeFraction == nil)
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
