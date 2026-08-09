# LifeLog — what's next

Audited against `main` on 2026-08-09. This is intentionally an **open-work**
list: shipped work has been removed, historical counts have not been carried
forward as if they were current, and hardware items remain only where the code
exists but has not yet been proven on the owner’s iPhone. LifeLog is still a
private, single-phone app; the App Store work is deliberately separate below.

## The next four code changes

1. [ ] **Make location resolution an invariant of every store mutation.** Run
   the resolver after arrivals, departures, corrections, Saved Place edits and
   relaunch recovery. Add one diagnostic validator for: at most one current
   resolved visit, no resolved overlaps or negative durations, no superseded
   visit in Timeline/Insights, and no automation replacing a user correction.

2. [ ] **Move Visit identity to Maps identifiers in a V6 migration.**
   `SavedPlace` already keeps an `MKMapItem.identifier`; `Visit` does not.
   Persist visit identifier plus field provenance, match identifier-first where
   available, and retain `NameKey` only as a carefully documented fallback for
   old or identifier-less records. Do not break existing backup restore.

3. [ ] **Make Saved Place learning conservative and reversible.** Do not turn
   one high scoring Maps result into a permanent Saved Place. Require repeated
   corroborating visits or a correction, preserve competing evidence, and add
   an alias/cluster rule for GPS drift around large venues without merging two
   genuinely different businesses.

4. [ ] **Make the archive searchable at archive scale.** Provide one scoped
   search over place, activity and note, surface note-bearing visits in the
   results and Timeline, and keep the query/index work off the main actor so
   nine years of data stays responsive.

## Device proof and data-quality work

- [ ] **Reproduce or retire the stale “Today’s Journey” theory.** It was seen
  once after midnight while the app had been backgrounded: the view’s day
  boundary is held in a clock refreshed only by its minute loop. Capture the
  relevant Diagnostics/scene state if it happens again; if confirmed, refresh
  that clock on foreground and when the view becomes active.

- [ ] **Force one real background-save failure.** Raise the three store files’
  protection class to `NSFileProtectionComplete` after launch, lock the phone,
  cause a background save, relaunch, and verify the pending failure reaches
  Diagnostics. The queue and unit test exist; device proof does not.

- [ ] **Run the location hardware checklist during ordinary use.** Verify a
  Saved Place names an entry without a Maps request, a geofence exit closes at
  the crossing, Wi-Fi assists a departure, the region-ranking diagnostic makes
  sensible choices within iOS’s 20-region cap, and the first Core Motion import
  records its proof. Keep the resulting Diagnostics/backup, not personal data
  in source control.

- [ ] **Exercise real callback traces with detailed diagnostics enabled.**
  Record an arrival, departure, geofence crossing and a noisy/poor-signal case;
  inspect the journal beside that day’s Timeline. Add deterministic replay
  fixtures for delayed and repeated callbacks, departure-before-arrival,
  coordinate drift, overlapping geofences, missing departures, relaunch with
  an open visit, and Home → destination → Home.

- [ ] **Prove or constrain foreground live-location bursts.** On hardware,
  confirm stationary indoor arrival settles promptly, continuous walking makes
  no visit, and bad signal ends cleanly. Add an on-demand Diagnostics trigger
  and sample-level trace only if the ordinary-use proof is insufficient; never
  silently fall back to a single-fix inference.

- [ ] **Handle reduced-accuracy location honestly.** Detect it in Settings and
  Diagnostics, explain its effect, and prevent it from teaching Saved Places or
  driving fine distance comparisons.

- [ ] **Calibrate rather than cargo-cult thresholds.** Review a few weeks of
  real traces before trusting `walkingBurstGap`,
  `maximumStayShareConsumedByJourney`, `passingStayCoverage`, and
  `passingStayPace`; record why each change is made and what cases it changes.

