import SwiftData
import Testing
@testable import LifeLog

/// Pins the only frozen schema that remains inside the supported migration
/// window. Older declarations are historical references, not executable paths.
///
/// A failure means a frozen version's entities or properties changed shape.
/// That is never the right fix -- freeze the current live version and add a new
/// one instead, per `SCHEMA_MIGRATIONS.md`. These constants are recorded once,
/// by running `SchemaFingerprint.of(...)` and copying its output; they are not
/// meant to be "fixed up" to match a changed frozen version.
struct SchemaFingerprintTests {
    @Test("The immediately previous schema matches its recorded fingerprint")
    func previousSchemaMatchesRecordedFingerprint() {
        #expect(
            SchemaFingerprint.of(LifeLogSchemaV11.self) == Self.v11,
            "V11's structural shape changed. The supported previous-store migration depends on it remaining frozen."
        )
    }

    @Test("The migration plan supports exactly the previous and current schemas")
    func migrationPlanContainsOnlyTheOneStepWindow() {
        #expect(LifeLogMigrationPlan.schemas.map(\.versionIdentifier) == [
            LifeLogSchemaV11.versionIdentifier,
            LifeLogSchemaV12.versionIdentifier
        ])
        #expect(LifeLogMigrationPlan.stages.count == 1)
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

    private static let v11 = """
    ActivityDefinitionRecord[category:Swift.String,colorHex:Swift.Optional<Swift.String>?,createdAt:Foundation.Date,isActive:Swift.Bool,lifeArea:Swift.String,modifiedAt:Foundation.Date,name:Swift.String,stableID:Foundation.UUID:unique,symbol:Swift.String]{stableID}
    DiagnosticEvent[budgetMs:Swift.Optional<Swift.Int>?,category:Swift.String,createdAt:Foundation.Date,durationMs:Swift.Optional<Swift.Int>?,eventCode:Swift.String,itemCount:Swift.Optional<Swift.Int>?,message:Swift.String,repairCount:Swift.Optional<Swift.Int>?,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[activityDefinitionID:Swift.Optional<Foundation.UUID>?,defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double,role:Swift.Optional<Swift.String>?]{}
    Visit[activityDefinitionID:Swift.Optional<Foundation.UUID>?,arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,resolutionStateRaw:Swift.String,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,stableID:Foundation.UUID,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """
}
