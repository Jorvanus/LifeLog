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
            placeName: "Home", placeCategory: "Home",
            inferredActivity: "At home", source: "automatic"
        ))
        try setupContext.save()

        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()
        let inserted = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Sleep", activity: "Sleeping", category: "Sleep", source: "health-sleep",
                start: start, end: start.addingTimeInterval(8 * 60 * 60)
            ),
            ActivityImportRecord(
                name: "Walking", activity: "Walking", category: "Walking", source: "health-walking",
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
            name: "Run workout", activity: "Running", category: "Running", source: "health-workout",
            start: start, end: start.addingTimeInterval(30 * 60)
        )

        try await writer.prepare()
        let first = try await writer.insertBatch([record])
        let second = try await writer.insertBatch([record])
        try await writer.finish()

        #expect(first == 1)
        #expect(second == 0)
    }
}
