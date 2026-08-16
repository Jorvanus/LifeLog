import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// Guards the promise `LocalBackupService`'s own doc comment makes: a local
/// backup represents the *current* schema, not a compatibility snapshot of
/// it. Two checks per `@Model` type, both against a real instance rather than
/// a hand-maintained list, so a field added to a model without also being
/// wired into its backup record fails here rather than silently vanishing
/// from every future backup:
///
/// 1. `assertFieldCoverage` — every one of a model's own stored properties
///    (found via `Mirror`, never a hand-copied list that could itself go
///    stale) has a same-named field on its backup record, modulo the one
///    documented rename (`Visit.resolutionStateRaw` ->
///    `VisitRecord.resolutionState`). This catches a field that exists on
///    neither side of `encodeBackup`/`restore` at all.
/// 2. `fullArchiveRoundTrips` — a single context holding one fully-populated,
///    cross-referencing instance of every current `@Model` type restores
///    with every field intact, not merely present. This catches a field that
///    has a backup counterpart but whose value silently drops out somewhere
///    in `encodeBackup` or `restore`.
@MainActor
struct ArchiveModelFieldCoverageTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self,
                 DiagnosticEvent.self, LocationEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A model's or record's own stored property names. `Mirror` reflects the
    /// object's actual storage, so this can never drift from what the type
    /// really declares the way a hand-copied list beside it could.
    ///
    /// `@Model` (SwiftData's macro) backs every stored property with an
    /// underscore-prefixed storage variable and adds two framework-owned ones
    /// of its own (`_$backingData`, `_$observationRegistrar`) — normalised
    /// away here so a `Visit` and its plain-struct `VisitRecord` compare on
    /// the same footing.
    private func storedFieldNames(_ instance: Any) -> Set<String> {
        Set(Mirror(reflecting: instance).children.compactMap { child -> String? in
            guard let label = child.label, !label.hasPrefix("_$") else { return nil }
            return label.hasPrefix("_") ? String(label.dropFirst()) : label
        })
    }

    private func assertFieldCoverage(modelFields: Set<String>, recordFields: Set<String>,
                                     renames: [String: String] = [:], type: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let mapped = Set(modelFields.map { renames[$0] ?? $0 })
        let uncovered = mapped.subtracting(recordFields)
        let extra = recordFields.subtracting(mapped)
        #expect(uncovered.isEmpty,
               "\(type) fields with no backup counterpart: \(uncovered.sorted())", sourceLocation: sourceLocation)
        #expect(extra.isEmpty,
               "Backup fields for \(type) with no current model counterpart: \(extra.sorted())", sourceLocation: sourceLocation)
    }

    // MARK: - Field coverage

    @Test("Every Visit field has a matching VisitRecord field")
    func visitFieldsAreBackedUp() throws {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(60), latitude: 1, longitude: 2,
                          placeName: "P", inferredActivity: "A", userActivity: "B",
                          activityDefinitionID: UUID(), note: "n", source: "automatic",
                          recognitionConfidence: "high", candidateData: Data([1]),
                          mapsIdentifier: "m", placeFieldProvenance: "maps",
                          resolutionExplanation: "e", healthKitSampleIDs: [UUID()],
                          routeData: Data([2]), stableID: UUID(), resolutionState: .resolved)
        let record = LifeLogBackup.VisitRecord(arrival: base, departure: nil, latitude: 0, longitude: 0,
            placeName: "", inferredActivity: "", userActivity: nil, note: "", source: "",
            activityDefinitionID: nil, recognitionConfidence: nil, candidateData: nil,
            mapsIdentifier: nil, placeFieldProvenance: nil, resolutionExplanation: nil,
            stableID: nil, resolutionState: nil, healthKitSampleIDs: nil, routeData: nil)
        assertFieldCoverage(modelFields: storedFieldNames(visit), recordFields: storedFieldNames(record),
                           renames: ["resolutionStateRaw": "resolutionState"], type: "Visit")
    }

    @Test("Every SavedPlace field has a matching SavedPlaceRecord field")
    func savedPlaceFieldsAreBackedUp() throws {
        let place = SavedPlace(name: "N", latitude: 1, longitude: 2, radius: 50,
                               defaultActivity: "A", mapsIdentifier: "m", activityDefinitionID: UUID())
        let record = LifeLogBackup.SavedPlaceRecord(name: "", latitude: 0, longitude: 0, radius: 0,
            defaultActivity: "", mapsIdentifier: nil, activityDefinitionID: nil, role: nil)
        assertFieldCoverage(modelFields: storedFieldNames(place), recordFields: storedFieldNames(record),
                           type: "SavedPlace")
    }

    @Test("Every ActivityDefinitionRecord field has a matching backup entry field")
    func activityDefinitionRecordFieldsAreBackedUp() throws {
        let definition = ActivityDefinitionRecord(stableID: UUID(), name: "N", category: "C", symbol: "s",
                                                   colorHex: "#fff", lifeArea: "L", isActive: false,
                                                   createdAt: base, modifiedAt: base)
        let entry = LifeLogBackup.ActivityDefinitionRecordEntry(stableID: UUID(), name: "", category: "",
            symbol: "", colorHex: nil, lifeArea: "", isActive: true, createdAt: base, modifiedAt: base)
        assertFieldCoverage(modelFields: storedFieldNames(definition), recordFields: storedFieldNames(entry),
                           type: "ActivityDefinitionRecord")
    }

    @Test("Every VisitCorrection field has a matching CorrectionRecord field")
    func visitCorrectionFieldsAreBackedUp() throws {
        let correction = VisitCorrection(changedAt: base, visitArrival: base, latitude: 1, longitude: 2,
            previousPlaceName: "p", newPlaceName: "n", previousActivity: "a", newActivity: "b")
        let record = LifeLogBackup.CorrectionRecord(changedAt: base, visitArrival: base, latitude: 0, longitude: 0,
            previousPlaceName: "", newPlaceName: "", previousActivity: "", newActivity: "",
            previousConfidence: "", newConfidence: "", reason: "")
        assertFieldCoverage(modelFields: storedFieldNames(correction), recordFields: storedFieldNames(record),
                           type: "VisitCorrection")
    }

    @Test("Every DiagnosticEvent field has a matching DiagnosticRecord field")
    func diagnosticEventFieldsAreBackedUp() throws {
        let event = DiagnosticEvent(createdAt: base, subsystem: "s", severity: "warning", message: "m",
                                    category: "general", eventCode: "generic", durationMs: 1,
                                    budgetMs: 2, itemCount: 3, repairCount: 4)
        let record = LifeLogBackup.DiagnosticRecord(createdAt: base, subsystem: "", severity: "", message: "",
            category: nil, eventCode: nil, durationMs: nil, budgetMs: nil, itemCount: nil, repairCount: nil)
        assertFieldCoverage(modelFields: storedFieldNames(event), recordFields: storedFieldNames(record),
                           type: "DiagnosticEvent")
    }

    @Test("Every LocationEvent field has a matching LocationEventRecord field")
    func locationEventFieldsAreBackedUp() throws {
        let event = LocationEvent(recordedAt: base, callbackType: "c", callbackAt: base, arrival: base,
                                  departure: base, latitude: 1, longitude: 2, accuracy: 5,
                                  distanceFromCurrentVisit: 3, transition: "created", visitArrival: base)
        let record = LifeLogBackup.LocationEventRecord(recordedAt: base, callbackType: "", callbackAt: base,
            arrival: nil, departure: nil, latitude: 0, longitude: 0, accuracy: 0,
            distanceFromCurrentVisit: nil, transition: "", visitArrival: nil)
        assertFieldCoverage(modelFields: storedFieldNames(event), recordFields: storedFieldNames(record),
                           type: "LocationEvent")
    }

    // MARK: - Full round trip

    @Test("A fully-populated instance of every current @Model type round-trips field-for-field")
    func fullArchiveRoundTrips() throws {
        // Isolated storage: `makeBackup`/`restore` both touch `ActivityCatalog`'s
        // UserDefaults-backed legacy catalogue, and this must not read or leave
        // behind state in the real one shared with every other test.
        let suite = UserDefaults(suiteName: "ArchiveModelFieldCoverageTests.\(UUID().uuidString)")!
        try ActivityCatalog.withStorage(suite) { try fullArchiveRoundTripsBody() }
    }

    private func fullArchiveRoundTripsBody() throws {
        let sourceContext = try makeContext()

        let activityID = UUID()
        let inactiveButReferencedID = UUID()
        let orphanInactiveID = UUID()
        let activeDefinition = ActivityDefinitionRecord(stableID: activityID, name: "Walking", category: "Fitness",
            symbol: "figure.walk", colorHex: "#00FF00", lifeArea: "Fitness", isActive: true,
            createdAt: base, modifiedAt: base.addingTimeInterval(10))
        let referencedInactive = ActivityDefinitionRecord(stableID: inactiveButReferencedID, name: "Old Gym",
            category: "Fitness", symbol: "dumbbell.fill", colorHex: nil, lifeArea: "Fitness", isActive: false,
            createdAt: base, modifiedAt: base)
        let orphanInactive = ActivityDefinitionRecord(stableID: orphanInactiveID, name: "Never Used",
            category: "Other", symbol: "circle.fill", colorHex: nil, lifeArea: "Other", isActive: false,
            createdAt: base, modifiedAt: base)
        [activeDefinition, referencedInactive, orphanInactive].forEach(sourceContext.insert)

        let stableID = UUID()
        let sampleIDs = [UUID(), UUID()]
        let route = [RoutePoint(latitude: -27.47, longitude: 153.03, time: base)]
        let routeData = try JSONEncoder().encode(route)
        let candidateData = try JSONEncoder().encode(
            VisitCandidatePayloadEnvelope(payload: .init(suggestions: [], score: nil, resolution: nil))
        )
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(1800), latitude: -27.47, longitude: 153.03,
            placeName: "Park", inferredActivity: "Walking", userActivity: "Walking",
            activityDefinitionID: inactiveButReferencedID, note: "a note", source: "health-walking",
            recognitionConfidence: "device", candidateData: candidateData, mapsIdentifier: "maps-park",
            placeFieldProvenance: "maps", resolutionExplanation: "matched-saved-place",
            healthKitSampleIDs: sampleIDs, routeData: routeData, stableID: stableID, resolutionState: .resolved)
        sourceContext.insert(visit)

        let place = SavedPlace(name: "Home", latitude: -27.5, longitude: 153.0, radius: 75,
                               defaultActivity: "At home", mapsIdentifier: "maps-home",
                               activityDefinitionID: activityID)
        place.homeWorkRole = .home
        sourceContext.insert(place)

        let correction = VisitCorrection(changedAt: base.addingTimeInterval(3600), visitArrival: base,
            latitude: -27.47, longitude: 153.03, previousPlaceName: "Identifying…", newPlaceName: "Park",
            previousActivity: "Visiting", newActivity: "Walking", previousConfidence: "pending",
            newConfidence: "confirmed", reason: "Manual correction")
        sourceContext.insert(correction)

        let locationEvent = LocationEvent(recordedAt: base.addingTimeInterval(5), callbackType: "geofence-entry",
            callbackAt: base, arrival: base, departure: nil, latitude: -27.47, longitude: 153.03,
            accuracy: 12, distanceFromCurrentVisit: 4, transition: "created", visitArrival: base)
        sourceContext.insert(locationEvent)

        try sourceContext.save()
        let diagnostic = DiagnosticEvent(createdAt: base, subsystem: "Test", severity: "info", message: "checked",
            category: Diagnostics.Category.performance, eventCode: "generic", durationMs: 42,
            budgetMs: 100, itemCount: 7, repairCount: 2)

        let data = try LocalBackupService.makeBackup(context: sourceContext, diagnostics: [diagnostic])

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LifeLogBackup.self, from: data)
        #expect(decoded.version == 3)
        // The manifest, present unconditionally on every backup this build writes.
        let manifest = try #require(decoded.manifest)
        #expect(manifest.recordCounts.visits == 1)
        #expect(manifest.recordCounts.savedPlaces == 1)
        #expect(manifest.recordCounts.corrections == 1)
        #expect(manifest.recordCounts.diagnostics == 1)
        #expect(manifest.recordCounts.locationEvents == 1)
        // Active + referenced-inactive, but not the unreferenced-inactive orphan.
        #expect(manifest.recordCounts.activityDefinitionRecords == 2)
        #expect(manifest.payloadSizes.total > 0)
        #expect(!manifest.appVersion.isEmpty)
        #expect(!manifest.schemaVersion.isEmpty)

        let definitionEntries = try #require(decoded.activityDefinitionRecords)
        #expect(Set(definitionEntries.map(\.stableID)) == [activityID, inactiveButReferencedID])
        #expect(definitionEntries.first { $0.stableID == inactiveButReferencedID }?.isActive == false)

        let restoredContext = try makeContext()
        try LocalBackupService.restore(data, into: restoredContext)

        let restoredVisit = try #require(try restoredContext.fetch(FetchDescriptor<Visit>()).first)
        #expect(restoredVisit.arrival == visit.arrival)
        #expect(restoredVisit.departure == visit.departure)
        #expect(restoredVisit.latitude == visit.latitude)
        #expect(restoredVisit.longitude == visit.longitude)
        #expect(restoredVisit.placeName == visit.placeName)
        #expect(restoredVisit.inferredActivity == visit.inferredActivity)
        #expect(restoredVisit.userActivity == visit.userActivity)
        #expect(restoredVisit.activityDefinitionID == visit.activityDefinitionID)
        #expect(restoredVisit.note == visit.note)
        #expect(restoredVisit.source == visit.source)
        #expect(restoredVisit.recognitionConfidence == visit.recognitionConfidence)
        #expect(restoredVisit.candidateData == visit.candidateData)
        #expect(restoredVisit.mapsIdentifier == visit.mapsIdentifier)
        #expect(restoredVisit.placeFieldProvenance == visit.placeFieldProvenance)
        #expect(restoredVisit.resolutionExplanation == visit.resolutionExplanation)
        #expect(restoredVisit.healthKitSampleIDs == visit.healthKitSampleIDs)
        #expect(restoredVisit.routeData == visit.routeData)
        #expect(restoredVisit.stableID == visit.stableID)
        #expect(restoredVisit.resolutionStateRaw == visit.resolutionStateRaw)

        let restoredPlace = try #require(try restoredContext.fetch(FetchDescriptor<SavedPlace>()).first)
        #expect(restoredPlace.name == place.name)
        #expect(restoredPlace.latitude == place.latitude)
        #expect(restoredPlace.longitude == place.longitude)
        #expect(restoredPlace.radius == place.radius)
        #expect(restoredPlace.defaultActivity == place.defaultActivity)
        #expect(restoredPlace.activityDefinitionID == place.activityDefinitionID)
        #expect(restoredPlace.mapsIdentifier == place.mapsIdentifier)
        #expect(restoredPlace.role == place.role)

        let restoredCorrection = try #require(try restoredContext.fetch(FetchDescriptor<VisitCorrection>()).first)
        #expect(restoredCorrection.changedAt == correction.changedAt)
        #expect(restoredCorrection.visitArrival == correction.visitArrival)
        #expect(restoredCorrection.latitude == correction.latitude)
        #expect(restoredCorrection.longitude == correction.longitude)
        #expect(restoredCorrection.previousPlaceName == correction.previousPlaceName)
        #expect(restoredCorrection.newPlaceName == correction.newPlaceName)
        #expect(restoredCorrection.previousActivity == correction.previousActivity)
        #expect(restoredCorrection.newActivity == correction.newActivity)
        #expect(restoredCorrection.previousConfidence == correction.previousConfidence)
        #expect(restoredCorrection.newConfidence == correction.newConfidence)
        #expect(restoredCorrection.reason == correction.reason)

        let restoredEvent = try #require(try restoredContext.fetch(FetchDescriptor<LocationEvent>()).first)
        #expect(restoredEvent.recordedAt == locationEvent.recordedAt)
        #expect(restoredEvent.callbackType == locationEvent.callbackType)
        #expect(restoredEvent.callbackAt == locationEvent.callbackAt)
        #expect(restoredEvent.arrival == locationEvent.arrival)
        #expect(restoredEvent.departure == locationEvent.departure)
        #expect(restoredEvent.latitude == locationEvent.latitude)
        #expect(restoredEvent.longitude == locationEvent.longitude)
        #expect(restoredEvent.accuracy == locationEvent.accuracy)
        #expect(restoredEvent.distanceFromCurrentVisit == locationEvent.distanceFromCurrentVisit)
        #expect(restoredEvent.transition == locationEvent.transition)
        #expect(restoredEvent.visitArrival == locationEvent.visitArrival)

        let restoredDefinitions = try restoredContext.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        let restoredActive = try #require(restoredDefinitions.first { $0.stableID == activityID })
        #expect(restoredActive.name == activeDefinition.name)
        #expect(restoredActive.category == activeDefinition.category)
        #expect(restoredActive.symbol == activeDefinition.symbol)
        #expect(restoredActive.colorHex == activeDefinition.colorHex)
        #expect(restoredActive.lifeArea == activeDefinition.lifeArea)
        #expect(restoredActive.isActive == activeDefinition.isActive)
        #expect(restoredActive.createdAt == activeDefinition.createdAt)
        #expect(restoredActive.modifiedAt == activeDefinition.modifiedAt)

        // The load-bearing assertion: a deactivated-but-referenced definition
        // stays deactivated after restore, rather than the pre-V3 behaviour of
        // `adoptLegacyDefinitions` always recreating an adopted row as active.
        let restoredInactive = try #require(restoredDefinitions.first { $0.stableID == inactiveButReferencedID })
        #expect(restoredInactive.isActive == false)
        #expect(restoredInactive.name == referencedInactive.name)

        // The unreferenced, inactive orphan was correctly left out of the
        // backup in the first place, so it does not come back at all.
        #expect(!restoredDefinitions.contains { $0.stableID == orphanInactiveID })
    }
}
