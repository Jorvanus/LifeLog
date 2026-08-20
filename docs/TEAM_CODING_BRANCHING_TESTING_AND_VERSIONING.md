# LifeLog team guide: coding, branches, testing, and versions

This is the simple rulebook for the small LifeLog team as we begin internal
TestFlight testing. It assumes nobody wants to become a Git or Xcode expert.

If you are unsure what to do, stop before merging or uploading a build and ask
the person coordinating the release. A bad merge or an untracked TestFlight
build is harder to undo than a short delay.

## The one-minute version

1. Start from an up-to-date `main` branch.
2. Make one small change on a branch named `feature/...`, `fix/...`, or
   `docs/...`.
3. Test the change locally. Run the focused checks first, then the broader
   checks that match the risk.
4. Open a pull request into `main`. Do not merge your own pull request unless
   the release coordinator explicitly says to.
5. Internal TestFlight builds are made from a reviewed release branch or a
   tagged commit, never from someone's unreviewed working copy.
6. Every commit must have a higher build number than the previous commit. A
   user-facing release also changes the marketing version when appropriate.
7. Write down what was tested, where it was tested, and what remains untested.

## What the branches mean

We use a small number of branch types. The name tells everyone what the branch
is for.

| Branch | Meaning | What belongs there |
| --- | --- | --- |
| `main` | The shared, reviewable product branch | Code that has passed review and is safe to combine with the next work |
| `feature/short-name` | A new capability | One cohesive feature, such as `feature/place-history-filter` |
| `fix/short-name` | A bug correction | One bug, such as `fix/health-import-retry` |
| `docs/short-name` | Documentation or process work | Guides, checklists, and explanatory text |
| `release/testflight-2.25.0` | A temporary TestFlight candidate | Only release fixes, version changes, and release notes for that candidate |
| `hotfix/short-name` | An urgent correction to an already-tested candidate | A fix needed before the current internal build can be trusted |

Do not create a permanent `develop`, `staging`, or `test` branch. They sound
useful but usually become extra places where code can get out of sync.

### `main` is not a playground

Do not make experimental edits directly on `main`. Do not leave half-finished
work there. `main` is where the team can see the best currently combined code.

The only exception is a tiny change agreed by the release coordinator, followed
by the same checks and documentation as a normal pull request.

## Where we test

Testing happens in layers. Passing one layer does not prove the next layer.

### 1. Local source checks — every change

The person making the change checks that the code is formatted sensibly, the
diff contains only intended files, and the project still describes the change.

From the repository folder:

```text
git status
git diff --check
```

If `project.yml` or project inputs changed, regenerate the Xcode project before
building:

```text
./.tools/xcodegen/bin/xcodegen generate
```

Do not hand-edit the generated Xcode project to make a change permanent. Put the
real change in `project.yml`, then regenerate it.

### 2. Build and automated tests — before requesting a merge

Run the repository verification script at the tier that matches the change.
The script is intentionally strict: a command that exits successfully but runs
zero tests is not considered a pass.

```text
./scripts/verify.sh fast
```

Use the focused unit/data/UI tiers described in `scripts/VERIFY.md` when the
change is narrow. Use the full unit and UI suites for changes that affect shared
models, imports, navigation, or common UI.

The pull request must say either:

- `PASS` — the named check completed successfully; or
- `NOT RUN` — explain why it could not be run.

Never write “tested” when you only inspected the source or compiled one file.

### 3. Simulator — repeatable app behavior

Use the iPhone 17 Pro Max simulator for repeatable UI and regression checks when
a physical phone is not required. This is useful for navigation, layout, seeded
sample data, empty states, error states, and UI tests.

The simulator does not prove real background location delivery, HealthKit or
Apple Watch delivery, motion data, protected-file behavior, battery impact, or
production signing.

### 4. Physical iPhone — real device behavior

Use the owner's iPhone 17 Pro Max for claims about:

- background and locked-phone location recording;
- Location and Motion permissions;
- HealthKit and Apple Watch imports;
- reboot, force-quit, Low Power Mode, and network gaps;
- data protection and protected-store access;
- battery and responsiveness over a normal day;
- backup, restore, and real archive migration.

Record the device model, iOS version, app version/build, scenario, result, and
any diagnostic evidence. A simulator pass must not be reported as a device pass.

### 5. Internal TestFlight — signed-build testing

TestFlight is the closest test to the build the team will actually install, but
it is still a controlled beta. Internal testers should test the signed build for
several days, using their normal workflows and reporting exact steps and the
version/build shown in Settings.

Internal TestFlight is the place to find problems involving distribution signing,
installation, upgrade from the prior build, first launch, permissions, and
real-world use. It is not permission to skip automated tests or device checks.

## What to test for common changes

| Change | Minimum evidence before merge | Extra evidence before TestFlight |
| --- | --- | --- |
| Text, documentation, or comments | Diff review and `git diff --check` | Not normally needed |
| One isolated view | Build, focused UI/unit test if available, simulator check | Physical phone if layout or permission flow is involved |
| Shared SwiftUI component | Full relevant UI tests and Dynamic Type/light-dark review | Physical phone smoke test |
| SwiftData model or migration | Focused migration/data tests plus full unit tests | Backup/restore and real-store device test |
| Location, motion, or HealthKit | Focused tests plus simulator checks for states | Physical iPhone testing is required |
| Release settings or entitlements | Generated-project diff and Release build | Signed archive inspection and internal TestFlight install |

## The normal coding workflow

