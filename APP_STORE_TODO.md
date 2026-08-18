# LifeLog — TestFlight and App Store readiness

This is a release plan for moving LifeLog from a private, single-owner build to
TestFlight and, only if the product is ready for strangers, the App Store.

It is deliberately staged. TestFlight is first a controlled reliability exercise;
the App Store is a public promise about permissions, data handling, support,
updates, and recovery. Do not treat a successful archive or an approved beta as
proof that the public release is ready.

## Current position and decisions to make first

LifeLog currently has:

- a local SwiftData archive with complete file protection;
- background Location Services and Core Motion recording;
- read-only HealthKit imports for activity, workouts, sleep, heart and breathing
  signals, with anchored/idempotent import work;
- local JSON backup/restore and archive repair tools;
- no sign-in, account, cloud sync, analytics, advertising, or server dependency;
- iPhone and iPad in `TARGETED_DEVICE_FAMILY`, although the owner’s validated
  device is an iPhone 17 Pro Max;
- a deployment target of iOS 27.0, which must be an intentional release decision,
  not an accidental dependency on a beta SDK;
- a privacy manifest that currently declares UserDefaults access but still needs
  a complete required-reason-API audit;
- UI-test seed and failure-injection paths that must not become a reviewer-facing
  data path by accident;
- no committed public privacy-policy, support, or reviewer-instructions URL.

Before implementation, decide:

- [ ] **TestFlight only, or App Store as well?** TestFlight can remain a small,
  invite-only beta. App Store distribution adds public support, privacy, metadata,
  accessibility, review, update, and incident-response obligations.
- [ ] **iPhone only, or universal?** The project currently declares iPhone and
  iPad. Choose iPhone-only unless iPad is a real supported product surface. If
  universal remains selected, add iPad navigation/layout coverage before upload.
- [ ] **Minimum OS policy.** Ship against the current public SDK/OS supported by
  the release environment, or explicitly accept that an iOS 27-only build has a
  narrow audience. Do not submit an app that only builds with an unreleased beta
  toolchain unless that is intentional and App Store eligibility has been checked.
- [ ] **Public positioning.** Decide whether LifeLog is primarily a private
  location diary (Lifestyle/Productivity) with HealthKit enrichment, or a
  Health & Fitness product. The choice affects metadata, screenshots, review
  expectations, and how prominently HealthKit is presented.
- [ ] **Data portability promise.** The current backup is a user-directed JSON
  export containing sensitive location and potentially Health-derived records.
  Decide what the public product promises about export compatibility, retention,
  and future schema changes before inviting testers.

## Release gates at a glance

Do not upload until every blocker in this order is green:

1. Privacy, permissions, and data-flow documentation are truthful.
2. A fresh install can understand the product without the owner’s archive.
3. Background location, HealthKit, backup/restore, and protected-store behavior
   have been exercised on a physical device.
4. Release builds are reproducible, signed, symbolicated, and free of test hooks.
5. TestFlight has a documented feedback and rollback process.
6. App Store metadata, screenshots, age rating, and review notes match the build.

## 1. Apple account, identifiers, and release configuration

- [ ] Enrol the correct Apple Developer Program team and confirm the legal seller
  name, tax/banking agreements, and App Store Connect roles.
- [ ] Create/verify the App Store Connect app record for the exact bundle ID
  `com.aaronbaxter.LifeLog`. Never change the bundle ID after testers have data.
- [ ] Confirm the development team, automatic signing, distribution certificate,
  provisioning profiles, entitlements, and App Store Connect capability state are
  aligned. Keep signing material out of the repository.
- [ ] Decide whether the personal team is sufficient for TestFlight and App Store
  distribution. Do not assume a personal provisioning profile supports every
  production capability or external beta workflow.
