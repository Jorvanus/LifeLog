# SwiftData schema migrations

LifeLog stores `Visit`, `SavedPlace`, `VisitCorrection`, and `DiagnosticEvent` as `LifeLogSchemaV3` (`3.0.0`), opened through `LifeLogMigrationPlan`. V1 dropped nothing yet; V2 removed `Visit.placeCategory` and `SavedPlace.category`; V3 added `Visit.routeData`, the path a movement record followed.

V1 and V2 are frozen snapshots that define their own models. Only the newest version may point at the live model types — two versions that both point there hash identically and SwiftData rejects the plan with "Duplicate version checksums detected". So before adding a property, freeze the current version by copying the live model definitions into it, exactly as shipped, and give the new version the live types.

Before adding any persisted property or model:

1. Freeze the outgoing version with the complete model definitions it shipped with, add the next `LifeLogSchemaVN` pointing at the live models, and update the migration plan’s schema list and stages.
2. Add a `MigrationStage.custom` or lightweight stage that gives the new field a safe value for every existing row.
3. Extend `SchemaMigrationTests` to seed a store with the frozen previous version, open the same on-disk copy through the new one, and assert every existing model and field survives plus the new field has its documented default. `migratesV2StoreAddingRoutes` is the worked example.
4. Run the migration test against a copied device store. Never use the original protected store for development experiments.
5. Only then update `LifeLogApp` (and the store-recovery report text) to open the new version and ship the change.

The fixture test intentionally starts with the unversioned schema that the current release used, writes representative data to a temporary SQLite store, closes it, and opens the same path with the versioned plan. This is the minimum regression gate for data-loss protection; future schema versions must retain this test and add an explicit V1 → V2 assertion.
