import Foundation
import SwiftData

struct LifeLogBackup: Codable {
    /// V2 adds a visit's route and HealthKit sample identity, a Saved Place's
    /// Home/Work role, and a diagnostic's retention category. Every V2 addition
    /// is an optional field, so a V1 archive — which simply has no key for it —
    /// still decodes without a custom `init(from:)`.
    static let currentVersion = 2
    let version: Int
    let createdAt: Date
    let visits: [VisitRecord]
    let savedPlaces: [SavedPlaceRecord]
    let corrections: [CorrectionRecord]
    let diagnostics: [DiagnosticRecord]
    /// Optional so backups made before the detailed callback journal existed still
    /// restore cleanly. It intentionally carries coordinates: the local backup
    /// already carries the timeline's coordinates, and this is the evidence needed
    /// to explain how those visits were created.
    let locationEvents: [LocationEventRecord]?
    /// Retained only so a V1 backup's legacy persistentModelID-text keys still
    /// decode and can still be converted by `VisitResolutionMigration` on the
    /// next store open. A V2 backup writes this empty: every visit's own
    /// `resolutionState` already carries `.ignored` keyed by its `stableID`,
    /// which is the durable identity a restore round-trips, unlike a key built
    /// from a row identity SwiftData reassigns on every restore.
    let ignoredVisitKeys: [String]
    let activityDefinitions: [ActivityDefinition]
    let preferences: [String: String]

    struct VisitRecord: Codable {
        let arrival: Date; let departure: Date?; let latitude: Double; let longitude: Double
        let placeName: String; let inferredActivity: String
        let userActivity: String?; let note: String; let source: String
        let recognitionConfidence: String?; let candidateData: Data?
        /// Optional so V1 backups remain valid after visits gained Maps identity.
        let mapsIdentifier: String?; let placeFieldProvenance: String?
        /// Optional so older local backups restore without manufacturing an answer.
        let resolutionExplanation: String?
        /// Optional so backups made before the V9 migration still restore. Present,
        /// these round-trip a visit's durable identity and resolution state exactly
        /// — including `.ignored` — instead of leaving `Visit.init` to regenerate a
        /// fresh identity and re-derive a state with no ignore of its own to go on.
        let stableID: UUID?
        let resolutionState: String?
        /// V2. Optional so a V1 backup — recorded before either field existed —
        /// still decodes; a restored visit simply has no route or HealthKit
        /// identity, exactly as it had none when that backup was made.
        let healthKitSampleIDs: [UUID]?
        let routeData: Data?
    }
    // `placeCategory`/`category` were dropped when LifeLog stopped modelling a
    // place type. Older backups still restore: JSON keys with no matching
    // property are ignored on decode, so the format version is unchanged.
    struct SavedPlaceRecord: Codable {
        let name: String; let latitude: Double; let longitude: Double; let radius: Double
        let defaultActivity: String; let mapsIdentifier: String?
        /// V2. Optional so a V1 backup, recorded before Home/Work roles existed,
        /// still decodes.
        let role: String?
    }
    struct CorrectionRecord: Codable { let changedAt: Date; let visitArrival: Date; let latitude: Double; let longitude: Double; let previousPlaceName: String; let newPlaceName: String; let previousActivity: String; let newActivity: String; let previousConfidence: String; let newConfidence: String; let reason: String }
    struct DiagnosticRecord: Codable {
        let createdAt: Date; let subsystem: String; let severity: String; let message: String
        /// V2. Optional so a V1 backup still decodes; restored as `.general` to
        /// match what a pre-category row already defaults to on this model.
        let category: String?
    }
    struct LocationEventRecord: Codable {
        let recordedAt: Date; let callbackType: String; let callbackAt: Date
        let arrival: Date?; let departure: Date?; let latitude: Double; let longitude: Double
        let accuracy: Double; let distanceFromCurrentVisit: Double?; let transition: String
        let visitArrival: Date?
    }
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
    case invalidResolutionState(String)
    case invalidSavedPlaceRole(String)
    case duplicateSavedPlaceIdentifier(String)
    case duplicateHealthKitSample(UUID)
    case invalidLocationEvent(reason: String)
    case invalidCorrection(reason: String)

