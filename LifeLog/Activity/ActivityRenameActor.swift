import Foundation
import SwiftData

/// Renaming an activity can legitimately touch every recorded occurrence, but
/// never needs to hold the editor or Settings list on the main actor while it does.
@ModelActor
actor ActivityRenameActor {
    func renameActivity(from: String, to: String) throws -> Int {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        var changed = 0
        for visit in visits {
            var touched = false
            if visit.userActivity?.caseInsensitiveCompare(from) == .orderedSame {
                visit.userActivity = to
                touched = true
            }
            if visit.inferredActivity.caseInsensitiveCompare(from) == .orderedSame {
                visit.inferredActivity = to
                touched = true
            }
            if touched { changed += 1 }
        }
        try Task.checkCancellation()
        if changed > 0 { try modelContext.save() }
        return changed
    }
}
