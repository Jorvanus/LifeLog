# LifeLog performance budgets

These checks are intended for a physical iPhone with the full 32,000-row Life Cycle archive imported. Run them after a clean launch and again after the archive has been opened once, because the second run exercises warmed caches.

## Budgets

| Area | Budget | What is measured |
| --- | ---: | --- |
| Responsive first screen | 250 ms | Root service setup through the first screen becoming available |
| Normal interaction | 250 ms | Any single user-initiated transition, tap response, or scroll interaction |
| Return to Timeline | 350 ms | Selecting Timeline from Insights, Activities, Settings, or an editor through Timeline appearing |
| Activities summary | 1,000 ms background | Whole-archive activity aggregation on its model actor; it must not block interaction |
| Insights: Day | 250 ms | Date-scoped fetch and snapshot rebuild |
| Insights: Week | 500 ms | Date-scoped fetch and snapshot rebuild |
| Insights: Month | 750 ms | Date-scoped fetch and snapshot rebuild |
| Insights: Year | 1,500 ms | Date-scoped fetch and snapshot rebuild |

The normal-interaction budget is a device acceptance criterion: no main-thread stall should exceed 250 ms. Use Instruments’ Main Thread Checker or Time Profiler to verify this; the app’s Diagnostics records are not a substitute for Instruments.

## Repeatable device checklist

1. Install the current debug build on the test iPhone and confirm the device is unlocked, charging, and has Location and Health permissions enabled.
2. Import the full 32,000-row archive once. Wait for the import progress state to finish before measuring.
3. Clear Diagnostics, force-quit LifeLog, and launch it three times. Record the first-screen timing for each run; the worst run must remain within 250 ms after the store is established.
4. On Timeline, scroll from the top to the end and back twice. Tap the current-location card and one historical card. Confirm no interaction stalls for more than 250 ms.
5. Return to Timeline from Insights, Activities, Settings, and Visit Editor. Each selection-to-appearance sample must remain within 350 ms, and no main-thread stall may exceed 250 ms.
6. Open Activities and wait for its background archive summary. Navigation must remain responsive; the aggregate should finish within 1,000 ms on the owner’s archive.
7. Open Insights and measure Day, Week, Month, and Year once each. Change the date, return to Today, and repeat each window. Each window must remain within its documented bound.
8. Open Settings → Diagnostics and retain the exported report. Budget records contain elapsed milliseconds and aggregate item counts only.
9. Repeat steps 3–7 after a device restart. Compare the worst timing per operation rather than individual sample values.

## Diagnostic records

`Diagnostics` stores budget events for launch, return to Timeline, background Activities aggregation, and each Insights period fetch/snapshot rebuild. Each event includes the operation, elapsed milliseconds, budget, pass/over-budget status, and an aggregate item count. No precise location, place name, note, or HealthKit value is recorded.
