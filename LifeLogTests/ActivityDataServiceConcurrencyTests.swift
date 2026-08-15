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
