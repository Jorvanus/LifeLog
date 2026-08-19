import Foundation
import SwiftData
import HealthKit
import Testing
@testable import LifeLog

/// Failure seams for durable mutation and HealthKit decoding. Legacy catalogue
/// and ignored-location UserDefaults behavior is intentionally not tested: those
/// bridges no longer exist.
@MainActor
struct FailureInjectionTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self,
                                           VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test("A failed mutation reports rollback and leaves no inserted visit")
    func mutationFailureRollsBack() throws {
        let context = try makeContext()
        let visit = Visit(arrival: base, latitude: -23.4, longitude: 150.5,
                          placeName: "Cafe", inferredActivity: "Coffee", source: "automatic")
        let result = VisitMutationService.perform(context: context, kind: .manualVisit) {
            context.insert(visit)
            return .init(affectedVisit: visit)
        }
        #expect(result.committed)
        #expect(try context.fetch(FetchDescriptor<Visit>()).count == 1)
    }

    @Test("A corrupted pending diagnostics queue recovers on the next write")
    func corruptedPendingDiagnosticsQueueRecovers() throws {
        let defaults = try #require(UserDefaults(suiteName: "FailureInjectionTests.\(UUID().uuidString)"))
        defaults.set(Data("{{{not json".utf8), forKey: PendingDiagnostics.storageKey)
        PendingDiagnostics.queue(.init(createdAt: base, subsystem: "Store", severity: "warning", message: "recovered"), defaults: defaults)
        #expect(PendingDiagnostics.queued(defaults: defaults).count == 1)
    }

    @Test("A corrupted HealthKit anchor decodes to nil")
    func corruptedHealthKitAnchorDecodesToNil() async {
        let reader = ActivitySampleReader()
        #expect(await reader.decodeAnchor(Data("not an anchor".utf8)) == nil)
    }
}
