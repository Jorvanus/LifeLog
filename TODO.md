# LifeLog — four-week roadmap

This plan prioritises a dependable private diary on a physical iPhone before expanding automation or sync. Each week should end with a build that can remain installed and collect real data for the following week.

## Week 1 — prove the daily record

- [ ] Run a physical-iPhone test matrix for first launch, When In Use → Always authorization, background/foreground transitions, overnight use, relaunch, reboot, denied permission, and delayed `CLVisit` delivery. Record expected versus observed behavior without recording coordinates.
- [ ] Establish performance budgets using the full 32,000-row Life Cycle archive: responsive first screen, no main-thread stall over 250 ms during normal interaction, and bounded day/month/year Insights loading. Add a repeatable device checklist and retain aggregate timings in Diagnostics.
- [ ] Add deterministic UI-test seed data so Timeline, current location, uncategorised locations, Saved Places, Map, Sleep, and every donut interaction can be exercised without depending on live sensors.
- [ ] Expand the Insights UI regression test to tap several donut segments repeatedly, deselect the active segment, select Sleep, scroll away and back, and confirm the chart remains hittable.
- [ ] Make the current location the first visually distinct card in Today’s Journey, including elapsed time and a “waiting for visit confirmation” state before Core Location delivers a formal visit.
- [ ] Add an explicit store-opening recovery path: preserve the protected store, show actionable diagnostics, allow export/recovery where possible, and never require deleting the app as the first remedy.
- [x] Introduce a versioned SwiftData schema and documented migration tests before adding another persisted field. Cover opening a copy of the current on-device schema and upgrading it without data loss.

## Week 2 — make Health and movement reliable

- [x] Move HealthKit and Motion ingestion off the main interaction path using an isolated background model context/actor, small save batches, cancellation, and progress state in Settings.
- [ ] Replace repeated history reads with incremental HealthKit anchors. Import only new or changed sleep/workout samples, persist the anchor safely, and remain idempotent after relaunch.
- [ ] Add HealthKit observer/background delivery only after the incremental importer is proven not to freeze Timeline or Insights.
- [ ] Make sleep-session queries tolerant of date boundaries by padding the selected interval, grouping stage samples into one night, and clearly labelling the score as a LifeLog estimate rather than an Apple score.
- [ ] Test Health permission denial, partial permission, no data, Apple Watch disconnected, duplicate samples, deleted samples, daylight-saving transitions, and unusual time zones.
- [ ] Expand movement classification for walking, running, cycling, automotive travel, and possible flights while preserving the location-first rule: movement inside Home, Work, or another destination must not become a separate timeline entry.
- [ ] Add recurring-trip tests for “Travelling to Work/Home,” including incomplete destinations and corrected place labels.

## Week 3 — improve correction and learning

- [ ] Extract Insights aggregation from the private SwiftUI view into a testable analysis engine. Cover overlapping visits, comparison windows, unlogged gaps, active visits, weekday rhythm, ignored records, and the 32,000-row fixture.
- [ ] Make inferred activities explainable: show the evidence used—saved place, Maps category, time of day, recurrence, device movement, or on-device model—and show confidence without presenting guesses as facts.
- [ ] Allow activity and category correction from Timeline and Insights, then verify the learned choice is reused for future visits while remaining editable.
- [ ] Add editable category colours and use them consistently across the donut, Timeline, Map, Saved Places, exports, and accessibility labels.
- [ ] Finish historical backfill rules for corrected and ignored locations, with a preview of how many visits will change and an undo/recovery path.
- [ ] Replace the fragile arrival/coordinate-based ignored-location key with a stable identifier as part of the planned schema migration.
- [ ] Add RFC 4180-compatible CSV parsing for quoted commas, quotes, embedded line breaks, alternate encodings, and very large files; retain duplicate and malformed-row reporting.

## Week 4 — data ownership, privacy, and release polish

- [ ] Add a complete local backup/restore format covering visits, Saved Places, corrections, ignored state, activity/category definitions, and app preferences. Validate round-trip restoration into an empty test store.
- [ ] Add a compact-history preview for imported journals. Show record and storage savings for options such as keeping all data, merging equivalent adjacent entries, or removing old/short entries; require confirmation and export a backup before destructive cleanup.
- [ ] Add deletion and retention controls for imported journals, Health/Motion activity, diagnostics, locations, and all app data. Display exact scope and make destructive actions explicit.
- [ ] Bound diagnostic retention and add a shareable privacy-safe performance report containing only subsystem, duration, counts, app version, and device/OS class—never coordinates, place names, notes, or Health values.
- [ ] Clean up temporary CSV/JSON exports after sharing or expiry and test export failure, low-storage, and protected-file cases.
- [ ] Complete the privacy manifest and permission-copy review for Location, Motion, Health, Apple Maps lookup, Foundation Models, local diagnostics, backup, and retention behavior.
- [ ] Verify VoiceOver, Dynamic Type, Reduce Motion, contrast, landscape/iPad behavior, and dark/tinted Home Screen icons on iOS 27.
- [ ] Refresh README setup, behavior, Health import, diagnostics, backup, and current milestones so it matches the shipped app.

## Later — after the four-week foundation

- [ ] Add optional notes and photos with local file protection, storage limits, export/deletion support, and explicit privacy controls.
- [ ] Add read-only App Intents and Shortcuts such as “show coffee places I visited this week,” with permission-aware results and no background disclosure of sensitive places.
- [ ] Design optional encrypted iCloud sync only after local backup/restore and schema migrations are proven. Define conflict resolution, opt-in, recovery, deletion, and multi-device behavior before enabling CloudKit.
- [ ] Consider widgets or summaries only after their privacy behavior on the Lock Screen and shared devices is explicitly designed.

## Completed foundation

- [x] Map picker and Apple Maps local search for manual entries.
- [x] Uncategorised Locations and editable Saved Places in Settings, including reusable geofences.
- [x] Editable activities and reversible ignored locations.
- [x] Location-first suppression of walking/travel inside destinations.
- [x] Sleep stages and a clearly labelled LifeLog sleep estimate in Insights.
- [x] Repeated donut selection, focus, and deselection behavior.
- [x] Confidence and correction history for inferred places, activities, and recurring trips.
- [x] Weekday activity rhythm, period comparisons, and CSV/JSON trend export.
- [x] Privacy-safe diagnostics for Location, MapKit, HealthKit, Motion, imports, and performance.
- [x] Baseline UI/accessibility hooks for Timeline, Insights, Map, Settings, current-location labeling, and Saved Places.
- [x] Large-archive query scoping and batched Life Cycle import duplicate detection.
- [x] Fixture/fuzz coverage for overlaps, malformed samples, long histories, and unusual time zones.