- [ ] Keep `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, the Settings version,
  archive version, and App Store Connect version record aligned. Use a new build
  number for every upload; never reuse a processed build number.
- [ ] Generate the Xcode project from `project.yml` before release work and archive
  from the generated project/scheme, not an unreviewed local project mutation.
- [ ] Select the release SDK deliberately. Record the Xcode version, SDK, Swift
  version, deployment target, and commit used for each uploaded build.
- [ ] Add a release configuration review for strict concurrency, dead-code
  stripping, optimization, symbol generation, bitcode-era assumptions, and
  compiler warnings. A Debug build passing is not release evidence.
- [ ] Verify the archive contains only the LifeLog app and intended resources;
  inspect embedded provisioning, entitlements, bundle identifier, version, and
  supported devices before upload.

## 2. Privacy, legal, and data-flow contract

Apple requires a privacy-policy URL for iOS apps and accurate App Privacy answers.
The in-app explanation and App Store metadata must agree with the implementation.

### Public documents and in-app access

- [ ] Publish a stable HTTPS Privacy Policy URL before external TestFlight review.
  It must identify:
  - what location, motion, HealthKit, diagnostic, and backup data LifeLog reads;
  - when each source is collected and what feature uses it;
  - that HealthKit data is read-only and never used for advertising, marketing,
    eligibility, insurance, or data mining;
  - whether Apple Maps/MapKit receives coordinates or search requests and what
    Apple’s service handles;
  - whether anything leaves the device (including user-selected share/export
    destinations, email, crash reports, or support attachments);
  - local storage protection, backup behavior, retention, deletion, and restore;
  - how a person revokes permissions and how they request help or deletion;
  - the absence or presence of third-party SDKs, analytics, identifiers, and
    server-side processing.
- [ ] Add an easily accessible in-app Privacy Policy link in Settings/About. A
  paragraph saying “stored locally” is not a substitute for the public policy.
- [ ] Publish a stable Support URL and a monitored support address before inviting
  anyone. A dead GitHub issue page or a private personal URL is not a support plan.
- [ ] Decide whether Terms of Use are needed. The standard Apple EULA is an option;
  a custom EULA needs legal review and must not contradict the privacy policy.
- [ ] Decide whether a separate privacy-choices/data-request URL is useful. It is
  optional for App Store Connect, but a clear local deletion/export explanation is
  still required for trust and support.

### App Privacy answers

- [ ] Complete App Store Connect App Privacy for the actual shipping build, not
  the intended architecture. Include data accessed by integrated Apple services
  and any future SDKs.
- [ ] Determine the exact labels for Location and Health & Fitness: collected or
  not collected under Apple’s definitions, linked or not linked, and purpose
  (App Functionality). Do not assume “on device” automatically means “not
  collected”; answer based on Apple’s questionnaire definitions.
- [ ] Document whether user-initiated backup/share counts as collection or sharing
  under the current App Privacy questionnaire, and keep the answer synchronized
  with the privacy policy and export UI.
- [ ] Record that LifeLog does not track across apps or websites, does not sell
  data, and has no advertising/analytics SDK—only if that remains true in the
  submitted binary.
- [ ] Revisit the answers whenever a new HealthKit type, SDK, support mechanism,
  or export destination is added.

### Privacy manifest and required-reason APIs

- [ ] Audit every required-reason API in the source and all linked dependencies.
  The current manifest declares UserDefaults only; verify whether file timestamps,
  disk-space queries, system boot time, or other listed APIs are used and add only
  the Apple-approved reason codes that actually apply.
- [ ] Validate the built archive’s privacy manifest, not just the source file.
- [ ] Confirm `NSPrivacyTracking` and tracking domains remain false/empty if there
  is no tracking.
- [ ] Keep private archive data, device backups, signing files, provisioning
  profiles, and real location exports out of the repository and all screenshots.

## 3. Permission and background-behavior readiness

### Location

- [ ] Test the complete path on a physical device: first launch, While Using,
  Always, denied, restricted, Precise Location off, background refresh off, Low
  Power Mode, airplane mode, reboot, force-quit, locked phone, and relaunch.
- [ ] Verify the permission explanation is specific and honest: LifeLog records
  visits in the background, does not claim continuous turn-by-turn tracking, and
  may depend on iOS visit/significant-change delivery timing.
- [ ] Explain what happens when the person grants only While Using. The app must
  remain useful and clearly show that background recording is unavailable.
- [ ] Verify `UIBackgroundModes=location` is necessary, battery behavior is
  acceptable, and review notes explain the direct user-facing feature that needs
  it. Remove the background mode if the product cannot justify it.
- [ ] Test that a long gap, delayed callback, duplicate callback, open stay, and
  travelling-by-car scenario produce an understandable result without claiming
  transport mode the evidence cannot support.
- [ ] Confirm geofence/monitored-place limits, registration failures, authorization
  changes, and recovery after iOS evicts or suspends the process are visible in
  Diagnostics without blocking the main Timeline.

### Motion

- [ ] Test unavailable motion hardware, denied motion permission, no samples, and
  delayed samples. Missing motion must never render as zero activity.
- [ ] Verify the motion purpose string describes the actual walking/running,
  cycling, and travel enrichment and does not imply medical measurement.
- [ ] Measure battery impact over a representative day with location and HealthKit
  enabled, then repeat with each source denied.

### HealthKit

- [ ] Confirm the HealthKit capability, read-only request set, and Info.plist
  purpose string match the exact types requested in `HealthKitTypeCatalog`.
- [ ] Request only the types that support a named screen and have tested
  authorized, denied, unavailable, empty, stale, and partially available states.
- [ ] Do not request Health access at launch. Request it in a clearly explained
  Health screen or feature context, and send the person to system Health privacy
  settings when access must be changed.
- [ ] Verify the UI says “recorded” or “not available” rather than interpreting
  heart/breathing values medically. Do not use Health data in advertising,
  marketing, eligibility, or social comparison.
- [ ] Test lock-state behavior and delayed HealthKit delivery. Health data may be
  unavailable while the device is locked; the app must retry without declaring
  zero or failure prematurely.
- [ ] Test anchored delivery, deletion, restore/erase, cancellation, and two
  simultaneous refreshes. The idempotent sample ownership key must remain stable
  and the duplicate-sleep safety net must stay at zero in repeated device runs.
- [ ] Decide whether routes or mobility types are truly needed. Every additional
  type needs a named screen, permission explanation, empty/denied state, and a
  fixture that distinguishes missing from zero.
- [ ] Confirm no HealthKit data is written and no personal health data is stored in
  iCloud. A user-directed local JSON backup still needs explicit privacy/export
  wording because it can contain sensitive data.

## 4. First-run product experience

An App Store reviewer and an external tester will not have the owner’s archive.
The app must make its value and limitations clear with no permissions granted.

- [ ] Add a short first-run onboarding flow covering the product, local-first
  storage, permission choices, and how to add a manual visit. Do not hide the main
  app behind a long tutorial or require every permission to continue.
- [ ] Add pre-permission explanations immediately before requesting Location,
  Motion, and HealthKit. Keep them contextual and shorter than the system sheet.
- [ ] Provide useful empty/denied/restricted states for Timeline, Insights,
  Activities, Places, Apple Health, Diagnostics, backup, and restore.
- [ ] Show an active import, permission failure, and store-recovery failure at the
  top of the relevant hub. Opening a tab must not be what starts repair or makes
  the database usable.
- [ ] Keep manual entry useful with no permissions. A person must be able to add a
  visit, choose a place/activity, edit it, and see it in Timeline and Insights.
- [ ] Decide on a reviewer/demo path. The current `UITestSeedData` is test
  infrastructure, not automatically a safe production demo mode. If a demo mode
  ships, it needs clear “sample data” labeling, one-tap removal, no collision with
  real records, and release-build tests. Otherwise provide precise reviewer notes
  using manual data and permission-denied states.
- [ ] Ensure every destructive or archive-wide action explains scope, destination,
  progress, cancellation, and what is recoverable before it starts.

## 5. Archive, backup, restore, and migration safety

This is a local-first app, so data recovery is part of the product—not an internal
debug convenience.

- [ ] Test first install, upgrade from the previous supported schema, interrupted
  migration, protected store while locked, low disk space, corrupt backup, partial
  backup, cancelled restore, restore over existing data, and erase cancellation.
- [ ] Keep the stated backup contract accurate: the created file starts in iOS’s
  temporary directory, stale temporary exports are swept on a later launch/export
  after the retention threshold, iOS may purge them earlier, and a copy saved via
  the share sheet belongs to the chosen destination and is never deleted by LifeLog.
- [ ] Write backup files with complete file protection, report space/write errors
  precisely, clear stale `backupURL` state when the file disappears, and never
  present a temporary staging copy as a durable backup.
- [ ] Validate backups before restore: schema marker, record counts, duplicate
  HealthKit sample ownership, malformed dates, unsupported versions, and required
  fields. The current public policy is to support the current and immediately
  previous scheme only; document the intentional cutoff and the user-visible error.
- [ ] Keep whole-store operations off the interaction path. Backup, explicit archive
  repair, rename/merge, archive statistics, and complete validation need progress,
  cancellation, bounded diagnostics, and the 32,000-row fixture.
- [ ] Keep launch, Settings opening, ordinary navigation, and per-day correction
  bounded. Verify no full `Visit` fetch appears in those paths.
- [ ] Test the 32,000-row fixture for launch, Timeline return, day/week/month/year
  Insights, Settings opening, backup setup, activity/place merge, and every newly
  accepted whole-store operation. Fail tests on generous device-class budgets.
- [ ] Verify that restore invalidates caches, re-runs versioned maintenance only
  after the restored store saves, and cannot leave an old completion marker saying
  the new archive was repaired.
- [ ] Ensure imported-journal rows, HealthKit IDs, aliases, activity definitions,
  saved places, corrections, and diagnostics survive backup/restore as intended.

## 6. Product architecture and release hardening

- [ ] Keep a versioned `MaintenanceCoordinator` as the only owner of versioned
  archive maintenance. Persist completion only after a successful save; publish
  progress; make it callable after migration and restore; never let a tab’s
  appearance task become the repair trigger.
- [ ] Keep Timeline appearance limited to preparing its selected day and current
  presentation. Maintenance and diagnostics must not run in the main interaction
  path.
- [ ] Finish ownership-oriented seams for LocationRecorder, TimelineView,
  ActivityDataService, and VisitEditor. Each extracted owner needs focused tests;
  file length alone is not a reason to split code.
- [ ] Make performance budgets executable and retain diagnostics for physical-device
  evidence. Separate build, unit-test, simulator, signed-archive, and real-device
  claims; simulator success does not prove Location, Motion, HealthKit, protected
  storage, or battery behavior.
- [ ] Review all `Task`, actor, model-context, and main-actor boundaries in Release.
  A background HealthKit import must not write through a stale context after erase,
  restore, or cancellation.
- [ ] Add crash logging/symbolication and a small release diagnostic policy. Never
  attach raw personal location or Health data to an automatic crash report.
- [ ] Verify no debug launch argument, in-memory store, failure injection, test
  destination, or seeded fixture can be activated through ordinary user input in
  a distribution build. Prefer compile-time or explicit internal-build guards for
  developer-only paths.
- [ ] Add a migration/rollback note for every schema release. Keep the previous
  supported backup scheme test fixture in the repository, but do not silently
  promise indefinite historical imports.

## 7. Accessibility, device coverage, and localization

- [ ] Decide supported device families and orientations. If iPad stays enabled,
  test the actual iPad navigation, split layout, sheets, keyboard, maps, charts,
  and restore/backup flows—not just that the app launches.
- [ ] Test the owner’s iPhone 17 Pro Max plus the smallest supported iPhone, a
  non-Pro iPhone, and every declared iPad family. Test cold launch, warm launch,
  background return, locked-device return, and low-storage behavior.
- [ ] Test Dynamic Type through the largest accessibility sizes on Timeline,
  Insights, Health, Settings hub, Diagnostics, Visit Editor, backup/restore,
  permission failures, and empty states. Check that the new day bar and recent-day
  strip remain legible and tappable.
- [ ] Run VoiceOver through the day bar, recent-day strip, charts, custom icons,
  activity/place rows, destructive confirmations, and progress/cancellation UI.
  Every chart must have an equivalent spoken summary, not only colored blocks.
- [ ] Test Increase Contrast, Reduce Motion, Bold Text, Dark Mode, light mode,
  larger content sizes, and pointer/keyboard use on iPad if supported.
- [ ] Audit color contrast and do not make activity, travel, sleep, or unlogged
  state depend on color alone. The day bar’s textures/labels need to survive
  grayscale and color-vision differences.
- [ ] Decide supported languages. If shipping English-only, verify every user-facing
  string is in the string catalog and that dates, durations, health units, and
  permission copy are locale-safe. Localize metadata separately from the binary.

## 8. Diagnostics and support privacy

- [ ] Review Diagnostics and Location Journal exports as sensitive-data exports.
  Make the scope visible before sharing and offer a redacted/default form that
  removes exact coordinates, place names, notes, Health values, stable IDs, and
  device identifiers unless the owner explicitly opts into a detailed report.
- [ ] Add a concise “include detailed local evidence” explanation when a support
  report genuinely needs personal data. The recipient, retention, and deletion
  path must be clear.
- [ ] Ensure diagnostics do not log raw HealthKit samples, notes, home/work names,
  or exact coordinates on the normal hot path. Keep aggregate timings, counts,
  source labels, and error codes instead.
- [ ] Add a support workflow: copy report, share report, explain where it goes,
  cancel safely, and recover if the share sheet is dismissed. Do not require an
  account or cloud upload just to report a problem.
- [ ] Maintain a release incident checklist for data corruption, duplicate Health
  imports, stuck maintenance, battery regressions, and a bad migration. Document
  how to pause distribution and communicate a fix to TestFlight testers.

## 9. TestFlight plan

Apple’s current TestFlight model supports up to 100 internal testers and up to
10,000 external testers; the first external build is subject to beta review and
builds are testable for a limited period. Start much smaller than those limits.

### Internal build

- [ ] Upload a signed archive with a unique build number and wait for processing.
- [ ] Install on the owner’s physical iPhone and at least one clean test device.
- [ ] Test upgrade from the current private build, fresh install, uninstall/reinstall,
  locked-device launch, background recording, Health permission changes, export,
  restore, and erase.
- [ ] Verify the processed archive’s symbols, entitlements, privacy manifest,
  version, supported devices, and release logs.
- [ ] Record battery, storage growth, crash-free sessions, import failures, and
  location callback coverage over at least several normal days.

### External beta

- [ ] Create separate tester groups: a small trusted group, a location/Health
  heavy-use group, and an accessibility/device group. Do not start with a public
  link.
- [ ] Prepare Test Information: beta description, contact email, what to test,
  known limitations, privacy warning for exported diagnostics, and reviewer steps.
- [ ] Give testers a migration warning: this is a beta; keep a local backup before
  installing; restore is destructive and must be done deliberately.
- [ ] Provide release notes that ask for observations rather than vague opinions:
  permission state, background recording timing, battery, Health import counts,
  duplicate/missing rows, backup/restore result, and device/OS.
- [ ] Define stop criteria: data loss, duplicate sample counter above zero, failed
  restore, repeated crash, unacceptable battery drain, unbounded launch work, or
  any privacy-report mismatch stops expansion.
- [ ] Review TestFlight crash/session feedback after every build and keep a build
  changelog. Never use production personal data in screenshots or public feedback.

## 10. App Store product page and review package

- [ ] Choose a name of no more than 30 characters and a subtitle of no more than
  30 characters. Reserve “Health” language for features the app actually provides;
  do not imply medical diagnosis or clinical monitoring.
- [ ] Write a concise description explaining automatic visits, manual correction,
  explainable travel, Insights, Health enrichment, backup/restore, and local-first
  storage. Do not promise continuous GPS precision, automatic transport-mode
  certainty, or medical conclusions.
- [ ] Select primary/secondary categories based on the product decision above.
- [ ] Complete age rating, content rights, export-compliance questions, advertising
  declarations, and availability/pricing. Keep the answers consistent with the
  binary and privacy policy.
- [ ] Provide a final opaque 1024px icon and verify the dark/tinted variants on
  current OS versions. Remove accidental `.DS_Store` or source artifacts from
  the asset set.
- [ ] Capture screenshots using synthetic/demo data only. Show the product’s core
  value in order: Timeline day shape, Insights, Places/Activities, Health overview,
  and private backup/recovery. Avoid screenshots containing personal places,
  dates, Health values, device status, or debug diagnostics.
- [ ] Use Apple’s current App Store Connect screenshot specification rather than
  hard-coding a device resolution in this checklist. Upload the highest required
  size for each supported device family and verify every localized product page.
- [ ] Consider an app preview only after the static screenshots and copy are clear;
  it is optional and adds another reviewable asset.
- [ ] Write App Review notes with a short deterministic path:
  1. launch with no permissions and inspect the useful empty state;
  2. grant Location if available and explain background behavior;
  3. open Timeline/Insights with sample or manually added records;
  4. open Health and explain denied/empty states;
  5. demonstrate backup without sending private data to the reviewer.
- [ ] Explain why background location is central, how often the app records, what
  happens when permissions are denied, and why HealthKit is directly integrated
  into a health/fitness feature.
- [ ] Include a reviewer contact and a short video only if it materially removes
  ambiguity. Do not rely on a video to substitute for a working binary.
- [ ] Submit a privacy-policy URL in App Store Connect and make the same policy
  reachable inside the app.

## 11. Final verification record

Create one release record per uploaded build containing:

- commit, version, build number, Xcode/SDK, deployment target, and team;
- archive validation result and entitlements/privacy-manifest inspection;
- unit, focused regression, UI, performance-fixture, and migration results;
- physical-device evidence for Location, Motion, HealthKit, lock state, battery,
  backup/restore, and erase;
- tester group, known limitations, reviewer notes, screenshots, and privacy answers;
- rollback decision and the next supported migration/backup scheme.

### Suggested order

1. Decide scope (iPhone-only vs universal, TestFlight vs App Store, minimum OS).
2. Finish privacy/support documents and permission/empty-state UX.
3. Harden release-only paths, archive recovery, and reviewer reproducibility.
4. Establish physical-device and 32,000-row performance evidence.
5. Upload one internal TestFlight build and exercise upgrade/recovery.
6. Run a small external beta with explicit stop criteria.
7. Finalize metadata/screenshots, submit for App Review, and keep a support/rollback
   plan active after release.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Protecting user privacy / HealthKit](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)
- [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Upload screenshots and app previews](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/)
