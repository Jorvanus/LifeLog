import Foundation
import SwiftData

struct LifeLogBackup: Codable {
    /// V3 added durable `ActivityDefinitionRecord` rows and a manifest; both stay
    /// optional so the immediately previous V3 JSON decodes. V4 makes those durable
    /// rows the only activity payload written by new backups, including aliases.
    ///
    /// `activityDefinitions` remains required for V3 decoding, but V4 writes it
    /// empty. Its former aliases are now `ActivityDefinitionRecordEntry.legacyNames`.
    static let currentVersion = 4
    let version: Int
    let createdAt: Date
    let visits: [VisitRecord]
    let savedPlaces: [SavedPlaceRecord]
    let corrections: [CorrectionRecord]
    let diagnostics: [DiagnosticRecord]
    /// Optional to preserve the immediately previous V3 document shape. It
    /// intentionally carries coordinates: the local backup already carries the
    /// timeline's coordinates, and this is the evidence needed to explain how
    /// those visits were created.
    let locationEvents: [LocationEventRecord]?
    /// Retained in V3/V4 for a stable document shape. New backups write it empty:
    /// every visit's own `resolutionState` carries `.ignored` keyed by its
    /// `stableID`, unlike a key built from a row identity SwiftData reassigns on
    /// every restore.
    let ignoredVisitKeys: [String]
    let activityDefinitions: [ActivityDefinition]
    /// Field-for-field snapshot of every `ActivityDefinitionRecord` the
    /// catalogue is currently active, plus any inactive one a historical
    /// `Visit` or `SavedPlace` still references — see `encodeBackup` for the
    /// exact filter. Optional only because V3 did not include aliases; V3 still
    /// carries durable record rows, while V4 writes aliases alongside them.
    let activityDefinitionRecords: [ActivityDefinitionRecordEntry]?
    let preferences: [String: String]
    /// Descriptive only — nothing in `restore` reads it — so a person
    /// inspecting a `.json` backup by hand, or a future diagnostic, can see
    /// what produced it without decoding every array and counting.
    let manifest: Manifest?

    /// Field-for-field snapshot of one `ActivityDefinitionRecord` row. See
    /// `LifeLog/Model/Models.swift`'s `ActivityDefinitionRecord` for the
    /// authoritative property list this must keep matching —
    /// `ArchiveModelFieldCoverageTests` fails if the two drift apart.
    struct ActivityDefinitionRecordEntry: Codable {
        let stableID: UUID
        let name: String
        let category: String
        let symbol: String
        let colorHex: String?
        // V3 backups may omit this field; keep the decode default while allowing
        // the explicit encoder initializer to supply aliases for V4 records.
        var legacyNames: [String]? = nil
        let lifeArea: String
        let isActive: Bool
        let createdAt: Date
        let modifiedAt: Date

        init(stableID: UUID, name: String, category: String, symbol: String,
             colorHex: String?, legacyNames: [String]? = nil, lifeArea: String,
             isActive: Bool, createdAt: Date, modifiedAt: Date) {
            self.stableID = stableID
            self.name = name
            self.category = category
            self.symbol = symbol
            self.colorHex = colorHex
            self.legacyNames = legacyNames
            self.lifeArea = lifeArea
            self.isActive = isActive
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }
    }

    /// What produced this backup, and how big it is. Every count and size is
    /// computed once at encode time from the exact arrays this document
    /// carries, so it can never drift from them the way a hand-maintained
    /// summary could.
    struct Manifest: Codable {
        let appVersion: String
        let schemaVersion: String
        let recordCounts: RecordCounts
        /// Byte size of each section's own JSON encoding, plus their sum —
        /// not the whole file's byte count, which also includes this manifest and
        /// portable preferences.
        let payloadSizes: PayloadSizes

