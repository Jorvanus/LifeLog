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
- [x] Give movement records a route rather than a single coordinate. Done for Apple Health workouts (`Visit.routeData`, schema V3): the recorded GPS track is imported, simplified, drawn on a map, and used to decide whether a walk left a place. Still open: walks with no workout behind them, which would need LifeLog to sample locations itself — a real battery cost, deliberately not taken.
- [x] The route is also the only honest way to tell a loop around the block from pacing at home. Both are walking inside a stay Core Location never closed, so duration cannot separate them; treating the walk as a departure invents an arrival the person never made. Resolved for workout-backed walks: `ActivityLocationPolicy.leftStay` measures the farthest point of the path from the stay. Movement with no route still stays absorbed.

## Week 3 — improve correction and learning

- [ ] Extract Insights aggregation from the private SwiftUI view into a testable analysis engine. Cover overlapping visits, comparison windows, unlogged gaps, active visits, weekday rhythm, ignored records, and the 32,000-row fixture.
- [x] Make inferred activities explainable: show the evidence used—saved place, Maps category, time of day, recurrence, device movement, or on-device model—and show confidence without presenting guesses as facts.
- [x] Allow activity and category correction from Timeline and Insights, then verify the learned choice is reused for future visits while remaining editable.

## Week 4 — data ownership and personal-device reliability

- [ ] Add deletion and retention controls for imported journals, Health/Motion activity, diagnostics, locations, and all app data. Display exact scope and make destructive actions explicit.
- [ ] Keep the privacy manifest and permission copy accurate for the personal-device build, without expanding into App Store compliance work yet.
- [ ] Prioritise iPhone layout, Dynamic Type, and dark mode regressions that affect the owner’s device; defer broad iPad and accessibility certification until distribution is planned.
- [ ] Refresh README setup, behavior, Health import, diagnostics, backup, and current milestones so personal testing remains repeatable.

## Next review — personal quality and speed

- [ ] Add a simple settings summary for permissions, data sources, storage, and diagnostics; defer generalized privacy onboarding until store distribution is considered.
- [ ] Add explicit retention controls for imported journals, Health/Motion records, diagnostics, exports, and all app data; show counts and estimated storage before deletion.
- [ ] Add low-storage handling for imports, backups, and reports: preflight available space, show a recoverable error, and never delete source data on a failed export.
- [ ] Add UI tests for the new Diagnostics and Journal Storage screens, including backup failure, protected-file failure, empty history, Dynamic Type, VoiceOver, and dark mode.
- [x] Improve current-activity artwork layout with asset bounds tests so transparent illustrations cannot enlarge or distort cards.
- [ ] Add import progress with cancel/retry and a post-import summary showing duplicates, malformed rows, compactable rows, and storage impact.
- [x] Move Insights aggregation into a reusable actor/cache with invalidation on visit edits, imports, corrections, and HealthKit updates.
- [ ] Add a practical on-device data-safety review: file protection, backup scope, temporary-file permissions, and an explicit switch for detailed personal diagnostics.
- [ ] Add a personal-device regression checklist for fresh install, upgrade, migration, store recovery, backup restore, permission changes, and relaunch.

## Location and Maps efficiency review

- [x] Add a persisted resolution state for location callbacks (provisional, resolved, superseded, ignored) with one data-layer resolver used by Timeline, Insights, Map, exports, and Saved Places backfill.
- [x] Cache Apple Maps results by a privacy-preserving rounded grid cell and place category, with a short expiry; cancel stale lookups when a visit is corrected or superseded.
- [ ] Add a per-visit lookup cooldown and retry budget so repeated location updates cannot trigger repeated MapKit searches or reverse geocoding.
- [ ] Store only the top few MapKit candidates needed for correction, discard duplicate candidates, and cap candidate payload size before writing it to SwiftData.
- [x] Avoid fetching every Saved Place for each location callback; maintain a bounded in-memory spatial index and refresh it only when Saved Places change.
- [x] Add explicit confidence transitions: Maps match must not silently replace a user correction, and low-confidence reverse geocoding must remain clearly labelled.
- [ ] Add delayed/out-of-order Core Location fixtures with GPS drift, repeated callbacks, overlapping open visits, and Home → destination → Home return sequences.
- [ ] Add location retention controls: precise coordinates for a configurable period, rounded coordinates for older history, and a clear irreversible-delete scope.
- [ ] Add a “why this place?” detail showing Saved Place, Maps result, distance, recurrence, and confidence without exposing raw coordinates.
- [x] Measure MapKit lookup latency, cache hit rate, callback-to-save latency, candidate payload size, and spatial-index refresh time using aggregate Diagnostics only.
- [ ] Review Apple Maps request policy and privacy copy; make lookup opt-out explicit and provide a manual-pin fallback that never requires network access.
- [ ] Scope location queries by date/window wherever possible and avoid loading imported journal rows or superseded callbacks into interactive views.

