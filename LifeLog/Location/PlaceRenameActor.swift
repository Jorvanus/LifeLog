import Foundation
import SwiftData

/// Merging two place names can legitimately touch every recorded visit, but never
/// needs to hold a drill-down sheet or Places list on the main actor while it does.
/// Modelled directly on `ActivityRenameActor`: the same shape of problem (multiple
/// text labels that should read as one) shows up for places just as it does for
/// activities -- an imported journal address and a Saved Place both meaning "home",
/// for instance, kept apart only because nothing ever rewrote one to match the other.
@ModelActor
actor PlaceRenameActor {
    /// Rewrites every visit whose `placeName` matches (case-insensitively) any of
    /// `sourceNames` to `targetName`. Saved Places are left alone: a merge here is
    /// about the text label history is grouped by, not about deleting a geofence
    /// definition, which is a separate, more consequential action a person takes
    /// deliberately in Places settings if they want it too.
    func mergePlace(sourceNames: [String], targetName: String) throws -> Int {
        let lowerNames = Set(sourceNames.map { $0.lowercased() })
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        var changed = 0
        for visit in visits where lowerNames.contains(visit.placeName.lowercased()) {
            visit.placeName = targetName
            changed += 1
        }
        try Task.checkCancellation()
        if changed > 0 { try modelContext.save() }
        return changed
    }
}
