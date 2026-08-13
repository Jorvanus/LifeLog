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

    // MARK: - Typed diagnostic events

    // The point of the typed fields: a performance report must read them directly
    // rather than recover them by pattern-matching `message`, which was only ever
    // informally structured. These use a message with no "N ms"/"N items" text at
    // all, so a report that still gets the right numbers proves it isn't regexing.

    @Test("A budget sample's report values come from typed fields, not the message text")
    func typedReportReadsFieldsDirectly() throws {
        let context = try makeContext()
        Diagnostics.budget(context, subsystem: "Location resolver", operation: "full-store audit",
                           startedAt: .now.addingTimeInterval(-0.05), budget: 8, itemCount: 32_000)

        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        let event = try #require(events.first)
        #expect(event.diagnosticEventCode == .budgetSample)
        #expect(event.durationMs != nil)
        #expect(event.budgetMs == 8000)
        #expect(event.itemCount == 32_000)

        let report = try #require(try? JSONDecoder().decode(
            Diagnostics.PerformanceReport.self, from: Diagnostics.makePerformanceReport(events: events)))
        let sample = try #require(report.samples.first)
        #expect(sample.durationMs == event.durationMs)
        #expect(sample.budgetMs == 8000)
        #expect(sample.itemCount == 32_000)
        #expect(sample.eventCode == DiagnosticEventCode.budgetSampleRaw)
    }

    @Test("A pre-typed event is still readable through its message, with an explicit legacy code")
    func legacyMessageOnlyEventStillReports() throws {
        let context = try makeContext()
        // `.legacyMessage` set explicitly, standing in for what SwiftData's
        // lightweight migration backfills onto an existing row's new column --
        // the model's own declared default, which only that migration path
        // actually reaches; a fresh `init(...)` here would otherwise take the
        // initializer's own default of `.generic` instead.
        let legacy = DiagnosticEvent(createdAt: base, subsystem: "Insights",
                                     message: "Slow trend history: 42 ms (7 items)",
                                     category: Diagnostics.Category.performance,
                                     eventCode: DiagnosticEventCode.legacyMessage.rawValue)
        context.insert(legacy)
        try context.save()

        #expect(legacy.diagnosticEventCode == .legacyMessage)
        #expect(legacy.durationMs == nil)
        #expect(legacy.itemCount == nil)

        let report = try #require(try? JSONDecoder().decode(
            Diagnostics.PerformanceReport.self,
            from: Diagnostics.makePerformanceReport(events: try context.fetch(FetchDescriptor<DiagnosticEvent>()))))
        let sample = try #require(report.samples.first)
        // No typed field to read, so the report still recovers these from the text
        // -- the fallback this refactor keeps rather than a data loss.
        #expect(sample.durationMs == 42)
        #expect(sample.itemCount == 7)
    }

    @Test("An unrecognised event code round-trips without crashing report generation")
    func unknownEventCodeIsPreserved() throws {
        let context = try makeContext()
        context.insert(DiagnosticEvent(createdAt: base, subsystem: "Future subsystem",
                                       message: "A future build's event.",
                                       category: Diagnostics.Category.performance,
                                       eventCode: "future-typed-metric-v2", durationMs: 5))
        try context.save()

        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.first?.diagnosticEventCode == .unknown("future-typed-metric-v2"))
        let report = try #require(try? JSONDecoder().decode(
            Diagnostics.PerformanceReport.self, from: Diagnostics.makePerformanceReport(events: events)))
        #expect(report.samples.first?.eventCode == "future-typed-metric-v2")
        #expect(report.samples.first?.durationMs == 5)
    }

    // MARK: - Retention by typed category

    @Test("Performance retention is unaffected by trimming the general or location bucket")
    func retentionIsScopedByTypedCategory() throws {
        let context = try makeContext()
        for index in 0..<(Diagnostics.performanceRetentionLimit - 1) {
            context.insert(DiagnosticEvent(createdAt: base.addingTimeInterval(Double(index)),
                                           subsystem: "Test", message: "perf \(index)",
                                           category: Diagnostics.Category.performance))
        }
        try context.save()

        // Push the general/location bucket well past its own, larger limit. If
        // trimming were not scoped by category, this alone would evict the
        // performance rows inserted above even though none of them are full yet.
        for index in 0..<(Diagnostics.generalRetentionLimit + 5) {
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "location event \(index)",
                               category: DiagnosticCategory.locationRaw)
        }

        let performanceCategory = Diagnostics.Category.performance
        let locationCategory = DiagnosticCategory.locationRaw
        let performanceCount = try context.fetchCount(FetchDescriptor<DiagnosticEvent>(
            predicate: #Predicate { $0.category == performanceCategory }))
        let locationCount = try context.fetchCount(FetchDescriptor<DiagnosticEvent>(
            predicate: #Predicate { $0.category == locationCategory }))
        #expect(performanceCount == Diagnostics.performanceRetentionLimit - 1,
                "the location bucket filling up must not evict performance rows")
        #expect(locationCount == Diagnostics.generalRetentionLimit,
                "location shares the general limit, not its own unbounded one")
    }

    // MARK: - Malformed payloads

    @Test("A corrupted pending-diagnostics queue is read as empty rather than crashing")
    func corruptedPendingQueueDoesNotCrash() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not valid JSON at all {{{".utf8), forKey: PendingDiagnostics.storageKey)

        #expect(PendingDiagnostics.queued(defaults: defaults).isEmpty)
        // Queuing a fresh entry afterward must still work -- a corrupted queue is
        // not a poisoned one.
        PendingDiagnostics.queue(.init(createdAt: base, subsystem: "Store", severity: "warning",
                                       message: "recovered"), defaults: defaults)
        #expect(PendingDiagnostics.queued(defaults: defaults).count == 1)
    }

    @Test("A pending entry queued before event codes existed decodes with no code, not a crash")
    func pendingEntryMissingEventCodeDecodesAsNil() throws {
        let defaults = try makeDefaults()
        let legacyJSON = """
        [{"createdAt":\(base.timeIntervalSinceReferenceDate),"subsystem":"Store","severity":"warning","message":"A background save failed."}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: PendingDiagnostics.storageKey)

        let queued = PendingDiagnostics.queued(defaults: defaults)
        #expect(queued.count == 1)
        #expect(queued.first?.eventCode == nil)
    }

    // MARK: - Pending diagnostics when the store cannot open

    @Test("A failure recorded while the store cannot open keeps its event code once the store recovers")
    func pendingDiagnosticEventCodeSurvivesUntilTheStoreOpens() throws {
        let defaults = try makeDefaults()

        // Simulates the store-can't-open case: no context yet, so the entry can
        // only be queued to UserDefaults, exactly as `StoreProtection`'s recovery
        // path relies on.
        Diagnostics.recordDurable(nil, subsystem: "Hardware validation",
                                  message: "Core Motion returned a segment.",
                                  eventCode: .hardwareValidation, defaults: defaults)
        #expect(PendingDiagnostics.queued(defaults: defaults).count == 1)
        #expect(PendingDiagnostics.queued(defaults: defaults).first?.eventCode == DiagnosticEventCode.hardwareValidationRaw)

        // The store recovers on a later launch and the queue is flushed into it.
        let context = try makeContext()
        let flushed = Diagnostics.flushPending(context, defaults: defaults)

        #expect(flushed == 1)
        let events = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(events.first?.diagnosticEventCode == .hardwareValidation)
        #expect(PendingDiagnostics.queued(defaults: defaults).isEmpty)
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

    @Test("Hardware validation keeps the first real-device proof without repeating it")
    func hardwareValidationRecordsEachProofOnce() throws {
        let defaults = try makeDefaults()
        let context = try makeContext()

        HardwareValidation.recordFirst(.motionHistory, context: context,
                                       message: "Core Motion returned a segment.", defaults: defaults)
        HardwareValidation.recordFirst(.motionHistory, context: context,
                                       message: "Core Motion returned a segment.", defaults: defaults)

        let evidence = try context.fetch(FetchDescriptor<DiagnosticEvent>())
            .filter { $0.subsystem == "Hardware validation" }
        #expect(evidence.count == 1)
        #expect(evidence.first?.message == "Core Motion returned a segment.")
    }
}
