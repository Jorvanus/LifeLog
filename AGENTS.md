# Repository workflow

## Project scope

LifeLog started as a private, personal-use app for the owner's iPhone. It is now
moving toward distribution: first a small TestFlight group of trusted testers,
with a public App Store release a possible later step. Prioritise correctness,
predictable background ingestion, responsive access to the archive, and code that
can be changed safely — these matter more, not less, once other people's data and
devices are involved. Generalized privacy copy, onboarding that doesn't assume the
owner's own knowledge, and release-readiness work are now genuinely in scope; they
were previously deferred but should no longer be treated as out of bounds.

Diagnostics may still include a person's own personal data when it's genuinely
useful for their own troubleshooting — that has not changed. What has changed:
never assume the owner is the only person whose data appears in a diagnostic,
report, or example. Diagnostics and support reports are redacted by default for
this reason (see the 2026-08-20 changelog entry); keep that default intact rather
than reverting to always-verbose output as testers are added. Do not publish or
push personal data, credentials, signing material, or device backups regardless of
whose device they came from.

The primary development and verification device is an iPhone 17 Pro Max, and it
remains the default target for on-device checks. But TestFlight testers will carry
a range of iPhone models and iOS versions LifeLog has never run on before — do not
assume a change verified only on that one device and OS version is safe for
everyone. Flag when a change touches something already known to vary by device or
OS (Always location authorization, HealthKit/Watch pairing and sync timing,
CoreLocation/CoreMotion API behavior that has already differed across an iOS
version this project) so it gets a real before/after check rather than reasoning
alone.

For every requested edit in this repository:

1. Add a concise dated entry to `CHANGELOG.md` describing the user-facing change. Do not add routine verification, test, or build text.
2. Regenerate the Xcode project when `project.yml` or project inputs change.
3. Run checks appropriate to the change and report the result.
4. Do not commit or push automatically. Leave source and changelog edits for the user to review and commit.
5. Never commit credentials, signing certificates, provisioning profiles, personal location data, or generated build products.
6. Add concise code comments for non-obvious intent, safeguards, and edge cases. Explain why the behavior exists without restating straightforward code.
7. Before each commit, increment `CURRENT_PROJECT_VERSION` by one. Apply sensible semantic versioning to `MARKETING_VERSION`: increment the patch component for a tiny fix, the minor component for a substantial cohesive feature or workflow, and the major component only for a breaking data or user-flow change. Keep the version shown in Settings aligned with the generated build.
8. Assume the person using a given build may not be the owner and may not know the app's internals. UI copy, error states, and defaults should read clearly to someone who didn't build it, not just to whoever already knows why a screen behaves a certain way.
