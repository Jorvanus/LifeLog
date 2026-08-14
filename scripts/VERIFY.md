# scripts/verify.sh

Repeatable LifeLog verification, built on `xcodebuild` and `simctl` only — no
Instruments, no Fastlane, no Simulator.app automation.

```bash
scripts/verify.sh <fast|data|ui-smoke|full|device-checklist>
```

Every simulator tier does the same four things before running anything:

1. Regenerates `LifeLog.xcodeproj` from `project.yml` with the repository's
   vendored XcodeGen (`.tools/xcodegen/bin/xcodegen`, **not** any Homebrew or
   global `xcodegen` — version can differ and silently produce a different
   project). Reports whether the checked-in `project.pbxproj` had drifted
   from `project.yml` before the run.
2. Resolves the destination to a `iPhone 17 Pro Max` simulator **UDID**
   (never a bare name — two devices sharing a name is a real failure mode on
   this Mac), preferring one that's already `Booted`. Boots it headlessly via
   `simctl` if needed. Never opens Simulator.app.
3. Uses a fresh, tier-appropriate `DerivedData` directory (wiped and
   recreated every run — see "Derived data paths" below).
4. Runs `xcodebuild`, tees output to a log file, and only calls the run a
   pass if **all** of: exit code 0, the expected `xcodebuild` success marker
   is present in the log, the `.xcresult` bundle exists with an `Info.plist`
   (a wedged run leaves one without it, and `xcresulttool` then refuses to
   read it — treat that as incomplete, not a pass), and — for test actions —
   `xcresulttool get test-results summary` reports at least one executed
   test and zero failures.

Any failure prints a `[verify] FAIL: ...` line and exits non-zero. Nothing in
this script erases a simulator, deletes a device's store, or touches a
physical device beyond a read-only `devicectl list devices`.

## Tiers

| Tier | What runs | Derived data |
| --- | --- | --- |
| `fast` | `build-for-testing` (whole scheme) + every `LifeLogTests` suite **except** the `data` tier's classes | `derived-focused` |
| `data` | Exactly the schema-migration, backup, resolver, import, and performance suites (see below) | `derived-focused` |
| `ui-smoke` | Four seeded, deterministic checks — one per named area (Timeline, Insights, Activities, Settings) | `derived-ui` |
| `full` | Every `LifeLogTests` suite, then every `LifeLogUITests` suite | `derived-focused` then `derived-ui` |
| `device-checklist` | Read-only device query + printed manual checklist; no build required to run it, though the commands it prints do build | — |

`fast` and `data` are two sides of the same list (`DATA_TEST_IDENTIFIERS` in
the script): `fast` skips it, `data` runs only it. They can't drift apart
from each other because they share the array — if you add a new class to one
side you also change the other.

### `data`: schema migrations, backup, resolver, import, performance

```
SchemaMigrationTests
LocalBackupTests
CurrentVisitInvariantTests, DepartureMatchingTests, DuplicateCallbackTests,
IgnoredAndConfirmedChoiceTests, ImportedHistoryInteractionTests,
OverlapResolutionTests, PresentationAndDiagnosticsTests,
TravelConstructionTests                                    (ActivityLocationPolicy resolver suites)
IncrementalLocationResolutionTests, VisitResolutionStateTests,
LocationArrivalConfirmationTests, PlaceScoringTests          (resolver, elsewhere)
ActivityImportActorTests, MalformedFixturesAndImportExportTests (import)
ResolverPerformanceTests                                     (performance)
```

`ResolverPerformanceTests` is the closest existing unit-level proxy for
`PERFORMANCE_BUDGETS.md`'s 32,000-row device archive check: it builds 20,000
rows in memory and asserts `InsightsSnapshot` aggregation stays sub-quadratic
(under 15s). It is **not** the 32,000-row on-device check itself — that only
exists as the manual `device-checklist` procedure, because a real archive
that size needs to be imported on hardware to mean anything. If you want a
literal 32,000-row in-memory guard added to the suite, that's a test change,
not a tooling change — this script just runs whatever exists today.

### `ui-smoke`: one seeded check per area, not the full UI suite

