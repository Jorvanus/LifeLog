import CoreLocation
import MapKit
import SwiftData
import Observation

/// A deliberately short-lived decision window. `stationary` comes from Core
/// Location's motion fusion; deriving the same answer from one location's speed
/// caused launch-time GPS noise to become a durable visit.
/// Owns the confirmation state machine independently of CLLocationManager. The
/// recorder only supplies live samples and performs the resulting mutation.
struct ArrivalConfirmationEngine {
    struct Sample: Equatable {
        let location: CLLocation
        let stationary: Bool
    }

    static let requiredStationarySamples = 2
    // Observed on-device 2026-08-10: `CLLocationUpdate.liveUpdates()` can deliver
    // well over one sample per second, and raising this from 3 only meant the cap
    // was reached in 5-7 seconds instead of fewer -- still cut short well inside
    // the 15-second `timeout`. Raised again so a fast delivery rate cannot end the
    // burst early on sample count; `timeout` is now the real limit either way.
    static let maximumSamples = 60
    static let timeout: Duration = .seconds(15)

    // A fallback for when Core Location's own "stationary" classification never
    // settles at all -- observed on-device 2026-08-10, indoors: every sample across
    // several full-length bursts read `stationary=false` despite being still the
    // whole time. A cluster of samples that stays put over a real stretch of time is
    // treated as equally good evidence: at any walking pace, `minimumSpan` covers
    // tens of metres, well past `clusterTolerance` even at indoor GPS accuracy,
    // while genuine jitter while still stays bounded.
    static let minimumStationarySpan: TimeInterval = 8
    static let stationaryClusterFloor: CLLocationDistance = 50
    static let stationaryClusterAccuracyMultiplier: CLLocationDistance = 2.5

    let startedAt = Date.now
    private(set) var samples: [Sample] = []

    mutating func append(location: CLLocation, stationary: Bool) {
        guard samples.count < Self.maximumSamples else { return }
        samples.append(.init(location: location, stationary: stationary))
    }

    var hasReachedSampleLimit: Bool { samples.count == Self.maximumSamples }
    var confirmedLocation: CLLocation? {
        if samples.count >= Self.requiredStationarySamples,
           samples.suffix(Self.requiredStationarySamples).allSatisfy(\.stationary) {
            return samples.last?.location
        }
        return clusteredStationaryLocation
    }

    /// Every sample collected so far, checked against the first: not a sliding
    /// window, since one confirmation attempt lives for at most `timeout` and
    /// nothing here needs to forget an old sample within that span.
    private var clusteredStationaryLocation: CLLocation? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2,
              last.location.timestamp.timeIntervalSince(first.location.timestamp) >= Self.minimumStationarySpan
        else { return nil }
        let tolerance = max(Self.stationaryClusterFloor,
                            (samples.map(\.location.horizontalAccuracy).max() ?? 0) * Self.stationaryClusterAccuracyMultiplier)
        let anchor = first.location
        guard samples.allSatisfy({ $0.location.distance(from: anchor) <= tolerance }) else { return nil }
        return last.location
    }
}

typealias LocationArrivalConfirmation = ArrivalConfirmationEngine

