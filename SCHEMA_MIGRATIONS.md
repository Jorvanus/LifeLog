# SwiftData schema migrations

LifeLog currently stores `Visit`, `SavedPlace`, `VisitCorrection`, and `DiagnosticEvent` as `LifeLogSchemaV1` (`1.0.0`). The app opens that schema through `LifeLogMigrationPlan`, even though V1 has no migration stage yet.

Before adding any persisted property or model:

1. Add a new `LifeLogSchemaV2` with the complete V2 model definitions and update the migration plan’s schema list.
2. Add a `MigrationStage.custom` or lightweight stage that gives the new field a safe value for every existing row.
3. Extend `SchemaMigrationTests` to seed the current schema, open the same on-disk copy through V2, and assert every existing model and field survives plus the new field has its documented default.
4. Run the migration test against a copied device store. Never use the original protected store for development experiments.
5. Only then update `LifeLogApp` to open V2 and ship the change.

The fixture test intentionally starts with the unversioned schema that the current release used, writes representative data to a temporary SQLite store, closes it, and opens the same path with the versioned plan. This is the minimum regression gate for data-loss protection; future schema versions must retain this test and add an explicit V1 → V2 assertion.
