import Foundation
import SwiftData
import CoreLocation

/// Keeps the timeline location-first by removing device activity that occurs during a place visit.
@MainActor
enum ActivityLocationPolicy {
    nonisolated static let supersededLocationSource = "automatic-superseded"
}