## High-priority location correctness

- [x] Match every `CLVisit` departure to the correct stored arrival using callback coordinate, arrival ordering, and overlap state; never blindly close the latest visit when delayed callbacks arrive out of order.
- [ ] Treat one-shot `requestLocation` fixes as provisional evidence only. Promote them to resolved visits after dwell time, a matching `CLVisit`, a Saved Place geofence match, or repeated stationary samples.
- [ ] Run the location resolver immediately after every arrival, departure, correction, Saved Place edit, and app relaunch so the store always maintains one deterministic current visit.
- [ ] Add a location-event journal for personal diagnostics containing callback type, callback/arrival/departure times, coordinate, accuracy, distance from current visit, chosen resolution transition, and related visit identifier.
- [ ] Add a “Location Debug” screen that shows the raw callback sequence beside the resolved Timeline, with actions to export the detailed report and rerun resolution without deleting raw data.
- [ ] Record why a callback was merged, superseded, closed, or promoted, and include MapKit cache hit/miss, query radius, candidate names/distances/categories, selected result, and fallback reason.
- [ ] Add an optional high-detail diagnostics mode for personal testing. Keep it off by default, automatically expire detailed location records, and clearly mark exports as containing personal location data.
- [ ] Add deterministic replay tests for departure-before-arrival delivery, repeated arrival callbacks, coordinate drift, stale one-shot fixes, overlapping geofences, missing departures, relaunch while a visit is open, and Home → destination → Home.
- [ ] Add invariants checked after each resolution pass: at most one current resolved location, no resolved location overlap, no negative duration, no superseded visit in Timeline/Insights, and no user correction overwritten by automation.

## Apple data auto-population

- [ ] Build one place-scoring pipeline combining Saved Place geofence, Apple Maps POI distance/category, dwell duration, horizontal accuracy, recurrence, time of day, and prior corrections; store the score breakdown for later inspection.
- [ ] Prefer Saved Places before making a Maps request, then reuse rounded-cell Maps results and reverse geocoding only as a fallback. Show which Apple source supplied each field.
- [ ] Do not permanently create a Saved Place from one high-confidence Maps result. Require a correction, repeated visits, or a configurable confidence streak before learning it as reusable.
- [ ] Learn aliases for GPS drift around large venues so multiple nearby Apple Maps pins resolve to one Saved Place without merging genuinely separate businesses.
- [ ] Refresh unresolved visits when better Apple Maps information becomes available, while preserving the original candidates and never replacing a confirmed user choice.
- [x] ~~Use Apple Maps category plus visit time to suggest activities…~~ Superseded: LifeLog no longer stores a place type. The Maps point-of-interest wording is now a transient inference hint only, and place identity is the place name.
- [x] Groups are editable in their own right: Settings → Groups lists each group with its activities, and adding, renaming (carrying activities) and deleting (falling back to "Other") are all available. Still open: moving several activities into a group at once, and wiring up the half-built `saveCategoryColor` so Insights uses a colour chosen per group.
- [ ] Add a review queue ranked by confidence and impact: current unresolved location first, then long-duration unknown visits, repeated unknown coordinates, and low-confidence Maps matches.
- [ ] Show nearby Apple Maps alternatives with distance and category when editing a visit or Saved Place, and remember the selected Apple Maps identifier/alias where the API permits.
- [ ] Add a bounded in-memory Saved Place spatial index and rounded-cell Maps cache so callbacks do not repeatedly fetch every place or contact Maps for the same area.
- [x] Add aggregate and detailed diagnostics for callback-to-resolution time, Maps latency, cache hit rate, candidate count, Saved Place match distance, resolver repairs, and incorrect suggestions later corrected by the user.

## Review — 2026-08-05 full pass

Findings from a complete read of the project. Ordered by whether they can bite you,
not by effort.

