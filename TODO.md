# LifeLog — what's next

Rewritten 2026-08-06 after a cleanup pass. Everything that had actually shipped
has been removed rather than left ticked, so this file is only open work. Items
carrying a number from the 2026-08-05 archive review (25,558 visits, 2017-05-06
to 2026-08-04) say so — those figures were measured then, not re-measured now.

LifeLog is a private app for one iPhone 17 Pro Max. Judge layout, performance and
Dynamic Type at that size. Nothing here is App Store readiness work.

---

## Now — small changes, real consequences

- [ ] A failed background save only sets `lastError`, which lives in memory and is gone after relaunch. An overnight failure leaves no trace at all. Record save failures to Diagnostics so they survive a restart.
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

- [ ] **`CLLocationUpdate.liveUpdates` is unused, and it is a materially better signal than what stands in for it today.** Verified present in the installed iOS 27 SDK (`CLLocationUpdater.h`, available since iOS 17). `refreshCurrentLocation()` fires one `requestLocation()` fix, and `seedCurrentVisit` decides "arrived here" from `speed <= 2.5` alone (`LocationRecorder.swift`) — a single noisy fix, commonly missing speed entirely on launch, can create or extend a visit on nothing. Each `CLUpdate` carries `stationary`, which comes from on-device motion fusion rather than an inferred speed, plus `accuracyLimited`, `insufficientlyInUse` and `locationUnavailable`, none of which LifeLog reads today. Replace the one-shot fix with a hard-bounded burst — fixed timeout and fixed sample count, whichever comes first — requiring `stationary == true` on the recent samples before treating an arrival as real. The same burst can confirm a `CLVisit` arrival that came in late or drifted (there is already a >15-minute-late diagnostic at the `didVisit` callback) rather than trusting the callback outright.
- [ ] **Sequencing for the above:** foreground-first. Verify it standalone — triggered from app launch/foreground, where `refreshCurrentLocation()` already runs — before it is ever wired into the background workflow, given how much of that workflow (Wi-Fi anchor, geofencing, motion collection, below) is already unproven on hardware. Fails open: a thrown error, a timeout, or an authorization change mid-burst falls back to today's single-fix behaviour, never to nothing.
- [ ] **This is a different axis from `resolutionState`'s `.provisional`.** That state (`Visit.resolutionState` in `IgnoredLocations.swift`) is about place *identity* — has this visit been named yet — not dwell *confidence*: whether the phone actually stopped here, versus one shaky fix saying so. There is no field for the latter today. Wire the live-updates burst into the arrival decision directly, without inventing that field yet; "promote provisional to resolved visits" two items above is where a real dwell-confidence state belongs, and it is bigger, separable work this does not need to wait on.
- [ ] **Cannot be exercised in the simulator** — `stationary` depends on real motion sensors. Log every sample in a burst (stationary flag, accuracy, elapsed time) through `Diagnostics`, so a real walk can be inspected afterward rather than watched live. Add a manual "run a live-updates burst now" trigger to a Diagnostics screen so it can be exercised on demand on the iPhone 17 Pro Max rather than waiting for a real ambiguous arrival. Device checklist: standing still indoors settles to stationary within the timeout; walking continuously never reports stationary; poor signal (elevator, underground) falls back cleanly rather than hanging.
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
- [ ] **Insights trends and habits only see twelve weeks.** `InsightsTrends.weeks` bounds the fetch to a season because it runs on the main actor beside the whole archive. The cost is what the habits card is allowed to claim: the sketch asked for "the first week this year you spent time on cinema" and it says "in 12 weeks" instead, because that is all it has read. Widening it to a year needs the fetch moved off the main actor or pre-aggregated, not just a bigger number.
- [ ] **"Your weekly rhythm" is hidden in the Day window rather than answered.** The snapshot only covers the selected period, so in Day view six of seven bars are empty by construction. Hiding it is honest but the card is missing from the screen most used. The fix is to give the weekly rhythm its own trailing-weeks aggregation, the way the trend lines have one, so it means the same thing in every window.
- [ ] An activity whose name is not in the catalogue groups as "Other", and "Other" is excluded from the habits card — so a label used for years can never become a recurring habit. Another consequence of the grouping switch noted above, and another reason to adopt history labels.

## Current-activity artwork

Every shipped activity now has an illustration, and a test fails if one loses it.
When adding one: name the file after its imageset (`ActivityLunch.png` inside
`ActivityLunch.imageset`), then add a rule to `ActivityIcon.resolvedAssetName`,
ordered so a specific match precedes a general one. Match on a **stem**, not the
plain verb — "exercising" does not contain "exercise", which is how two rules
silently matched nothing for months.

## Layout and structure

