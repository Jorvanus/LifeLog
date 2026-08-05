# LifeLog — what's next

Rewritten 2026-08-06 after a cleanup pass. Everything that had actually shipped
has been removed rather than left ticked, so this file is only open work. Items
carrying a number from the 2026-08-05 archive review (25,558 visits, 2017-05-06
to 2026-08-04) say so — those figures were measured then, not re-measured now.

LifeLog is a private app for one iPhone 17 Pro Max. Judge layout, performance and
Dynamic Type at that size. Nothing here is App Store readiness work.

---

## Now — small changes, real consequences

- [ ] `LocationRecorder.loadSavedPlaceCache` swallows a failed fetch and leaves the cache empty. If the protected store is locked when a background callback arrives, every Saved Place silently disappears: arrivals at Home are treated as unknown, a Maps lookup runs, and "Identifying…" visits are created at places LifeLog already knows. Distinguish "no saved places" from "could not read them", keep the previous cache on failure, and record a diagnostic.
- [ ] A failed background save only sets `lastError`, which lives in memory and is gone after relaunch. An overnight failure leaves no trace at all. Record save failures to Diagnostics so they survive a restart.
- [ ] `SavedPlaceLearning.preview` and `applyIgnored` still fetch every `Visit` in the archive. The bounding-box work covered `upsert` and `apply` but missed these two, and both run from the Saved Place editor against 25,000 rows.
- [ ] The seeded `Working` entry shadows an adopted `Work`. `preferredLabel` tries an exact match first, and `Working` matches the seed exactly, so it never reaches the stem rule that would find `Work`. Inference therefore still writes `Working` — the case the change was meant to fix. Renaming the seeded entry offers to carry its visits across, so that is the cheapest fix.
- [ ] `ActivityCatalog.category(for:)` checks a hardcoded switch before the catalogue, so seeded names keep their group even after deletion while adopted ones lose theirs. That is why deleting `Eating` is harmless and deleting `Work` moved 2,732 visits to "Other". Either drop the switch and let the catalogue be the single source, or keep it and say so where it matters.

## Location accuracy

The part of the app that has to be right. Most of this cannot be exercised by the
test suite or the simulator, which is exactly why it needs fixtures and a device
checklist rather than more code.

### Resolution correctness

- [ ] Treat one-shot `requestLocation` fixes as provisional evidence only. Promote them to resolved visits after dwell time, a matching `CLVisit`, a Saved Place geofence match, or repeated stationary samples.
- [ ] Run the location resolver immediately after every arrival, departure, correction, Saved Place edit, and app relaunch so the store always maintains one deterministic current visit.
- [ ] Add invariants checked after each resolution pass: at most one current resolved location, no resolved location overlap, no negative duration, no superseded visit in Timeline/Insights, and no user correction overwritten by automation.
- [ ] Add delayed/out-of-order Core Location fixtures with GPS drift, repeated callbacks, overlapping open visits, and Home → destination → Home return sequences.
- [ ] Add deterministic replay tests for departure-before-arrival delivery, repeated arrival callbacks, coordinate drift, stale one-shot fixes, overlapping geofences, missing departures, relaunch while a visit is open, and Home → destination → Home.

### Signals not yet used

- [ ] **`CLLocationUpdate.liveUpdates` is unused.** Verified present in the installed iOS 27 SDK (`CLLocationUpdater.h`, available since iOS 17). Each `CLUpdate` carries `stationary`, `accuracyLimited`, `insufficientlyInUse`, `locationUnavailable` and the authorization flags. LifeLog currently infers dwell from `CLVisit` timing alone and has no signal at all for the others. A short live-updates session around an ambiguous arrival would settle "am I actually stopped here?" without the battery cost of continuous tracking, and would replace the one-shot `requestLocation` guesswork above.
- [ ] **Approximate location is not handled.** If the owner ever grants reduced accuracy, `accuracyLimited` is the only way to know, and every distance comparison in `ActivityLocationPolicy` and `SavedPlaceLearning` silently becomes meaningless. Detect it, say so plainly in Settings, and stop learning Saved Places from fixes that carry it.
- [ ] The Wi-Fi anchor, geofencing and motion collection shipped 2026-08-05 and are **still unproven on hardware**. Confirm a Saved Place arrival is named on entry without a Maps request, that exit closes the stay at the crossing, and that `geofences_monitored` appears in Diagnostics. iOS caps monitored regions at 20, so also confirm the recency/frequency prioritisation is picking sensibly.