### Start work

```text
git switch main
git pull --ff-only
git switch -c feature/short-name
```

Replace `feature/short-name` with the correct branch type. If `git pull` says
your local `main` has changes, do not overwrite them; ask for help first.

### While working

Keep the branch small and focused. Avoid mixing a feature with unrelated cleanup.
Commit in sensible pieces, with messages that say what changed:

```text
git add the/files/you/intended/to/change
git commit -m "Add clearer place history empty state"
```

Before each commit, follow the version rules below. Never commit passwords,
signing certificates, provisioning profiles, device backups, personal location
exports, or generated build products.

### Before opening a pull request

```text
git status
git diff --check
git fetch origin
git rebase origin/main
```

Run the relevant verification tier again after the rebase. Then open a pull
request from your branch into `main` with:

- a one-sentence summary;
- what changed and what did not change;
- checks run and their result;
- simulator/device/TestFlight evidence, if relevant;
- known limitations or follow-up work;
- screenshots or a short recording for visible UI changes.

### Review and merge

The reviewer checks the code, the tests, the version/build, the changelog entry,
and the stated evidence. The reviewer should ask “what could this claim not
prove?” for location, HealthKit, motion, migrations, signing, and release work.

After approval, merge the pull request into `main` using the team's agreed
GitHub merge button. Do not merge new work while a TestFlight candidate is being
stabilised unless the release coordinator confirms it belongs in that candidate.

Delete the feature branch after the merge if the hosting service offers to do
so. The merged commit remains in `main`; deleting the short-lived branch does
not delete the work.

## Preparing an internal TestFlight build

The release coordinator owns this process.

1. Confirm `main` is green and contains only reviewed work.
2. Create `release/testflight-2.25.0` from that exact `main` commit.
3. Update the marketing version/build and add release notes in the same change.
4. Run the full appropriate verification suite.
5. Build a Release archive and inspect its bundle ID, version/build, entitlements,
   provisioning profile, privacy manifest, and matching dSYMs.
6. Upload the archive to App Store Connect.
7. Add only the intended internal testers and tell them the exact version/build.
8. Track feedback by version/build and severity. Do not silently replace a build
   while testers are investigating it.
9. If a fix is needed, make it on `hotfix/...` or the release branch, review it,
   retest it, and upload the next higher build number.
10. When the candidate is accepted, merge the release changes back into `main`
    and tag the shipped commit if the team uses tags.

The first internal build should be treated as a reliability exercise. Do not
move to external TestFlight just because the upload succeeded.

## Versioning in plain English

LifeLog has two numbers:

- **Marketing version**, such as `2.25.0`: the human-facing product release.
- **Build number**, such as `249`: the unique number for one compiled build.

The numbers are configured in `project.yml` and copied into the app's Settings
and bundle during generation/build. Keep them aligned; do not edit only the
generated project.

### When to change each number

| Change size | Marketing version | Build number |
| --- | --- | --- |
| Documentation, comments, or a tiny safe fix | Usually unchanged | Increase |
| Small bug fix or polish release | Increase patch: `2.25.0` → `2.25.1` | Increase |
| Cohesive feature or meaningful workflow change | Increase minor: `2.25.0` → `2.26.0` | Increase |
| Breaking data format or user-flow change | Increase major: `2.25.0` → `3.0.0` | Increase |

Before every commit, increment `CURRENT_PROJECT_VERSION` by one. Before every
TestFlight upload, use a build number higher than every build already uploaded
to App Store Connect. Never reuse an uploaded build number, even if the code is
different.

If several branches are changing the version at once, stop and coordinate the
next number. The release coordinator is the final owner of the shared build
counter.

### Version checklist

- [ ] `project.yml` contains the intended marketing version and build number.
- [ ] `LifeLog/Info.plist` still uses the build settings, not hard-coded numbers.
- [ ] Settings shows the same version/build in the built app.
- [ ] The dated `CHANGELOG.md` entry names the user-facing change.
- [ ] The generated Xcode project was regenerated when project inputs changed.
- [ ] The archive and App Store Connect record show the same version/build.

## Merge-conflict instructions for beginners

If Git says there is a conflict, do not panic and do not click “accept all.”

1. Stop and read the file names Git lists.
2. Keep the version and changelog decisions made by the release coordinator.
3. For code, compare both sides and keep the behavior that matches the agreed
   feature. Ask the author if the intent is unclear.
4. Remove the conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
5. Run `git diff --check`, then the relevant tests.
6. Ask for review again if the conflict changed behavior.

Never resolve a conflict by deleting a whole file or accepting one side without
reading it.

## Bug reports from testers

Every report should include:

- app version and build from Settings;
- device model and iOS version;
- what the tester expected;
- what actually happened;
- exact steps to reproduce;
- whether it happens every time;
- screenshots or a screen recording when safe;
- relevant in-app Diagnostics output.

Do not attach a full backup or raw location archive unless the release
coordinator explicitly requests it through a private channel. Those files can
contain sensitive personal history.

Use these severity labels:

- **Blocker:** data loss, corrupt/failed migration, cannot launch, or a core
  recording failure;
- **High:** important workflow is wrong or unreliable, but a workaround exists;
- **Normal:** a repeatable defect that does not threaten data;
- **Polish:** wording, spacing, or a minor visual improvement.

## The team rule of thumb

Small branch. Clear commit. Evidence that matches the claim. One reviewer.
Higher build number. No secrets or personal archives in Git. When in doubt,
pause before merging.