- [ ] **Complete the Health and motion device matrix.** Test denial, partial
  permission, no data, disconnected Watch, duplicate/deleted samples, DST and
  timezone changes. Watch one overnight sleep observer path end-to-end, grant
  Workout Routes then re-import, and show the age of the last received sample
  instead of treating “prompt shown” as proof of Health access.

- [ ] **Decide the Health re-import product boundary.** It currently rereads a
  fixed 30-day window. If older workout routes matter, design a date-range
  import with progress, cancellation, retry and an understandable summary.

- [ ] **Make Home and Work explicit Saved Place roles.** Stop discovering them
  from name keywords; then add recurring-trip tests and decide whether a
  commute deserves its own Timeline row. Keep location first: movement inside
  a destination must not become a separate visit.

## UI things to consider

- [ ] Replace green model-oriented confidence labels (`Low`, `Medium`,
  `Learned`) with decision-oriented states such as **Needs checking**,
  **Suggested** and **Confirmed**. Do not show a badge when it gives no useful
  action or assurance.

- [ ] Build visual regression coverage from approved screenshots. Existing UI
  tests prove reachability, not overlapping or unreadable text. Cover normal
  and Accessibility XXXL text in light and dark appearance, then review Place
  History, Visit Editor and Add Visit at the largest size.

- [ ] Expand interaction coverage for the Insights donut: select/deselect
  several segments, including Sleep, scroll away and back, and verify the
  chart remains accessible and tappable.

- [ ] Add a day-level investigation view that places raw location callbacks,
  resolver decisions and the final Timeline side by side. Mark location-journal
  exports conspicuously as sensitive personal location data.

- [ ] Make all permission and recovery states useful on screen: precise versus
  approximate location, Health’s last successful sample, background-location
  availability, low storage, failed import/export, and backup restore outcome.

- [ ] Revisit the activity catalogue workflow after real use: recently used,
  history-only and unused labels are now separated, but bulk adoption and
  colour/icon choices need to remain understandable without a second route.

## Insight enhancements

- [ ] Correct the highest-value imported place history and adopt active
  activity labels. Inference from place and time band, weighted toward
  corrections and LifeLog-created entries over bulk-imported defaults, now
  exists and only gets better answers once this curation happens — it isn't a
  replacement for doing it.

- [ ] Surface recurring commute patterns and meaningful changes in time away
  from Home only after explicit Home/Work roles and the underlying location
  validation are trustworthy.

- [ ] Let place-score and correction evidence explain an insight’s confidence;
  never promote an inferred pattern as fact merely because the archive is large.

## Other things to consider and improve

- [ ] **Validate a copied pre-versioned device store.** The synthetic migration suite now passes after correcting its V4 model-type mismatch and rebuilding the legacy fixture from the exact unversioned V1 shape. That proves the declared migration stages, but only a copied store from before versioning can prove the real on-device upgrade path. Keep the original protected store untouched.

- [ ] Make MapKit lookup work testable: inject the search transport, test cache
  expiry/cancellation/retry paths without live Maps, keep candidate payloads
  bounded and deduplicated, and make lookup opt-out plus a manual-pin fallback
  explicit.

- [ ] Add automatic expiry to opt-in detailed location diagnostics and clear
  retention/deletion controls for coordinates, imported journals, Health and
  Motion records, Diagnostics, exports and all app data. Show count, storage
  estimate and irreversible scope before deletion.

- [ ] Protect data interchange: set an explicit strong file-protection class
  on backups/exports, shorten temporary share-file lifetime or clear after the
  share sheet, preflight low storage, and never delete a source record because
  an export failed.

- [ ] Keep import and restore resilient: visible progress, cancel/retry,
  malformed/duplicate/compactable-row summary, plus a personal-device
  regression checklist for fresh install, upgrade, migration, store recovery,
  backup restore, permission changes and relaunch.

- [ ] Isolate UI-test state completely. A seeded run must use/reset a scratch
  defaults suite for every app-owned key, not just its in-memory SwiftData
  store, so test order cannot change results.

