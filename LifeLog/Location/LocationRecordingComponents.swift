import CoreLocation
import SwiftData

/// The only Core Location-shaped values allowed past the delegate boundary.
/// Capturing `now` here keeps delayed callback handling deterministic in tests.
enum CoreLocationEvent: Sendable {
    case authorizationChanged(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization)
    case visitArrival(coordinate: CLLocationCoordinate2D, arrival: Date, accuracy: CLLocationAccuracy, callbackDelay: TimeInterval)
    case visitDeparture(coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date, accuracy: CLLocationAccuracy)
    case locationSample(LocationCallbackSample)
    case failure(LocationFailure)
}

/// The useful, Sendable part of an NSError captured at the delegate boundary.
/// Core Location's Error cannot cross into typed event handling itself, but reducing
/// it to a generic failure used to discard the only reason the framework supplied.
struct LocationFailure: Sendable, Equatable {
    let domain: String
    let code: Int
    let description: String

    init(_ error: Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        description = error.localizedDescription
    }

    var diagnosticMessage: String {
        "A location update failed (\(domain) \(code)): \(description)"
    }
}

struct LocationCallbackSample: Sendable {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let accuracy: CLLocationAccuracy
}

struct CoreLocationEventAdapter {
    var now: @Sendable () -> Date = { .now }

    func event(for visit: CLVisit) -> CoreLocationEvent? {
        guard visit.coordinate.latitude.isFinite, visit.coordinate.longitude.isFinite else { return nil }
        if visit.departureDate == .distantFuture {
            return .visitArrival(coordinate: visit.coordinate, arrival: visit.arrivalDate,
                                 accuracy: visit.horizontalAccuracy,
                                 callbackDelay: now().timeIntervalSince(visit.arrivalDate))
        }
        return .visitDeparture(coordinate: visit.coordinate, arrival: visit.arrivalDate,
                               departure: visit.departureDate, accuracy: visit.horizontalAccuracy)
    }

    func event(for locations: [CLLocation]) -> CoreLocationEvent? {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSince(now())) <= 5 * 60 else { return nil }
        return .locationSample(.init(coordinate: location.coordinate, timestamp: location.timestamp,
                                     accuracy: location.horizontalAccuracy))
    }
}

/// Keeps coupled SwiftData resolution and publication behind the one mutation service.
struct LocationMutationCoordinator {
    var finalize: @MainActor (ModelContext, VisitMutationService.Kind, VisitMutationService.Change) -> VisitMutationService.Result

    init(finalize: @escaping @MainActor (ModelContext, VisitMutationService.Kind, VisitMutationService.Change) -> VisitMutationService.Result = { context, kind, change in
        VisitMutationService.finalize(context: context, kind: kind, change: change)
    }) {
        self.finalize = finalize
    }
}

/// A small injectable holder for callback evidence. Persisting remains opt-in through
/// the existing LocationJournal detail setting, preserving the current diagnostics policy.
struct LocationDiagnosticsRecorder {
    var record: @MainActor (_ context: ModelContext?, _ message: String, _ severity: String) -> Void

    init(record: @escaping @MainActor (_ context: ModelContext?, _ message: String, _ severity: String) -> Void = { context, message, severity in
        Diagnostics.record(context, subsystem: "Core Location", message: message, severity: severity)
    }) {
        self.record = record
    }
}

/// Explicitly identifies the recovery paths that are allowed to start background work.
enum LocationRecoveryCoordinator {
    static func shouldStartBackgroundWorkflow(enabled: Bool, authorization: CLAuthorizationStatus) -> Bool {
        enabled && authorization != .notDetermined
    }

    /// Whether `LocationRecorder.holdServiceSession` must build a new
    /// `CLServiceSession`, given what it is holding and what is being asked for.
    ///
    /// The decision used to be `held != required` alone, which made a dead session
    /// permanent: the recorder kept the requirement of a session whose diagnostic
    /// stream had already ended, so a restart matched the stale requirement and
    /// returned without creating a replacement. Background recording then stayed off
    /// until the app was quit and reopened. `hasLiveSession` is the missing half —
    /// matching a requirement means nothing if nothing is actually holding it.
    static func shouldRebuildServiceSession(held: CLServiceSession.AuthorizationRequirement?,
                                            hasLiveSession: Bool,
                                            required: CLServiceSession.AuthorizationRequirement) -> Bool {
        held != required || !hasLiveSession
    }
}

/// Pure geofence planning seam; the monitor owns iOS registration while this keeps
/// selection deterministic and testable without Core Location hardware.
enum GeofenceMonitor {
    static func desired(_ places: [SavedPlace], visits: [Visit]) -> [MonitoredPlaces.Ranked] {
        Array(MonitoredPlaces.prioritised(places, visits: visits, limit: .max).prefix(MonitoredPlaces.limit))
    }

    /// What must change to bring the monitored region set to exactly `wanted`,
    /// given the identifiers currently registered with `CLMonitor`. Pure so the
    /// reconciliation decision -- the "monitored-region synchronisation" the
    /// recorder used to work out inline against the live monitor -- is testable
    /// without one.
    ///
    /// A single snapshot of `monitoredIdentifiers` is enough even though the
    /// recorder applies removals before additions: every identifier this plan
    /// removes is, by construction, one `wanted` does not contain, so it can
    /// never also be a "keep" candidate `toAdd` needs to exclude.
    static func plan(wanted: [MonitoredPlaces.Ranked], monitoredIdentifiers: Set<String>)
    -> (toAdd: [MonitoredPlaces.Ranked], toRemove: [String]) {
        let wantedIDs = Set(wanted.map(\.identifier))
        let toRemove = monitoredIdentifiers.subtracting(wantedIDs)
        let toAdd = wanted.filter { !monitoredIdentifiers.contains($0.identifier) }
        return (toAdd, Array(toRemove))
    }
}

