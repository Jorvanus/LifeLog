# LifeLog — code roadmap

Rebuilt from a repository-wide audit of `main` at `25d3f92` on 2026-08-16.
This is an open-work list, not a record of shipped features. The old roadmap was
discarded rather than amended because archive repair, Insights, activity identity,
backup, and recovery have all changed materially since it was written.

LifeLog is a private app for one iPhone 17 Pro Max. Correct history, predictable
background ingestion, responsive access to the nine-year archive, and code that can
be changed safely outrank App Store preparation or speculative integrations.

## Do next — correctness and recovery

- [ ] **Make local backup represent the current schema, not its compatibility
  snapshot.** Add the durable `ActivityDefinitionRecord` rows to a new backup
  version, including inactive definitions still referenced by historical Visits.
  Keep the legacy `ActivityDefinition` catalogue only for older-backup compatibility.
  Put record counts, app/schema version, and payload sizes in a manifest and add a
  field-for-field round-trip fixture for every current `@Model` type. A schema field
  added without a corresponding backup field should make that test fail.

- [ ] **Request every Health type that Insights already reads.** `healthTypes`
  requests steps, sleep, workouts, routes, and the four heart/breathing signals, but
  omits walking/running distance, active energy, exercise time, and stand time even
  though `HealthInsightsSummary` queries and displays them. Put the requested read
  set, observer set, and summary-query set behind one source of truth and test that
  they cannot drift apart.

- [ ] **Fix current-month comparisons.** A month in progress is currently totalled
  only through today but compared with the entire previous month, so “more/less than
  last month” can be structurally misleading. Compare equal elapsed calendar spans
  (with calendar/DST-aware boundaries), or compare normalized daily averages and say
  so in the UI. Make `MonthlyInsights` use the interval parameters it currently
  accepts but ignores; cover the first day, mid-month, completed months, leap years,
  and different month lengths.

- [ ] **Finish the protected-store recovery path.** Recovery reports and copied-store
  manifests still identify the schema as V4 while the live migration plan is V11.
  Derive the schema/build identity rather than hard-coding it, apply protection to
  recovery exports, test all three SQLite files (`store`, `-wal`, `-shm`), and keep
  retry/export behavior non-destructive when one file is unavailable.

## Remove repaired-archive lifecycle debt

- [ ] **Run one explicit audit of the cleaned archive, then retire four historical
  Timeline passes.** Once the audit reports clean, delete
  `automatic-location-deduplicated-v3`, `stay-splits-rejoined-v1`,
  `WorkoutJourneys.splitWorkoutRepairKey`, and
  `location-policy-reconciled-v12`, together with their `@AppStorage` flags, verbose
  appearance diagnostics, and archive-wide work in `TimelineView`. These exist to
  repair old output; current arrivals/imports already have bounded reconciliation.

- [ ] **Do not delete the live race safeguards; move them to the writer that needs
  them.** `reapplyRecentMovementAbsorption`, `reapplyRecentJourneyTiming`, and
  `reapplyRecentOpenStayAbsorption` still compensate for the Health/Motion import
  actor finishing with a different `ModelContext`. Make import completion one
  coordinated mutation/save/publication boundary, then remove both the Timeline
  appearance repairs and their duplicate invalidation observer.

- [ ] **Find and eliminate the source of recurring duplicate sleep before removing
  `SleepSessionRepair`.** It has found duplicates after the original arrival-window
  bug was fixed, including around erase/restore and live Health sync. Serialize those
  operations or make Health sample ownership the idempotent import key. Keep the
  repair as a measured safety net until a test reproduces the race and the counter
  remains zero across real use.

- [ ] **Give future maintenance passes one owner outside SwiftUI.** A small versioned
  maintenance coordinator should decide prerequisites, persist completion only after
  a successful save, publish progress, and be callable after migration/restore.
  Screens may show status; opening a tab must not be what repairs the database.

## Insights logic and architecture

- [ ] **Extract the 1,366-line `InsightsView` coordinator.** Keep navigation and the
  selected period in the view, but move Health loading, archive retrospectives,
  period preparation, and Day/Week/Month/Year presentation state behind narrow,
  testable models. Preserve the existing bounded Visit fetch and snapshot cache; do
  not replace them with an archive-wide `@Query`.

- [ ] **Define one period-comparison policy and use it everywhere.** Day, Week, Month,
  Year, highlights, hero metrics, Health summaries, and export should agree on partial
  periods, future time, scope filtering, and comparison labels. Add table-driven
  fixtures for DST, open multi-day stays, overlaps, ignored/superseded rows, a changed
  Home radius, and sparse Health samples.

- [ ] **Add a recording-quality insight before another decorative chart.** Show
  logged coverage by week/month, longest and total gaps, provisional rows, and days
  below a useful coverage threshold. Every result already has a correction path; link
  gaps to Add Visit and provisional rows to the existing editor/review queue. This is
  the most actionable new use of the archive because it distinguishes “nothing
  happened” from “LifeLog has no evidence.”

