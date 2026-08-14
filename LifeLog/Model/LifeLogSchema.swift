import Foundation
import SwiftData

// MARK: - Frozen schema declarations: read before editing anything below

// `LifeLogSchemaV1` through `LifeLogSchemaV10` are frozen snapshots. Each one
// defines its own copies of `Visit`, `SavedPlace`, `VisitCorrection`,
// `DiagnosticEvent`, and (from V5 on) `LocationEvent` / `ActivityDefinitionRecord`
// exactly as they shipped. Only `LifeLogSchemaV11` -- the newest version -- may
// point at the live model types in `LifeLog/Model/Models.swift` and
// `LifeLog/Diagnostics/Diagnostics.swift`; see V11's own doc comment for why that
// is safe going forward but was not safe applied retroactively to V10.
//
// Do not rewrite, reformat, rename, or split a frozen version's declarations.
// SwiftData fingerprints each version from its exact property list (name, type,
// optionality, uniqueness) to line up an on-device store with a stage in
// `LifeLogMigrationPlan`; a change that looks purely cosmetic -- reordering
// properties, adding a comment inside the type, splitting one `@Model final class`
// declaration across lines differently -- does not change that fingerprint and is
// safe, but a change to the properties themselves does, and can strand an
// already-migrated device store outside the plan's graph with "Cannot use staged
// migration with an unknown model version." `SchemaFingerprintTests` pins each
// frozen version's structural fingerprint precisely to catch that class of
// accident; a failure there means a frozen version's shape changed, not that the
// test fixture is stale.
//
// To add a new persisted property or model: freeze the *current* live version
// (V11 today) with a copy of exactly what it shipped, add a new
// `LifeLogSchemaVN` pointing at the live types, and extend the migration plan --
// see `SCHEMA_MIGRATIONS.md` for the full checklist. Never edit a version already
// frozen, and never add a migration by editing V1 through V10 in place, even if
// the edit seems tests will still pass -- see `SchemaMigrationTests` and
// `SchemaFingerprintTests` for why "tests still pass" is not sufficient proof: a
// frozen version can drift from what a real installed store contains without
// breaking any fixture built after the drift.

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
/// Frozen in turn once V8 needed a real snapshot to migrate from — see the comment
/// there.
enum LifeLogSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?; var resolutionExplanation: String?
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

/// V8 gives a Saved Place an explicit Home/Work role, so commute detection and
/// travel labelling no longer guess from the place's name. The migration backfills
/// the role for whatever the owner already named "Home"/"Work" — see
/// `LifeLogMigrationPlan`'s V7→V8 stage — without renaming anything.
///
/// Frozen now that V9 needs a real snapshot to migrate from, the same reason V1
/// through V7 are frozen above.
enum LifeLogSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?; var resolutionExplanation: String?
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
        var defaultActivity: String; var mapsIdentifier: String?; var role: String?
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

/// V9 gives every `Visit` a stable UUID identity (`stableID`) and a persisted
/// resolution state (`resolutionStateRaw`: provisional, resolved, superseded or
/// ignored), replacing a UserDefaults registry keyed by
/// `String(describing: persistentModelID)` — an identifier SwiftData assigns from
/// the store's own row identity, which a backup/restore round trip never
/// preserves, so a restored store silently forgot every ignored visit.
///
/// See `LifeLogMigrationPlan`'s V8→V9 stage for the backfill (a fresh, unique
/// `stableID` per row, and each visit's resolution state derived the same way
/// `ActivityLocationPolicy.derivedAutomaticResolutionState` derives it going
/// forward), and `VisitResolutionMigration` for the separate, one-time,
/// post-open conversion of the legacy ignore registry — which needs
/// `UserDefaults` and its own idempotence, neither of which a migration stage's
/// `didMigrate` is positioned to own.
enum LifeLogSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?; var resolutionExplanation: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        var stableID: UUID = UUID(); var resolutionStateRaw: String = VisitResolutionState.provisional.rawValue
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude
            self.placeName = placeName; self.inferredActivity = inferredActivity
            self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double
        var defaultActivity: String; var mapsIdentifier: String?; var role: String?
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

