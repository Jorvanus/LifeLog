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

    // The first released store did not yet have diagnostic retention categories.
    // Keep this model frozen so the unversioned store from that release matches V1.
    @Model
    final class DiagnosticEvent {
        var createdAt: Date
        var subsystem: String
        var severity: String
        var message: String

        init(createdAt: Date, subsystem: String, severity: String, message: String) {
            self.createdAt = createdAt
            self.subsystem = subsystem
            self.severity = severity
            self.message = message
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
///
/// Frozen for the same reason V1 and V2 are: only the newest version may point at the
/// live models, or two versions hash identically and SwiftData rejects the plan.
enum LifeLogSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

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
        var routeData: Data?

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

/// V4 adds `SavedPlace.mapsIdentifier`. A place was identified by its name, which two
/// businesses can share and which changes when either Apple or the person rewords it.
/// Apple Maps' own identifier survives both.
enum LifeLogSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }

    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude
            self.placeName = placeName; self.inferredActivity = inferredActivity
            self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double
        var defaultActivity: String; var mapsIdentifier: String?
        init(name: String, latitude: Double, longitude: Double, radius: Double, defaultActivity: String) {
            self.name = name; self.latitude = latitude; self.longitude = longitude
            self.radius = radius; self.defaultActivity = defaultActivity
        }
    }
    @Model final class VisitCorrection {
        var changedAt: Date; var visitArrival: Date; var latitude: Double; var longitude: Double
        var previousPlaceName: String; var newPlaceName: String; var previousActivity: String; var newActivity: String
        var previousConfidence: String; var newConfidence: String; var reason: String
        init(changedAt: Date, visitArrival: Date, latitude: Double, longitude: Double, previousPlaceName: String,
             newPlaceName: String, previousActivity: String, newActivity: String, previousConfidence: String,
             newConfidence: String, reason: String) {
            self.changedAt = changedAt; self.visitArrival = visitArrival; self.latitude = latitude; self.longitude = longitude
            self.previousPlaceName = previousPlaceName; self.newPlaceName = newPlaceName; self.previousActivity = previousActivity
            self.newActivity = newActivity; self.previousConfidence = previousConfidence; self.newConfidence = newConfidence; self.reason = reason
        }
    }
    @Model final class DiagnosticEvent {
        var createdAt: Date; var subsystem: String; var severity: String; var message: String; var category: String = "general"
        init(createdAt: Date, subsystem: String, severity: String, message: String, category: String) {
            self.createdAt = createdAt; self.subsystem = subsystem; self.severity = severity; self.message = message; self.category = category
        }
    }
}

/// Adds the location-event journal: the raw Core Location callbacks behind the visits,
/// kept only while detailed diagnostics are on.
///
/// A new model and nothing else. No existing type gains, loses or changes a property,
/// so every visit, place and correction is carried over untouched and the store gains
/// one empty table — which is the cheapest migration there is, and deliberately chosen
/// over giving `Visit` an identifier to reference, which would have rewritten every one
/// of them.
enum LifeLogSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }

    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude
            self.placeName = placeName; self.inferredActivity = inferredActivity
            self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double
        var defaultActivity: String; var mapsIdentifier: String?
        init(name: String, latitude: Double, longitude: Double, radius: Double, defaultActivity: String) {
            self.name = name; self.latitude = latitude; self.longitude = longitude
            self.radius = radius; self.defaultActivity = defaultActivity
        }
    }
    @Model final class VisitCorrection {
        var changedAt: Date; var visitArrival: Date; var latitude: Double; var longitude: Double
        var previousPlaceName: String; var newPlaceName: String; var previousActivity: String; var newActivity: String
        var previousConfidence: String; var newConfidence: String; var reason: String
        init(changedAt: Date, visitArrival: Date, latitude: Double, longitude: Double, previousPlaceName: String,
             newPlaceName: String, previousActivity: String, newActivity: String, previousConfidence: String,
             newConfidence: String, reason: String) {
            self.changedAt = changedAt; self.visitArrival = visitArrival; self.latitude = latitude; self.longitude = longitude
            self.previousPlaceName = previousPlaceName; self.newPlaceName = newPlaceName; self.previousActivity = previousActivity
            self.newActivity = newActivity; self.previousConfidence = previousConfidence; self.newConfidence = newConfidence; self.reason = reason
        }
    }
    @Model final class DiagnosticEvent {
        var createdAt: Date; var subsystem: String; var severity: String; var message: String; var category: String = "general"
        init(createdAt: Date, subsystem: String, severity: String, message: String, category: String) {
            self.createdAt = createdAt; self.subsystem = subsystem; self.severity = severity; self.message = message; self.category = category
        }
    }
    @Model final class LocationEvent {
        var recordedAt: Date; var callbackType: String; var callbackAt: Date; var arrival: Date?; var departure: Date?
        var latitude: Double; var longitude: Double; var accuracy: Double; var distanceFromCurrentVisit: Double?
        var transition: String; var visitArrival: Date?
        init(recordedAt: Date, callbackType: String, callbackAt: Date, latitude: Double, longitude: Double, accuracy: Double, transition: String) {
            self.recordedAt = recordedAt; self.callbackType = callbackType; self.callbackAt = callbackAt
            self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.transition = transition
        }
    }
}

