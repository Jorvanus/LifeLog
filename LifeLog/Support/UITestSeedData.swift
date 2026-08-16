import Foundation
import SwiftData

enum UITestSeedData {
    static let launchArgument = "-ui-test-seed"

    static func install(in container: ModelContainer) throws {
        resetPersistentTestStateIfNeeded()
        // The store is in-memory and so starts empty every launch, but the activity
        // catalogue lives in UserDefaults and does not. A test that adopts a label
        // left it adopted for every run afterwards, so the seeded state a test began
        // from depended on which tests had already been run on that simulator.
        ActivityCatalog.resetForTesting()
        let context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: .now)
        let home = SavedPlace(name: "Home", latitude: -23.378, longitude: 150.511, defaultActivity: "At home")
        let shops = SavedPlace(name: "Gracemere Shopping World", latitude: -23.437, longitude: 150.456, defaultActivity: "Shopping")
        context.insert(home); context.insert(shops)
        func visit(_ start: Int, _ end: Int?, _ place: String, _ activity: String, _ source: String = "automatic", _ confidence: String? = "learned") {
            let arrival = day.addingTimeInterval(TimeInterval(start * 60))
            let departure = end.map { day.addingTimeInterval(TimeInterval($0 * 60)) }
            // A low-confidence guess must keep userActivity empty, otherwise the
            // person has effectively already answered and it is no longer in review.
            let userActivity = confidence == "low" ? nil : activity
            // Device records carry no coordinate. Health and Core Motion report that
            // you moved or slept, not where — `walkingRecords` builds walks from step
            // counts, which have no location at all. Seeding them at a place's
            // coordinates made the fixture disagree with every real store, and hid the
            // case where the editor has no position to show.
            let located = !(source.hasPrefix("health-") || source == "motion")
            let latitude = located ? (place == "Home" ? home.latitude : shops.latitude) : 0
            let longitude = located ? (place == "Home" ? home.longitude : shops.longitude) : 0
            context.insert(Visit(arrival: arrival, departure: departure, latitude: latitude, longitude: longitude, placeName: place, inferredActivity: activity, userActivity: userActivity, source: source, recognitionConfidence: confidence))
        }
        // The night before, so the day opens with the stay it woke up in rather than
        // with the first time the person went out.
        visit(-360, 390, "Home", "At home")
        // Ten minutes on foot from one place to the next: a journey in its own right.
        visit(390, 400, "Walking", "Walking", "health-walking", "device")
        visit(400, 470, "Gracemere Shopping World", "Shopping")
        visit(480, nil, "Home", "At home")
        visit(120, 390, Visit.unknownPlaceName, "Visiting", "automatic", nil)
        // "Work", matching the catalogue. A label the catalogue already holds is an
        // adopted one; seeded as "Working" it silently became a second history-only
        // label, and the adoption test below depends on there being exactly one.
        visit(600, 660, "atWork Australia - Gracemere", "Work", "automatic", "low")
        // A label that lives only in recorded visits and was never adopted into the
        // catalogue — which describes most of a bulk-imported archive. The Activities
        // tab has to show it, mark it as not yet an activity, and offer to add it.
        // Without one seeded, that whole path renders as nothing at all.
        visit(690, 750, "Rockhampton Hospital", "Donate Blood", "automatic", "medium")
        visit(-420, -30, "Sleep", "Sleeping", "health-sleep", "device")
        // A hand-typed Add Visit entry with no resolved coordinate — what "Where?"
        // produces when a name is typed rather than chosen from a search result.
        // Distinct from the device-sourced Walking row above: this one is a location
        // source (manual) with none recorded, which the editor must offer to set
        // rather than treat as a genuine no-position device recording.
        context.insert(Visit(arrival: day.addingTimeInterval(750 * 60), departure: day.addingTimeInterval(780 * 60),
                             latitude: 0, longitude: 0, placeName: "Blood Bank",
                             inferredActivity: "Donate Blood", userActivity: "Donate Blood",
                             source: "manual", recognitionConfidence: nil))

        // A focused visual fixture keeps the DayTimelineBar states deterministic:
        // sleep wins part of a Home stay, a resolved travel interval sits between
        // destinations, and the day still has an explicitly future half.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-timeline-states") {
            visit(0, 120, "Home", "At home")
            visit(120, 480, "Sleep", "Sleeping", "health-sleep", "device")
            visit(480, 510, "In transit", "Travelling", "motion", "device")
            visit(510, 600, "Gracemere Shopping World", "Shopping")
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-manual-visit-gap") {
            // A single, isolated, unambiguous gap far from the default fixture's
            // overlapping visits and its open-ended "Home" stay (which would
            // otherwise cover straight through to `now` and leave nothing to find).
            // Named places found nowhere else in the seed, so a test can locate this
            // exact row without depending on the default fixture's own shape.
            let farDay = calendar.date(byAdding: .day, value: -10, to: day)!
            context.insert(Visit(arrival: farDay.addingTimeInterval(9 * 3600),
                                 departure: farDay.addingTimeInterval(10 * 3600),
                                 latitude: -23.38, longitude: 150.51, placeName: "Rockhampton Grammar School",
                                 inferredActivity: "Eating", userActivity: "Eating", source: "imported-journal"))
            context.insert(Visit(arrival: farDay.addingTimeInterval(12 * 3600),
                                 departure: farDay.addingTimeInterval(13 * 3600),
                                 latitude: -23.38, longitude: 150.51, placeName: "Regional Office",
                                 inferredActivity: "Work", userActivity: "Work", source: "imported-journal"))
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-week-travel") {
            // A dedicated long transition makes the Week card's meaningful-travel
            // state deterministic without changing the default seed's small-trip case.
            visit(900, 1_140, "Flight", "Flight", "manual", "learned")
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-long-labels") {
            let longPlace = "The Very Long Riverfront Community Health and Wellbeing Centre"
            context.insert(SavedPlace(name: longPlace, latitude: shops.latitude, longitude: shops.longitude,
                                      defaultActivity: "Long-form community activity"))
            visit(780, 900, longPlace,
                  "A very long activity name for accessibility and truncation regression coverage",
                  "manual", "learned")
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-imported-history") {
            // A bounded, repeatable imported archive gives the source-scope and
            // annual layouts realistic density without reading any journal on disk.
            for offset in stride(from: 1, through: 16, by: 1) {
                let historicalDay = calendar.date(byAdding: .month, value: -offset, to: day)!
                let arrival = historicalDay.addingTimeInterval(9 * 60 * 60)
                let departure = arrival.addingTimeInterval(7 * 60 * 60)
                context.insert(Visit(arrival: arrival, departure: departure,
                                     latitude: shops.latitude, longitude: shops.longitude,
                                     placeName: "Imported journal office \(offset)",
                                     inferredActivity: "Work", userActivity: "Work",
                                     source: "imported-journal", recognitionConfidence: "learned"))
            }
        }
        try context.save()
    }

    private static func resetPersistentTestStateIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTesting"),
              !arguments.contains("-ui-test-preserve-preferences"),
              let identifier = Bundle.main.bundleIdentifier else { return }
        // SwiftData is in memory for seeded runs, but UserDefaults is not. Resetting
        // only this test app's domain prevents a previous test's scope, catalogue, or
        // Health-import marker from changing a later test's visual result.
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        UserDefaults.standard.synchronize()
    }
}
