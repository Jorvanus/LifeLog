# Change log

## 2026-08-12

### Insights drill-downs keep the selected period

- Significant activity, place, travel, sleep, comparison, and unlogged-time Insights now open period-scoped detail with consistent titles, accessible actions, and bounded resolved rows; review items continue directly to Visit Editor.

### Travel is now a first-class Insights dimension

- Day, Week, Month, and Year now share a Travel summary with total time, trip count, median duration, long-trip count, commute versus other travel, confident mode labels, waking-time share, and a trip drill-down; movement inside a resolved destination stays out of the summary, and short vehicle travel remains out of Timeline.

### Day timeline labels stay readable

- The current-time “Now” label moves to a separate line when it is close to a six-hour time marker, preventing the two labels from overlapping.

### Month Insights adds a scorecard

- Month now includes the Week-style scorecard for time at Home, Work, travelling, average sleep, steps, and exercise, with Health-derived rows shown only when the month has usable data.

### Durations now use human-scale units

- Long totals across Insights, Timeline, Places, Activities, and Visit Editor now use days plus hours instead of four-digit hour totals; short durations keep their existing minute precision.
- Year place summaries now use consistent spacing between Most time, Most visits, Newly discovered, and previously regular places so each story reads as a distinct group.
- Year place summaries now use the same activity icons and stable colours as Month Insights.

## 2026-08-12

### Year Insights is now a personal retrospective

- Year now presents a concise annual story with a 12-month stacked life-area chart, annual place summaries and drill-downs, source-aware movement and wellbeing metrics, restrained travel totals, and milestones that are only shown when the comparison or confidence data supports them.
- Incomplete, sparse, and imported-only history stays visibly limited: prior-year comparisons require meaningful history in both years, Health-derived sleep and steps appear only when data exists, and travel excludes movement within an existing destination.

### Insights period switching is lighter

- Month and Year no longer trigger a full-period sleep refresh while switching windows, and shared commute/category resolution is reused during aggregation; Year renders its current story before deferred archive and Health-derived history finishes loading.

### Month Insights now answers “What changed in my life this month?”

- Month now has a dedicated monthly headline, conservative activity-change cards, a derived high-level balance, a place story with Place History routes, and a full calendar heatmap that keeps quiet days visible and opens Day Insights when tapped.
- Monthly comparisons use the previous completed calendar month and require both absolute and percentage movement before calling a change meaningful. Imported journal and device-recorded history continue through the existing Insights source-visibility policy.

### Insights' Week window now answers "how did this week compare with usual"

