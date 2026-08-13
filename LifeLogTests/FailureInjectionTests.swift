import Foundation
import SwiftData
import HealthKit
import Testing
@testable import LifeLog

/// Exercises the failure paths the `try?` audit turned up: a protected/failed
/// store save must never look like a completed mutation, corrupt `UserDefaults`
/// content must fall back safely and distinguishably from "nothing stored yet",
/// and a corrupted HealthKit anchor must decode to "no anchor" rather than crash.
@MainActor
struct FailureInjectionTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            LocationEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A read-only store configuration is the closest in-process stand-in for a
    /// protected file `NSFileProtectionComplete` would refuse to write to:
    /// `context.save()` throws for the same reason in both cases. Needs a real,
    /// already-existing on-disk file -- `allowsSave: false` against a URL with
    /// no store there yet fails to open at all (SQLite has nothing to open
    /// read-only), and combining it with `isStoredInMemoryOnly` makes SwiftData
    /// try to open `/dev/null` instead. So the store is created writable first,
    /// then reopened read-only at the same URL.
    private func makeProtectedContext() throws -> ModelContext {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FailureInjection-\(UUID().uuidString).store")
        _ = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            LocationEvent.self,
            configurations: ModelConfiguration(url: url)
        )
        let configuration = ModelConfiguration(url: url, allowsSave: false)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
            LocationEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    // MARK: - Protected store / failed save

    @Test("VisitMutationService rolls back rather than reporting success against a protected store")
    func mutationServiceRollsBackOnProtectedStore() throws {
        let context = try makeProtectedContext()
        let visit = Visit(arrival: base, latitude: -23.4, longitude: 150.5,
                          placeName: "Cafe", inferredActivity: "Coffee", source: "automatic")

        let result = VisitMutationService.perform(context: context, kind: .manualVisit) {
            context.insert(visit)
            return .init(affectedVisit: visit)
        }

        #expect(result.status == .rolledBack)
        #expect(result.failureDescription != nil)
        // The insert must not have survived the rollback -- a caller checking
        // only `result.committed` and a caller re-querying the store must agree.
        #expect(try context.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    @Test("A merge/delete-shaped mutation against a protected store never appears committed")
    func savedPlaceChangeRollsBackOnProtectedStore() throws {
        let context = try makeProtectedContext()
        let place = SavedPlace(name: "Old Cafe", latitude: -23.4, longitude: 150.5)

        let result = VisitMutationService.perform(context: context, kind: .savedPlaceChange) {
            context.insert(place)
            context.delete(place)
            return .init(changedCount: 1)
        }

        // This is exactly the shape `LocationDetailView.merge`/the delete
        // confirmation use: insert/mutate, delete, then one `.finalize` call.
        // The view now checks `mutation.committed` before dismissing; this
        // confirms that check has something real to fail on.
        #expect(result.status == .rolledBack)
        #expect(!result.committed)
    }

    @Test("A local backup restore leaves no partial data when the destination store cannot save")
    func backupRestoreDoesNotPartiallyApplyOnProtectedStore() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, latitude: -23.4, longitude: 150.5,
                                   placeName: "Cafe", inferredActivity: "Coffee", source: "automatic"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let protectedContext = try makeProtectedContext()
        #expect(throws: (any Error).self) {
            try LocalBackupService.restore(data, into: protectedContext)
        }
        #expect(try protectedContext.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    // MARK: - Corrupt UserDefaults JSON

    @Test("ActivityCatalog.load distinguishes corrupt stored data from no data at all")
    func activityCatalogLoadDistinguishesMissingFromCorrupt() throws {
        let suite = try #require(UserDefaults(suiteName: "FailureInjectionTests.\(UUID().uuidString)"))

        ActivityCatalog.withStorage(suite) {
            let freshInstall = ActivityCatalog.load()
            #expect(!freshInstall.isEmpty, "a fresh install still gets the built-in catalogue")
            #expect(ActivityCatalog.lastLoadWasCorrupt == false)

            suite.set(Data("not valid JSON at all {{{".utf8), forKey: "LifeLog.ActivityCatalog.v1")
            let afterCorruption = ActivityCatalog.load()
            #expect(!afterCorruption.isEmpty, "corrupt data still falls back to the built-in catalogue")
            #expect(ActivityCatalog.lastLoadWasCorrupt == true,
                    "corrupt bytes must be distinguishable from a store that was simply never written")

            // A later, valid save clears the flag -- it does not stick past the
            // condition that set it.
            ActivityCatalog.save(afterCorruption)
            _ = ActivityCatalog.load()
            #expect(ActivityCatalog.lastLoadWasCorrupt == false)
        }
    }

    @Test("A corrupted pending-diagnostics queue does not prevent later diagnostics from queuing")
    func corruptedPendingDiagnosticsQueueRecoversOnNextWrite() throws {
        let defaults = try #require(UserDefaults(suiteName: "FailureInjectionTests.\(UUID().uuidString)"))
        defaults.set(Data("{{{not json".utf8), forKey: PendingDiagnostics.storageKey)

        #expect(PendingDiagnostics.queued(defaults: defaults).isEmpty)

        PendingDiagnostics.queue(.init(createdAt: base, subsystem: "Store", severity: "warning",
                                       message: "recovered after corruption"), defaults: defaults)

        let queued = PendingDiagnostics.queued(defaults: defaults)
        #expect(queued.count == 1)
        #expect(queued.first?.message == "recovered after corruption")
    }

    // MARK: - HealthKit anchor encoding/decoding

    @Test("A corrupted HealthKit anchor decodes to nil rather than crashing")
    func corruptedHealthKitAnchorDecodesToNil() async {
        let reader = ActivitySampleReader()
        let corrupt = Data("not an archived HKQueryAnchor".utf8)

        let decoded = await reader.decodeAnchor(corrupt)

        #expect(decoded == nil)
    }

    @Test("Missing and corrupted HealthKit anchor data are indistinguishable, both nil")
    func missingAndCorruptedHealthKitAnchorsMatch() async {
        let reader = ActivitySampleReader()

        let fromNil = await reader.decodeAnchor(nil)
        let fromEmpty = await reader.decodeAnchor(Data())
        let fromCorrupt = await reader.decodeAnchor(Data([0xFF, 0x00, 0x01]))

        #expect(fromNil == nil)
        #expect(fromEmpty == nil)
        #expect(fromCorrupt == nil)
    }

    @Test("A HealthKit anchor round-trips through encode/decode")
    func healthKitAnchorRoundTrips() async {
        let reader = ActivitySampleReader()
        let anchor = HKQueryAnchor(fromValue: 42)

        let encoded = await reader.encodeAnchor(anchor)
        let decoded = await reader.decodeAnchor(encoded)

        #expect(decoded != nil)
    }
}