        struct RecordCounts: Codable {
            let visits: Int
            let savedPlaces: Int
            let corrections: Int
            let diagnostics: Int
            let locationEvents: Int
            let activityDefinitionRecords: Int
        }
        struct PayloadSizes: Codable {
            let visits: Int
            let savedPlaces: Int
            let corrections: Int
            let diagnostics: Int
            let locationEvents: Int
            let activityDefinitionRecords: Int
            let total: Int
        }
    }

    struct VisitRecord: Codable {
        let arrival: Date; let departure: Date?; let latitude: Double; let longitude: Double
        let placeName: String; let inferredActivity: String
        let userActivity: String?; let note: String; let source: String
        /// Optional because V3's visit snapshot can predate activity linking.
        let activityDefinitionID: UUID?
        let recognitionConfidence: String?; let candidateData: Data?
        /// Optional when a V3 visit had no Maps identity.
        let mapsIdentifier: String?; let placeFieldProvenance: String?
        /// Optional so the previous backup format restores without manufacturing an answer.
        let resolutionExplanation: String?
        /// Optional where the previous format has no durable identity. Present,
        /// these round-trip a visit's durable identity and resolution state exactly
        /// — including `.ignored` — instead of leaving `Visit.init` to regenerate a
        /// fresh identity and re-derive a state with no ignore of its own to go on.
        let stableID: UUID?
        let resolutionState: String?
        /// Optional so V3 records with neither field remain an honest absence.
        let healthKitSampleIDs: [UUID]?
        let routeData: Data?
    }
    // `placeCategory`/`category` were dropped when LifeLog stopped modelling a
    // place type. The supported V3/V4 documents have no such keys; unknown JSON
    // keys remain ignored by Codable as a normal forward-compatibility safeguard.
    struct SavedPlaceRecord: Codable {
        let name: String; let latitude: Double; let longitude: Double; let radius: Double
        let defaultActivity: String; let mapsIdentifier: String?
        let activityDefinitionID: UUID?
        /// Optional where a V3 Saved Place had no explicit Home/Work role.
        let role: String?
    }
    struct CorrectionRecord: Codable { let changedAt: Date; let visitArrival: Date; let latitude: Double; let longitude: Double; let previousPlaceName: String; let newPlaceName: String; let previousActivity: String; let newActivity: String; let previousConfidence: String; let newConfidence: String; let reason: String }
    struct DiagnosticRecord: Codable {
        let createdAt: Date; let subsystem: String; let severity: String; let message: String
        /// Optional where a V3 diagnostic has no explicit category; it restores as
        /// `.general`, the model's ordinary default.
        let category: String?
        /// Optional where the previous format has an untyped diagnostic. It remains
        /// readable through `message` without inventing typed values.
        let eventCode: String?
        let durationMs: Int?
        let budgetMs: Int?
        let itemCount: Int?
        let repairCount: Int?
    }
    struct LocationEventRecord: Codable {
        let recordedAt: Date; let callbackType: String; let callbackAt: Date
        let arrival: Date?; let departure: Date?; let latitude: Double; let longitude: Double
        let accuracy: Double; let distanceFromCurrentVisit: Double?; let transition: String
        let visitArrival: Date?
    }
}

/// The exact five model groups Restore requires to be empty. Settings fetches
/// these counts on demand through `BackupExportActor`; it must not observe the
/// full archive merely to decide whether Restore can be offered.
struct BackupDestinationState: Equatable, Sendable {
    let visits: Int
    let savedPlaces: Int
    let corrections: Int
    let diagnostics: Int
    let locationEvents: Int

    static let empty = Self(visits: 0, savedPlaces: 0, corrections: 0, diagnostics: 0, locationEvents: 0)

    var recordCount: Int { visits + savedPlaces + corrections + diagnostics + locationEvents }
    var isEmpty: Bool { recordCount == 0 }
}

