import Foundation
import SwiftData

/// Says why LifeLog did what it did to a location callback.
///
/// The resolver merges, supersedes, closes and promotes records constantly, and until
/// now none of it was written down — a stay that vanished or a name that changed left
/// no trace of which rule was responsible. Every reconstruction of a bug started from
/// a screenshot and guesswork.
///
/// The reason itself is safe to record and always is. The *evidence* — which places
/// Apple Maps offered, how far away each was, which was chosen — is a record of where
/// the owner has been, so it is written only when detailed diagnostics are switched
/// on, and expires with the rest of the log. Off, the same event still explains
/// itself; it just counts candidates instead of naming them.
@MainActor
enum LocationDiagnostics {
    enum Decision: String {
        case merged      // two records described one arrival
        case superseded  // a duplicate was kept but taken out of the timeline
        case closed      // an open stay was given an end
        case promoted    // a place was named, or a name was upgraded
        case rejected    // a candidate was declined and something else used

        var verb: String { rawValue }
    }

    static let detailKey = "LifeLog.Diagnostics.detailedLocation.v1"
    static let category = "location"

    /// Off by default. Turning it on is a decision to keep a fine-grained record of
    /// your own movements on the device, which is the whole reason it is a switch.
    static var isDetailed: Bool {
        get { UserDefaults.standard.bool(forKey: detailKey) }
        set { UserDefaults.standard.set(newValue, forKey: detailKey) }
    }

    /// - Parameters:
    ///   - subject: what was acted on, in a form safe to log — a source, a count.
    ///   - reason: the rule that fired. Always recorded.
    ///   - evidence: place names, distances, coordinates. Recorded only in detail
    ///     mode, and built lazily so nothing is assembled when it will be discarded.
    static func record(_ decision: Decision, subject: String, reason: String,
                       evidence: @autoclosure () -> String? = nil,
                       context: ModelContext?) {
        var message = "\(subject) \(decision.verb): \(reason)"
        if isDetailed, let evidence = evidence() {
            message += " — \(evidence)"
        }
        Diagnostics.record(context, subsystem: "Core Location", message: message,
                           severity: "info", category: category)
    }

    /// What a Maps lookup asked for, what came back, and what was done with it.
    ///
    /// Written as one line rather than several so a single lookup reads as a single
    /// decision, which is how it has to be read when reconstructing a wrong name.
    static func recordLookup(radius: Double, cacheHit: Bool, candidates: [PlaceSuggestion],
                             selected: PlaceSuggestion?, confidence: String,
                             fallback: String?, context: ModelContext?) {
        var message = "Maps lookup: \(cacheHit ? "cache hit" : "cache miss"), "
        message += "radius \(Int(radius.rounded())) m, \(candidates.count) candidates, "
        message += "confidence \(confidence)"
        if let fallback { message += ", fell back to \(fallback)" }
        if isDetailed {
            let listed = candidates
                .map { "\($0.name) (\(Int($0.distance.rounded())) m)" }
                .joined(separator: ", ")
            if !listed.isEmpty { message += " — offered: \(listed)" }
            if let selected { message += "; chose \(selected.name)" }
        } else if selected != nil {
            message += ", a candidate was chosen"
        }
        Diagnostics.record(context, subsystem: "MapKit", message: message,
                           severity: "info", category: category)
    }
}
