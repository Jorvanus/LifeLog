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

- [ ] **`extendStay` cannot tell "still getting ready" from "already gone" apart,
  and a real commute got shrunk from ~21 minutes to a displayed 7 as a result.**
  Confirmed against the real archive 2026-08-21/22: Core Location logged
  `geofence-exit` and `visit-departure` for Home at 08:26:24/08:27:08 (raw
  samples then show steady movement to 9.4 km away by 08:41), but the Home
  `Visit`'s persisted departure reads 08:40:31 -- matching a `health-walking`
  record that starts then. `extendStay` (`ActivityLocationPolicy+Journeys.swift:96`)
  reached Home's departure forward across the entire real drive because nothing
  in `stays`/`activities` occupied the gap, which is the *only* evidence it ever
  consults. The same pattern, same ~13-14 minute gap, is also the shape of the
  legitimate case already covered by
  `OverlapResolutionTests.stayHoldsUntilTheWalkThatLeftIt` (Home closed
  2026-08-08 07:02:44, a `health-workout` walk began 07:16:22, and extending was
  correct -- they really were still home). A same-source-type, same-duration fix
  attempted 2026-08-22 (excluding all HealthKit-sourced movement from
  `extendStay`) was reverted before landing because it cannot tell these two
  cases apart either -- it would have silently broken the tested, correct case
  to fix the broken one. Neither `health-walking` nor `health-workout` records
  carry coordinates, so the source type alone is not enough signal.
  **Design sketch for a real fix, not yet started:**
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

- [ ] **Seven pre-existing unit test failures, surfaced 2026-08-22 and not yet
  investigated.** The `LifeLogTests` target could not compile at all before
  2026-08-22 (a Swift 6.3.3 SILGen crash on a keypath over `[any
  VersionedSchema.Type]` in `SchemaFingerprintTests.swift`, now fixed with an
  explicit closure in place of the keypath literal), so nobody could see these.
  None touch anything changed that day; each needs its own look:
  1. `ActivityMergeTests.seedingStabilizesLoadIDs()` --
     `ActivityCatalog.load().first { $0.name == "Work" } → nil`
     (`ActivityMergeTests.swift:124`): seeding isn't producing a "Work" entry
     repeated `load()` calls can find.
  2. `ArchiveModelFieldCoverageTests.fullArchiveRoundTrips()` --
     `(decoded.version → 4) == 3` (`ArchiveModelFieldCoverageTests.swift:209`):
     either a real round-trip bug or a fixture left at the previous schema
     version after an unrelated bump -- worth checking which before assuming
     either.
  3. `ExportFileStagingTests.writesProtectedStagingFile()` --
     `attributes[.protectionKey] as? FileProtectionType → nil` where `.complete`
     was expected (`ExportFileStagingTests.swift:18`): could be a real
     regression in the staging write, or the simulator/sandbox here not
     reporting file protection classes the way a device does -- needs a device
     check before concluding either way.
  4. `GapSuggestionViewModelTests.sleepWalkingWorkoutOffersHomeWithoutAppleIntelligence()`
     -- "Expected a Home draft, got .idle" (`GapSuggestionViewModelTests.swift:102`):
     the short Sleep-to-walking-workout gap case that should bypass Apple
     Intelligence and still offer Home is instead resolving to no suggestion.
  5. `LocalBackupTests.negativeAccuracyLocationEventRestores()` -- restoring a
     backup throws `NSCocoaErrorDomain Code=259 "the file couldn't be opened
     because it isn't in the correct format"` (`LocalBackupTests.swift:344`):
     the fixture this test builds to prove a negative-accuracy location event
     survives restore may itself be malformed, or restore is rejecting
     something it shouldn't.
  6. `TravelConstructionTests.commutesRequireBothEnds()` --
     `(shopsToWork.first?.start → 09:00:00) == (shops.departure → 09:25:00)`
     (`TravelConstructionTests.swift:345`): a constructed commute's start time
     doesn't match the departure it should be anchored to.
  7. `VisitMutationServiceTests.failedMutationDoesNotPublishPartialState()` --
     `(original.placeName → "Unsaved replacement") == "Home"`
     (`VisitMutationServiceTests.swift:79`): a failed mutation's rollback is
     leaving the replacement name visible instead of restoring "Home", which
     is exactly the partial-state leak this test exists to catch.
  Separately, the `LifeLogUITests` target reported 36 of 60 tests failing in
  the same run, spread across every unrelated screen (Accessibility, Insights,
  Settings, Timeline) with generic "element didn't appear" failures -- that
  breadth points at the sandboxed simulator session lacking something a real
  run needs (permission state, animation timing), not 36 independent
  regressions. Re-run on-device or in a normal interactive simulator session
  before trusting that count.

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

