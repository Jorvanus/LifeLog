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

    @Test("withStoreReplacement waits for an in-flight import's coordinator before erasing, and a cancelled import leaves nothing behind")
    func storeReplacementSerializesAgainstInFlightImport() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            ActivityDefinitionRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let service = ActivityDataService()
        service.connect(context, container: container)

        let writer = try #require(await service.backgroundWriter())
        let coordinator = service.importWriteCoordinatorForTesting
        let order = OrderedEvents()
        let gate = ContinuationGate()
        let record = ActivityImportRecord(name: "Walking", activity: "Walking", source: "health-walking",
                                          start: Date(timeIntervalSince1970: 1_800_000_000),
                                          end: Date(timeIntervalSince1970: 1_800_003_600),
                                          healthKitSampleIDs: [UUID()])

        // Reproduces startImport()'s own sequencing: acquire the same coordinator
        // withStoreReplacement uses, insert an uncommitted batch (autosave is off
        // until `finish()`), then get cancelled mid-flight and roll back -- the
        // same path startImport's `catch is CancellationError` takes. `gate` makes
        // the resume-after-cancel ordering deterministic: a single `Task.yield()`
        // does not guarantee `importTask.cancel()` below actually lands before this
        // task re-checks `Task.isCancelled`, so this task waits for an explicit
        // signal the test only sends after cancelling.
        let importTask = Task {
            await coordinator.acquire()
            defer { Task { await coordinator.release() } }
            try await writer.prepare()
            _ = try await writer.insertBatch([record])
            await order.append("import inserted (uncommitted)")
            await gate.wait()
            guard !Task.isCancelled else {
                await writer.cancel()
                await order.append("import rolled back")
                return
            }
            try? await writer.finish()
        }
        // Wait for the deterministic checkpoint rather than a single Task.yield(),
        // which does not guarantee the other task has reached its own await chain.
        while await order.values.isEmpty { await Task.yield() }
        importTask.cancel()
        await gate.signal()

        // Settings' eraseAllData()/LocalBackupService.restore() both go through this
        // exact call. If it ran concurrently with the import above instead of behind
        // its coordinator, the erase could finish before the import's later `finish()`
        // resurrected the batch it just deleted.
        try await service.withStoreReplacement {
            try context.delete(model: Visit.self)
            try context.save()
        }
        await order.append("erase finished")
        try await importTask.value

        let events = await order.values
        #expect(events == ["import inserted (uncommitted)", "import rolled back", "erase finished"],
                "erase must wait for the coordinator the in-flight import already holds")

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(visits.isEmpty,
                "a cancelled import must never write through erase's own store replacement")
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

/// Suspends `wait()` until `signal()` is called, even if `signal()` runs first --
/// unlike a single `Task.yield()`, which only offers the scheduler a chance to run
/// the other side and does not guarantee it reaches any particular point.
private actor ContinuationGate {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OrderedEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
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
