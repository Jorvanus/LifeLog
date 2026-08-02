# LifeLog

A private, native iOS location diary. It records Apple `CLVisit` events and significant location changes, recognizes saved places, infers a likely activity, accepts corrections, and charts time by activity.

LifeLog can also import sleep, Apple Watch workouts, Watch walking, and iPhone motion classifications. These add Sleeping, Walking, Running, Cycling, and Travelling entries to the timeline and Insights dashboard.

## Open the project

1. Install full Xcode from the Mac App Store and launch it once.
2. XcodeGen 2.45.4 is installed locally in this workspace.
3. To regenerate the project, run `.tools/xcodegen/bin/xcodegen generate`, then open `LifeLog.xcodeproj`.
4. Select your Apple development team under Signing & Capabilities.
5. Run on a physical iPhone; visit monitoring is not meaningfully testable in the simulator.

## Important behavior

- iOS, not the app, decides when visit events arrive. They can be delayed.
- Explicit Core Location service sessions keep **When In Use** and background **Always** authorization as separate user-controlled workflows.
- Background location is designed for low-power visit/significant-change monitoring, not continuous GPS tracking.
- Data remains in local SwiftData storage protected by the device data-protection class.
- Correcting a located visit creates or updates a reusable `SavedPlace` geofence. Future visits within its radius inherit the corrected name, category, and activity.
- Connect Apple Health and Motion Activity from LifeLog Settings. Health data is imported for the most recent 30 days and iPhone motion history for the most recent 7 days.

## Next milestones

- Add MapKit local search for manual place selection.
- Add weekly comparisons, weekday patterns, and CSV/JSON export.
- Add an optional encrypted iCloud sync mode.
