# Repository workflow

For every requested edit in this repository:

1. Add a concise dated entry to `CHANGELOG.md` describing the user-facing change. Do not add routine verification, test, or build text.
2. Regenerate the Xcode project when `project.yml` or project inputs change.
3. Run checks appropriate to the change and report the result.
4. Do not commit or push automatically. Leave source and changelog edits for the user to review and commit.
5. Never commit credentials, signing certificates, provisioning profiles, personal location data, or generated build products.
6. Add concise code comments for non-obvious intent, safeguards, and edge cases. Explain why the behavior exists without restating straightforward code.
