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
    var authorization: CLAuthorizationStatus = .notDetermined
    var isBackgroundLoggingEnabled = false
    var lastError: String?

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
        if isBackgroundLoggingEnabled, authorization != .notDetermined {
            startBackgroundWorkflow()
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
                self?.lastError = "Location permission status couldn’t be refreshed."
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
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.coordinate.latitude.isFinite, visit.coordinate.longitude.isFinite else { return }
        if visit.departureDate == .distantFuture {
            createVisit(at: visit.coordinate, arrival: visit.arrivalDate)
        } else {
            closeLatestVisit(at: visit.departureDate)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 * 60 else { return }
        identifyRecentUnknown(near: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }

    private func createVisit(at coordinate: CLLocationCoordinate2D, arrival: Date) {
        guard let context, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let safeArrival = min(arrival, .now)
        var recentDescriptor = FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival, order: .reverse)])
        recentDescriptor.fetchLimit = 1
        if let latest = try? context.fetch(recentDescriptor).first, latest.departure == nil {
            let existingLocation = CLLocation(latitude: latest.latitude, longitude: latest.longitude)
            let incomingLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if existingLocation.distance(from: incomingLocation) <= 150 { return }
            latest.departure = max(latest.arrival, safeArrival)
        }

        let saved = nearestSavedPlace(to: coordinate, context: context)
        let name = saved?.name ?? "Identifying…"
        let category = saved?.category ?? "Other"
        let activity = InferenceEngine.activity(placeName: name, category: category,
                                                defaultActivity: saved?.defaultActivity, arrival: safeArrival)
        let item = Visit(arrival: safeArrival, latitude: coordinate.latitude, longitude: coordinate.longitude,
                         placeName: name, placeCategory: category, inferredActivity: activity,
                         recognitionConfidence: saved == nil ? nil : "learned")
        context.insert(item)
        reconcileActivity(with: item, context: context)
        save(context)
        if saved == nil { identifyPlace(item) }
    }

    private func closeLatestVisit(at departure: Date) {
        guard let context else { return }
        var descriptor = FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival, order: .reverse)])
        descriptor.fetchLimit = 1
        if let latest = try? context.fetch(descriptor).first, latest.departure == nil {
            latest.departure = max(latest.arrival, min(departure, .now))
            reconcileActivity(with: latest, context: context)
            save(context)
        }
    }

    private func nearestSavedPlace(to coordinate: CLLocationCoordinate2D, context: ModelContext) -> SavedPlace? {
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return (try? context.fetch(FetchDescriptor<SavedPlace>()))?
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
        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            defer { self.identifyingVisits.remove(identity) }
            do {
                let result = try await PlaceLookupService.nearbyPlaces(at: coordinate, arrival: visit.arrival)
                visit.placeSuggestions = result.suggestions
                visit.recognitionConfidence = result.confidence.rawValue

                if result.confidence == .high, let match = result.suggestions.first, match.category != "Other" {
                    visit.placeName = match.name
                    visit.placeCategory = match.category
                    visit.inferredActivity = match.suggestedActivity
                    cache(match, context: context)
                } else if let likely = result.suggestions.first {
                    visit.placeName = likely.name
                    visit.inferredActivity = likely.suggestedActivity
                } else {
                    reverseGeocode(visit)
                    return
                }
                save(context)
            } catch {
                reverseGeocode(visit)
            }
        }
    }

    private func cache(_ match: PlaceSuggestion, context: ModelContext) {
        let coordinate = CLLocation(latitude: match.latitude, longitude: match.longitude)
        let existing = (try? context.fetch(FetchDescriptor<SavedPlace>()))?.contains { place in
            coordinate.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= 50
        } ?? false
        guard !existing else { return }
        context.insert(SavedPlace(name: TextSafety.clean(match.name, maximumLength: 100),
                                  latitude: match.latitude, longitude: match.longitude,
                                  radius: 85, category: match.category, defaultActivity: match.suggestedActivity))
    }

    private func reverseGeocode(_ visit: Visit) {
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        Task { @MainActor [weak self] in
            guard let self, let context = self.context,
                  let request = MKReverseGeocodingRequest(location: location) else { return }
            do {
                let mapItems = try await request.mapItems
                guard let item = mapItems.first else {
                    markUnknown(visit, context: context)
                    return
                }
                let resolvedName = item.name ?? item.address?.shortAddress ?? item.address?.fullAddress ?? "Unknown place"
                visit.placeName = TextSafety.clean(resolvedName, maximumLength: 120)
                visit.placeCategory = "Other"
                visit.recognitionConfidence = "low"
                visit.inferredActivity = InferenceEngine.activity(placeName: visit.placeName, category: visit.placeCategory,
                                                                   arrival: visit.arrival)
                save(context)
            } catch {
                markUnknown(visit, context: context)
            }
        }
    }

    private func markUnknown(_ visit: Visit, context: ModelContext) {
        visit.placeName = "Unknown place"
        visit.placeCategory = "Other"
        visit.recognitionConfidence = "low"
        visit.inferredActivity = "Visiting"
        save(context)
    }

    private func identifyRecentUnknown(near location: CLLocation) {
        guard let context else { return }
        var descriptor = FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival, order: .reverse)])
        descriptor.fetchLimit = 5
        guard let recent = try? context.fetch(descriptor) else { return }
        for visit in recent where visit.source == "automatic" && visit.placeCategory == "Other" {
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
            lastError = "LifeLog couldn’t securely save this update. Your existing timeline is unchanged."
        }
    }

    private func reconcileActivity(with locationVisit: Visit, context: ModelContext) {
        do {
            try ActivityLocationPolicy.reconcile(locationVisit: locationVisit, context: context)
        } catch {
            lastError = "LifeLog couldn’t reconcile activity with this location visit."
        }
    }
}
