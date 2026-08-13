import SwiftUI

/// The shell passes prepared strings instead of the full Insights snapshot so
/// changing a chart selection does not also invalidate the period controls.
struct InsightsPeriodControls: View {
    let window: InsightWindow
    let periodTitle: String
    let periodSubtitle: String
    let scopeSubtitle: String
    let recordedHours: Double
    let emptyState: String?
    let isCurrentWindow: Bool
    @Binding var scopeRawValue: String
    @Binding var selectedWindow: InsightWindow
    let onMove: (Int) -> Void
    let onChooseDate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { onMove(-1) } label: {
                    Image(systemName: "chevron.left").font(.title3.bold())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Previous \(window.title.lowercased())")
                Spacer()
                Button(action: onChooseDate) {
                    VStack(spacing: 2) {
                        Text(periodTitle).font(.title3.bold()).foregroundStyle(.primary)
                        Text(periodSubtitle).font(.caption).foregroundStyle(.secondary)
                        Text(scopeSubtitle).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("insights-scope-summary")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(periodTitle), \(periodSubtitle), \(scopeSubtitle)")
                .accessibilityHint("Choose a different date")
                .accessibilityIdentifier("insights-period-picker")
                Spacer()
                Button { onMove(1) } label: {
                    Image(systemName: "chevron.right").font(.title3.bold())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isCurrentWindow)
                .accessibilityLabel("Next \(window.title.lowercased())")
            }
            InsightsScopeMenu(rawValue: $scopeRawValue, recordedHours: recordedHours)
            if let emptyState {
                Text(emptyState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("insights-scope-empty-state")
            }
            Picker("Time window", selection: $selectedWindow) {
                ForEach(InsightWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.top, 8)
    }

}
