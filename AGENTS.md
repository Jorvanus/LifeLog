# Repository workflow

For every requested edit in this repository:

1. Add a concise dated entry to `CHANGELOG.md` describing the user-facing change. Do not add routine verification, test, or build text.
2. Regenerate the Xcode project when `project.yml` or project inputs change.
3. Run checks appropriate to the change before committing.
4. Commit with a descriptive message and push the current branch to `origin`.
5. Never commit credentials, signing certificates, provisioning profiles, personal location data, or generated build products.
