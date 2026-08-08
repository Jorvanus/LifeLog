import Foundation
import SwiftData

enum UITestSeedData {
    static let launchArgument = "-ui-test-seed"

    static func install(in container: ModelContainer) throws {
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
        try context.save()
    }
}
