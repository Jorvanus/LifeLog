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

    @Test("A stay recorded mid-walk does not cut the imported workout into fragments")
    func workoutSurvivesAStayRecordedDuringIt() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Cedric Archer Park on 7 August: a saved place, so every confidence guard
        // protects it, sitting wholly inside the walk. Before this it split the workout
        // into two rows and deleted the 17 minutes between them.
        let setupContext = ModelContext(container)
        setupContext.insert(Visit(
            arrival: start.addingTimeInterval(11 * 60), departure: start.addingTimeInterval(28 * 60),
            latitude: -23.44096, longitude: 150.45,
            placeName: "Cedric Archer Park", inferredActivity: "Walking",
            source: "automatic", recognitionConfidence: "learned"
        ))
        try setupContext.save()

        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()
        let inserted = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Walking workout", activity: "Walking", source: "health-workout",
                start: start, end: start.addingTimeInterval(34 * 60),
                healthKitSampleIDs: [UUID()]
            )
        ])
        try await writer.finish()

        let verificationContext = ModelContext(container)
        let workouts = try verificationContext.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-workout" }
        #expect(inserted == 1)
        #expect(workouts.count == 1, "one started workout is one row")
        #expect(workouts.first?.arrival == start)
        #expect(workouts.first?.departure == start.addingTimeInterval(34 * 60))
    }

    @Test("A main-context correction to a stay survives a batch prepared before it landed")
    func importBatchDoesNotOverwriteAConcurrentStayCorrection() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self,
            configurations: configuration
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setupContext = ModelContext(container)
        let home = Visit(
            arrival: start, departure: start.addingTimeInterval(20 * 60),
            latitude: -27.47, longitude: 153.03,
            placeName: "Home", inferredActivity: "At home", source: "automatic"
        )
        setupContext.insert(home)
        try setupContext.save()

        // The actor loads its own copy of Home before the main context's correction
        // below lands — the exact ordering behind the 07:16:22/07:02:44 capture.
        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()

        // A main-context repair (Timeline reconciliation, in production) corrects
        // Home's departure a moment later, to a value the import batch below never sees.
        home.departure = start.addingTimeInterval(5 * 60)
        try setupContext.save()

        // The batch bounds a walk against its own, now-stale view of Home (would land
        // Home's departure at 6 minutes, not 5) and saves. Before the fix, that save
        // silently reverted the main context's correction to the import's own answer.
        let inserted = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Walking", activity: "Walking", source: "health-walking",
                start: start.addingTimeInterval(6 * 60), end: start.addingTimeInterval(30 * 60)
            )
        ])
        try await writer.finish()

        let verificationContext = ModelContext(container)
        let stays = try verificationContext.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "automatic" }
        #expect(inserted == 1, "the walk still gets written, bounded against the actor's own view of Home")
        #expect(stays.count == 1)
        #expect(stays.first?.departure == start.addingTimeInterval(5 * 60),
               "the main context's correction survives the import's save")
    }

    @Test("A stay the imported walk passed through is withdrawn before it can split anything")
    func passingStayIsWithdrawnDuringImport() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            configurations: configuration
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setupContext = ModelContext(container)
        setupContext.insert(Visit(
            arrival: start.addingTimeInterval(11 * 60), departure: start.addingTimeInterval(28 * 60),
            latitude: -23.44133, longitude: 150.45,
            placeName: "Gracemere Pump Track", inferredActivity: "Visiting",
            source: "automatic", recognitionConfidence: "medium"
        ))
        try setupContext.save()

        var route: [RoutePoint] = []
        var time = start
        while time <= start.addingTimeInterval(34 * 60) {
            route.append(RoutePoint(latitude: -23.44133 + 1.3 * time.timeIntervalSince(start) / 111_000,
                                    longitude: 150.45, time: time))
            time = time.addingTimeInterval(60)
        }

        let writer = ActivityImportActor(modelContainer: container)
        try await writer.prepare()
        _ = try await writer.insertBatch([
            ActivityImportRecord(
                name: "Walking workout", activity: "Walking", source: "health-workout",
                start: start, end: start.addingTimeInterval(34 * 60),
                healthKitSampleIDs: [UUID()], route: route
            )
        ])
        try await writer.finish()

        let verificationContext = ModelContext(container)
        let stay = try #require(try verificationContext.fetch(FetchDescriptor<Visit>())
            .first { $0.placeName == "Gracemere Pump Track" })
        #expect(stay.source == ActivityLocationPolicy.supersededLocationSource)
        #expect(try verificationContext.fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-workout" }.count == 1)
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
