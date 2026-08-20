# LifeLog — code roadmap

Rebuilt from a repository-wide audit of `main` at `9f65bfe` on 2026-08-19 and
updated after the migration-debt cleanup. This is an
open-work list, not a record of shipped features. The previous roadmap (from
2026-08-16) was mostly completed since — backup manifest/versioning, Settings'
status-led redesign, the maintenance coordinator, the archive-wide-fetch contract,
activity-catalogue durability, staging-file hardening, and the `VisitEditor`/Timeline
ownership seams all landed — so it was rebuilt rather than amended.

LifeLog is a private app for one iPhone 17 Pro Max, owned and used by one person.
Correct history, predictable background ingestion, responsive access to the archive,
and code that can be changed safely outrank App Store preparation or speculative
integrations.

## Correctness and recovery — still open

- [ ] **Run one explicit audit of the cleaned archive, then retire four historical
  Timeline passes.** Once the audit reports clean, delete
  `automatic-location-deduplicated-v3`, `stay-splits-rejoined-v1`,
  `WorkoutJourneys.splitWorkoutRepairKey`, and `location-policy-reconciled-v13`,
  together with their remaining repair passes. These exist to repair old output;
  current arrivals/imports already have bounded reconciliation.
  **Last run against the real archive 2026-08-17: not clean.**
  `deduplicateAutomaticLocations` and `WorkoutJourneys.repairSplitWorkouts` found
  nothing, but `rejoinStaysSplitByMovement` and `reconcileAll` still changed rows
  identically across fresh backups after a confirmed successful reconciliation run.
  Root cause found and mitigated (see the next item); once that mitigation has had a
  few more days of normal on-device use, re-run this same audit before trying the
  retirement again.

- [ ] **Merge adjacent same-place `.automatic` stays with nothing recorded between
  them at all.** `coalesceStaysAcrossUnlocatedMovement` only folds away a fragment
  that carries no coordinates; `mergeOverlappingStays` only merges stays that
  overlap in time. Neither reaches two touching-but-not-overlapping `.automatic`
  stays at the same place with a real gap and nothing recorded in it — the shape a
  multi-parking-spot Work commute produces (confirmed against the real archive
  2026-08-17: a 4-minute manual "walk from the car" row between an arrival and the
  main Work stay). Deliberately not started: needs a decision on how far a gap can
  stretch before two stays are no longer "the same visit," and must never touch a
  `manual`-source row someone entered by hand.

- [ ] **A drive with no Core Motion sample yet can lose its whole duration into the
  parking-spot stay at its start, not just the commute display.** Confirmed against
  the real archive 2026-08-20: leaving Work's geofence created a new stay (the
  parking spot) at 07:09:55; raw location samples show a real drive from there
  reaching 8.6km away by 07:23; a new Home arrival closed the loop at 07:25:15 —
  but CoreLocation's own `.visitDeparture` for the parking-spot stay did not fire
  until 07:26:27 (device already home), and no Core Motion automotive sample
  existed yet to bound the stay against (motion import is throttled to once every
  6 hours, `ActivityDataService.swift:720`). The parking-spot stay's departure
  defaulted to the next visit's arrival, so the entire ~15-minute drive read as
  "Visiting" the parking spot instead of commuting. Even once the motion sample
  does import, `boundStay`'s guard (`departure <= movement.end`,
  `ActivityLocationPolicy+Journeys.swift:64`) may not retroactively correct a stay
  whose departure was already pushed past where the real drive ended — unverified
  either way. Waiting on the owner to recheck the same day's data after the next
  motion refresh before touching this: `boundStay`/`extendStay` have already caused
  a nine-day repair loop from an earlier tuning attempt (see the comment at
  `ActivityLocationPolicy+Journeys.swift:114`), so a next change here needs a real
  before/after on-device comparison, not just reasoning about the code.

- [ ] **Find and eliminate the source of recurring duplicate sleep before removing
  `SleepSessionRepair`.** It has found duplicates after the original arrival-window
  bug was fixed, including around erase/restore and live Health sync. Serialize
  those operations or make Health sample ownership the idempotent import key. Keep
  the repair as a measured safety net until a test reproduces the race and the
  counter remains zero across real use.

## Tidiness — still open

