import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `ActivityDataService.backgroundWriter()` memoizes the single `ActivityImportActor`
/// every Health import goes through. Two overlapping callers used to each find the
/// cache empty and each construct their own actor -- distinct in-memory views of the
/// same store, neither able to see the other's not-yet-saved insert. That produced
/// exact-duplicate sleep visits (identical arrival, departure and HealthKit sample
/// IDs) on real devices when a fast-changing Insights `.task(id:)` raced a superseded
/// run that SwiftUI had only cooperatively cancelled.
@MainActor
struct ActivityDataServiceConcurrencyTests {
    @Test("Overlapping Health write sessions are serialized")
    func overlappingWritesNeverRunTogether() async {
        let coordinator = HealthImportWriteCoordinator()
        let state = WriteProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await coordinator.acquire()
                    await state.enter()
                    try? await Task.sleep(for: .milliseconds(1))
                    await state.leave()
                    await coordinator.release()
                }
            }
        }
        let maximum = await state.maximum
        #expect(maximum == 1,
                "a cancelled/replaced Health import must not overlap a second sleep writer")
    }

    @Test("Serialized sleep sessions keep one Health sample as one visit")
    func concurrentSleepSessionsRemainIdempotent() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           configurations: configuration)
        let writer = ActivityImportActor(modelContainer: container)
        let gate = HealthImportWriteCoordinator()
        let sampleID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = ActivityImportRecord(name: "Sleep", activity: "Sleeping",
                                          source: SleepEvidence.measuredSource,
                                          start: start, end: start.addingTimeInterval(8 * 60 * 60),
                                          healthKitSampleIDs: [sampleID])

        func writeOneSession() async throws {
            await gate.acquire()
            defer { Task { await gate.release() } }
            try await writer.prepare()
            _ = try await writer.insertBatch([record])
            try await writer.finish()
        }
        async let first = writeOneSession()
        async let second = writeOneSession()
        try await first
        try await second

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .filter { $0.source == SleepEvidence.measuredSource }
        #expect(visits.count == 1)
        #expect(Set(visits.first?.healthKitSampleIDs ?? []) == [sampleID])
    }

    @Test("Two overlapping callers of backgroundWriter() converge on the same actor instance")
    func concurrentCallersShareOneWriter() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            ActivityDefinitionRecord.self,
            configurations: configuration
        )
        let service = ActivityDataService()
        service.connect(ModelContext(container), container: container)

        // `async let` starts both before either awaits the other, reproducing the
        // window where the old check-then-create code let two callers both see an
        // empty cache.
        async let first = service.backgroundWriter()
        async let second = service.backgroundWriter()
        let (writerA, writerB) = await (first, second)

        let a = try #require(writerA)
        let b = try #require(writerB)
        #expect(a === b, "concurrent callers must share one writer, or each can insert the same HealthKit sample as a separate visit")
    }

    @Test("Four overlapping callers still converge on one actor instance")
    func manyConcurrentCallersShareOneWriter() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            ActivityDefinitionRecord.self,
            configurations: configuration
        )
        let service = ActivityDataService()
        service.connect(ModelContext(container), container: container)

        async let w1 = service.backgroundWriter()
        async let w2 = service.backgroundWriter()
        async let w3 = service.backgroundWriter()
        async let w4 = service.backgroundWriter()
        let (r1, r2, r3, r4) = await (w1, w2, w3, w4)

        let first = try #require(r1)
        for writer in [r2, r3, r4] {
            #expect(try #require(writer) === first)
        }
    }
}

private actor WriteProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
}
