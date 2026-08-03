import Foundation
import SwiftData

enum UITestSeedData {
    static let launchArgument = "-ui-test-seed"

    static func install(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: .now)
        let home = SavedPlace(name: "Home", latitude: -23.378, longitude: 150.511, category: "Home", defaultActivity: "At home")
        let shops = SavedPlace(name: "Gracemere Shopping World", latitude: -23.437, longitude: 150.456, category: "Shopping", defaultActivity: "Shopping")
        context.insert(home); context.insert(shops)
        func visit(_ start: Int, _ end: Int?, _ place: String, _ category: String, _ activity: String, _ source: String = "automatic", _ confidence: String? = "learned") {
            let arrival = day.addingTimeInterval(TimeInterval(start * 60))
            let departure = end.map { day.addingTimeInterval(TimeInterval($0 * 60)) }
            context.insert(Visit(arrival: arrival, departure: departure, latitude: place == "Home" ? home.latitude : shops.latitude, longitude: place == "Home" ? home.longitude : shops.longitude, placeName: place, placeCategory: category, inferredActivity: activity, userActivity: activity, source: source, recognitionConfidence: confidence))
        }
        visit(0, 390, "Home", "Home", "At home")
        visit(400, 470, "Gracemere Shopping World", "Shopping", "Shopping")
        visit(480, nil, "Home", "Home", "At home")
        visit(120, 390, "Unknown place", "Other", "Visiting", "automatic", nil)
        visit(-420, -30, "Sleep", "Sleep", "Sleeping", "health-sleep", "device")
        try context.save()
    }
}
