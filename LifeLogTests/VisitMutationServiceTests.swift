import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct VisitMutationServiceTests {
    @Test("Every supported mutation has an explicit resolution and cache contract")
    func supportedMutationPoliciesAreExplicit() {
        let expected: [VisitMutationService.Kind: VisitMutationService.Resolution] = [
            .coreLocationArrival: .incremental,
            .coreLocationDeparture: .incremental,
            .visitEdit: .incremental,
            .ignoreChange: .incremental,
            .savedPlaceChange: .fullAudit,
            .manualVisit: .incremental,
            .importBatch: .none,
            .healthKitChange: .none,
            .bulkHistoricalCorrection: .fullAudit,
            .backupRestore: .fullAudit,
            .relaunchRecovery: .fullAudit
        ]

        #expect(Set(expected.keys) == Set(VisitMutationService.Kind.allCases))
        for kind in VisitMutationService.Kind.allCases {
            let policy = VisitMutationService.Policy.forKind(kind)
            #expect(policy.resolution == expected[kind])
            #expect(!policy.invalidatedScopes.isEmpty)
            #expect(!policy.diagnosticOperation.isEmpty)
        }
    }

    @Test("A committed mutation resolves and invalidates exactly once after its save")
    func committedMutationPublishesOnce() throws {
        let context = try makeContext()
        let visit = Visit(arrival: .now, departure: .now.addingTimeInterval(60),
                          latitude: -27.47, longitude: 153.03, placeName: "Home",
                          inferredActivity: "At home", source: "manual")
        var invalidations = 0
        let observer = NotificationCenter.default.addObserver(forName: InsightsInvalidation.notification,
                                                               object: nil, queue: nil) { _ in invalidations += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = VisitMutationService.perform(context: context, kind: .manualVisit) {
            context.insert(visit)
            return .init(affectedVisit: visit, coordinate: visit.coordinate)
        }

        #expect(result.committed)
        #expect(result.resolution == .incremental)
        #expect(invalidations == 1)
        #expect(try context.fetchCount(FetchDescriptor<Visit>()) == 1)
        #expect(try context.fetch(FetchDescriptor<DiagnosticEvent>()).filter {
            $0.subsystem == "Visit mutation" && $0.message.contains("manual visit")
        }.count == 1)
    }

    @Test("A failed mutation rolls back before it can invalidate Insights")
    func failedMutationDoesNotPublishPartialState() throws {
        let context = try makeContext()
        let original = Visit(arrival: .now, departure: .now.addingTimeInterval(60),
                             latitude: -27.47, longitude: 153.03, placeName: "Home",
                             inferredActivity: "At home", source: "manual")
        context.insert(original)
        try context.save()
        var invalidations = 0
        let observer = NotificationCenter.default.addObserver(forName: InsightsInvalidation.notification,
                                                               object: nil, queue: nil) { _ in invalidations += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = VisitMutationService.perform(context: context, kind: .visitEdit) {
            original.placeName = "Unsaved replacement"
            throw TestFailure.expected
        }

        #expect(!result.committed)
        #expect(invalidations == 0)
        #expect(original.placeName == "Home")
        #expect(try context.fetch(FetchDescriptor<DiagnosticEvent>()).filter {
            $0.subsystem == "Visit mutation"
        }.isEmpty)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           DiagnosticEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private enum TestFailure: Error { case expected }
}