- Week used to fall through to the same section list Month/Year get. It now has its own layout: a seven-day mini-calendar (one compact chronological bar per day, so a quiet or unlogged day is still visible rather than disappearing; tap a day to open it in Day Insights); a weekly scorecard (time at Home, at Work, travelling, sleep average, total/average daily steps, exercise — each row simply absent when the data doesn't exist rather than shown as a placeholder zero); "What changed," a rolling-baseline comparison against the last 8 completed weeks rather than only the single preceding week, showing only changes past the existing 10% noticeable-change threshold; and a Commute summary, shown only once Home and Work Saved Place roles are both configured and the week's commutes span at least 2 distinct days.
- The rolling baseline reuses `InsightsTrendAggregator`/`InsightsTrends.weeklyTotals` — the same off-main-actor, bounded fetch already powering trend lines and habits — rather than a second aggregation pass; `InsightsTrends.range` already excludes the in-progress week from that fetch, which is what keeps a partial current week from being compared as if it were complete. The weekly strip and scorecard read the same post-resolution `InsightsSnapshot.makeSegments`/`categoryHours` the donut and Timeline already use, so nothing on the new screen can disagree with either.
- New `InsightsSnapshot.categoryHours(in segments:)` generalises `travelHours`/`fitnessHours`'s shared filter into one dictionary lookup; new `InsightsSnapshot.weekCommuteSummary` is the one place the commute-days confidence heuristic lives, since `CommuteDetection` itself carries no confidence signal.

### Insights' Day window is now a daily review screen, not a smaller Month

- Day used to render the same section list as Week/Month/Year plus one extra card, even though most of those sections (trends, weekly rhythm, habits, trend lines) are empty on a single day. Day now has its own layout: a compact Current Activity summary (reusing Timeline's own "what's open right now" concept, not a duplicate live card); a new chronological 24-hour day bar as the lead visual; the donut, kept but demoted; a short Day summary (time at Home, away from Home, travel time, steps, last night's sleep, exercise); a "Needs your attention" card when something genuinely needs a look; and, last rather than first, up to three highlight cards. Week/Month/Year are unchanged.
- The new day bar (`DayTimelineBar`) is a true midnight-to-midnight scale, not the old bar's elapsed-so-far rescaling — it shows the rest of today distinctly rather than reporting it as "unlogged," includes a current-time marker, and tapping any block opens the matching visit or, for a real gap, an Add Visit sheet scoped to that gap. It's built from the same post-resolution `InsightsSnapshot.makeSegments` the donut already uses, over the full day instead of the `now`-capped analysis interval, so it can never double-count an overlapping record any more than the donut can.
- "Needs your attention" and the Current Activity card reuse existing detection rather than inventing new rules: `ReviewQueue.entries` (the same queue Timeline's own review card reads) for uncategorised/low-confidence/provisional stays, and a new `InsightsSnapshot.meaningfulGaps` for a genuine unlogged stretch (≥30 minutes, already past).

### A donut slice's detail rows now add up to exactly what the header says

- Tapping a donut segment (or a place in Top Places) opened `InsightSliceEditor`, whose header already showed the correct, deduplicated segment total but whose rows below it summed each visit's own raw `duration`/`duration(in:)`. Two records that overlap in time — an overnight Home stay under a Sleep record, a duplicate or imperfectly deduplicated automatic arrival — each claimed the same minutes twice, so the rows could add up to well more than the header.
- Rows are now built from the same post-resolution `InsightSegment`s the donut and header are already built from (`InsightsSnapshot.sliceRows`), grouped by the record that produced them and summed only over the slivers each one actually won. A row whose own recorded span extends beyond what it won now says "Shares this time with another entry" rather than showing a smaller number with no explanation.
- `InsightsSnapshot.makePlaceTotals` (the "Top Places" header total) is now built the same way, so the place-total entry point into the same screen stays consistent with the category entry point on the same overlapping data.
- Editing from a row, and the selected segment refreshing afterward, are unchanged — the sheet's existing `onDismiss: reloadInsights` still rebuilds the snapshot.

### The full migration chain is now proven against a real device store

- Extracted a copy of the on-device `LifeLog.store` (via Xcode's Devices and Simulators → Download Container) and opened it through the live `LifeLogMigrationPlan`, working only on the copy. All 25,685 real visits, 8 Saved Places, 81 corrections, and the diagnostic/location-event history survived the full V1→V8 chain intact, and the one place actually named "Home" was correctly backfilled to the new Home role. Closes the "prove it on a real historical store" gap the synthetic V1–V7 fixtures alone couldn't close.

### Home and Work are now explicit Saved Place roles, not a name guess

- Commute detection, travel-destination labelling ("Travelling to Work"), and the Insights "away from home" segment used to independently re-derive Home/Work by testing a place's *name* for the words "home"/"work" — a false positive for a café called "Homeward Bound," a false negative for an unnamed office, and two implementations that didn't even agree with each other. `SavedPlace` now has an explicit `role` (Home/Work/none), and every one of those consumers trusts it instead.
- A new V7→V8 migration backfills the role onto whatever the owner already had named exactly "Home"/"Work" (case-insensitive, never a substring — a real "Homemaker Centre" is untouched), without renaming anything. `SavedPlaceRole.of(_:in:)` is the one shared resolver (Maps identifier first, then geofence-radius membership) every consumer now calls.
- The Saved Place editor (Settings → Locations → a place) gets an explicit Role control, so an existing place can be marked Home or Work without renaming it. The "Set as Home"/"Set as Work" quick labels on an uncategorised visit now also set this role on whichever place they learn or update.
- `InferenceEngine`'s own Home/Work keyword guesses are unchanged — they still suggest a default activity for a place LifeLog has never seen before, which is a different question from "is this the owner's home or work."

### Timeline refreshes its day boundary immediately on foreground

- The minute clock that decides what "today" is drives itself with a 60-second sleeping `Task`, which iOS suspends in the background — so returning to the app could show up to a minute of stale data, long enough to miss a midnight crossing entirely. Timeline now refreshes the clock immediately on scene activation instead of waiting for that loop to resume.
- If the person was already looking at "today" when the app was backgrounded, the selected day now advances across the boundary too, so a foreground open after midnight doesn't silently swap the live view for yesterday's read-only journal. Deliberately reading a past day is left alone — foregrounding never yanks it back to today.

### An approximate location fix no longer teaches a Saved Place or wins on distance

- LifeLog now detects when a location fix is too fuzzy to trust for a distance comparison — either because Precise Location is off for the app, or because the fix itself is simply poor (indoors, urban canyon) — and treats both the same way, since a full-precision fix in a bad spot is just as untrustworthy as a deliberately fuzzed one.
- An approximate fix can no longer anchor a new Saved Place, and no longer counts as one of the three corroborating arrivals automatic learning requires. Identity-based evidence (a shared Apple Maps identifier, an actual geofence-entry event) still counts fully; only distance-based "closest wins" credit is withheld.
- Settings shows when Precise Location is off for LifeLog, with a way to open iPhone Settings to turn it back on. Diagnostics adds a "Location quality" summary (precise location on/off, and how many recent arrivals were approximate) and flags approximate rows in the raw location journal.
- The corresponding hardware-checklist TODO item now also calls for a real reduced-accuracy session on the phone, since this is unproven on hardware like the rest of the location pipeline.

### Sleep import now distinguishes measurement from an estimate

- Health sleep changes now rebuild the complete affected night instead of piecing together individual Watch sync fragments. Deleted samples reconcile only the relevant overnight evidence, so one edited stage no longer removes an otherwise valid night.
- When no wearable sleep is available, LifeLog can record Health’s time-in-bed estimate as `In bed` rather than calling it sleep, and Settings offers a clearly confirmed manual sleep entry for nights without a tracker.
- Settings and Diagnostics now report whether recent Health evidence was measured sleep, estimated time in bed, or absent. Background Health deliveries remain pending until LifeLog has processed them, rather than being acknowledged before the import finishes.
- The project roadmap and supporting README, migration, and performance guides now reflect the shipped resolver, Saved Place, archive, Diagnostics, and V7 schema work; the active list is limited to genuinely unfinished implementation and device proof.

### Large archives now use bounded history lookups

- Timeline now reads a short current-day window rather than the complete archive, and place/activity history has reusable day, month, year, place, activity, and explicit place-search queries. Notes remain outside ordinary history searches so Timeline does not load note text just to render.
- Diagnostics now measures the budget for returning to Timeline after leaving it, making a slow return from Insights, Settings, or an editor visible alongside launch and Insights timings.
- Returning from Settings no longer reruns the archive-wide callback resolver. The remaining one-day reconciliation helpers now query the recent window before they filter it, and the return budget starts when Timeline is selected rather than when it was left — so Diagnostics reports the actual return time instead of time spent reading another tab.
- Activities now builds its archive-wide summary away from the interface, and day Insights defers long-range trend/history work that does not affect its current-day cards. Opening either now prioritises the scoped information already on screen.

### Saved Place learning now waits for real evidence

- A single Apple Maps result no longer becomes a Saved Place and future geofence on its own. Automatic learning now needs three corroborating automatic arrivals; manually correcting a visit or explicitly saving a place still takes effect immediately.
- The resolver keeps the competing Maps candidates that led to a learning decision. When Maps repeatedly reports different entrances at a shopping centre or mall but offers the shared venue as an alternative, those arrivals now corroborate one wider Saved Place cluster instead of creating several competing places.

### Diagnostics now shows why one place candidate won

- Diagnostics has a new "Location resolution choices" screen for automatic stays. It shows the selected Maps or Saved Place candidate, every named alternative the resolver rejected, and the persisted resolution reason — without putting raw Core Location callbacks or coordinates into Timeline. The decision remains available even after a later Saved Place correction clears the editor's suggestion list.

### Every automatic location repair now keeps its reason

- Automatic stays now persist the decision that resolved them: a Maps identifier, a Saved Place, coordinate-and-time matching, a duplicate callback, movement evidence, or a low-confidence result that was ignored. The explanation is retained with the visit (and included in local backups), so it survives the short-lived diagnostic journal and can still explain why a timeline row was changed later.
- Added the V6→V7 lightweight migration: existing history deliberately starts without a manufactured explanation, and new explanations persist once recorded.

### Location callbacks now distinguish nearby businesses more safely

- Automatic location resolution now treats a shared Maps identity as the strongest proof that two close callbacks describe the same venue. For older records without one, it falls back to a normalised matching name; an unresolved “Identifying…” callback can still refine a nearby named arrival, but only within a tighter radius. Two different named businesses are no longer folded into one visit simply because they are close together and their callbacks arrived within a minute.
- Added deterministic callback-replay coverage for Home → destination → Home, a delayed departure delivered after a newer arrival, repeated arrivals, GPS drift around one Maps-identified venue, neighbouring different businesses, and a long journey followed by its destination.

### Maps visit identity now backs the remaining recurrence and monitoring signals

- The V6 migration already gave every Maps-resolved `Visit` a durable identifier alongside `SavedPlace`, and several matching sites already preferred it over a name. Two more did not: place scoring's recurrence signal (has this exact spot come up before) and the monitored-places ranking (which visits count toward a Saved Place's usage) both matched by name/proximity only, even though both sides can carry the same identifier today. Both now check the Maps identifier first — two records can only share one by being the same physical POI, which name matching can't guarantee — falling back to name, then proximity/geofence, exactly as documented elsewhere in this pipeline.
- Added a migration test isolating the V5→V6 hop specifically (previously only exercised implicitly via the current-schema round-trip test): a V5 store's visit has no Maps identity to restore, and the field is settable and persists once assigned.

### A Timeline row's icon is a little smaller, and its title no longer leaves a stray gap before the duration column

- The activity icon on a Timeline row is now 48pt rather than 58pt, leaving more width for the title next to it.
- The title used to reserve a text column sized off however much width happened to be available, so a short place name ("Blood Bank", "Home") rendered flush left with a wide, empty gap before the duration/status column — most visible on a device with a large screen. The title now only claims the width it actually needs (via `layoutPriority` rather than `maxWidth: .infinity`), and a long name still wraps properly under real contention with the fixed-width duration/chevron column. The duration, status pill and chevron stay pinned to the card's right edge on every row — short or long — the same way Mail or Messages pins a trailing timestamp, rather than trailing the text at whatever distance it happens to end.
- The status pill ("Medium", "Low") could break mid-word ("Medi-um") once the title started claiming more of the row; it is now pinned to its own single-line width regardless of how little room is left, so the title wraps first.

### A Timeline row's connecting dot no longer floats away from a long place name

- Diagnosed from a real screen: a long place name ("Rockhampton Child Safety Service Centre", "State Government Building") wraps its Timeline row title to two or three lines, but the dot-and-line column on the left was fixed at a flat 108pt regardless — sized for a one-line name — so on a taller, wrapped row the dot stayed pinned where a short row would have centred it instead of following the card down, landing near the top instead of the middle. Both the dot/line column and the card content now share a `minHeight` instead of a fixed `height`, so they grow together and the dot stays centred whatever the name wraps to, while a short single-line row renders pixel-identical to before. Verified by seeding a two-line name in the simulator and comparing before/after screenshots.

### An activity's stats and its editor are now one screen, not two

- Tapping an activity from the Activities tab opened a read-only stats page — occasions, top locations, totals — with no way to change its colour, icon or category. That editing only existed on a completely different screen, reachable only from Settings → Activity Labels, so there was no way to fix an activity's colour from the page you were already looking at it on. `ActivityDetailView` now carries both: stats plus (once the activity is adopted into the catalogue) name, colour, category, icon, its full visit history, and delete — reached identically from either the Activities tab or Settings. Renaming still offers to carry existing visits across, or merge into another activity if the new name already exists, exactly as it did before.
- The old edit-only screen (`ActivityEditor`) is now a plain creation form for a brand new activity, since editing an existing one lives on the merged page. `ActivityUsageSummary` was fully redundant with stats the merged page already shows, and is removed.

### "At home" and "Home time" are now one activity, not two

- `InferenceEngine` silently split every automatic home arrival by time of day — "At home" before 8am or after 6pm, "Home time" in between — while "Set as Home" always wrote "At home" regardless of the hour. The same place fragmented into two labels depending purely on when an automatic guess happened to land, for no reason anyone asked for. The time-of-day split is gone; every "home" arrival is "At home" now, and every existing visit and catalogue entry still holding "Home time" is renamed across in one pass at next launch (same pattern already used to merge the old "Working" label into "Work").

### "Use a previous activity here" now actually means "here"

- It unconditionally appended the entire activity catalogue on top of whatever had actually been used at this specific place, so it ended up showing nearly everything "Choose an activity" already does — never the short, place-specific shortcut its own label promised. It now shows only activities genuinely recorded at this place, and stays hidden (as it already did) when there aren't any yet.

### Timeline's past entries now lead with place name, matching Current Activity

- The Current Activity card shows place name bold with activity underneath ("Home" / "At home"). Every past entry below it showed the same pairing the other way round (activity bold, place name underneath), so the identical "Home"/"At home" pair read backwards depending on which card it was in. Past entries now lead with place name too, except a walk or workout with a route -- its place name is only ever "Walking workout", so that case still leads with the activity and shows distance underneath, same as before.

### "Use" on a place's own map now actually returns you to "Where?"

- Picking a place via "Choose on map" or a nearby row's own detail screen wrote the choice back correctly, but the screen didn't dismiss -- "Use" appeared to do nothing, leaving the back chevron as the only way out and the pick effectively lost. The callback that was supposed to close "Where?" captured its dismiss action two navigation levels up from where it actually got called, which doesn't reliably pop that far. Replaced with each screen dismissing only itself: the place-detail screen closes on "Use", and "Where?" now reacts to the pick being made at all, however many screens away it happened.

### A low-confidence guess now says so on Timeline, and recurring stops stop needing Maps to agree on a name

- Diagnosed from a real false arrival: walking home landed on "Johnson Rd & Labanka Crescent Stop" — a bus stop 7-20 m from the actual (GPS-accurate) position — because Apple Maps had no better POI registered at the door and Home wasn't saved as a place, so the arrival fell through to the same weak nearby-POI guess every time (score 18 of the 75 needed, correctly flagged `recognitionConfidence: "low"`).
- The "Current Activity" card treated that low-confidence guess identically to a confident one — `Visit.needsConfirmation` was already computed correctly, but the card only ever checked `needsCategorisation` (fully unidentified places), so a named-but-unsure guess showed with total, silent certainty. It now shows a "Confirm" badge and "Is this right?" the same way the review queue already phrases uncertain matches.
- "Set as Home"/"Set as Work" quick labels only appeared for a fully unidentified place, not a named-but-uncertain one — so there was no one-tap way to correct exactly this case. They now appear for either.
- Place scoring's recurrence signal only counted prior visits that got the *exact same resolved name* as the current guess, so a spot visited daily got no credit for that history if Apple Maps kept picking an inconsistent (or simply wrong) nearby POI each time — precisely what was happening here. It now also counts prior visits within 60 m regardless of name, the same "same physical place" radius already used elsewhere in this pipeline.
- `PlaceScoreLifecycle.rescore` used to fetch every `Visit` and `VisitCorrection` in the entire archive, unbounded, on every single automatic arrival/departure/correction, just to answer "has this name/spot come up before" for the new proximity signal above. Replaced with `PlaceHistoryLookup`: a spatial bounding-box query plus one narrow name-contains fetch per distinct candidate name, instead of loading the whole table every time.

## 2026-08-11

### "Choose on map" now starts on the visit being edited, not wherever the phone last was

- "Where?" anchored its map and its "places nearby" search on whichever visit was most recently recorded anywhere in the archive — correcting an old visit from a different city centred the map, and searched nearby, on today's location instead of the one actually being corrected. It now prefers the coordinate already recorded on the visit being edited, falling back to the most-recent-visit heuristic only for a brand new Add Visit entry that has no coordinate of its own yet.

### The "Place" screen's map no longer needs "Adjust pin location" first

- Moving the pin required tapping "Adjust pin location" to enter a separate editing mode before a tap on the map did anything. Removed the toggle; a tap always moves the pin now, the same way it already works on "Choose on map" -- nothing here commits until the whole visit editor is saved, so there was nothing the toggle was actually protecting.

### The "Where?" picker no longer hides its own nearby list behind the current guess

- The location field pre-filled itself with the visit's current place name, which is usually specific enough to match nothing else nearby — opening the picker on an already-named visit routinely landed on "no nearby matches" instead of a usable list. The field now starts blank, and the current guess is shown as a checkmark next to its row in Places nearby instead, so the list stays browsable and typing still narrows it live.
- The per-row "details" control was an invisible tap target with no visible affordance at all. It's now a visible info-circle icon, but only for a place LifeLog already knows (already saved, already visited) — a plain Apple Maps result has no history, save, or merge behind it to show, so it gets no detail link (and no disclosure chevron, which a `NavigationLink` draws automatically whether or not it leads anywhere useful) at all.
- "Choose on map" and the per-row detail link had a `simultaneousGesture` diagnostic beacon added alongside their `NavigationLink`, which competed with the link's own tap handling — the button visibly highlighted but the push often didn't fire, needing several taps to actually open. Removed; the checkpoint diagnostics already sitting inside the destination screen cover the same ground without a gesture on the trigger itself.

### "Place" is now its own screen, with the map on top and the name below

- Edit Visit used to show an editable pin map and a "Place" row as two separate sections inline in the main form. Tapping "Place" now opens a dedicated screen instead — the map first, then the current name as a row that leads into the existing "Where?" search/nearby picker, matching how "Choose on map" already gets its own screen rather than living inline.

### Fixed UI freeze when opening "Choose on map" in location chooser

- Replaced an unbounded `@Query` over all historic visits in `VisitLocationChooser` with a single bounded fetch limited to the latest visit coordinate, avoiding main-thread object materialization of thousands of visits.
- Deferred the location history lookup in `LocationDetailView` to yield during navigation push transitions, keeping screen navigation fluid on large datasets.
- `LocationDetailView`'s merge action had the same unbounded scan, looping every visit in the archive to rename the ones matching the merged place; switched to the same scoped `PlaceVisitLookup` fetch the history list already uses.
- The freeze persisted after the above, so added unconditional checkpoint diagnostics (category `performance`, so they land in the existing "Share performance report" export) across the whole path — tap, view construction, map appearance, history fetch — so the last-reached checkpoint identifies where a future hang actually stalls, rather than continuing to guess.

### Leaving Edit Visit, "Where?", or Edit Place no longer keeps changes you didn't ask to keep

- All three screens wrote straight into the live model as you interacted with them — a map tap set the coordinate immediately, a radius slider or activity pick committed on the spot, and Edit Visit persisted everything on `onDisappear` regardless of how you left. The back button, and even a swipe, already amounted to saving; there was no way to change your mind. Every field is now a draft, committed only by an explicit Done/Save, and each screen has a real Cancel that discards it and nothing else. The default back button is hidden in favour of that Cancel so it's not still sitting there implying "go back" while actually meaning "keep this."
- Typing in the "Where?" picker's search field had the same problem one level down: every keystroke wrote into the caller's place-name draft directly, so backing out after typing but not choosing anything left the half-typed text in place as if it had been picked. Typing is now purely local until an actual selection is made — a nearby row, a search result, or "Use" on the map.

### The "Where?" picker's nearby list now narrows as you type

- Typing in the location field only ever ran a fresh Apple Maps search on submit; the "Places nearby" list underneath stayed exactly as loaded, unfiltered, until then. It now narrows live against what's already on screen as each letter is typed — the on-submit Apple Maps search is unchanged and still there for a place that isn't in the nearby list at all.

### Editing a visit's place now uses the same "Where?" picker as Add Visit

- Edit Visit's place field was a plain text box plus a "Choose nearby Apple Maps place" sheet capped at 3 results, with no search, no map pin, and no awareness of Saved Places — a second, weaker path to what Add Visit's location picker already did well. Tapping the place row now opens that same picker: search by name, choose on the map, or pick from nearby places (Saved Places included, marked as already known). The old sheet is gone.

### Geofence arrivals are now confirmed before becoming a visit, and deleting one can offer to split its time

- A geofence boundary being crossed was trusted immediately, with no check that the phone had actually stopped — unlike a `CLVisit` arrival, which already waits for Core Location's own motion-fused "stationary" signal before writing a durable visit. GPS jitter near an already-open stay, or driving straight past a saved place, could create a visit for a stop that never happened. Geofence entries now go through the same stationary confirmation; if the phone is still moving when the check window ends, nothing is recorded.
- Deleting a visit sandwiched between two different places used to just leave a gap, shown afterward as unlogged time. It now asks whether to split the freed time evenly between the visit before and after, or leave it unlogged. Deleting a visit sandwiched between two identical place/activity entries still merges automatically, as before.

## 2026-08-10

### Roadmap updated with Insights enhancement items

- Added detailed actionable Insights items to `TODO.md` covering Waking Life Balance Ratio, Commute Overhead trends, Exploration & Novelty scores, Peak Dwell duration metrics, Timeline micro-insight badges, and Insights tab segmentation.

## 2026-08-09

### A new arrival can now guess its activity from what this place has meant before

- A live arrival's activity used to come only from a keyword table matched against the place's name and Maps category — it had no memory of what this specific place, at this time of day, has actually been logged as before. It now also asks the archive, weighted so a correction or a confirmed visit outweighs several automatic guesses, and a bulk-imported default barely counts at all — only trusted once there's enough real evidence, never from a single data point.

### Three new archive retrospectives, only when they have something to say

- Insights can now notice a genuinely first-ever visit to a place, the longest a familiar place has ever gone unvisited when that record is set inside the period you're looking at, and one restrained comparison of this period's total against the same period a year ago. Each stays silent rather than stating the obvious: a place seen only once or twice has no meaningful gap to report, and a small year-over-year shift isn't called out as a change.

### Habits can now say "back to" instead of overstating "first ever"

- The habits card only ever saw twelve weeks of history, because resolving that history ran on the main actor beside the whole archive — a wider window meant a slower screen. It now runs entirely off the main actor, so habits reads a full year instead: a real return after months away used to read as "First entertainment in 12 weeks" (implying it had never happened before) and now correctly reads "Back to entertainment". Trend lines and the weekly rhythm chart stay at twelve weeks on purpose — a year on a line chart reads worse than a season, and neither needed the wider window to begin with. Also removed a redundant recomputation that would have made the wider window meaningfully slower: one piece of the aggregation (commute detection) doesn't depend on which week is being looked at, but was being redone identically once per week regardless.

### Schema migration fixtures now test the real model versions

- Corrected the V4 fixture to insert frozen V4 model types instead of current models, and rebuilt the legacy-store fixture from the exact unversioned V1 shape. Frozen V1 correction and diagnostic models now preserve the pre-versioning schema metadata, preventing a false “environmental” crash from hiding migration failures.
- Updated the migration notes to describe the shipped V6 baseline and the remaining need to validate a copied pre-versioned device store.

### Five regressions from the last diagnostics/performance pass, found and fixed

- **A budget sample stopped recording whether it passed.** The previous "reduce diagnostics noise" change made `Diagnostics.budget` silent unless an operation ran over budget, and removed the unconditional "Reconciliation check" log from Timeline's own appearance. Both broke the same thing on purpose-built to prevent: telling "this ran and was fine" apart from "this never ran at all", which cost four wasted builds the first time it was lost. Both are restored; there's an existing test (`budgetRecordsEveryTime`) that would have caught this had it been run before that change shipped.
- **A genuine walk between two places could no longer show on Timeline.** The same pass excluded all `motion`/`health-walking` records from Timeline's query outright, to avoid loading an archive's worth of samples just to render one day. But Timeline already asks `shouldShowInTimeline` that exact question per row — which can tell a walk absorbed into a stay apart from a real journey between two places — and a query-level exclusion discards a row before that check ever runs. Reverted; the archive-scale cost this was trying to avoid is real and still worth solving, but with a date-scoped fetch, not by source.
- **`ActivityIcon`/`ActivityScene`'s pure lookup properties crashed when called from a non-`@MainActor` context.** Both conform to `View`, so SwiftUI infers `@MainActor` on every member by default, including properties that touch no UI state at all. Marked `nonisolated` explicitly.
- **A place-scoring test asked for dwell duration at the wrong lifecycle stage.** Scores deliberately read zero dwell on arrival — the eventual duration is re-evaluated at departure — and a test fixture with a real departure never asked for that stage. Fixed the test.
- **A UI test scrolled the wrong direction, then the right direction too many times.** Swapped a fixed `swipeDown()` loop for the same "swipe until found" pattern already used everywhere else in the file.

None of these were caught before shipping because the previous commit touched no test files. Full suite verified clean afterward on a fresh simulator. The separate SchemaMigrationTests issue was investigated independently and is covered by the migration-fixture entry above.

### The routine Health refresh stops re-reading a month of steps every time

- Walking data isn't read incrementally the way sleep and workouts are — it has no anchored-query equivalent, so it re-scans whatever window it's given from scratch every time. The routine refresh, throttled to once every two minutes, was handing it a flat 30-day window regardless, so every foreground reprocessed roughly a month of step-count samples: a real capture showed 18 imports in under three hours averaging ~700ms, one at 1.9s, with item counts flat around 392-421 rather than trending toward the handful of genuinely new samples since the last read. The window is now sized to the actual gap since the last successful read — two days during ordinary, frequent use, widening automatically to cover a real absence instead of a flat number either too small (silently losing history) or too large (re-reading it needlessly).

### Diagnostics focus on actionable slow paths

- Fast Insights budget passes and completed Timeline reconciliation checks are no longer persisted on every tab appearance. Slow budget samples, recovery attempts, and resolver warnings remain visible, while correction validation now evaluates only the latest manual edit for an arrival.

### Timeline returns to an interactive frame sooner

- Timeline no longer loads passive motion and walking samples just to render destination cards. Sleep and deliberate workouts remain visible, while catch-up repairs yield to the first frame when returning to the tab.

### Maps identity is now retained on visits

- Migrated the local timeline to V6 so Maps-resolved visits preserve Apple Maps identifiers and their source. Matching now prefers those identifiers, while older, manually pinned, and identifier-less records safely retain the existing name fallback and local backups round-trip both forms.

### Location resolution now protects every timeline mutation

- Arrivals, departures, corrections, Saved Place changes, and relaunch recovery now run one location resolver before data is displayed. Diagnostics validate one current resolved stay, non-overlapping positive durations, hidden superseded callbacks, and preserved manual corrections.

### Place scores follow the complete visit lifecycle

- Place scores now start with zero dwell on arrival, then refresh at Maps lookup, departure, and a manual correction. Each refreshed score retains its inputs and stage, records its threshold and score delta in Diagnostics, and cannot replace a confirmed choice.

### Current roadmap and future release work clarified

- Re-audited LifeLog’s open work against the current implementation, removing shipped items, prioritising the next five code changes, and separating private-app improvements from the additional privacy, quality and distribution work needed for an App Store release.

### Place decisions keep one explainable score

- Saved Place/geofence evidence, Apple Maps distance and category, dwell duration, location accuracy, recurrence, time of day, and prior corrections now feed one place-scoring pipeline. Each visit keeps the component breakdown alongside its stored MapKit candidates for later inspection.

### Place-name fallback matching is consistent

- Place History and monitored-place ranking now use the shared `NameKey` normalization for accent-, case-, and whitespace-insensitive fallback matching. Visit identity by Maps identifier remains a separate V5 migration.

### Place lookups stop retrying on every location update

- An unresolved stay now gets at most three place-resolution attempts, spaced at least five minutes apart. A Maps search and its reverse-geocoding fallback share the same attempt, so repeated noisy fixes cannot keep sending the same place to MapKit.

### Hardware checks now collect proof during ordinary use

- The first real Saved Place geofence entry, exit, Wi-Fi-assisted departure, and completed Core Motion import now leave a concise one-time proof in Diagnostics. Changes to the monitored-place ranking also say how many Saved Places iOS is watching and whether any were excluded.
- Local backups now include the detailed Location journal as well as the ordinary Diagnostics record, so an arrival or departure can be inspected after the fact without arranging a special trip.

### Timeline honours chosen activity icons

- Timeline activity icons now use the saved icon from the Activities catalogue before falling back to keyword inference for uncatalogued labels.

### Diagnostics and Journal Storage UI coverage

- Added deterministic UI coverage for empty journal history, backup and protected-report failures, Accessibility XXXL layout, dark appearance, and VoiceOver-facing labels on Diagnostics and Journal Storage.

### Test suite audit closes weak-test checklist item

- Audited UI and unit tests for conditional assertions and disconnected fixtures. Required UI elements now assert unconditionally, the 20,000-row archive benchmark proves its rows land inside the year and produce totals, and the activity-location rules have end-to-end UI coverage alongside direct unit tests.

### Primary-tab screenshot coverage

- Added a kept XCTest screenshot matrix for Timeline, Insights, Activities, and Settings at normal and Accessibility XXXL text sizes in both light and dark appearances. Seeded captures include the review card, activity sections, and initial location permission state.

### Settings uses accurate saved-place wording

- The Places footer now describes labels, categories, and activities without promising Home or Work roles before those roles exist.

### Date pickers can be cancelled safely

- Timeline and Insights now edit a draft date in their calendar sheets. Cancel leaves the current day or period unchanged; Done commits the selection.

### Activities are grouped by purpose

- Activities now separates recently used labels from history-only labels awaiting adoption, while unused catalogue labels stay collapsed until needed. A search field keeps the grouped list quick to navigate as it grows.

### One clear action on Timeline and Insights

- Timeline review cards now use their orange **Check** or **Categorise** cue without a redundant chevron. Insights uses the date shown between its arrows as its single date-picker control, removing the duplicate toolbar calendar button.

### Insights highlights now point to useful actions

- Insights no longer presents the catch-all **Other** category as a standout activity change, and day headings now use a full localized date. When Health is not connected, a dedicated Apple Health setup card offers the relevant permission action above the chart; the chart centre simply reports that no step data is available.

### Apple Health and Motion Activity now have separate setup paths

- Settings now gives Apple Health and Motion Activity their own status, explanation, and recovery controls. Apple Health opens its permissions in the Health app and can re-import its history independently; Motion Activity can be enabled with its own prompt, refreshed independently, or recovered through iPhone Settings when denied.

### Location permission setup now starts with one clear choice

- Settings initially shows one **Enable location logging** action instead of a permission status, a premature background switch and a differently worded permission button. Background logging appears only after foreground access succeeds, with an explanation that recording while LifeLog is closed requires Always access. Denied access now has a direct route to iPhone Settings, while restricted access is explained without offering a control that cannot work.

### Largest text sizes keep the important controls readable

- Activities gives its text the full row and removes the decorative seven-day sparkline at accessibility sizes, instead of breaking names and statistics into narrow fragments.
- Settings stacks labels, values and toggles vertically when text is enlarged, keeping each control readable and comfortably tappable.
- Timeline drops its decorative greeting at accessibility sizes, caps the floating add control and keeps review text large but bounded, bringing the day’s journey into reach much sooner. Journey entries also replace their fixed-height horizontal card with a flexible vertical reading order, so the newly reachable content is not clipped.

### The visual review is saved as an actionable checklist

- Added the iPhone 17 Pro Max visual-review findings to the active todo list, prioritising large-text reflow before navigation, wording and lower-friction refinements.

### Validation now targets the owner’s iPhone model

- LifeLog’s development workflow now defaults device checks to the owner’s iPhone 17 Pro Max, so layout and behaviour are verified on the device the app is actually used on.

### Insights now explains every period on a like-for-like basis

- The Highlights carousel now appears for Day, Week, Month and Year. Days retain their step and sleep comparisons; every period can also call out its biggest activity change and the place where the most time was spent. The strongest comparison stays first, while supporting cards rotate predictably by period instead of jumping around during a refresh.
- A day still in progress now compares its steps with the same elapsed part of recent matching weekdays, rather than with their finished totals. Month and year comparisons now use the preceding calendar month or year instead of a same-length slice that can drift at calendar boundaries.

### Insights maps keep nearby place names readable

- Place names no longer sit permanently over the map as overlapping tags. Each location is a normal tappable map marker, with its name available in the native callout instead.

### Weekly rhythm is useful from every Insights window

- The weekly-rhythm chart no longer disappears when viewing one day. It now uses the same trailing twelve completed weeks as the trend charts and averages each weekday, so its bars describe a usual week rather than the size of the selected date range.

### The todo list now contains only open work

- Removed completed items from the active todo list, leaving the remaining work and its validation notes easier to review.

### Arrivals now need motion-confirmed evidence, not one GPS fix

- Opening LifeLog no longer turns a single noisy location fix into a visit just because its reported speed looks slow or is missing. It takes up to three live Core Location samples for at most fifteen seconds and creates an arrival only after two recent samples say the phone is stationary. Delayed visit callbacks receive the same check, so an old or drifted callback cannot create a current stay on its own. Diagnostics records the short burst and any reduced-accuracy, unavailable-location or not-in-use signal it receives.

### A car journey no longer loses its middle when motion classification blinks

- The phone was already recognising driving, but a real forty-three-minute trip arrived as four separate 3–8 minute fragments whenever Core Motion briefly stopped calling it automotive. The gaps made most of the trip appear to be absent. Short automotive gaps are now rejoined into one journey, while walking keeps its much stricter gap so steps before and after a drive cannot become one long walk. Existing fragments are repaired once and future rolling imports replace them instead of leaving duplicates behind.

### Apple Maps categories now drive activity inference directly

- A place's Apple Maps point-of-interest category is now mapped straight to LifeLog's activity groups instead of being converted to broad prose and guessed from keywords again, so places such as pharmacies, cafes and cinemas can classify correctly even when their names do not contain those words.

### Trend export filenames now use Swift's ISO 8601 format style directly

- CSV and JSON trend exports still get timestamped filenames, but the timestamp now comes from Foundation's Swift format-style API instead of creating an `ISO8601DateFormatter` and patching its output afterwards.

### A correction made right after an import finishes can no longer be silently reverted by it

- The background import and the screen you're looking at were both able to write to the same stay at the same time, and the import always won without saying so — a departure time corrected a moment earlier could quietly revert to whatever the import's own, older understanding of that stay was. Confirmed with the exact capture that first surfaced it: a departure corrected to 07:02:44 read back as 07:16:22, the import's stale answer, in the same second. The import no longer holds a stay it doesn't own — it keeps its own working copy for placing new records correctly, but only ever writes new records to the store, never a correction to a stay someone else might be correcting at the same time.

### Short walks scattered through a day at home are absorbed, not left stranded

- Nine separate "walking" rows could appear through one day spent entirely at home, none of them merged into the Home stay they happened inside of, even though moving around inside a place you haven't left is already supposed to count as being at that place. The cause: Health's walking data isn't read incrementally, it's re-scanned from a rolling window on every import, so a short burst can be written to the timeline before Home itself has been recorded arriving. Once Home exists, the next re-scan correctly works out that burst shouldn't be there any more — but nothing was going back to remove the copy already written from the first pass, so it stayed stranded. The same repair that already runs on every appearance and after every import for other timing fixes now also cleans this up.

### Home no longer overlaps the place visited straight after it

- Home would sometimes show as still open two minutes after Gracemere Shopping World had already been recorded arriving — a Core Location departure callback for Home can be delayed and is only ever clamped against "now", so a late one could land after a different place had already opened. A person can't be at two places at once, so an already-closed stay's departure is now trimmed back to a later arrival at a different place, the same way an open stay is already closed by one.

### Insights drops its own name and gains a date button

- The word "Insights" at the top of the Insights tab was telling you which screen you were already looking at — the tab bar right below it says the same thing. Removed.
- A calendar button now sits top-right, opening the same date picker the period title in the middle already opened. One more way in, not a replacement — tapping "Today" still works too.

### The lead-in fix needed the archive re-checked once, which the first build didn't ask for

- Shipped without bumping the reconciliation marker, so it would have reached today's walk and every future one but never gone back for a day like 3 August, already sitting in the store under the old rule. The marker now reflects this fix too; the archive-wide pass runs once more on the next launch.

### Steps taken before a workout starts now stay at home, not on the walk

- The previous fix stopped a walk being recorded twice over, but the walk itself still opened a few minutes earlier than it should: waking up, moving around at home, then starting a workout showed as two adjacent entries rather than one, because the stay you left was closing at the moment those pre-workout steps began rather than at the moment the workout did.
- The cause: deciding when a stay was left looks at every movement record independently, and whichever one reaches the stay first wins. A `health-walking` or `motion` record for the same walk as a workout routinely starts earlier — steps taken before pressing start — so it was reaching the stay first and closing it there instead of at the workout's own beginning.
- A weaker record ending within fifteen minutes of a workout beginning no longer gets a say in when a stay was left; the workout alone decides that now. The time before it starts falls back into the stay it was recorded inside, absorbed by the same mechanism that already absorbs any other movement recorded inside an open stay. A real gap before an unrelated, much later workout is unaffected — the fifteen-minute window is deliberately short enough that it can't be mistaken for one.

### A walk is no longer recorded two or three times over

- Cross-checked against Life Cycle, run in parallel the whole time LifeLog has been live: it recorded one walk on every morning this showed two or three. `health-walking` (step counts) and `motion` (Core Motion) are both weaker, inferred guesses at the same real event a Watch workout already declares, and their windows rarely line up exactly with the workout's own — a few minutes either side is normal — so neither ever fully contained the other, which is the only case the existing de-duplication caught.
- A `health-walking` or `motion` record now has whatever a started workout already covers subtracted from it, the same way a Saved Place's time is already subtracted from movement recorded inside it. What is left of the weaker record — the part before the workout started, say — survives on its own; what the workout fully covers does not survive as a second entry.
- This runs twice: once over the last day, every time the Timeline appears or an import finishes, because the weaker record for a walk is routinely imported before the workout that explains it — different HealthKit queries, different delivery timing — so catching it only once misses the ordinary case. And once over the whole archive, on the next launch, to clear roughly a week of walks already recorded twice over since live tracking began.

### A known place stopped meaning "the person agreed to this visit"

- A park on a regular walking route was landing in the review queue — "Did you stop here?" — every single time it was merely passed, because it is a Saved Place: Core Location has matched that coordinate before, so every pass came back `recognitionConfidence == "learned"`, and that confidence alone was protecting it from ever being withdrawn when a route couldn't settle the question outright.
- That conflated two different facts. "Learned" means the *place* has been recognised before — it says nothing about whether *this* particular pass was a stop. Only a chosen activity, typed or picked for that specific visit, is the person actually agreeing with it.
- Without a route to consult, a stay is now superseded when it is unanswered and brief — matching the same ten-minute limit the review queue itself already uses to decide "somewhere passed" from "somewhere spent time." A Saved Place is not, on its own, exempt any more. Duration is what still protects a long stay a workout happens to fully cover, such as a workout started before leaving the house — that guard was never really about the place's name, and now it does the job on its own.
- Independently checked against Life Cycle's own record of the same morning: it logged the whole stretch as one uninterrupted forty-five-minute walk, no stops at all — confirming this wasn't only the park. A five-minute stop recorded moments earlier at a shop the walk also merely passed will fold back into the same walk once this runs.
- Existing installs need one more pass over the whole archive for this to reach a stay already stuck from before; that runs once on the next launch.

## 2026-08-08

### Editing a saved place name no longer mutates the store on every keystroke

- `SavedPlaceEditor` bound its text field straight to the SwiftData model object, causing store updates and query evaluation on every character typed.
- Editing now uses a local draft state that is committed when tapping **Done**, leaving store queries untouched while typing and keeping edits draft-only until saved.


### A journal of the raw location callbacks behind the timeline

- Everything else LifeLog records is a conclusion — a visit, a correction, a sentence in Diagnostics. When a stay lands in the wrong place or at the wrong time the conclusion is the thing in doubt, and the inputs that produced it were gone. This keeps the inputs: what Core Location reported, when it reported it, how accurately, how far from the stay already in progress, and which branch the resolver then took.
- Under **Diagnostics → Location journal**. Arrivals, departures, geofence crossings and ordinary fixes, newest first, each showing how late the callback was delivered — a stay that looks mistimed is usually a callback that was — and whether it was merged, closed, created or ignored. A departure that matched no stored arrival is called out, because that is a real observation the timeline has no record of acting on.
- **It holds precise coordinates, deliberately**, which is the opposite of every other diagnostic. So it is written only while detailed location diagnostics are on, which is off unless you turn it on, is trimmed to the most recent 500, and can be emptied from the journal itself. The Settings footer for that switch now says so; it previously promised only place names and distances, which would have understated what it turns on.
- Storing this needed a new table and nothing else — no existing type gains, loses or changes a field — so upgrading carries every visit, place and correction across untouched. Adding an identifier to `Visit` to reference instead would have rewritten all 25,000 of them; the journal points at a visit by its arrival time, the way corrections already do.

### The visit editor now says why it settled on a place, not just how sure it was

- "Confirmed", "Learned", "Medium" is a verdict with the reasoning left out. When a name is wrong, what matters is not how confident the app was but what it was reading.
- Under Recognition, beside the confidence it already showed: whether a Saved Place covers this spot and how far from its centre the visit fell, which Apple Maps candidate the name came from and how far away that was, whether Maps supplied an identifier rather than just a matching name, and how many times the place has been recorded before. When the name matches none of the candidates Maps offered, it says so — that is a correction, a Saved Place or a typed name, and it should not read as a Maps result.
- It is in the section that already answers "how did LifeLog work this out", rather than a new one competing with it.
- **No coordinates appear anywhere in it**, and a test enforces that rather than trusting the wording. The map above already shows where the visit was; this screen is meant to be read and pasted into a bug report, and repeating a precise position as digits is a different thing entirely.

### A walk with no position now shows the places either side of it

- Editing a walk imported from Health showed no map at all, because there is nothing to put on one: these records are built from step counts, which carry no location, so they are stored with no coordinate and no route. That left the entries hardest to judge as the only ones with nothing to judge them by.
- The editor now shows where the record sits — the stay before it and the stay after it, pinned, with the distance between them. For a walk that is really half an hour of shopping the summary line settles it on its own: "29m · Gracemere Shopping World to Star Liquor, 455 m apart". A walk that begins and ends at the same place says so instead, which is what pacing about at home looks like.
- The pins are not this entry's position and the screen says so. LifeLog has none for it, and drawing one would be a guess dressed as a record.
- Found while testing this: the seeded walking visit used for UI tests was being given a shopping centre's coordinates, so the fixture disagreed with every real store and hid this case entirely. Records from Health and Core Motion now seed with no coordinate, as they are actually stored.

### The background import now says it ran, whether or not it was slow

- It is the writer that lands on top of everything else — its own store connection, its own copies of the same visits, and the save that wins — so "did it run, and when" is the question every visit correction is now sequenced against. It answered that only on launches where it happened to take longer than 250 ms. The two entries that finally explained four failed fixes, at 334 ms and 361 ms, were luck.
- All ten timing samples in the app were checked rather than just this one. Three of them — launch service setup and both Insights passes — sat beside a budget line already measuring the same interval unconditionally, so they only ever added a second and contradictory row: "Slow, 150 ms" next to "Budget pass, 150 ms / 250 ms", for one measurement. Those are gone.
- The five that remain are all computations whose results are on the screen in front of you, so their absence is visible without a log. A timing sample is the right instrument there, and the wrong one for anything whose silence is indistinguishable from success.

### Shopping is no longer recorded as a 29-minute walk between two shops

- A shop visit on 8 August ran 9:36 to 10:07 and appeared as two minutes of shopping followed by twenty-nine minutes of walking — to a shop 455 metres away, reached by car. Two separate faults each produced half of it.
- Walking records are built from step counts, not from a walking workout, and bursts of stepping less than **five minutes** apart were fused into one walk. Steps around the first shop, steps to the car, and steps inside the second fused into a single record spanning the drive. The gap is now ninety seconds, which still absorbs a wait at a crossing but no longer spans a journey by car.
- Separately, a walk beginning inside a stay was read as the moment the person left it. That is right for the walk out the door, and wrong for walking about inside a shop: here the steps began two minutes after arriving, so the stay was bounded there and the rest of the visit became the walk. A journey may no longer consume more than three quarters of the stay it supposedly left — a stay that is almost entirely walking was never a stay.
- Neither of these can be settled properly without the walk's route, which these records have never carried. What has changed is that the two readings the data plainly does not support are refused.

### Typing a place name no longer costs as much as the archive is long

- Every character typed into a visit's place name was written straight into the store. That changed a visit, which invalidated every `@Query` watching visits — this screen's own, and the Timeline still mounted behind it — so a keystroke re-read the archive before the letter appeared.
- The screen then rebuilt itself from that archive. Which activities have been used at this place, and how many times the place has been visited before, were each answered by scanning every visit ever recorded — three scans a keystroke, with the activity catalogue decoded from JSON and re-sorted alongside them.
- Typing now stays in the fields and reaches the visit at the one point that already saved it, so the store is written when the edit is finished rather than while it is being made. The two questions the screen asks of the archive are answered by one scoped fetch, when it opens and when the name is committed, and the catalogue is read once.
- The scoped fetch narrows in the store and then applies the same name comparison used everywhere else, so a place is still matched ignoring case and accents — and a longer name that merely contains the one typed is still a different place.

### The journey correction now lands after the import, not under it

- Re-applying the correction whenever the Timeline appeared was still not enough: the background Health import runs at launch too, finishes second, and its save overwrites. The log caught both events in the same second, with the old value back 36 seconds later.
- The correction now also runs when the import announces it has finished, so it lands on top of that write rather than beneath it.

### The gap before a walk closes, and stays closed

- The repair had been correct for four builds and invisible every time. The diagnostics finally caught it: the stay's departure was written as 07:16:22 and read back as 07:02:44 **in the same second**, with the background Health import running in that second.
- That import has its own store connection and holds its own copies of the same visits, loaded before the repair. It saves last, so its older copies win — on every launch, which is why each fix appeared to do nothing.
- Rather than sequence two writers, the correction is now re-applied to the last day every time the Timeline appears. It changes nothing when there is nothing to change, and covers a day rather than the archive, so losing the race costs a moment instead of a release.

### The reconciliation pass now reports what it decided

- Instrumentation, not a fix. A gap between waking up and a morning walk has survived three attempts, and the pass that should close it leaves no trace either way, so each attempt was a guess.
- Running `reconcileAll` offline over the complete exported store — all 673 recorded visits — closes the gap in under a tenth of a second. On the phone it does not. Every explanation for that has been wrong, so the pass now says what it did to each of the last day's journeys: bounded the stay it left, held the stay open until it began, or changed nothing.

### The reconciliation pass now says whether it ran

- Reported before any guard, on every appearance, so an already-completed marker cannot return in silence — the first attempt at this logged from inside the branch the marker protects, which made "already done" and "never reached" look identical.
- A reported gap survived two fixes, and neither could be checked: `Diagnostics.performance` only records operations slower than 250ms, and this pass takes milliseconds — so a repair that ran, and a repair that never ran, left exactly the same trace, which is none.
- It records either "Reconciliation ran over N visits" or "Reconciliation deferred: N visits loaded, none from a device yet", every time, in **Settings → Diagnostics**. The count distinguishes an empty query from a store genuinely holding no device activity, which are different faults.

### Timeline repairs were being marked done without running

- The reported 14-minute gap survived the fix meant to close it, and the reason was worse than the gap. Repairs that run once per version are guarded by a stored marker, and that marker was written whether or not the repair actually happened: the work is skipped when the timeline query holds nothing, which on a launch is far more often "not loaded yet" than "nothing to do".
- So a repair could be recorded as complete having never executed, and no later launch would try again. Bumping the version to ship a fix did not help, because the new marker was written the same way on the first launch that saw an empty query.
- This affected every timeline repair shipped this way, not only the newest one. The marker is now written only when the work is done; an unloaded query means try again next time.

### The minutes before a walk belong to where you were

- Getting up at home before this morning's walk showed as fourteen minutes of "Unlogged". Home closed at 07:02:44, the walk began at 07:16:22, and nothing at all claimed the time between — so Insights was right, and the recording was what was missing.
- Core Location times a departure from a geofence crossing, not from the moment somewhere stopped being where you were. A stay closed shortly before the journey that left it now holds until that journey begins.
- Nothing is invented. If you had gone somewhere in the gap there would be a record of it, and the rule refuses when one exists. It also refuses after half an hour, past which "must have still been home" would be a guess rather than the only reading the records allow.
- Applies to timelines already recorded, not only to new ones — so mornings already logged this way are corrected too, and their numbers will shift slightly.

### The donut fills its card, and you can scroll past it

- Scrolling over the chart did nothing. It carried a zero-distance drag gesture to catch taps, and that claims *every* drag beginning anywhere on it — so the ring was a dead zone the height of the card and the page could only be moved around it. It reads taps as taps now, and lets a drag through.
- The ring is a square sized from the card rather than a fixed height, so it fills the width instead of sitting in a band of empty card. The hole grows with it, which is the one thing the step count in the middle has always been short of.
- The legend underneath is gone. Each wedge already carries its icon and its hours, and tapping one names it in the centre and turns that centre into a button onto the same visits the legend rows opened.
- A wedge too thin for a label used to be a bare colour with a key underneath; with no key, thin wedges now keep their icon down to a much smaller share, and drop only the duration.

### Home is a place, not a word

- "Time away from Home" decided what counted as home by looking for the letters "home" in a place name or activity. Anywhere carrying them — a Homemaker Centre, a suburb called Homebush — counted as being home, and a home saved under any other name did not.
- It now measures against the place you saved as Home: its coordinate and its radius. A stay there counts as home even when Core Location never worked out what to call it. With no Home saved, the wording is still read, because then the name genuinely is all there is.

### Your day fits inside its card

- Each block in the 24-hour bar took its share of the full width, and then a gap was added between every pair on top of that — so the bar overran the card by two points per block, worse the more broken up the day was. The gaps come out of the width first now.
- The "Grouped by activity" bar below it is gone. It said what the donut says, in a second shape, without the labels that make the donut readable.
- Unlogged time moved here as a footnote under the day, which is where a caveat about the day belongs.

### One colour language on Insights

- Activity changes drew its bars orange for up and blue for down, on a screen where colour otherwise means *which activity*. Home read as orange there and green in the bar directly above it.
- The bars now wear each activity's own colour, taken from the same slice the donut uses so the two cannot drift apart, and the **+** or **−** carries the direction on its own. VoiceOver says "up" or "down" outright, since colour is no longer doing that job.

### Timeline quality moved to Diagnostics

- Callbacks reviewed and duplicates resolved are the app reporting on its own plumbing, on a screen that answers where your time went. They are in **Settings → Diagnostics** now, counted from the store directly so that screen no longer depends on Insights having been opened first.
- It was also the only card on Insights narrower than the rest — nothing inside it was full-width, so it shrank to fit its own text while every sibling was stretched by a progress bar or a chart.

## 2026-08-07

### On this day

- Under whatever day you are reading, the same date in earlier years — where you were, longest first. Tapping a year opens it, and that day has its own earlier years beneath it, so the archive can be walked rather than only queried.
- It reports **places, not activities**. Almost the whole archive arrived by bulk import carrying labels the old app defaulted to, so an activity read back from 2019 is often not what happened; a place name came from an arrival that was really recorded.
- Only the part of a stay that falls inside the day counts towards it, so a night at home does not outrank a working day on hours it spent in a different date.
- Years with nothing recorded are left out rather than shown as blanks, and the search stops at your first record instead of offering years that cannot hold anything.

### Two ways to do something are one too many

- **Settings → Edit Current Location** is gone. It opened the same editor, on the same visit, that tapping the current activity on Timeline opens — where the activity is already in front of you, and where an uncategorised one is surfaced more plainly anyway. Settings keeps **Locations**, which is a different thing: the places you have saved.
- **Settings → Activity Labels → Add from your history** is gone, now that the history has been imported. Adopting a label happens on the Activities tab instead, on the row for that label, where its occasions and hours are visible while you decide — either by swiping the row or by opening it. The bulk list showed none of that.

### The journal can be read as a journal

- Timeline only ever showed today. Nine years of recorded days existed and could not be opened — they were reachable only as totals in Insights, which answers "how much" and never "what happened".
- Tap the date to open a calendar and pick the day you want, anywhere back to your first record. A **Today** button brings you back to the live screen. There are no day-at-a-time arrows: nine years is far too much history to step through, so naming the day is the way in.
- Date navigation alone would not have been enough: Timeline's query deliberately excludes the imported journal to keep launch fast, and the imported journal is what nine years of past days are made of. A past day now fetches for itself, scoped to that day, so opening one in 2017 costs the same as opening yesterday and the archive is never loaded whole.
- A past day is measured against the end of that day rather than the present. An unclosed stay from 2019 would otherwise have been reported as still running, six years long.
- The greeting, the date and the review queue stay on today, where they mean something. A past day is just the day.

### A label from your history can be added where it says it needs adding

- A label that exists only in recorded visits is marked "From your history · not yet an activity", and tapping it is the obvious response. That opened a statistics page with no way to act on what had just been announced — the only way to add it was a swipe, mentioned once in small print at the bottom of the list.
- The page now offers **Add to Activities** at the top when the label is not in your list, and says what adding it gets you: a group, an icon, a colour, and Insights counting it properly instead of as Other. The footer no longer pretends the swipe is the only way in.
- There are three ways to adopt a label now — the bulk sheet, the swipe, and this button — so they share one implementation. The same label cannot come out looking different depending on which one you used.

### Insights sits next to Timeline

- Tab order is now Timeline, Insights, Activities, Settings. The two views of the same days — as they happened, and totalled up — are next to each other, which is the move you actually make.

### Deleting an activity no longer decides its group by accident

- Deleting `Eating` left every meal grouped under Food & Drink. Deleting `Work` moved 2,732 visits to "Other". Same action, opposite result, and nothing on screen explained why: a hand-written list inside the app happened to mention one name and not the other.
- That list held the same facts as the shipped activity list, in a second copy nothing kept in step. Eight shipped activities were missing from it — `Work`, `Commuting`, `Home time`, `Swimming`, `Yoga`, `Strength training` among them — and each lost its group when deleted. Yesterday's rename of `Working` to `Work` left it pointing at a name the app no longer ships, which is the same fault happening again in miniature.
- There is one list now. The group a deleted activity keeps is read from the shipped activities themselves, so it cannot fall out of step with them, and all eight are covered.
- Re-grouping a shipped activity in Settings now works. The hand-written list answered first and never consulted your catalogue, so moving `Eating` to a group of your own was quietly ignored.
- An activity you named yourself still falls to "Other" when you delete it. LifeLog knows what `Swimming` means and does not know what your own label means, and inventing a group for it would be a worse answer than admitting that.

### Inference finally uses your word for work

- Adopting `Work` from your history was supposed to make inference write `Work`. It kept writing `Working`, because the label LifeLog ships with is itself called `Working`: resolving a label takes an exact catalogue match before it tries the rule that folds `Working` and `Work` together, so the shipped entry matched itself and the one you adopted was never reachable.
- The shipped label is now `Work`, and a catalogue that already holds `Working` has that entry retired on next launch. The visits move with it — a rename that left them behind would strand every one of them on wording the catalogue no longer knows, which is what sends visits to "Other".
- Where `Work` had already been adopted, the two merge rather than sit side by side, and your own entry keeps the group and symbol you gave it. It happens once, so renaming an entry back to `Working` on purpose stays that way.
- Each label had a test on its own; nothing tested a catalogue holding both, which is how this shipped. That case is covered now.
- Renaming the shipped label uncovered a second fault sitting behind it. Commute detection, travel labelling and the Add Visit suggestions all decided "is this a workplace?" by comparing the *displayed* label against the fixed word `Working`. That only ever worked because the shipped label was spelled the same as the concept behind it — so renaming `Work` to anything of your own, which the app invites you to do, would have quietly stopped LifeLog recognising your commute. Those checks now ask what the place *is*, separately from what it is called.

### A save that fails overnight no longer disappears without trace

- A background save failing only set an in-memory message shown in Settings. Core Location wakes LifeLog while you sleep, so a failure at 3am was gone by the time you looked — nothing said an arrival had been dropped, or why.
- Failures are recorded to Diagnostics now, which meant solving the obvious circularity first: Diagnostics is the same store, so the write that records a failed save is a write to the store that just refused one. Failures are queued outside SwiftData instead, and moved into Diagnostics at the next save that works or at the next launch.
- A store that keeps refusing writes cannot flood the queue. It holds the first fifty failures rather than the last, because the earliest ones explain how it started.
- The entry records the error's domain and code, not its text. A Core Data error can name the entity and attribute it failed on, and diagnostics stay clear of anything describing where you have been.

### One walk is one row again

- A 2.69 km morning walk was appearing on Timeline as two separate "Walking" entries of 709 m and 324 m, with a "Visiting Gracemere Pump Track" card wedged between them. Three of the four walks recorded since geofencing arrived were broken the same way, and the missing 1.66 km in the middle had not been hidden — it was never written down.
- The cause was the import path subtracting every place that overlapped an incoming record. Timeline's own reconciliation stopped doing that to a started workout some time ago: pressing Start is your own account of what that time was, and no Core Location guess outranks it. The importer never learned the same rule, so a stay recorded partway round the walk cut the workout up as it was saved — and the pieces no longer overlapped the stay, which is exactly the evidence needed to recognise the stay as a drive-by. Each fault protected the other.
- Both paths now agree. A workout is imported whole, and the stays it merely walked past are withdrawn before anything is allowed to cut it.
- Deciding whether you stopped somewhere now asks the walk's own path whether it kept moving. This replaces a guess based on how the place was named: a park you saved yourself, walked straight through at a steady pace, was previously untouchable and split the walk in two. A path that goes nowhere for the whole time still reads as a real stop, so pausing mid-walk keeps its place.
- Walks already broken in the store are put back together on next launch. Every fragment carries its Health session's identifier, so the halves are rejoined into one journey with no guesswork about which belonged together. The clipped part of the route cannot be invented, but Health still has it — **Settings → Reimport Health history** restores the full path, and re-runs the repair with the complete route to judge by.

### `ActivityImportActor` no longer mixes reading with writing

- The file held two complete, unrelated `actor` types in 521 lines: one reading HealthKit and Core Motion, one writing the results into SwiftData. Neither ever touched the other's concern; they only shared a file.
- Split along that seam. `ActivitySampleReader.swift` now holds everything that reads Health/Motion data and turns it into plain records; `ActivityImportActor.swift` keeps only the SwiftData writer. `ActivityDataService` already coordinated the two as separate collaborators, so this is a move, not a rewrite — no behaviour changed, and no other file needed to change.
- `ActivityLocationPolicy` has a version of the same problem, mixing six concerns rather than two split across two types. That one is a bigger job — noted in TODO with the breakdown.

### The home illustration had a checkerboard baked into it, not a background

- The new home artwork looked fine on white and wrong everywhere else: a visible grey-and-white grid behind the house, in both light and dark mode. The file had an alpha channel but no pixel in it actually used one — the "transparency" was a checkerboard pattern flattened into ordinary opaque pixels, the same fault caught in the football scene yesterday.
- Removed in three passes: flood-filled the checker from the canvas edges inward, then found the alternating pattern sealed inside the artwork itself — the soft edge of the watercolour wash — where a plain colour test would have punched holes through the wash rather than clearing only the grid. A last pass caught the faint scattered flecks left by the wash's antialiased edge, without touching the actual line art.
- The rounded-rectangle border that had been baked into the previous version of this asset is gone from this one — a real change in the new source art, not something fixed here.

## 2026-08-06

### The current-activity picture no longer speckles black at night

- Stripping the outer white background and border from each PNG (above) fixed the edges, but not the gaps *inside* the drawings — a highlight on a bowl, a seam in a tablecloth, the glow under a lamp. Composited straight onto the card, a fully transparent interior pixel reads as paper in light mode and as a black fleck in dark mode, scattered through the middle of the picture rather than around it.
- The current-activity card now always draws the illustration on the same pale panel, with soft rounded corners, in both appearances. A transparent pixel reveals that panel rather than whatever the card's own background happens to be that night, so the speckling is gone regardless of which illustration is showing — including any added later, with no per-image care required.
- Along the way: the football scene had been a duplicate of the home illustration, and both briefly picked up a watercolour checkerboard baked into their pixels as real colour rather than transparency — the same fault the nine scenes added earlier today shipped with, caught and cleaned the same way before either reached a card.

### Updated ActivityHome artwork asset

- Processed newly generated `ActivityHome.png` asset: removed solid white background and AI badge overlay, making the background transparent RGBA so the house illustration and sage watercolor wash blend seamlessly on both Light and Dark mode cards.

### Current-activity card artwork border & cropping fix

- Cleaned all 33 activity scene PNGs across `Assets.xcassets`: stripped out baked outer rounded-rectangle card borders and white background blocks, converting them to 1024×576 landscape artwork on transparent RGBA backgrounds.
- Fixed the vertical white lines and misaligned cropping that appeared on Dark Mode current-activity cards (e.g. `ActivityHome`, `ActivityWorkV2`, `ActivityDriving`, `ActivitySleep`, `ActivityWalking`).

### SavedPlaceLearning preview & applyIgnored performance optimization

- Added `SpatialBounds.box` spatial bounding box predicates to `SavedPlaceLearning.preview` and `SavedPlaceLearning.applyIgnored`. Instead of fetching every `Visit` in a 25,000+ record archive, both queries are now bounded to candidate visits within the place's bounding box.

### Timeline activity artwork clean-up & dedicated scenes

- Removed redundant legacy V1 imagesets (`ActivityBeers`, `ActivityCoffee`, `ActivityDoctor`, `ActivityMeeting`, `ActivityWork`, `ActivityShopping`).
- Added high-resolution, wide-aspect landscape scene artwork for **Football** (`ActivityFootball`) and **Public Transit** (`ActivityTransit`), giving both dedicated illustrations instead of sharing artwork with studying or driving.

### Saved Place cache retained when data store is locked

- `LocationRecorder.loadSavedPlaceCache` no longer clears the in-memory cache of Saved Places if reading the database fails (for example, when a background location callback arrives while the protected store is locked under `NSFileProtectionComplete`). Keeping the previous cache prevents arrivals at known places like Home from temporarily falling back to unknown MapKit lookups.

### Every activity now has a picture

- Nine new scenes: breakfast, lunch, dining out, eating, a concert, studying, socialising, visiting, and watching television. With the artwork already in the app now wired up, all twenty-nine activities have an illustration on the current-activity card — it was twelve this morning.
- Football and studying share one picture. They arrived as a single frame holding a goal, a ball, a desk lamp and an open book, so it reads as either; football deserves its own eventually.
- The pictures came as one sheet with its transparency flattened into a grey checkerboard. That had to be found and removed rather than cropped around — including the pockets sealed inside the artwork, like the glow under the desk lamp, where the checker was tinted warm by the light and had to be smoothed out instead.
- A test now fails if any shipped activity loses its picture, which is how the missing dozen went unnoticed in the first place.

### The current activity's illustration

- Eleven finished illustrations were sitting in the app unused, including a whole refreshed set — tighter, squarer versions of work, coffee, beers, meeting, shopping, fitness, the doctor and family — plus scenes that existed for nothing else: a blood donation, a work trip, a cafe. They are all in use now.
- **Exercising had never once shown its own picture.** The rule looked for "exercise" and the activity is called "Exercising" — "exercis-ing" does not contain "exercise", so it matched nothing and fell through to no artwork at all. Commuting missed the driving scene the same way. Both had usable pictures in the app the entire time.
- Running, cycling, swimming, yoga and strength training now show the fitness scene rather than nothing.
- The pictures are sharper. Each was being shrunk to fit the card and then magnified three times, drawing a small source several times larger than itself. They now fill the card directly, which reaches the same framing at the smallest enlargement that still covers it.
- Ten of the picture files were named `ActivityCoffee.png` regardless of what they showed — the work desk, the beer, the blood donation. Nothing was broken by it, because the app reads the name from elsewhere, which is why nobody noticed. Each file is now named after what it is.
- Nineteen of the twenty-nine activities now have a picture, up from twelve. The ten still without are listed in TODO.

### A test that could only ever pass once

- `testAdoptingAHistoryLabelFromTheActivitiesTab` had been failing on every run since the day it was written, and the app was fine. The test adopts "Donate Blood" from recorded history and checks the row stops being marked as history-only.
- The seeded test launch uses a throwaway in-memory database, so each run starts from the same visits. The activity list does not live there — it lives in preferences, which survive. So the first run adopted the label for good, and every run after it found the label already adopted, no marker to check, and failed. Once per simulator, then never again.
- The seeded launch now resets the activity list too, so a run's starting state no longer depends on which tests happened to run on that simulator before it. No effect on the real app: this only applies to the seeded test launch.

### Every night's sleep was counted as time away from home

- "Time away from Home" included every hour you slept in your own bed. Sleep arrives from Health as its own activity, "Sleeping", at a place called "Sleep" — and where an overnight stay at home overlapped it, the sleep record won, because it is the shorter and completed one. Neither of its labels says "home", so the night was read as time spent elsewhere.
- A device record — sleep, or movement the phone noticed — has no place of its own, so it is now judged by the stay it happened inside. A night at home is time at home; a night away still counts as away.
- A visit that names its own place is untouched. Shopping at four o'clock is time away from home whatever else claims those minutes, and an old open stay overlapping it cannot absorb it.

### Insights now says what it noticed, not just what it counted

- **Recurring habits.** Up to two things the last twelve weeks actually say: something taken up again after a gap, a new high, or a run of weeks. "Back to entertainment — first time since June, after seven weeks away." Sleep and time at home are left out; doing them every week is not a habit worth reporting, and both have their own cards asking how much instead.
- **Recent months.** Two lines, home and sleep, a point per week over twelve weeks, with the usual week drawn behind them as a dashed rule. Underneath, the comparison in plain hours: "Less home than usual last week — 36h 52m against a usual 47h 46m." Weekly rather than daily, because hours at home swing between nothing and twenty-four depending only on whether you went out — a daily line draws your calendar, not your habits.
- **A day now opens with what stood out.** Steps against the same weekday over recent weeks — a Saturday measured against a week of Mondays would read as a triumph every weekend — and sleep against the last fortnight of nights. Swipe between them. If there is no history to compare against, nothing is claimed; and anything within a tenth of usual is called "about the same", because inventing a trend out of three percent makes everything else here less believable.
- Shifts in how time was spent are reported, never congratulated. Steps and sleep have a direction everyone agrees on. Eleven hours more at home is a fact about a day, and cheering it would be the app having an opinion about how you should have spent it.

### Your weekly rhythm is a chart now

- It used to name the single biggest activity for each weekday in seven small tiles. It is now a bar for each day, stacked by activity, in the same colours as the ring above it.
- Sleep is left out. It is the largest and steadiest block of nearly every day, and including it flattened all seven bars into near-identical columns — burying the differences between the waking days, which is the only thing the chart is for.
- Every day of the week is always drawn, including the empty ones. A week with nothing recorded on Monday previously had no Monday at all: the bars slid across and a quiet day was indistinguishable from a missing one. The week also starts on the day your calendar starts it.
- "View full chart" opens a larger version with each day listed out and its activities broken down.
- It no longer appears in the Day window. A single day cannot have a weekly rhythm, and six empty bars said nothing true.

### Smaller things on Insights

- **Top Activities**, showing each activity's share of your logged time, with the rest a tap away.
- **Your day** gains a second bar underneath the hour-by-hour one, grouping the same day by activity, largest first — the ring's answer in a straight line. Both are tappable.
- The file behind this screen was called `TrendsView` while the tab, the folder and everything on it said Insights. It is `InsightsView` now.

### Two screens called Activities, showing different lists

- The Activities tab and Settings → Activities looked like the same list disagreeing with itself. They were never the same list. The tab reports on how much you do each thing; the Settings screen edits the vocabulary — the names, groups and icons. Settings is now called **Activity Labels**, so the difference is visible before you go looking for it.
- The lists differ because the tab also shows labels found in your recorded visits that were never added to your activity list — which is most of a bulk-imported history, and a screen about where your time went should not hide it. Those rows now say so, instead of silently behaving differently from the ones above them.
- They can be added where you find them: swipe a history label and tap Add. It joins your activity list with a suggested group and icon, and Insights stops counting it as Other straight away. The same thing "Add from your history" does in bulk, offered on the row where you can already see how much of your time it accounts for.
- The footer counts what is left, so the gap between the two screens is a number you can work through rather than something you have to notice.

### The date was unreadable in dark mode

- The day you are looking at, under "Today" on Insights, was drawn in dark blue on black. It sat inside a button, and a button tints its own label — so what was asked for as "secondary text" came out as a dim shade of the accent colour instead of a dim shade of the foreground. It now uses the colours it was always meant to. This was wrong at every text size, not only large ones.

### Insights and Timeline at the largest text sizes

- Checked on the 6.9" screen at the largest accessibility size, in dark mode, for the first time. Both screens were broken there.
- The Insights ring is a fixed size and the writing inside it was not. At the largest sizes "1h 10m" lay across the segments, "steps" ran under the tab bar and "Connect Apple Health" was written straight over the ring. Text inside the ring now stops growing at the point it would leave the ring. Everywhere else on the page still scales the whole way.
- Headings had begun crowding out what they introduce. "Good Morning" and the date filled a third of the screen; "How you spent your time" and its subtitle took six lines and pushed the chart below the bottom edge. Both stop growing before that happens. The count of places to review is not capped — it is the one line there worth acting on, and it now wraps instead of cutting off mid-word.
- The review card squeezed its text between an icon, a button and an arrow until "Is this right?" wrapped one word to a line. At accessibility sizes the icon and arrow now step aside and the button moves below at full width.
- Ordinary text sizes are unchanged.

### A walk you started is a walk, and it was being deleted

- A morning walk from home, with a workout running on the Watch, appeared nowhere — not on the timeline, not in Insights. It had not been hidden. It had been deleted.
- Any stay overlapping a walk is subtracted from it, and the test for whether the stay really contained the walk is how far the walk's own path got from it. With no path there is no answer, and LifeLog treated "unknown" as "yes". Home and a stay recorded partway round both claimed the walk, nothing was left of it, and the record was removed.
- No walk had a path, because Health had never been asked for Workout Routes. So this had been happening to every walk.
- A workout you started yourself is now believed. It keeps its own row whether or not a route was recorded, and no stay can subtract it away. The exception is its own path: a route that never leaves the place is proof you did not, and pacing about the house with a walking workout running is still pacing about the house. Movement the phone merely noticed — not a workout you started — is unchanged.

### Places invented while you were out walking

- A stay recorded while a workout was running is now treated as somewhere you passed, not somewhere you went, and no longer appears or asks to be confirmed. Walking through anywhere with businesses nearby produces an arrival, and Apple Maps names whatever is closest — which is how a lap of the lake became "Is this right? Gracemere Lake Golf Club".
- A genuine stop still counts. Somewhere you have saved is never affected, nor anywhere you named or corrected yourself, nor a stay that mostly outlasts the workout — stopping in for an hour afterwards leaves a stay reaching well past the session, and it stays. The record is kept and readable in Diagnostics rather than thrown away.

### Getting back what was lost

- Settings gains "Re-import Health history". LifeLog reads Health from a bookmark, so anything it discarded after reading is not returned by an ordinary refresh — including the walks deleted by the rule above.
- It reads the last 30 days again from the start. Existing entries are updated rather than duplicated, a confirmed activity is never overwritten, and a walk that already has a path keeps it.
- Worth doing once after granting Workout Routes: it fetches the paths for walks already imported without one, which is what lets LifeLog tell a walk that went somewhere from one that circled the house.

### Last night's sleep could be missing all morning

- An Apple Watch writes the night's sleep to the phone some time after waking, and LifeLog listens for exactly that so it lands in the timeline on its own. It has not been working. The sleep notification arrived, asked for an import, and was turned away by a six-hourly timer that a Core Motion sweep had set — one throttle covered both sources. Sleep would then appear hours later, for no visible reason.
- The two now have separate schedules. Motion keeps the long interval: its queries are expensive and it only holds a week of history. Health repeats freely, because it is read from a bookmark and only ever collects what has arrived since.

### Health said "Not connected" when only one category was missing

- Workout routes are a separate permission from workouts, and were added to what LifeLog asks for after sleep, workouts and steps had already been granted. Because LifeLog asked about all four together, one never-requested category made the whole lot report as disconnected.
- Each category is now checked on its own, so the status reads "Connected", "Partly connected" or "Not connected" — and Settings names the ones iOS has never asked about, which is why the permission sheet can be shorter than the list above it.
- Consequence worth knowing: route access has been missing since walks first gained a path, so recorded walks have had no route. Granting it now is what lets a loop around the block be told apart from pacing at home.

### Apple Health said "Not connected" and would not reconnect

- Settings could sit on "Not connected" indefinitely with no prompt and nothing to press. Two things caused it, and they hid each other.
- Whether to show the Health prompt was decided by LifeLog's own note that it had asked once before — not by asking iOS. If that note was ever set while authorisation did not actually complete, LifeLog would never ask again.
- The status label itself was only ever set as a side effect of a successful request or an import. Imports are throttled to once every six hours, so on most launches nothing set it at all and it stayed on its start-up value of "Not connected" — whatever the true state was.
- LifeLog now asks HealthKit directly whether the prompt is still available, at launch and every time the app is brought to the front, and shows the prompt when it is. The label reflects what iOS reports rather than what LifeLog last remembered.
- If Health is not connected, Settings now offers "Connect Apple Health" instead of leaving a dead end. Because iOS only ever shows the sheet once, the screen also says where to go when nothing appears: Health → Sharing → Apps → LifeLog.
- Worth knowing: Apple never tells an app whether reading was actually allowed, only whether it has asked. "Connected" therefore means the question has been settled, not that data is flowing — which is why the pointer to the Health app is there.
- The "turn these back on" note was previously shown when either source read "Denied", but nothing ever set Health to "Denied" — only Motion could. It now says Motion & Fitness, which is what it always meant.

### One answer to "is this the same place?"

- Comparing two place or activity names was written out separately in five places, and they disagreed. Three ignored accents and two did not, so `Café` and `Cafe` were one place to the part of LifeLog that resolves a stay and two separate activities in Insights. Three trimmed stray spaces and two did not. All five now go through one rule, so a name means the same thing on every screen.
- The visible effect is small and in one direction: totals that were split by an accent or a trailing space now add up together.

### Code that was never running

- A place lookup carried a token so a correction could cancel that one lookup. Nothing ever cancelled by token — the path had been dead since it was written, while the token was still being created and passed around on every lookup. Removed. Editing a visit still cancels lookups; it cancels all of them, which is what has actually been happening all along.
- Health background delivery was still behind a validated/not-validated flag that was set to true unconditionally at launch, along with the disable path nothing called. Removed; the behaviour is unchanged.
- Also removed: three Health and Motion import entry points left over from when Settings had buttons for them, an unused review-queue explanation string, an unused inference summary, an unused performance budget, and a diagnostic decision nothing ever recorded.

### Files you can find things in

- Every source file used to sit in one flat folder of fifty-three. They are now grouped by what they do: App, Model, Location, Activity, Journal, Timeline, Insights, Places, Settings, Diagnostics and Support.
- The two largest files were doing several jobs each. The timeline no longer also contains the visit editor and the activity artwork; Insights no longer also contains the ring, the map and the whole aggregation. The largest file dropped from 1,360 lines to 506.
- The Insights aggregation was private inside its own view, which is why it has never had a single test. It now lives on its own and can be reached from one.

## 2026-08-05

### Diagnostics say why a location was changed

- When LifeLog merges two records, closes a stay, supersedes a duplicate or renames a place, it now writes down which rule decided that. None of it was recorded before, so a stay that disappeared or a name that changed left no trace of what was responsible, and working out why meant guessing.
- Apple Maps lookups record what was asked and what came back: a cache hit or miss, the radius searched, how many places were offered, the confidence, and whether it fell back to reverse geocoding.
- Settings → Troubleshooting adds "Detailed location diagnostics", off unless you turn it on. With it on, the same entries also name the places Maps offered, how far away each was, and which was chosen. That is a detailed record of where you have been, so it stays on this iPhone and expires with everything else in Diagnostics.

### Places are remembered by identity, not by spelling

- A place was recognised by its name and how close it sat to another. That cannot tell two businesses apart when they share a name, and it loses track of one the moment Apple rewords it or you rename it yourself. Places found through Apple Maps now keep Apple's own identifier for them, which survives both.
- The first thing this fixes: deciding whether a place is already known used to mean "within fifty metres", so two different businesses on the same block could be treated as one. Where an identifier is known on both sides it now decides, and distance is only the fallback.
- Places you pinned by hand, and everything saved before this, carry on working by name and location exactly as before.

### Your own places are recognised as you arrive

- A saved place used to be worked out after the event, by measuring how far a delivered visit sat from each one. That waits on a callback which can arrive long afterwards, and in the meantime Apple Maps could write a neighbouring business over the top of somewhere you had named yourself. LifeLog now watches the boundary of each place, so arriving at Home is recorded as Home the moment you cross it — with no delay and no Maps request.
- Leaving is recorded the same way. A boundary crossing is the departure itself, seen as it happens, rather than worked back from wherever you turned up next.
- iOS only watches a limited number of places at once, so LifeLog picks by how often each is used and then by how recently. Somewhere you go daily keeps its place over somewhere you visited once, however lately.

### Adding a visit asks where you were, not what to search for

- Add Visit is now three questions: where, what you did, and when. Location and activity each open a page of their own instead of being fields to fill in.
- "Where?" lists everywhere around you, closest first, with the distance to each. Places already in your timeline appear alongside them, marked, and keep your name for them rather than Apple's. You can still just type a name. Previously you had to think of a search term, press Search, and hope.
- The arrow beside a place opens it on a map: move the pin, rename it, and see everything you have ever recorded there. A place you already use can be merged into another or deleted from the same screen — merging renames its visits onto the place you choose rather than discarding them, and deleting removes only the place, never a visit.
- Underneath the times, LifeLog now offers the gaps in your own timeline: stretches it has nothing recorded for, with its reading of what they were. The same place either side means you were probably still there; home on one side and work on the other is a commute. Tapping one fills the whole entry in.

### Group colours you can tell apart

- Work and Entertainment were both plain purple. Side by side in the Insights donut there was no telling which was which.
- The groups most of a day is made of — Home, Work, Sleep, Commute, Food & Drink and Fitness — now have widely separated colours, so the chart reads at a glance. The rest are deliberately variations on their neighbours: they appear in small slices, and giving each a completely distinct colour would only blur the ones that matter.
- The colour drawn and the colour reported are now the same. They came from two separate lists that had already drifted, so Entertainment was purple in the chart and grey in exports and in what VoiceOver announced. One list also matched group names exactly while the other ignored case, so the two could disagree on the same group.

### Delete moved away from the back button

- Deleting a visit was a small trash icon in the top-left corner, right beside the back arrow — a destructive action exactly where you reach to leave the screen. It is now at the bottom of the visit, and still asks first.
- Saved places can be deleted from the place itself, at the bottom and behind a question, rather than only by swiping a list where a stray scroll could do it.
- Deleting an activity from its own screen now always asks, instead of going ahead silently when nothing was using it.

### Relabelling a walk survives

- Calling a recorded walk "Dog walk" would have been undone. Apple Health and the iPhone's motion history replay their samples, and a replay overwrote the label unless the entry had been confirmed — which only happened for entries with a location, and a walk has none. Your own labels on walks, workouts and sleep now stand.
- "Dog walk" is in the Activities list, grouped under Fitness.

### The activities LifeLog creates now exist in your list

- Sleeping, Walking, Running, Cycling, Swimming, Yoga, Strength training, Commuting, In transit and Home time are all things LifeLog records for you, and none of them were in the Activities list. Each arrived as a grey dot with no colour and no group of its own, and could not be given one without you typing the name yourself — while the Sleep and Commute groups sat empty despite the timeline being full of both. They are now proper activities, added once to a list that predates them, and anything you delete afterwards stays deleted.
- Four more icons: an electric car, a balloon, and two-person and family symbols. A hundred in total.

### Wi-Fi sharpens when you left

- Leaving somewhere is rarely noticed at the time. Core Location reports a departure only once it sees the region was left, so LifeLog fell back to timing it from wherever you turned up next — which is why leaving home at 8:40 and reaching work at 9:09 was recorded as leaving at 9:05, and a twenty-five minute commute read as four.
- Your home network drops when you walk out the door. If LifeLog sees the phone leave the network a stay began on, that moment is used as the departure instead of the next arrival.
- Losing a network is never treated as leaving. A router restart, a band switch, or the phone preferring cellular would otherwise invent a departure that never happened; rejoining the same network erases the absence entirely. Nothing is written unless a departure was already being guessed at, and the corrected time can only ever sit inside the stay it belongs to.
- Networks are stored as a digest, never as a name. LifeLog only needs to know "the same one as before" — which network it is says where you live, and is not recorded.

### Walking and travel are collected without being asked for

- Your walks and drives were missing even though Motion Activity said "Connected". The iPhone keeps its motion history for about a week, and LifeLog only read it when you pressed "Connect Walking & Travel" in Settings — so every week you did not press it expired unread, permanently. Apple Health was never affected, because its samples persist and are read from where LifeLog last stopped, which is why sleep and workouts arrived normally while walking and driving did not.
- Both sources are now asked for once, on first run, and collected from then on: when LifeLog opens, when you come back to it, and when Apple Health has something new. The week of motion history is always gathered well before it expires.
- The "Connect Apple Health", "Connect Walking & Travel" and "Import Recent Activity" buttons are gone. Settings shows what each source is doing and when it was last collected. If you have refused one, it says where to turn it back on — iOS never asks a second time, and that is the only part LifeLog cannot do for you.
- Apple Health updates now arrive in the background by default, rather than only while the app is open.

### Ninety-six icons, and a picker you can see them in

- Activities offered ten icons, and none of them were the ones the app ships with — so opening Coffee, Beers, Concert or Watching a movie showed a picker with nothing selected, as though the icon had been lost. There are now 96, grouped as Home, Work & study, Food & drink, Shopping & money, Fitness, Health, Travel, Outdoors, Going out, People & pets and Other, and every icon the app uses is among them.
- Choosing one is now a grid tinted in the activity's own colour rather than a single-file menu, because picking an icon means comparing shapes side by side.
- An icon that is not in the list — set by an older version, or by an import — is shown at the top as "Current" rather than being quietly dropped when you open the picker.

### The Activities list stops doing work it does not show

- Opening Activities was still slow after the first fix — 380 ms on a 25,000-entry archive, against the 250 ms this project treats as the limit for blocking the screen. The list shows three things per activity, but was working out all of them: top locations reads and compares a place name for every entry in your history, and the shortest, longest, first-used, last-used and previous-period figures are each another pass over the same entries. None of that is on screen until you open an activity, so none of it is worked out until you do.

### The Activities tab opens quickly

- Opening Activities lagged. It worked out each activity's figures by walking your entire timeline separately for that activity, so with an imported archive it read hundreds of thousands of entries to draw one screen — and then did it again on every redraw. Every activity now comes from a single pass, worked out once when the screen appears and again only when something changes.
- The screen also reports its own timing to Diagnostics now. It was slow and left no trace there, which is its own kind of failure.

### A rename that could not reach your visits now says so

- Renaming an activity offers to bring its visits with it. If that write failed — a locked device, a protected store — the failure was discarded: the activity was renamed, the visits silently kept the old label, and Insights counted them as "Other" with nothing said. It now tells you, so you can rename again and bring them across.

### Importing a walk's route is safe against itself

- Apple Health delivers a recorded route in batches, on its own queue rather than the one LifeLog imports on. The partial route was being assembled without guarding against that, so two batches arriving together could corrupt it or finish the import twice — the second of which ends the app rather than logging a warning. The route is now assembled behind a lock that can only complete once.

### An Activities tab

- A new tab between Timeline and Insights lists every activity you use, each with the shape of the last seven days beside it. Activities your timeline uses but the Activities list has never heard of appear too, rather than being quietly left out — those are usually the ones worth attention. Anything you have never recorded sorts to the bottom.
- Opening one shows that activity on its own: how it moved over the last 7, 30 or 90 days, this period against the one before it with the change between them, averages per day and per week, the places it happens most, and the totals underneath — occasions, total time, average, shortest and longest.
- When there is nothing in the previous period, no change is reported rather than a percentage invented from zero.

### Activity settings say when a label was used

- Editing an activity now shows when it was first and last used — "This activity was used once, on Thursday 18 August 2025" — which is usually how you spot a label created once and forgotten. Its History is one tap away, and it can be deleted from the same screen instead of only by swiping the list. Deleting still asks first when the activity is in use, and still leaves its visits labelled.

### Commuting is counted as its own thing

- The journey between home and work is now recognised as a commute, and only that journey: a drive to work from the gym is not one. Previously LifeLog looked only at where a journey ended, so anything finishing at work read the same way, and commuting could never be totalled.
- Commutes have their own group in Insights, separate from holidays and flights, so "how much of my life goes to commuting" is a question the app can answer.
- A stop of under ten minutes on the way does not end the commute. That tolerance also absorbs the brief matches Apple Maps returns for businesses passed at speed, which otherwise interrupt almost every real journey.
- Time between leaving home and arriving at work was previously reported as unlogged. It is now counted as the commute it was.
- Nothing is written to your timeline for this. A commute is the interval between two arrivals you actually made, worked out fresh each time, so it corrects itself when the stays around it change and can never linger as a record of a journey you did not take.

### Locations to Review now has something to say

- The review queue only ever asked how confident Apple Maps was, and Maps reports how sure it is about which business sits at a coordinate — not whether you went inside. A captured day held two "high confidence" stays of 3m46s and 5m46s, both on a commute and both almost certainly traffic, which nothing could ever queue. A brief stay at a place you have not been back to is now reviewable however confident the match was, and it asks the right question: "Did you stop here?"
- The queue is ordered by what is worth answering rather than by uncertainty. The place you are standing in right now leads, because it is the only one still answerable from memory. Then unidentified places, the ones accounting for the most time first — correcting a coordinate you keep returning to fixes every visit there at once. Then uncertain matches, and last the ones that merely look like passing traffic.
- Timeline and Settings → Locations to Review now show the same queue in the same order, so their counts cannot disagree.

### Hiding a location before it is saved

- Ignoring a visit that had not been written to the timeline yet recorded it against a temporary identifier, which could then match a different unsaved visit and hide a record nobody hid. A visit that is not in the timeline yet now simply has no ignore state.

### Settings reports the build you are actually running

- Settings → Version always said "1.0 (1)", whatever was installed. The version and build number were written into Info.plist as fixed text rather than taken from the build settings, so every release since the first reported the same thing and there was no way to tell which build was on the phone. It now reports the build it was made from.

### A lookup record that grew for the life of the app

- Every public-place lookup added an entry to a table that was only ever emptied by a cancellation path nothing called, so it grew with each place identified until the app was relaunched. The table is gone. What it was meant to protect still holds: a place is never looked up twice at once, and a late Apple Maps result still cannot overwrite a label you chose yourself.

### Groups you can see and change

- Settings → Groups shows every group with the activities filed under it. Grouping decides where Insights counts your time, but it could only be set one activity at a time through a picker, and there was no way to ask what was in a group.
- Groups are no longer a fixed list of twelve. Add your own, rename one — its activities come with it, and Insights re-counts their visits straight away — or delete one, which moves its activities to "Other" rather than dropping them out of the count. "Other" itself cannot be removed, because deleting a group has to leave its activities somewhere.
- A group still in use by an activity is always listed, so a group cannot disappear while something is filed under it, and two groups cannot share a name — that would split the same time in two.

### Activities are listed alphabetically

- Settings → Activities was ordered by when each entry was added, so a newly added activity appeared at the bottom and the list had no order to scan. It now reads alphabetically, ignoring case and accents, and a renamed activity moves to its new place immediately.

### Walks keep the path they took

- A walk now records where it went. Apple Health already stores the GPS track for a recorded workout, and LifeLog simply never asked for it; walks imported from a workout now keep that path. Nothing new is recorded and no extra battery is used — the walk had already been tracked.
- The walk is no longer tied to a place. It shows the distance covered rather than a meaningless "Walking workout" label, and opening it draws the route on a map, saying whether the walk returned to where it started.
- This settles the question the app could not answer. A loop around the block and walking about at home are identical to Core Location: movement, no departure, no new arrival. With a path, LifeLog measures how far the walk actually got. A walk that stays within 250 m of the place is movement at that place and is absorbed as before; one that genuinely leaves ends the stay where it began and resumes it on return. What used to be a guess — and briefly invented a "Home" arrival that never happened — is now a measurement.
- Walks Health recorded only as step counts, and movement inferred from the phone alone, carry no coordinates and behave exactly as before. This makes the timeline better where a route exists, not everywhere.
- Route points are precise and are kept indefinitely, alongside the existing location controls. They are the most detailed location data LifeLog holds, and the journey screen says so.

### One place, one entry

- A day at work was being listed three times. Core Location records a fresh arrival as the phone moves around a large site, and a delayed departure can stretch the first arrival across all of them, leaving stays that overlap each other at the same place. Overlapping stays at one place are now collapsed into the single stay they describe. A person cannot be somewhere twice over the same minutes, so nothing is guessed here — and it runs every time the timeline resolves, rather than as a one-time repair, so a store that drifts is corrected again.
- This also clears the duplicated "Home" left behind by yesterday's change, which the earlier repair could not match once a departure callback made the two halves overlap instead of leaving a gap.
- Insights was already unaffected: it divides the day at visit boundaries and gives each moment to one visit, so overlapping records never inflated a total.

### Short journeys are journeys

- The shortest movement that earns a timeline entry drops from five minutes to three. A recorded walk to a park took 11m25s and the walk home 4m18s, so the trip out appeared and the trip back did not.

### The day starts where you woke up

- Today's Journey now shows the stay you were already in. Core Location records one arrival per stay, so a night at home arrives the evening before; Timeline selected entries by their arrival date and dropped it, and the day appeared to begin at the first time you went out. Stays that began earlier now show their start time with the day it fell on, so "Yesterday 6:12 pm – 7:20 am" cannot read as a few minutes.

### Walks and drives between places are journeys

- A walk to the park and back is now a timeline entry. Movement previously needed to last an hour to earn a card, which hid every ordinary walk. Anything over five minutes between two places is shown; shorter samples are still counted in Insights only.
- Leaving somewhere is now recorded as leaving. A departure is timed from the next arrival, so a stay looked like it covered the walk out the door — and a stay LifeLog has not closed yet looked like it covered everything after it. Either way the walk sat inside a stay and was deleted rather than shown. A finished walk or drive now ends the stay where it began.
- Movement that finishes inside a place is still absorbed, so pacing at home or a lap of the office does not become an entry of its own.

### Walking at home is not leaving home

- A walk recorded while you were at a place LifeLog had never seen you leave was briefly read as leaving and coming back, which split one stay in two and invented an arrival you never made: "Home, walking, Home" while you were home the whole time. It no longer does. Without a departure, movement inside a place is movement at that place. Telling a loop around the block apart from pacing at home needs to know where the walk went — which LifeLog now does, later the same day; see "Walks keep the path they took" above.
- Stays that were split this way are rejoined on the next launch, and the walk between the two halves goes back to being counted in Insights only. Only a split at the same place, with nothing but a short walk between the halves, is repaired — a real outing between two places is left alone.
- A walk described by both the iPhone's motion history and Apple Health over exactly the same minutes is now shown once, using whichever source knows more. Whether the duplicate appeared depended on which import arrived first.

### See and correct the visits behind an activity

- Opening an activity now shows how many visits use it and lets you open the list. Each visit opens in the ordinary editor, so one can be corrected without touching the rest.
- The list always matches the count beside it: an activity you chose yourself wins, and an inferred one only counts when you have not chosen.

### Renaming an activity onto an existing one merges them

- Renaming an activity to a name already in the list now offers to merge: its visits move onto the existing activity and the duplicate entry is removed. Previously the list would keep two entries with the same name, and which one decided the Insights group depended on their order.

### Diagnostics actions moved above the event list

- "Create performance report" and "Clear diagnostics" now sit at the top of the Diagnostics screen. They were below the events, which meant scrolling past hundreds of entries to reach either.
- Clearing now asks first and reports failure. It previously relied on autosave, so a clear could appear to work and the events return on the next launch.

### Deleting or renaming an activity no longer strands its history

- Each activity now shows how many visits use it, so the cost of removing one is visible before you swipe.
- Deleting an activity that is in use asks first. Visits keep their label either way, but Insights counts them as "Other" until the activity exists again, and changing its group instead keeps the history counted.
- Renaming an activity offers to rename its visits too. Previously the visits kept the old wording and quietly fell out of their group.

### Stopped repeating fruitless place searches

- When Apple Maps found no places near a coordinate, LifeLog forgot the answer immediately and searched again on the next location update — several seconds of network work, followed by a reverse-geocode fallback, to rediscover that there is nothing there. Empty results are now remembered for a few minutes, short enough that a newly listed business still turns up soon afterwards.

### Activities you actually use, counted properly

- Insights was filing 17% of an imported archive under "Other" — including 2,732 entries labelled "Work", which showed up as 5 visits. Anything the Activities list has never heard of has no group, so it fell through. Activities now show their group, the group is editable, and "Add from your history" offers the activities already in your timeline with a suggested group for each.
- Inferred activities now use the wording from your Activities list. A recognised workplace is labelled the way you label it rather than always "Working". Only unambiguous matches are adopted — a shared word stem, or a group with a single activity in it — so LifeLog never guesses between two labels that mean different things.

### Correct a place across its whole history

- Settings → Locations → Place History lists every place name in your timeline, however it was recorded, with how often it appears and what it is usually logged as. Opening one shows what that place looks like at each time of day and lets you correct the activity across every entry at once.
- Imported journal entries have no coordinates, so Saved Place learning could never reach them and they could only be fixed one at a time. This is the first route to correcting them in bulk.
- A change never touches an entry you confirmed yourself, and can be scoped to a time of day, so a home address keeps "Sleeping" overnight while the rest of the day is corrected. Bulk changes are only reversible from a backup, so take one first.

### Uncertain place matches ask before being accepted

- Apple Maps sometimes returns a nearby business for a coordinate it is not confident about — a workplace matched onto a home address, for example. LifeLog was writing that name in as though it were settled. An uncertain match now appears in the review queue asking "Is this right?", showing the guessed name, with a "Yes, this is right" button that confirms it and remembers the place for future visits. Correcting the name instead teaches it the same way as before.
- Places LifeLog could not name at all continue to appear as "Uncategorised location". The Settings review list now covers both, and is named "Locations to Review".

### Bounded superseded location callbacks

- When Core Location replays an arrival, LifeLog keeps the best record and marks the duplicates superseded. Those duplicates handed their time to the surviving visit but were left open-ended, so their recorded length kept growing for as long as the store existed. They are now closed when superseded, and any left open by an earlier build are repaired the next time the Timeline opens. Nothing changes on screen: superseded records were already hidden everywhere.

### Removed place type

- Editing a visit now offers just the place name and the nearby Apple Maps picker. The "Place type" control is gone from both the visit editor and the Saved Place editor, and LifeLog no longer stores a place type anywhere.
- A visit is now identified by its name. Somewhere still waiting to be identified is one LifeLog has no name for yet, rather than one whose type was left as "Other", so setting a name or an activity clears it from the review queue.
- Insights continues to group time by activity, and "Top places by time" continues to group by place name. Icons and travel destination labels are now chosen from the place name instead of a type.
- Existing timelines migrate automatically: the store moves to schema V2, which drops the two unused columns while keeping every visit, saved place, correction, and note. Backups taken before this change still restore.

## 2026-08-04

### Headline text now respects the system text size

- The Timeline greeting and "Today's Journey" heading, and the Insights time-away figure, used fixed point sizes that ignored the system text size setting entirely. They now scale, keeping their rounded display face, and the greeting wraps rather than truncating at the largest sizes. The add button grows with them so its icon cannot overflow.

### Correctly sized activity icons

- Activity icons were rendered at their default size and then visually shrunk, which left their layout and shadow at the original size — and in the weekday summary drew a 37pt icon inside a 30pt slot. Each icon is now asked for the size it should actually be.

### Consistent titles, colours, and tab definitions

- Screen titles now use consistent capitalisation ("Add Visit", "Choose Activity", "Journal Storage", "Nearby Apple Maps Places").
- Saved place icons use the same activity colour as the rest of the app instead of always rendering blue.
- The tab bar is declared with the current `Tab` API rather than the older item-and-tag form.

### Consistent card styling across Timeline and Insights

- Timeline and Insights drew their cards through three near-identical private modifiers, two of which differed only by 2pt of corner radius yet were applied to neighbouring cards in the same scrolling stack. They now share one card style, so adjacent cards no longer render with mismatched corners.

### Larger, labelled Insights period controls

- The previous/next period chevrons were only as tappable as the arrow glyph itself, well under the recommended minimum. They now use a full-size target and, along with the date button, announce themselves properly to VoiceOver.

### Activity editing follows the app's own navigation pattern

- The activity editor no longer supplies its own navigation container when pushed from Settings, matching how the visit and saved place editors already work, and only offers Cancel in the modal "Add Activity" flow where it is needed.

### Repaired the UI test suite and removed the unreachable Map screen

- Three of the four UI tests were failing because they looked screens up under `otherElements`, but SwiftUI attaches each screen identifier to whatever container it renders (a scroll view for Timeline, a form or list elsewhere). They now match on identifier alone, so the tests no longer depend on the concrete element type SwiftUI picks.
- Removed `MapView`, which had no remaining entry point after the Map tab was retired, along with the UI test steps that still expected that tab.

### Removed Health-imported visits when their source sample is deleted

- Sleep and workout visits now record the HealthKit sample UUID(s) they were built from. When a later Health import reports that a sample was deleted, the matching visit is removed too, instead of lingering in the timeline forever. A visit already manually confirmed is left in place rather than removed.

### Fixed Saved Place corrections not reaching newly-learned visits

- Learning a Saved Place from a previously unrecognized ("Other"/no-confidence) visit no longer skips applying that correction back onto the very visit that triggered it, and no longer skips other still-unresolved visits at the same location. A resolution-state refactor had narrowed the applied filter from "not ignored" to "already resolved," which excluded exactly the newly-corrected visits the feature exists to update.

### Bounded Saved Place fetches

- Saved Place upsert and the visit-matching pass it triggers no longer load every SavedPlace or every located Visit in the archive. Both now fetch only rows within a bounding box around the coordinate in question, letting SwiftData filter before rows are loaded instead of after.

### Bounded place lookup cache

- Place lookup results are now swept for expired entries on every new lookup instead of only being checked on read, so a long-running background session no longer accumulates one permanent in-memory entry per distinct location ever visited.

### Logged Insights cache invalidation reasons

- The reason an Insights cache invalidation fired (HealthKit import, Saved Place correction, visit edit, and so on) is now recorded to Diagnostics instead of being silently discarded.

### Tap to navigate from Insights

- Tapping a donut wedge on the Insights tab now highlights it as before, and tapping the centre card that appears opens the underlying visit (or the "Add Visit" flow for unlogged time), matching the legend rows below the chart.
- Rows in "Top places by time" are now tappable and open that place's visits for the current period, editing directly when there's only one.

### Preserved manual activity corrections on re-import

- Replayed HealthKit/Motion anchored samples no longer overwrite an activity a person has explicitly confirmed on a visit; only the inferred activity refreshes when the same sample is imported again.

### Bounded diagnostic writes

- Diagnostic logging no longer fetches the entire diagnostic history on every write to check retention. It now checks a lightweight row count first and fetches only the overflow rows that need trimming.

### Accurate error diagnostics

- Fixed error diagnostics recording the literal text "(operation) failed" instead of the actual failing operation, so HealthKit, MapKit, and Activity Import failures are distinguishable again in the Diagnostics screen.

### Saved Place learning comment cleanup

- Removed a stale, contradictory comment and a redundant reassignment in Saved Place learning. The code already correctly leaves a person's manual activity untouched when a saved place's default activity changes; the comments now say so.

### Provisioning-compatible store protection

- Restored the profile-required default data-protection entitlement so personal-team builds sign successfully, while retaining the best-effort post-open SQLite file protection adjustment for background location use.

### Reliable background store access

- Changed the timeline store to encrypted “available after first unlock” file protection so background location callbacks no longer fail while the iPhone screen is locked. Existing store files are upgraded after a successful open, and the app retries once automatically when brought to the foreground.

### Home arrival de-duplication

- Core Location arrivals now merge a placeholder and a learned Saved Place when they represent the same time and coordinates, preferring the better recognised label and preventing a duplicate “Identifying…” Timeline card.

## 2026-08-03

### Commit versioning

- Documented the repository rule to increment the app build number for every commit and apply sensible patch/minor/major marketing-version changes based on the size and compatibility impact of the work.

### Expanded location performance diagnostics

- Added aggregate metrics for callback-to-save time, serialized Maps candidate payload size, and Saved Place lookup refresh time/counts alongside existing Maps latency, cache-hit, candidate-count, and match-distance metrics.

### Reusable Insights aggregation cache

- Added an actor-coordinated Insights generation and UI snapshot cache. Visit edits, Saved Place corrections, imports, and HealthKit sleep/activity updates now invalidate cached aggregation before the next refresh.

### Current-activity artwork positioning

- Shifted the enlarged current-activity illustration upward inside its fixed clipping frame so the artwork subject is not cut off at the bottom.

### Current-activity artwork scale

- Increased the scene illustration rendering to 3× inside the same clipped card footprint, keeping the card dimensions fixed.

### Bounded current-activity artwork

- Removed oversized artwork scaling from the current-activity card, added a clipped fixed footprint, and added asset-dimension regression tests so transparent illustrations cannot distort the card layout.

### Explainable activity inference

- Insights donut focus now shows confidence and the evidence behind an inferred activity, including Saved Places, Maps category, time of day, recurrence, device movement, and on-device inference. Guesses remain explicitly editable.

### Location resolution diagnostics

- Added bounded metric events for callback resolution time, Maps latency/cache hits/candidate counts, Saved Place match distance, resolver repairs, and suggestions later corrected by the user.

### Deterministic Core Location departures

- Departure callbacks now match stored arrivals using callback coordinate, arrival order, and overlap state. Unmatched delayed callbacks are diagnosed instead of closing the newest visit.

### Location reliability roadmap audit

- Expanded the roadmap with prioritized Core Location callback matching, deterministic resolution invariants, Apple Maps/Saved Place scoring, personal detailed diagnostics, replay tests, and safer automatic place learning.

### Simplified main navigation

- Removed the standalone Map tab from the main tab bar; map-based place tools remain available from relevant location workflows.

### Richer personal Insights

- Added a daily time strip, time-away-from-Home summary, visual activity-change bars, and a conditional timeline-quality card using the existing cached Insights snapshot.

### Personal-use roadmap priorities

- Documented that LifeLog is currently a private personal-device project. The roadmap now prioritises correctness, useful diagnostics, responsiveness, and storage efficiency over App Store generalisation and broad release certification.

### Split activity illustration assets

- Added individually named, unscaled activity-card image assets for Coffee, Beers, Fitness, Donate Blood, Meeting, Doctor Visit, Shopping, Visiting Family, Work Trip, and Work.

### Expanded activity illustrations

- Added Coffee, Beers, Exercise, Healthcare, Meeting, Doctor, Groceries, Family, Hotel, and Desk illustrations for current activity cards.
- Timeline selects the most specific illustration available and keeps the existing SF Symbol fallback for activities without artwork.

### Illustrated current activity cards

- Added the supplied activity illustrations to the asset catalog and connected Home, Shopping, Sleep, Work, Driving, Walking, Cafe, and Flight visuals to Timeline activity cards, with SF Symbol fallback for other activities.

### Simpler Activities list

- Activities settings now shows only each activity name; category remains editable inside the activity editor and is used for Insights grouping.

### Flexible activity vocabulary

- Activities now model reusable things people do—such as Coffee, Beers, Breakfast, Lunch, Dining out, Concert, and Football—rather than forcing one permanent activity onto a place.
- Saved Place defaults remain future suggestions, while each visit can keep a different activity. Visit editing also offers activities previously used at the same place and supports custom additions.

### Complete local backup and restore

- Added a versioned JSON backup covering visits, Saved Places, corrections, diagnostics, ignored state, activity definitions, category colours, and LifeLog preferences.
- Added Settings export/restore controls and a round-trip test restoring into an empty in-memory store.

### RFC 4180 journal CSV parsing

- Life Cycle imports now handle quoted commas, escaped quotes, embedded line breaks, UTF-8/UTF-16 encodings, and very large records without splitting fields incorrectly.
- Duplicate and malformed-row reporting remains unchanged.

### Stable ignored-location identifiers

- Ignore state now uses each Visit’s stable SwiftData persistent identifier instead of mutable arrival and coordinate values.
- Existing coordinate-based ignore entries migrate lazily the next time each visit is read, preserving current user choices while preparing for the planned schema migration.

### Sensible timeline visit deletion

- Timeline visits can now be deleted with confirmation. Matching bordering visits merge their time when they represent the same place and activity; different destinations are preserved without an unsafe guess.

### Travel as an Insights-only event

- Travel between destinations now remains a distinct Insights event, including shorter trips, while Timeline hides trips under one hour and shows only long journeys as cards.

### Historical backfill previews and recovery

- Saved Place editing now previews how many historical visits will change and records corrections for recovery.
- Saved Places can ignore all matching visits with confirmation; ignored visits remain restorable from Ignored Locations.

### Enrich imported journal locations

- Core Location visits now enrich matching imported journal rows with coordinates, place identity, and place type when time and place/activity evidence agree.
- Imported source and original journal content remain intact; enrichment is non-destructive and marked with an enriched confidence.

### Locations settings navigation

- Locations settings now leads with clickable Uncategorised Locations and Ignored Locations rows, each opening a dedicated review page, followed by the full Saved Places list.

### Cinema and entertainment inference

- Apple Maps cinema categories and cinema-like names now suggest “Watching a movie” under Entertainment, with the existing evidence and confidence UI keeping the suggestion editable and clearly provisional.

### Editable category colours

- Added editable category colours in Activities settings and a shared resolver used by the Insights donut, Timeline, Map, Saved Places, exports, and accessibility-facing labels.

### Editable learned activity corrections

- Timeline and Insights now explicitly expose activity and place-type correction flows, with guidance that recognised locations learn the saved choice for future visits while remaining editable.

### Apple Maps nearby-place picker

- Visit editing now offers a dedicated nearby-place page that searches Apple Maps around the recorded pin and lets users match the visit to a nearby business by name and distance.

### Map pin editing for visits and places

- Visit and Saved Place editors now include an interactive map picker for adjusting the stored location pin before saving.

### Explainable activity inferences

- Visit editing now shows the evidence behind inferred activities, including saved places, Maps/place types, time of day, device movement, and on-device inference.
- Confidence and inference language make clear when a value is a suggestion rather than a confirmed fact.

### Separate place types from activity categories

- Place categories are now presented as “Place type” for recognition and geofencing, while Insights groups time using an activity category derived from the activity itself.
- Existing persisted stores remain compatible; no destructive schema rename is required.

### Propagate learned place activities

- Correcting an entry such as Gracemere Shopping World now updates the learned Saved Place and all matching historical check-ins, including visits with an existing manual activity label.

### Gated HealthKit background delivery

- Added opt-in HealthKit sleep/workout observers that trigger the existing anchored importer in isolated batches.
- Background delivery is disabled by default and exposes an explicit validation-only Settings toggle so it cannot affect Timeline or Insights before the incremental importer is proven responsive on-device.

### Incremental HealthKit history imports

- Sleep and workout imports now use persisted HealthKit anchors, requesting only samples added or changed since the previous successful import.
- Anchors are saved only after the corresponding SwiftData batches finish saving, so cancellation, relaunch, and protected-store failures remain safe and idempotent.

### Faster large-period Insights snapshots

- Reworked overlapping-visit segmentation to sweep sorted arrivals instead of scanning the full archive at every time boundary, reducing year-view snapshot work for large Life Cycle imports.

### Accurate HealthKit step totals

- Insights uses HealthKit’s source-aware cumulative step statistic, which avoids double-counting overlapping iPhone and Apple Watch samples while keeping year queries fast.

### Performance budgets for large archives

- Added centralized 250 ms responsive-first-screen and normal-interaction budgets, plus bounded Day/Week/Month/Year Insights budgets.
- Diagnostics now retains privacy-safe pass/over-budget timing samples with aggregate item counts for launch and Insights fetch/rebuild work.
- Added `PERFORMANCE_BUDGETS.md` with a repeatable physical-device checklist for the full 32,000-row Life Cycle archive.

### Current location journey state

- Today’s Journey now puts the current location first with a distinct live card and elapsed time. A validated location sample that arrives before Core Location confirms a formal visit is shown as a privacy-safe “Waiting for visit confirmation” state rather than a duplicate provisional entry.

### Protected store recovery

- Replaced the generic store-opening failure screen with a recovery flow that preserves the original protected store, supports retrying, and explains the next safe steps.
- Added privacy-safe diagnostic report export and a best-effort copy of the store, WAL, and SHM files for recovery before any destructive action.

### Versioned SwiftData schema baseline

- Added `LifeLogSchemaV1` and a migration plan for the current protected on-device models.
- Added an on-disk compatibility test that writes the current schema, reopens the same store through the versioned plan, and verifies visits, saved places, corrections, diagnostics, notes, and candidate data survive.
- Documented the required V2 workflow before adding another persisted field.
- Updated the fixture to use the explicit URL-based `ModelConfiguration` initializer required by the current SDK.
- Made the schema version constant immutable for Swift 6 strict-concurrency checking.

### Responsive background activity imports

- Moved HealthKit and Core Motion history reading and SwiftData writes onto isolated actors, with database saves limited to small batches so app navigation and touch handling remain responsive.
- Added cancellable import progress, completion, and failure states to Settings.
- Kept sleep, movement-at-location filtering, duplicate prevention, and recurring travel descriptions inside the background import pipeline.
- Corrected background-writer cleanup so cancelled and failed imports reliably release their active batch session.

### Refined Timeline design

- Updated the Timeline to match the supplied visual direction with a stronger greeting, prominent current-activity card, larger activity icons, connected journey rail, clearer status badges, and roomier visit cards.

### Sleep in Insights

- Added a lightweight, date-scoped Apple Health sleep refresh when Insights opens so sleep appears in the donut without running the full Health history import.
- Sleep is now preserved when it overlaps Home or another location; location overlap suppression remains limited to walking and travel.

### Grouped Insights donut slices

- The donut now renders the same aggregated category slices as the Insights summary, grouping repeated visits and locations instead of drawing one sector per individual event.

### Insights donut hit testing

- Converted donut tap angles through `ChartProxy`’s data scale so a tap selects the slice under the finger instead of comparing screen degrees with duration values.

### Insights overlapping visit coverage

- Reworked the day segmentation to resolve overlapping imported and automatic stays by time slice, so completed destinations remain visible in the donut even when an older open location record spans the same period.

### Recorded map section builder fix

- Made the uncategorised-location map section use explicit SwiftUI header/content builders so it compiles cleanly under Swift 6.

### Insights and HealthKit error recovery

- Insights now falls back to an in-memory period filter if the date-scoped SwiftData predicate cannot be translated, instead of blanking the screen.
- Step-query diagnostics include privacy-safe error domain/code context and the Settings Health status now explains when Apple Health access is needed.
- Renamed the Health permission action to make clear that it covers steps as well as sleep and workouts.

### Repeated location callback deduplication

- Prevented repeated Core Location arrival callbacks from creating duplicate Timeline cards.
- Added a one-time cleanup for identical automatic visits already stored, while preserving later returns and manual entries.
- Later destinations now close an earlier open stay so Insights can show the complete sequence, such as Shopping followed by Home.

### Timeline journey time labels

- Only the actual current visit uses “Since”; all other Today’s Journey cards show start and end times, including a safe current-time fallback for stale open records.

### Uncategorised location map editing

- Added a recorded-location map to the uncategorised visit editor.
- Users can enter pin-adjustment mode, tap the map to correct the stored coordinate, and save the visit with the updated location.

### Four-week development roadmap

- Reorganised the project roadmap around physical-device validation, non-blocking incremental Health ingestion, correction/learning quality, data ownership, privacy, and release readiness.
- Moved completed foundations out of the active queue and added concrete completion criteria for large-history performance, schema migration, backup/restore, retention, and deterministic UI coverage.

### Settings version information

- Added the app version and build number to an About section in Settings.

### Insights angle type fix

- Converted Charts’ polar `Angle` selection to degrees before matching donut segments, fixing the Swift 6 type error in repeated selection handling.

### Health steps in Insights

- Replaced the neutral donut center’s logged-hours summary with Apple Health step count for the selected period.
- When Health access or step data is unavailable, the center clearly prompts the user to connect Apple Health.

### Donut selection toggle

- Tapping the currently focused Insights donut segment again now deselects it and restores the neutral chart.

### Life Cycle journal import

- Added a local CSV importer in Settings for Life Cycle exports, mapping timestamps, activities, locations, and notes into imported visits.
- Repeat imports skip matching imported rows; malformed rows are counted and reported instead of stopping the import.

### Large-import performance

- Made repeat-import duplicate detection constant-time per row, so large Life Cycle files no longer scan the full timeline for every entry.
- Limited Insights change tracking to visits overlapping the selected period instead of hashing the entire imported archive on every view update.
- Moved one-time timeline reconciliation behind a versioned local flag, avoiding a full-history cleanup scan each time Timeline appears.

### Deferred HealthKit catch-up

- Removed HealthKit and Motion history imports from the critical launch path.
- The app becomes interactive first; the Settings action performs an explicit 30-day refresh.
- Delayed and cached Insights step queries so opening the chart does not compete with first-screen rendering or repeat the same HealthKit request.

### Performance diagnostics

- Added privacy-safe timing events for large journal imports, Insights snapshot rebuilds, timeline reconciliation, HealthKit catch-up, and step queries.
- Slow events record only subsystem, duration, and aggregate item counts; precise locations, notes, and Health values are never stored.
- Existing diagnostics in Settings now provide a lightweight way to identify the slowest operation on the testing phone.

### HealthKit import batching

- HealthKit catch-up now fetches the existing timeline once per batch and reuses it while importing samples, avoiding a full SwiftData fetch for every Health record.
- Existing visits are indexed by source and location type during the batch so duplicate and overlap checks do not repeatedly scan imported journal rows.
- Explicit HealthKit catch-up remains bounded to the most recent two days after first connection, while Settings can request a 30-day refresh.
- Added separate timings for HealthKit queries and SwiftData saving to identify the next bottleneck without recording Health values.
- The explicit first connection skips no workout data; Settings and manual refreshes import workouts as well.

### Launch responsiveness diagnostics

- Excluded zero-coordinate and journal-only records from Timeline and Map startup queries while retaining the full archive for Insights.
- Removed delayed automatic HealthKit writes after confirming they caused a second freeze several seconds after launch; launch service setup remains timed.
- Applied the same location-only query to Settings and Saved Places so imported journal rows cannot block controls or text input there.

### Weekly activity rhythm

- Replaced the weekday total-time chart with a weekday-by-weekday view of the activity taking the most time, including its duration.

### Large archive performance sweep

- Insights now fetches only the selected period, its comparison period, and active visits instead of loading the complete journal archive.
- Scoped Health imports, movement reconciliation, Saved Place backfills, location lookup, Timeline, Map, and Settings queries to the record types they actually use.
- Reused CSV date formatters for the complete file, substantially reducing processing overhead on large imports.
- Kept historical import trimming non-destructive: the app retains meaningful short visits while avoiding full-archive work during everyday use.

### Trends analysis and export

- Added weekday pattern bars with top activity and average logged-time context.
- Weekly and other period comparisons now include percentage context and identify new categories.
- Added local CSV and JSON export from Insights with visit times, places, categories, activities, durations, source, and confidence.

### Activity editor polish

- Replaced the raw SF Symbol name field with a friendly icon picker, removing technical values such as `.fill` from the activity editor.

### Protected timeline startup fix

- Removed the ignored-location field from the SwiftData `Visit` schema and moved ignore state to local preferences, avoiding a protected-store migration on existing iPhones.

### Timeline startup migration fix

- Moved editable activities out of the protected SwiftData schema and into a versioned local preferences payload, preventing existing timeline stores from failing to open after the Activities feature was added.

### Locations section builder fix

- Rewrote the Locations list sections with explicit headers so SwiftUI resolves the conditional content correctly under Swift 6.

### Editable activities and locations

- Added Activities and Locations destinations in Settings.
- Activities can be added, renamed, recategorised, and assigned an SF Symbol; visit editors use the editable catalogue.
- Locations now show Saved Places, uncategorised visits, and ignored visits with reversible Ignore/Restore controls.
- Ignored locations are excluded from Timeline, Insights, Map, and future Saved Place backfills.

### Settings diagnostics context fix

- Connected `SettingsView` to its SwiftData model context so the Clear Diagnostics action can delete and save diagnostic events correctly.

### App icon asset dimensions

- Resized the dark app icon asset to the required 1024×1024 pixels for the AppIcon catalog.

### Timeline fixture and fuzz coverage

- Added deterministic tests for overlapping location/activity intervals, malformed coordinates and text, year-long histories, and extreme time zones.

### MapKit iOS 27 API cleanup

- Replaced deprecated `MKMapItem.placemark` usage in manual entries with iOS 27 `location`, `address`, and `addressRepresentations` APIs.

### Privacy-safe diagnostics

- Added local diagnostics for delayed Core Location callbacks, MapKit lookup/reverse-geocoding failures, HealthKit imports and sleep queries, and motion imports.
- Diagnostics store only generic subsystem messages, severity, and timestamps; they never include precise locations, place names, HealthKit samples, or health values.
- Settings now shows the latest diagnostic events and provides a clear action.

### Recognition confidence and correction history

- Visits now retain a human-readable confidence state for Apple Maps matches, saved-place learning, device activity, and recurring travel destinations.
- Manual corrections and Saved Place backfills are recorded in a local audit history and shown in the visit editor.
- Recurring destinations such as Work now mark generated “Travelling to …” labels as learned confidence.

### Map-based manual entries

- Manual visits now include Apple Maps local search, selectable business results, and an interactive map picker.
- When no business match is available, a tapped coordinate can be saved as a clearly marked low-confidence pinned location instead of being discarded.
- Manual entries retain the entered name/activity and use the selected coordinate for future place learning.

### UI and accessibility coverage

- Added stable accessibility identifiers for Timeline, Insights, Map, Settings, current-location labeling, Saved Places, and the manual-entry flow.
- Added an XCUITest target covering primary-tab navigation, Saved Places navigation, and manual-entry controls.

## 2026-08-02

### Backlog refinement

- Added the latest product ideas to `TODO.md`, including map-based manual entries, an uncategorised-location backfill queue, editable activities and category colours, ignored places, notes/photos, App Intents, Shortcuts, and an incremental iCloud backup plan.
- Recorded that Apple’s public HealthKit APIs provide sleep stages rather than a general-purpose official Sleep Score value; LifeLog should keep its calculated score clearly labelled.

### Sleep details and dark-mode icon

- Added a dark luminosity AppIcon appearance that switches with the iOS interface style.
- Added a prioritized project backlog in `TODO.md` covering device validation, HealthKit edge cases, performance, privacy, and planned exports/sync.

### Responsive Insights interactions

- Insights now prepares timeline segments, trends, and place totals once per data or date change instead of rebuilding them for every donut selection.
- Donut taps use Charts’ native angle selection and local state, keeping repeated taps responsive without rebuilding the rest of Insights or its map.
- Donut highlighting now uses one immediate state transition, preventing the previously selected slice from flashing during a new tap.

### Sleep details

- Selecting a Sleep segment now loads its Apple Health sleep stages on demand and shows asleep time, time in bed, deep sleep, REM, awake time, interruptions, and a clearly labelled LifeLog sleep estimate.
- LifeLog does not claim to reproduce Apple’s private Sleep Score; the estimate is derived from HealthKit duration, restorative stages, and interruptions.

### Current and saved places

- A stationary current location is recorded immediately when LifeLog opens or location is refreshed, so it appears as an uncategorised location instead of unlogged time.
- Timeline cards show the suspected activity, live status, and a clear prompt to label an unknown current location.
- Settings now includes current-location editing and Saved Places management for Home, Work, custom activities, and geofence radius.
- Editing a saved place updates matching timeline history and Insights, while one-tap Home and Work labels make first-time setup faster.
- Current Insights windows stop at the present time so future hours are not counted as unlogged.

### Location-first movement timeline

- Walking activity is now shown only between a previous and next destination, so walking around a current location no longer appears as a separate timeline entry.
- Vehicle and other travel movement follows the same destination-only rule and is grouped under the Travel category.
- Repeated work-bound trips are labelled “Travelling to Work” when the destination is recognised.

### Focused insight entries

- Insights is now the second tab and Map is the third.
- The Insights donut now represents individual timeline entries while retaining category totals below it.
- Tapping a donut segment now highlights it in place and shows that entry’s check-in, check-out, and duration in the centre without opening a popup.

### Editable insight slices

- Tapping an Insights category total opens its contributing visit for editing, or a list when several visits make up the total.
- Unlogged pie segments now offer a direct way to add the missing visit.

### Personal-device signing

- Data protection now matches the Personal Team provisioning profile so LifeLog can install on the registered iPhone.

### Corrected-visit geofence learning

- Correcting a located visit now creates or updates a reusable `SavedPlace` geofence.
- Renaming a visit updates the matching nearby saved place rather than creating a duplicate.
- Corrected categories and activities become the defaults for future visits within the saved radius.

### Location-first timeline

- Device activity is excluded wherever it overlaps an automatic or manual location visit.
- Partial walking, workout, sleep, or travel segments are trimmed so only time between places remains.
- Location visits also reconcile activity that was imported before Core Location delivered the visit.