/// Every way a backup can describe an impossible store. Checked in full before a
/// single row is inserted — see `LifeLogBackup.validate()` — so a truncated or
/// hand-edited archive fails all at once rather than leaving the destination
/// store partially restored.
enum BackupValidationError: LocalizedError {
    case duplicateStableID(UUID)
    case negativeDuration(arrival: Date)
    case invalidCoordinate(latitude: Double, longitude: Double)
    case malformedRoute(arrival: Date)
    case oversizedPayload(arrival: Date)
    case invalidResolutionState(String)
    case invalidSavedPlaceRole(String)
    case duplicateSavedPlaceIdentifier(String)
    case duplicateHealthKitSample(UUID)
    case invalidLocationEvent(reason: String)
    case invalidCorrection(reason: String)
    case duplicateActivityDefinitionID(UUID)

    var errorDescription: String? {
        switch self {
        case .duplicateStableID(let id): "Two visits share the same identity (\(id))."
        case .negativeDuration(let arrival): "The visit arriving \(arrival) has a departure before its arrival."
        case .invalidCoordinate(let latitude, let longitude): "A record has an invalid coordinate (\(latitude), \(longitude))."
        case .malformedRoute(let arrival): "The route recorded for the visit arriving \(arrival) could not be decoded."
        case .oversizedPayload(let arrival): "The payload recorded for the visit arriving \(arrival) exceeds LifeLog's safe storage limit."
        case .invalidResolutionState(let raw): "Unknown visit resolution state \"\(raw)\"."
        case .invalidSavedPlaceRole(let raw): "Unknown Saved Place role \"\(raw)\"."
        case .duplicateSavedPlaceIdentifier(let identifier): "Two Saved Places share Maps identifier \(identifier)."
        case .duplicateHealthKitSample(let id): "The HealthKit sample \(id) is attached to more than one visit."
        case .invalidLocationEvent(let reason): "A location callback record is invalid: \(reason)."
        case .invalidCorrection(let reason): "A correction record is invalid: \(reason)."
        case .duplicateActivityDefinitionID(let id): "Two activity definitions share the same identity (\(id))."
        }
    }
}

/// Failures that stop a restore before the archive's own content is even
/// considered — distinct from `BackupValidationError`, which describes an
/// impossible archive, not an unsuitable destination.
enum RestoreError: LocalizedError {
    /// `LocalBackupService.restore` never merges into existing history: the
    /// destination must be empty of everything it repopulates (Visit,
    /// SavedPlace, VisitCorrection, DiagnosticEvent, LocationEvent) before it
    /// will insert a single row. Without this guard, restoring into a store
    /// that already has data silently duplicated every one of those records
    /// instead of the "complete replacement" Settings promises.
    case destinationNotEmpty

    var errorDescription: String? {
        switch self {
        case .destinationNotEmpty:
            "Restore requires an empty store. Use \"Erase all data\" in Settings first, then restore."
        }
    }
}