/// V10 moves the authoritative editable activity definitions into the versioned
/// store. Visit and Saved Place names remain snapshots and the optional IDs are
/// populated after opening in bounded batches, so this structural migration never
/// turns launch into an archive rewrite.
///
/// Frozen now that V11 needs a real snapshot to migrate from, the same reason V1
/// through V9 are frozen above. This one matters more than most: it used to point
/// directly at the live model types, on the theory that whatever they currently
/// looked like simply *was* V10. That reasoning breaks the moment a live type
/// gains a field for an unrelated reason — the typed diagnostic event fields added
/// here did exactly that, and a build changing `LifeLog.DiagnosticEvent` therefore
/// silently changed what "V10" meant retroactively. A store already migrated to
/// the old V10 could no longer be placed in the (now different) migration graph,
/// which SwiftData reports as "Cannot use staged migration with an unknown model
/// version" — a real store on a real device, not a test artifact. Freezing V10 to
/// a fixed snapshot and adding V11 as its own stage is what every version before
/// it already does, and is the only form that can't be perturbed by later changes.
enum LifeLogSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, ActivityDefinitionRecord.self,
         VisitCorrection.self, DiagnosticEvent.self, LocationEvent.self]
    }
    @Model final class Visit {
        var arrival: Date; var departure: Date?; var latitude: Double; var longitude: Double
        var placeName: String; var inferredActivity: String; var userActivity: String?
        var activityDefinitionID: UUID?
        var note: String; var source: String; var recognitionConfidence: String?
        var mapsIdentifier: String?; var placeFieldProvenance: String?; var resolutionExplanation: String?
        var candidateData: Data?; var healthKitSampleIDs: [UUID]?; var routeData: Data?
        var stableID: UUID = UUID(); var resolutionStateRaw: String = VisitResolutionState.provisional.rawValue
        init(arrival: Date, latitude: Double, longitude: Double, placeName: String,
             inferredActivity: String, note: String, source: String) {
            self.arrival = arrival; self.latitude = latitude; self.longitude = longitude
            self.placeName = placeName; self.inferredActivity = inferredActivity
            self.note = note; self.source = source
        }
    }
    @Model final class SavedPlace {
        var name: String; var latitude: Double; var longitude: Double; var radius: Double
        var defaultActivity: String; var activityDefinitionID: UUID?
        var mapsIdentifier: String?; var role: String?
        init(name: String, latitude: Double, longitude: Double, radius: Double, defaultActivity: String) {
            self.name = name; self.latitude = latitude; self.longitude = longitude
            self.radius = radius; self.defaultActivity = defaultActivity
        }
    }
    @Model final class ActivityDefinitionRecord {
        @Attribute(.unique) var stableID: UUID
        var name: String; var category: String; var symbol: String; var colorHex: String?
        var lifeArea: String; var isActive: Bool; var createdAt: Date; var modifiedAt: Date
        init(stableID: UUID, name: String, category: String, symbol: String, lifeArea: String,
             isActive: Bool, createdAt: Date, modifiedAt: Date) {
            self.stableID = stableID; self.name = name; self.category = category
            self.symbol = symbol; self.lifeArea = lifeArea; self.isActive = isActive
            self.createdAt = createdAt; self.modifiedAt = modifiedAt
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

/// V11 adds the typed diagnostic event fields (`eventCode`, `durationMs`,
/// `budgetMs`, `itemCount`, `repairCount`) to `DiagnosticEvent`, replacing a
/// performance report's reliance on regex-parsing `message` for a duration or
/// item count. This is the version that now points directly at the live model
/// types — see V10's comment for why that reasoning is fine going forward
/// (nothing later mutates these types without also freezing V11 in turn and
/// adding a V12) but was not fine retroactively applied to an already-shipped
/// version.
enum LifeLogSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LifeLog.Visit.self, LifeLog.SavedPlace.self, LifeLog.ActivityDefinitionRecord.self,
         LifeLog.VisitCorrection.self, LifeLog.DiagnosticEvent.self, LifeLog.LocationEvent.self]
    }
}

enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeLogSchemaV1.self, LifeLogSchemaV2.self, LifeLogSchemaV3.self,
         LifeLogSchemaV4.self, LifeLogSchemaV5.self, LifeLogSchemaV6.self,
         LifeLogSchemaV7.self, LifeLogSchemaV8.self, LifeLogSchemaV9.self,
         LifeLogSchemaV10.self, LifeLogSchemaV11.self]
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
            .lightweight(fromVersion: LifeLogSchemaV6.self, toVersion: LifeLogSchemaV7.self),
            // Custom, not lightweight: an existing place literally named "Home" or
            // "Work" (case-insensitively, exact match — never a substring, so a real
            // "Homemaker Centre" is left alone) needs its role backfilled, or every
            // installed store would silently lose commute detection until the owner
            // re-set it by hand. The name itself is never touched.
            // `didMigrate` runs against V8's own model, not the live one — this stage
            // predates V8 being frozen, when V8 still pointed at `LifeLog.SavedPlace`
            // directly and that fetch was correct. Now that V9 is the version pointing
            // at live models, this must fetch `LifeLogSchemaV8.SavedPlace` instead, and
            // write its raw `role` string directly: `homeWorkRole` is a convenience
            // only the live type has.
            .custom(
                fromVersion: LifeLogSchemaV7.self,
                toVersion: LifeLogSchemaV8.self,
                willMigrate: nil,
                didMigrate: { context in
                    let places = try context.fetch(FetchDescriptor<LifeLogSchemaV8.SavedPlace>())
                    for place in places {
                        if place.name.caseInsensitiveCompare("Home") == .orderedSame {
                            place.role = SavedPlaceRole.home.rawValue
                        } else if place.name.caseInsensitiveCompare("Work") == .orderedSame {
                            place.role = SavedPlaceRole.work.rawValue
                        }
                    }
                    try context.save()
                }
            ),
            // Custom, not lightweight: `stableID` is non-optional, so the structural
            // step ahead of `didMigrate` fills it with a single default value shared
            // by every existing row — the same UUID for all of them until this
            // overwrites each one individually. `resolutionStateRaw` gets a uniform
            // "provisional" default the same way; this replaces it with what each
            // visit's own fields actually derive. Ignored state is deliberately not
            // touched here — see `VisitResolutionMigration` for why that is a
            // separate, post-open step rather than part of this stage.
            //
            // Fetches `LifeLogSchemaV9.Visit`, not `LifeLog.Visit` — this stage's own
            // target model, not the live type. It briefly fetched the live type
            // instead, back when V9 pointed directly at live models itself and the
            // two were identical; now that V9 is frozen (to make room for what V10,
            // and now V11, each needed), fetching the live type creates two
            // classes named "Visit" in the same staged-migration process and crashes
            // deep inside SwiftData with "Failed to cast model LifeLog.Visit ... to
            // Visit" — confirmed on-device 2026-08-14. The primitive-only overload of
            // `derivedAutomaticResolutionState` avoids needing a live `Visit` here at
            // all.
            .custom(
                fromVersion: LifeLogSchemaV8.self,
                toVersion: LifeLogSchemaV9.self,
                willMigrate: nil,
                didMigrate: { context in
                    let visits = try context.fetch(FetchDescriptor<LifeLogSchemaV9.Visit>())
                    for visit in visits {
                        visit.stableID = UUID()
                        visit.resolutionStateRaw = ActivityLocationPolicy.derivedAutomaticResolutionState(
                            source: visit.source, placeName: visit.placeName,
                            recognitionConfidence: visit.recognitionConfidence
                        ).rawValue
                    }
                    try context.save()
                }
            ),
            .lightweight(fromVersion: LifeLogSchemaV9.self, toVersion: LifeLogSchemaV10.self),
            .lightweight(fromVersion: LifeLogSchemaV10.self, toVersion: LifeLogSchemaV11.self)
        ]
    }
}
