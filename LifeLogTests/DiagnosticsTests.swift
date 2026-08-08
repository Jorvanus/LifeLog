import Foundation
import SwiftData
import Testing
import CoreLocation
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
            LocationEvent.self,
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

    // MARK: - Location journal

    // This is the one thing in the store that holds precise coordinates, so the switch
    // guarding it is not a preference — it is the whole basis on which it is allowed to
    // exist. These run it both ways rather than trusting the guard by reading it.

    @Test("Nothing is journalled while detailed diagnostics are off")
    func journalStaysEmptyWhenNotDetailed() throws {
        let context = try makeContext()
        let previous = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = previous }
        LocationDiagnostics.isDetailed = false

        LocationJournal.record("visit-arrival",
                               at: CLLocationCoordinate2D(latitude: -23.4455, longitude: 150.4522),
                               callbackAt: base, arrival: base, accuracy: 12,
                               transition: .created, context: context)

        #expect(try context.fetch(FetchDescriptor<LocationEvent>()).isEmpty,
                "an off switch that still records is not an off switch")
    }

    @Test("A callback is journalled with its timing, accuracy and chosen transition")
    func journalRecordsTheCallback() throws {
        let context = try makeContext()
        let previous = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = previous }
        LocationDiagnostics.isDetailed = true

        let open = Visit(arrival: base, latitude: -23.4455, longitude: 150.4522,
                         placeName: "Home", inferredActivity: "At home", source: "automatic")
        context.insert(open)
        // ~350 m north of the open stay.
        LocationJournal.record("visit-arrival",
                               at: CLLocationCoordinate2D(latitude: -23.4424, longitude: 150.4522),
                               callbackAt: base, arrival: base.addingTimeInterval(60),
                               accuracy: 12, transition: .created, openVisit: open, context: context)

        let events = try context.fetch(FetchDescriptor<LocationEvent>())
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.callbackType == "visit-arrival")
        #expect(event.transition == "created")
        #expect(event.accuracy == 12)
        #expect(event.visitArrival == base)
        let distance = try #require(event.distanceFromCurrentVisit)
        #expect(distance > 300 && distance < 400)
    }

    @Test("With no stay open, the distance is absent rather than zero")
    func journalDistinguishesNoOpenStayFromZeroDistance() throws {
        let context = try makeContext()
        let previous = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = previous }
        LocationDiagnostics.isDetailed = true

        LocationJournal.record("location-update",
                               at: CLLocationCoordinate2D(latitude: -23.4455, longitude: 150.4522),
                               callbackAt: base, accuracy: 65, context: context)

        let event = try #require(try context.fetch(FetchDescriptor<LocationEvent>()).first)
        // "Nothing was running" and "the callback was exactly here" are different facts
        // and only one of them is a distance.
        #expect(event.distanceFromCurrentVisit == nil)
        #expect(event.visitArrival == nil)
    }

    @Test("The journal is trimmed to its limit, oldest first")
    func journalIsTrimmed() throws {
        let context = try makeContext()
        let previous = LocationDiagnostics.isDetailed
        defer { LocationDiagnostics.isDetailed = previous }
        LocationDiagnostics.isDetailed = true

        // Two past the limit, inserted directly so the test is about trimming rather
        // than about writing five hundred rows through the recorder. Stamped in the
        // past relative to now, because `record` stamps its own row with `.now` and
        // trimming is by `recordedAt` — fixtures dated in the future would make the
        // new row the oldest and see it dropped the moment it was written.
        let oldest = Date.now.addingTimeInterval(-Double(LocationJournal.retentionLimit + 2) * 60)
        for index in 0..<(LocationJournal.retentionLimit + 2) {
            context.insert(LocationEvent(recordedAt: oldest.addingTimeInterval(Double(index) * 60),
                                         callbackType: "location-update",
                                         callbackAt: base.addingTimeInterval(Double(index)),
                                         latitude: -23.4455, longitude: 150.4522, accuracy: 10))
        }
        try context.save()
        let marker = base.addingTimeInterval(10_000)
        LocationJournal.record("location-update",
                               at: CLLocationCoordinate2D(latitude: -23.4455, longitude: 150.4522),
                               callbackAt: marker, accuracy: 10, context: context)

        let events = try context.fetch(FetchDescriptor<LocationEvent>())
        #expect(events.count == LocationJournal.retentionLimit)
        // The oldest went, not the newest: a log that drops what just happened is
        // useless for the thing that just went wrong.
        #expect(!events.contains { $0.recordedAt == oldest })
        #expect(events.contains { $0.callbackAt == marker })
    }

    @Test("Clearing the journal empties it")
    func journalClears() throws {
        let context = try makeContext()
        for index in 0..<3 {
            context.insert(LocationEvent(callbackType: "location-update",
                                         callbackAt: base.addingTimeInterval(Double(index)),
                                         latitude: -23.4455, longitude: 150.4522, accuracy: 10))
        }
        try context.save()

        #expect(LocationJournal.clear(context) == 3)
        #expect(try context.fetch(FetchDescriptor<LocationEvent>()).isEmpty)
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