- [ ] **Add routine stability using existing data.** Start with weekday arrival and
  departure ranges for explicit Home/Work roles, regularity of sleep start/end, and
  commute median plus variability. Require enough distinct days, show the sample
  window, and suppress conclusions when coverage is poor. Reuse resolved segments so
  the result cannot disagree with the donut or Timeline.

- [ ] **Make currently collected Health data useful before requesting more.** Give
  steps, walking/running distance, exercise minutes, stand hours, active energy,
  workouts, sleep, and the existing heart/breathing signals a coherent overview and
  drill-down. Add sleep-duration and sleep-timing consistency against the person's
  own baseline. Keep physiological cards observational, source-labelled, and free of
  medical interpretation.

- [ ] **Then evaluate a small second Health permission set.** Heart-rate variability
  and cardio fitness are better candidates than collecting a broad medical record;
  walking speed/step length may also add useful mobility context. Add a type only if
  it supports a named screen, has an empty/denied state, and can be tested without
  treating missing samples as zero.

## Settings and information architecture

- [ ] **Turn Settings from one long operational form into a status-led hub.** Put a
  compact “Recording status” summary first, then route to focused screens for
  Recording (Location/Motion), Apple Health, Places & Activities, Data & Recovery,
  Diagnostics, and About. Keep permission failures and an active import visible at
  the top; move paragraphs and uncommon actions into the relevant child screen.

- [ ] **Make Data & Recovery show what an action will do.** After creating a backup,
  show creation time, record counts, and file size, with Save/Share and a clear
  temporary-copy explanation. Before restore or erase, show the destination state and
  exact scope. Put Journal import/compaction and the two remaining archive repairs in
  this screen rather than mixing them with everyday permissions.

- [ ] **Remove accidental Settings data loads.** `SettingsView` declares complete
  Visit and Diagnostic queries that are not read anywhere. Delete them; load counts
  or backup data on demand through the existing actors. Keep Saved Places live only
  if its count materially helps the hub.

- [ ] **Use consistent row language and visual hierarchy.** Show status values with a
  shared status-row component, use sentence case for actions, reserve red for erase,
  and make each footer answer one question rather than carrying implementation
  history. Verify the redesigned hierarchy at accessibility Dynamic Type as well as
  the owner's normal iPhone layout.

## Data access, performance, and maintainability

- [ ] **Move Timeline maintenance off the main interaction path.** The day query is
  already bounded, but its appearance task still sequences repairs and diagnostics on
  the main actor. After the lifecycle work above, the screen should only prepare its
  selected day and current presentation.

- [ ] **Classify every remaining full-Visit fetch.** Backup, explicit archive repair,
  rename/merge, archive statistics, and complete validation are legitimate whole-store
  operations and should stay off the interaction path with progress/cancellation.
  Launch, Settings, ordinary navigation, and per-day correction are not. Record this
  contract beside `VisitArchiveReader` and add the 32,000-row fixture to any newly
  accepted whole-store path.

- [ ] **Reduce duplicate sources of activity truth.** Finish the transition from the
  UserDefaults catalogue to `ActivityDefinitionRecord`: define which is authoritative
  for active/inactive state and aliases, make backup/restore use it, and confine the
  legacy snapshot to decoding older data. This will also remove several launch-time
  seed/adopt/merge compatibility calls.

- [ ] **Split by ownership, not merely file length.** Next candidates are
  `LocationRecorder` (permissions, monitoring, callback handling), `TimelineView`
  (day selection versus maintenance), `ActivityDataService` (authorization, import
  orchestration, Health summaries), and `VisitEditor` (draft state, validation,
  persistence). Each extraction needs a focused test seam; line count alone is not a
  reason to move code.

- [ ] **Make performance budgets executable.** Use representative archive fixtures
  for Timeline return, Day/Week/Month/Year Insights, Settings opening, backup setup,
  and activity/place merge. Fail focused regression tests on a generous device-class
  budget and retain diagnostics for real-device evidence rather than treating either
  source as proof of the other.

## Backup file lifetime — current behavior to make explicit

The file created by **Create backup** is a staging copy in iOS's temporary directory.
LifeLog deletes matching temporary exports only when the app next launches or another
export starts, and only once their modification time is more than 24 hours old. It is
therefore eligible after 24 hours, not guaranteed to disappear exactly then; iOS may
also purge temporary files earlier. A copy saved through the share sheet belongs to
the chosen destination and LifeLog never deletes it.

- [ ] **Harden and clarify staging-file handling.** Write backups with complete file
  protection, report write/space failures accurately, clear stale `backupURL` state if
  its file disappears, and show the temporary-versus-saved distinction beside the
  share action. Keep the 24-hour sweep as a fallback rather than promising an exact
  retention time.

## Deliberately not priorities

- App Store metadata, public privacy policy, consumer onboarding, and generalized
  release work while LifeLog remains a private personal app.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, Settings structure, and the recording-quality/routine insights above.
