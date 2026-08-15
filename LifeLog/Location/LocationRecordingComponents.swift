import CoreLocation
import SwiftData

/// The only Core Location-shaped values allowed past the delegate boundary.
/// Capturing `now` here keeps delayed callback handling deterministic in tests.
enum CoreLocationEvent: Sendable {
    case authorizationChanged(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization)
    case visitArrival(coordinate: CLLocationCoordinate2D, arrival: Date, accuracy: CLLocationAccuracy, callbackDelay: TimeInterval)
    case visitDeparture(coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date, accuracy: CLLocationAccuracy)
    case locationSample(LocationCallbackSample)
    case failure
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
