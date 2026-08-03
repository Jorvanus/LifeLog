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
    let ignoredVisitKeys: [String]
    let activityDefinitions: [ActivityDefinition]
    let preferences: [String: String]

    struct VisitRecord: Codable {
        let arrival: Date; let departure: Date?; let latitude: Double; let longitude: Double
        let placeName: String; let placeCategory: String; let inferredActivity: String
        let userActivity: String?; let note: String; let source: String
        let recognitionConfidence: String?; let candidateData: Data?
    }
    struct SavedPlaceRecord: Codable { let name: String; let latitude: Double; let longitude: Double; let radius: Double; let category: String; let defaultActivity: String }
    struct CorrectionRecord: Codable { let changedAt: Date; let visitArrival: Date; let latitude: Double; let longitude: Double; let previousPlaceName: String; let newPlaceName: String; let previousActivity: String; let newActivity: String; let previousConfidence: String; let newConfidence: String; let reason: String }
    struct DiagnosticRecord: Codable { let createdAt: Date; let subsystem: String; let severity: String; let message: String }
}

enum LocalBackupService {
    static func makeBackup(context: ModelContext, diagnostics: [DiagnosticEvent]) throws -> Data {
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let corrections = try context.fetch(FetchDescriptor<VisitCorrection>())
        let document = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: .now,
            visits: visits.map { .init(arrival: $0.arrival, departure: $0.departure, latitude: $0.latitude, longitude: $0.longitude, placeName: $0.placeName, placeCategory: $0.placeCategory, inferredActivity: $0.inferredActivity, userActivity: $0.userActivity, note: $0.note, source: $0.source, recognitionConfidence: $0.recognitionConfidence, candidateData: $0.candidateData) },
            savedPlaces: places.map { .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius, category: $0.category, defaultActivity: $0.defaultActivity) },
            corrections: corrections.map { .init(changedAt: $0.changedAt, visitArrival: $0.visitArrival, latitude: $0.latitude, longitude: $0.longitude, previousPlaceName: $0.previousPlaceName, newPlaceName: $0.newPlaceName, previousActivity: $0.previousActivity, newActivity: $0.newActivity, previousConfidence: $0.previousConfidence, newConfidence: $0.newConfidence, reason: $0.reason) },
            diagnostics: diagnostics.map { .init(createdAt: $0.createdAt, subsystem: $0.subsystem, severity: $0.severity, message: $0.message) },
            ignoredVisitKeys: IgnoredLocations.exportKeys(), activityDefinitions: ActivityCatalog.load(), preferences: preferences())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func restore(_ data: Data, into context: ModelContext) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LifeLogBackup.self, from: data)
        guard backup.version == LifeLogBackup.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
        for record in backup.visits { context.insert(Visit(arrival: record.arrival, departure: record.departure, latitude: record.latitude, longitude: record.longitude, placeName: record.placeName, placeCategory: record.placeCategory, inferredActivity: record.inferredActivity, userActivity: record.userActivity, note: record.note, source: record.source, recognitionConfidence: record.recognitionConfidence, candidateData: record.candidateData)) }
        for record in backup.savedPlaces { context.insert(SavedPlace(name: record.name, latitude: record.latitude, longitude: record.longitude, radius: record.radius, category: record.category, defaultActivity: record.defaultActivity)) }
        for record in backup.corrections { context.insert(VisitCorrection(changedAt: record.changedAt, visitArrival: record.visitArrival, latitude: record.latitude, longitude: record.longitude, previousPlaceName: record.previousPlaceName, newPlaceName: record.newPlaceName, previousActivity: record.previousActivity, newActivity: record.newActivity, previousConfidence: record.previousConfidence, newConfidence: record.newConfidence, reason: record.reason)) }
        for record in backup.diagnostics { context.insert(DiagnosticEvent(createdAt: record.createdAt, subsystem: record.subsystem, severity: record.severity, message: record.message)) }
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