/// A confirmed or pending arrival's evidence, carried from the callback that
/// noticed it (a `CLVisit`, a geofence, or nothing at all for a launch-time
/// check) through to whichever live-location burst confirms or discards it.
struct PendingArrival: Sendable {
    let coordinate: CLLocationCoordinate2D?
    let arrival: Date
    let callbackType: LocationCallbackType
    let accuracy: CLLocationAccuracy
}

/// Owns the live-location confirmation burst's state machine independently of
/// `CLLocationManager`: the pure `ArrivalConfirmationEngine`'s samples, the
/// pending arrival they are confirming (if any), the burst and timeout tasks'
/// lifecycle, and callers waiting for the burst to finish.
///
/// `LocationRecorder` still owns interpreting a raw `CLLocationUpdate`, the
/// resulting Visit mutation, and every diagnostic around them -- this
/// collaborator never touches SwiftData. It exists so that bookkeeping (is a
/// burst already running, should a new pending arrival supersede it, has the
/// sample limit been reached, who is still awaiting completion) is not five
/// separate stored properties on the recorder mutated from several methods.
@MainActor
final class ArrivalConfirmationSession {
    /// A finished burst's evidence, exactly as `LocationRecorder` needs to
    /// decide what to do next -- confirm, fall back to the pending arrival's
    /// own coordinate, or discard.
    struct Outcome {
        let confirmedLocation: CLLocation?
        let pendingArrival: PendingArrival?
        let sampleCount: Int
    }

    private var engine: ArrivalConfirmationEngine?
    private(set) var pendingArrival: PendingArrival?
    private var burstTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isActive: Bool { engine != nil }
    var startedAt: Date? { engine?.startedAt }
    var hasReachedSampleLimit: Bool { engine?.hasReachedSampleLimit ?? false }

    /// Starts a new burst unless one is already active for the same kind of
    /// check. A `CLVisit` arrival supersedes an in-flight launch check by
    /// cancelling it first -- it carries historical evidence worth preserving
    /// once confirmed, which a bare launch check does not -- but two arrivals
    /// (or two launch checks) in flight at once simply fold into the first.
    ///
    /// Returns whether a new burst actually started; the caller must only
    /// create its `Task`s (via `attach`) when this is `true`.
    @discardableResult
    func begin(pendingArrival: PendingArrival?) -> Bool {
        if let pendingArrival, self.pendingArrival == nil, engine != nil {
            cancel()
        }
        guard engine == nil else { return false }
        engine = .init()
        self.pendingArrival = pendingArrival
        return true
    }

    /// Hands the session ownership of the burst/timeout tasks `begin`'s caller
    /// just started, so `cancel()`/`finish()` can tear them down. Separate from
    /// `begin` because the tasks' closures need to reference the recorder
    /// (for the side effects that follow each sample), not this session.
    func attach(burstTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        self.burstTask = burstTask
        self.timeoutTask = timeoutTask
    }

    /// Records one validated live-location sample and reports how many the
    /// burst has collected so far, for the recorder's own diagnostic.
    @discardableResult
    func append(location: CLLocation, stationary: Bool) -> Int {
        engine?.append(location: location, stationary: stationary)
        return engine?.samples.count ?? 0
    }

    /// Ends the burst -- by timeout, sample limit, stream failure, or a
    /// superseding arrival -- and reports what it found. `nil` when no burst
    /// was active, which the recorder reads as "already handled."
    @discardableResult
    func finish() -> Outcome? {
        guard let engine else { return nil }
        let outcome = Outcome(confirmedLocation: engine.confirmedLocation,
                              pendingArrival: pendingArrival, sampleCount: engine.samples.count)
        cancel()
        return outcome
    }

    /// Tears the burst down without reporting an outcome -- background logging
    /// turned off, or a supersede that discards the check being replaced.
    func cancel() {
        burstTask?.cancel()
        burstTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        engine = nil
        pendingArrival = nil
        let waiters = continuations
        continuations = []
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the current burst (or the next one, if none is active
    /// yet) finishes. Joins whichever cycle is already running rather than
    /// starting a second one -- the waiter list isn't tied to which cycle
    /// resumes it, only to `cancel()`/`finish()` having run.
    func awaitCompletion() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

/// Tracks the newest Maps request for a visit. A correction can invalidate its token,
/// ensuring a late response cannot publish after a newer choice.
@MainActor
final class PlaceResolutionCoordinator {
    private var generations: [ObjectIdentifier: Int] = [:]

    func begin(for visit: Visit) -> Int {
        let identity = ObjectIdentifier(visit)
        let next = generations[identity, default: 0] + 1
        generations[identity] = next
        return next
    }

    func isCurrent(_ token: Int, for visit: Visit) -> Bool {
        generations[ObjectIdentifier(visit)] == token
    }

    func cancel(for visit: Visit) { generations[ObjectIdentifier(visit)] = nil }
}