### Maps requests

- [ ] Add a per-visit lookup cooldown and retry budget so repeated location updates cannot trigger repeated MapKit searches or reverse geocoding.
- [ ] **Per-visit lookup cancellation no longer exists.** The `lookupID` mechanism was removed in the 2026-08-06 cleanup because nothing ever called the cancel path — it had been dead since it was written. `PlaceLookupService.cancelAllLookups()` is what actually runs, and it cancels every lookup in flight whenever any visit is edited. If per-visit cancellation is wanted, build it deliberately and call it.
- [ ] Store only the top few MapKit candidates needed for correction, discard duplicate candidates, and cap candidate payload size before writing it to SwiftData.
- [ ] Review Apple Maps request policy and privacy copy; make lookup opt-out explicit and provide a manual-pin fallback that never requires network access.
- [ ] Scope location queries by date/window wherever possible and avoid loading imported journal rows or superseded callbacks into interactive views.

### Place identity

- [ ] **Match by `MKMapItem.identifier` everywhere, not just when learning one.** `SavedPlaceLearning`, `PlaceHistoryView`, `MonitoredPlaces`, `ReviewQueue`, the merge flow and `ActivityStatistics` now all route through the new `NameKey` helper, which made them consistent — but consistent on the *name*, which is still what breaks on a rename or a shared name. Needs the identifier on `Visit` too, so it is a V5 migration.
- [ ] Build one place-scoring pipeline combining Saved Place geofence, Apple Maps POI distance/category, dwell duration, horizontal accuracy, recurrence, time of day, and prior corrections; store the score breakdown for later inspection.
- [ ] Prefer Saved Places before making a Maps request, then reuse rounded-cell Maps results and reverse geocoding only as a fallback. Show which Apple source supplied each field.
- [ ] Do not permanently create a Saved Place from one high-confidence Maps result. Require a correction, repeated visits, or a configurable confidence streak before learning it as reusable.
- [ ] Learn aliases for GPS drift around large venues so multiple nearby Apple Maps pins resolve to one Saved Place without merging genuinely separate businesses.
- [ ] Refresh unresolved visits when better Apple Maps information becomes available, while preserving the original candidates and never replacing a confirmed user choice.

### Explaining and retaining

- [ ] Add a "why this place?" detail showing Saved Place, Maps result, distance, recurrence, and confidence without exposing raw coordinates.
- [ ] Add a location-event journal for personal diagnostics containing callback type, callback/arrival/departure times, coordinate, accuracy, distance from current visit, chosen resolution transition, and related visit identifier.
- [ ] Add a "Location Debug" screen showing the raw callback sequence beside the resolved Timeline, with actions to export the detailed report and rerun resolution without deleting raw data.
- [ ] Detailed location diagnostics are opt-in but never expire on their own. Add automatic expiry and mark exports as containing personal location data.
- [ ] Add location retention controls: precise coordinates for a configurable period, rounded coordinates for older history, and a clear irreversible-delete scope.

## Living with nine years of data

Several parts of the app still assume a small, recent dataset.

- [ ] **Timeline only ever shows today.** `TimelineView` filters to `startOfDay(for: clock)` and there is no way to open a past day, so nine years of history is reachable only through Insights aggregates. Add date navigation, or a "jump to date", so the journal can be read as a journal.
- [ ] **There is no search anywhere except Place History.** One `.searchable` in the whole app. "When did I last go to X" and "what did I do the week before the trip" are unanswerable. A single search over place name, activity and note would make the archive usable.
- [ ] 155 visits carry a note and nothing surfaces them. Notes are invisible unless the exact visit is opened. List them, include them in search, and show an indicator on Timeline cards.
- [ ] Consider retrospectives that only make sense with this much history: this day in previous years, first and last visit to a place, longest gap since a place, year-over-year comparisons.
- [ ] Re-run the physical-device performance checklist with the latest archive and confirm no main-thread stall over 250 ms; keep only aggregate timings in Diagnostics.

## Layout and structure

