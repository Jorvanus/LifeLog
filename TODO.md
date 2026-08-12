# LifeLog — current roadmap

Audited against `main` at `718c3ee` on 2026-08-12. This is an open-work list,
not a history of shipped features. Completed callback replay, resolver invariants,
conservative Saved Place learning, resolution diagnostics, sleep-evidence plumbing,
and the first archive-query pass have been removed.

LifeLog is a private app for one iPhone 17 Pro Max. Real-device correctness and a
responsive 32,000-row archive outrank App Store preparation and speculative features.

## Next three deliverables

1. [ ] **Prove the shipped sleep-evidence update on real hardware.** The app now
   rebuilds a complete affected night, waits to acknowledge Health observer delivery
   until import finishes, distinguishes measured sleep from estimated time in bed,
   and supports confirmed manual sleep. Run its deterministic suite when the Xcode 27
   beta services are healthy, then prove on the phone: Watch worn overnight, Watch not
   worn with an iPhone Sleep Schedule, no sleep source, delayed Watch sync, one deleted
   stage, a deleted night, and partial/denied Health access. Completion means one
   correct overnight entry, no duplicate in-bed card beside measured sleep, and a
   useful Settings/Diagnostics explanation for every case.

2. [ ] **Add archive search without putting notes on Timeline’s normal path.** Build
   one explicit search screen for place and activity, with note search as a slower
   opt-in mode. Reuse `VisitHistoryQuery`, add result limits/paging, and measure it on
   the 32,000-row archive. Decide from measurements whether normalized place, Maps ID,
   activity, and arrival-day fields need persisted indexes; do not attempt another
   schema migration merely because an index sounds useful. Completion means ordinary
   Timeline never fetches note text for search and a broad query cannot freeze the UI.

3. [ ] **Prove location quality and hardware behavior on real hardware.** LifeLog now
   detects reduced-accuracy location (the Precise Location toggle and a genuinely
   poor fix), shows it in Settings and Diagnostics, and an approximate fix no longer
   teaches a Saved Place or wins a fine-distance comparison against a better
   candidate. Run the existing hardware checklist with detailed diagnostics: named
   Saved Place arrival, geofence exit, Wi-Fi departure assistance, region ranking,
   noisy signal, repeated callback, and an outdoor continuous walk that must not
   satisfy the stationary fallback — including a real reduced-accuracy session to
   confirm Settings/Diagnostics reflect it correctly.

## Correctness and recovery

- [ ] **Audit cross-visit `DateInterval` construction.** `CommuteDetection` previously
  trapped when overlapping manual visits produced an end before a start. Inspect every
  interval built from two different visits, guard invalid ordering, and add overlapping
  manual-entry fixtures. Decide whether Add Visit should warn about or resolve overlaps
  rather than leaving every downstream calculation to defend itself.

- [ ] **Prove protected-store recovery on the phone.** After a successful foreground
  open, apply complete protection to the three store files, lock the phone, provoke a
  background save failure, then verify the pending failure appears after relaunch.
  Preserve the aggregate diagnostic evidence, never the personal store.

- [ ] **Validate a copied pre-versioned device store.** Synthetic V1–V7 migrations
  cover the declared schemas, but only a copy of the historical device store proves
  the real upgrade. Work on a copy and leave the original protected store untouched.

- [ ] **Make Home and Work explicit Saved Place roles.** Remove name-keyword discovery,
  migrate behavior without renaming the owner’s places, and then lock recurring-trip
  and commute semantics with tests. Location remains primary: movement inside a
  destination must never become a separate activity card.

- [ ] **Choose the Health re-import boundary.** Routine Health refresh is bounded and
  the manual re-import reads 30 days. If older workout routes matter, add a date-range
  import with progress, cancellation, retry, and a clear inserted/updated/deleted
  summary. Otherwise document 30 days as an intentional limit.

## Archive performance and storage

- [ ] **Finish the broad-query audit.** Most history-facing views are now bounded, but
  broad collections remain in Diagnostics, Settings, Places, and journal compaction.
  Classify each as bounded-by-retention, genuinely whole-store, or accidental. Replace
  accidental queries; for intentional whole-store tools, load on demand away from the
  interaction path and show progress.

- [ ] **Run the complete physical-phone budget after the sleep/data-shape changes.**
  Measure cold/warm launch, Timeline return from Insights/Settings/Visit Editor,
  Activities, day/week/month/year Insights, editor opening, and archive search. Keep
  aggregate timings only and investigate any main-thread interaction over 250 ms.

- [ ] **Protect exports and temporary files consistently.** Backups and reports need
  an explicit strong protection class, short expiry after sharing, low-storage
  preflight, and failure behavior that never deletes source records. Show count,
  estimated size, and irreversible scope before bulk deletion or compaction.

- [ ] **Add retention controls for sensitive local evidence.** Detailed callback
  diagnostics are opt-in and bounded, but still need automatic expiry plus clear
  count/size/delete controls for coordinates, Health/Motion-derived rows, imported
  journal data, diagnostics, exports, and all app data.

## Testability and diagnostics

- [ ] **Make MapKit lookup deterministic.** Inject the search transport and test cache
  expiry, cancellation, retry, bounded/deduplicated candidates, lookup opt-out, and
  manual-pin fallback without live Apple Maps.

- [ ] **Add visual regression coverage.** Current UI tests prove reachability, not
  layout. Capture approved light/dark screenshots at normal and Accessibility XXXL for
  Timeline rows, Place History, Visit Editor, Add Visit, Diagnostics resolution choices,
  sleep fallback, and the Insights donut.

- [ ] **Isolate UI-test preferences.** Seeded tests already use an in-memory store, but
  every app-owned `UserDefaults` marker also needs a scratch suite/reset so test order
  cannot change one-shot repairs, hardware evidence, or permission-facing state.

- [ ] **Calibrate thresholds from real traces.** Review several weeks before changing
  `walkingBurstGap`, passing-stay thresholds, journey absorption, or stationary-cluster
  values. Record the trace pattern and the deterministic fixtures changed by any new
  threshold.

- [ ] **Add a day investigation screen only if Diagnostics remains too fragmented.**
  Resolution choices and the callback journal are now inspectable without Timeline.
  If real debugging still requires manual cross-referencing, add a day view aligning
  callbacks, resolver decisions, and final stays. Mark any export as precise, sensitive
  location data.

## Product and UI follow-ups

- [ ] Replace internal confidence words (`Low`, `Medium`, `Learned`) with actionable
  states such as **Needs checking**, **Suggested**, and **Confirmed**. Hide badges that
  provide neither an action nor assurance.

- [ ] Reconcile `InsightSliceEditor` totals. Its header uses deduplicated segment time
  while rows show raw visit duration, so overlapping Home/Sleep records need either
  post-resolution row contributions or wording that does not imply the rows add up.

- [ ] Review the activity catalogue after real use: recently used, history-only, and
  unused labels are separated; confirm bulk adoption and icon/colour editing remain
  understandable beside activity history.

- [ ] Improve Insights only after the above evidence is trustworthy. Candidate work,
  in order: commute overhead after explicit Home/Work roles; focused Overview/Trends/
  Places sections; waking-life balance; exploration/novelty; dwell/focus duration.
  Insights must show its evidence and uncertainty rather than turning archive size into
  false confidence. Timeline micro-badges remain deferred after the first design made
  cards wrap badly.

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
