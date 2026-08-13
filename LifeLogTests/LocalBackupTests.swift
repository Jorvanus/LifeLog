import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct LocalBackupTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

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

    // MARK: - V1 compatibility

    @Test("A V1 backup, with none of the V2 fields, still restores")
    func v1BackupStillRestores() throws {
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
        try LocalBackupService.restore(Data(v1JSON.utf8), into: context)

        let visits = try context.fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1)
        #expect(visits.first?.placeName == "Old Cafe")
        #expect(visits.first?.routeData == nil)
        #expect(visits.first?.healthKitSampleIDs == nil)
        // No stableID/resolutionState in the archive: `restore` mints a fresh
        // identity and derives a state, rather than leaving either unset.
        #expect(visits.first?.stableID != nil)

        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        #expect(places.first?.role == nil)

        let diagnostics = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(diagnostics.first?.category == Diagnostics.Category.general)
    }

    // MARK: - Full V2 round trip

    @Test("Every V2 field round-trips: route, HealthKit IDs, roles, corrections, ignored state, diagnostics, activities")
    func fullV2RoundTrip() throws {
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
            // Ignored state now travels per-visit; a V2 archive carries none of the
            // legacy persistentModelID-text keys.
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
            #expect(restoredDiagnostics.first?.category == Diagnostics.Category.performance)
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
                .init(arrival: base, departure: nil, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: shared, resolutionState: nil, healthKitSampleIDs: nil, routeData: nil),
                .init(arrival: base.addingTimeInterval(3600), departure: nil, latitude: 0, longitude: 0, placeName: "B", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: shared, resolutionState: nil, healthKitSampleIDs: nil, routeData: nil)
            ],
            savedPlaces: [], corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], preferences: [:])
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
                .init(arrival: base, departure: nil, latitude: 0, longitude: 0, placeName: "A", inferredActivity: "Sleeping", userActivity: nil, note: "", source: "health-sleep", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: nil, resolutionState: nil, healthKitSampleIDs: [sharedSample], routeData: nil),
                .init(arrival: base.addingTimeInterval(3600), departure: nil, latitude: 0, longitude: 0, placeName: "B", inferredActivity: "Sleeping", userActivity: nil, note: "", source: "health-sleep", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: nil, resolutionState: nil, healthKitSampleIDs: [sharedSample], routeData: nil)
            ],
            savedPlaces: [], corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], preferences: [:])
        let data = try JSONEncoder.lifeLogBackup.encode(backup)

        let context = try makeContext()
        #expect(throws: BackupValidationError.self) {
            try LocalBackupService.restore(data, into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Visit>()).isEmpty)
    }

    // MARK: - Restore failure without partial data

    @Test("A backup that fails validation partway through its visits leaves earlier records unrestored too")
    func restoreFailureLeavesNoPartialData() throws {
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: [
                // Valid on its own -- would restore fine if it were alone.
                .init(arrival: base, departure: base.addingTimeInterval(1800), latitude: 0, longitude: 0, placeName: "Valid", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: UUID(), resolutionState: nil, healthKitSampleIDs: nil, routeData: nil),
                // Negative duration: departure precedes arrival.
                .init(arrival: base.addingTimeInterval(7200), departure: base.addingTimeInterval(3600), latitude: 0, longitude: 0, placeName: "Invalid", inferredActivity: "Visiting", userActivity: nil, note: "", source: "automatic", recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil, stableID: UUID(), resolutionState: nil, healthKitSampleIDs: nil, routeData: nil)
            ],
            savedPlaces: [.init(name: "Existing preference guard", latitude: 0, longitude: 0, radius: 100, defaultActivity: "", mapsIdentifier: nil, role: nil)],
            corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], preferences: ["LifeLog.Test.marker": "should-not-be-written"])
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

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self,
            configurations: configuration
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
