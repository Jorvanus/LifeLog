# Change log

## 2026-08-03

### Life Cycle journal import

- Added a local CSV importer in Settings for Life Cycle exports, mapping timestamps, activities, locations, and notes into imported visits.
- Repeat imports skip matching imported rows; malformed rows are counted and reported instead of stopping the import.

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
