import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct LocalBackupTests {
    @Test("Local backup round-trips into an empty store")
    func roundTrip() throws {
        let schema = Schema([Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self])
        let source = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let sourceContext = ModelContext(source)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        sourceContext.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1800), latitude: -27.47, longitude: 153.03, placeName: "Cinema", placeCategory: "Entertainment", inferredActivity: "Watching a movie", userActivity: "Watching a movie", source: "automatic", recognitionConfidence: "medium"))
        sourceContext.insert(SavedPlace(name: "Cinema", latitude: -27.47, longitude: 153.03, category: "Entertainment", defaultActivity: "Watching a movie"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let restored = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restoredContext = ModelContext(restored)
        try LocalBackupService.restore(data, into: restoredContext)
        #expect(try restoredContext.fetch(FetchDescriptor<Visit>()).count == 1)
        #expect(try restoredContext.fetch(FetchDescriptor<SavedPlace>()).first?.defaultActivity == "Watching a movie")
    }
}
