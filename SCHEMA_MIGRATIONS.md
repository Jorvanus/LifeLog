# SwiftData schema migrations

LifeLog stores `Visit`, `SavedPlace`, `VisitCorrection`, `DiagnosticEvent`, `LocationEvent`, and `ActivityDefinitionRecord` as `LifeLogSchemaV12` (`12.0.0`), opened through `LifeLogMigrationPlan`. V12 adds durable activity aliases beside each activity identity.

LifeLog is a single-owner app that is updated with each release. Its compatibility contract is deliberately small: the app opens only the immediately previous schema (V11 → V12 today) and restores only the current and immediately previous backup formats (V3/V4 today). A backup or on-device store outside that window is not silently repaired or guessed at; it must first be opened by the preceding app version.

## Frozen versions

**V1 through V11 are frozen snapshots that define their own models. V11 is the only predecessor currently in the migration plan; only V12 points at the live model types.** Two versions that both point at the live types hash identically and SwiftData rejects the plan with "Duplicate version checksums detected", and a frozen version whose declaration is edited after real stores have migrated through it can no longer be recognised by those stores, which SwiftData reports as "Cannot use staged migration with an unknown model version" — a real failure on a real device, not a hypothetical. See the note atop `LifeLog/Model/LifeLogSchema.swift` for the same rule in the file a future edit is most likely to land in.

Do not rewrite, reformat, rename, or split a frozen version's declarations, even when the change looks purely cosmetic and every test still passes — see "Detecting an accidental edit" below for why "tests still pass" is not sufficient proof that a frozen version is unchanged.

Before adding any persisted property or model:

1. Freeze the outgoing version with the complete model definitions it shipped with, add the next `LifeLogSchemaVN` pointing at the live models, and replace the plan’s one predecessor and stage with the new previous-to-current pair.
2. Add a `MigrationStage.custom` or lightweight stage that gives the new field a safe value for every existing row.
3. Extend `SchemaMigrationTests` to seed a store with the frozen previous version, open the same on-disk copy through the new one, and assert every existing model and field survives plus the new field has its documented default. `migratesV11StoreAddingDurableActivityAliases` is the current lightweight example.
4. Add the new version's structural fingerprint to `SchemaFingerprintTests` (see below) once it is itself frozen for a later version — never before, since a live version is expected to keep changing.
5. Run the migration test against a copied device store. Never use the original protected store for development experiments.
6. Only then update `LifeLogApp` (and the store-recovery report text) to open the new version and ship the change.

The fixture suite writes a representative V11 store to a temporary SQLite file, closes it, and opens the same path with the V11 → V12 plan. It asserts real persisted data after migration, never merely that the store opened. Every new version replaces this fixture with its own explicit previous-version → current-version assertion.

## Detecting an accidental edit

A frozen version can drift from what a real installed store contains without breaking a single fixture. `SchemaFingerprintTests` closes that gap for V11, the one supported predecessor: it pins its exact structural shape (entity names, and each property's name, type, optionality, and uniqueness) to a recorded constant, computed by `SchemaFingerprint.of(_:)` (`LifeLogTests/TestSupport/SchemaFingerprint.swift`) from SwiftData's own `Schema.Entity` reflection rather than from source text, so harmless formatting or comment changes never trip it — only a real change to the persisted shape does.

If `SchemaFingerprintTests` fails, the fix is never to update the recorded constant to match the new shape — that defeats the entire test. It means either the edit was a mistake (revert it), or it was an intentional new field that has to become a brand-new frozen version with its own migration stage, per the checklist above.

## Backup/restore is tested independently of schema migration

`LocalBackupTests` never seeds a frozen `LifeLogSchemaVN` snapshot or opens a store through `LifeLogMigrationPlan` for its round-trip, validation, or identity-preservation coverage — every one of those tests builds its context directly against the live model types, so `LocalBackupService` is proven correct on its own terms, independent of whatever the migration plan happens to look like. The one exception, `restoresIntoAContainerOpenedThroughTheRealMigrationPlan`, opens a fresh V12 store through the real `LifeLogMigrationPlan` specifically to confirm that independence is not hiding a real dependency — restore has to work the way the app actually constructs its container, not only in a bespoke test-only one.

`ArchiveModelFieldCoverageTests` is the backstop for the promise above: a local backup represents the *current* schema, not merely whatever fields someone remembered to copy into it. It reflects a real instance of every `@Model` type with `Mirror` — never a hand-maintained field list, which could itself go stale the same way the backup format could — and asserts every stored property has a same-named counterpart on its backup record type (modulo the one documented rename). Add a stored property to any of `Visit`, `SavedPlace`, `ActivityDefinitionRecord`, `VisitCorrection`, `DiagnosticEvent`, or `LocationEvent` without also adding it to the matching record in `LocalBackupService.LifeLogBackup` and wiring it through `encodeBackup`/`restore`, and this suite fails — before a real backup ever silently ships without it.