extension LifeLogBackup {
    /// Every invariant the app itself enforces on this data, checked up front. A
    /// backup that decodes cleanly can still describe a store no code path here
    /// would ever produce — two visits claiming one HealthKit sample, a departure
    /// before its own arrival — and restoring one anyway would corrupt the
    /// destination rather than merely fail to import it.
    func validate() throws {
        var stableIDs = Set<UUID>()
        var healthKitSampleIDs = Set<UUID>()
        for visit in visits {
            if let departure = visit.departure, departure < visit.arrival {
                throw BackupValidationError.negativeDuration(arrival: visit.arrival)
            }
            guard (-90...90).contains(visit.latitude), (-180...180).contains(visit.longitude) else {
                throw BackupValidationError.invalidCoordinate(latitude: visit.latitude, longitude: visit.longitude)
            }
            if let stableID = visit.stableID, !stableIDs.insert(stableID).inserted {
                throw BackupValidationError.duplicateStableID(stableID)
            }
            if let raw = visit.resolutionState, VisitResolutionState(rawValue: raw) == nil {
                throw BackupValidationError.invalidResolutionState(raw)
            }
            // A malformed or future payload remains part of a backup. It is raw
            // evidence a newer build or repair tool may understand; rejecting it
            // here would force a person to choose between restoring the archive
            // and preserving that evidence. Size is the one safety boundary.
            if VisitPayloadDecoder.exceedsSafeStorageLimit(candidateData: visit.candidateData,
                                                            routeData: visit.routeData) {
                throw BackupValidationError.oversizedPayload(arrival: visit.arrival)
            }
            for sampleID in visit.healthKitSampleIDs ?? [] where !healthKitSampleIDs.insert(sampleID).inserted {
                throw BackupValidationError.duplicateHealthKitSample(sampleID)
            }
        }
        var mapsIdentifiers = Set<String>()
        for place in savedPlaces {
            if let role = place.role, SavedPlaceRole(rawValue: role) == nil {
                throw BackupValidationError.invalidSavedPlaceRole(role)
            }
            if let identifier = place.mapsIdentifier, !mapsIdentifiers.insert(identifier).inserted {
                throw BackupValidationError.duplicateSavedPlaceIdentifier(identifier)
            }
        }
        for event in locationEvents ?? [] {
            // Negative accuracy is not corrupt data -- it is CoreLocation's own
            // convention for "unavailable", and `LocationJournal.record`'s default
            // parameter (-1) uses it for exactly that: a geofence exit only ever
            // carries a bare coordinate, never a `CLLocation` with a real accuracy
            // reading, so every geofence-exit event legitimately has none. Rejecting
            // the whole restore over this would mean no backup with a geofence exit
            // in it could ever be restored.
            if let arrival = event.arrival, let departure = event.departure, departure < arrival {
                throw BackupValidationError.invalidLocationEvent(reason: "departure before arrival")
            }
        }
        for correction in corrections where correction.changedAt < correction.visitArrival {
            throw BackupValidationError.invalidCorrection(reason: "recorded before the visit it corrects")
        }
        var activityDefinitionIDs = Set<UUID>()
        for definition in activityDefinitionRecords ?? [] where !activityDefinitionIDs.insert(definition.stableID).inserted {
            throw BackupValidationError.duplicateActivityDefinitionID(definition.stableID)
        }
    }
}

enum LocalBackupService {
    /// UserDefaults keys that describe this device or this device's own
    /// HealthKit/store session rather than app state a restore should carry
    /// across. Restoring a Wi-Fi anchor or a HealthKit anchored-query cursor
    /// from another device (or an old snapshot of this one) would make the
    /// geofence and HealthKit importers reason about a session that never
    /// happened here, so these never enter or leave `preferences`.
    private static let excludedPreferencePrefixes = [
        "LifeLog.WiFiAnchor.", "LifeLog.HealthKit.sleepAnchor", "LifeLog.HealthKit.workoutAnchor",
        "LifeLog.HardwareValidation.",
        // Superseded by each visit's own `resolutionState`; see `ignoredVisitKeys`.
        "LifeLog.IgnoredLocations.v1",
    ]
    private static func isPortablePreferenceKey(_ key: String) -> Bool {
        key.hasPrefix("LifeLog.") && !excludedPreferencePrefixes.contains { key.hasPrefix($0) }
    }

    static func makeBackup(context: ModelContext, diagnostics: [DiagnosticEvent]) throws -> Data {
        if UITestFailureInjection.shouldFailBackup {
            throw CocoaError(.fileWriteUnknown)
        }
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        let locationEvents = try context.fetch(FetchDescriptor<LocationEvent>())
        let activityDefinitionRecords = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        return try encodeBackup(visits: visits, places: places, corrections: corrections,
                                diagnostics: diagnostics, locationEvents: locationEvents,
                                activityDefinitionRecords: activityDefinitionRecords)
    }

