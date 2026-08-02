# Change log

## 2026-08-02

### Editable insight slices

- Tapping an Insights pie segment now opens its contributing visit for editing, or a list when several visits make up the segment.
- Unlogged pie segments now offer a direct way to add the missing visit.

### Personal-device signing

- Data protection now matches the Personal Team provisioning profile so LifeLog can install on the registered iPhone.

### Corrected-visit geofence learning

- Correcting a located visit now creates or updates a reusable `SavedPlace` geofence.
- Renaming a visit updates the matching nearby saved place rather than creating a duplicate.
- Corrected categories and activities become the defaults for future visits within the saved radius.

### Location-first timeline

- Device activity is excluded wherever it overlaps an automatic or manual location visit.
- Partial walking, workout, sleep, or travel segments are trimmed so only time between places remains.
- Location visits also reconcile activity that was imported before Core Location delivered the visit.