    var errorDescription: String? {
        switch self {
        case .duplicateStableID(let id): "Two visits share the same identity (\(id))."
        case .negativeDuration(let arrival): "The visit arriving \(arrival) has a departure before its arrival."
        case .invalidCoordinate(let latitude, let longitude): "A record has an invalid coordinate (\(latitude), \(longitude))."
        case .malformedRoute(let arrival): "The route recorded for the visit arriving \(arrival) could not be decoded."
        case .invalidResolutionState(let raw): "Unknown visit resolution state \"\(raw)\"."
        case .invalidSavedPlaceRole(let raw): "Unknown Saved Place role \"\(raw)\"."
        case .duplicateSavedPlaceIdentifier(let identifier): "Two Saved Places share Maps identifier \(identifier)."
        case .duplicateHealthKitSample(let id): "The HealthKit sample \(id) is attached to more than one visit."
        case .invalidLocationEvent(let reason): "A location callback record is invalid: \(reason)."
        case .invalidCorrection(let reason): "A correction record is invalid: \(reason)."
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
            if let routeData = visit.routeData,
               (try? JSONDecoder().decode([RoutePoint].self, from: routeData)) == nil {
                throw BackupValidationError.malformedRoute(arrival: visit.arrival)
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
            guard event.accuracy >= 0 else {
                throw BackupValidationError.invalidLocationEvent(reason: "negative accuracy")
            }
            if let arrival = event.arrival, let departure = event.departure, departure < arrival {
                throw BackupValidationError.invalidLocationEvent(reason: "departure before arrival")
            }
        }
        for correction in corrections where correction.changedAt < correction.visitArrival {
            throw BackupValidationError.invalidCorrection(reason: "recorded before the visit it corrects")
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
        let document = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: visits.map { .init(arrival: $0.arrival, departure: $0.departure, latitude: $0.latitude, longitude: $0.longitude, placeName: $0.placeName, inferredActivity: $0.inferredActivity, userActivity: $0.userActivity, note: $0.note, source: $0.source, recognitionConfidence: $0.recognitionConfidence, candidateData: $0.candidateData, mapsIdentifier: $0.mapsIdentifier, placeFieldProvenance: $0.placeFieldProvenance, resolutionExplanation: $0.resolutionExplanation, stableID: $0.stableID, resolutionState: $0.resolutionStateRaw, healthKitSampleIDs: $0.healthKitSampleIDs, routeData: $0.routeData) },
            savedPlaces: places.map { .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius, defaultActivity: $0.defaultActivity, mapsIdentifier: $0.mapsIdentifier, role: $0.role) },
            corrections: corrections.map { .init(changedAt: $0.changedAt, visitArrival: $0.visitArrival, latitude: $0.latitude, longitude: $0.longitude, previousPlaceName: $0.previousPlaceName, newPlaceName: $0.newPlaceName, previousActivity: $0.previousActivity, newActivity: $0.newActivity, previousConfidence: $0.previousConfidence, newConfidence: $0.newConfidence, reason: $0.reason) },
            diagnostics: diagnostics.map { .init(createdAt: $0.createdAt, subsystem: $0.subsystem, severity: $0.severity, message: $0.message, category: $0.category) },
            locationEvents: locationEvents.map { .init(recordedAt: $0.recordedAt, callbackType: $0.callbackType,
                callbackAt: $0.callbackAt, arrival: $0.arrival, departure: $0.departure,
                latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.accuracy,
                distanceFromCurrentVisit: $0.distanceFromCurrentVisit, transition: $0.transition,
                visitArrival: $0.visitArrival) },
            ignoredVisitKeys: [], activityDefinitions: ActivityCatalog.load(), preferences: preferences())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Decodes and validates the whole archive before touching `context`, then
    /// restores it in one pass. Any failure in either phase leaves the store and
    /// preferences exactly as they were: validation runs before the first
    /// `insert`, and an error from `context.save()` itself rolls back everything
    /// staged in this call before it propagates, so a caller never sees a store
    /// left half-restored.
    @MainActor
    static func restore(_ data: Data, into context: ModelContext) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup: LifeLogBackup
        do {
            backup = try decoder.decode(LifeLogBackup.self, from: data)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        // V1 and V2 both restore; only a version this build has never heard of
        // (from a future build) is rejected, not merely an old one.
        guard (1...LifeLogBackup.currentVersion).contains(backup.version) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try backup.validate()

        do {
            for record in backup.visits {
                context.insert(Visit(arrival: record.arrival, departure: record.departure, latitude: record.latitude, longitude: record.longitude, placeName: record.placeName, inferredActivity: record.inferredActivity, userActivity: record.userActivity, note: record.note, source: record.source, recognitionConfidence: record.recognitionConfidence, candidateData: record.candidateData, mapsIdentifier: record.mapsIdentifier, placeFieldProvenance: record.placeFieldProvenance, resolutionExplanation: record.resolutionExplanation,
                    healthKitSampleIDs: record.healthKitSampleIDs, routeData: record.routeData,
                    stableID: record.stableID ?? UUID(),
                    resolutionState: record.resolutionState.flatMap(VisitResolutionState.init(rawValue:))))
            }
            for record in backup.savedPlaces {
                let place = SavedPlace(name: record.name, latitude: record.latitude, longitude: record.longitude, radius: record.radius, defaultActivity: record.defaultActivity, mapsIdentifier: record.mapsIdentifier)
                place.role = record.role
                context.insert(place)
            }
            for record in backup.corrections { context.insert(VisitCorrection(changedAt: record.changedAt, visitArrival: record.visitArrival, latitude: record.latitude, longitude: record.longitude, previousPlaceName: record.previousPlaceName, newPlaceName: record.newPlaceName, previousActivity: record.previousActivity, newActivity: record.newActivity, previousConfidence: record.previousConfidence, newConfidence: record.newConfidence, reason: record.reason)) }
            for record in backup.diagnostics { context.insert(DiagnosticEvent(createdAt: record.createdAt, subsystem: record.subsystem, severity: record.severity, message: record.message, category: record.category ?? Diagnostics.Category.general)) }
            for record in backup.locationEvents ?? [] {
                context.insert(LocationEvent(recordedAt: record.recordedAt, callbackType: record.callbackType,
                                             callbackAt: record.callbackAt, arrival: record.arrival,
                                             departure: record.departure, latitude: record.latitude,
                                             longitude: record.longitude, accuracy: record.accuracy,
                                             distanceFromCurrentVisit: record.distanceFromCurrentVisit,
                                             transition: record.transition, visitArrival: record.visitArrival))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // Everything from here on is UserDefaults, not the SwiftData store the
        // block above already committed — none of it can throw, so a restore
        // that reached this point always finishes in full.
        IgnoredLocations.importKeys(backup.ignoredVisitKeys)
        ActivityCatalog.save(backup.activityDefinitions)
        for (key, value) in backup.preferences where isPortablePreferenceKey(key) {
            UserDefaults.standard.set(value, forKey: key)
        }

        // One resolver pass settles the just-restored timeline into the same
        // shape any other store mutation leaves it in, and its own invariant
        // validator — run exactly once here — records whether it succeeded.
        try ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "backup-restore")
    }

    private static func preferences() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation().compactMapValues { value in
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
            return nil
        }.filter { isPortablePreferenceKey($0.key) }
    }
}
