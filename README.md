# LifeLog

A private, native iOS location diary. It records Apple `CLVisit` events and significant location changes, recognizes saved places, infers a likely activity, accepts corrections, and charts time by activity.

LifeLog can also import sleep, Apple Watch workouts, Watch walking, and iPhone motion classifications. These add Sleeping, Walking, Running, Cycling, and Travelling entries to the timeline and Insights dashboard.

## Open the project

1. Install full Xcode from the Mac App Store and launch it once.
2. XcodeGen 2.45.4 is installed locally in this workspace.
3. To regenerate the project, run `.tools/xcodegen/bin/xcodegen generate`, then open `LifeLog.xcodeproj`.
4. Select your Apple development team under Signing & Capabilities.
5. Run on a physical iPhone; visit monitoring is not meaningfully testable in the simulator.

## Source layout

Sources are grouped by what they do, under `LifeLog/`. `project.yml` globs the
whole directory, so adding a file to any of these folders needs no project edit —
just regenerate.

| Folder | What lives there |
| --- | --- |
| `App/` | Entry point, root tab view, store opening and recovery |
| `Model/` | SwiftData models and the versioned schema/migration plan |
| `Location/` | Core Location recording, stay resolution, geofences, Maps lookup, Saved Place learning, review queue |
| `Activity/` | Activity vocabulary, icons, colours, statistics, inference, Health/Motion import |
| `Journal/` | CSV journal import and compaction |
| `Timeline/` | The day's journey, its visit editor and artwork, manual entry |
| `Insights/` | Aggregation snapshot, the donut, the places map, export |
| `Places/` | Saved Places and place history |
| `Settings/` | Settings and the activity/group editors |
| `Diagnostics/` | Diagnostic records and the screens that show them |
| `Support/` | Text safety, name matching, backup, card styling, test seed data |

## Important behavior

- iOS, not the app, decides when visit events arrive. They can be delayed.
- Explicit Core Location service sessions keep **When In Use** and background **Always** authorization as separate user-controlled workflows.
- Background location is designed for low-power visit/significant-change monitoring, not continuous GPS tracking.
- Data remains in local SwiftData storage protected by the device data-protection class.
- Correcting a located visit creates or updates a reusable `SavedPlace` geofence. Future visits within its radius inherit the corrected name, category, and activity.
- Location visits take priority over passive device activity: movement inside a destination does not create a second Timeline card. Measured sleep and a deliberately started workout remain visible because they are direct evidence, not a passive movement guess.
- Timeline opens on today but can jump to any archived day without loading the complete archive. Insights supports day, week, month, and year windows.
- Connect Apple Health and Motion Activity from LifeLog Settings. Routine Health refresh uses a bounded window sized to the gap since the last import (2–30 days), manual Health re-import reads 30 days, and iPhone motion history reads the most recent 7 days.

## Next milestones

See `TODO.md`, which is the audited live list. The near-term priorities are proving
the rebuilt sleep/no-Watch path on real hardware, adding explicit archive search,
and completing location-quality and hardware validation. The test targets currently
cover location replay and invariants, Saved Place learning, archive/Insights
aggregation, migrations, import recovery, and UI reachability.
