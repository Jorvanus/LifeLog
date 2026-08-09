# Repository workflow

## Project scope

LifeLog is a private, personal-use app for the owner’s iPhone and is not currently
being prepared for App Store distribution. Prioritise useful behaviour, correctness,
diagnostics, responsiveness, and efficient storage over broad-market accessibility,
generalized privacy copy, or release-readiness work. For diagnostics, exposing the
owner’s personal data is acceptable when explicitly useful for troubleshooting, but
do not publish or push personal data, credentials, signing material, or device
backups. Continue to protect against accidental destructive changes and explain
when a diagnostic intentionally includes sensitive local data.

The owner’s device is an iPhone 17 Pro Max. When verification needs a device,
target that model by default; use the simulator only when the check cannot be run on
the physical phone or when it is specifically requested.

For every requested edit in this repository:

1. Add a concise dated entry to `CHANGELOG.md` describing the user-facing change. Do not add routine verification, test, or build text.
2. Regenerate the Xcode project when `project.yml` or project inputs change.
3. Run checks appropriate to the change and report the result.
4. Do not commit or push automatically. Leave source and changelog edits for the user to review and commit.
5. Never commit credentials, signing certificates, provisioning profiles, personal location data, or generated build products.
6. Add concise code comments for non-obvious intent, safeguards, and edge cases. Explain why the behavior exists without restating straightforward code.
7. Before each commit, increment `CURRENT_PROJECT_VERSION` by one. Apply sensible semantic versioning to `MARKETING_VERSION`: increment the patch component for a tiny fix, the minor component for a substantial cohesive feature or workflow, and the major component only for a breaking data or user-flow change. Keep the version shown in Settings aligned with the generated build.
