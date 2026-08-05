import CoreLocation
import MapKit
import SwiftData
import Observation

@MainActor @Observable
final class LocationRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    private enum PreferenceKey {
        static let backgroundLoggingEnabled = "LifeLogBackgroundLoggingEnabled"
    }

    private let manager = CLLocationManager()
    private var context: ModelContext?
    private var serviceSession: CLServiceSession?
    private var serviceSessionRequirement: CLServiceSession.AuthorizationRequirement?
    private var diagnosticTask: Task<Void, Never>?
    private var identifyingVisits: Set<ObjectIdentifier> = []
    private var savedPlaceCache: [SavedPlace] = []
    /// Limits immediate-place creation to samples explicitly requested by LifeLog.
    /// Significant-change callbacks can arrive while travelling and must not become visits.
    private var shouldSeedCurrentLocation = false
    var authorization: CLAuthorizationStatus = .notDetermined
    var isBackgroundLoggingEnabled = false
    var lastError: String?
    /// The most recent validated location sample is intentionally exposed only as
    /// a timestamp. Timeline can explain a pending visit without displaying a
    /// precise coordinate or duplicating a provisional visit in the data model.
    private(set) var latestLocationTimestamp: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        authorization = manager.authorizationStatus
        isBackgroundLoggingEnabled = UserDefaults.standard.bool(forKey: PreferenceKey.backgroundLoggingEnabled)
    }

    func connect(_ context: ModelContext) {
        self.context = context
        loadSavedPlaceCache()
        if isBackgroundLoggingEnabled, authorization != .notDetermined {
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
        guard !shouldSeedCurrentLocation else { return }
        shouldSeedCurrentLocation = true
        manager.requestLocation()
    }

    func disableBackgroundLogging() {
        isBackgroundLoggingEnabled = false
        UserDefaults.standard.set(false, forKey: PreferenceKey.backgroundLoggingEnabled)
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        diagnosticTask?.cancel()
        diagnosticTask = nil
        serviceSession?.invalidate()
        serviceSession = nil
        serviceSessionRequirement = nil
    }

    private func startBackgroundWorkflow() {
        holdServiceSession(requiring: .always)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            refreshCurrentLocation()
        }
    }

    private func holdServiceSession(requiring requirement: CLServiceSession.AuthorizationRequirement) {
        guard serviceSessionRequirement != requirement else { return }
        diagnosticTask?.cancel()
        serviceSession?.invalidate()

        let session = CLServiceSession(authorization: requirement)
        serviceSession = session
        serviceSessionRequirement = requirement
        diagnosticTask = Task { [weak self, session] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled else { break }
                    self?.handle(diagnostic)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = "Location permission status couldn't be refreshed."
            }
        }
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedAlways, isBackgroundLoggingEnabled {
            startBackgroundWorkflow()
        }
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            refreshCurrentLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.coordinate.latitude.isFinite, visit.coordinate.longitude.isFinite else { return }
        let callbackDelay = Date.now.timeIntervalSince(visit.arrivalDate)
        if callbackDelay > 15 * 60 {
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "A visit arrived later than expected (\(Int(callbackDelay / 60)) minutes).")
        }
        if visit.departureDate == .distantFuture {
            createVisit(at: visit.coordinate, arrival: visit.arrivalDate)
        } else {
            closeVisit(at: visit.coordinate, arrival: visit.arrivalDate, departure: visit.departureDate)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 * 60 else { return }
        latestLocationTimestamp = location.timestamp
        if shouldSeedCurrentLocation {
            shouldSeedCurrentLocation = false
            seedCurrentVisit(from: location)
        }
        identifyRecentUnknown(near: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        shouldSeedCurrentLocation = false
        _ = error
        lastError = "Location updates are temporarily unavailable."
        Diagnostics.record(context, subsystem: "Core Location", message: "A location update failed.")
    }

    private func createVisit(at coordinate: CLLocationCoordinate2D, arrival: Date) {
        guard let context, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let callbackStartedAt = Date.now
        let safeArrival = min(arrival, .now)
        var inferredDeparture: Date?
        if let duplicate = recentDuplicateLocation(at: coordinate, arrival: safeArrival, context: context) {
            // Core Location can replay the same arrival after a visit was closed. Keep
            // the original record and update its bounds instead of creating a new card.
            duplicate.arrival = min(duplicate.arrival, safeArrival)
            if duplicate.needsCategorisation { identifyPlace(duplicate) }
            reconcileActivity(with: duplicate, context: context)
            save(context)
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
                reconcileActivity(with: latest, context: context)
                try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
                save(context)
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
                latest.departure = max(latest.arrival, safeArrival)
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
        let activity = InferenceEngine.activity(placeName: name,
                                                defaultActivity: saved?.defaultActivity, arrival: safeArrival)
        let item = Visit(arrival: safeArrival, departure: inferredDeparture,
                         latitude: coordinate.latitude, longitude: coordinate.longitude,
                         placeName: name, inferredActivity: activity,
                         recognitionConfidence: saved == nil ? nil : "learned")
        context.insert(item)
        reconcileActivity(with: item, context: context)
        try? SavedPlaceLearning.enrichImportedVisits(with: item, context: context)
        try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
        save(context)
        Diagnostics.locationMetric(context, operation: "callback_to_save",
                                   durationMs: Int((Date.now.timeIntervalSince(callbackStartedAt) * 1000).rounded()))
        if saved == nil { identifyPlace(item) }
    }

    private func recentDuplicateLocation(at coordinate: CLLocationCoordinate2D, arrival: Date,
                                         context: ModelContext) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 30
        guard let recent = try? context.fetch(descriptor) else { return nil }
        let incoming = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return recent.first { visit in
            let recorded = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let sameArrival = abs(visit.arrival.timeIntervalSince(arrival)) <= 60
            let sameOpenStay = visit.departure == nil
            return recorded.distance(from: incoming) <= 60 && (sameArrival || sameOpenStay)
        }
    }

    private func closeVisit(at coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date) {
        guard let context else { return }
        let resolutionStartedAt = Date.now
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        guard let candidates = try? context.fetch(descriptor),
              let matched = ActivityLocationPolicy.matchDeparture(
                coordinate: coordinate, arrival: min(arrival, .now),
                departure: min(departure, .now), visits: candidates
              ) else {
            Diagnostics.record(context, subsystem: "Core Location",
                               message: "A departure callback did not match a stored arrival.")
            return
        }
        matched.departure = max(matched.arrival, min(departure, .now))
        reconcileActivity(with: matched, context: context)
        _ = try? ActivityLocationPolicy.resolveLocationCallbacks(context: context)
        try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
        save(context)
        Diagnostics.locationMetric(context, operation: "callback_resolution",
                                   durationMs: Int((Date.now.timeIntervalSince(resolutionStartedAt) * 1000).rounded()))
        Diagnostics.locationMetric(context, operation: "callback_to_save",
                                   durationMs: Int((Date.now.timeIntervalSince(resolutionStartedAt) * 1000).rounded()))
    }

    private func seedCurrentVisit(from location: CLLocation) {
        // A fast sample represents movement, not a destination. Unknown speed (-1) is
        // accepted because stationary one-shot fixes commonly omit speed on launch.
        guard location.speed < 0 || location.speed <= 2.5 else { return }
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
        createVisit(at: location.coordinate, arrival: location.timestamp)
    }

    private func latestLocationVisit(in context: ModelContext) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func loadSavedPlaceCache() {
        guard let context else { return }
        let startedAt = Date.now
        savedPlaceCache = (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
        Diagnostics.locationMetric(context, operation: "saved_place_index_refresh",
                                   durationMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                   candidateCount: savedPlaceCache.count)
    }

    func invalidateSavedPlaceCache() {
        loadSavedPlaceCache()
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

    private func identifyPlace(_ visit: Visit) {
        let identity = ObjectIdentifier(visit)
        guard identifyingVisits.insert(identity).inserted else { return }
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        // Identifies this lookup to the service for the life of the call. It used to
        // be retained in a dictionary keyed by visit so a correction could cancel it,
        // but nothing ever cancelled, and only the (uncalled) cancel path removed an
        // entry — so the dictionary grew for the life of the process. `identifyingVisits`
        // still guards against a second lookup for the same visit, and the `guard
        // visit.needsCategorisation` below is what actually stops a late Maps result
        // from overwriting a correction.
        let lookupID = UUID()
        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            defer { self.identifyingVisits.remove(identity) }
            do {
                let result = try await PlaceLookupService.nearbyPlaces(at: coordinate, arrival: visit.arrival, lookupID: lookupID)
                Diagnostics.locationMetric(context, operation: "maps_lookup",
                                           durationMs: result.latencyMs,
                                           candidateCount: result.candidateCount,
                                           cacheHit: result.cacheHit,
                                           payloadBytes: result.candidatePayloadBytes)
                // The user may label Home or Work while Maps is still searching. Never let
                // a late public-place result overwrite that explicit correction.
                guard visit.needsCategorisation else { return }
                visit.placeSuggestions = result.suggestions
                visit.recognitionConfidence = result.confidence.rawValue

                if result.confidence == .high, let match = result.suggestions.first,
                   !Visit.isPlaceholderName(match.name) {
                    visit.placeName = match.name
                    visit.inferredActivity = match.suggestedActivity
                    cache(match, context: context)
                } else if let likely = result.suggestions.first {
                    visit.placeName = likely.name
                    visit.inferredActivity = likely.suggestedActivity
                } else {
                    reverseGeocode(visit)
                    return
                }
                try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
                save(context)
            } catch {
                if Task.isCancelled { return }
                Diagnostics.record(context, subsystem: "MapKit",
                                   message: "Nearby place lookup failed; fallback resolution was used.")
                Diagnostics.locationMetric(context, operation: "maps_lookup_failed", severity: "warning")
                reverseGeocode(visit)
            }
        }
    }

    private func cache(_ match: PlaceSuggestion, context: ModelContext) {
        let coordinate = CLLocation(latitude: match.latitude, longitude: match.longitude)
        let existing = savedPlaceCache.contains { place in
            coordinate.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= 50
        }
        guard !existing else { return }
        context.insert(SavedPlace(name: TextSafety.clean(match.name, maximumLength: 100),
                                  latitude: match.latitude, longitude: match.longitude,
                                  radius: 85, defaultActivity: match.suggestedActivity))
        loadSavedPlaceCache()
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
                visit.inferredActivity = InferenceEngine.activity(placeName: visit.placeName,
                                                                   arrival: visit.arrival)
                try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
                save(context)
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
        visit.inferredActivity = "Visiting"
        try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
        save(context)
    }

    private func identifyRecentUnknown(near location: CLLocation) {
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
        guard let recent = try? context.fetch(descriptor) else { return }
        for visit in recent {
            let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            if visitLocation.distance(from: location) <= 250 {
                identifyPlace(visit)
                return
            }
        }
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            lastError = "LifeLog couldn't securely save this update. Your existing timeline is unchanged."
        }
    }

    private func reconcileActivity(with locationVisit: Visit, context: ModelContext) {
        do {
            try ActivityLocationPolicy.reconcile(locationVisit: locationVisit, context: context)
        } catch {
            lastError = "LifeLog couldn't reconcile activity with this location visit."
        }
    }
}