- [ ] **Insights aggregation is now extractable — write the tests.** The 2026-08-06 cleanup moved `InsightsSnapshot` and its model types out of the view into `Insights/InsightsSnapshot.swift` and made them internal, so `@testable import LifeLog` can reach them. Nothing about the behaviour changed and it still has **no test coverage at all**. Cover overlapping visits, comparison windows, unlogged gaps, active visits, weekday rhythm, ignored records, and the large fixture.
- [ ] Two files are still doing too much: `ActivityLocationPolicy` (702 lines) mixes stay resolution, journey detection, commute matching and confidence scoring; `ActivityImportActor` (521) mixes HealthKit reading, Core Motion reading and writing. Both would split along seams that already exist.
- [ ] Prioritise iPhone 17 Pro Max layout, Dynamic Type and dark mode regressions. The 6.9" screen and the Insights donut have never been checked together at the largest accessibility sizes.
- [ ] Expand the Insights UI regression test to tap several donut segments repeatedly, deselect the active segment, select Sleep, scroll away and back, and confirm the chart remains hittable.
- [ ] Add UI tests for the Diagnostics and Journal Storage screens, including backup failure, protected-file failure, empty history, Dynamic Type, VoiceOver and dark mode.
- [ ] `PlaceLookupService` cannot be tested without a live `MKLocalSearch`, and its cache is private. Injecting the search (a closure or small protocol, defaulted to the real one) would make the cache, the expiry split and the cancellation paths testable.

## Apple APIs worth adopting

**Checked against the SDK actually installed on this Mac: Xcode 27.0 beta
(27A5228h), iOS 27.0 SDK.** There is no iOS 28 SDK here, so no iOS 28 API can be
verified from this machine — the last section lists what to look at when it
arrives, deliberately without naming APIs that cannot be confirmed.

### iOS 27 — present in the installed SDK, unused by LifeLog

- [ ] `CLLocationUpdate.liveUpdates` and the `CLUpdate` diagnostic flags. Covered under Location accuracy above; listed here because it is the single largest unused Core Location surface. iOS 27 also adds a `maritime` live-update configuration, which LifeLog has no use for.
- [ ] **New `MKPointOfInterestCategory` values.** iOS 27 adds Pharmacy, Hotel, Airport, AirportTerminal, PublicTransport, University, Theater, ATM, ScenicView, RestArea, PicnicArea, RVPark, MiniGolf, Castle, RangerStation, InformationBooth and TicketOffice, among others. `InferenceEngine` still matches on hand-written keyword lists ("hospital", "airport", "station"), so a pharmacy resolves as Shopping and a hotel as Travelling only by luck of wording. Mapping the categories directly would be both more accurate and shorter.
- [ ] **SwiftData sectioned results.** `ResultsSection` / `ResultsSectionCollection` and the `sectionBy:` fetch initialisers are new in iOS 27. A Timeline that can open any day needs day sections over 25,000 rows, which is exactly this.
- [ ] **SwiftUI `reorderable()` / `reorderContainer(for:)`** (iOS 27). Directly serves the open "move several activities into a group at once" work, and would replace hand-rolled ordering in the Activities and Groups screens.
- [ ] `ToolbarContent.visibilityPriority` (iOS 27) for toolbars that have to degrade gracefully at large Dynamic Type sizes.

### iOS 28 betas — cannot be checked from this Mac

- [ ] Install the iOS 28 SDK, then re-run this audit before assuming anything. The specific things worth checking when it lands: whether Core Location gains a first-class dwell or arrival-confidence signal that would replace LifeLog's own resolution rules; whether `CLMonitor` raises the 20-region cap or adds priority; whether MapKit exposes a stable place identity beyond `MKMapItem.identifier`; whether SwiftData gains partial-index or predicate support that would remove the bounding-box pre-filter in `SpatialBounds`; and whether FoundationModels' on-device model gains a structured-output path better suited to place classification than the current `@Generable` tagging use.
- [ ] Bumping `deploymentTarget` past 27.0 is a decision about the owner's own phone, not a compatibility question. Take it only when something above actually requires it.

## Data ownership and safety

- [ ] A backup is complete personal history — every coordinate, note and place name — written as plain JSON to the temporary directory and then shared wherever the person chooses. The current backup is sitting unencrypted in iCloud Drive. Offer an optional passphrase, or at least warn plainly at the moment of sharing what the file contains.
- [ ] Export and backup writes use `.atomic` without an explicit protection class. The default-data-protection entitlement should cover them, but a personal-history file is worth setting `.completeFileProtection` on explicitly rather than inheriting it.
- [ ] Staged export files live in the temporary directory for up to 24 hours. Consider shortening that, or clearing them as soon as the share sheet is dismissed.
- [ ] Add explicit retention and deletion controls for imported journals, Health/Motion records, diagnostics, exports and all app data; show counts and estimated storage before deletion, and make destructive scope explicit.
- [ ] Add low-storage handling for imports, backups and reports: preflight available space, show a recoverable error, and never delete source data on a failed export.
- [ ] Add import progress with cancel/retry and a post-import summary showing duplicates, malformed rows, compactable rows and storage impact.
- [ ] Add a personal-device regression checklist for fresh install, upgrade, migration, store recovery, backup restore, permission changes and relaunch.