```
AccessibilitySmokeTests/testPrimaryScreensExposeStableAccessibilityHooks   (Timeline, Insights, Settings tabs exist)
InsightsDayTests/testInsightsDayShowsCurrentActivityCard                  (seeded Insights)
TimelineAndActivitiesTests/testActivityVisitsAreListedAndEditable         (seeded Timeline + Activities)
SettingsAndDiagnosticsTests/testSavedPlaceRoleControlIsReachable          (seeded Settings)
```

All four launch with the deterministic seed path
(`-uiTesting -ui-test-seed`, see `LifeLogUITests/Support/UITestSupport.swift`)
except the first, which only checks tab/accessibility-hook presence and
doesn't need fixture data. This is a smoke tier on purpose — the full
screenshot-matrix and visual-regression suites (`InsightsPeriodTests`,
`InsightsVisualRegressionTests`, the rest of `AccessibilitySmokeTests`) are
minutes slower and belong in `full`, not in a tier meant to run often.

## Derived data paths

Two fixed paths under the verify root, each wiped at the start of the tier
that uses it:

- `derived-focused` — `fast`, `data`, and the unit half of `full`.
- `derived-ui` — `ui-smoke` and the UI half of `full`.

Keeping them separate means a wedged UI run's derived data can never poison
the fast unit loop, and vice versa. "Fresh" here means wiped, not
incrementally reused — reproducibility was prioritised over rebuild speed for
a *verification* script; use plain `xcodebuild` yourself for iterative
development.

## Where output goes

```
${LIFELOG_VERIFY_DIR:-$TMPDIR/lifelog-verify}/<timestamp>/
  logs/<label>.log            # full xcodebuild output, tee'd live
  <label>.xcresult            # -resultBundlePath for that run
```

Override the root with `LIFELOG_VERIFY_DIR=/path/to/dir scripts/verify.sh ...`.
Nothing under here is ever committed — it's DerivedData/build-product
territory, out of scope for source control per `AGENTS.md`.

## Version alignment

`fast` and `full` finish their unit-test step by reading
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` out of `project.yml` and
comparing them against `CFBundleShortVersionString`/`CFBundleVersion` in the
just-built `LifeLog.app`'s `Info.plist`. Settings' "Version" row
(`SettingsView.swift`) reads those same two bundle keys directly, so a match
here means Settings will show the same string once that build is installed —
the script doesn't launch the app to confirm that separately.

## `device-checklist`

Purely informational, plus a read-only `xcrun devicectl list devices` query
so you can see at a glance whether the iPhone 17 Pro Max is connected and
trusted. It prints, but does not run, the build/test commands for the
physical device — installing and measuring is manual because the budgets in
`PERFORMANCE_BUDGETS.md` (250 ms first screen, 1,500 ms Year snapshot, etc.)
require Instruments' Time Profiler / Main Thread Checker to verify properly,
which this script deliberately doesn't attempt to automate.

A simulator PASS on any other tier tells you the app's logic is correct. It
proves nothing about geofencing, the Wi-Fi anchor, motion collection, or
HealthKit — those only run for real on hardware. Don't read a green
`ui-smoke` or `full` run as device-equivalent for anything sensor-related.

## Troubleshooting

**Most UI tests fail at once, all timing out.** Almost always a stale
`LifeLog.store` left on that simulator by an earlier schema version, not a
regression — see the "stale simulator" note below. This script never runs
`simctl erase` itself (erasing deletes the simulator's store, and the brief
for this script explicitly rules that out as an automatic action). If you
suspect this, erase the simulator yourself and re-run:

```bash
xcrun simctl list devices | grep "iPhone 17 Pro Max"
xcrun simctl shutdown <udid>
xcrun simctl erase <udid>
```

**`xcresulttool could not read ...xcresult`.** The bundle is
incomplete/wedged (usually an interrupted run). The script already treats
this as a failure rather than a pass; just re-run the tier.

**`No "iPhone 17 Pro Max" simulator is available.`** None exists on this
Mac. The script deliberately does not create one automatically — create it
with `xcrun simctl create` (the failure message prints the exact command
shape) or via Xcode's device manager, then re-run.
