import Foundation
import SwiftData

/// The shape shipped before LifeLog stopped modelling a place type. These
/// definitions are a frozen snapshot and are never used by app code — they exist
/// so the migration plan has a distinct V1 to migrate *from*. Pointing V1 at the
/// live model types instead makes both versions hash identically and SwiftData
/// rejects the plan with "Duplicate version checksums detected."
enum LifeLogSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }

    @Model
    final class Visit {
        var arrival: Date
        var departure: Date?
        var latitude: Double
        var longitude: Double
        var placeName: String
        var placeCategory: String
        var inferredActivity: String
        var userActivity: String?
        var note: String
        var source: String
        var recognitionConfidence: String?
        var candidateData: Data?
        var healthKitSampleIDs: [UUID]?

        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             placeCategory: String, inferredActivity: String, note: String, source: String) {
            self.arrival = arrival
            self.latitude = latitude
            self.longitude = longitude
            self.placeName = placeName
            self.placeCategory = placeCategory
            self.inferredActivity = inferredActivity
            self.note = note
            self.source = source
        }
    }

    @Model
    final class SavedPlace {
        var name: String
        var latitude: Double
        var longitude: Double
        var radius: Double
        var category: String
        var defaultActivity: String

        init(name: String, latitude: Double, longitude: Double, radius: Double,
             category: String, defaultActivity: String) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.category = category
            self.defaultActivity = defaultActivity
        }
    }
}

/// V2 drops `Visit.placeCategory` and `SavedPlace.category`. LifeLog no longer
/// models a place type: a visit is identified by its name, Insights groups by
/// activity, and "Top places" groups by place name.
///
/// Frozen for the same reason V1 is: V3 points at the live models, and two versions
/// that both point there hash identically, which SwiftData rejects. These definitions
/// must keep matching the shape shipped as V2 exactly, or an installed store will not
/// be recognised as V2 and cannot be migrated forward.
enum LifeLogSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }

    @Model
    final class Visit {
        var arrival: Date
        var departure: Date?
        var latitude: Double
        var longitude: Double
        var placeName: String
        var inferredActivity: String
        var userActivity: String?
        var note: String
        var source: String
        var recognitionConfidence: String?
        var candidateData: Data?
        var healthKitSampleIDs: [UUID]?

        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival
            self.latitude = latitude
            self.longitude = longitude
            self.placeName = placeName
            self.inferredActivity = inferredActivity
            self.note = note
            self.source = source
        }
    }

    @Model
    final class SavedPlace {
        var name: String
        var latitude: Double
        var longitude: Double
        var radius: Double
        var defaultActivity: String

        init(name: String, latitude: Double, longitude: Double, radius: Double,
             defaultActivity: String) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.defaultActivity = defaultActivity
        }
    }

    @Model
    final class VisitCorrection {
        var changedAt: Date
        var visitArrival: Date
        var latitude: Double
        var longitude: Double
        var previousPlaceName: String
        var newPlaceName: String
        var previousActivity: String
        var newActivity: String
        var previousConfidence: String
        var newConfidence: String
        var reason: String

        init(changedAt: Date, visitArrival: Date, latitude: Double, longitude: Double,
             previousPlaceName: String, newPlaceName: String, previousActivity: String,
             newActivity: String, previousConfidence: String, newConfidence: String,
             reason: String) {
            self.changedAt = changedAt
            self.visitArrival = visitArrival
            self.latitude = latitude
            self.longitude = longitude
            self.previousPlaceName = previousPlaceName
            self.newPlaceName = newPlaceName
            self.previousActivity = previousActivity
            self.newActivity = newActivity
            self.previousConfidence = previousConfidence
            self.newConfidence = newConfidence
            self.reason = reason
        }
    }

    @Model
    final class DiagnosticEvent {
        var createdAt: Date
        var subsystem: String
        var severity: String
        var message: String
        var category: String = "general"

        init(createdAt: Date, subsystem: String, severity: String, message: String, category: String) {
            self.createdAt = createdAt
            self.subsystem = subsystem
            self.severity = severity
            self.message = message
            self.category = category
        }
    }
}

/// V3 adds `Visit.routeData`: the path a movement record followed. A walk passes
/// through many places and belongs to none of them, so a journey needs a sequence of
/// coordinates rather than the single point a stay has.
enum LifeLogSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [LifeLog.Visit.self, LifeLog.SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }
}

enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeLogSchemaV1.self, LifeLogSchemaV2.self, LifeLogSchemaV3.self]
    }

    /// Dropping a property and adding an optional one are both lightweight, so
    /// SwiftData rewrites the store without a custom handler. Every existing visit
    /// keeps its fields and arrives at V3 with no route, which is correct: nothing
    /// recorded before this version has a path to restore.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LifeLogSchemaV1.self, toVersion: LifeLogSchemaV2.self),
            .lightweight(fromVersion: LifeLogSchemaV2.self, toVersion: LifeLogSchemaV3.self)
        ]
    }
}
