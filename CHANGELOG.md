# Change log

## 2026-08-03

### Versioned SwiftData schema baseline

- Added `LifeLogSchemaV1` and a migration plan for the current protected on-device models.
- Added an on-disk compatibility test that writes the current schema, reopens the same store through the versioned plan, and verifies visits, saved places, corrections, diagnostics, notes, and candidate data survive.
- Documented the required V2 workflow before adding another persisted field.

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
