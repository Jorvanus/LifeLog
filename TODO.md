# LifeLog — code roadmap

Rebuilt from a repository-wide audit of `main` at `9f65bfe` on 2026-08-19. This is an
open-work list, not a record of shipped features. The previous roadmap (from
2026-08-16) was mostly completed since — backup manifest/versioning, Settings'
status-led redesign, the maintenance coordinator, the archive-wide-fetch contract,
activity-catalogue durability, staging-file hardening, and the `VisitEditor`/Timeline
ownership seams all landed — so it was rebuilt rather than amended.

LifeLog is a private app for one iPhone 17 Pro Max, owned and used by one person.
Correct history, predictable background ingestion, responsive access to the archive,
and code that can be changed safely outrank App Store preparation or speculative
integrations.

## Retire one-time migration debt — this device has already migrated

Every item below exists to carry data or a schema shape from before a migration that
has already completed, on the one device that will ever open this store. None of them
protect against a real future case; they are load-bearing only until deleted.

- [ ] **Drop the UserDefaults activity-catalogue bridge.**
  `ActivityCatalog.prepareDurableCatalogue`'s `legacyDataExists` check has been
  permanently false on this device since the one migration that mattered removed its
  UserDefaults key. Delete the legacy-snapshot decode path and the alias-merge loop
  it feeds. Keep `ActivityDefinition.legacyNames` itself — that's the live
  rename-alias feature `AskLifeLogResolver` still searches, not the migration
  bridge.

- [ ] **Drop the legacy ignored-locations conversion.**
  `VisitResolutionMigration.convertLegacyIgnoredKeysIfNeeded` already short-circuits
  on this device (its one-time completion flag is permanently set). Delete it, its
  launch call, `IgnoredLocations`'s legacy key-encoding helpers, and the
  `ignoredVisitKeys` backup field — every ignore is already carried by
  `Visit.resolutionState`.

- [ ] **Delete frozen schema versions V1 through V10.**
  `LifeLogMigrationPlan.schemas` only ever consults `[LifeLogSchemaV11, LifeLogSchemaV12]`
  — the roughly 850 lines of V1–V10 struct declarations in `LifeLogSchema.swift` are
  unreachable on a device that has already migrated to V12 and exist only as
  historical documentation. Delete them; keep V11 (the one live predecessor) and V12
  (current).

## Correctness and recovery — still open

- [ ] **Run one explicit audit of the cleaned archive, then retire four historical
  Timeline passes.** Once the audit reports clean, delete
  `automatic-location-deduplicated-v3`, `stay-splits-rejoined-v1`,
  `WorkoutJourneys.splitWorkoutRepairKey`, and `location-policy-reconciled-v13`,
  together with their remaining repair passes. These exist to repair old output;
  current arrivals/imports already have bounded reconciliation.
  **Last run against the real archive 2026-08-17: not clean.**
  `deduplicateAutomaticLocations` and `WorkoutJourneys.repairSplitWorkouts` found
  nothing, but `rejoinStaysSplitByMovement` and `reconcileAll` still changed rows
  identically across fresh backups after a confirmed successful reconciliation run.
  Root cause found and mitigated (see the next item); once that mitigation has had a
  few more days of normal on-device use, re-run this same audit before trying the
  retirement again.

- [ ] **Do not delete the live race safeguards; move them to the writer that needs
  them.** `reapplyRecentMovementAbsorption`, `reapplyRecentJourneyTiming`, and
  `reapplyRecentOpenStayAbsorption` still compensate for the Health/Motion import
  actor finishing with a different `ModelContext`. **Partial mitigation shipped**,
  not the fix this item asks for: the three passes now take an explicit `lookback`,
  and `ActivityDataService` re-applies them once more after each Health/Motion
  import at the width it actually just replayed. This closes the gap without the
  architectural change; making import completion one coordinated
  mutation/save/publication boundary — so the Timeline appearance repairs and their
  duplicate invalidation observer can be removed outright — is still the real fix.

- [ ] **Merge adjacent same-place `.automatic` stays with nothing recorded between
  them at all.** `coalesceStaysAcrossUnlocatedMovement` only folds away a fragment
  that carries no coordinates; `mergeOverlappingStays` only merges stays that
  overlap in time. Neither reaches two touching-but-not-overlapping `.automatic`
  stays at the same place with a real gap and nothing recorded in it — the shape a
  multi-parking-spot Work commute produces (confirmed against the real archive
  2026-08-17: a 4-minute manual "walk from the car" row between an arrival and the
  main Work stay). Deliberately not started: needs a decision on how far a gap can
  stretch before two stays are no longer "the same visit," and must never touch a
  `manual`-source row someone entered by hand.

- [ ] **Find and eliminate the source of recurring duplicate sleep before removing
  `SleepSessionRepair`.** It has found duplicates after the original arrival-window
  bug was fixed, including around erase/restore and live Health sync. Serialize
  those operations or make Health sample ownership the idempotent import key. Keep
  the repair as a measured safety net until a test reproduces the race and the
  counter remains zero across real use.

## Deliberately not priorities

- App Store metadata, public privacy policy, consumer onboarding, and generalized
  release work while LifeLog remains a private personal app.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, and the recording-quality/routine insights above.
