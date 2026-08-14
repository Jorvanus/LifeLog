import SwiftData
import Testing
@testable import LifeLog

/// Pins the structural fingerprint of every frozen schema version (V1 through
/// V10 -- see the note atop `LifeLogSchema.swift`) so an edit to a frozen
/// declaration fails here even when it still compiles, still opens a store, and
/// even still passes `SchemaMigrationTests` because no fixture happens to touch
/// the changed field.
///
/// A failure means a frozen version's entities or properties changed shape.
/// That is never the right fix -- freeze the current live version and add a new
/// one instead, per `SCHEMA_MIGRATIONS.md`. These constants are recorded once,
/// by running `SchemaFingerprint.of(...)` and copying its output; they are not
/// meant to be "fixed up" to match a changed frozen version.
struct SchemaFingerprintTests {
    @Test("Frozen schema versions match their recorded fingerprint")
    func frozenSchemasMatchRecordedFingerprints() {
        let cases: [(label: String, actual: String, expected: String)] = [
            ("V1", SchemaFingerprint.of(LifeLogSchemaV1.self), Self.v1),
            ("V2", SchemaFingerprint.of(LifeLogSchemaV2.self), Self.v2),
            ("V3", SchemaFingerprint.of(LifeLogSchemaV3.self), Self.v3),
            ("V4", SchemaFingerprint.of(LifeLogSchemaV4.self), Self.v4),
            ("V5", SchemaFingerprint.of(LifeLogSchemaV5.self), Self.v5),
            ("V6", SchemaFingerprint.of(LifeLogSchemaV6.self), Self.v6),
            ("V7", SchemaFingerprint.of(LifeLogSchemaV7.self), Self.v7),
            ("V8", SchemaFingerprint.of(LifeLogSchemaV8.self), Self.v8),
            ("V9", SchemaFingerprint.of(LifeLogSchemaV9.self), Self.v9),
            ("V10", SchemaFingerprint.of(LifeLogSchemaV10.self), Self.v10)
        ]
        for testCase in cases {
            #expect(
                testCase.actual == testCase.expected,
                "\(testCase.label)'s structural shape changed. If this is deliberate, it must be a brand-new frozen version (never an edit to an existing one) -- see the note atop LifeLogSchema.swift."
            )
        }
    }

    /// Guards the manifest itself, not just its contents: today exactly ten
    /// versions (V1...V10) are frozen and the eleventh (V11) is the live one this
    /// file must never pin, because a live version is expected to keep changing
    /// until it, too, is frozen for a V12. If this count ever moves without a
    /// matching change here, that is exactly the moment a new frozen version's
    /// fingerprint was forgotten -- add its case to
    /// `frozenSchemasMatchRecordedFingerprints` and its recorded constant below,
    /// and add its own previous-to-current migration fixture to
    /// `SchemaMigrationTests` (see `migratesV10StoreAddingTypedDiagnosticFields`
    /// for the shape that test should take).
    @Test("The migration plan still has exactly ten frozen versions ahead of the live one")
    func frozenVersionCountMatchesThePlan() {
        let frozenCount = LifeLogMigrationPlan.schemas.count - 1
        #expect(frozenCount == 10, "LifeLogMigrationPlan now has \(frozenCount) frozen versions, not 10 -- update SchemaFingerprintTests and SchemaMigrationTests for the newly frozen version before this can pass again.")
        #expect(LifeLogMigrationPlan.schemas.last?.versionIdentifier == LifeLogSchemaV11.versionIdentifier, "LifeLogSchemaV11 is expected to be the current, live-pointing version. If a new version now ships, SchemaMigrationTests' previous-on-device-schema fixture must move to match it.")
    }

    // Recorded fingerprints. Regenerate a single line by printing
    // `SchemaFingerprint.of(LifeLogSchemaVN.self)` for that version -- never bulk
    // regenerate all of them, which would silently defeat this test's purpose.
    private static let v1 = """
    DiagnosticEvent[createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    SavedPlace[category:Swift.String,defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,note:Swift.String,placeCategory:Swift.String,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v2 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,note:Swift.String,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v3 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,note:Swift.String,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v4 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,note:Swift.String,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v5 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,note:Swift.String,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v6 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v7 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v8 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double,role:Swift.Optional<Swift.String>?]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v9 = """
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double,role:Swift.Optional<Swift.String>?]{}
    Visit[arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,resolutionStateRaw:Swift.String,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,stableID:Foundation.UUID,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """

    private static let v10 = """
    ActivityDefinitionRecord[category:Swift.String,colorHex:Swift.Optional<Swift.String>?,createdAt:Foundation.Date,isActive:Swift.Bool,lifeArea:Swift.String,modifiedAt:Foundation.Date,name:Swift.String,stableID:Foundation.UUID:unique,symbol:Swift.String]{stableID}
    DiagnosticEvent[category:Swift.String,createdAt:Foundation.Date,message:Swift.String,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[activityDefinitionID:Swift.Optional<Foundation.UUID>?,defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double,role:Swift.Optional<Swift.String>?]{}
    Visit[activityDefinitionID:Swift.Optional<Foundation.UUID>?,arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,resolutionStateRaw:Swift.String,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,stableID:Foundation.UUID,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """
}
