import Foundation
import SwiftUI

/// The source boundary for every Insights result. This is presentation scope,
/// not a new activity catalogue: visits keep their original source and are only
/// included or excluded before the shared Insights aggregation pass.
enum InsightsScope: String, CaseIterable, Identifiable, Sendable {
    case allHistory = "all-history"
    case deviceAndManual = "device-and-manual"
    case importedJournal = "imported-journal"
    case confirmedLocations = "confirmed-locations"

    static let storageKey = "LifeLog.Insights.Scope"

    var id: Self { self }

    var title: String {
        switch self {
        case .allHistory: "All history"
        case .deviceAndManual: "Device + manual only"
        case .importedJournal: "Imported journal only"
        case .confirmedLocations: "Confirmed/corrected locations only"
        }
    }

    var emptyState: String {
        switch self {
        case .allHistory: "There is no recorded activity for this period yet."
        case .deviceAndManual: "No device or manual activity is recorded for this period. Try All history to compare other sources."
        case .importedJournal: "No imported journal entries are recorded for this period."
        case .confirmedLocations: "No confirmed or corrected locations are recorded for this period."
        }
    }

    /// HealthKit is a device source. Imported journals and the confirmed-location
    /// view should not quietly add separate Health-derived totals to their story.
    var includesHealthData: Bool {
        self == .allHistory || self == .deviceAndManual
    }

    func includes(_ visit: Visit) -> Bool {
        switch self {
        case .allHistory:
            return true
        case .deviceAndManual:
            return visit.source != "imported-journal"
        case .importedJournal:
            return visit.source == "imported-journal"
        case .confirmedLocations:
            return ActivityLocationPolicy.isLocationVisit(visit) && visit.resolutionState == .resolved
        }
    }

    func filtering(_ visits: [Visit]) -> [Visit] {
        visits.filter(includes)
    }
}

/// A compact source selector that stays in the existing Insights control strip.
/// The recorded-hour subtitle is derived from the already-filtered snapshot, so
/// opening the menu never performs another archive query.
struct InsightsScopeMenu: View {
    @Binding var rawValue: String
    let recordedHours: Double

    private var selectedScope: InsightsScope {
        InsightsScope(rawValue: rawValue) ?? .allHistory
    }

    var body: some View {
        Menu {
            ForEach(InsightsScope.allCases) { scope in
                Button {
                    rawValue = scope.rawValue
                } label: {
                    Label(scope.title, systemImage: scope == selectedScope ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedScope.title).font(.subheadline.weight(.semibold))
                    Text("\(formatHours(recordedHours)) recorded hours")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Insights data scope, \(selectedScope.title), \(formatHours(recordedHours)) recorded hours")
        .accessibilityHint("Choose which sources appear in Insights")
        .accessibilityIdentifier("insights-scope-picker")
    }
}