## Health and movement

- [ ] Test Health permission denial, partial permission, no data, Apple Watch disconnected, duplicate samples, deleted samples, daylight-saving transitions and unusual time zones.
- [ ] **One throttle governs two very different imports.** `refreshAutomatically` returns early for six hours after any import, and that single gate covers both Core Motion and Health. Motion needs it — its queries are expensive and its history only spans a week. Health is read by anchor, so repeating it costs almost nothing and only collects what has arrived since. Give them separate schedules so a Health sample that lands after a Motion import does not wait up to six hours.
- [ ] **HealthKit never reveals whether a read was granted.** `statusForAuthorizationRequest` only says whether the prompt has been shown, so "Connected" cannot distinguish granted from silently refused. The one honest signal is whether any sample has ever arrived. Consider reporting last-received-sample age next to the status, so a permission revoked in the Health app becomes visible instead of reading as connected forever.
- [ ] Expand movement classification for walking, running, cycling, automotive travel and possible flights while preserving the location-first rule: movement inside Home, Work or another destination must not become a separate timeline entry.
- [ ] Add recurring-trip tests for "Travelling to Work/Home", including incomplete destinations and corrected place labels.
- [ ] Mark a Saved Place as Home or Work explicitly. Commute detection and travel labelling both recognise them from the place's own name, so an office named "atWork Australia" is found by keyword luck rather than by the person saying so.
- [ ] Give a commute its own Timeline row. It is counted in Insights but the gap between leaving work and arriving home still reads as empty space on the day's journey.
- [ ] Walks with no workout behind them still have no route, so `ActivityLocationPolicy.leftStay` cannot tell a loop around the block from pacing at home and correctly absorbs both into the stay. Sampling locations for this would be a real battery cost and remains deliberately not taken — but the live-updates work above may make it affordable.

## Inference — sequencing agreed 2026-08-05, still the plan

1. [ ] **Clean the history first.** 95% of named history is bulk-imported journal, and its labels are whatever Life Cycle defaulted to. 26 place names hold 10,756 entries, so most of the corpus is a few dozen corrections away from being trustworthy. Use the Place History screen.
2. [ ] **Then run "Add from your history"** in Activities. 17% of the archive groups as "Other" in Insights, including 2,732 `Work` visits that show as 5. Grouping is computed rather than stored, so adopting the activities re-buckets that history immediately.
3. [ ] **Then infer from past behaviour**, keyed on place *and* time band rather than place alone. A home address is 92% `Sleeping` between midnight and 06:00 and 99% `At home` between 11:00 and 22:00, so place alone would be wrong roughly half the time. Weight corrections and LifeLog-entered activity heavily and imported values lightly — frequency in imported data measures what was never fixed, not what was true.

## Later

- [ ] Add optional notes and photos with local file protection, storage limits, export/deletion support and explicit privacy controls.
- [ ] Add read-only App Intents and Shortcuts such as "show coffee places I visited this week", with permission-aware results and no background disclosure of sensitive places.
- [ ] Design optional encrypted iCloud sync only after local backup/restore and schema migrations are proven. Define conflict resolution, opt-in, recovery, deletion and multi-device behaviour before enabling CloudKit.
- [ ] Consider widgets or summaries only after their Lock Screen and shared-device privacy behaviour is explicitly designed.

## Decided against, with evidence

Kept so they are not proposed again.

- **A merge tool for duplicate activity labels.** Across 77 labels in a real archive there is exactly one near-duplicate pair (`Work` and `Working`), covered by the rename above.
- **Feeding motion and HealthKit into place inference.** Of 605 device records only 103 overlap a named place, 94 of those already have a keyword-matchable name, and the remaining 9 are walking records against places labelled Eating and Donate Blood, where the signal would mislead. Revisit only if automatic visits start producing many unnamed places.
- **Standalone time-of-day inference.** Unconditioned it is close to useless; conditioned on place it is decisive, which is step 3 above.
- **Storing a place type.** Removed in the V1→V2 migration. The Apple Maps point-of-interest wording is a transient inference hint only, and place identity is the place name — soon, the Maps identifier.
