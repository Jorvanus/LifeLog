import Foundation
import SwiftData

// V11 is the only supported predecessor and V12 is current. Older schema
// declarations were unreachable on this installation and are intentionally not
// retained as migration targets or historical source code.

enum LifeLogSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, ActivityDefinitionRecord.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?; var activityDefinitionID: UUID?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?; var resolutionExplanation: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        var stableID: UUID = UUID(); var resolutionStateRaw: String = VisitResolutionState.provisional.rawValue
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String, inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude; self.placeName = placeName
            self.inferredActivity = inferredActivity; self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double; var defaultActivity: String
        var activityDefinitionID: UUID?; var mapsIdentifier: String?; var role: String?
        init(name: String, latitude: Double, longitude: Double, radius: Double, defaultActivity: String) {
            self.name = name; self.latitude = latitude; self.longitude = longitude; self.radius = radius; self.defaultActivity = defaultActivity
        }
    }
    @Model final class ActivityDefinitionRecord {
        @Attribute(.unique) var stableID: UUID
        var name: String; var category: String; var symbol: String; var colorHex: String?
        var lifeArea: String; var isActive: Bool; var createdAt: Date; var modifiedAt: Date
        init(stableID: UUID, name: String, category: String, symbol: String, lifeArea: String, isActive: Bool, createdAt: Date, modifiedAt: Date) {
            self.stableID = stableID; self.name = name; self.category = category; self.symbol = symbol; self.lifeArea = lifeArea
            self.isActive = isActive; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        }
    }
    @Model final class VisitCorrection {
        var changedAt: Date; var visitArrival: Date; var latitude: Double; var longitude: Double
        var previousPlaceName: String; var newPlaceName: String; var previousActivity: String; var newActivity: String
        var previousConfidence: String; var newConfidence: String; var reason: String
        init(changedAt: Date, visitArrival: Date, latitude: Double, longitude: Double, previousPlaceName: String, newPlaceName: String, previousActivity: String, newActivity: String, previousConfidence: String, newConfidence: String, reason: String) {
            self.changedAt = changedAt; self.visitArrival = visitArrival; self.latitude = latitude; self.longitude = longitude
            self.previousPlaceName = previousPlaceName; self.newPlaceName = newPlaceName; self.previousActivity = previousActivity; self.newActivity = newActivity
            self.previousConfidence = previousConfidence; self.newConfidence = newConfidence; self.reason = reason
        }
    }
    @Model final class DiagnosticEvent {
        var createdAt: Date; var subsystem: String; var severity: String; var message: String; var category: String = "general"
        var eventCode: String = "legacy-message"; var durationMs: Int?; var budgetMs: Int?; var itemCount: Int?; var repairCount: Int?
        init(createdAt: Date, subsystem: String, severity: String, message: String, category: String) {
            self.createdAt = createdAt; self.subsystem = subsystem; self.severity = severity; self.message = message; self.category = category
        }
    }
    @Model final class LocationEvent {
        var recordedAt: Date; var callbackType: String; var callbackAt: Date; var arrival: Date?; var departure: Date?
        var latitude: Double; var longitude: Double; var accuracy: Double; var distanceFromCurrentVisit: Double?
        var transition: String; var visitArrival: Date?
        init(recordedAt: Date, callbackType: String, callbackAt: Date, latitude: Double, longitude: Double, accuracy: Double, transition: String) {
            self.recordedAt = recordedAt; self.callbackType = callbackType; self.callbackAt = callbackAt; self.latitude = latitude; self.longitude = longitude
            self.accuracy = accuracy; self.transition = transition
        }
    }
}

/// V12 puts aliases beside each durable activity identity.
enum LifeLogSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LifeLog.Visit.self, LifeLog.SavedPlace.self, LifeLog.ActivityDefinitionRecord.self, LifeLog.VisitCorrection.self, LifeLog.DiagnosticEvent.self, LifeLog.LocationEvent.self]
    }
}

enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LifeLogSchemaV11.self, LifeLogSchemaV12.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LifeLogSchemaV11.self, toVersion: LifeLogSchemaV12.self)]
    }
}
