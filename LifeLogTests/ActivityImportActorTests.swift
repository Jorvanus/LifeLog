import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct ActivityImportActorTests {
    @Test("Import progress reports bounded completion")
    func reportsProgress() {
        let progress = ActivityImportProgress(
            state: .saving, title: "Saving activity…", completed: 20, total: 40
        )
        #expect(progress.isActive)
        #expect(progress.fraction == 0.5)
        #expect(ActivityImportProgress(
            state: .complete, title: "Import complete", completed: 0, total: 0
        ).fraction == 1)
    }

    @Test("Background batches preserve sleep and suppress walking at Home")
    func importsWithLocationPolicy() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setupContext = ModelContext(container)
        setupContext.insert(Visit(
            arrival: start, departure: start.addingTimeInterval(9 * 60 * 60),
            latitude: -27.47, longitude: 153.03,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        ))
        try setupContext.save()

        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()
        let inserted = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Sleep", activity: "Sleeping", source: "health-sleep",
                start: start, end: start.addingTimeInterval(8 * 60 * 60)
            ),
            ActivityImportRecord(
                name: "Walking", activity: "Walking", source: "health-walking",
                start: start.addingTimeInterval(60 * 60), end: start.addingTimeInterval(90 * 60)
            )
        ])
        try await writer.finish()

        let verificationContext = ModelContext(container)
        let imported = try verificationContext.fetch(FetchDescriptor<Visit>())
            .filter { $0.source.hasPrefix("health-") }
        #expect(inserted == 1)
        #expect(imported.count == 1)
        #expect(imported.first?.source == "health-sleep")
    }

    @Test("Repeated background batches do not duplicate records")
    func deduplicatesAcrossBatches() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let writer = ActivityImportActor(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = ActivityImportRecord(
            name: "Run workout", activity: "Running", source: "health-workout",
            start: start, end: start.addingTimeInterval(30 * 60)
        )

        try await writer.prepare()
        let first = try await writer.insertBatch([record])
        let second = try await writer.insertBatch([record])
        try await writer.finish()

        #expect(first == 1)
        #expect(second == 0)
    }

    @Test("Deleted HealthKit samples remove unconfirmed imported visits but preserve confirmed ones")
    func removesVisitsForDeletedSamples() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let removedID = UUID()
        let keptID = UUID()

        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()
        _ = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Run workout", activity: "Running", source: "health-workout",
                start: start, end: start.addingTimeInterval(30 * 60), healthKitSampleIDs: [removedID]
            ),
            ActivityImportRecord(
                name: "Sleep", activity: "Sleeping", source: "health-sleep",
                start: start.addingTimeInterval(3 * 60 * 60), end: start.addingTimeInterval(11 * 60 * 60),
                healthKitSampleIDs: [keptID]
            )
        ])
        try await writer.finish()

        // Simulate the sleep visit having since been manually confirmed.
        let editContext = ModelContext(container)
        let sleepVisit = try #require(try editContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "health-sleep" }
        )).first)
        sleepVisit.recognitionConfidence = "confirmed"
        try editContext.save()

        try await writer.prepare()
        let removed = try await writer.deleteRemovedRecords(sampleIDs: [removedID, keptID])
        try await writer.finish()

        #expect(removed == 1)
        let remaining = try editContext.fetch(FetchDescriptor<Visit>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.source == "health-sleep")
    }
}
