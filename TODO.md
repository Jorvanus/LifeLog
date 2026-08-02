# LifeLog TODO

Priorities below reflect the current implementation and the risks that matter most before relying on LifeLog as a daily personal record.

## P0 — validate the core record

- [ ] Test authorization, visit delivery, relaunch, and background behavior on a physical iPhone running iOS 27. The simulator cannot validate delayed `CLVisit` delivery or real background transitions.
- [ ] Add an Insights UI regression test (or a repeatable device checklist) that selects several donut segments in succession, including Sleep, after scrolling and returning to the page.
- [ ] Exercise HealthKit permission denial, no-data, partial-data, and Apple Watch disconnected cases. Keep the LifeLog sleep estimate clearly distinct from any Apple Health score.
- [ ] Confirm the public HealthKit API surface on iOS 27: Apple does not expose a general-purpose official Sleep Score value, so show Apple Watch/Health sleep stages and keep any calculated score explicitly labeled as a LifeLog estimate.
- [ ] Make sleep-session queries tolerant of boundary differences by padding the selected interval and grouping overlapping HealthKit stage samples into one night.
- [ ] Add import idempotency tests for repeated HealthKit and motion imports, including overlapping samples, time zones, and daylight-saving transitions.

## P1 — finish the daily workflow

- [x] Add a map picker and MapKit local search to manual entries, with a clear confidence/fallback path when no business match is found.
- [ ] Add an Uncategorised Locations queue in Settings. Applying a label should update the selected visit and backfill all matching historical visits and the learned Saved Place.
- [ ] Make the current location the first, visually distinct card in Today’s Journey, with live status and elapsed duration even before Core Location delivers a visit.
- [ ] Add UI/accessibility coverage for Timeline, Insights, Map, Settings, current-location labeling, and Saved Places.
- [ ] Profile Insights and Map with month/year histories and large annotation counts; keep chart selection and scrolling responsive on a physical phone.
- [ ] Add HealthKit observer/background delivery so new sleep and workout data can be imported without opening Settings.
- [ ] Expand movement classification coverage for cycling, running, and car/plane travel, while preserving the location-first rule that excludes movement inside a place.
- [ ] Add weekday patterns, richer weekly comparisons, and CSV/JSON export for the trends data.
- [x] Add confidence and correction history for inferred place names, activities, and recurring trips such as commuting to Work.
- [ ] Make activity inference explainable and editable: show why a visit is suggested as Coffee, Lunch, or another activity, allow correction from the donut/timeline, and learn recurring choices without treating a guess as fact.
- [ ] Add an editable activity/category catalogue, including user-created activities and category colours used consistently in the donut, timeline, and map.
- [ ] Add an Ignore Location flow for places that should be excluded from the diary, with reversible settings and historical cleanup rules.
- [ ] Add optional notes and photos to a visit, stored locally with explicit privacy controls.
- [ ] Add App Intents and Shortcuts for read-only queries such as “show coffee places I visited this week,” with permission-aware results.

## P2 — privacy, resilience, and polish

- [ ] Design optional encrypted iCloud backup/sync with conflict resolution, an explicit opt-in, and a documented restore path; start with an exportable backup before full sync.
- [ ] Add user-facing export, deletion, and retention controls for locations, HealthKit imports, and saved places.
- [ ] Complete the privacy manifest and App Store review checklist, including plain-language explanations for Location, Motion, and Health access.
- [ ] Verify dark-mode and tinted Home Screen icon behavior across iOS 27 appearances and device sizes. Dark luminosity switching is implemented; tinted appearance still needs verification.
- [x] Add diagnostics for delayed Core Location visits, MapKit lookup failures, and HealthKit query errors without logging precise locations or health data.
- [x] Expand fixture and fuzz coverage for overlapping visits, malformed samples, long-running histories, and unusual time zones.

## Recently completed

- Sleep segments load HealthKit stages and show a transparent LifeLog estimate in the Insights donut.
- Insights selection was moved to local/native Charts state to prevent repeated-tap lag and flashing.
- Corrected visits learn reusable Saved Places; location visits take priority over activity.
- Current unknown locations are surfaced for labeling, with Home and Work shortcuts in Settings.
- A dark luminosity variant was added for the app icon.
- Walking inside a current place is excluded from the location-first timeline; movement is retained only between destinations.
- Saved Places already remember corrected location/activity choices and can be edited from Settings or Insights.
