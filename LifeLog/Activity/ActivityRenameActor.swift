import Foundation
import SwiftData

/// Merging two activities can legitimately touch every recorded occurrence, but
/// never needs to hold the editor or Settings list on the main actor while it does.
@ModelActor
actor ActivityRenameActor {
    /// Folds one whole activity identity into another: every text label the source
    /// has ever carried (its current name plus any legacy aliases) is rewritten to
    /// the target's name, and anything already staged onto the source's
    /// `activityDefinitionID` is repointed to the target rather than left dangling
    /// once the source definition is removed from the catalogue. This is the real
    /// replacement for the old rename-into-an-existing-name trick, which the ID
    /// migration made unsafe (see `ActivityCatalog.mergeActivity`) — matching stays
    /// case-insensitive for the same reason every other free-text match here is.
    func mergeActivity(sourceID: UUID, sourceNames: [String], targetID: UUID, targetName: String) throws -> Int {
        let lowerNames = Set(sourceNames.map { $0.lowercased() })
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        var changed = 0
        for visit in visits {
            var touched = false
            if let userActivity = visit.userActivity, lowerNames.contains(userActivity.lowercased()) {
                visit.userActivity = targetName
                touched = true
            }
            if lowerNames.contains(visit.inferredActivity.lowercased()) {
                visit.inferredActivity = targetName
                touched = true
            }
            if visit.activityDefinitionID == sourceID {
                visit.activityDefinitionID = targetID
                touched = true
            }
            if touched { changed += 1 }
        }
        try Task.checkCancellation()
        let places = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        for place in places where place.activityDefinitionID == sourceID
            || lowerNames.contains(place.defaultActivity.lowercased()) {
            place.defaultActivity = targetName
            place.activityDefinitionID = targetID
        }
        try Task.checkCancellation()
        if changed > 0 || !places.isEmpty { try modelContext.save() }
        return changed
    }
}
