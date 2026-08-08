import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct DiagnosticsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A suite of its own, so a test never reads or writes the app's real queue.
    private func makeDefaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: name))
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // The rule these two cover: a timing sample answers "was this slow", and only an
    // unconditional record answers "did this run". Conflating them cost four builds on
    // 8 August, when a repair that ran and a repair that never ran left the same trace.

    @Test("A fast operation leaves no timing sample at all")
    func performanceStaysSilentBelowItsThreshold() throws {
        let context = try makeContext()
        Diagnostics.performance(context, subsystem: "Timeline", operation: "a quick repair",
                                startedAt: .now)

        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.isEmpty, "this is the silence that made 'ran' and 'never ran' identical")
    }

    @Test("A budget sample records whether or not it was slow")
    func budgetRecordsEveryTime() throws {
        let context = try makeContext()
        Diagnostics.budget(context, subsystem: "Launch", operation: "responsive first screen",
                           startedAt: .now, budget: 10)

        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.count == 1)
        #expect(events.first?.message.contains("Budget pass") == true)
        // Kept out of the general bucket so chatty location logging cannot evict it.
        #expect(events.first?.category == Diagnostics.Category.performance)
    }

    @Test("A queued failure outlives the process that recorded it")
    func queuedFailureSurvivesInDefaults() throws {
        let defaults = try makeDefaults()
        PendingDiagnostics.queue(.init(createdAt: base, subsystem: "Store", severity: "warning",
                                       message: "A background save failed."), defaults: defaults)

        // Reading through a second handle on the same suite is what a relaunch does:
        // nothing is held in memory, the record is on disk or it is gone.
        let reloaded = PendingDiagnostics.queued(defaults: defaults)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.createdAt == base)
        #expect(reloaded.first?.message == "A background save failed.")
    }

    @Test("Flushing moves queued failures into the store and empties the queue")
    func flushWritesPendingIntoTheStore() throws {
        let defaults = try makeDefaults()
        let context = try makeContext()
        PendingDiagnostics.queue(.init(createdAt: base, subsystem: "Store", severity: "warning",
                                       message: "A background save failed (NSCocoaErrorDomain 513)."),
                                 defaults: defaults)

        let flushed = Diagnostics.flushPending(context, defaults: defaults)

        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(flushed == 1)
        #expect(events.count == 1)
        #expect(events.first?.subsystem == "Store")
        #expect(events.first?.createdAt == base, "the failure is logged when it happened, not when it was flushed")
        #expect(PendingDiagnostics.queued(defaults: defaults).isEmpty)
    }

    @Test("Flushing an empty queue does nothing")
    func flushWithNothingQueuedIsANoOp() throws {
        let defaults = try makeDefaults()
        let context = try makeContext()

        #expect(Diagnostics.flushPending(context, defaults: defaults) == 0)
        #expect(try context.fetch(FetchDescriptor<DiagnosticEvent>()).isEmpty)
    }

    @Test("A store that keeps failing cannot flood the queue, and keeps the first failures")
    func queueIsBoundedAndKeepsTheOldest() throws {
        let defaults = try makeDefaults()
        for index in 0..<(PendingDiagnostics.queueLimit + 20) {
            PendingDiagnostics.queue(.init(createdAt: base.addingTimeInterval(Double(index)),
                                           subsystem: "Store", severity: "warning",
                                           message: "failure \(index)"), defaults: defaults)
        }

        let queued = PendingDiagnostics.queued(defaults: defaults)
        #expect(queued.count == PendingDiagnostics.queueLimit)
        #expect(queued.first?.message == "failure 0", "the earliest failure explains how it started")
        #expect(queued.last?.message == "failure \(PendingDiagnostics.queueLimit - 1)")
    }

    @Test("A failure recorded with no store still survives")
    func durableRecordWithoutAContextIsStillKept() throws {
        let defaults = try makeDefaults()

        Diagnostics.recordDurable(nil, subsystem: "Store", message: "A background save failed.",
                                  defaults: defaults)

        #expect(PendingDiagnostics.queued(defaults: defaults).count == 1)
    }

    @Test("A failure recorded with a working store reaches Diagnostics immediately")
    func durableRecordWithAContextIsLoggedAtOnce() throws {
        let defaults = try makeDefaults()
        let context = try makeContext()

        Diagnostics.recordDurable(context, subsystem: "Store", message: "A background save failed.",
                                  defaults: defaults)

        #expect(try context.fetch(FetchDescriptor<DiagnosticEvent>()).count == 1)
        #expect(PendingDiagnostics.queued(defaults: defaults).isEmpty)
    }
}
