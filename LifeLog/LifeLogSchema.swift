import SwiftData

/// The on-device store currently shipped to users. Keep this list unchanged when
/// adding a new persisted property; introduce LifeLogSchemaV2 and a migration stage
/// first, then update the app container to the latest schema.
enum LifeLogSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self]
    }
}

/// Migration stages are intentionally empty until the next persisted field is
/// designed and tested against a copy of a V1 store.
enum LifeLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeLogSchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}
