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
    private(set) var savedPlaceCache: [SavedPlace] = []
    private var placeMonitor: CLMonitor?
    private var placeMonitorTask: Task<Void, Never>?
    private var monitoredPlaces: [String: MonitoredPlaces.Ranked] = [:]
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
            createVisit(at: visit.coordinate, arrival: visit.arrivalDate,
                        callbackType: "visit-arrival", accuracy: visit.horizontalAccuracy)
        } else {
            closeVisit(at: visit.coordinate, arrival: visit.arrivalDate, departure: visit.departureDate,
                       callbackType: "visit-departure", accuracy: visit.horizontalAccuracy)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        sampleWiFiAnchor()
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 * 60 else { return }
        latestLocationTimestamp = location.timestamp
        let seeding = shouldSeedCurrentLocation
        if shouldSeedCurrentLocation {
            shouldSeedCurrentLocation = false
            seedCurrentVisit(from: location)
        }
        identifyRecentUnknown(near: location)
        // The ordinary fixes, which create nothing on their own but are the evidence a
        // stay was or was not where it claims. Their accuracy is the field that matters:
        // a stay built on a 200 m fix and one built on a 5 m fix look identical
        // afterwards, and only this says which it was.
        if let context {
            LocationJournal.record("location-update", at: location.coordinate,
                                   callbackAt: location.timestamp,
                                   accuracy: location.horizontalAccuracy,
                                   transition: seeding ? .created : .none,
                                   openVisit: latestLocationVisit(in: context), context: context)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        shouldSeedCurrentLocation = false
        _ = error
        lastError = "Location updates are temporarily unavailable."
        Diagnostics.record(context, subsystem: "Core Location", message: "A location update failed.")
    }

    private func createVisit(at coordinate: CLLocationCoordinate2D, arrival: Date,
                             callbackType: String = "visit-arrival",
                             accuracy: CLLocationAccuracy = -1) {
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
                reconcileActivity(with: latest, context: context)
                try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
                save(context)
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
        let activity = InferenceEngine.activity(placeName: name,
                                                defaultActivity: saved?.defaultActivity, arrival: safeArrival)
        let item = Visit(arrival: safeArrival, departure: inferredDeparture,
                         latitude: coordinate.latitude, longitude: coordinate.longitude,
                         placeName: name, inferredActivity: activity,
                         recognitionConfidence: saved == nil ? nil : "learned")
        context.insert(item)
        WiFiAnchor.save(nil)
        sampleWiFiAnchor()
        reconcileActivity(with: item, context: context)
        try? SavedPlaceLearning.enrichImportedVisits(with: item, context: context)
        try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
        save(context)
        // Reported against the visit this callback produced, so the journal points at
        // the stay it is explaining rather than the one it replaced.
        LocationJournal.record(callbackType, at: coordinate, callbackAt: arrival,
                               arrival: safeArrival, departure: inferredDeparture,
                               accuracy: accuracy, transition: .created,
                               openVisit: item, context: context)
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

    private func closeVisit(at coordinate: CLLocationCoordinate2D, arrival: Date, departure: Date,
                            callbackType: String = "visit-departure",
                            accuracy: CLLocationAccuracy = -1) {
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
            // A departure that matched nothing is the most useful row in the journal:
            // it is a real observation the timeline has no record of acting on.
            LocationJournal.record(callbackType, at: coordinate, callbackAt: departure,
                                   arrival: arrival, departure: departure, accuracy: accuracy,
                                   transition: .ignored, context: context)
            return
        }
        matched.departure = max(matched.arrival, min(departure, .now))
        reconcileActivity(with: matched, context: context)
        _ = try? ActivityLocationPolicy.resolveLocationCallbacks(context: context)
        try? ActivityLocationPolicy.updateTravelDescriptions(context: context)
        save(context)
        LocationJournal.record(callbackType, at: coordinate, callbackAt: departure,
                               arrival: arrival, departure: matched.departure, accuracy: accuracy,
                               transition: .closed, openVisit: matched, context: context)
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
        let visits = (try? context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" }
        ))) ?? []
        let wanted = MonitoredPlaces.prioritised(savedPlaceCache, visits: visits)
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
    }

    private func handle(_ event: CLMonitor.Event) {
        guard let place = monitoredPlaces[event.identifier] else { return }
        switch event.state {
        case .satisfied:
            createVisit(at: place.coordinate, arrival: event.date, callbackType: "geofence-entry")
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
        WiFiAnchor.save(nil)
        reconcileActivity(with: open, context: context)
        _ = try? ActivityLocationPolicy.resolveLocationCallbacks(context: context)
        save(context)
        if let coordinate {
            LocationJournal.record("geofence-exit", at: coordinate, callbackAt: departure,
                                   departure: open.departure, transition: .closed,
                                   openVisit: open, context: context)
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

    private func identifyPlace(_ visit: Visit) {
        let identity = ObjectIdentifier(visit)
        guard identifyingVisits.insert(identity).inserted else { return }
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
                guard visit.needsCategorisation else { return }
                visit.placeSuggestions = result.suggestions
                visit.recognitionConfidence = result.confidence.rawValue

                LocationDiagnostics.recordLookup(
                    radius: result.searchRadius, cacheHit: result.cacheHit,
                    candidates: result.suggestions,
                    selected: result.confidence == .high ? result.suggestions.first : nil,
                    confidence: result.confidence.rawValue,
                    fallback: result.suggestions.isEmpty ? "reverse geocoding" : nil,
                    context: context)
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
        // Identity first: the same Maps place moves a little between fixes, and two
        // different businesses can sit within fifty metres of each other.
        let existing = savedPlaceCache.contains { place in
            if let identifier = match.mapsIdentifier, let known = place.mapsIdentifier {
                return identifier == known
            }
            return coordinate.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= 50
        }
        guard !existing else { return }
        context.insert(SavedPlace(name: TextSafety.clean(match.name, maximumLength: 100),
                                  latitude: match.latitude, longitude: match.longitude,
                                  radius: 85, defaultActivity: match.suggestedActivity,
                                  mapsIdentifier: match.mapsIdentifier))
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
                LocationDiagnostics.record(.promoted, subject: "Unnamed stay",
                                           reason: "no Maps match; reverse geocoding supplied a name",
                                           evidence: visit.placeName, context: context)
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

    /// The one save that happens with nobody watching.
    ///
    /// Core Location wakes LifeLog in the background, so this can fail at 3am with the
    /// app never brought to the foreground. `lastError` lives in memory and shows only
    /// in Settings, so an overnight failure left no trace at all — by morning there was
    /// nothing to say an arrival had been dropped, or why.
    private func save(_ context: ModelContext) {
        do {
            try context.save()
            // The store has just proved it is writable, so this is the moment to move
            // any earlier failure out of the queue and into the log.
            Diagnostics.flushPending(context)
        } catch {
            lastError = "LifeLog couldn't securely save this update. Your existing timeline is unchanged."
            // Domain and code rather than the message: a Core Data error can name the
            // entity and attribute it failed on, and diagnostics stay clear of anything
            // describing where the owner has been.
            let failure = error as NSError
            Diagnostics.recordDurable(context, subsystem: "Store",
                                      message: "A background save failed (\(failure.domain) \(failure.code)). "
                                             + "The update was not written.")
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
