import Foundation
import SwiftData

struct LifeLogBackup: Codable {
    static let currentVersion = 1
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
    let ignoredVisitKeys: [String]
    let activityDefinitions: [ActivityDefinition]
    let preferences: [String: String]

    struct VisitRecord: Codable {
        let arrival: Date; let departure: Date?; let latitude: Double; let longitude: Double
        let placeName: String; let inferredActivity: String
        let userActivity: String?; let note: String; let source: String
        let recognitionConfidence: String?; let candidateData: Data?
    }
    // `placeCategory`/`category` were dropped when LifeLog stopped modelling a
    // place type. Older backups still restore: JSON keys with no matching
    // property are ignored on decode, so the format version is unchanged.
    struct SavedPlaceRecord: Codable { let name: String; let latitude: Double; let longitude: Double; let radius: Double; let defaultActivity: String }
    struct CorrectionRecord: Codable { let changedAt: Date; let visitArrival: Date; let latitude: Double; let longitude: Double; let previousPlaceName: String; let newPlaceName: String; let previousActivity: String; let newActivity: String; let previousConfidence: String; let newConfidence: String; let reason: String }
    struct DiagnosticRecord: Codable { let createdAt: Date; let subsystem: String; let severity: String; let message: String }
    struct LocationEventRecord: Codable {
        let recordedAt: Date; let callbackType: String; let callbackAt: Date
        let arrival: Date?; let departure: Date?; let latitude: Double; let longitude: Double
        let accuracy: Double; let distanceFromCurrentVisit: Double?; let transition: String
        let visitArrival: Date?
    }
}

enum LocalBackupService {
    static func makeBackup(context: ModelContext, diagnostics: [DiagnosticEvent]) throws -> Data {
        if UITestFailureInjection.shouldFailBackup {
            throw CocoaError(.fileWriteUnknown)
        }
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        let locationEvents = try context.fetch(FetchDescriptor<LocationEvent>())
        let document = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: visits.map { .init(arrival: $0.arrival, departure: $0.departure, latitude: $0.latitude, longitude: $0.longitude, placeName: $0.placeName, inferredActivity: $0.inferredActivity, userActivity: $0.userActivity, note: $0.note, source: $0.source, recognitionConfidence: $0.recognitionConfidence, candidateData: $0.candidateData) },
            savedPlaces: places.map { .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius, defaultActivity: $0.defaultActivity) },
            corrections: corrections.map { .init(changedAt: $0.changedAt, visitArrival: $0.visitArrival, latitude: $0.latitude, longitude: $0.longitude, previousPlaceName: $0.previousPlaceName, newPlaceName: $0.newPlaceName, previousActivity: $0.previousActivity, newActivity: $0.newActivity, previousConfidence: $0.previousConfidence, newConfidence: $0.newConfidence, reason: $0.reason) },
            diagnostics: diagnostics.map { .init(createdAt: $0.createdAt, subsystem: $0.subsystem, severity: $0.severity, message: $0.message) },
            locationEvents: locationEvents.map { .init(recordedAt: $0.recordedAt, callbackType: $0.callbackType,
                callbackAt: $0.callbackAt, arrival: $0.arrival, departure: $0.departure,
                latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.accuracy,
                distanceFromCurrentVisit: $0.distanceFromCurrentVisit, transition: $0.transition,
                visitArrival: $0.visitArrival) },
            ignoredVisitKeys: IgnoredLocations.exportKeys(), activityDefinitions: ActivityCatalog.load(), preferences: preferences())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func restore(_ data: Data, into context: ModelContext) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LifeLogBackup.self, from: data)
        guard backup.version == LifeLogBackup.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
        for record in backup.visits { context.insert(Visit(arrival: record.arrival, departure: record.departure, latitude: record.latitude, longitude: record.longitude, placeName: record.placeName, inferredActivity: record.inferredActivity, userActivity: record.userActivity, note: record.note, source: record.source, recognitionConfidence: record.recognitionConfidence, candidateData: record.candidateData)) }
        for record in backup.savedPlaces { context.insert(SavedPlace(name: record.name, latitude: record.latitude, longitude: record.longitude, radius: record.radius, defaultActivity: record.defaultActivity)) }
        for record in backup.corrections { context.insert(VisitCorrection(changedAt: record.changedAt, visitArrival: record.visitArrival, latitude: record.latitude, longitude: record.longitude, previousPlaceName: record.previousPlaceName, newPlaceName: record.newPlaceName, previousActivity: record.previousActivity, newActivity: record.newActivity, previousConfidence: record.previousConfidence, newConfidence: record.newConfidence, reason: record.reason)) }
        for record in backup.diagnostics { context.insert(DiagnosticEvent(createdAt: record.createdAt, subsystem: record.subsystem, severity: record.severity, message: record.message)) }
        for record in backup.locationEvents ?? [] {
            context.insert(LocationEvent(recordedAt: record.recordedAt, callbackType: record.callbackType,
                                         callbackAt: record.callbackAt, arrival: record.arrival,
                                         departure: record.departure, latitude: record.latitude,
                                         longitude: record.longitude, accuracy: record.accuracy,
                                         distanceFromCurrentVisit: record.distanceFromCurrentVisit,
                                         transition: record.transition, visitArrival: record.visitArrival))
        }
        try context.save()
        IgnoredLocations.importKeys(backup.ignoredVisitKeys)
        ActivityCatalog.save(backup.activityDefinitions)
        for (key, value) in backup.preferences { UserDefaults.standard.set(value, forKey: key) }
    }

    private static func preferences() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation().compactMapValues { value in
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
            return nil
        }.filter { $0.key.hasPrefix("LifeLog.") }
    }
}
