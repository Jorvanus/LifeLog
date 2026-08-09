import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct LocalBackupTests {
    @Test("Local backup round-trips into an empty store")
    func roundTrip() throws {
        let schema = Schema([Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self])
        let source = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let sourceContext = ModelContext(source)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        sourceContext.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1800), latitude: -27.47, longitude: 153.03, placeName: "Cinema", inferredActivity: "Watching a movie", userActivity: "Watching a movie", source: "automatic", recognitionConfidence: "medium", mapsIdentifier: "maps-cinema", placeFieldProvenance: "maps"))
        sourceContext.insert(SavedPlace(name: "Cinema", latitude: -27.47, longitude: 153.03, defaultActivity: "Watching a movie", mapsIdentifier: "maps-cinema"))
        sourceContext.insert(LocationEvent(recordedAt: arrival.addingTimeInterval(10), callbackType: "geofence-entry",
                                           callbackAt: arrival, arrival: arrival, latitude: -27.47,
                                           longitude: 153.03, accuracy: 15, transition: "created",
                                           visitArrival: arrival))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let restored = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restoredContext = ModelContext(restored)
        try LocalBackupService.restore(data, into: restoredContext)
        let restoredVisits = try restoredContext.fetch(FetchDescriptor<Visit>())
        #expect(restoredVisits.count == 1)
        #expect(restoredVisits.first?.mapsIdentifier == "maps-cinema")
        #expect(restoredVisits.first?.placeFieldProvenance == "maps")
        #expect(try restoredContext.fetch(FetchDescriptor<SavedPlace>()).first?.mapsIdentifier == "maps-cinema")
        let callbacks = try restoredContext.fetch(FetchDescriptor<LocationEvent>())
        #expect(callbacks.count == 1)
        #expect(callbacks.first?.callbackType == "geofence-entry")
    }
}
