# LifeLog — current roadmap

Audited against `main` at `e4ce878` on 2026-08-14. This is an open-work list,
not a history of shipped features. Completed callback replay, resolver invariants,
conservative Saved Place learning, resolution diagnostics, sleep-evidence plumbing,
the first archive-query pass, the distinct Day/Week/Month/Year Insights layouts,
the explicit archive search screen, the Month/Week `InsightsView` split, and the
Insights data-access boundary have been removed.

LifeLog is a private app for one iPhone 17 Pro Max. A responsive 32,000-row archive,
clear code boundaries, and reliable local data outrank App Store preparation and
speculative features.

## Correctness and recovery

- [ ] **Remove `InsightsView`'s orphaned `standardLayout` and its dead sections.**
  The 2026-08-14 Month/Week split found `standardLayout` (and everything it alone
  reaches — `highlightsSection`, `awayFromHomeSection`, `activityChangesSection`,
  `trendsSection`, `weekdayPatternsSection`/`weekdayChart`/`weekdayChartSheet`,
  `habitsSection`, `trendLinesSection`, `topActivitiesSection`/`topPlacesSection`
  and their `InsightsActivitySelectionList`/`InsightsPlaceSelectionList` — plus
  `lifeAreaBalanceSection`) is never called from `body`; only Day/Week/Month/Year
  layouts render. Confirm each is genuinely unreachable (not a future layout
  mid-flight) before deleting, and check whether the weekday-chart feature was
  meant to still be reachable from somewhere — its `.sheet` binding is still wired
  at the top level with nothing left to trigger it.

- [ ] **Audit cross-visit `DateInterval` construction.** `CommuteDetection` previously
  trapped when overlapping manual visits produced an end before a start. Inspect every
  interval built from two different visits, guard invalid ordering, and add overlapping
  manual-entry fixtures. Decide whether Add Visit should warn about or resolve overlaps
  rather than leaving every downstream calculation to defend itself.

- [ ] **Complete protected-store recovery as a first-class code path.** Centralise the
  three-store-file protection policy, make pending-save recovery idempotent across
  relaunches, and ensure all failure reporting stays aggregate-only. Add deterministic
  fixtures for protected/unavailable files and interrupted recovery; avoid coupling the
  UI to raw store contents.

- [ ] **Choose the Health re-import boundary.** Routine Health refresh is bounded and
  the manual re-import reads 30 days. If older workout routes matter, add a date-range
  import with progress, cancellation, retry, and a clear inserted/updated/deleted
  summary. Otherwise document 30 days as an intentional limit.

## Archive performance and storage

- [ ] **Finish the broad-query audit outside Insights.** Diagnostics, Settings, Places,
  and journal compaction still need classification as bounded-by-retention, genuinely
  whole-store, or accidental. Replace accidental reads with a narrow predicate, paging,
  or an aggregate; for genuine whole-store tools, load on demand away from the interaction
  path and show progress. Do not add a schema index without measured evidence.

- [ ] **Make performance budgets executable regression checks.** Keep the existing
  diagnostic timings, but add repeatable archive fixtures and focused benchmarks for
  Timeline return, period Insights, editor opening, archive search, and export setup.
  Record aggregate timings only and investigate main-thread interaction over 250 ms.

- [ ] **Protect exports and temporary files consistently.** Backups and reports need
  an explicit strong protection class, short expiry after sharing, low-storage
  preflight, and failure behavior that never deletes source records. Show count,
  estimated size, and irreversible scope before bulk deletion or compaction.

- [ ] **Add retention controls for sensitive local evidence.** Detailed callback
  diagnostics are opt-in and bounded, but still need automatic expiry plus clear
  count/size/delete controls for coordinates, Health/Motion-derived rows, imported
  journal data, diagnostics, exports, and all app data.

## Code quality, navigation, and diagnostics

- [ ] **Make MapKit lookup deterministic.** Inject the search transport and test cache
  expiry, cancellation, retry, bounded/deduplicated candidates, lookup opt-out, and
  manual-pin fallback without live Apple Maps.

- [ ] **Make Insights navigation intentional and testable.** The tab-level navigation
  foundation is already modern (`Tab` and `NavigationStack`); do not rewrite it for style.
  Audit each Insights action by purpose: temporary edit/add flows may remain sheets, while
  browse-deeper flows (activity, place, life area, comparison) need a consistent route,
  reliable Back behaviour, and an escape back to the same period and scroll context.
  Reuse the existing Place History and Visit Editor rather than adding parallel screens.

- [ ] **Isolate UI-test preferences.** Seeded tests already use an in-memory store, but
  every app-owned `UserDefaults` marker also needs a scratch suite/reset so test order
  cannot change one-shot repairs, hardware evidence, or permission-facing state.

- [ ] **Move inference thresholds into named, documented policy.** Consolidate
  `walkingBurstGap`, passing-stay thresholds, journey absorption, and stationary-cluster
  values behind a small policy type with units and rationale. Keep deterministic fixtures
  alongside each threshold so a change states exactly which behaviours it intends to move.

- [ ] **Add a day investigation screen only if Diagnostics remains too fragmented.**
  Resolution choices and the callback journal are now inspectable without Timeline.
  If real debugging still requires manual cross-referencing, add a day view aligning
  callbacks, resolver decisions, and final stays. Mark any export as precise, sensitive
  location data.

## Product and UI follow-ups

- [ ] Replace internal confidence words (`Low`, `Medium`, `Learned`) with actionable
  states such as **Needs checking**, **Suggested**, and **Confirmed**. Hide badges that
  provide neither an action nor assurance.


- [ ] Review the activity catalogue after real use: recently used, history-only, and
  unused labels are separated; confirm bulk adoption and icon/colour editing remain
  understandable beside activity history.

- [ ] **Tighten the new Month review before extending Insights.**
  Month now has a comparison-led hero, changes, life-area balance, place stories, and a
  calendar drawn from the resolved segments. Make the evidence thresholds and empty/
  partial/source-filtered presentation rules explicit in `MonthlyInsights`, and ensure
  every place route reaches the existing history/editor surfaces while sleep remains
  separate from waking-life totals. Only then prioritise the next evidence-backed slice:
  commute overhead after explicit Home/Work roles, exploration/novelty, or dwell/focus
  duration. Do not convert archive volume into false confidence.

- [ ] Consider photos, read-only App Intents/Shortcuts, widgets, and multi-device sync
  only after local retention, deletion, backup, and recovery behavior is designed.

## Deliberately deferred

- **App Store release work.** Distribution metadata, public privacy policy, consumer
  deletion, release diagnostics, accessibility certification, and submission review
  form a separate programme if this stops being a private personal app.
- **A duplicate-label merge tool.** The archive audit did not find enough genuine
  duplicates to justify it; keep normalization and rename paths reliable.
- **Movement as primary place inference.** Health and Motion may resolve journeys but
  must not overrule trusted location evidence or create a place.
- **Persisting an Apple Maps place type.** It is an inference hint, not stable identity;
  retain Maps ID, candidates, provenance, and correction evidence instead.
- **A schema bump solely for `VisitCorrection.mapsIdentifier`.** First measure whether
  resolving the correction through its visit is sufficient. Schema risk needs a real
  correctness or performance benefit.
