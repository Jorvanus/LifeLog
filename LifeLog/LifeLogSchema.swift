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
enum LifeLogSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [LifeLog.Visit.self, LifeLog.SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }
}

enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeLogSchemaV1.self, LifeLogSchemaV2.self]
    }

    /// Dropping a property is a lightweight change, so SwiftData rewrites the
    /// store without a custom handler and existing visits keep every other field.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LifeLogSchemaV1.self, toVersion: LifeLogSchemaV2.self)]
    }
}
