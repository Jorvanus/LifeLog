# Change log

## 2026-08-05

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
