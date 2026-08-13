import CoreLocation
import SwiftData

/// Coordinates only visit and Saved Place mutations whose derived timeline and
/// Insights state must agree. It is deliberately not a repository: reads and
/// unrelated SwiftData writes remain direct, while these coupled writes get one
/// resolver, one save, and publication only after that save succeeds.
@MainActor
struct VisitMutationService {
    enum Kind: String, CaseIterable, Sendable {
        case coreLocationArrival
        case coreLocationDeparture
        case visitEdit
        case ignoreChange
        case savedPlaceChange
        case manualVisit
        case importBatch
        case healthKitChange
        case bulkHistoricalCorrection
        case backupRestore
        case relaunchRecovery
    }

    enum Resolution: Sendable, Equatable {
        case none
        case incremental
        case fullAudit
    }

    struct Policy: Sendable, Equatable {
        let resolution: Resolution
        let requiresPlaceScoring: Bool
        let invalidatedScopes: Set<InsightsInvalidation.Scope>
        let diagnosticOperation: String

        static func forKind(_ kind: Kind) -> Policy {
            switch kind {
            case .coreLocationArrival:
                return .init(resolution: .incremental, requiresPlaceScoring: true,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: "location arrival")
            case .coreLocationDeparture:
                return .init(resolution: .incremental, requiresPlaceScoring: true,
                             invalidatedScopes: [.timeline, .insights, .travel],
                             diagnosticOperation: "location departure")
            case .visitEdit:
                return .init(resolution: .incremental, requiresPlaceScoring: true,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: "visit edit")
            case .manualVisit:
                // A hand-entered visit is already the person's chosen answer; unlike
                // a location callback it has no Maps evidence to score or replace.
                return .init(resolution: .incremental, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: "manual visit")
            case .ignoreChange:
                return .init(resolution: .incremental, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .places],
                             diagnosticOperation: "visit ignore change")
            case .savedPlaceChange, .bulkHistoricalCorrection, .backupRestore, .relaunchRecovery:
                return .init(resolution: .fullAudit, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: kind.rawValue)
            case .importBatch, .healthKitChange:
                return .init(resolution: .none, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .travel],
                             diagnosticOperation: kind == .importBatch ? "import batch" : "HealthKit change")
            }
        }
    }

    /// The mutation closure returns the visit whose neighbouring timeline is allowed
    /// to change. A full audit deliberately does not need one; imports and HealthKit
    /// changes already maintain their own bounded reconciliation before completion.
    struct Change {
        let affectedVisit: Visit?
        let callbackInterval: DateInterval?
        let coordinate: CLLocationCoordinate2D?
        let changedCount: Int
        let placeScoreAlreadyApplied: Bool

        init(affectedVisit: Visit? = nil, callbackInterval: DateInterval? = nil,
             coordinate: CLLocationCoordinate2D? = nil, changedCount: Int = 1,
             placeScoreAlreadyApplied: Bool = false) {
            self.affectedVisit = affectedVisit
            self.callbackInterval = callbackInterval
            self.coordinate = coordinate
            self.changedCount = changedCount
            self.placeScoreAlreadyApplied = placeScoreAlreadyApplied
        }
    }

    struct Result: Equatable {
        enum Status: Equatable { case committed, rolledBack }
        let kind: Kind
        let status: Status
        let resolution: Resolution
        let changedCount: Int
        let invalidatedScopes: Set<InsightsInvalidation.Scope>
        let failureDescription: String?

        var committed: Bool { status == .committed }
    }

    /// Runs a coupled mutation as one publication unit. `InsightsInvalidation` is
    /// intentionally last: observers can never rebuild an Insights snapshot from an
    /// unsaved or resolver-failed intermediate timeline.
    static func perform(context: ModelContext, kind: Kind,
                        mutate: () throws -> Change) -> Result {
        let policy = Policy.forKind(kind)
        do {
            let change = try mutate()
            if policy.requiresPlaceScoring, !change.placeScoreAlreadyApplied, let visit = change.affectedVisit {
                _ = PlaceScoreLifecycle.rescore(visit, stage: .correction, context: context)
            }
            try resolve(policy: policy, change: change, context: context)
            Diagnostics.stage(context, subsystem: "Visit mutation",
                              message: "Committed \(policy.diagnosticOperation); \(change.changedCount) change(s).",
                              severity: "info")
            try context.save()
            if !policy.invalidatedScopes.isEmpty {
                InsightsInvalidation.invalidate(scopes: policy.invalidatedScopes,
                                                reason: policy.diagnosticOperation,
                                                context: context, recordsDiagnostic: false)
            }
            return .init(kind: kind, status: .committed, resolution: policy.resolution,
                         changedCount: change.changedCount, invalidatedScopes: policy.invalidatedScopes,
                         failureDescription: nil)
        } catch {
            // No notification has been published yet. Discard the context's pending
            // edits too, so @Query cannot expose half a correction after a resolver or
            // protected-store failure.
            context.rollback()
            return .init(kind: kind, status: .rolledBack, resolution: policy.resolution,
                         changedCount: 0, invalidatedScopes: [],
                         failureDescription: error.localizedDescription)
        }
    }

    /// Bridges existing callback code while it is migrated in small steps. The
    /// callback has already applied its raw Core Location fields; this method owns
    /// the coupled resolver/save/publication tail and rolls those fields back on
    /// failure rather than letting a `try?` leave them half-visible.
    static func finalize(context: ModelContext, kind: Kind, change: Change) -> Result {
        perform(context: context, kind: kind) { change }
    }

    private static func resolve(policy: Policy, change: Change, context: ModelContext) throws {
        switch policy.resolution {
        case .none:
            return
        case .incremental:
            guard let visit = change.affectedVisit else {
                throw MutationError.incrementalMutationNeedsVisit
            }
            _ = try ActivityLocationPolicy.resolveAfterLocationMutation(
                context: context,
                mutation: .init(affectedVisit: visit, callbackInterval: change.callbackInterval,
                                coordinate: change.coordinate, reason: policy.diagnosticOperation)
            )
        case .fullAudit:
            _ = try ActivityLocationPolicy.runFullStoreAudit(context: context, reason: policy.diagnosticOperation)
        }
    }

    private enum MutationError: LocalizedError {
        case incrementalMutationNeedsVisit

        var errorDescription: String? { "This visit mutation needs its affected visit to resolve safely." }
    }
}