A code-tidiness audit, 2026-08-20: simplification/deduplication candidates, not
correctness bugs (those stay in the section above). Ranked by how much confusion or
duplication cost each one actually carries.

- [ ] **Broken string interpolation garbles a real error message.**
  `ExportFileStaging.swift:15` — `"LifeLog couldn't write the temporary backup:
  (error.localizedDescription)"` is missing the `\` before the parenthesized
  expression, so anyone hitting this failure sees the literal text
  `(error.localizedDescription)` instead of the actual reason. `Diagnostics.swift`
  has an explicit comment (~line 662) warning against exactly this mistake after an
  earlier instance of it, which suggests this one slipped past the same review.
  Trivial, safe, one-line fix.

- [ ] **`ActivitySampleReader.swift` implements the same interval-merge algorithm
  twice.** `merge` (line 534, one caller) and `mergeWithIdentifiers` (line 550,
  three callers for sleep sessions) both sort-and-coalesce overlapping/near
  intervals within a gap tolerance — the second's own doc comment says "Same merge
  as above, but keeps track of...". `merge` could just be
  `mergeWithIdentifiers` with placeholder IDs stripped afterward, so a future fix
  to the gap-comparison logic only has to land once.

- [ ] **A per-category custom-colour override is read but never written anywhere.**
  `ActivityColors.swift:33` checks `UserDefaults` for
  `"LifeLog.CategoryColor.\(key)"` before falling back to `CategoryPalette` — no
  setter, no UI, no test writes that key. Half-built feature that adds a silent
  branch to the file's own stated "one place a colour is chosen," for a
  capability that doesn't exist yet. Either build the override UI or delete the
  read path.

- [ ] **Three call-alike but not-actually-equivalent `VisitHistoryQuery` lookups,
  two of them dead.** `day(_:calendar:includesImported:)`, `month(containing:)`,
  and `year(containing:)` (`VisitHistoryQuery.swift:8-33`) have zero call sites —
  Timeline actually builds its own inline `@Query` predicate instead
  (`TimelineView.swift`'s `PastDayJourney`), which doesn't even replicate what
  those functions do. Worse, `ArchiveSearchView.swift:5-7`'s doc comment cites
  `VisitHistoryQuery.day`/`.month` as if Timeline routes through them, which will
  send a future reader to dead code looking for where day-fetching really lives.
  Separately, `place(named:mapsIdentifier:limit:)` (line 35-45) is also unreachable
  — every real call site uses the sibling `place(mapsIdentifier:)` overload or
  `legacyPlace(named:)` instead.

- [ ] **`ActivityCatalog.mergeWorkingIntoWork(context:)` has no caller outside
  tests.** `ActivityCatalog.swift:807` — only referenced from
  `SavedPlaceLearningTests.swift`. Reads like a one-time "Working" → "Work" data
  migration that either already ran once and should be deleted, or was meant to be
  wired into `AppLifecycleCoordinator` alongside the adjacent
  `ActivityIdentityMigration.backfillNextBatch` and never was. Worth finding out
  which before touching it.

- [ ] **Shared formatting helpers live in a `Timeline` file that `Places` and
  `Settings` quietly depend on.** `formattedDuration`/`durationWithinDay`/
  `formattedDistance` (`Timeline/TimelineView.swift:691,703,711`) are called from
  `PlaceHistoryView.swift`, `Settings/ActivitiesTabView.swift`, and
  `Settings/ActivityDetailView.swift`. Not wrong, but it breaks the "one obvious
  home" pattern `ActivityColors.swift`/`CategoryPalette.swift` were themselves
  written to establish for lookups — someone in `Settings` looking for where
  duration text comes from has to know to check a `Timeline` file first. Lowest
  priority here: a mechanical move to a neutrally-named formatting file, not a
  design change.

## Deliberately not priorities

- App Store metadata, public privacy policy, consumer onboarding, and generalized
  release work while LifeLog remains a private personal app.
- Cloud sync, a website, or multi-user infrastructure before local restore is complete
  and demonstrably atomic.
- Broad medical-data collection, diagnoses, or correlations presented without enough
  samples and explicit source/coverage context.
- Photos, widgets, and write-capable App Intents ahead of lifecycle cleanup, backup
  fidelity, and the recording-quality/routine insights above.