    /// The app's own version, matching `SettingsView.appVersion`'s format —
    /// duplicated rather than shared because that one is a `View` property and
    /// this runs off the main actor inside `BackupExportActor`.
    private static func appVersionString() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// A definition belongs in the backup if it is still offered (`isActive`) or
    /// if a `Visit` or `SavedPlace` in this same backup still points at it by
    /// `stableID` — an inactive, unreferenced definition is dead weight nothing
    /// will ever resolve again. Keeping a referenced-but-inactive one is what
    /// lets a deleted activity's historical visits keep a resolvable identity
    /// after a restore, instead of the identity simply vanishing.
    private static func definitionsToBackUp(_ definitions: [ActivityDefinitionRecord],
                                             visits: [Visit], places: [SavedPlace]) -> [ActivityDefinitionRecord] {
        let referenced = Set(visits.compactMap(\.activityDefinitionID)) .union(places.compactMap(\.activityDefinitionID))
        return definitions.filter { $0.isActive || referenced.contains($0.stableID) }
    }

    /// Encoding is shared with `BackupExportActor`; the actor owns the archive
    /// read, while this pure transformation preserves the tested backup format.
    static func encodeBackup(visits: [Visit], places: [SavedPlace], corrections: [VisitCorrection],
                             diagnostics: [DiagnosticEvent], locationEvents: [LocationEvent],
                             activityDefinitionRecords: [ActivityDefinitionRecord]) throws -> Data {
        let sizingEncoder = JSONEncoder(); sizingEncoder.dateEncodingStrategy = .iso8601
        func size<T: Encodable>(_ value: T) -> Int { (try? sizingEncoder.encode(value))?.count ?? 0 }

        let visitRecords = visits.map { LifeLogBackup.VisitRecord(arrival: $0.arrival, departure: $0.departure, latitude: $0.latitude, longitude: $0.longitude, placeName: $0.placeName, inferredActivity: $0.inferredActivity, userActivity: $0.userActivity, note: $0.note, source: $0.source, activityDefinitionID: $0.activityDefinitionID, recognitionConfidence: $0.recognitionConfidence, candidateData: $0.candidateData, mapsIdentifier: $0.mapsIdentifier, placeFieldProvenance: $0.placeFieldProvenance, resolutionExplanation: $0.resolutionExplanation, stableID: $0.stableID, resolutionState: $0.resolutionStateRaw, healthKitSampleIDs: $0.healthKitSampleIDs, routeData: $0.routeData) }
        let savedPlaceRecords = places.map { LifeLogBackup.SavedPlaceRecord(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius, defaultActivity: $0.defaultActivity, mapsIdentifier: $0.mapsIdentifier, activityDefinitionID: $0.activityDefinitionID, role: $0.role) }
        let correctionRecords = corrections.map { LifeLogBackup.CorrectionRecord(changedAt: $0.changedAt, visitArrival: $0.visitArrival, latitude: $0.latitude, longitude: $0.longitude, previousPlaceName: $0.previousPlaceName, newPlaceName: $0.newPlaceName, previousActivity: $0.previousActivity, newActivity: $0.newActivity, previousConfidence: $0.previousConfidence, newConfidence: $0.newConfidence, reason: $0.reason) }
        let diagnosticRecords = diagnostics.map { LifeLogBackup.DiagnosticRecord(createdAt: $0.createdAt, subsystem: $0.subsystem, severity: $0.severity, message: $0.message, category: $0.category, eventCode: $0.eventCode, durationMs: $0.durationMs, budgetMs: $0.budgetMs, itemCount: $0.itemCount, repairCount: $0.repairCount) }
        let locationEventRecords = locationEvents.map { LifeLogBackup.LocationEventRecord(recordedAt: $0.recordedAt, callbackType: $0.callbackType,
                callbackAt: $0.callbackAt, arrival: $0.arrival, departure: $0.departure,
                latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.accuracy,
                distanceFromCurrentVisit: $0.distanceFromCurrentVisit, transition: $0.transition,
                visitArrival: $0.visitArrival) }
        let definitionRecords = definitionsToBackUp(activityDefinitionRecords, visits: visits, places: places)
            .map { LifeLogBackup.ActivityDefinitionRecordEntry(stableID: $0.stableID, name: $0.name, category: $0.category, symbol: $0.symbol, colorHex: $0.colorHex, legacyNames: $0.legacyNames, lifeArea: $0.lifeArea, isActive: $0.isActive, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt) }

        let payloadSizes = LifeLogBackup.Manifest.PayloadSizes(
            visits: size(visitRecords), savedPlaces: size(savedPlaceRecords), corrections: size(correctionRecords),
            diagnostics: size(diagnosticRecords), locationEvents: size(locationEventRecords),
            activityDefinitionRecords: size(definitionRecords),
            total: size(visitRecords) + size(savedPlaceRecords) + size(correctionRecords)
                + size(diagnosticRecords) + size(locationEventRecords) + size(definitionRecords)
        )
        let manifest = LifeLogBackup.Manifest(
            appVersion: appVersionString(),
            schemaVersion: "\(LifeLogMigrationPlan.schemas.last!.versionIdentifier)",
            recordCounts: .init(visits: visitRecords.count, savedPlaces: savedPlaceRecords.count,
                                corrections: correctionRecords.count, diagnostics: diagnosticRecords.count,
                                locationEvents: locationEventRecords.count, activityDefinitionRecords: definitionRecords.count),
            payloadSizes: payloadSizes
        )

        let document = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: visitRecords, savedPlaces: savedPlaceRecords, corrections: correctionRecords,
            diagnostics: diagnosticRecords, locationEvents: locationEventRecords,
            ignoredVisitKeys: [], activityDefinitions: [],
            activityDefinitionRecords: definitionRecords, preferences: preferences(), manifest: manifest)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Decodes and validates the whole archive, requires an empty destination,
    /// then restores it in one pass. Every insert -- visits, places,
    /// corrections, diagnostics, location events, and activity definition records
    /// stays unsaved until the single commit inside `VisitMutationService.finalize`,
    /// which also runs the mandatory full-store audit before that commit. There
    /// is no earlier `context.save()` to leave standing: a decode, validation,
    /// non-empty-destination, insert, activity-identity, or audit/resolver
    /// failure at any point rolls back everything staged in this call, and
    /// UserDefaults (`IgnoredLocations`, the legacy `ActivityCatalog` snapshot,
    /// and portable preferences) is only ever written after that commit is
    /// confirmed, so a caller never sees a store or a preference set left
    /// half-restored.
    @MainActor
    static func restore(_ data: Data, into context: ModelContext) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup: LifeLogBackup
        do {
            backup = try decoder.decode(LifeLogBackup.self, from: data)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The owner updates LifeLog with each release, so imports intentionally
        // accept only the immediately previous document format and the current one.
        // This keeps restore semantics small, tested, and aligned with the one-step
        // on-device schema migration policy.
        guard ((LifeLogBackup.currentVersion - 1)...LifeLogBackup.currentVersion).contains(backup.version) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try backup.validate()
        guard let definitions = backup.activityDefinitionRecords else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // A restore is a complete replacement, never a merge: appending into an
        // existing store would silently duplicate every visit, place,
        // correction, diagnostic, and location callback already there. This
        // checks exactly the model types `eraseAllData` (Settings) wipes and
        // `restore` repopulates. `ActivityDefinitionRecord` is deliberately not a
        // blocker: a fresh install seeds it before any restore runs, and the restore
        // replaces that small catalogue transactionally with the backup's records.
        guard try context.fetchCount(FetchDescriptor<Visit>()) == 0,
              try context.fetchCount(FetchDescriptor<SavedPlace>()) == 0,
              try context.fetchCount(FetchDescriptor<VisitCorrection>()) == 0,
              try context.fetchCount(FetchDescriptor<DiagnosticEvent>()) == 0,
              try context.fetchCount(FetchDescriptor<LocationEvent>()) == 0 else {
            throw RestoreError.destinationNotEmpty
        }

        do {
            for record in backup.visits {
                let visit = Visit(arrival: record.arrival, departure: record.departure, latitude: record.latitude, longitude: record.longitude, placeName: record.placeName, inferredActivity: record.inferredActivity, userActivity: record.userActivity, activityDefinitionID: record.activityDefinitionID, note: record.note, source: record.source, recognitionConfidence: record.recognitionConfidence, candidateData: record.candidateData, mapsIdentifier: record.mapsIdentifier, placeFieldProvenance: record.placeFieldProvenance, resolutionExplanation: record.resolutionExplanation,
                    healthKitSampleIDs: record.healthKitSampleIDs, routeData: record.routeData,
                    stableID: record.stableID ?? UUID(),
                    resolutionState: record.resolutionState.flatMap(VisitResolutionState.init(rawValue:)))
                context.insert(visit)
                visit.stageUnreadablePayloadDiagnostics(in: context)
            }
            for record in backup.savedPlaces {
                let place = SavedPlace(name: record.name, latitude: record.latitude, longitude: record.longitude, radius: record.radius, defaultActivity: record.defaultActivity, mapsIdentifier: record.mapsIdentifier, activityDefinitionID: record.activityDefinitionID)
                place.role = record.role
                context.insert(place)
            }
            for record in backup.corrections { context.insert(VisitCorrection(changedAt: record.changedAt, visitArrival: record.visitArrival, latitude: record.latitude, longitude: record.longitude, previousPlaceName: record.previousPlaceName, newPlaceName: record.newPlaceName, previousActivity: record.previousActivity, newActivity: record.newActivity, previousConfidence: record.previousConfidence, newConfidence: record.newConfidence, reason: record.reason)) }
            for record in backup.diagnostics {
                context.insert(DiagnosticEvent(createdAt: record.createdAt, subsystem: record.subsystem, severity: record.severity,
                                               message: record.message, category: record.category ?? Diagnostics.Category.general,
                                               eventCode: record.eventCode ?? DiagnosticEventCode.legacyMessage.rawValue,
                                               durationMs: record.durationMs, budgetMs: record.budgetMs,
                                               itemCount: record.itemCount, repairCount: record.repairCount))
            }
            for record in backup.locationEvents ?? [] {
                context.insert(LocationEvent(recordedAt: record.recordedAt, callbackType: record.callbackType,
                                             callbackAt: record.callbackAt, arrival: record.arrival,
                                             departure: record.departure, latitude: record.latitude,
                                             longitude: record.longitude, accuracy: record.accuracy,
                                             distanceFromCurrentVisit: record.distanceFromCurrentVisit,
                                             transition: record.transition, visitArrival: record.visitArrival))
            }
            // A restore replaces the catalogue as well as the visible archive. A
            // fresh destination may already contain first-launch definitions; keeping
            // those alongside the backup would leave duplicate labels and make the
            // restored active/inactive state non-deterministic. Match by stable ID to
            // update a same-device restore in place, insert genuinely new rows, then
            // remove destination-only definitions before the shared commit below.
            let existing = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.stableID, $0) })
            let restoredIDs = Set(definitions.map(\.stableID))
            for record in definitions {
                if let definition = byID[record.stableID] {
                    definition.name = record.name
                    definition.category = record.category
                    definition.symbol = record.symbol
                    definition.colorHex = record.colorHex
                    definition.legacyNames = record.legacyNames ?? []
                    definition.lifeArea = record.lifeArea
                    definition.isActive = record.isActive
                    definition.createdAt = record.createdAt
                    definition.modifiedAt = record.modifiedAt
                } else {
                    context.insert(ActivityDefinitionRecord(
                        stableID: record.stableID, name: record.name, category: record.category,
                        symbol: record.symbol, colorHex: record.colorHex,
                        legacyNames: record.legacyNames ?? [], lifeArea: record.lifeArea,
                        isActive: record.isActive, createdAt: record.createdAt, modifiedAt: record.modifiedAt
                    ))
                }
            }
            for definition in existing where !restoredIDs.contains(definition.stableID) {
                context.delete(definition)
            }
            // V3 stored aliases in its retired display snapshot. Keep those aliases
            // additively without allowing its older snapshot to override a durable
            // name, category, or active state.
            if backup.version == LifeLogBackup.currentVersion - 1 {
                let records = try context.fetch(FetchDescriptor<ActivityDefinitionRecord>())
                for legacy in backup.activityDefinitions {
                    guard let record = records.first(where: { $0.stableID == legacy.id }) else { continue }
                    for alias in legacy.legacyNames where
                        alias.caseInsensitiveCompare(record.name) != .orderedSame &&
                        !record.legacyNames.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                        record.legacyNames.append(alias)
                    }
                }
            }
        } catch {
            context.rollback()
            throw error
        }

        // Nothing inserted above has been saved yet, so the full-store audit
        // this runs -- and the one `context.save()` inside it -- is the single
        // commit point for the entire restore. A resolver or save failure here
        // rolls back every insert staged above along with it; there is no
        // earlier commit left partially standing.
        let mutation = VisitMutationService.finalize(
            context: context,
            kind: .backupRestore,
            change: .init(changedCount: backup.visits.count)
        )
        guard mutation.committed else {
            throw BackupValidationError.invalidCorrection(
                reason: mutation.failureDescription ?? "Restored history could not be resolved."
            )
        }

        // Only now that the store is durably committed do preferences get written. UserDefaults has no
        // transaction of its own to roll back, so these must wait until the
        // one thing that could still fail is already known to have succeeded --
        // otherwise a resolver failure above would leave preferences restored
        // against a store that never actually committed.
        IgnoredLocations.importKeys(backup.ignoredVisitKeys)
        try? ActivityCatalog.refresh(context: context)
        for (key, value) in backup.preferences where isPortablePreferenceKey(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
        MaintenanceCoordinator.shared.runAfterRestore(context: context)
    }

    static func preferences() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation().compactMapValues { value in
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
            return nil
        }.filter { isPortablePreferenceKey($0.key) }
    }
}