### Correctness — small changes, real consequences

- [ ] `LocationRecorder.lookupIDs` grows for the life of the process. Entries are only removed by `cancelPlaceLookup`, which nothing calls, so every place lookup leaves one behind. Worse, the keys are `ObjectIdentifier`s of SwiftData objects: once a visit is deallocated the address can be reused, so a stale entry can collide with a new visit and cancel the wrong lookup. Key the map on the visit's persistent identifier and clear it in the same `defer` that clears `identifyingVisits`.
- [ ] `loadSavedPlaceCache` swallows a failed fetch and leaves the cache empty. If the protected store is locked when a background callback arrives, every Saved Place silently disappears: arrivals at Home are treated as unknown, a Maps lookup runs, and "Identifying…" visits are created at places LifeLog already knows. Distinguish "no saved places" from "could not read them", keep the previous cache on failure, and record a diagnostic.
- [ ] A failed background save only sets `lastError`, which lives in memory and is gone after relaunch. An overnight failure leaves no trace at all. Record save failures to Diagnostics so they survive a restart.
- [ ] `SavedPlaceLearning.preview` and `applyIgnored` still fetch every `Visit` in the archive. The bounding-box work covered `upsert` and `apply` but missed these two, and both run from the Saved Place editor against 25,000 rows.

### Dead code

- [ ] Remove four functions nothing calls: `ActivitySampleReader.workoutRecords` (superseded by `anchoredWorkoutRecords`), `LocationRecorder.cancelPlaceLookup`, `PlacesView.locationRow`, and `saveCategoryColor(_:forCategory:)`. Removing `cancelPlaceLookup` should be done together with the `lookupIDs` fix above, since it is the only place that cleanup currently lives.

### Activity vocabulary — follow-ups from the 2026-08-05 work

- [ ] The seeded `Working` entry shadows an adopted `Work`. `preferredLabel` tries an exact match first, and `Working` matches the seed exactly, so it never reaches the stem rule that would find `Work`. Inference therefore still writes `Working` — the case the change was meant to fix — until the seeded entry is renamed or removed. Renaming it now offers to carry its 5 visits across, so that is the cheapest fix; longer term, consider reconciling seeded activities against real usage on first run, or preferring the label the timeline actually uses when both exist.
- [ ] `ActivityCatalog.category(for:)` checks a hardcoded switch before the catalogue, so seeded names keep their group even after deletion while adopted ones lose theirs. That is why deleting `Eating` is harmless and deleting `Work` moves 2,732 visits to "Other". The asymmetry is invisible and arbitrary: either drop the switch and let the catalogue be the single source, or keep it and say so where it matters.
- **Not worth building** — a merge tool for duplicate activity labels. Across 77 labels in a real archive there is exactly one near-duplicate pair (`Work` and `Working`), covered by the rename above.

### Repository process

- [ ] `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` have not moved since build 6 / 1.1.0, across roughly seven commits. `AGENTS.md` asks for a build increment before each commit and a semantic marketing bump. Decide the version this run should land on and set it in `project.yml`, which is the source of truth.
- [ ] Run the full UI suite before committing, not just the test being worked on. Scoping to a single test to save time let a broken editor test sit unnoticed for two commits: moving "Add from your history" to the top of the Activities list changed which row `cells.firstMatch` selects, and only the new test was re-run afterwards.
- [ ] `project.yml` is the real project definition and recent files were added by hand-editing `project.pbxproj` instead. `sources: [LifeLog]` is a directory glob so nothing was lost, but the two can drift. XcodeGen is not installed on this Mac, so either install it or note explicitly that the checked-in `project.pbxproj` is now authoritative.

### Living with nine years of data

The archive is 25,558 visits spanning 2017-05-06 to 2026-08-04, and grows by roughly
2,000–4,000 a year. Several parts of the app still assume a small, recent dataset.

- [ ] Timeline only ever shows today. There is no way to open a past day, so nine years of history is only reachable through Insights aggregates. Add date navigation, or a "jump to date", so the journal can actually be read as a journal.
- [ ] There is no search anywhere except the Place History screen. "When did I last go to X" and "what did I do the week before the trip" are unanswerable. A single search over place name, activity, and note would make the archive usable.
- [ ] 155 visits carry a note and nothing surfaces them. Notes are invisible unless the exact visit is opened. Consider listing them, including them in search, and showing an indicator on Timeline cards.
- [ ] Consider retrospectives that only make sense with this much history: this day in previous years, first and last visit to a place, longest gap since a place, year-over-year comparisons.

