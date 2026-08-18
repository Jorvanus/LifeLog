import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// Backup/restore coverage is deliberately independent of `SchemaMigrationTests`:
/// every test below builds its source and destination contexts against the live
/// model types directly (`makeContext()`), never against a frozen
/// `LifeLogSchemaVN` snapshot or `LifeLogMigrationPlan`. `LocalBackupService`
/// operates on whatever `ModelContext` it is handed and has no idea how that
/// context's container was constructed, so this suite proves restore correctness
/// on its own terms -- JSON shape, validation, identity preservation -- without
/// needing a single frozen-version fixture to do it. The one exception is
/// `restoresIntoAContainerOpenedThroughTheRealMigrationPlan`, which exists
/// specifically to confirm that independence doesn't hide an accidental
/// dependency: restore must also work against a container built the way the app
/// actually builds one.
@MainActor
struct LocalBackupTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Unknown persisted domain values remain lossless and are not reclassified")
    func unknownRawDomainValuesRemainReadable() throws {
        let visit = Visit(arrival: base, latitude: 0, longitude: 0, placeName: "Future source",
                          inferredActivity: "Visiting", source: "satellite-import-v2",
                          recognitionConfidence: "machine-verified",
                          placeFieldProvenance: "nearby-device-cache")
        #expect(visit.visitSource == .unknown("satellite-import-v2"))
        #expect(visit.recognition == .unknown("machine-verified"))
        #expect(visit.placeProvenance == .unknown("nearby-device-cache"))
        #expect(visit.visitSource.isLocation == false)

        let callback = LocationEvent(callbackType: "beacon-entry-v2", callbackAt: base,
                                     latitude: 0, longitude: 0, accuracy: 10,
                                     transition: "deferred")
        #expect(callback.callback == .unknown("beacon-entry-v2"))
        #expect(callback.resolverTransition == .unknown("deferred"))

        let diagnostic = DiagnosticEvent(subsystem: "Future subsystem", severity: "notice",
                                         message: "Kept as evidence", category: "retention-v2")
        #expect(diagnostic.diagnosticSubsystem == .unknown("Future subsystem"))
        #expect(diagnostic.diagnosticSeverity == .unknown("notice"))
        #expect(diagnostic.diagnosticCategory == .unknown("retention-v2"))

        let context = try makeContext()
        context.insert(visit)
        context.insert(callback)
        try context.save()
        let backup = try LocalBackupService.makeBackup(context: context, diagnostics: [diagnostic])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LifeLogBackup.self, from: backup)
        #expect(decoded.visits.first?.source == "satellite-import-v2")
        #expect(decoded.visits.first?.recognitionConfidence == "machine-verified")
        #expect(decoded.visits.first?.placeFieldProvenance == "nearby-device-cache")
        #expect(decoded.locationEvents?.first?.callbackType == "beacon-entry-v2")
        #expect(decoded.locationEvents?.first?.transition == "deferred")
    }

    @Test("Local backup round-trips into an empty store")
    func roundTrip() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, departure: base.addingTimeInterval(1800), latitude: -27.47, longitude: 153.03, placeName: "Cinema", inferredActivity: "Watching a movie", userActivity: "Watching a movie", source: "automatic", recognitionConfidence: "medium", mapsIdentifier: "maps-cinema", placeFieldProvenance: "maps"))
        sourceContext.insert(SavedPlace(name: "Cinema", latitude: -27.47, longitude: 153.03, defaultActivity: "Watching a movie", mapsIdentifier: "maps-cinema"))
        sourceContext.insert(LocationEvent(recordedAt: base.addingTimeInterval(10), callbackType: "geofence-entry",
                                           callbackAt: base, arrival: base, latitude: -27.47,
                                           longitude: 153.03, accuracy: 15, transition: "created",
                                           visitArrival: base))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)
        let restoredVisits = try restoredContext.fetch(FetchDescriptor<Visit>())
        #expect(restoredVisits.count == 1)
        #expect(restoredVisits.first?.mapsIdentifier == "maps-cinema")
        #expect(restoredVisits.first?.placeFieldProvenance == "maps")
        #expect(try restoredContext.fetch(FetchDescriptor<SavedPlace>()).first?.mapsIdentifier == "maps-cinema")
        let callbacks = try restoredContext.fetch(FetchDescriptor<LocationEvent>())
        #expect(callbacks.count == 1)
        #expect(callbacks.first?.callbackType == "geofence-entry")
    }

    // MARK: - Compatibility window

    @Test("A backup older than the immediately previous format is rejected without changing the destination")
    func v1BackupIsRejected() throws {
        let v1JSON = """
        {
          "version": 1,
          "createdAt": "2024-01-01T00:00:00Z",
          "visits": [
            {
              "arrival": "2024-01-01T09:00:00Z",
              "departure": "2024-01-01T10:00:00Z",
              "latitude": -27.47, "longitude": 153.03,
              "placeName": "Old Cafe", "inferredActivity": "Coffee",
              "userActivity": null, "note": "", "source": "automatic",
              "recognitionConfidence": "high", "candidateData": null,
              "mapsIdentifier": null, "placeFieldProvenance": null,
              "resolutionExplanation": null, "stableID": null, "resolutionState": null
            }
          ],
          "savedPlaces": [
            { "name": "Old Cafe", "latitude": -27.47, "longitude": 153.03, "radius": 100, "defaultActivity": "Coffee", "mapsIdentifier": null }
          ],
          "corrections": [],
          "diagnostics": [
            { "createdAt": "2024-01-01T00:00:00Z", "subsystem": "Test", "severity": "info", "message": "hello" }
          ],
          "locationEvents": null,
          "ignoredVisitKeys": ["persistent:<x-coredata://store/Visit/p1>"],
          "activityDefinitions": [],
          "preferences": {}
        }
        """
        let context = try makeContext()
        #expect(throws: (any Error).self) {
            try LocalBackupService.restore(Data(v1JSON.utf8), into: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<Visit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SavedPlace>()) == 0)
    }

    // MARK: - Full backup round trip

    @Test("Every current backup field round-trips: route, HealthKit IDs, roles, corrections, ignored state, diagnostics, activities")
    func fullCurrentBackupRoundTrip() throws {
        let sourceContext = try makeContext()
        let stableID = UUID()
        let sampleIDs = [UUID(), UUID()]
        let route = [RoutePoint(latitude: -27.47, longitude: 153.03, time: base),
                     RoutePoint(latitude: -27.48, longitude: 153.04, time: base.addingTimeInterval(600))]
        let routeData = try JSONEncoder().encode(route)

        let visit = Visit(arrival: base, departure: base.addingTimeInterval(1800),
                          latitude: -27.47, longitude: 153.03, placeName: "Park",
                          inferredActivity: "Walking", source: "health-walking",
                          recognitionConfidence: "device", mapsIdentifier: "maps-park",
                          placeFieldProvenance: "maps", healthKitSampleIDs: sampleIDs,
                          routeData: routeData, stableID: stableID, resolutionState: .resolved)
        sourceContext.insert(visit)

        let home = SavedPlace(name: "Home", latitude: -27.5, longitude: 153.0, defaultActivity: "At home", mapsIdentifier: "maps-home")
        home.homeWorkRole = .home
        sourceContext.insert(home)

        sourceContext.insert(VisitCorrection(changedAt: base.addingTimeInterval(3600), visitArrival: base, latitude: -27.47, longitude: 153.03, previousPlaceName: "Identifying…", newPlaceName: "Park", previousActivity: "Visiting", newActivity: "Walking"))
        try sourceContext.save()

        let diagnosticEvent = DiagnosticEvent(subsystem: "Test", message: "budget check", category: Diagnostics.Category.performance)

        ActivityCatalog.withStorage(UserDefaults(suiteName: "LocalBackupTests.\(UUID().uuidString)")!) {
            ActivityCatalog.save([ActivityDefinition(name: "Walking", category: "Fitness", symbol: "figure.walk")])
            let data = try! LocalBackupService.makeBackup(context: sourceContext, diagnostics: [diagnosticEvent])

            let iso8601Decoder = JSONDecoder(); iso8601Decoder.dateDecodingStrategy = .iso8601
            let decoded = try! iso8601Decoder.decode(LifeLogBackup.self, from: data)
            #expect(decoded.version == LifeLogBackup.currentVersion)
            #expect(decoded.visits.first?.routeData == routeData)
            #expect(decoded.visits.first?.healthKitSampleIDs == sampleIDs)
            #expect(decoded.visits.first?.stableID == stableID)
            #expect(decoded.visits.first?.resolutionState == VisitResolutionState.resolved.rawValue)
            #expect(decoded.savedPlaces.first?.role == "home")
            #expect(decoded.diagnostics.first?.category == Diagnostics.Category.performance)
            // Ignored state travels per-visit; the backup retains no retired
            // persistent-model-ID keys.
            #expect(decoded.ignoredVisitKeys.isEmpty)

            let restoredContext = try! makeContext()
            try! LocalBackupService.restore(data, into: restoredContext)

            let restoredVisit = try! restoredContext.fetch(FetchDescriptor<Visit>()).first
            #expect(restoredVisit?.stableID == stableID)
            #expect(restoredVisit?.resolutionState == .resolved)
            #expect(restoredVisit?.healthKitSampleIDs == sampleIDs)
            #expect(restoredVisit?.route == route)

            let restoredPlace = try! restoredContext.fetch(FetchDescriptor<SavedPlace>()).first
            #expect(restoredPlace?.homeWorkRole == .home)

            let restoredCorrections = try! restoredContext.fetch(FetchDescriptor<VisitCorrection>())
            #expect(restoredCorrections.count == 1)
            #expect(restoredCorrections.first?.newPlaceName == "Park")

            let restoredDiagnostics = try! restoredContext.fetch(FetchDescriptor<DiagnosticEvent>())
            // Not `.first`: the restore's own full-store audit stages a "Committed
            // backupRestore" diagnostic in the same commit, and an unsorted fetch
            // makes no promise about which of the two comes first.
            #expect(restoredDiagnostics.first { $0.subsystem == "Test" }?.category == Diagnostics.Category.performance)
        }
    }

    // MARK: - Route preservation

    @Test("A visit's route survives backup and restore exactly")
    func routePreservation() throws {
        let sourceContext = try makeContext()
        let route = [RoutePoint(latitude: 1, longitude: 2, time: base),
                     RoutePoint(latitude: 3, longitude: 4, time: base.addingTimeInterval(120)),
                     RoutePoint(latitude: 5, longitude: 6, time: base.addingTimeInterval(240))]
        let visit = Visit(arrival: base, latitude: 0, longitude: 0, placeName: "", inferredActivity: "Walking", source: "motion")
        visit.route = route
        sourceContext.insert(visit)
        try sourceContext.save()

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])
        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let restored = try restoredContext.fetch(FetchDescriptor<Visit>()).first
        #expect(restored?.route == route)
        #expect(restored?.hasRoute == true)
    }

    // MARK: - HealthKit identifier preservation

    @Test("HealthKit sample identifiers survive backup and restore")
    func healthKitIdentifierPreservation() throws {
        let sourceContext = try makeContext()
        let samples = [UUID(), UUID(), UUID()]
        sourceContext.insert(Visit(arrival: base, departure: base.addingTimeInterval(28_800),
                                   latitude: 0, longitude: 0, placeName: "", inferredActivity: "Sleeping",
                                   source: "health-sleep", healthKitSampleIDs: samples))
        try sourceContext.save()

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])
        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let restored = try restoredContext.fetch(FetchDescriptor<Visit>()).first
        #expect(restored?.healthKitSampleIDs == samples)
    }

    // MARK: - Saved Place role preservation

    @Test("Home and Work Saved Place roles survive backup and restore")
    func savedPlaceRolePreservation() throws {
        let sourceContext = try makeContext()
        let home = SavedPlace(name: "Home", latitude: -27.5, longitude: 153.0, mapsIdentifier: "maps-home")
        home.homeWorkRole = .home
        let work = SavedPlace(name: "Office", latitude: -27.6, longitude: 153.1, mapsIdentifier: "maps-office")
        work.homeWorkRole = .work
        let neither = SavedPlace(name: "Gym", latitude: -27.7, longitude: 153.2)
        sourceContext.insert(home); sourceContext.insert(work); sourceContext.insert(neither)
        try sourceContext.save()

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])
        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let places = try restoredContext.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.first { $0.name == "Home" }?.homeWorkRole == .home)
        #expect(places.first { $0.name == "Office" }?.homeWorkRole == .work)
        #expect(places.first { $0.name == "Gym" }?.homeWorkRole == nil)
    }

    // MARK: - Ignored-state preservation

    @Test("An ignored visit's resolution state survives by stable ID, not persistentModelID text")
    func ignoredStatePreservation() throws {
        let sourceContext = try makeContext()
        let visit = Visit(arrival: base, latitude: -27.47, longitude: 153.03,
                          placeName: "A misidentified drive-by", inferredActivity: "Visiting",
                          source: "automatic", recognitionConfidence: "low")
        sourceContext.insert(visit)
        try sourceContext.save()
        visit.isIgnored = true
        try sourceContext.save()
        #expect(visit.resolutionState == .ignored)
        let originalStableID = visit.stableID

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])
        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let restored = try restoredContext.fetch(FetchDescriptor<Visit>()).first
        #expect(restored?.stableID == originalStableID)
        #expect(restored?.resolutionState == .ignored)
        // `persistentModelID` is reassigned by every restore into a fresh store,
        // so it is `stableID` — not the SwiftData row identity — that has to
        // carry the ignore across. Confirms the two containers really did hand
        // out different row identities, which is exactly what the legacy
        // persistentModelID-text keys could never survive.
        #expect(restored?.persistentModelID != visit.persistentModelID)
    }

    // MARK: - Corrupt/truncated input

    @Test("Truncated JSON is rejected and leaves the destination store untouched")
    func truncatedInputRejected() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, latitude: -27.47, longitude: 153.03, placeName: "Cafe", inferredActivity: "Coffee", source: "automatic"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])
        let truncated = data.dropLast(data.count / 3)

        let restoredContext = try makeContext()
        #expect(throws: (any Error).self) {
            try LocalBackupService.restore(Data(truncated), into: restoredContext)
        }
        #expect(try restoredContext.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    // MARK: - Duplicate identifiers

    @Test("A backup with two visits sharing a stable ID is rejected before any insert")
    func duplicateStableIDRejected() throws {
        let shared = UUID()
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: [
                .init(arrival: base, departure: nil, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: shared, resolutionState: nil, healthKitSampleIDs: nil, routeData: nil),
                .init(arrival: base.addingTimeInterval(3600), departure: nil, latitude: 0, longitude: 0, placeName: "B", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: shared, resolutionState: nil, healthKitSampleIDs: nil, routeData: nil)
            ],
            savedPlaces: [], corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], activityDefinitionRecords: nil,
            preferences: [:], manifest: nil)
        let data = try JSONEncoder.lifeLogBackup.encode(backup)

        let context = try makeContext()
        #expect(throws: BackupValidationError.self) {
            try LocalBackupService.restore(data, into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    @Test("A backup with one HealthKit sample claimed by two visits is rejected")
    func duplicateHealthKitSampleRejected() throws {
        let sharedSample = UUID()
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: [
                .init(arrival: base, departure: nil, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "Sleeping", userActivity: nil, note: "", source: "health-sleep", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: nil, resolutionState: nil, healthKitSampleIDs: [sharedSample], routeData: nil),
                .init(arrival: base.addingTimeInterval(3600), departure: nil, latitude: 0, longitude: 0, placeName: "B", inferredActivity: "Sleeping", userActivity: nil, note: "", source: "health-sleep", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: nil, resolutionState: nil, healthKitSampleIDs: [sharedSample], routeData: nil)
            ],
            savedPlaces: [], corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], activityDefinitionRecords: nil,
            preferences: [:], manifest: nil)
        let data = try JSONEncoder.lifeLogBackup.encode(backup)

        let context = try makeContext()
        #expect(throws: BackupValidationError.self) {
            try LocalBackupService.restore(data, into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    @Test("A geofence-exit location event's negative accuracy is not rejected -- it means \"unavailable\", not corrupt")
    func negativeAccuracyLocationEventRestores() throws {
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: [], savedPlaces: [], corrections: [], diagnostics: [],
            locationEvents: [
                .init(recordedAt: base, callbackType: "geofence-exit", callbackAt: base,
                      arrival: base.addingTimeInterval(-1800), departure: base, latitude: 0, longitude: 0,
                      accuracy: -1, distanceFromCurrentVisit: nil, transition: "closed", visitArrival: base.addingTimeInterval(-1800))
            ],
            ignoredVisitKeys: [], activityDefinitions: [], activityDefinitionRecords: nil,
            preferences: [:], manifest: nil)
        let data = try JSONEncoder.lifeLogBackup.encode(backup)

        let context = try makeContext()
        try LocalBackupService.restore(data, into: context)
        let events = try context.fetch(FetchDescriptor<LocationEvent>())
        #expect(events.count == 1)
        #expect(events.first?.accuracy == -1)
    }

    // MARK: - Restore requires an empty destination

    @Test("Restoring into a store that already has data is rejected, not appended")
    func restoreIntoNonEmptyDestinationRejected() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, latitude: -27.47, longitude: 153.03, placeName: "Cinema", inferredActivity: "Watching a movie", source: "automatic"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let destinationContext = try makeContext()
        let existingVisit = Visit(arrival: base.addingTimeInterval(-3600), latitude: 1, longitude: 1, placeName: "Already here", inferredActivity: "Visiting", source: "automatic")
        destinationContext.insert(existingVisit)
        try destinationContext.save()

        #expect(throws: RestoreError.self) {
            try LocalBackupService.restore(data, into: destinationContext)
        }
        // Not appended: the pre-existing row is untouched and nothing from the
        // backup was inserted alongside it.
        let visits = try destinationContext.fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1)
        #expect(visits.first?.placeName == "Already here")
    }

    @Test("A non-empty destination is rejected even when only a non-repopulated model type has data")
    func restoreIntoDestinationWithOnlyPreExistingSavedPlaceRejected() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, latitude: -27.47, longitude: 153.03, placeName: "Cinema", inferredActivity: "Watching a movie", source: "automatic"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let destinationContext = try makeContext()
        destinationContext.insert(SavedPlace(name: "Existing", latitude: 0, longitude: 0, defaultActivity: "At home"))
        try destinationContext.save()

        #expect(throws: RestoreError.self) {
            try LocalBackupService.restore(data, into: destinationContext)
        }
        #expect(try destinationContext.fetch(FetchDescriptor<Visit>()).isEmpty)
        #expect(try destinationContext.fetch(FetchDescriptor<SavedPlace>()).count == 1)
    }

    // MARK: - Restore failure without partial data

    @Test("A backup that fails validation partway through its visits leaves earlier records unrestored too")
    func restoreFailureLeavesNoPartialData() throws {
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: [
                // Valid on its own -- would restore fine if it were alone.
                .init(arrival: base, departure: base.addingTimeInterval(1800), latitude: 0, longitude: 0, placeName: "Valid", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: UUID(), resolutionState: nil, healthKitSampleIDs: nil, routeData: nil),
                // Negative duration: departure precedes arrival.
                .init(arrival: base.addingTimeInterval(7200), departure: base.addingTimeInterval(3600), latitude: 0, longitude: 0, placeName: "Invalid", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: UUID(), resolutionState: nil, healthKitSampleIDs: nil, routeData: nil)
            ],
            savedPlaces: [.init(name: "Existing preference guard", latitude: 0, longitude: 0, radius: 100, defaultActivity: "", mapsIdentifier: nil, activityDefinitionID: nil, role: nil)],
            corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], activityDefinitionRecords: nil,
            preferences: ["LifeLog.Test.marker": "should-not-be-written"], manifest: nil)
        let data = try JSONEncoder.lifeLogBackup.encode(backup)

        let context = try makeContext()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "LifeLog.Test.marker")
        #expect(throws: BackupValidationError.self) {
            try LocalBackupService.restore(data, into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Visit>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SavedPlace>()).isEmpty)
        #expect(defaults.string(forKey: "LifeLog.Test.marker") == nil)
        defaults.removeObject(forKey: "LifeLog.Test.marker")
    }

    // MARK: - A large representative archive

    @Test("A large, varied archive restores completely and leaves the resolver's invariants clean")
    func largeRepresentativeArchive() throws {
        let sourceContext = try makeContext()
        var expectedStableIDs = Set<UUID>()
        for index in 0..<300 {
            let arrival = base.addingTimeInterval(Double(index) * 3600)
            let source = index.isMultiple(of: 5) ? "health-walking" : "automatic"
            let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(1800),
                              latitude: -27.0 - Double(index % 10) * 0.01,
                              longitude: 153.0 + Double(index % 10) * 0.01,
                              placeName: "Place \(index % 20)", inferredActivity: "Visiting",
                              source: source, recognitionConfidence: index.isMultiple(of: 3) ? "learned" : "medium",
                              mapsIdentifier: "maps-\(index % 20)",
                              healthKitSampleIDs: source == "health-walking" ? [UUID()] : nil,
                              routeData: source == "health-walking" ? try? JSONEncoder().encode([RoutePoint(latitude: -27, longitude: 153, time: arrival)]) : nil)
            expectedStableIDs.insert(visit.stableID)
            sourceContext.insert(visit)
        }
        for index in 0..<20 {
            let place = SavedPlace(name: "Place \(index)", latitude: -27.0 - Double(index) * 0.01,
                                   longitude: 153.0 + Double(index) * 0.01, mapsIdentifier: "maps-\(index)")
            if index == 0 { place.homeWorkRole = .home }
            if index == 1 { place.homeWorkRole = .work }
            sourceContext.insert(place)
        }
        for index in 0..<50 {
            sourceContext.insert(LocationEvent(recordedAt: base.addingTimeInterval(Double(index) * 60),
                                               callbackType: "geofence-entry", callbackAt: base,
                                               latitude: -27, longitude: 153, accuracy: 10,
                                               transition: "created"))
        }
        try sourceContext.save()
        let diagnostics = (0..<40).map { DiagnosticEvent(subsystem: "Test", message: "event \($0)", category: $0.isMultiple(of: 2) ? Diagnostics.Category.performance : Diagnostics.Category.general) }

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: diagnostics)
        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let restoredVisits = try restoredContext.fetch(FetchDescriptor<Visit>())
        #expect(restoredVisits.count == 300)
        #expect(Set(restoredVisits.map(\.stableID)) == expectedStableIDs)
        #expect(try restoredContext.fetch(FetchDescriptor<SavedPlace>()).count == 20)
        #expect(try restoredContext.fetch(FetchDescriptor<LocationEvent>()).count == 50)

        let validation = try ActivityLocationPolicy.validateLocationResolution(context: restoredContext)
        #expect(validation.negativeDurations == 0)
        #expect(validation.resolvedOverlaps == 0)
    }

    @Test("Activity identity migration keeps diacritic-distinct names separate but links a case-only difference")
    func activityIdentityMigrationIsConservative() throws {
        let context = try makeContext()
        let defaultsSuite = "ActivityIdentityMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let cafe = ActivityDefinition(name: "Cafe", category: "Food & Drink", symbol: "cup.and.saucer.fill")
        let accented = ActivityDefinition(name: "Café", category: "Social", symbol: "person.2.fill")
        try ActivityCatalog.withStorage(defaults) {
            ActivityCatalog.save([cafe, accented])
            context.insert(Visit(arrival: base, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "Cafe"))
            context.insert(Visit(arrival: base.addingTimeInterval(60), latitude: 0, longitude: 0, placeName: "B", inferredActivity: "Café"))
            context.insert(Visit(arrival: base.addingTimeInterval(120), latitude: 0, longitude: 0, placeName: "C", inferredActivity: "CAFE"))
            try context.save()
            #expect(ActivityCatalog.adoptFromHistory("Cafe!") == true)
            #expect(ActivityCatalog.load().count == 3)
            _ = try ActivityIdentityMigration.adoptLegacyDefinitions(context: context,
                                                                       definitions: ActivityCatalog.load())
            let progress = try ActivityIdentityMigration.backfillNextBatch(context: context)
            #expect(progress.adoptedDefinitions == 0)
        }
        let definitions = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        #expect(definitions.count == 3)
        #expect(Set(definitions.map(\.stableID)).isSuperset(of: Set([cafe.id, accented.id])))
        let visits = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
        #expect(visits[0].activityDefinitionID == cafe.id)
        #expect(visits[1].activityDefinitionID == accented.id)
        // "CAFE" is "Cafe" typed in caps, and links to it. The rule that matters
        // is that `Cafe` and `Café` stay two activities — they differ by a
        // diacritic, not by case, so the case-only fallback never sees them as
        // the same candidate. See `ActivityIdentityMigration.LabelIndex`.
        #expect(visits[2].activityDefinitionID == cafe.id)
    }

    @Test("Two activities differing only in case link to neither")
    func activityIdentityMigrationRefusesAmbiguousCase() throws {
        let context = try makeContext()
        let defaultsSuite = "ActivityIdentityMigration.ambiguous.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        // Deliberately created as two separate activities. Folding them would be
        // irreversible data loss, so an ambiguous fold links nothing and leaves
        // the snapshot label intact.
        let lower = ActivityDefinition(name: "gym", category: "Fitness", symbol: "dumbbell.fill")
        let upper = ActivityDefinition(name: "Gym", category: "Fitness", symbol: "dumbbell.fill")
        try ActivityCatalog.withStorage(defaults) {
            ActivityCatalog.save([lower, upper])
            _ = try ActivityIdentityMigration.adoptLegacyDefinitions(context: context,
                                                                       definitions: ActivityCatalog.load())
            context.insert(Visit(arrival: base, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "GYM"))
            try context.save()
            _ = try ActivityIdentityMigration.backfillNextBatch(context: context)
        }
        let visits = try context.fetch(FetchDescriptor<Visit>())
        #expect(visits[0].activityDefinitionID == nil)
    }

    @Test("Activity identity backfill is bounded for a large archive")
    func activityIdentityBackfillIsBounded() throws {
        let context = try makeContext()
        let defaultsSuite = "ActivityIdentityMigration.large.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let work = ActivityDefinition(name: "Work", category: "Work", symbol: "briefcase.fill")
        try ActivityCatalog.withStorage(defaults) {
            ActivityCatalog.save([work])
            _ = try ActivityIdentityMigration.adoptLegacyDefinitions(context: context,
                                                                       definitions: ActivityCatalog.load())
            for index in 0..<32_000 {
                context.insert(Visit(arrival: base.addingTimeInterval(Double(index)), latitude: 0, longitude: 0,
                                     placeName: "Office", inferredActivity: "Work"))
            }
            try context.save()
            let clock = ContinuousClock()
            let start = clock.now
            let progress = try ActivityIdentityMigration.backfillNextBatch(context: context)
            #expect(progress.linkedVisits == ActivityIdentityMigration.batchSize)
            #expect(clock.now - start < .seconds(10))
        }
        let linked = try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.activityDefinitionID != nil })).count
        #expect(linked == ActivityIdentityMigration.batchSize)
    }

    // MARK: - Restoring into a real, migration-plan-backed container

    @Test("A V4 backup round-trips durable activity aliases and inactive state")
    func durableActivityDefinitionsRoundTripWithoutLegacySnapshot() throws {
        let source = try makeContext()
        let activityID = UUID()
        source.insert(ActivityDefinitionRecord(stableID: activityID, name: "Breakfast",
                                               category: "Food & Drink", symbol: "sunrise.fill",
                                               legacyNames: ["Morning meal"], isActive: false,
                                               createdAt: base, modifiedAt: base))
        source.insert(Visit(arrival: base, latitude: -23.38, longitude: 150.51,
                            placeName: "Home", inferredActivity: "Breakfast",
                            activityDefinitionID: activityID, source: "manual"))
        try source.save()

        let data = try LocalBackupService.makeBackup(context: source, diagnostics: [])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(LifeLogBackup.self, from: data)
        #expect(document.version == 4)
        #expect(document.activityDefinitions.isEmpty)
        #expect(document.activityDefinitionRecords?.first?.legacyNames == ["Morning meal"])

        let destination = try makeContext()
        try LocalBackupService.restore(data, into: destination)
        let restored = try #require(destination.fetch(FetchDescriptor<ActivityDefinitionRecord>()).first)
        #expect(restored.stableID == activityID)
        #expect(restored.legacyNames == ["Morning meal"])
        #expect(restored.isActive == false)
    }

    /// Every other test in this file restores into a plain live-model container,
    /// which is deliberate -- see the type's doc comment. This one instead opens a
    /// container the same way `LifeLogApp` does, through `LifeLogMigrationPlan`
    /// against an on-disk store, to confirm restore has no hidden dependency on
    /// bypassing that path. The store is freshly created at V12 (nothing to
    /// migrate from), so this is not a migration test and duplicates none of
    /// `SchemaMigrationTests`' frozen-version fixtures; it only proves the two
    /// subsystems compose.
    @Test("Restore succeeds into a container opened through the real versioned migration plan, not just a fresh in-memory one")
    func restoresIntoAContainerOpenedThroughTheRealMigrationPlan() throws {
        let sourceContext = try makeContext()
        sourceContext.insert(Visit(arrival: base, departure: base.addingTimeInterval(1800),
                                   latitude: -27.47, longitude: 153.03, placeName: "Museum",
                                   inferredActivity: "Visiting", source: "automatic",
                                   recognitionConfidence: "learned"))
        try sourceContext.save()
        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [])

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-backup-into-versioned-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let restoredContext = try makeVersionedContext(at: storeURL)
        try LocalBackupService.restore(data, into: restoredContext)

        let restored = try restoredContext.fetch(FetchDescriptor<Visit>())
        #expect(restored.count == 1)
        #expect(restored.first?.placeName == "Museum")
        #expect(restored.first?.stableID != nil)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeVersionedContext(at url: URL) throws -> ModelContext {
        let schema = Schema(versionedSchema: LifeLogSchemaV12.self)
        let configuration = ModelConfiguration(
            "LifeLogBackupFixture", schema: schema, url: url,
            allowsSave: true, cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema, migrationPlan: LifeLogMigrationPlan.self, configurations: [configuration]
        )
        return ModelContext(container)
    }
}

private extension JSONEncoder {
    static var lifeLogBackup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