/// Backup is intentionally archive-wide, but Settings must remain usable while it
/// is read and encoded. The actor returns only the finished `Data` share payload.
@ModelActor
actor BackupExportActor {
    func restoreDestinationState() throws -> BackupDestinationState {
        try .init(
            visits: modelContext.fetchCount(FetchDescriptor<Visit>()),
            savedPlaces: modelContext.fetchCount(FetchDescriptor<SavedPlace>()),
            corrections: modelContext.fetchCount(FetchDescriptor<VisitCorrection>()),
            diagnostics: modelContext.fetchCount(FetchDescriptor<DiagnosticEvent>()),
            locationEvents: modelContext.fetchCount(FetchDescriptor<LocationEvent>())
        )
    }

    func makeBackup() throws -> Data {
        try Task.checkCancellation()
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        try Task.checkCancellation()
        let places = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        let corrections = try modelContext.fetch(FetchDescriptor<VisitCorrection>())
        let diagnostics = try modelContext.fetch(FetchDescriptor<DiagnosticEvent>())
        let locationEvents = try modelContext.fetch(FetchDescriptor<LocationEvent>())
        let activityDefinitionRecords = try modelContext.fetch(FetchDescriptor<ActivityDefinitionRecord>())
        try Task.checkCancellation()
        return try LocalBackupService.encodeBackup(
            visits: visits, places: places, corrections: corrections,
            diagnostics: diagnostics, locationEvents: locationEvents,
            activityDefinitionRecords: activityDefinitionRecords
        )
    }
}
