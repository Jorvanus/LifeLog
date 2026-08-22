# LifeLog — code roadmap

Rebuilt from a repository-wide audit of `main` at `9f65bfe` on 2026-08-19 and
updated after a second dead-code and interaction-path audit on 2026-08-20, and
reframed on 2026-08-22 as LifeLog begins moving toward TestFlight distribution to a
small group of trusted testers. This is an open-work list, not a record of shipped
features. The previous roadmap (from 2026-08-16) was mostly completed since —
backup manifest/versioning, Settings' status-led redesign, the maintenance
coordinator, the archive-wide-fetch contract, activity-catalogue durability,
staging-file hardening, and the `VisitEditor`/Timeline ownership seams all landed —
so it was rebuilt rather than amended.

LifeLog was built as a private app for one iPhone 17 Pro Max, owned and used by one
person, and that history still shows in places that assume whoever is using it
already knows how it works. Correct history, predictable background ingestion,
responsive access to the archive, and code that can be changed safely remain the
top priorities — they matter more, not less, once someone other than the author
depends on the app behaving right without being able to ask why it didn't.
Distribution-readiness work (see below) is now genuinely in scope rather than
deliberately deferred, though the scope for now is a small TestFlight group, not a
public App Store listing.

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

- [ ] **`extendStay`'s location-journal check is landed diagnostics-only; flip
  `enforceLocationJournalDepartureCheck` once a real trial period backs it up.**
  Steps 1-4 of the design (below) shipped in `e8eea4f` "Dry-run extendStay
  location-journal check; unblock test suite" (2026-08-22): `LocationJournal.
  showsDeparture(fromStayAt:in:beyond:context:)` exists, `extendStay` threads a
  `context` and refuses via `extensionRefusedByLocationEvidence` when the
  journal shows a real departure inside the gap, and both required
  `OverlapResolutionTests` fixtures pass -- the legitimate "still getting
  ready" case (no location evidence) still extends, and the actual 2026-08-21
  commute (real `geofence-exit`/`live-location-sample` rows, Home shrunk from a
  real ~21-minute departure to a displayed 7) gets refused. Verified again
  2026-08-22: full suite (679 tests) green.
  What's left is step 5 only: `enforceLocationJournalDepartureCheck` is still
  `false` (`ActivityLocationPolicy+Journeys.swift:101`), so today this only
  *logs* what it would have refused ("Would have held ... Extending anyway (dry
  run)."). Given `boundStay`/`extendStay` already caused a nine-day repair loop
  from an earlier tuning attempt (`ActivityLocationPolicy+Journeys.swift:114`),
  do not flip it on first read of the code -- let the dry-run logging run for a
  week or two of real mornings, compare its "would have refused" decisions
  against what the owner actually remembers happening, and only then flip the
  flag to `true` and remove the dry-run branch in `boundStays`.
  **Original design, for reference:**
  1. `LocationJournal` (`Diagnostics/LocationJournal.swift`) already has exactly
     the missing signal -- `geofence-exit`/`visit-departure` rows carry real
     coordinates and `distanceFromCurrentVisit` -- but only when
     `LocationDiagnostics.isDetailed` is on (it happens to be, on the owner's
     phone, which is how this was diagnosed at all) and only for its most
     recent 500 rows (`LocationJournal.retentionLimit`). A design that relies on
     it must treat "no rows in the gap" as *inconclusive*, not as "confirmed
     still there" -- diagnostics being off and genuine silence must stay
     indistinguishable, or every stay would extend by default the moment
     detailed diagnostics is switched off.
  2. Add `LocationJournal.showsDeparture(fromStayAt:in:beyond:context:) -> Bool`:
     query `LocationEvent` rows in the candidate gap window and return whether
     any exceeds `ActivityLocationPolicy.departureRadius` (250 m, already
     defined at `ActivityLocationPolicy+Journeys.swift:16`) from the stay's
     coordinate.
  3. Thread a `context: ModelContext?` into `extendStay` (the call site,
     `boundStays(around:stays:context:now:)` at line 227, already carries one)
     and refuse to extend a candidate when `showsDeparture` is true for its gap.
     With diagnostics off or the journal empty for that window, the query finds
     nothing and today's behaviour is unchanged -- this is strictly more
     conservative, never a new way to wrongly hold a stay open.
  4. Add `LocationEvent` fixtures to `OverlapResolutionTests.swift` alongside
     the existing ones: the 8 August case replayed with **no** location events
     (must still extend, guarding against repeating the reverted mistake), and
     the 21 August case replayed with real `geofence-exit`/`live-location-sample`
     rows showing distance past 250 m (must **not** extend).
  5. Given `boundStay`/`extendStay` already caused a nine-day repair loop from an
     earlier tuning attempt (`ActivityLocationPolicy+Journeys.swift:114`), land
     this diagnostics-only first -- log what it *would* have decided differently
     (same pattern as the existing "Journey ... bounded/held/changed nothing"
     logging at line 261) for a week or two of real mornings, and compare
     against what the owner actually remembers, before letting it mutate
     `stay.departure` live.

- [ ] **Finish `VisitMutationService`'s live-object restore coverage.** Fixing
  `VisitMutationServiceTests.failedMutationDoesNotPublishPartialState()`
  (2026-08-22) found that `context.rollback()` does not revert an
  already-mutated property on a live, already-fetched model object -- confirmed
  directly against this SDK: the persisted store is correctly left untouched,
  but the same object reference (even re-fetched through the same context)
  keeps reading the failed edit indefinitely. `perform`/`finalize` now take an
  explicit `restore: () -> Void` closure to cover this, wired through every
  real interactive call site (`VisitEditor`, `PlacesView` x3,
  `PlaceHistoryView`, `SavedPlaceLearning.applyIgnored`,
  `VisitLocationChooser.merge`) plus `SavedPlaceLearning.upsert`'s own internal
  failure path for the `SavedPlace` it mutates. Two gaps remain, deliberately
  left rather than rushed alongside that fix:
  1. `LocationRecorder.swift`'s eight `finalizeMutation` call sites (Core
     Location arrival/departure callbacks) each mutate a `Visit` directly
     before calling it, the same shape `VisitEditor` had -- none carry a
     `restore` closure yet. Lower visibility than an open editor (no UI is
     usually bound to the exact visit a background callback just touched), but
     the same class of bug. Needs its own pass through that file rather than
     the drive-by treatment the interactive call sites got.
  2. `SavedPlaceLearning.apply(_:context:)` bulk-relabels every `Visit` inside
     a place's radius and calls `ActivityLocationPolicy.reconcileResolutionStates`
     -- a failure partway through that loop leaves whichever visits it already
     touched unrestored. `upsert` now rolls back and restores the `SavedPlace`
     itself on failure, but not the individual visits `apply` reached first.

- [ ] **Audit the full test suite for correctness, not just for passing.**
  Fixing the eight pre-existing failures surfaced 2026-08-22 (`ActivityMergeTests`,
  `ArchiveModelFieldCoverageTests`, `ExportFileStagingTests`,
  `GapSuggestionViewModelTests`, `LocalBackupTests`, `TravelConstructionTests`,
  `VisitMutationServiceTests`, `ActivityArtworkBoundsTests` -- all now green)
  turned up real, previously-invisible bugs behind several of them: a shared
  static (`ActivityCatalog.cached`) leaking between tests that swap
  `ActivityCatalog.storage` by hand instead of through `withStorage`
  (`ActivityMergeTests.swift`, and the same pattern independently in
  `ActivityLinkingCatchUpTests.swift`), a real product bug in
  `ArchiveRepairActor.gapSuggestionContext` (a 30-minute gap floor meant for one
  caller's list silently applied to a different caller with no floor at all),
  and the `VisitMutationService` gap above. A test suite that was silently
  wrong in several unrelated places for an unknown stretch of time is reason
  enough to look at the rest on purpose rather than only when something happens
  to fail: read through what's left for other tests asserting something that
  no longer matches intent (stale fixtures, wrong expected values) or masking a
  real bug behind a coincidentally-passing assertion, the same shape every one
  of these turned out to be.
  Separately, the `LifeLogUITests` target reported 36 of 60 tests failing in
  the same 2026-08-22 run, spread across every unrelated screen (Accessibility,
  Insights, Settings, Timeline) with generic "element didn't appear" failures
  -- that breadth points at the sandboxed simulator session lacking something a
  real run needs (permission state, animation timing), not 36 independent
  regressions. Re-run on-device or in a normal interactive simulator session to
  get a trustworthy count before including UI tests in this audit.

- [ ] **Re-enable place geofence monitoring (`CLMonitor`) once Apple fixes it.**
  Disabled 2026-08-21 after a confirmed, reproducible crash loop on the owner's
  iPhone 17 Pro Max on iOS 27.0 beta (`24A5418b`): `CLMonitor`'s own initializer
  raised an uncaught assertion in
  `+[CLMonitor _requestMonitorWithConfiguration:locationManager:completion:]` on
  every single launch, three times in a row, unchanged by a fresh monitor
  identifier or a 500 ms delay before construction — ruling out stale on-disk
  state or a launch-timing race in LifeLog's own code. A Feedback Assistant
  report was filed with Apple 2026-08-21, referencing matching reports already on
  the Apple Developer Forums (threads 802143, 771001). `placeMonitoringDisabledPendingAppleFix`
  (`LocationRecorder.swift:855`) is the single flag to flip back once a build
  confirms it no longer reproduces; re-test on-device (install fresh, not over a
  prior build) before trusting it, the same way this bug was first found.

- [ ] **Find and eliminate the source of recurring duplicate sleep before removing
  `SleepSessionRepair`.** It has found duplicates after the original arrival-window
  bug was fixed, including around erase/restore and live Health sync. Serialize
  those operations or make Health sample ownership the idempotent import key. Keep
  the repair as a measured safety net until a test reproduces the race and the
  counter remains zero across real use.

## Distribution readiness — new priority

Concrete work that was explicitly out of scope while LifeLog was private-only.
The scope for now is a small TestFlight group, not a public App Store listing —
this is about a tester not being confused or losing trust in their own data, not
about marketing copy, ratings prompts, or broad-market onboarding.

- [ ] **Confirm the Xcode Cloud release workflow is reliably distribution-clean.**
  The Archive action's Distribution Preparation and the TestFlight Internal
  Testing post-action are configured and have shipped one build successfully
  (2.25.11); worth a second confirmed clean build before trusting that
  pipeline, since the first attempts hit both a missing Distribution
  Preparation setting and a missing `NSHealthUpdateUsageDescription` key.

## Efficiency and tidiness — still open

A code-first audit on 2026-08-20. These are ranked interaction-path and ownership
improvements, not a request for blanket rewrites or cosmetic file splitting.

- [ ] **Continue splitting `LocationRecorder` at its existing component seams.**
  Five seams moved out 2026-08-22, each behind the same boundary: the
  recorder still decides what a result means and performs the Visit
  mutation, the collaborator only owns the mechanics.
  `ArrivalConfirmationSession` (the live-location burst's samples, pending
  arrival, task lifecycle, waiters -- previously five stored properties
  mutated from four methods); `GeofenceMonitor.plan(wanted:monitoredIdentifiers:)`
  (a pure diff extracted from `refreshMonitoredRegions`'s inline add/remove
  loop); `LocationServiceSessionController` (the `CLServiceSession` that
  keeps Core Location delivering, its diagnostic stream, and the generation
  bookkeeping that stops a just-replaced session's stream-ended callback
  from clearing its successor -- previously four stored properties:
  `serviceSession`, `serviceSessionRequirement`, `serviceSessionGeneration`,
  `diagnosticTask`); `SavedPlaceCache` (the in-memory Saved Place fetch, its
  keep-previous-on-failure behaviour, and the nearest-match lookup
  `createVisit`/`closeVisit`/`identifyPlace` all read inline -- previously a
  bare stored array reloaded and read directly from six places); and
  `PlaceLookupService.reverseGeocode(at:)` (the `MKReverseGeocodingRequest`
  call and raw name extraction, returning a three-case outcome --
  `.resolved`/`.notFound`/`.unavailable` -- so the recorder's existing
  three-way handling of "found a name," "found nothing," and "MapKit
  couldn't even build the request" carried over exactly). The full arrival/
  incremental-resolution suite, plus new unit tests for each collaborator
  testable without live Core Location/MapKit, passed unmodified after every
  step; reverse geocoding has no new tests, matching `PlaceLookupService.
  nearbyPlaces`'s existing untested status -- both need a live MapKit
  response that isn't mockable, so this is a pre-existing gap the split
  didn't create or close.
  At ~1,125 lines (up slightly from splitting out `reverseGeocode`'s
  three-way switch, though its actual MapKit surface area left the file) the
  recorder still owns delegate adaptation, raw evidence, visit mutation,
  Wi-Fi sampling, and diagnostics. Visit mutation (`createVisit`,
  `closeVisit`, `closeMonitoredVisit`) is what remains as the one large
  seam, and the most entangled with everything already extracted (Saved
  Place lookup, place identification, and Wi-Fi anchoring all happen inline
  in `createVisit`) -- likely the last and hardest piece.

## Deliberately not priorities

- Public App Store marketing, ratings/review prompts, broad-market accessibility
  localization, and other public-listing-specific work — in scope once TestFlight
  distribution to trusted testers is solid, not before.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, and the recording-quality/routine insights above.
