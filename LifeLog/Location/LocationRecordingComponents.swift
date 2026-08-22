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

    /// Whether a geofence exit named `name` is the departure for `open`. Guards
    /// against a stale or out-of-order `CLMonitor` event closing the wrong stay --
    /// `open` must still be open, and must be the same place the exit fired for.
    static func matchesExit(open: Visit, name: String) -> Bool {
        open.departure == nil && open.placeName.caseInsensitiveCompare(name) == .orderedSame
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

/// Whether a live-location burst's confirmed location is close enough to the
/// arrival it was confirming to trust it -- the check `finishLocationConfirmation`
/// used to run inline once a burst produced a confirmed location at all. Tolerance
/// scales with whichever side's accuracy is worse, since a coarse expected fix or a
/// coarse confirmation both widen how far "the same place" can land.
enum LiveConfirmationMatch {
    /// `expected` is nil for a bare launch check with nothing to confirm against,
    /// which always matches.
    static func matches(expected: CLLocationCoordinate2D?, expectedAccuracy: CLLocationAccuracy,
                        confirmed: CLLocationCoordinate2D, confirmedAccuracy: CLLocationAccuracy) -> Bool {
        guard let expected else { return true }
        let expectedLocation = CLLocation(latitude: expected.latitude, longitude: expected.longitude)
        let confirmedLocation = CLLocation(latitude: confirmed.latitude, longitude: confirmed.longitude)
        let tolerance = max(150, max(expectedAccuracy, confirmedAccuracy) * 2)
        return expectedLocation.distance(from: confirmedLocation) <= tolerance
    }
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
        if pendingArrival != nil, self.pendingArrival == nil, engine != nil {
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

/// Owns the `CLServiceSession` that keeps Core Location delivering: which
/// requirement it currently holds, its diagnostic stream, and the generation
/// bookkeeping that stops a stream ending for a just-replaced session from
/// clearing its successor.
///
/// `LocationRecorder` still decides what each diagnostic means for
/// `lastError`/`Diagnostics` -- this collaborator only owns whether a session
/// needs rebuilding and keeps its stream running. Previously four separate
/// stored properties (`serviceSession`, `serviceSessionRequirement`,
/// `serviceSessionGeneration`, `diagnosticTask`) read and written from three
/// different methods.
@MainActor
final class LocationServiceSessionController {
    private var session: CLServiceSession?
    private var requirement: CLServiceSession.AuthorizationRequirement?
    private var generation = 0
    private var diagnosticTask: Task<Void, Never>?

    /// Rebuilds the session only when `LocationRecoveryCoordinator.
    /// shouldRebuildServiceSession` says the held one cannot be assumed to
    /// still be serving `requirement` -- see that function's own doc comment
    /// for why a session whose stream already ended must not be treated as
    /// live. `onDiagnostic` runs for every diagnostic the new session's
    /// stream delivers; `onStreamFailure` only when the stream throws, not
    /// when it is cancelled by a deliberate replacement.
    func hold(requiring requirement: CLServiceSession.AuthorizationRequirement,
             onDiagnostic: @escaping (CLServiceSession.Diagnostic) -> Void,
             onStreamFailure: @escaping () -> Void) {
        guard LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: self.requirement, hasLiveSession: session != nil, required: requirement
        ) else { return }
        diagnosticTask?.cancel()
        session?.invalidate()

        let newSession = CLServiceSession(authorization: requirement)
        generation += 1
        let currentGeneration = generation
        session = newSession
        self.requirement = requirement
        diagnosticTask = Task { [weak self, newSession] in
            do {
                for try await diagnostic in newSession.diagnostics {
                    guard !Task.isCancelled else { return }
                    onDiagnostic(diagnostic)
                }
            } catch is CancellationError {
                return
            } catch {
                onStreamFailure()
            }
            // Reached only when this session's stream is finished for good. A
            // cancelled task is a deliberate replacement and returns above, so
            // it never releases the newer session out from under itself.
            guard !Task.isCancelled else { return }
            self?.release(generation: currentGeneration)
        }
    }

    /// Drops the cached session once its stream has ended, so the next `hold`
    /// builds a new one. The generation check means a session that has
    /// already been replaced cannot clear its successor.
    private func release(generation: Int) {
        guard generation == self.generation else { return }
        session = nil
        requirement = nil
    }

    /// Tears the session down without waiting for its stream to end on its
    /// own -- background logging turned off.
    func invalidate() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        session?.invalidate()
        session = nil
        requirement = nil
    }
}

/// Whether `LocationRecorder.identifyPlace` should start another Maps/reverse-
/// geocoding attempt for a visit. MapKit and reverse geocoding are a single
/// resolution attempt; a noisy stream of location fixes must not turn one
/// unresolved stay into a lookup per fix, so an attempt already in flight and a
/// per-visit attempt cap with a cooldown between attempts both hold it back.
///
/// `LocationRecorder` still owns the actual bookkeeping this reads (`identifyingVisits`,
/// `placeLookupAttempts`) and records a new attempt when this says to proceed; this
/// only decides whether to.
enum PlaceLookupThrottle {
    static let cooldown: TimeInterval = 5 * 60
    static let maximumAttempts = 3

    static func shouldAttempt(isAlreadyInFlight: Bool, priorAttempts: [Date], now: Date) -> Bool {
        !isAlreadyInFlight &&
            priorAttempts.count < maximumAttempts &&
            (priorAttempts.last.map { now.timeIntervalSince($0) >= cooldown } ?? true)
    }
}

/// Builds the `Visit` a new arrival becomes, given what the Saved Place cache and
/// learned-activity lookup already found. Pure -- constructs the model but never
/// inserts it or touches SwiftData; `LocationRecorder` still owns insertion and
/// every mutation that follows (rescoring, activity reconciliation, enrichment,
/// journaling), the same boundary as every other collaborator here.
enum VisitArrivalFactory {
    static func makeVisit(coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date?,
                          saved: SavedPlace?, savedDistance: CLLocationDistance?,
                          learnedActivity: String?) -> Visit {
        let name = saved?.name ?? Visit.identifyingPlaceName
        let activity = InferenceEngine.activity(placeName: name,
                                                defaultActivity: saved?.defaultActivity ?? learnedActivity,
                                                arrival: arrival)
        let item = Visit(arrival: arrival, departure: departure,
                         latitude: coordinate.latitude, longitude: coordinate.longitude,
                         placeName: name, inferredActivity: activity,
                         recognitionConfidence: saved == nil ? nil : "learned",
                         mapsIdentifier: saved?.mapsIdentifier,
                         placeFieldProvenance: saved == nil ? nil : "saved-place",
                         resolutionExplanation: saved == nil ? nil : LocationResolutionExplanation.savedPlace.rawValue)
        if let saved, let savedDistance {
            item.locationResolutionCandidates = .init(
                chosen: PlaceSuggestion(name: saved.name, latitude: saved.latitude, longitude: saved.longitude,
                                        suggestedActivity: saved.defaultActivity, distance: savedDistance,
                                        mapsIdentifier: saved.mapsIdentifier),
                rejected: []
            )
        }
        return item
    }
}

/// Owns the in-memory Saved Place cache every location callback reads
/// synchronously -- `createVisit`, `closeVisit`, and `identifyPlace` all score
/// or match against it inline on the callback path, where a store fetch would
/// be too slow to repeat per callback.
///
/// `LocationRecorder` still owns when to reload it (on connect, and whenever
/// `invalidateSavedPlaceCache()` says a place changed) and what a failure
/// means for `lastError`; this collaborator only owns the fetch, keeping the
/// previous cache on failure, and the nearest-match lookup every arrival
/// callback needs.
@MainActor
final class SavedPlaceCache {
    private(set) var places: [SavedPlace] = []

    /// Reloads from the store. Keeps the previous cache on failure -- e.g. the
    /// background store is locked under `NSFileProtectionComplete` -- rather
    /// than overwriting it with `[]`, which would resolve every known place as
    /// unknown and trigger a redundant Maps lookup for each one.
    @discardableResult
    func reload(context: ModelContext) -> Result<Int, Error> {
        do {
            places = try context.fetch(FetchDescriptor<SavedPlace>())
            return .success(places.count)
        } catch {
            return .failure(error)
        }
    }

    /// The nearest Saved Place whose radius actually reaches `coordinate`,
    /// clamped to a sane range so neither a tiny nor an unrealistically large
    /// radius can match somewhere it plainly shouldn't.
    func nearest(to coordinate: CLLocationCoordinate2D) -> SavedPlace? {
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places
            .compactMap { place -> (SavedPlace, CLLocationDistance)? in
                let distance = current.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                return distance <= min(max(place.radius, 25), 500) ? (place, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }
}

/// The arrival-merge decision `LocationRecorder.createVisit` used to work out inline
/// against two already-fetched visits: a recent duplicate, and whichever stay is
/// currently open. Pure so that decision -- which of four things a new arrival means --
/// is testable without SwiftData or Core Location.
///
/// `LocationRecorder` still performs the fetches this reads, every mutation an outcome
/// implies, and every diagnostic around them; this only decides which outcome applies.
enum VisitArrivalMerge {
    /// What an already-open stay means for a new arrival, once it is not a plain
    /// duplicate of something recent (see `duplicateMatch`).
    enum OpenVisitOutcome: Equatable {
        /// Close enough to be the same stay continuing -- extend its arrival back
        /// rather than create a second card for it.
        case mergeIntoOpen
        /// A `CLVisit` callback delivered after a newer one-shot arrival: historical
        /// evidence, not a new current stay, so the *new* visit being created is
        /// bounded at this departure rather than left open.
        case boundNewVisitDeparture(Date)
        /// Newer than the open stay and too far away to be it: Core Location never
        /// saw the departure, so this arrival's timing (or, if closer, a Wi-Fi
        /// absence observed first) stands in for it.
        case closeOpenVisit(departure: Date, usedWiFiAnchor: Bool)
    }

    /// The same coordinate and arrival (or the same still-open stay) seen again --
    /// most often Core Location replaying an arrival after the original visit
    /// already closed. `candidates` is the recorder's own recent-automatic-visits
    /// fetch, newest first.
    static func duplicateMatch(coordinate: CLLocationCoordinate2D, arrival: Date,
                               in candidates: [Visit]) -> Visit? {
        let incoming = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return candidates.first { visit in
            let recorded = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let sameArrival = abs(visit.arrival.timeIntervalSince(arrival)) <= 60
            let sameOpenStay = visit.departure == nil
            return recorded.distance(from: incoming) <= 60 && (sameArrival || sameOpenStay)
        }
    }

    /// `nil` when nothing is open, in which case the new arrival has nothing to
    /// reconcile against and simply becomes its own visit.
    static func outcome(for openVisit: Visit?, coordinate: CLLocationCoordinate2D, arrival: Date,
                        wifiObservation: WiFiAnchor.Observation?) -> OpenVisitOutcome? {
        guard let openVisit else { return nil }
        let existingLocation = CLLocation(latitude: openVisit.latitude, longitude: openVisit.longitude)
        let incomingLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if existingLocation.distance(from: incomingLocation) <= 150 {
            return .mergeIntoOpen
        }
        if arrival < openVisit.arrival {
            return .boundNewVisitDeparture(openVisit.arrival)
        }
        let anchored = WiFiAnchor.departure(for: wifiObservation, arrival: openVisit.arrival, fallback: arrival)
        return .closeOpenVisit(departure: max(openVisit.arrival, anchored ?? arrival), usedWiFiAnchor: anchored != nil)
    }

    /// Whether a live-location confirmation with no pending arrival to reconcile
    /// (a bare launch or pull-to-refresh check) is already the currently open
    /// stay -- `seedConfirmedCurrentVisit`'s own tolerance check, scaled by GPS
    /// accuracy so indoor drift does not split one stay into several
    /// uncategorised locations. Distinct from `outcome`'s fixed 150m
    /// `.mergeIntoOpen` threshold: this only decides whether to re-attempt
    /// identifying the open stay instead of creating a new one, never a merge.
    static func matchesCurrentlyOpenVisit(_ openVisit: Visit, confirmedLocation: CLLocationCoordinate2D,
                                          confirmedAccuracy: CLLocationAccuracy) -> Bool {
        let recorded = CLLocation(latitude: openVisit.latitude, longitude: openVisit.longitude)
        let confirmed = CLLocation(latitude: confirmedLocation.latitude, longitude: confirmedLocation.longitude)
        let tolerance = max(150, confirmedAccuracy * 2)
        return recorded.distance(from: confirmed) <= tolerance
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
