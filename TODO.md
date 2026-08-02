# LifeLog TODO

Priorities below reflect the current implementation and the risks that matter most before relying on LifeLog as a daily personal record.

## P0 — validate the core record

- [ ] Test authorization, visit delivery, relaunch, and background behavior on a physical iPhone running iOS 27. The simulator cannot validate delayed `CLVisit` delivery or real background transitions.
- [ ] Add an Insights UI regression test (or a repeatable device checklist) that selects several donut segments in succession, including Sleep, after scrolling and returning to the page.
- [ ] Exercise HealthKit permission denial, no-data, partial-data, and Apple Watch disconnected cases. Keep the LifeLog sleep estimate clearly distinct from any Apple Health score.
- [ ] Make sleep-session queries tolerant of boundary differences by padding the selected interval and grouping overlapping HealthKit stage samples into one night.
- [ ] Add import idempotency tests for repeated HealthKit and motion imports, including overlapping samples, time zones, and daylight-saving transitions.

## P1 — finish the daily workflow

- [ ] Add MapKit local search and place confirmation for manual entries, with a clear confidence/fallback path when no business match is found.
- [ ] Add UI/accessibility coverage for Timeline, Insights, Map, Settings, current-location labeling, and Saved Places.
- [ ] Profile Insights and Map with month/year histories and large annotation counts; keep chart selection and scrolling responsive on a physical phone.
- [ ] Add HealthKit observer/background delivery so new sleep and workout data can be imported without opening Settings.
- [ ] Expand movement classification coverage for cycling, running, and car/plane travel, while preserving the location-first rule that excludes movement inside a place.
- [ ] Add weekday patterns, richer weekly comparisons, and CSV/JSON export for the trends data.
- [ ] Add confidence and correction history for inferred place names, activities, and recurring trips such as commuting to Work.

## P2 — privacy, resilience, and polish

- [ ] Design optional encrypted iCloud sync with conflict resolution and an explicit opt-in.
- [ ] Add user-facing export, deletion, and retention controls for locations, HealthKit imports, and saved places.
- [ ] Complete the privacy manifest and App Store review checklist, including plain-language explanations for Location, Motion, and Health access.
- [ ] Verify dark-mode and tinted Home Screen icon behavior across iOS 27 appearances and device sizes.
- [ ] Add diagnostics for delayed Core Location visits, MapKit lookup failures, and HealthKit query errors without logging precise locations or health data.
- [ ] Expand fixture and fuzz coverage for overlapping visits, malformed samples, long-running histories, and unusual time zones.

## Recently completed

- Sleep segments load HealthKit stages and show a transparent LifeLog estimate in the Insights donut.
- Insights selection was moved to local/native Charts state to prevent repeated-tap lag and flashing.
- Corrected visits learn reusable Saved Places; location visits take priority over activity.
- Current unknown locations are surfaced for labeling, with Home and Work shortcuts in Settings.
- A dark luminosity variant was added for the app icon.
