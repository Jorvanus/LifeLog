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
            case .savedPlaceChange, .bulkHistoricalCorrection, .backupRestore:
                return .init(resolution: .fullAudit, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: kind.rawValue)
            case .relaunchRecovery:
                return .init(resolution: .none, requiresPlaceScoring: false,
                             invalidatedScopes: [.timeline, .insights, .places, .travel],
                             diagnosticOperation: "bounded relaunch recovery")
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
    ///
    /// `restore` undoes whatever property mutations `mutate` (or the caller, just
    /// before calling this) already applied to a live model object. `context.rollback()`
    /// alone is not enough for that: it discards the context's pending-save diff, so
    /// the persisted store is correctly left untouched, but it does not revert an
    /// already-written Swift property back to its prior value on the *same* live
    /// object instance -- confirmed directly against this SDK, not assumed from
    /// documentation. Any other code still holding that same reference (another open
    /// editor, a `@Query`) would otherwise keep showing the failed edit indefinitely,
    /// which is exactly the "partial state" this method exists to prevent. Callers
    /// that mutate a model must snapshot the fields they are about to touch and pass
    /// a closure here that puts them back; `restore` defaults to a no-op only for
    /// call sites where `mutate` builds its `Change` without touching a live model
    /// first (a still-unsaved, freshly inserted object, say).
    static func perform(context: ModelContext, kind: Kind,
                        mutate: () throws -> Change, restore: () -> Void = {}) -> Result {
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
            // protected-store failure. `restore()` undoes the live in-memory mutation
            // `context.rollback()` alone cannot touch (see the doc comment above).
            context.rollback()
            restore()
            return .init(kind: kind, status: .rolledBack, resolution: policy.resolution,
                         changedCount: 0, invalidatedScopes: [],
                         failureDescription: error.localizedDescription)
        }
    }

    /// Bridges existing callback code while it is migrated in small steps. The
    /// callback has already applied its raw Core Location fields; this method owns
    /// the coupled resolver/save/publication tail and rolls those fields back on
    /// failure rather than letting a `try?` leave them half-visible -- `restore`
    /// is how a caller that mutated its model before calling this actually
    /// delivers on that; see `perform`'s doc comment for why `rollback()` alone
    /// cannot.
    static func finalize(context: ModelContext, kind: Kind, change: Change, restore: () -> Void = {}) -> Result {
        perform(context: context, kind: kind, mutate: { change }, restore: restore)
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

extension Visit {
    /// Every field a caller might mutate before handing this visit to
    /// `VisitMutationService.perform`/`finalize` — taken so a failed mutation can
    /// be handed back to `restore`, undoing exactly what was changed. See
    /// `VisitMutationService.perform`'s doc comment for why `context.rollback()`
    /// alone cannot do this for a live, already-fetched object.
    struct MutableSnapshot {
        let arrival: Date
        let departure: Date?
        let latitude: Double
        let longitude: Double
        let placeName: String
        let inferredActivity: String
        let userActivity: String?
        let activityDefinitionID: UUID?
        let note: String
        let recognitionConfidence: String?
        let mapsIdentifier: String?
        let placeFieldProvenance: String?
        let resolutionExplanation: String?
        let resolutionState: VisitResolutionState
    }

    var mutableSnapshot: MutableSnapshot {
        .init(arrival: arrival, departure: departure, latitude: latitude, longitude: longitude,
              placeName: placeName, inferredActivity: inferredActivity, userActivity: userActivity,
              activityDefinitionID: activityDefinitionID, note: note,
              recognitionConfidence: recognitionConfidence, mapsIdentifier: mapsIdentifier,
              placeFieldProvenance: placeFieldProvenance, resolutionExplanation: resolutionExplanation,
              resolutionState: resolutionState)
    }

    /// Puts every field `mutableSnapshot` captured back exactly as it was.
    /// `actor: .user` for the resolution state, not `.automation`: this is
    /// undoing a rejected edit, not automation reaching a new conclusion, and
    /// `.user` is the one actor `setResolutionState`'s guards never block —
    /// a restore must always succeed regardless of what state it's undoing.
    func restore(_ snapshot: MutableSnapshot) {
        arrival = snapshot.arrival
        departure = snapshot.departure
        latitude = snapshot.latitude
        longitude = snapshot.longitude
        placeName = snapshot.placeName
        inferredActivity = snapshot.inferredActivity
        userActivity = snapshot.userActivity
        activityDefinitionID = snapshot.activityDefinitionID
        note = snapshot.note
        recognitionConfidence = snapshot.recognitionConfidence
        mapsIdentifier = snapshot.mapsIdentifier
        placeFieldProvenance = snapshot.placeFieldProvenance
        resolutionExplanation = snapshot.resolutionExplanation
        setResolutionState(snapshot.resolutionState, actor: .user)
    }
}

extension SavedPlace {
    /// The `SavedPlace` counterpart to `Visit.MutableSnapshot` — `SavedPlaceLearning.upsert`
    /// and the Places screens mutate an *existing* saved place directly, the same
    /// live-reference hazard `VisitMutationService.perform`'s doc comment describes.
    struct MutableSnapshot {
        let name: String
        let latitude: Double
        let longitude: Double
        let radius: Double
        let defaultActivity: String
        let activityDefinitionID: UUID?
        let mapsIdentifier: String?
        let role: String?
    }

    var mutableSnapshot: MutableSnapshot {
        .init(name: name, latitude: latitude, longitude: longitude, radius: radius,
              defaultActivity: defaultActivity, activityDefinitionID: activityDefinitionID,
              mapsIdentifier: mapsIdentifier, role: role)
    }

    func restore(_ snapshot: MutableSnapshot) {
        name = snapshot.name
        latitude = snapshot.latitude
        longitude = snapshot.longitude
        radius = snapshot.radius
        defaultActivity = snapshot.defaultActivity
        activityDefinitionID = snapshot.activityDefinitionID
        mapsIdentifier = snapshot.mapsIdentifier
        role = snapshot.role
    }
}