- [ ] Re-run archive performance on the physical phone after each data-shape
  change. Keep aggregate timing only; investigate any main-thread stall over
  250 ms.

- [ ] Re-audit newly adopted iOS SDK capabilities only when a public SDK is
  actually installed and a concrete LifeLog problem justifies the deployment
  target change. Do not reserve roadmap space for unverified beta APIs.

- [ ] Consider notes/photos, read-only App Intents/Shortcuts, widgets and
  multi-device sync only after their local privacy, retention, deletion and
  recovery behaviour is designed.

## If LifeLog goes on the App Store

This is a separate release programme, not a switch to flip. Before submitting,
build a release checklist around the exact build and its actual behaviour:

- [ ] **Set up distribution and honest store metadata.** Enrol and configure
  App Store Connect, choose category/age rating/price/territories, supply a
  support URL and current screenshots, test the release archive on real
  hardware, and write review notes that explain why foreground and background
  location, Health and Motion are core to the journal. Do not claim features
  the app has not proven on-device.

- [ ] **Publish a plain privacy policy and complete the App Privacy answers
  from a verified data map.** Include precise location, place names, notes,
  Health/Motion-derived records, diagnostics, backups/exports and any MapKit
  request. State what stays on device, what leaves the device, retention,
  deletion and how support requests are handled. Re-check this with every SDK
  or dependency update.

- [ ] **Audit the privacy manifest and required-reason APIs before every
  upload.** The current manifest declares UserDefaults, while export cleanup
  also reads file timestamps. Inventory app and SDK calls, declare only
  Apple-approved reasons that accurately match functionality, and run archive
  validation before App Store Connect does it.

- [ ] **Turn diagnostic and data ownership into a consumer-safe experience.**
  Detailed location trace must be off by default, time-limited, clearly marked
  sensitive on export, and easy to delete. Backups/exports need explicit file
  protection and a disclosure at sharing time. Provide in-app deletion for all
  stored personal data; if an account or server is introduced later, add the
  corresponding account deletion flow and public process.

- [ ] **Design permissions for denial and review.** Give each permission a
  short, feature-specific explanation immediately before requesting it; keep a
  capable app when any is denied; ensure `Info.plist` wording, Settings copy,
  the privacy policy and review notes agree; and test fresh-install, upgrade,
  approximate-location, background-denial and Health partial-access paths.

- [ ] **Keep Health data within Apple’s rules.** Use it only for the stated
  health/fitness experience, never for advertising or data brokerage, and do
  not put personal HealthKit-derived information in iCloud or another remote
  store without a design and review that meets Apple’s HealthKit terms. The
  current app has no CloudKit sync; treat enabling it as a new privacy review.

- [ ] **Meet baseline quality and accessibility.** Exercise VoiceOver, Dynamic
  Type, contrast, keyboard/focus, error recovery, offline Maps fallback,
  network loss, low storage and battery impact on supported devices. Resolve
  crashes, stalled imports and misleading automation before submission.

- [ ] **Review all third-party and system surfaces.** Maintain licences,
  dependency privacy manifests, support/contact route, export control, and a
  release-only diagnostic policy. Never ship personal backups, diagnostics,
  signing material or test fixtures containing real locations.

Official references: [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/), [required-reason APIs](https://developer.apple.com/documentation/BundleResources/describing-use-of-required-reason-api), and [HealthKit privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy).

## Deliberately not doing

- **A duplicate-label merge tool.** The prior archive audit found insufficient
  genuine duplicates to justify its complexity; keep normalisation and rename
  paths good instead.
- **Movement/Health as a primary place-inference signal.** It remains weaker
  than location and can mislabel a legitimate stay. Use it to resolve journeys
  only after the location evidence is sound.
- **Standalone time-of-day inference.** Time becomes useful only when combined
  with a trusted place and correction history.
- **Persisting an Apple Maps “place type.”** It is an inference hint, not a
  stable fact. Preserve evidence and provenance instead.
