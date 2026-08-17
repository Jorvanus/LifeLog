import SwiftUI
import SwiftData
import Charts

/// How `ActivitiesTabView` orders its rows within each section.
enum ActivitiesSortOrder: String, CaseIterable, Identifiable {
    case mostUsed, alphabetical

    var id: String { rawValue }
    var title: String { self == .mostUsed ? "Most used" : "A–Z" }
}

/// The activities screen: every label you use, with the shape of the last week beside
/// it, and a page of detail behind each one.
///
/// Insights answers "where did my time go" by group. This answers "what about this
/// one thing" — how often, how long, where, and whether it is going up or down.
struct ActivitiesTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Held rather than computed in `body`. As a computed property this was rebuilt on
    /// every render, and each rebuild walked the whole timeline once per activity.
    @State private var rows: [Row] = []
    @State private var searchText = ""
    @State private var showingUnused = false
    /// Persisted like other standing view preferences — set once, stays set. Most
    /// used first is the default: the point of this screen is "what about this
    /// thing," and that question is asked most about the things done most.
    @AppStorage("activities-tab-sort-order") private var sortRawValue = ActivitiesSortOrder.mostUsed.rawValue
    private var sortOrder: ActivitiesSortOrder { ActivitiesSortOrder(rawValue: sortRawValue) ?? .mostUsed }

    private func reload() async {
        let startedAt = Date.now
        let definitions = ActivityCatalog.load()
        var symbols: [String: String] = [:]
        for definition in definitions { symbols[definition.name.lowercased()] = definition.symbol }

        // Summaries, not full statistics: the list shows occasions, total time and
        // the week's shape. Everything else is computed when an activity is opened.
        let result: ActivitySummaryAggregator.Result
        do {
            result = try await ActivitySummaryAggregator(modelContainer: context.container)
                .load(names: definitions.map(\.name), now: .now)
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Activities",
                               operation: "activity statistics", severity: "warning")
            return
        }
        let summaries = result.summaries
        // `summaries` deliberately also returns labels found in the archive that the
        // catalogue has never heard of — most of a bulk-imported history is exactly
        // that, and a screen reporting where time went must not hide it. But such a row
        // cannot be renamed, grouped or given an icon until it is adopted, and until now
        // nothing here said so or offered to do it.
        let adopted = Set(definitions.map { NameKey.matching($0.name) })
        var built = summaries.map { entry in
            Row(name: entry.activity,
                symbol: symbols[entry.activity.lowercased()] ?? "circle.fill",
                statistics: entry,
                isAdopted: adopted.contains(NameKey.matching(entry.activity)))
        }
        built.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        rows = built
        // Archive-wide work is allowed here because it is isolated from the UI actor;
        // retain a realistic diagnostic budget so a future regression remains visible.
        Diagnostics.budget(context, subsystem: "Activities", operation: "background activity statistics",
                           startedAt: startedAt, budget: 1.0, itemCount: result.itemCount)
    }

    private struct Row: Identifiable {
        let name: String
        let symbol: String
        let statistics: ActivityStatistics.Summary
        /// In the catalogue, so it can be edited in Settings → Activity Labels. False
        /// means the label exists only in recorded visits.
        let isAdopted: Bool
        var id: String { name }
    }

    /// Adds a label the archive already uses to the catalogue, so it can be renamed,
    /// grouped and given an icon — and so Insights stops counting it under "Other".
    ///
    /// The same thing "Add from your history" does in bulk, offered on the row where
    /// the person is already looking at the label and can see how much of their time
    /// it accounts for.
    private func adopt(_ row: Row) {
        guard ActivityCatalog.adoptFromHistory(row.name) else { return }
        // Grouping is computed rather than stored, so adopting a label re-buckets every
        // visit already carrying it. Insights has to be told.
        InsightsInvalidation.invalidate(reason: "Activity adopted from history", context: context)
        Task { await reload() }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recentRows.isEmpty {
                    Section {
                        ForEach(recentRows) { activityRow($0) }
                    } header: {
                        Text("Recently used")
                    }
                }
                if !historyRows.isEmpty {
                    Section {
                        ForEach(historyRows) { activityRow($0) }
                    } header: {
                        Text("From your history")
                    } footer: {
                        Text("These labels came from recorded visits but are not activities yet. Tap one to review its history, or swipe right to add it to Activities.")
                    }
                }
                if !unusedRows.isEmpty {
                    Section {
                        Button { showingUnused.toggle() } label: {
                            HStack {
                                Label("Not used yet", systemImage: showingUnused ? "chevron.down" : "chevron.right")
                                Spacer()
                                Text("\(unusedRows.count)").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("unused-activities-toggle")
                        if showingUnused || !searchText.isEmpty {
                            ForEach(unusedRows) { activityRow($0) }
                        }
                    } footer: {
                        Text("These labels are ready for future visits. They stay collapsed until you need one.")
                    }
                }
            }
            .navigationTitle("Activities")
            .accessibilityIdentifier("activities-tab-screen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Same checkmark-list Menu shape as `InsightsScopeMenu`, so a
                    // sort control reads the same way wherever it appears.
                    Menu {
                        ForEach(ActivitiesSortOrder.allCases) { order in
                            Button {
                                sortRawValue = order.rawValue
                            } label: {
                                Label(order.title, systemImage: order == sortOrder ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort activities, \(sortOrder.title)")
                    .accessibilityHint("Choose how the list is ordered")
                    .accessibilityIdentifier("activities-sort-menu")
                }
            }
            .searchable(text: $searchText, prompt: "Search activities")
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                Task { await reload() }
            }
        }
    }

    private func activityRow(_ row: Row) -> some View {
        NavigationLink {
            ActivityDetailView(activityName: row.name, symbol: row.symbol)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                activityIcon(for: row)
                activityDescription(for: row)
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 0 : 8)
                // A tiny chart cannot retain useful geometry beside text several lines
                // tall. The detail page still carries the full history, so accessibility
                // sizes give the words the complete row instead of crushing fragments.
                if !dynamicTypeSize.isAccessibilitySize {
                    WeekSparkline(days: row.statistics.recentDays,
                                  color: activityColor(row.name))
                        .frame(width: 78, height: 30)
                }
            }
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !row.isAdopted {
                Button { adopt(row) } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }.tint(.orange)
            }
        }
        .accessibilityIdentifier(row.isAdopted ? "activity-row" : "unadopted-activity-row")
    }

    private func filtered(_ source: [Row]) -> [Row] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// "Most used" ranks by occasions first — the number the row itself leads
    /// with — falling back to total time and then name so the order is never
    /// arbitrary for two activities used equally often.
    private func sorted(_ source: [Row]) -> [Row] {
        switch sortOrder {
        case .alphabetical:
            return source.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .mostUsed:
            return source.sorted { lhs, rhs in
                if lhs.statistics.occasions != rhs.statistics.occasions {
                    return lhs.statistics.occasions > rhs.statistics.occasions
                }
                if lhs.statistics.totalTime != rhs.statistics.totalTime {
                    return lhs.statistics.totalTime > rhs.statistics.totalTime
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var recentRows: [Row] {
        sorted(filtered(rows.filter { $0.isAdopted && !$0.statistics.isEmpty }))
    }

    private var historyRows: [Row] {
        sorted(filtered(rows.filter { !$0.isAdopted && !$0.statistics.isEmpty }))
    }

    private var unusedRows: [Row] {
        // Every row here is unused by definition (`occasions == 0`), so "most
        // used" ties on the same fallback A-Z order either way.
        sorted(filtered(rows.filter { $0.isAdopted && $0.statistics.isEmpty }))
    }

    private func activityIcon(for row: Row) -> some View {
        Image(systemName: row.symbol)
            .font(.title3)
            .foregroundStyle(activityColor(row.name))
            // The row is the control, but a stable icon column prevents its text from
            // being squeezed by a symbol that grows independently with Dynamic Type.
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 30,
                   height: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
    }

    private func activityDescription(for row: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name).font(.headline)
            Text(subtitle(for: row.statistics))
                .font(.caption).foregroundStyle(.secondary)
            if !row.isAdopted {
                // Says why this row behaves differently from the one above it, rather
                // than leaving the person to discover it in Settings.
                Label("From your history · not yet an activity",
                      systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(for statistics: ActivityStatistics.Summary) -> String {
        guard !statistics.isEmpty else { return "Not used yet" }
        let occasions = "\(statistics.occasions) \(statistics.occasions == 1 ? "occasion" : "occasions")"
        return "\(occasions) · \(formattedDuration(statistics.totalTime))"
    }
}

/// Seven days at a glance. Deliberately unlabelled: it shows the shape of a week, and
/// the numbers behind it are one tap away.
private struct WeekSparkline: View {
    let days: [ActivityStatistics.DayTotal]
    let color: Color

    var body: some View {
        if days.allSatisfy({ $0.hours == 0 }) {
            // A flat line rather than an empty frame, so an unused activity still
            // reads as "nothing this week" instead of looking like a rendering fault.
            Rectangle().fill(color.opacity(0.25)).frame(height: 1.5)
        } else {
            Chart(days) { day in
                AreaMark(x: .value("Day", day.day), y: .value("Hours", day.hours))
                    .foregroundStyle(color.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day.day), y: .value("Hours", day.hours))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        }
    }
}
