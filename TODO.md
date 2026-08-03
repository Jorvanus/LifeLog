# LifeLog — four-week roadmap

This plan prioritises a dependable private diary on a physical iPhone before expanding automation or sync. Each week should end with a build that can remain installed and collect real data for the following week.

## Week 1 — prove the daily record

- [ ] Run a physical-iPhone test matrix for first launch, When In Use → Always authorization, background/foreground transitions, overnight use, relaunch, reboot, denied permission, and delayed `CLVisit` delivery. Record expected versus observed behavior without recording coordinates.
- [ ] Re-run the physical-device performance checklist with the latest 32,000-row archive and confirm no main-thread stall over 250 ms; keep only aggregate timings in Diagnostics.
- [ ] Expand the Insights UI regression test to tap several donut segments repeatedly, deselect the active segment, select Sleep, scroll away and back, and confirm the chart remains hittable.

## Week 2 — make Health and movement reliable

- [ ] Test Health permission denial, partial permission, no data, Apple Watch disconnected, duplicate samples, deleted samples, daylight-saving transitions, and unusual time zones.
- [ ] Expand movement classification for walking, running, cycling, automotive travel, and possible flights while preserving the location-first rule: movement inside Home, Work, or another destination must not become a separate timeline entry.
- [ ] Add recurring-trip tests for “Travelling to Work/Home,” including incomplete destinations and corrected place labels.

## Week 3 — improve correction and learning

- [ ] Extract Insights aggregation from the private SwiftUI view into a testable analysis engine. Cover overlapping visits, comparison windows, unlogged gaps, active visits, weekday rhythm, ignored records, and the 32,000-row fixture.
- [ ] Make inferred activities explainable: show the evidence used—saved place, Maps category, time of day, recurrence, device movement, or on-device model—and show confidence without presenting guesses as facts.
- [ ] Allow activity and category correction from Timeline and Insights, then verify the learned choice is reused for future visits while remaining editable.

## Week 4 — data ownership, privacy, and release polish

- [ ] Add deletion and retention controls for imported journals, Health/Motion activity, diagnostics, locations, and all app data. Display exact scope and make destructive actions explicit.
- [ ] Complete the privacy manifest and permission-copy review for Location, Motion, Health, Apple Maps lookup, Foundation Models, local diagnostics, backup, and retention behavior.
- [ ] Verify VoiceOver, Dynamic Type, Reduce Motion, contrast, landscape/iPad behavior, and dark/tinted Home Screen icons on iOS 27.
- [ ] Refresh README setup, behavior, Health import, diagnostics, backup, and current milestones so it matches the shipped app.

## Next review — UI, security, and efficiency

- [ ] Add a first-run privacy dashboard explaining Location, Health, Motion, Maps lookup, local backup, diagnostics, and retention in plain language with links to revoke each permission.
- [ ] Add explicit retention controls for imported journals, Health/Motion records, diagnostics, exports, and all app data; show counts and estimated storage before deletion.
- [ ] Add low-storage handling for imports, backups, and reports: preflight available space, show a recoverable error, and never delete source data on a failed export.
- [ ] Add UI tests for the new Diagnostics and Journal Storage screens, including backup failure, protected-file failure, empty history, Dynamic Type, VoiceOver, and dark mode.
- [ ] Improve current-activity artwork layout with asset bounds tests so transparent illustrations cannot enlarge or distort cards.
- [ ] Add import progress with cancel/retry and a post-import summary showing duplicates, malformed rows, compactable rows, and storage impact.
- [ ] Move Insights aggregation into a reusable actor/cache with invalidation on visit edits, imports, corrections, and HealthKit updates.
- [ ] Add an offline-only security review: file protection class, backup exclusion decisions, temporary-file permissions, redacted logs, and no sensitive data in crash breadcrumbs.
- [ ] Add a release checklist for iOS 27 device classes, fresh install, upgrade, migration, store recovery, backup restore, permission changes, and uninstall/reinstall behavior.

## Location and Maps efficiency review

- [ ] Add a persisted resolution state for location callbacks (provisional, resolved, superseded, ignored) with one data-layer resolver used by Timeline, Insights, Map, exports, and Saved Places backfill.
- [ ] Cache Apple Maps results by a privacy-preserving rounded grid cell and place category, with a short expiry; cancel stale lookups when a visit is corrected or superseded.
- [ ] Add a per-visit lookup cooldown and retry budget so repeated location updates cannot trigger repeated MapKit searches or reverse geocoding.
- [ ] Store only the top few MapKit candidates needed for correction, discard duplicate candidates, and cap candidate payload size before writing it to SwiftData.
- [ ] Avoid fetching every Saved Place for each location callback; maintain a bounded in-memory spatial index and refresh it only when Saved Places change.
- [ ] Add explicit confidence transitions: Maps match must not silently replace a user correction, and low-confidence reverse geocoding must remain clearly labelled.
- [ ] Add delayed/out-of-order Core Location fixtures with GPS drift, repeated callbacks, overlapping open visits, and Home → destination → Home return sequences.
- [ ] Add location retention controls: precise coordinates for a configurable period, rounded coordinates for older history, and a clear irreversible-delete scope.
- [ ] Add a “why this place?” detail showing Saved Place, Maps result, distance, recurrence, and confidence without exposing raw coordinates.
- [ ] Measure MapKit lookup latency, cache hit rate, callback-to-save latency, candidate payload size, and spatial-index refresh time using aggregate Diagnostics only.
- [ ] Review Apple Maps request policy and privacy copy; make lookup opt-out explicit and provide a manual-pin fallback that never requires network access.
- [ ] Scope location queries by date/window wherever possible and avoid loading imported journal rows or superseded callbacks into interactive views.

## Later — after the four-week foundation

- [ ] Add optional notes and photos with local file protection, storage limits, export/deletion support, and explicit privacy controls.
- [ ] Add read-only App Intents and Shortcuts such as “show coffee places I visited this week,” with permission-aware results and no background disclosure of sensitive places.
- [ ] Design optional encrypted iCloud sync only after local backup/restore and schema migrations are proven. Define conflict resolution, opt-in, recovery, deletion, and multi-device behavior before enabling CloudKit.
- [ ] Consider widgets or summaries only after their privacy behavior on the Lock Screen and shared devices is explicitly designed.