/// V6 gives each Maps-resolved visit the same durable identifier already stored on
/// SavedPlace, plus field provenance. Existing visits migrate with nil identifiers
/// and continue to use the documented name fallback.
enum LifeLogSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude
            self.placeName = placeName; self.inferredActivity = inferredActivity
            self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double
        var defaultActivity: String; var mapsIdentifier: String?
        init(name: String, latitude: Double, longitude: Double, radius: Double, defaultActivity: String) {
            self.name = name; self.latitude = latitude; self.longitude = longitude
            self.radius = radius; self.defaultActivity = defaultActivity
        }
    }
    @Model final class VisitCorrection {
        var changedAt: Date; var visitArrival: Date; var latitude: Double; var longitude: Double
        var previousPlaceName: String; var newPlaceName: String; var previousActivity: String; var newActivity: String
        var previousConfidence: String; var newConfidence: String; var reason: String
        init(changedAt: Date, visitArrival: Date, latitude: Double, longitude: Double, previousPlaceName: String,
             newPlaceName: String, previousActivity: String, newActivity: String, previousConfidence: String,
             newConfidence: String, reason: String) {
            self.changedAt = changedAt; self.visitArrival = visitArrival; self.latitude = latitude; self.longitude = longitude
            self.previousPlaceName = previousPlaceName; self.newPlaceName = newPlaceName; self.previousActivity = previousActivity
            self.newActivity = newActivity; self.previousConfidence = previousConfidence; self.newConfidence = newConfidence; self.reason = reason
        }
    }
    @Model final class DiagnosticEvent {
        var createdAt: Date; var subsystem: String; var severity: String; var message: String; var category: String = "general"
        init(createdAt: Date, subsystem: String, severity: String, message: String, category: String) {
            self.createdAt = createdAt; self.subsystem = subsystem; self.severity = severity; self.message = message; self.category = category
        }
    }
    @Model final class LocationEvent {
        var recordedAt: Date; var callbackType: String; var callbackAt: Date; var arrival: Date?; var departure: Date?
        var latitude: Double; var longitude: Double; var accuracy: Double; var distanceFromCurrentVisit: Double?
        var transition: String; var visitArrival: Date?
        init(recordedAt: Date, callbackType: String, callbackAt: Date, latitude: Double, longitude: Double, accuracy: Double, transition: String) {
            self.recordedAt = recordedAt; self.callbackType = callbackType; self.callbackAt = callbackAt
            self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.transition = transition
        }
    }
}

/// V7 adds a durable explanation to automatic stays. The previous V6 snapshot is
/// frozen above so installed stores retain their original checksum during the hop.
enum LifeLogSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LifeLog.Visit.self, LifeLog.SavedPlace.self, LifeLog.VisitCorrection.self,
         LifeLog.DiagnosticEvent.self, LifeLog.LocationEvent.self]
    }
}

enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeLogSchemaV1.self, LifeLogSchemaV2.self, LifeLogSchemaV3.self,
         LifeLogSchemaV4.self, LifeLogSchemaV5.self, LifeLogSchemaV6.self,
         LifeLogSchemaV7.self]
    }

    /// Dropping a property, adding an optional one and adding a whole model are all
    /// lightweight, so SwiftData rewrites the store without a custom handler. Every
    /// existing visit keeps its fields and arrives at V3 with no route, which is
    /// correct: nothing recorded before this version has a path to restore.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LifeLogSchemaV1.self, toVersion: LifeLogSchemaV2.self),
            .lightweight(fromVersion: LifeLogSchemaV2.self, toVersion: LifeLogSchemaV3.self),
            .lightweight(fromVersion: LifeLogSchemaV3.self, toVersion: LifeLogSchemaV4.self),
            .lightweight(fromVersion: LifeLogSchemaV4.self, toVersion: LifeLogSchemaV5.self),
            .lightweight(fromVersion: LifeLogSchemaV5.self, toVersion: LifeLogSchemaV6.self),
            .lightweight(fromVersion: LifeLogSchemaV6.self, toVersion: LifeLogSchemaV7.self)
        ]
    }
}