### Apple APIs worth adopting — both checked against the iOS 27 SDK

- [ ] `CLMonitor` with `CLCircularGeographicCondition` is available and unused. Saved Places are currently recognised by measuring distance from a `CLVisit` after the fact, which is why Home arrivals wait for a delayed callback and can be misidentified by Maps in the meantime. Real geofence entry and exit would identify known places immediately and without a Maps request. iOS caps monitored regions at 20, so prioritise by recency or frequency if Saved Places ever outgrow that.
- [ ] `MKMapItem.identifier` exists from iOS 18 and is unused. Places are matched by normalised name, which cannot distinguish two businesses with the same name and breaks on a spelling change. Storing the Maps identifier alongside the name would give stable identity, and directly serves the existing "remember the selected Apple Maps identifier" item.

- [ ] `PlaceLookupService` cannot be tested without a live `MKLocalSearch`, and its cache is private, so the negative-result caching fix above landed without a test. Injecting the search (a closure or small protocol, defaulted to the real one) would make the cache, the expiry split, and the cancellation paths testable.

### Backup and export safety

- [ ] A backup is complete personal history — every coordinate, note, and place name — written as plain JSON to the temporary directory and then shared wherever the person chooses. The current backup is sitting unencrypted in iCloud Drive. Offer an optional passphrase, or at least warn plainly at the moment of sharing what the file contains.
- [ ] Export and backup writes use `.atomic` without an explicit protection class. The default-data-protection entitlement should cover them, but a personal-history file is worth setting `.completeFileProtection` on explicitly rather than inheriting it.
- [ ] Staged export files live in the temporary directory for up to 24 hours. Consider shortening that, or clearing them as soon as the share sheet is dismissed.

### Insights aggregation

- [ ] `InsightsSnapshot` is `private` inside a 1,335-line view and carries roughly 230 lines of segmentation, slicing, comparison, and weekday logic with **no test coverage at all**. This is the largest untested surface in the project and already appears under Week 3. Extracting it would also let the 25,000-row archive be used as a fixture.
- [ ] `TrendsView` is 1,335 lines and `TimelineView` 1,053. Both mix aggregation, presentation, and editing. Splitting the editors out would make each readable without changing behaviour.

### Inference — sequencing agreed on 2026-08-05

- [ ] **First, clean the history.** 95% of named history is bulk-imported journal, and its labels are whatever Life Cycle defaulted to. 26 place names hold 10,756 entries, so most of the corpus is a few dozen corrections away from being trustworthy. Use the new Place History screen.
- [ ] **Then run "Add from your history"** in Activities. 17% of the archive currently groups as "Other" in Insights, including 2,732 `Work` visits that show as 5. Grouping is computed rather than stored, so adopting the activities re-buckets that history immediately.
- [ ] **Then infer from past behaviour**, keyed on place *and* time band rather than place alone. The evidence for conditioning is strong: a home address is 92% `Sleeping` between midnight and 06:00 and 99% `At home` between 11:00 and 22:00, so place alone would be wrong roughly half the time. Weight corrections and LifeLog-entered activity heavily and imported values lightly — frequency in imported data measures what was never fixed, not what was true.
- **Decided against, with evidence** — feeding motion and HealthKit into place inference. Of 605 device records only 103 overlap a named place, 94 of those already have a keyword-matchable name, and the remaining 9 are walking records against places labelled Eating and Donate Blood, where the signal would mislead. Revisit only if automatic visits start producing many unnamed places.
- **Decided against** — standalone time-of-day inference. Unconditioned it is close to useless; conditioned on place it is decisive, which is the item above.

## Later — after the four-week foundation

- [ ] Add optional notes and photos with local file protection, storage limits, export/deletion support, and explicit privacy controls.
- [ ] Add read-only App Intents and Shortcuts such as “show coffee places I visited this week,” with permission-aware results and no background disclosure of sensitive places.
- [ ] Design optional encrypted iCloud sync only after local backup/restore and schema migrations are proven. Define conflict resolution, opt-in, recovery, deletion, and multi-device behavior before enabling CloudKit.
- [ ] Consider widgets or summaries only after their privacy behavior on the Lock Screen and shared devices is explicitly designed.
