# Change log

## 2026-08-02

### Corrected-visit geofence learning

- Correcting a located visit now creates or updates a reusable `SavedPlace` geofence.
- Renaming a visit updates the matching nearby saved place rather than creating a duplicate.
- Corrected categories and activities become the defaults for future visits within the saved radius.
- Added in-memory SwiftData tests for geofence creation and update behavior.

### Verification

- Two Xcode 27 / Swift 6 `SavedPlaceLearning` unit tests passed.
- iOS 27 simulator Debug build.
- iOS 27 generic-device Release build.
