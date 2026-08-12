# SwiftData schema migrations

LifeLog stores `Visit`, `SavedPlace`, `VisitCorrection`, `DiagnosticEvent`, and `LocationEvent` as `LifeLogSchemaV7` (`7.0.0`), opened through `LifeLogMigrationPlan`. V1 is the frozen shape from the unversioned store immediately before versioning; V2 removed `Visit.placeCategory` and `SavedPlace.category`; V3 added `Visit.routeData`; V4 added `SavedPlace.mapsIdentifier`; V5 added the raw location journal; V6 added Maps identity and provenance to visits; and V7 added the persisted location-resolution explanation.

V1 through V6 are frozen snapshots that define their own models. Only the newest version may point at the live model types — two versions that both point there hash identically and SwiftData rejects the plan with "Duplicate version checksums detected". So before adding a property, freeze the current version by copying the live model definitions into it, exactly as shipped, and give the new version the live types.

Before adding any persisted property or model:

1. Freeze the outgoing version with the complete model definitions it shipped with, add the next `LifeLogSchemaVN` pointing at the live models, and update the migration plan’s schema list and stages.
2. Add a `MigrationStage.custom` or lightweight stage that gives the new field a safe value for every existing row.
3. Extend `SchemaMigrationTests` to seed a store with the frozen previous version, open the same on-disk copy through the new one, and assert every existing model and field survives plus the new field has its documented default. `migratesV2StoreAddingRoutes` is the worked example.
4. Run the migration test against a copied device store. Never use the original protected store for development experiments.
5. Only then update `LifeLogApp` (and the store-recovery report text) to open the new version and ship the change.

The fixture suite intentionally starts with the exact unversioned schema shipped immediately before the V1 baseline, writes representative data to a temporary SQLite store, closes it, and opens the same path with the versioned plan. It also exercises the frozen version hops through V7, including V6 → V7’s optional resolution explanation. Future versions must retain the full-chain fixture and add an explicit previous-version → current-version assertion. A copied pre-versioned device store remains the final proof because no synthetic fixture can prove every historical store variant.