@MainActor @Observable
final class LocationRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    private enum PreferenceKey {
        static let backgroundLoggingEnabled = "LifeLogBackgroundLoggingEnabled"
    }

    private let manager = CLLocationManager()
    private var eventAdapter = CoreLocationEventAdapter()
    private var mutationCoordinator = LocationMutationCoordinator()
    private var diagnosticsRecorder = LocationDiagnosticsRecorder()
    private let placeResolutionCoordinator = PlaceResolutionCoordinator()
    private var context: ModelContext?
    private var serviceSession: CLServiceSession?
    private var serviceSessionRequirement: CLServiceSession.AuthorizationRequirement?
    /// Distinguishes one session from its replacement, so a finished stream only ever
    /// clears its own session. See `releaseServiceSession(generation:)`.
    private var serviceSessionGeneration = 0
    private var diagnosticTask: Task<Void, Never>?
    private var identifyingVisits: Set<ObjectIdentifier> = []
    /// MapKit and reverse geocoding are a single resolution attempt. A noisy stream
    /// of location fixes must not turn one unresolved stay into a request per fix.
    private var placeLookupAttempts: [ObjectIdentifier: [Date]] = [:]
    private static let placeLookupCooldown: TimeInterval = 5 * 60
    private static let maximumPlaceLookupAttempts = 3
    private(set) var savedPlaceCache: [SavedPlace] = []
    private var placeMonitor: CLMonitor?
    private var placeMonitorTask: Task<Void, Never>?
    private var monitoredPlaces: [String: MonitoredPlaces.Ranked] = [:]
    private struct PendingArrival {
        let coordinate: CLLocationCoordinate2D?
        let arrival: Date
        let callbackType: LocationCallbackType
        let accuracy: CLLocationAccuracy
    }

    private var liveLocationBurstTask: Task<Void, Never>?
    private var liveLocationBurstTimeoutTask: Task<Void, Never>?
    private var locationConfirmation: ArrivalConfirmationEngine?
    private var pendingArrival: PendingArrival?
    var authorization: CLAuthorizationStatus = .notDetermined
    /// Whether iOS is fuzzing this app's location fixes to city-block scale (the
    /// user-controlled "Precise Location" toggle). Read once at init and refreshed
    /// on every authorization change, since it can flip independently of `authorization`.
    private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var isBackgroundLoggingEnabled = false
    var lastError: String?
    /// The most recent validated location sample is intentionally exposed only as
    /// a timestamp. Timeline can explain a pending visit without displaying a
    /// precise coordinate or duplicating a provisional visit in the data model.
    private(set) var latestLocationTimestamp: Date?

    init(eventAdapter: CoreLocationEventAdapter = .init(),
         mutationCoordinator: LocationMutationCoordinator = .init(),
         diagnosticsRecorder: LocationDiagnosticsRecorder = .init()) {
        self.eventAdapter = eventAdapter
        self.mutationCoordinator = mutationCoordinator
        self.diagnosticsRecorder = diagnosticsRecorder
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        isBackgroundLoggingEnabled = UserDefaults.standard.bool(forKey: PreferenceKey.backgroundLoggingEnabled)
    }

    func connect(_ context: ModelContext) {
        self.context = context
        loadSavedPlaceCache()
        if LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: isBackgroundLoggingEnabled, authorization: authorization
        ) {
            startBackgroundWorkflow()
        }
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            refreshCurrentLocation()
        }
    }

    func requestPermission() {
        holdServiceSession(requiring: .whenInUse)
    }

    func enableBackgroundLogging() {
        isBackgroundLoggingEnabled = true
        UserDefaults.standard.set(true, forKey: PreferenceKey.backgroundLoggingEnabled)
        startBackgroundWorkflow()
    }

    func refreshCurrentLocation() {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            if authorization == .notDetermined { requestPermission() }
            return
        }
        beginLocationConfirmation()
    }

    func disableBackgroundLogging() {
        isBackgroundLoggingEnabled = false
        UserDefaults.standard.set(false, forKey: PreferenceKey.backgroundLoggingEnabled)
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        placeMonitorTask?.cancel()
        placeMonitorTask = nil
        placeMonitor = nil
        monitoredPlaces = [:]
        manager.allowsBackgroundLocationUpdates = false
        diagnosticTask?.cancel()
        diagnosticTask = nil
        serviceSession?.invalidate()
        serviceSession = nil
        serviceSessionRequirement = nil
        cancelLocationConfirmation()
    }

    private func startBackgroundWorkflow() {
        holdServiceSession(requiring: .always)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        startPlaceMonitoring()
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            refreshCurrentLocation()
        }
    }

    /// Holds the session that keeps Core Location delivering, rebuilding it whenever
    /// there is not a live one.
    ///
    /// The guard used to compare the requirement alone, which made a dead session
    /// permanent: `serviceSessionRequirement` stayed `.always` after a session ended —
    /// its diagnostic stream finishing or throwing, typically once authorization was
    /// refused — so every later `startBackgroundWorkflow()` matched the stale
    /// requirement and returned without creating a replacement. Background recording
    /// then stayed off no matter how many times it was restarted, and only a relaunch
    /// (which builds a fresh recorder) brought it back. Checking that a session
    /// actually exists, and clearing it when its stream ends, lets a restart restart.
    private func holdServiceSession(requiring requirement: CLServiceSession.AuthorizationRequirement) {
        guard LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: serviceSessionRequirement, hasLiveSession: serviceSession != nil, required: requirement
        ) else { return }
        diagnosticTask?.cancel()
        serviceSession?.invalidate()

        let session = CLServiceSession(authorization: requirement)
        serviceSessionGeneration += 1
        let generation = serviceSessionGeneration
        serviceSession = session
        serviceSessionRequirement = requirement
        diagnosticTask = Task { [weak self, session] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled else { return }
                    self?.handle(diagnostic)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = "Location permission status couldn't be refreshed."
            }
            // Reached only when this session's stream is finished for good. A
            // cancelled task is a deliberate replacement and returns above, so it
            // never releases the newer session out from under itself.
            guard !Task.isCancelled else { return }
            self?.releaseServiceSession(generation: generation)
        }
    }

    /// Drops the cached session once its stream has ended, so the next
    /// `holdServiceSession` builds a new one. The generation check means a session
    /// that has already been replaced cannot clear its successor.
    private func releaseServiceSession(generation: Int) {
        guard generation == serviceSessionGeneration else { return }
        serviceSession = nil
        serviceSessionRequirement = nil
    }

    private func handle(_ diagnostic: CLServiceSession.Diagnostic) {
        if diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally {
            lastError = "Location access is turned off. You can enable it in iPhone Settings."
        } else if diagnostic.authorizationRestricted {
            lastError = "Location access is restricted on this device."
        } else if diagnostic.alwaysAuthorizationDenied, isBackgroundLoggingEnabled {
            lastError = "Always Location access is required to record visits in the background."
        } else if diagnostic.insufficientlyInUse {
            lastError = "Open LifeLog before starting background location logging."
        }
    }

    /// Records authorization transitions, because losing Always is the one way
    /// background recording stops that leaves no other trace.
    ///
    /// iOS periodically re-asks whether an app may keep using location in the
    /// background, and answering "While Using" silently ends visit and
    /// significant-location delivery. `isBackgroundLoggingEnabled` is LifeLog's own
    /// preference, so it stays on and Settings keeps saying background logging is
    /// enabled while nothing is being recorded. The only previous signal was
    /// `lastError`, a transient string that any later message overwrites; with
    /// nothing durable, the outage had to be diagnosed by guesswork afterwards.
    ///
    /// Written durably for the drop, so it survives an authorization change delivered
    /// at launch before `connect(_:)` has supplied a `ModelContext` — precisely the
    /// case where iOS downgraded the app while it was not running and the owner opens
    /// it to find recording stopped.
    private func recordAuthorizationChange(from previous: CLAuthorizationStatus,
                                           to current: CLAuthorizationStatus) {
        guard previous != current else { return }
        if previous == .authorizedAlways, current != .authorizedAlways {
            let consequence = isBackgroundLoggingEnabled
                ? "Background recording has stopped until Always access is restored."
                : "Background logging is off, so nothing was being recorded anyway."
            Diagnostics.recordDurable(
                context, subsystem: "Core Location",
                message: "Always Location access was lost (now \(Self.name(for: current))). \(consequence)",
                severity: isBackgroundLoggingEnabled ? "warning" : "info",
                eventCode: .generic
            )
            return
        }
        if current == .authorizedAlways {
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "Always Location access granted; background recording is active.",
                               severity: "info")
            return
        }
        Diagnostics.record(context, subsystem: "Core Location",
                           message: "Location authorization changed from \(Self.name(for: previous)) to \(Self.name(for: current)).",
                           severity: current == .denied || current == .restricted ? "warning" : "info")
    }

    private static func name(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not determined"
        @unknown default: "Unknown"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handle(.authorizationChanged(status: manager.authorizationStatus,
                                     accuracy: manager.accuracyAuthorization))
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard let event = eventAdapter.event(for: visit) else { return }
        handle(event)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        sampleWiFiAnchor()
        guard let event = eventAdapter.event(for: locations) else { return }
        handle(event)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        _ = error
        handle(.failure)
    }

    /// Delegate callbacks are deliberately limited to adaptation and dispatch. All
    /// persistence and asynchronous work stays below this boundary.
    private func handle(_ event: CoreLocationEvent) {
        switch event {
        case let .authorizationChanged(status, accuracy):
            let previousAuthorization = authorization
            let previousAccuracyAuthorization = accuracyAuthorization
            authorization = status
            accuracyAuthorization = accuracy
            if accuracyAuthorization == .reducedAccuracy, previousAccuracyAuthorization != .reducedAccuracy {
                Diagnostics.record(context, subsystem: "Core Location",
                                   message: "Precise Location turned off; arrivals will resolve less accurately until it's back on.")
            }
            recordAuthorizationChange(from: previousAuthorization, to: authorization)
            if authorization == .authorizedAlways, isBackgroundLoggingEnabled {
                startBackgroundWorkflow()
            }
            if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
                refreshCurrentLocation()
            }
        case let .visitArrival(coordinate, arrival, accuracy, callbackDelay):
            if callbackDelay > 15 * 60 {
                diagnosticsRecorder.record(context, "A visit arrived later than expected (\(Int(callbackDelay / 60)) minutes).", "warning")
            }
            // A late CLVisit is useful evidence, but not proof that the phone is
            // still there. Confirm it against the same motion-fused burst used at
            // launch before writing a new durable arrival.
            beginLocationConfirmation(
                pendingArrival: .init(coordinate: coordinate, arrival: arrival,
                                      callbackType: .visitArrival, accuracy: accuracy)
            )
        case let .visitDeparture(coordinate, arrival, departure, accuracy):
            closeVisit(at: coordinate, arrival: arrival, departure: departure,
                       callbackType: .visitDeparture, accuracy: accuracy)
        case let .locationSample(sample):
            let location = CLLocation(coordinate: sample.coordinate, altitude: 0,
                                      horizontalAccuracy: sample.accuracy, verticalAccuracy: -1,
                                      timestamp: sample.timestamp)
            recordLocationEvidence(location, callbackType: .locationUpdate)
        case .failure:
            cancelLocationConfirmation()
            lastError = "Location updates are temporarily unavailable."
            diagnosticsRecorder.record(context, "A location update failed.", "warning")
        }
    }

    private func recordLocationEvidence(_ location: CLLocation, callbackType: LocationCallbackType,
                                        transition: LocationJournal.Transition = .none) {
        latestLocationTimestamp = location.timestamp
        identifyRecentUnknown(near: location, accuracy: location.horizontalAccuracy)
        // The ordinary fixes, which create nothing on their own but are the evidence a
        // stay was or was not where it claims. Their accuracy is the field that matters:
        // a stay built on a 200 m fix and one built on a 5 m fix look identical
        // afterwards, and only this says which it was.
        if let context {
            LocationJournal.record(callbackType, at: location.coordinate,
                                   callbackAt: location.timestamp,
                                   accuracy: location.horizontalAccuracy,
                                   transition: transition,
                                   openVisit: latestLocationVisit(in: context), context: context)
        }
    }

    private func beginLocationConfirmation(pendingArrival: PendingArrival? = nil) {
        // A CLVisit arrival supersedes an in-flight launch check: it carries a
        // historical arrival to preserve once the phone confirms it is still nearby.
        if let pendingArrival, self.pendingArrival == nil, locationConfirmation != nil {
            cancelLocationConfirmation()
        }
        guard locationConfirmation == nil else { return }

        locationConfirmation = .init()
        self.pendingArrival = pendingArrival
        liveLocationBurstTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard !Task.isCancelled else { return }
                    self?.receiveLiveLocationUpdate(update)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.finishLocationConfirmation(reason: "stream failed")
            }
        }
        liveLocationBurstTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: LocationArrivalConfirmation.timeout)
                guard !Task.isCancelled else { return }
                self?.finishLocationConfirmation(reason: "timed out")
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func receiveLiveLocationUpdate(_ update: CLLocationUpdate) {
        if update.accuracyLimited || update.insufficientlyInUse || update.locationUnavailable {
            let conditions = [
                update.accuracyLimited ? "accuracy limited" : nil,
                update.insufficientlyInUse ? "insufficiently in use" : nil,
                update.locationUnavailable ? "location unavailable" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "Live location confirmation: \(conditions).")
        }
        guard let location = update.location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 * 60,
              var confirmation = locationConfirmation else { return }

        confirmation.append(location: location, stationary: update.stationary)
        locationConfirmation = confirmation
        Diagnostics.record(context, subsystem: "Core Location",
                           message: "Live location sample \(confirmation.samples.count)/\(LocationArrivalConfirmation.maximumSamples): stationary=\(update.stationary), accuracy=\(Int(location.horizontalAccuracy.rounded())) m, elapsed=\(Int(Date.now.timeIntervalSince(confirmation.startedAt).rounded())) s.",
                           severity: "info")
        recordLocationEvidence(location, callbackType: .liveLocationSample)
        if confirmation.hasReachedSampleLimit {
            finishLocationConfirmation(reason: "sample limit")
        }
    }

    private func finishLocationConfirmation(reason: String) {
        guard let confirmation = locationConfirmation else { return }
        let arrival = pendingArrival
        cancelLocationConfirmation()
        guard let location = confirmation.confirmedLocation else {
            // A CLVisit arrival already carries Core Location's own coordinate — its
            // motion-fused engine decided the phone had stopped before `didVisit` was
            // ever called. The live burst here exists to catch a *stale* CLVisit
            // delivered after the phone actually left, which is real evidence and
            // still discarded below. Zero samples is not that: it is background
            // `CLLocationUpdate.liveUpdates()` delivering nothing inside the window,
            // observed on-device 2026-08-10 discarding an entire day of arrivals.
            // Silence is not disproof, so a pending CLVisit arrival stands on its own
            // evidence instead. There is nothing to fall back to for the launch-time
            // check (no `arrival`), which keeps its stricter, evidence-required rule.
            if let arrival, confirmation.samples.isEmpty {
                HardwareValidation.recordFirst(
                    .liveBurstBackgroundFallback, context: context,
                    message: "A background live-location burst produced no samples; the CLVisit arrival was used instead of being discarded."
                )
                Diagnostics.record(context, subsystem: "Core Location",
                                   message: "Live location confirmation \(reason) with no samples; used the CLVisit arrival directly.",
                                   severity: "info")
                if let coordinate = arrival.coordinate {
                    createVisit(at: coordinate, arrival: arrival.arrival,
                               callbackType: arrival.callbackType, accuracy: arrival.accuracy)
                }
                return
            }
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "Live location confirmation \(reason) without stationary evidence (\(confirmation.samples.count) sample(s))\(arrival == nil ? "" : "; samples disagreed with the pending arrival, discarding it").",
                               severity: "info")
            return
        }
        if let expected = arrival?.coordinate {
            let expectedLocation = CLLocation(latitude: expected.latitude, longitude: expected.longitude)
            let tolerance = max(150, max(arrival?.accuracy ?? 0, location.horizontalAccuracy) * 2)
            guard expectedLocation.distance(from: location) <= tolerance else {
                Diagnostics.record(context, subsystem: "Core Location",
                                   message: "A visit arrival did not match its live confirmation.")
                return
            }
        }
        recordLocationEvidence(location, callbackType: .liveLocationConfirmed, transition: .created)
        if let arrival {
            createVisit(at: location.coordinate, arrival: arrival.arrival,
                        callbackType: arrival.callbackType, accuracy: location.horizontalAccuracy)
        } else {
            seedConfirmedCurrentVisit(from: location)
        }
    }

    private func cancelLocationConfirmation() {
        liveLocationBurstTask?.cancel()
        liveLocationBurstTask = nil
        liveLocationBurstTimeoutTask?.cancel()
        liveLocationBurstTimeoutTask = nil
        locationConfirmation = nil
        pendingArrival = nil
    }

    private func createVisit(at coordinate: CLLocationCoordinate2D, arrival: Date,
                             callbackType: LocationCallbackType = .visitArrival,
                             accuracy: CLLocationAccuracy = -1) {
        guard let context, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let callbackStartedAt = Date.now
        let safeArrival = min(arrival, .now)
        var inferredDeparture: Date?
        var usedWiFiAnchor = false
        if let duplicate = recentDuplicateLocation(at: coordinate, arrival: safeArrival, context: context) {
            // Core Location can replay the same arrival after a visit was closed. Keep
            // the original record and update its bounds instead of creating a new card.
            duplicate.arrival = min(duplicate.arrival, safeArrival)
            duplicate.locationResolutionExplanation = .coordinateTime
            if duplicate.needsCategorisation { identifyPlace(duplicate, accuracy: accuracy) }
            reconcileActivity(with: duplicate, context: context)
            guard finalizeMutation(.coreLocationArrival,
                                   change: .init(affectedVisit: duplicate, coordinate: coordinate,
                                                 placeScoreAlreadyApplied: true), context: context) else { return }
            LocationJournal.record(callbackType, at: coordinate, callbackAt: arrival,
                                   arrival: safeArrival, accuracy: accuracy,
                                   transition: .merged, openVisit: duplicate, context: context)
            Diagnostics.locationMetric(context, operation: "callback_to_save",
                                       durationMs: Int((Date.now.timeIntervalSince(callbackStartedAt) * 1000).rounded()))
            return
        }
        if let latest = latestLocationVisit(in: context), latest.departure == nil {
            let existingLocation = CLLocation(latitude: latest.latitude, longitude: latest.longitude)
            let incomingLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if existingLocation.distance(from: incomingLocation) <= 150 {
                // A later CLVisit callback often has a more accurate, earlier arrival than
                // the one-shot sample used to make the current location visible immediately.
                latest.arrival = min(latest.arrival, safeArrival)
                latest.locationResolutionExplanation = .coordinateTime
                reconcileActivity(with: latest, context: context)
                guard finalizeMutation(.coreLocationArrival,
                                       change: .init(affectedVisit: latest, coordinate: coordinate,
                                                     placeScoreAlreadyApplied: true), context: context) else { return }
                LocationJournal.record(callbackType, at: coordinate, callbackAt: arrival,
                                       arrival: safeArrival, accuracy: accuracy,
                                       transition: .merged, openVisit: latest, context: context)
                Diagnostics.locationMetric(context, operation: "callback_to_save",
                                           durationMs: Int((Date.now.timeIntervalSince(callbackStartedAt) * 1000).rounded()))
                return
            }
            if safeArrival < latest.arrival {
                // CLVisit callbacks can be delayed and delivered after a newer
                // one-shot current-location visit. This is historical evidence,
                // not a new current stay, so bound it at the newer arrival.
                inferredDeparture = latest.arrival
            } else {
                // Core Location did not see the departure, so this timestamp is the
                // next arrival standing in for it. If the phone was observed off the
                // stay's own Wi-Fi before then, that moment is the better answer.
                let anchored = WiFiAnchor.departure(for: WiFiAnchor.loadObservation(),
                                                    arrival: latest.arrival,
                                                    fallback: safeArrival)
                usedWiFiAnchor = anchored != nil
                latest.departure = max(latest.arrival, anchored ?? safeArrival)
                // The stay is closed, so its network observation belongs to nothing now.
                WiFiAnchor.save(nil)
            }
        }

        let saved = nearestSavedPlace(to: coordinate)
        if let saved {
            let distance = CLLocation(latitude: saved.latitude, longitude: saved.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            Diagnostics.locationMetric(context, operation: "saved_place_match",
                                       distanceMeters: Int(distance.rounded()))
        }
        let name = saved?.name ?? Visit.identifyingPlaceName
        let learned = saved.flatMap { learnedActivity(forPlaceName: $0.name, arrival: safeArrival) }
        let activity = InferenceEngine.activity(placeName: name,
                                                defaultActivity: saved?.defaultActivity ?? learned,
                                                arrival: safeArrival)
        let item = Visit(arrival: safeArrival, departure: inferredDeparture,
                         latitude: coordinate.latitude, longitude: coordinate.longitude,
                         placeName: name, inferredActivity: activity,
                         recognitionConfidence: saved == nil ? nil : "learned",
                         mapsIdentifier: saved?.mapsIdentifier,
                         placeFieldProvenance: saved == nil ? nil : "saved-place",
                         resolutionExplanation: saved == nil ? nil : LocationResolutionExplanation.savedPlace.rawValue)
        if let saved {
            let distance = CLLocation(latitude: saved.latitude, longitude: saved.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            item.locationResolutionCandidates = .init(
                chosen: PlaceSuggestion(name: saved.name, latitude: saved.latitude, longitude: saved.longitude,
                                        suggestedActivity: saved.defaultActivity, distance: distance,
                                        mapsIdentifier: saved.mapsIdentifier),
                rejected: []
            )
        }
        context.insert(item)
        _ = PlaceScoreLifecycle.rescore(
            item, stage: .arrival, context: context, savedPlaces: savedPlaceCache,
            accuracy: accuracy, geofenceTriggered: callbackType == .geofenceEntry
        )
        WiFiAnchor.save(nil)
        sampleWiFiAnchor()
        reconcileActivity(with: item, context: context)
        // Recoverable background work: enrichment is a bonus pass over already-
        // imported rows, not part of this arrival's own commit, so a failure here
        // must not block or roll back the visit finalized just below — it only
        // needs to be visible instead of vanishing silently.
        do {
            try SavedPlaceLearning.enrichImportedVisits(with: item, context: context)
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Core Location",
                               operation: "imported visit enrichment")
        }
        guard finalizeMutation(.coreLocationArrival,
                               change: .init(affectedVisit: item, coordinate: coordinate,
                                             placeScoreAlreadyApplied: true), context: context) else { return }
        // Reported against the visit this callback produced, so the journal points at
        // the stay it is explaining rather than the one it replaced.
        LocationJournal.record(callbackType, at: coordinate, callbackAt: arrival,
                               arrival: safeArrival, departure: inferredDeparture,
                               accuracy: accuracy, transition: .created,
                               openVisit: item, context: context)
        Diagnostics.locationMetric(context, operation: "callback_to_save",
                                   durationMs: Int((Date.now.timeIntervalSince(callbackStartedAt) * 1000).rounded()))
        if callbackType == .geofenceEntry, saved != nil {
            HardwareValidation.recordFirst(.namedGeofenceEntry, context: context,
                message: "A Saved Place geofence named an arrival locally; no Maps lookup was needed.")
        }
        if usedWiFiAnchor {
            HardwareValidation.recordFirst(.wifiDepartureAnchor, context: context,
                message: "A Wi-Fi absence sharpened a stay departure before the next arrival.")
        }
        if saved == nil { identifyPlace(item) }
    }

    private func recentDuplicateLocation(at coordinate: CLLocationCoordinate2D, arrival: Date,
                                         context: ModelContext) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 30
        // Required in spirit, not merely best effort: this fetch's nil result
        // means "create a brand new Visit", so a swallowed fetch error and a
        // real absence of duplicates look identical and both create one. There
        // is nothing to retry a location callback from, so the fetch still
        // proceeds as "no duplicate found" -- but logged, not silent, so a
        // resulting duplicate visit is diagnosable instead of a mystery.
        let recent = fetchLogging(descriptor, context: context, operation: "recent duplicate location lookup")
        let incoming = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return recent.first { visit in
            let recorded = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let sameArrival = abs(visit.arrival.timeIntervalSince(arrival)) <= 60
            let sameOpenStay = visit.departure == nil
            return recorded.distance(from: incoming) <= 60 && (sameArrival || sameOpenStay)
        }
    }

    private func closeVisit(at coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date,
                            callbackType: LocationCallbackType = .visitDeparture,
                            accuracy: CLLocationAccuracy = -1) {
        guard let context else { return }
        let resolutionStartedAt = Date.now
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        let candidates = fetchLogging(descriptor, context: context, operation: "departure candidate lookup")
        guard let matched = ActivityLocationPolicy.matchDeparture(
                coordinate: coordinate, arrival: min(arrival, .now),
                departure: min(departure, .now), visits: candidates
              ) else {
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "A departure callback did not match a stored arrival.")
            // A departure that matched nothing is the most useful row in the journal:
            // it is a real observation the timeline has no record of acting on.
            LocationJournal.record(callbackType, at: coordinate, callbackAt: departure,
                                   arrival: arrival, departure: departure, accuracy: accuracy,
                                   transition: .ignored, context: context)
            return
        }
        matched.departure = max(matched.arrival, min(departure, .now))
        matched.locationResolutionExplanation = .coordinateTime
        _ = PlaceScoreLifecycle.rescore(
            matched, stage: .departure, context: context, savedPlaces: savedPlaceCache,
            accuracy: accuracy
        )
        reconcileActivity(with: matched, context: context)
        guard finalizeMutation(.coreLocationDeparture,
                               change: .init(
                                affectedVisit: matched,
                                callbackInterval: DateInterval(start: matched.arrival, end: matched.departure ?? matched.arrival),
                                coordinate: coordinate, placeScoreAlreadyApplied: true
                               ), context: context) else { return }
        LocationJournal.record(callbackType, at: coordinate, callbackAt: departure,
                               arrival: arrival, departure: matched.departure, accuracy: accuracy,
                               transition: .closed, openVisit: matched, context: context)
        Diagnostics.locationMetric(context, operation: "callback_resolution",
                                   durationMs: Int((Date.now.timeIntervalSince(resolutionStartedAt) * 1000).rounded()))
        Diagnostics.locationMetric(context, operation: "callback_to_save",
                                   durationMs: Int((Date.now.timeIntervalSince(resolutionStartedAt) * 1000).rounded()))
    }

    private func seedConfirmedCurrentVisit(from location: CLLocation) {
        // This method is only reached after the live burst saw two recent stationary
        // updates. Do not reintroduce speed here: a missing or stale speed is exactly
        // why one-shot launch fixes used to manufacture visits.
        guard let context else { return }
        if let current = latestLocationVisit(in: context), current.departure == nil {
            let recorded = CLLocation(latitude: current.latitude, longitude: current.longitude)
            // Scale the duplicate threshold with GPS uncertainty so indoor drift does not
            // split one stay into several uncategorised locations.
            let tolerance = max(150, location.horizontalAccuracy * 2)
            if recorded.distance(from: location) <= tolerance {
                if current.needsCategorisation { identifyPlace(current) }
                return
            }
        }
        createVisit(at: location.coordinate, arrival: location.timestamp, accuracy: location.horizontalAccuracy)
    }

    private func latestLocationVisit(in context: ModelContext) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        // Same reasoning as `recentDuplicateLocation`: `seedConfirmedCurrentVisit`
        // treats a nil result as "nothing open, start a new visit", so a
        // swallowed fetch error here is a second, independent way to silently
        // duplicate the current stay. Logged rather than thrown, for the same
        // reason -- there is no queue to retry a live location callback from.
        return fetchLogging(descriptor, context: context, operation: "latest location visit lookup").first
    }

    /// Central point for every `Visit`/`VisitCorrection` fetch in this file whose
    /// nil-on-failure result feeds a decision (create vs. merge, identify vs.
    /// skip) rather than merely populating a UI list. A location callback has no
    /// user waiting on an alert and nothing to retry from, so the failure cannot
    /// be surfaced any more strongly than a diagnostic -- but it must be at least
    /// that, since every caller here already treats an empty result as a
    /// legitimate answer, and only the diagnostic tells the two apart afterward.
    private func fetchLogging<T>(_ descriptor: FetchDescriptor<T>, context: ModelContext,
                                 operation: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Core Location", operation: operation)
            return []
        }
    }

    private func loadSavedPlaceCache() {
        guard let context else { return }
        let startedAt = Date.now
        do {
            savedPlaceCache = try context.fetch(FetchDescriptor<SavedPlace>())
            Diagnostics.locationMetric(context, operation: "saved_place_index_refresh",
                                       durationMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                       candidateCount: savedPlaceCache.count)
        } catch {
            // Keep the previous cache on failure (e.g. if background store is locked under NSFileProtectionComplete).
            // Overwriting with [] would cause known places to resolve as unknown and trigger redundant Maps lookups.
            lastError = "Failed to read Saved Places: \(error.localizedDescription)"
            Diagnostics.record(context, subsystem: "LocationRecorder",
                               message: "Failed to read Saved Places cache; retaining previous cache (\(savedPlaceCache.count) item(s)). Error: \(error.localizedDescription)",
                               severity: "warning")
        }
    }

    func invalidateSavedPlaceCache() {
        loadSavedPlaceCache()
        Task { await refreshMonitoredRegions() }
    }

    /// Watches the Saved Places the system will actually tell us about.
    ///
    /// Until now a known place was recognised after the fact, by measuring how far a
    /// delivered `CLVisit` sat from each Saved Place. That waits for a callback which
    /// can arrive long afterwards, and in the meantime Apple Maps may have written a
    /// neighbouring business over the top of somewhere the person named themselves.
    /// A geofence says "this is Home" the moment the boundary is crossed, with no
    /// Maps request and no delay — and, just as usefully, says when it was left.
    private func startPlaceMonitoring() {
        guard authorization == .authorizedAlways, placeMonitorTask == nil else { return }
        placeMonitorTask = Task { [weak self] in
            let monitor = await CLMonitor("LifeLogSavedPlaces")
            guard let self else { return }
            self.placeMonitor = monitor
            await self.refreshMonitoredRegions()
            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled else { return }
                    self.handle(event)
                }
            } catch {
                self.lastError = "Place monitoring stopped unexpectedly."
            }
        }
    }

    /// Reconciles the watched set with the chosen places, adding and removing only
    /// what changed. iOS caps how many regions an app may monitor, so the set is
    /// ranked rather than truncated arbitrarily; see `MonitoredPlaces`.
    private func refreshMonitoredRegions() async {
        guard let placeMonitor, let context else { return }
        // Best effort, but logged: an empty result here only affects geofence
        // *ranking* for this refresh cycle, not any stored data -- the next
        // successful refresh re-derives it from scratch, so there is nothing to
        // roll back. Still logged, since a persistently failing fetch would
        // otherwise silently starve every geofence of its visit history.
        let visits = fetchLogging(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" }
        ), context: context, operation: "monitored region visit lookup")
        let ranked = MonitoredPlaces.prioritised(savedPlaceCache, visits: visits, limit: .max)
        let wanted = GeofenceMonitor.desired(savedPlaceCache, visits: visits)
        let wantedByID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.identifier, $0) })

        for identifier in await placeMonitor.identifiers where wantedByID[identifier] == nil {
            await placeMonitor.remove(identifier)
        }
        let existing = Set(await placeMonitor.identifiers)
        for place in wanted where !existing.contains(place.identifier) {
            let condition = CLMonitor.CircularGeographicCondition(center: place.coordinate,
                                                                  radius: place.radius)
            await placeMonitor.add(condition, identifier: place.identifier)
        }
        monitoredPlaces = wantedByID
        Diagnostics.locationMetric(context, operation: "geofences_monitored",
                                   candidateCount: wanted.count)
        let selected = wanted.first.map { "first selected place has \($0.visits) prior visit(s)" } ?? "no Saved Places selected"
        let excluded = ranked.dropFirst(MonitoredPlaces.limit).first.map {
            "; first excluded has \($0.visits) prior visit(s)"
        } ?? "; no Saved Places excluded"
        HardwareValidation.recordRanking(signature: wanted.map(\.identifier).joined(separator: "|"),
                                         context: context,
                                         message: "Geofence monitoring selected \(wanted.count) of \(ranked.count) Saved Places by frequency then recency: \(selected)\(excluded).")
    }

    private func handle(_ event: CLMonitor.Event) {
        guard let place = monitoredPlaces[event.identifier] else { return }
        switch event.state {
        case .satisfied:
            // A geofence crossing is not proof the phone stopped -- GPS jitter near
            // an already-open stay's boundary, or driving straight through, can
            // satisfy the region without a real visit happening. Confirm it against
            // the same motion-fused burst used for CLVisit arrivals before writing
            // a durable one; a phone still moving when the burst ends produces no
            // confirmed location and the arrival is discarded, not recorded.
            beginLocationConfirmation(
                pendingArrival: .init(coordinate: place.coordinate, arrival: event.date,
                                      callbackType: .geofenceEntry, accuracy: -1)
            )
        case .unsatisfied:
            closeMonitoredVisit(named: place.name, at: event.date, coordinate: place.coordinate)
        default:
            break
        }
    }

    /// A geofence exit is the departure itself, observed as it happens rather than
    /// inferred from wherever the person turned up next.
    private func closeMonitoredVisit(named name: String, at departure: Date,
                                     coordinate: CLLocationCoordinate2D? = nil) {
        guard let context, let open = latestLocationVisit(in: context), open.departure == nil,
              open.placeName.caseInsensitiveCompare(name) == .orderedSame else { return }
        open.departure = max(open.arrival, min(departure, .now))
        _ = PlaceScoreLifecycle.rescore(
            open, stage: .departure, context: context, savedPlaces: savedPlaceCache,
            geofenceTriggered: true
        )
        WiFiAnchor.save(nil)
        reconcileActivity(with: open, context: context)
        let didSave = finalizeMutation(.coreLocationDeparture,
                                       change: .init(
                                        affectedVisit: open,
                                        callbackInterval: DateInterval(start: open.arrival, end: open.departure ?? open.arrival),
                                        coordinate: coordinate, placeScoreAlreadyApplied: true
                                       ), context: context)
        if let coordinate {
            LocationJournal.record(.geofenceExit, at: coordinate, callbackAt: departure,
                                   departure: open.departure, transition: .closed,
                                   openVisit: open, context: context)
        }
        if didSave {
            HardwareValidation.recordFirst(.geofenceExit, context: context,
                message: "A Saved Place geofence exit closed its open stay at the boundary.")
        }
    }

    private func nearestSavedPlace(to coordinate: CLLocationCoordinate2D) -> SavedPlace? {
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return savedPlaceCache
            .compactMap { place -> (SavedPlace, CLLocationDistance)? in
                let distance = current.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                return distance <= min(max(place.radius, 25), 500) ? (place, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// What this place has meant at this hour before, weighted toward the
    /// person's own corrections and confirmations over automatic guesses and
    /// bulk-imported defaults. Exact name match rather than `NameKey`-normalised:
    /// every visit assigned this Saved Place's name went through the same
    /// canonical `saved.name` string, so the fuzzier match earns nothing here
    /// and would cost a full-table scan on every arrival to get it.
    private func learnedActivity(forPlaceName name: String, arrival: Date) -> String? {
        guard let context else { return nil }
        // Best effort, logged: a failure here degrades this one guess to a
        // worse (or absent) inference, never a stored write, so there is
        // nothing to roll back -- only a diagnostic worth keeping.
        let visits = fetchLogging(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName == name }
        ), context: context, operation: "learned activity visit lookup")
        let corrections = fetchLogging(FetchDescriptor<VisitCorrection>(
            predicate: #Predicate { $0.newPlaceName == name }
        ), context: context, operation: "learned activity correction lookup")
        return ActivityByPlaceAndTime.infer(arrival: arrival, history: visits, corrections: corrections)
    }

    private func identifyPlace(_ visit: Visit, accuracy: CLLocationAccuracy = -1) {
        let identity = ObjectIdentifier(visit)
        let now = Date.now
        let attempts = placeLookupAttempts[identity, default: []]
        guard !identifyingVisits.contains(identity),
              attempts.count < Self.maximumPlaceLookupAttempts,
              attempts.last.map({ now.timeIntervalSince($0) >= Self.placeLookupCooldown }) ?? true
        else { return }
        identifyingVisits.insert(identity)
        placeLookupAttempts[identity, default: []].append(now)
        let lookupToken = placeResolutionCoordinator.begin(for: visit)
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        // Lookups used to carry a per-visit identifier so a correction could cancel
        // one, but nothing ever cancelled by identifier and the token was threaded
        // through the service unused. `identifyingVisits` guards against a second
        // lookup for the same visit, and the `guard visit.needsCategorisation` below
        // is what actually stops a late Maps result from overwriting a correction.
        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            defer { self.identifyingVisits.remove(identity) }
            do {
                let result = try await PlaceLookupService.nearbyPlaces(at: coordinate, arrival: visit.arrival)
                Diagnostics.locationMetric(context, operation: "maps_lookup",
                                           durationMs: result.latencyMs,
                                           candidateCount: result.candidateCount,
                                           cacheHit: result.cacheHit,
                                           payloadBytes: result.candidatePayloadBytes)
                // The user may label Home or Work while Maps is still searching. Never let
                // a late public-place result overwrite that explicit correction.
                guard self.placeResolutionCoordinator.isCurrent(lookupToken, for: visit),
                      visit.needsCategorisation else { return }
                visit.placeSuggestions = result.suggestions
                guard let evaluation = PlaceScoreLifecycle.rescore(
                    visit, stage: .mapsLookup, context: context, savedPlaces: self.savedPlaceCache,
                    accuracy: accuracy, geofenceTriggered: false
                ) else { return }
                visit.recognitionConfidence = evaluation.breakdown.confidence
                // Keep this independently of `placeSuggestions`: a later Saved Place
                // correction clears editor choices, while Diagnostics must retain the
                // exact alternatives that were rejected at resolution time.
                visit.locationResolutionCandidates = .init(
                    chosen: evaluation.selected,
                    rejected: result.suggestions.filter { $0.id != evaluation.selected?.id }
                )

                LocationDiagnostics.recordLookup(
                    radius: result.searchRadius, cacheHit: result.cacheHit,
                    candidates: result.suggestions,
                    selected: evaluation.breakdown.confidence == "high" ? evaluation.selected : nil,
                    confidence: evaluation.breakdown.confidence,
                    fallback: result.suggestions.isEmpty ? "reverse geocoding" : nil,
                    context: context)
                if PlaceScoreLifecycle.canSuggest(for: visit, evaluation: evaluation), let match = evaluation.selected,
                   !Visit.isPlaceholderName(match.name) {
                    visit.placeName = match.name
                    visit.inferredActivity = match.suggestedActivity
                    visit.mapsIdentifier = match.mapsIdentifier
                    visit.placeFieldProvenance = match.mapsIdentifier == nil ? "name-fallback" : "maps"
                    visit.locationResolutionExplanation = match.mapsIdentifier == nil ? .coordinateTime : .mapsIdentifier
                    cache(match, for: visit, context: context)
                } else if let likely = evaluation.selected {
                    visit.placeName = likely.name
                    visit.inferredActivity = likely.suggestedActivity
                    visit.mapsIdentifier = likely.mapsIdentifier
                    visit.placeFieldProvenance = likely.mapsIdentifier == nil ? "name-fallback" : "maps"
                    visit.locationResolutionExplanation = likely.mapsIdentifier == nil ? .coordinateTime : .mapsIdentifier
                } else {
                    reverseGeocode(visit)
                    return
                }
                guard self.finalizeMutation(.coreLocationArrival,
                                            change: .init(affectedVisit: visit, coordinate: visit.coordinate,
                                                          placeScoreAlreadyApplied: true), context: context) else { return }
            } catch {
                if Task.isCancelled { return }
                Diagnostics.record(context, subsystem: "MapKit",
                                   message: "Nearby place lookup failed; fallback resolution was used.")
                Diagnostics.locationMetric(context, operation: "maps_lookup_failed", severity: "warning")
                reverseGeocode(visit)
            }
        }
    }

    private func cache(_ match: PlaceSuggestion, for visit: Visit, context: ModelContext) {
        do {
            // A lookup has only named this one arrival. SavedPlaceLearning waits for
            // corroboration before it turns that evidence into a future geofence.
            if try SavedPlaceLearning.learnAutomatically(from: match, visit: visit, context: context) != nil {
                loadSavedPlaceCache()
            }
        } catch {
            Diagnostics.record(context, subsystem: "Saved Place learning",
                               message: "A Maps result was kept as a candidate but could not be corroborated.")
        }
    }

    private func reverseGeocode(_ visit: Visit) {
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        Task { @MainActor [weak self] in
            guard let self, let context = self.context,
                  let request = MKReverseGeocodingRequest(location: location) else { return }
            do {
                let mapItems = try await request.mapItems
                guard visit.needsCategorisation else { return }
                guard let item = mapItems.first else {
                    markUnknown(visit, context: context)
                    return
                }
                let resolvedName = item.name ?? item.address?.shortAddress ?? item.address?.fullAddress ?? Visit.unknownPlaceName
                visit.placeName = TextSafety.clean(resolvedName, maximumLength: 120)
                visit.recognitionConfidence = "low"
                visit.placeFieldProvenance = "name-fallback"
                visit.locationResolutionExplanation = .lowConfidence
                LocationDiagnostics.record(.promoted, subject: "Unnamed stay",
                                           reason: "no Maps match; reverse geocoding supplied a name",
                                           evidence: visit.placeName, context: context)
                visit.inferredActivity = InferenceEngine.activity(
                    placeName: visit.placeName,
                    defaultActivity: learnedActivity(forPlaceName: visit.placeName, arrival: visit.arrival),
                    arrival: visit.arrival
                )
                guard self.finalizeMutation(.coreLocationArrival,
                                            change: .init(affectedVisit: visit, coordinate: visit.coordinate), context: context) else { return }
            } catch {
                Diagnostics.record(context, subsystem: "MapKit",
                                   message: "Reverse geocoding failed; the visit remains available for manual labeling.")
                markUnknown(visit, context: context)
            }
        }
    }

    private func markUnknown(_ visit: Visit, context: ModelContext) {
        guard visit.needsCategorisation else { return }
        visit.placeName = Visit.unknownPlaceName
        visit.recognitionConfidence = "low"
        visit.placeFieldProvenance = "name-fallback"
        visit.locationResolutionExplanation = .lowConfidence
        visit.inferredActivity = "Visiting"
        _ = finalizeMutation(.coreLocationArrival,
                             change: .init(affectedVisit: visit, coordinate: visit.coordinate), context: context)
    }

    private func identifyRecentUnknown(near location: CLLocation, accuracy: CLLocationAccuracy = -1) {
        guard let context else { return }
        // Placeholder names are what marks a visit as still unidentified now that
        // LifeLog no longer stores a place type.
        let identifying = Visit.identifyingPlaceName
        let unknown = Visit.unknownPlaceName
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate {
                $0.source == "automatic" && ($0.placeName == identifying || $0.placeName == unknown)
            },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        // Best effort, logged: a failure here just misses one chance to name an
        // already-unknown visit from a later, closer callback -- the visit
        // itself is unchanged either way, only logged so a persistent failure
        // is visible rather than read as "nothing nearby was ever unknown."
        let recent = fetchLogging(descriptor, context: context, operation: "recent unknown visit lookup")
        for visit in recent {
            let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            if visitLocation.distance(from: location) <= 250 {
                identifyPlace(visit, accuracy: accuracy)
                return
            }
        }
    }

    /// Records whether the phone is still on the network the open stay began with.
    ///
    /// Sampled only when a location event has already woken LifeLog, so it costs
    /// nothing extra — and means the observation is at its freshest exactly when a
    /// departure is about to be timed.
    private func sampleWiFiAnchor(now: Date = .now) {
        Task { @MainActor in
            let hash = await WiFiAnchor.currentNetworkHash()
            WiFiAnchor.save(WiFiAnchor.update(WiFiAnchor.loadObservation(), sampled: hash, at: now))
        }
    }

    /// Keeps callback publication behind VisitMutationService's single commit. The
    /// recorder still owns raw CLLocation interpretation; the service owns the
    /// resolver, durable diagnostic, save, and Insights refresh that follow it.
    private func finalizeMutation(_ kind: VisitMutationService.Kind,
                                  change: VisitMutationService.Change,
                                  context: ModelContext) -> Bool {
        let result = mutationCoordinator.finalize(context, kind, change)
        guard result.committed else {
            lastError = "LifeLog couldn't securely save this update. Your existing timeline is unchanged."
            Diagnostics.recordDurable(context, subsystem: "Store",
                                      message: "A location mutation rolled back (\(result.failureDescription ?? "unknown failure")).")
            return false
        }
        Diagnostics.flushPending(context)
        return true
    }

    private func reconcileActivity(with locationVisit: Visit, context: ModelContext) {
        do {
            try ActivityLocationPolicy.reconcile(locationVisit: locationVisit, context: context)
        } catch {
            lastError = "LifeLog couldn't reconcile activity with this location visit."
        }
    }
}
