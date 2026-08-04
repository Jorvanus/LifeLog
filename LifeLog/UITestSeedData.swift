import Foundation
import SwiftData

enum UITestSeedData {
    static let launchArgument = "-ui-test-seed"

    static func install(in container: ModelContainer) throws {
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
            context.insert(Visit(arrival: arrival, departure: departure, latitude: place == "Home" ? home.latitude : shops.latitude, longitude: place == "Home" ? home.longitude : shops.longitude, placeName: place, inferredActivity: activity, userActivity: userActivity, source: source, recognitionConfidence: confidence))
        }
        visit(0, 390, "Home", "At home")
        visit(400, 470, "Gracemere Shopping World", "Shopping")
        visit(480, nil, "Home", "At home")
        visit(120, 390, Visit.unknownPlaceName, "Visiting", "automatic", nil)
        visit(600, 660, "atWork Australia - Gracemere", "Working", "automatic", "low")
        visit(-420, -30, "Sleep", "Sleeping", "health-sleep", "device")
        try context.save()
    }
}
