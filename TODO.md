# LifeLog — code roadmap

Rebuilt from a repository-wide audit of `main` at `9f65bfe` on 2026-08-19 and
updated after a second dead-code and interaction-path audit on 2026-08-20. This is an
open-work list, not a record of shipped features. The previous roadmap (from
2026-08-16) was mostly completed since — backup manifest/versioning, Settings'
status-led redesign, the maintenance coordinator, the archive-wide-fetch contract,
activity-catalogue durability, staging-file hardening, and the `VisitEditor`/Timeline
ownership seams all landed — so it was rebuilt rather than amended.

LifeLog is a private app for one iPhone 17 Pro Max, owned and used by one person.
Correct history, predictable background ingestion, responsive access to the archive,
and code that can be changed safely outrank App Store preparation or speculative
integrations.

## Correctness and recovery — still open

- [ ] **Stop reporting failed user mutations as if they succeeded, and retain the
  original Core Location failure.** `ActivityGroupsView` discards errors from group
  rename/delete with `try?`, then reloads and posts an Insights invalidation as though
  the mutation committed. `PlacesView` similarly discards the save failure when an
  ignored visit is restored/hidden and when a Saved Place is deleted. Route these
  through the same explicit committed/failed result pattern as
  `VisitMutationService`, keep the existing data visible on failure, and show one
  actionable error state. Separately, replace `LocationRecorder`'s `_ = error` in
  `locationManager(_:didFailWithError:)` with a diagnostic that retains the error
  domain/code and useful description; the current generic `.failure` event throws
  away the only reason Core Location supplied.

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

- [ ] **A drive with no Core Motion sample yet can lose its whole duration into the
  parking-spot stay at its start, not just the commute display.** Confirmed against
  the real archive 2026-08-20: leaving Work's geofence created a new stay (the
  parking spot) at 07:09:55; raw location samples show a real drive from there
  reaching 8.6km away by 07:23; a new Home arrival closed the loop at 07:25:15 —
  but CoreLocation's own `.visitDeparture` for the parking-spot stay did not fire
  until 07:26:27 (device already home), and no Core Motion automotive sample
  existed yet to bound the stay against (motion import is throttled to once every
  6 hours, `ActivityDataService.swift:720`). The parking-spot stay's departure
  defaulted to the next visit's arrival, so the entire ~15-minute drive read as
  "Visiting" the parking spot instead of commuting. Even once the motion sample
  does import, `boundStay`'s guard (`departure <= movement.end`,
  `ActivityLocationPolicy+Journeys.swift:64`) may not retroactively correct a stay
  whose departure was already pushed past where the real drive ended — unverified
  either way. Waiting on the owner to recheck the same day's data after the next
  motion refresh before touching this: `boundStay`/`extendStay` have already caused
  a nine-day repair loop from an earlier tuning attempt (see the comment at
  `ActivityLocationPolicy+Journeys.swift:114`), so a next change here needs a real
  before/after on-device comparison, not just reasoning about the code.

- [ ] **Find and eliminate the source of recurring duplicate sleep before removing
  `SleepSessionRepair`.** It has found duplicates after the original arrival-window
  bug was fixed, including around erase/restore and live Health sync. Serialize
  those operations or make Health sample ownership the idempotent import key. Keep
  the repair as a measured safety net until a test reproduces the race and the
  counter remains zero across real use.

## Efficiency and tidiness — still open

A code-first audit on 2026-08-20. These are ranked interaction-path and ownership
improvements, not a request for blanket rewrites or cosmetic file splitting.

- [ ] **Make the Locations review queue one prepared result, with one explicit
  scope.** `PlacesView` currently hydrates every automatic/manual `Visit` through an
  unbounded main-context `@Query`. Its `needingReview` computed property then rebuilds
  and sorts `ReviewQueue.entries(in:)` each time it is read; the body reads it for the
  destination, empty label, and count, so one render can repeat the same archive walk.
  The comment that this is the "same queue" as Timeline is also false in scope:
  Timeline passes only its seven-day query while Locations passes the full archive.
  Define whether Locations is the complete queue and Timeline is a recent preview (or
  make them genuinely identical), prepare the result once on an isolated reader keyed
  by store generation, and return only the Sendable row/count data each surface needs.
  Add a 32,000-row budget test and an agreement test for the chosen scope.

- [ ] **Calculate Activity Detail statistics once per meaningful input change.**
  `ActivityDetailView.statistics` runs `ActivityStatistics.make` over as many as
  5,000 candidate visits, while the view reads that computed property throughout its
  chart, comparison, places, totals, usage text, merge copy, and delete copy. Swift
  does not memoize computed properties, so a render can repeat the same filters,
  maps, day bucketing, place grouping, and sorts many times. Prepare one immutable
  statistics value for `(activity identity, candidate generation, window, now)` and
  pass it into the sections that render it; do not use ad-hoc `@State` without an
  explicit invalidation rule. Instrument the calculation count and retain a large
  activity-history performance fixture.

- [ ] **Move Diagnostics' archive summaries off live, whole-model `@Query`s.**
  `DiagnosticsView` loads every `automatic` and `automatic-superseded` visit merely to
  count provisional, approximate, duplicate, and resolution-inspectable rows; opening
  `LocationResolutionChoicesView` loads those same two collections again and filters
  them in Swift. Use store predicates/counts or an isolated reader that returns small
  Sendable summaries, and fetch only rows with candidate/explanation payloads when the
  detail screen is opened (paged if the real archive warrants it). Keep the deliberately
  capped diagnostic-event and 500-row location-journal queries simple.

- [ ] **Delete the confirmed dead production declarations and the one decorative
  empty section.** `InsightsPlacesMap` has no construction site anywhere in the app or
  tests, and `MonthlyInsights.definedCategory(for:)` has no call site. Remove both,
  plus the `Section { EmptyView() }` used only to host the Groups footer; attach that
  explanation without manufacturing an empty row. Do not churn the superficially
  similar empty alert-button closures or Ask LifeLog's `.idle` `EmptyView`: those are
  real SwiftUI API/state branches, not dead calls. Add a lightweight repeatable
  declaration-reference check so future abandoned helpers are found during tidying.

- [ ] **Return the app target to an actionable-warning-clean build.** A clean Swift 6
  build currently reports that the global `openAppleHealth()`/`openAppSettings()`
  helpers call main-actor-isolated `UIApplication` APIs from a nonisolated context;
  make their UI isolation explicit. It also reports four unnecessary `await`s around
  `InsightsAggregationActor.shared.currentGeneration()` in `PlaceHistoryView`; remove
  them if the generation accessor is intentionally synchronous, or restore a real
  isolation boundary if it is meant to serialize with aggregation. Treat Xcode's
  "no AppIntents.framework dependency" metadata message as expected for this app,
  not as a warning to silence with unused framework linkage.

- [ ] **Continue splitting `LocationRecorder` at its existing component seams.** At
  1,181 lines it still owns service-session lifetime, delegate adaptation, arrival
  confirmation, raw evidence, visit mutation, Saved Place caching, region monitoring,
  reverse geocoding, Wi-Fi sampling, and diagnostics. Preserve the observable recorder
  as the UI-facing facade, but move the confirmation state machine and monitored-region
  synchronisation behind narrow collaborators like the types already established in
  `LocationRecordingComponents.swift`. This is a maintainability refactor, not a new
  recorder rewrite: keep callback ordering and persistence boundaries covered by the
  existing arrival/incremental-resolution tests.

## Deliberately not priorities

- App Store metadata, public privacy policy, consumer onboarding, and generalized
  release work while LifeLog remains a private personal app.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, and the recording-quality/routine insights above.
