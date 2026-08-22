import CoreLocation
import SwiftData
import Testing
@testable import LifeLog

struct LocationArrivalConfirmationTests {
    private func sample(_ offset: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 12,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A launch arrival needs consecutive stationary live updates")
    func requiresRecentStationaryUpdates() {
        var confirmation = LocationArrivalConfirmation()
        let moving = sample()
        confirmation.append(location: moving, stationary: false)
        #expect(confirmation.confirmedLocation == nil)

        confirmation.append(location: sample(1), stationary: true)
        #expect(confirmation.confirmedLocation == nil)

        let stationary = sample(2)
        confirmation.append(location: stationary, stationary: true)
        #expect(confirmation.confirmedLocation == stationary)
    }

    @Test("A confirmation burst has a hard sample cap")
    func stopsAcceptingSamplesAtLimit() {
        var confirmation = LocationArrivalConfirmation()
        for offset in 0...LocationArrivalConfirmation.maximumSamples {
            confirmation.append(location: sample(TimeInterval(offset)), stationary: true)
        }

        #expect(confirmation.samples.count == LocationArrivalConfirmation.maximumSamples)
        #expect(confirmation.hasReachedSampleLimit)
    }

    private func sample(_ offset: TimeInterval, latitudeOffset: Double, accuracy: CLLocationAccuracy = 12) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47 + latitudeOffset, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: accuracy,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A cluster that never reads stationary still confirms once it spans long enough")
    func clusteredSamplesConfirmWithoutTheStationaryFlag() {
        // The exact shape observed on-device 2026-08-10, indoors: every sample
        // reads stationary=false, but the phone never actually moved.
        var confirmation = LocationArrivalConfirmation()
        for offset in stride(from: 0, through: 8, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: 0), stationary: false)
        }
        #expect(confirmation.confirmedLocation != nil)
    }

    @Test("A cluster spanning less than the minimum time does not confirm")
    func briefClusterDoesNotConfirm() {
        var confirmation = LocationArrivalConfirmation()
        for offset in stride(from: 0, through: 5, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: 0), stationary: false)
        }
        #expect(confirmation.confirmedLocation == nil)
    }

    @Test("Real movement across the window does not confirm as stationary")
    func movingClusterDoesNotConfirm() {
        var confirmation = LocationArrivalConfirmation()
        // ~0.0009 degrees latitude is roughly 100 m -- comfortably past the
        // cluster tolerance even at this accuracy, over an 8-second span.
        for offset in stride(from: 0, through: 8, by: 1) {
            confirmation.append(location: sample(TimeInterval(offset), latitudeOffset: Double(offset) * 0.0009 / 8),
                                stationary: false)
        }
        #expect(confirmation.confirmedLocation == nil)
    }

    @Test("Typed callback adapter preserves delayed arrivals without touching Core Location state")
    func delayedArrivalIsAdaptedDeterministically() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = CoreLocationEventAdapter(now: { now })
        let visit = MockCLVisit(coordinate: .init(latitude: -27.47, longitude: 153.03),
                                horizontalAccuracy: 12,
                                arrivalDate: now.addingTimeInterval(-7 * 24 * 60 * 60),
                                departureDate: .distantFuture)
        guard case let .visitArrival(_, _, _, delay)? = adapter.event(for: visit) else {
            Issue.record("Expected an arrival event")
            return
        }
        #expect(delay == 7 * 24 * 60 * 60)
    }

    @Test("A newer place-resolution token rejects a stale Maps response")
    @MainActor
    func staleMapsLookupIsRejected() {
        let coordinator = PlaceResolutionCoordinator()
        let visit = Visit(arrival: .now, latitude: -27.47, longitude: 153.03,
                          placeName: Visit.identifyingPlaceName, inferredActivity: "Visiting")
        let old = coordinator.begin(for: visit)
        let new = coordinator.begin(for: visit)
        #expect(coordinator.isCurrent(old, for: visit) == false)
        #expect(coordinator.isCurrent(new, for: visit))
    }

    @Test("A Core Location failure retains the framework's reason in diagnostics")
    @MainActor
    func locationFailureKeepsFrameworkDetails() {
        var recordedMessage: String?
        let recorder = LocationRecorder(diagnosticsRecorder: .init { _, message, _ in
            recordedMessage = message
        })
        let error = NSError(domain: "kCLErrorDomain", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Location permission denied"])

        recorder.locationManager(CLLocationManager(), didFailWithError: error)

        #expect(recorder.lastError == "Location updates are temporarily unavailable.")
        #expect(recordedMessage == "A location update failed (kCLErrorDomain 1): Location permission denied")
    }

    @Test("Relaunch recovery only starts the background workflow when it can be useful")
    func recoveryStartPolicyIsExplicit() {
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: true, authorization: .authorizedAlways
        ))
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: true, authorization: .notDetermined
        ) == false)
        #expect(LocationRecoveryCoordinator.shouldStartBackgroundWorkflow(
            enabled: false, authorization: .authorizedAlways
        ) == false)
    }

    @Test("A restart rebuilds the location session when the held one is gone")
    func deadServiceSessionIsRebuiltRatherThanAssumedLive() {
        // The bug: the recorder kept `.always` as its requirement after the session
        // behind it ended, so restarting background recording matched the stale
        // requirement and did nothing. Recording stayed off until the app was quit.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .always, hasLiveSession: false, required: .always
        ))
        // A live session for the same requirement is the one case that must not be
        // torn down and rebuilt, or every restart would drop delivery for a moment.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .always, hasLiveSession: true, required: .always
        ) == false)
        // Upgrading from the when-in-use session `requestPermission` holds.
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: .whenInUse, hasLiveSession: true, required: .always
        ))
        #expect(LocationRecoveryCoordinator.shouldRebuildServiceSession(
            held: nil, hasLiveSession: false, required: .always
        ))
    }

    // MARK: - GeofenceMonitor.plan

    private func rankedPlace(_ name: String, latitude: Double = -27.47, longitude: Double = 153.03) -> MonitoredPlaces.Ranked {
        .init(name: name, latitude: latitude, longitude: longitude, radius: 100, visits: 1, lastVisit: .now)
    }

    @Test("A region synchronisation plan adds everything wanted when nothing is monitored yet")
    func planAddsEverythingFromEmpty() {
        let wanted = [rankedPlace("Home"), rankedPlace("Work")]
        let plan = GeofenceMonitor.plan(wanted: wanted, monitoredIdentifiers: [])
        #expect(Set(plan.toAdd.map(\.identifier)) == Set(wanted.map(\.identifier)))
        #expect(plan.toRemove.isEmpty)
    }

    @Test("A region synchronisation plan changes nothing once the monitored set already matches")
    func planIsEmptyWhenAlreadySynchronised() {
        let wanted = [rankedPlace("Home"), rankedPlace("Work")]
        let plan = GeofenceMonitor.plan(wanted: wanted, monitoredIdentifiers: Set(wanted.map(\.identifier)))
        #expect(plan.toAdd.isEmpty)
        #expect(plan.toRemove.isEmpty)
    }

    @Test("A region synchronisation plan only touches what actually changed")
    func planIsMinimalOnAMixedSet() {
        let home = rankedPlace("Home")
        let work = rankedPlace("Work")
        let stale = "place|stale-gym|-27.50000,153.05000"
        // Home is already monitored and still wanted -- neither added nor removed.
        // Work is wanted but not yet monitored -- added. `stale` is monitored but no
        // longer wanted -- removed.
        let plan = GeofenceMonitor.plan(wanted: [home, work], monitoredIdentifiers: [home.identifier, stale])
        #expect(plan.toAdd.map(\.identifier) == [work.identifier])
        #expect(plan.toRemove == [stale])
    }

    @Test("A geofence exit only closes a stay that is still open at the same place")
    func matchesExitRequiresOpenAndSamePlace() {
        let open = Visit(arrival: .now, latitude: -27.47, longitude: 153.03,
                         placeName: "Home", inferredActivity: "Visiting")
        #expect(GeofenceMonitor.matchesExit(open: open, name: "Home"))
        #expect(GeofenceMonitor.matchesExit(open: open, name: "home"), "the match is case-insensitive")
        #expect(!GeofenceMonitor.matchesExit(open: open, name: "Work"), "a different place must not close this stay")

        let closed = Visit(arrival: .now.addingTimeInterval(-3600), departure: .now, latitude: -27.47, longitude: 153.03,
                           placeName: "Home", inferredActivity: "Visiting")
        #expect(!GeofenceMonitor.matchesExit(open: closed, name: "Home"),
               "an already-closed stay must not be closed a second time by a stale event")
    }

    // MARK: - ArrivalConfirmationSession

    private func stationarySample(_ offset: TimeInterval) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -27.47, longitude: 153.03),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 12,
                   timestamp: Date.now.addingTimeInterval(offset))
    }

    @Test("A session folds a second begin into the running burst instead of starting another")
    @MainActor
    func sessionFoldsRepeatedBeginIntoRunningBurst() {
        let session = ArrivalConfirmationSession()
        #expect(session.begin(pendingArrival: nil))
        #expect(session.isActive)
        #expect(!session.begin(pendingArrival: nil), "a second begin while one is active must fold in, not restart")
    }

    @Test("A CLVisit arrival supersedes an in-flight launch check")
    @MainActor
    func sessionArrivalSupersedesBareLaunchCheck() {
        let session = ArrivalConfirmationSession()
        #expect(session.begin(pendingArrival: nil))
        let arrival = PendingArrival(coordinate: .init(latitude: -27.47, longitude: 153.03),
                                     arrival: .now, callbackType: .visitArrival, accuracy: 10)
        #expect(session.begin(pendingArrival: arrival), "an arrival must cancel and restart the bare launch check")
        #expect(session.pendingArrival?.arrival == arrival.arrival)
    }

    @Test("A finished session reports its samples' outcome and becomes inactive")
    @MainActor
    func sessionFinishReportsOutcomeAndClears() {
        let session = ArrivalConfirmationSession()
        _ = session.begin(pendingArrival: nil)
        _ = session.append(location: stationarySample(0), stationary: false)
        _ = session.append(location: stationarySample(1), stationary: true)
        let count = session.append(location: stationarySample(2), stationary: true)
        #expect(count == 3)

        let outcome = session.finish()
        #expect(outcome?.confirmedLocation != nil)
        #expect(outcome?.sampleCount == 3)
        #expect(!session.isActive)
        // A finished session can begin again immediately.
        #expect(session.begin(pendingArrival: nil))
    }

    @Test("Cancelling an inactive-again session is a no-op, not an outcome")
    @MainActor
    func sessionFinishIsNilWhenNothingIsActive() {
        let session = ArrivalConfirmationSession()
        #expect(session.finish() == nil)
    }

    @Test("A waiter resumes when the session finishes, not before")
    @MainActor
    func sessionAwaiterResumesOnFinish() async {
        let session = ArrivalConfirmationSession()
        _ = session.begin(pendingArrival: nil)
        let waiter = Task { await session.awaitCompletion() }
        // Give the waiter a chance to register before the session ends.
        await Task.yield()
        session.cancel()
        await waiter.value
    }

    // MARK: - VisitArrivalMerge

    @Test("A duplicate match requires proximity and either a matching arrival or an open stay")
    func duplicateMatchRequiresProximityAndTiming() {
        let arrival = Date.now
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let sameArrivalFarAway = Visit(arrival: arrival, latitude: -27.60, longitude: 153.10,
                                       placeName: "Elsewhere", inferredActivity: "Visiting")
        let closeButDifferentTimeAndClosed = Visit(arrival: arrival.addingTimeInterval(10 * 60),
                                                    departure: arrival.addingTimeInterval(20 * 60),
                                                    latitude: -27.47, longitude: 153.03,
                                                    placeName: "Closed", inferredActivity: "Visiting")
        let closeAndSameArrival = Visit(arrival: arrival.addingTimeInterval(30),
                                        latitude: -27.4701, longitude: 153.0301,
                                        placeName: "Match", inferredActivity: "Visiting")

        #expect(VisitArrivalMerge.duplicateMatch(coordinate: coordinate, arrival: arrival,
                                                  in: [sameArrivalFarAway, closeButDifferentTimeAndClosed]) == nil)
        #expect(VisitArrivalMerge.duplicateMatch(coordinate: coordinate, arrival: arrival,
                                                  in: [closeAndSameArrival]) === closeAndSameArrival)
    }

    @Test("A duplicate match also fires for a close, still-open stay regardless of arrival time")
    func duplicateMatchFiresForOpenStayEvenWithDifferentArrival() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let openStay = Visit(arrival: Date.now.addingTimeInterval(-3600), latitude: -27.4701, longitude: 153.0301,
                             placeName: "Open", inferredActivity: "Visiting")
        #expect(VisitArrivalMerge.duplicateMatch(coordinate: coordinate, arrival: .now, in: [openStay]) === openStay)
    }

    @Test("A close arrival merges into the currently open stay")
    func outcomeMergesWhenClose() {
        let openVisit = Visit(arrival: Date.now.addingTimeInterval(-600), latitude: -27.47, longitude: 153.03,
                              placeName: "Home", inferredActivity: "Visiting")
        let outcome = VisitArrivalMerge.outcome(for: openVisit, coordinate: .init(latitude: -27.4701, longitude: 153.0301),
                                                arrival: .now, wifiObservation: nil)
        #expect(outcome == .mergeIntoOpen)
    }

    @Test("A far, earlier arrival bounds the new visit's departure instead of closing the open stay")
    func outcomeBoundsNewVisitWhenArrivalIsOlder() {
        let latestArrival = Date.now
        let openVisit = Visit(arrival: latestArrival, latitude: -27.47, longitude: 153.03,
                              placeName: "Home", inferredActivity: "Visiting")
        let outcome = VisitArrivalMerge.outcome(for: openVisit, coordinate: .init(latitude: -27.60, longitude: 153.10),
                                                arrival: latestArrival.addingTimeInterval(-3600), wifiObservation: nil)
        #expect(outcome == .boundNewVisitDeparture(latestArrival))
    }

    @Test("A far, newer arrival closes the open stay at its own timestamp with no Wi-Fi evidence")
    func outcomeClosesOpenVisitWithoutWiFiAnchor() {
        let openArrival = Date.now.addingTimeInterval(-3600)
        let openVisit = Visit(arrival: openArrival, latitude: -27.47, longitude: 153.03,
                              placeName: "Home", inferredActivity: "Visiting")
        let newArrival = Date.now
        let outcome = VisitArrivalMerge.outcome(for: openVisit, coordinate: .init(latitude: -27.60, longitude: 153.10),
                                                arrival: newArrival, wifiObservation: nil)
        #expect(outcome == .closeOpenVisit(departure: newArrival, usedWiFiAnchor: false))
    }

    @Test("A Wi-Fi absence observed before the next arrival sharpens the close")
    func outcomeClosesOpenVisitWithWiFiAnchor() {
        let openArrival = Date.now.addingTimeInterval(-3600)
        let openVisit = Visit(arrival: openArrival, latitude: -27.47, longitude: 153.03,
                              placeName: "Home", inferredActivity: "Visiting")
        let absentAt = openArrival.addingTimeInterval(1800)
        let observation = WiFiAnchor.Observation(networkHash: "abc", lastSeen: openArrival, firstAbsent: absentAt)
        let newArrival = Date.now
        let outcome = VisitArrivalMerge.outcome(for: openVisit, coordinate: .init(latitude: -27.60, longitude: 153.10),
                                                arrival: newArrival, wifiObservation: observation)
        #expect(outcome == .closeOpenVisit(departure: absentAt, usedWiFiAnchor: true))
    }

    @Test("Nothing open produces no outcome")
    func outcomeIsNilWithNoOpenVisit() {
        #expect(VisitArrivalMerge.outcome(for: nil, coordinate: .init(latitude: -27.47, longitude: 153.03),
                                          arrival: .now, wifiObservation: nil) == nil)
    }

    // MARK: - VisitArrivalFactory

    @Test("With no Saved Place match, the visit is unidentified and placeless")
    func makeVisitWithNoSavedPlaceIsIdentifying() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let item = VisitArrivalFactory.makeVisit(coordinate: coordinate, arrival: .now, departure: nil,
                                                  saved: nil, savedDistance: nil, learnedActivity: nil)
        #expect(item.placeName == Visit.identifyingPlaceName)
        #expect(item.recognitionConfidence == nil)
        #expect(item.mapsIdentifier == nil)
        #expect(item.placeFieldProvenance == nil)
        #expect(item.resolutionExplanation == nil)
        #expect(item.locationResolutionCandidates == nil)
    }

    @Test("A Saved Place match names the visit and records it as a resolution candidate")
    func makeVisitWithSavedPlaceIsLearnedAndCandidateRecorded() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let saved = SavedPlace(name: "Home", latitude: -27.4701, longitude: 153.0301,
                               defaultActivity: "Sleeping", mapsIdentifier: "maps-123")
        let item = VisitArrivalFactory.makeVisit(coordinate: coordinate, arrival: .now, departure: nil,
                                                  saved: saved, savedDistance: 25, learnedActivity: nil)
        #expect(item.placeName == "Home")
        #expect(item.inferredActivity == "Sleeping")
        #expect(item.recognitionConfidence == "learned")
        #expect(item.mapsIdentifier == "maps-123")
        #expect(item.placeFieldProvenance == "saved-place")
        #expect(item.resolutionExplanation == LocationResolutionExplanation.savedPlace.rawValue)
        #expect(item.locationResolutionCandidates?.chosen?.name == "Home")
        #expect(item.locationResolutionCandidates?.chosen?.distance == 25)
        #expect(item.locationResolutionCandidates?.rejected.isEmpty == true)
    }

    @Test("A learned activity is only used when the Saved Place has none of its own")
    func makeVisitPrefersSavedPlaceActivityOverLearned() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let savedWithDefault = SavedPlace(name: "Home", latitude: -27.47, longitude: 153.03, defaultActivity: "Sleeping")
        let item = VisitArrivalFactory.makeVisit(coordinate: coordinate, arrival: .now, departure: nil,
                                                  saved: savedWithDefault, savedDistance: 10, learnedActivity: "Working")
        #expect(item.inferredActivity == "Sleeping", "the Saved Place's own default activity wins over a learned guess")
    }

    @Test("The new visit's departure is whatever the caller inferred, unset when nothing was")
    func makeVisitCarriesTheInferredDeparture() {
        let coordinate = CLLocationCoordinate2D(latitude: -27.47, longitude: 153.03)
        let departure = Date.now
        let item = VisitArrivalFactory.makeVisit(coordinate: coordinate, arrival: .now.addingTimeInterval(-3600),
                                                  departure: departure, saved: nil, savedDistance: nil, learnedActivity: nil)
        #expect(item.departure == departure)
    }

    // MARK: - SavedPlaceCache

    @Test("The nearest place wins, and one outside every radius is not a match")
    @MainActor
    func cacheFindsTheNearestPlaceWithinRadius() throws {
        let context = try makeSavedPlaceContext()
        // ~0.0002 degrees is roughly 22 m at this latitude, comfortably inside
        // both places' 100 m radius but clearly farther than the exact match.
        let nearer = SavedPlace(name: "Nearer Cafe", latitude: -27.4700, longitude: 153.0300, radius: 100)
        let farther = SavedPlace(name: "Farther Cafe", latitude: -27.4702, longitude: 153.0302, radius: 100)
        let outOfRange = SavedPlace(name: "Distant Cafe", latitude: -27.60, longitude: 153.10, radius: 100)
        [nearer, farther, outOfRange].forEach(context.insert)
        try context.save()

        let cache = SavedPlaceCache()
        _ = cache.reload(context: context)
        let match = cache.nearest(to: .init(latitude: -27.47, longitude: 153.03))

        #expect(match?.name == "Nearer Cafe")
    }

    @Test("Nothing within any radius is not a match")
    @MainActor
    func cacheReturnsNilWhenNothingIsInRange() throws {
        let context = try makeSavedPlaceContext()
        context.insert(SavedPlace(name: "Distant Cafe", latitude: -27.60, longitude: 153.10, radius: 100))
        try context.save()

        let cache = SavedPlaceCache()
        _ = cache.reload(context: context)

        #expect(cache.nearest(to: .init(latitude: -27.47, longitude: 153.03)) == nil)
    }

    @Test("Reload reports the fetched place count")
    @MainActor
    func cacheReloadReportsCount() throws {
        let context = try makeSavedPlaceContext()
        context.insert(SavedPlace(name: "Home", latitude: -27.47, longitude: 153.03))
        context.insert(SavedPlace(name: "Work", latitude: -27.46, longitude: 153.04))
        try context.save()

        let cache = SavedPlaceCache()
        let result = cache.reload(context: context)

        #expect(try result.get() == 2)
        #expect(cache.places.count == 2)
    }

    @MainActor
    private func makeSavedPlaceContext() throws -> ModelContext {
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
}

/// `CLVisit` has no public initializer -- CoreLocation only ever hands one to the
/// delegate itself -- so a test that needs one overrides its read-only properties
/// on a subclass instead.
private final class MockCLVisit: CLVisit {
    private let mockCoordinate: CLLocationCoordinate2D
    private let mockHorizontalAccuracy: CLLocationAccuracy
    private let mockArrivalDate: Date
    private let mockDepartureDate: Date

    init(coordinate: CLLocationCoordinate2D, horizontalAccuracy: CLLocationAccuracy,
         arrivalDate: Date, departureDate: Date) {
        self.mockCoordinate = coordinate
        self.mockHorizontalAccuracy = horizontalAccuracy
        self.mockArrivalDate = arrivalDate
        self.mockDepartureDate = departureDate
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("MockCLVisit does not support NSCoding")
    }

    override var coordinate: CLLocationCoordinate2D { mockCoordinate }
    override var horizontalAccuracy: CLLocationAccuracy { mockHorizontalAccuracy }
    override var arrivalDate: Date { mockArrivalDate }
    override var departureDate: Date { mockDepartureDate }
}