- [ ] **Insights aggregation — finish the tests.** The 2026-08-06 cleanup moved `InsightsSnapshot` out of the view and made it reachable from `@testable import LifeLog`; the Insights rebuild later that day added the first coverage it has ever had. Now covered: time away from home against overlapping stays, weekday rhythm and its sleep exclusion, weekly trend bucketing, habit detection, and the day highlights. **Still uncovered: comparison windows, unlogged gaps, active (open) visits, ignored records, and the large fixture.**
- [ ] Two files are still doing too much: `ActivityLocationPolicy` (702 lines) mixes stay resolution, journey detection, commute matching and confidence scoring; `ActivityImportActor` (521) mixes HealthKit reading, Core Motion reading and writing. Both would split along seams that already exist.
- [ ] **Layout regressions need screenshots, not assertions.** The 2026-08-06 pass fixed four real faults at AccessibilityXXXL on the 6.9" screen — a date rendered dark blue on black, ring labels drawn across the segments, headings pushing their own content off the bottom, and a review card squeezing text to one word per line. None of them are reachable from XCTest: overlapping text has perfectly valid frames, and the `insights-donut-chart` identifier is inherited by the enclosing card, so a frame read through it spans the section rather than the ring. `testInsightsAndReviewCardSurviveTheLargestTextSize` guards only that both screens still render and stay reachable at that size. Catching the rest means capturing screenshots at a set of size/appearance combinations and comparing them against approved images — worth building, since this class of bug is invisible to everything else.
- [ ] Check the remaining screens at AccessibilityXXXL in both appearances. Only Timeline and Insights have been looked at; Settings, Activities, Place History, the visit editor and Add Visit have not. `xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large` plus `appearance dark`, then launch with `-ui-test-seed`, is the loop.
- [ ] Expand the Insights UI regression test to tap several donut segments repeatedly, deselect the active segment, select Sleep, scroll away and back, and confirm the chart remains hittable.
- [ ] Add UI tests for the Diagnostics and Journal Storage screens, including backup failure, protected-file failure, empty history, Dynamic Type, VoiceOver and dark mode.
- [ ] `PlaceLookupService` cannot be tested without a live `MKLocalSearch`, and its cache is private. Injecting the search (a closure or small protocol, defaulted to the real one) would make the cache, the expiry split and the cancellation paths testable.
- [ ] **Audit the rest of the persisted state the seeded launch does not reset.** `testAdoptingAHistoryLabelFromTheActivitiesTab` failed on every run after its first because it adopted an activity into `UserDefaults`, which the in-memory store does not clear — so the fixture a run started from depended on what had run before it. The activity catalogue is reset now, but `LifeLog.IgnoredLocations.v1`, the Diagnostics toggles and anything else keyed into defaults are not. Any test that writes one has the same trap waiting. Either reset all app-owned defaults for the seeded launch, or point the whole app at a scratch suite for it.

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
- [ ] **Prove the sleep observer on the device.** The six-hourly throttle that was silently swallowing `HKObserverQuery` callbacks is split (2026-08-06), so an overnight sync should now reach the timeline by itself. That has only been reasoned about and unit-tested — the actual path, Watch writes overnight sleep → observer fires → anchored import → Timeline, has never been watched happen on hardware. Check one morning before trusting it.
- [ ] **Grant Workout Routes, then re-import.** Routes are a separate permission that was never asked for, so no walk has a path — which is what `leftStay` needs to tell a loop around the block from pacing at home. Settings → Re-import Health history (added 2026-08-06) clears the anchors and re-reads 30 days, and the importer adds a route to a visit that lacked one without duplicating it. Do this once, then confirm past walks have paths.
- [ ] **Decide whether 30 days is enough of a re-import.** `reimportHealthHistory` re-reads the same window the routine import uses. Workouts older than that keep no route and no amount of pressing the button will fetch one. If the archive's older walks matter, this needs a date range rather than a fixed window.
- [ ] **`passingStayCoverage` is a guess.** 75% of a stay falling inside a workout marks it as passed-through. It was chosen to clear the observed case — a 9-minute stay recorded during a 45-minute walk — while sparing a real stop that outlasts the session. It has never been checked against a month of real data. Look at what it supersedes over a few weeks before trusting it, and remember superseded rows are still in the store and readable in Diagnostics.
- [ ] **HealthKit never reveals whether a read was granted.** `statusForAuthorizationRequest` only says whether the prompt has been shown, so "Connected" cannot distinguish granted from silently refused. The one honest signal is whether any sample has ever arrived. Consider reporting last-received-sample age next to the status, so a permission revoked in the Health app becomes visible instead of reading as connected forever.
- [ ] Expand movement classification for walking, running, cycling, automotive travel and possible flights while preserving the location-first rule: movement inside Home, Work or another destination must not become a separate timeline entry.
- [ ] Add recurring-trip tests for "Travelling to Work/Home", including incomplete destinations and corrected place labels.
- [ ] Mark a Saved Place as Home or Work explicitly. Commute detection and travel labelling both recognise them from the place's own name, so an office named "atWork Australia" is found by keyword luck rather than by the person saying so.
- [ ] Give a commute its own Timeline row. It is counted in Insights but the gap between leaving work and arriving home still reads as empty space on the day's journey.
- [ ] Walks with no workout behind them still have no route, so `ActivityLocationPolicy.leftStay` cannot tell a loop around the block from pacing at home and correctly absorbs both into the stay. Sampling locations for this would be a real battery cost and remains deliberately not taken — but the live-updates work above may make it affordable.

## Inference — sequencing agreed 2026-08-05, still the plan

1. [ ] **Clean the history first.** 95% of named history is bulk-imported journal, and its labels are whatever Life Cycle defaulted to. 26 place names hold 10,756 entries, so most of the corpus is a few dozen corrections away from being trustworthy. Use the Place History screen.
2. [ ] **Then adopt the labels your history already uses.** 17% of the archive groups as "Other" in Insights, including 2,732 `Work` visits that show as 5. Grouping is computed rather than stored, so adopting re-buckets that history immediately. Two ways now: "Add from your history" in Settings → Activity Labels for bulk, or swipe-to-add on the Activities tab, where each label is shown beside the time it actually accounts for — which is the better order to work through them in.
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
