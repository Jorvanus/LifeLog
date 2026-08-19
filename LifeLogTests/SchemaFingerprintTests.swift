import SwiftData
import Testing
@testable import LifeLog

struct SchemaFingerprintTests {
    @Test("The immediately previous schema remains frozen")
    func previousSchemaMatchesRecordedFingerprint() {
        #expect(SchemaFingerprint.of(LifeLogSchemaV11.self) == Self.v11)
    }

    @Test("The migration plan contains only the supported one-step window")
    func migrationPlanContainsOnlyV11AndV12() {
        #expect(LifeLogMigrationPlan.schemas.map(\.versionIdentifier) == [LifeLogSchemaV11.versionIdentifier, LifeLogSchemaV12.versionIdentifier])
        #expect(LifeLogMigrationPlan.stages.count == 1)
    }

    private static let v11 = """
    ActivityDefinitionRecord[category:Swift.String,colorHex:Swift.Optional<Swift.String>?,createdAt:Foundation.Date,isActive:Swift.Bool,lifeArea:Swift.String,modifiedAt:Foundation.Date,name:Swift.String,stableID:Foundation.UUID:unique,symbol:Swift.String]{stableID}
    DiagnosticEvent[budgetMs:Swift.Optional<Swift.Int>?,category:Swift.String,createdAt:Foundation.Date,durationMs:Swift.Optional<Swift.Int>?,eventCode:Swift.String,itemCount:Swift.Optional<Swift.Int>?,message:Swift.String,repairCount:Swift.Optional<Swift.Int>?,severity:Swift.String,subsystem:Swift.String]{}
    LocationEvent[accuracy:Swift.Double,arrival:Swift.Optional<Foundation.Date>?,callbackAt:Foundation.Date,callbackType:Swift.String,departure:Swift.Optional<Foundation.Date>?,distanceFromCurrentVisit:Swift.Optional<Swift.Double>?,latitude:Swift.Double,longitude:Swift.Double,recordedAt:Foundation.Date,transition:Swift.String,visitArrival:Swift.Optional<Foundation.Date>?]{}
    SavedPlace[activityDefinitionID:Swift.Optional<Foundation.UUID>?,defaultActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,name:Swift.String,radius:Swift.Double,role:Swift.Optional<Swift.String>?]{}
    Visit[activityDefinitionID:Swift.Optional<Foundation.UUID>?,arrival:Foundation.Date,candidateData:Swift.Optional<Foundation.Data>?,departure:Swift.Optional<Foundation.Date>?,healthKitSampleIDs:Swift.Optional<Swift.Array<Foundation.UUID>>?,inferredActivity:Swift.String,latitude:Swift.Double,longitude:Swift.Double,mapsIdentifier:Swift.Optional<Swift.String>?,note:Swift.String,placeFieldProvenance:Swift.Optional<Swift.String>?,placeName:Swift.String,recognitionConfidence:Swift.Optional<Swift.String>?,resolutionExplanation:Swift.Optional<Swift.String>?,resolutionStateRaw:Swift.String,routeData:Swift.Optional<Foundation.Data>?,source:Swift.String,stableID:Foundation.UUID,userActivity:Swift.Optional<Swift.String>?]{}
    VisitCorrection[changedAt:Foundation.Date,latitude:Swift.Double,longitude:Swift.Double,newActivity:Swift.String,newConfidence:Swift.String,newPlaceName:Swift.String,previousActivity:Swift.String,previousConfidence:Swift.String,previousPlaceName:Swift.String,reason:Swift.String,visitArrival:Foundation.Date]{}
    """
}