- [x] **"One thing from today" showed "5h 27m more on sleep — Compared with the
  previous day" when the honest comparison was "1h 33m less."** Root cause found
  and fixed 2026-08-22, confirmed against a fresh backup/screenshot pair taken at
  the same moment (`LifeLog-Backup-1787354271.json`, 09:17:51). Not the
  categorisation pipeline, the elapsed-window pairing, or `DayHighlight`/
  `InsightsSnapshot`'s comparison math — all three were already confirmed sound
  in the prior investigation pass, and `highlightKey`'s staleness
  (`InsightsView.swift`, fixed earlier the same day) was real but not sufficient
  on its own. The actual bug was one layer up, in `InsightsPeriodLoader.reload`'s
  SwiftData fetch: its predicate was `visit.arrival >= fetchStart && visit.arrival
  < fetchEnd`, but `InsightsSnapshot.makeSegments` selects and clips candidates
  with `Visit.overlaps` (`arrival < range.end && (departure ?? now) > range.start`)
  — a *laxer* lower bound that also admits a visit whose `arrival` predates the
  range but that hadn't departed yet by the time the range started. The manual
  sleep entry for the previous night (2026-08-20 23:46 → 07:00 local) arrived 14
  minutes before the previous comparison window's own midnight boundary, so the
  fetch dropped it entirely — not clipped, *absent*. `makeComparisons` then read
  the previous period's missing "Sleep" category as `0` rather than the ~7h it
  actually was, so `delta = 5.443 - 0 = +5.443h`, and the sign flipped from "less"
  to "more" because the previous total didn't shrink, it vanished. The existing
  "active visit supplement" query already patched this exact class of bug for a
  still-*open* multi-day stay (`departure == nil`); it just never covered a
  *completed* visit straddling the same boundary. Generalized that supplement's
  predicate to `visit.arrival < fetchStart && (visit.departure ?? farFuture) >
  fetchStart` (`InsightsPeriodLoader.swift`) — matching `Visit.overlaps`'s
  semantics exactly, for either an open or a completed visit. Note: SwiftData's
  `#Predicate` macro cannot translate a forced-unwrap (`departure! > fetchStart`)
  to SQL and throws `unsupportedPredicate` at fetch time; the surrounding `catch`
  swallowed that silently on the first attempt, so the fetch never actually
  changed until the predicate was rewritten with `??` instead. Regression test:
  `LifeLogTests/InsightsPeriodLoaderTests.swift` — inserts a completed visit
  straddling a fetch boundary into an in-memory `ModelContainer`, confirmed to
  fail against the pre-fix predicate and pass against the fix.

## Distribution readiness — new priority

Concrete work that was explicitly out of scope while LifeLog was private-only.
The scope for now is a small TestFlight group, not a public App Store listing —
this is about a tester not being confused or losing trust in their own data, not
about marketing copy, ratings prompts, or broad-market onboarding.

- [ ] **Distinguish "still syncing" from "confirmed nothing" for Health data,
  starting with sleep.** Found 2026-08-22: HealthKit repeatedly returned zero
  sleep samples across several queries right after wake-up (`Sleep evidence
  rebuilt: 0 measured, 0 in-bed session(s)`, logged from
  `ActivityDataService.swift`), because the Watch's overnight sleep hadn't
  finished syncing to the phone yet — the same data appeared correctly a few
  minutes later, confirmed against the Health app directly. The owner knew to
  wait; a first-time tester won't, and Settings' "Add sleep manually" prompt
  ("What can this add? A sleep entry when Apple Health has no usable sleep
  evidence") is sitting right there inviting exactly the wrong move at exactly
  the wrong moment — a manual entry that becomes a duplicate once the real
  Watch data lands. Needs a distinct UI state for "checked recently and found
  nothing yet" versus "confirmed empty after a reasonable wait," so the
  manual-entry prompt doesn't fire during the plausible sync window. Directly
  related to the duplicate-sleep item above: this removes one more source
  feeding that bug, not just a symptom next to it.

- [ ] **Write a real privacy policy and host it somewhere linkable.** TestFlight
  external testing requires a privacy policy URL for Apple's Beta App Review,
  even for a small group. Needs to accurately describe what LifeLog actually
  does: on-device-only storage, no server, exactly what Health/Location/Motion
  data it reads and why, and that diagnostics are redacted by default (already
  true, see the 2026-08-20 changelog entry) but can include real personal data
  when someone explicitly turns on detailed diagnostics for their own
  troubleshooting.

- [ ] **Audit UI copy and defaults for "the owner already knows this"
  assumptions.** Look for onboarding gaps, permission-request copy, and error
  states written for someone who already understands why LifeLog wants Always
  location, or why sleep might briefly show as missing (see above). A focused
  pass through first launch, the permission-request flow, and Settings —
  not the whole app at once.

- [ ] **Confirm the Xcode Cloud release workflow is reliably distribution-clean.**
  The Archive action's Distribution Preparation and the TestFlight Internal
  Testing post-action are configured and have shipped one build successfully
  (2.25.11); worth a second confirmed clean build before trusting that
  pipeline, since the first attempts hit both a missing Distribution
  Preparation setting and a missing `NSHealthUpdateUsageDescription` key.

## Efficiency and tidiness — still open

A code-first audit on 2026-08-20. These are ranked interaction-path and ownership
improvements, not a request for blanket rewrites or cosmetic file splitting.

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

- Public App Store marketing, ratings/review prompts, broad-market accessibility
  localization, and other public-listing-specific work — in scope once TestFlight
  distribution to trusted testers is solid, not before.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, and the recording-quality/routine insights above.
