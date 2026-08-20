import SwiftUI
import Charts

struct AnnualGroupChartData: Identifiable {
    let group: String
    /// The real groups folded into this displayed row. For a named row that is just
    /// `[group]`; for the synthetic "Other" row it is every group that missed the
    /// top-5 cut, which is why opening it filters by all of them rather than by the
    /// single label "Other".
    let foldedGroups: [String]
    let monthlyHours: [Double]
    let totalHours: Double

    var id: String { group }
}

enum AnnualGroupChartDataBuilder {
    /// Keeps the annual story legible: five meaningful groups get their own series
    /// and everything else is honest about its combined "Other" time.
    ///
    /// The groups come from the months themselves rather than a fixed list, so a
    /// group the person added shows up here without this needing to know about it —
    /// which is the whole reason a fixed vocabulary was worth removing.
    static func make(months: [AnnualInsights.Month]) -> [AnnualGroupChartData] {
        var totals: [String: Double] = [:]
        for month in months {
            for (group, hours) in month.hours { totals[group, default: 0] += hours }
        }
        let totalHours = totals.values.reduce(0, +)
        let meaningfulThreshold = totalHours > 0 ? max(1, totalHours * 0.01) : 0
        let other = ActivityCatalog.fallbackCategory
        // Ties are broken by name so the series order — and therefore the colours a
        // person sees — cannot shuffle between two identical renders.
        let named = totals.keys
            .filter { $0 != other && totals[$0, default: 0] >= meaningfulThreshold }
            .sorted {
                let left = totals[$0, default: 0], right = totals[$1, default: 0]
                return left == right ? $0 < $1 : left > right
            }
        let displayed = Array(named.prefix(5))
        let displayedNames = Set(displayed)
        let foldedIntoOther = totals.keys.filter { !displayedNames.contains($0) }.sorted()
        let otherMonthlyHours = months.map { month in
            month.hours.reduce(0) { partial, entry in
                displayedNames.contains(entry.key) ? partial : partial + entry.value
            }
        }
        let rows = displayed.map { group in
            AnnualGroupChartData(group: group, foldedGroups: [group],
                                 monthlyHours: months.map { $0.hours[group] ?? 0 },
                                 totalHours: totals[group, default: 0])
        }
        let otherTotal = otherMonthlyHours.reduce(0, +)
        guard otherTotal > 0 || rows.isEmpty else { return rows }
        return rows + [AnnualGroupChartData(group: other, foldedGroups: foldedIntoOther,
                                            monthlyHours: otherMonthlyHours,
                                            totalHours: otherTotal)]
    }
}

struct AnnualGroupsChart: View {
    let months: [AnnualInsights.Month]
    @Binding var selectedGroup: String?
    let openGroup: (AnnualGroupChartData) -> Void

    private var data: [AnnualGroupChartData] {
        AnnualGroupChartDataBuilder.make(months: months)
    }

    private var monthLabels: [String] {
        months.enumerated().compactMap { index, month in
            months.count <= 6 || index.isMultiple(of: 2) ? month.label : nil
        }
    }

    private var selectedData: AnnualGroupChartData? {
        guard let selectedGroup else { return nil }
        return data.first { $0.group == selectedGroup }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(months) { month in
                    ForEach(data) { row in
                        let monthIndex = months.firstIndex { $0.id == month.id } ?? 0
                        let hours = row.monthlyHours[monthIndex]
                        let barOpacity: Double = selectedGroup == nil || selectedGroup == row.group ? 1 : 0.24
                        BarMark(x: .value("Month", month.label), y: .value("Hours", hours))
                            .foregroundStyle(by: .value("Group", row.group))
                            .opacity(barOpacity)
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: monthLabels) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.caption2)
                                .minimumScaleFactor(0.75)
                                .fixedSize()
                        }
                    }
                }
            }
            .chartForegroundStyleScale(domain: data.map(\.group),
                                       range: data.map { insightColor(for: $0.group) })
            .frame(height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Annual groups chart")
            .accessibilityValue(accessibilityChartValue)
            .accessibilityIdentifier("annual-group-chart")

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(data) { row in
                    Button {
                        selectedGroup = selectedGroup == row.group ? nil : row.group
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(insightColor(for: row.group))
                                .frame(width: 10, height: 10)
                            Text(row.group)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                        }
                        .foregroundStyle(.primary)
                        .opacity(selectedGroup == nil || selectedGroup == row.group ? 1 : 0.48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.group), \(formatHours(row.totalHours))")
                    .accessibilityValue(selectedGroup == row.group ? "Selected. Double tap to clear selection." : "Double tap to select")
                    .accessibilityIdentifier("annual-group-\(row.id)")
                }
            }

            if let selectedData {
                Button { openGroup(selectedData) } label: {
                    HStack {
                        Label(selectedData.group, systemImage: insightSymbol(for: selectedData.group))
                        Spacer()
                        Text(formatHours(selectedData.totalHours))
                            .font(.subheadline.bold().monospacedDigit())
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel("Open \(selectedData.group) details, \(formatHours(selectedData.totalHours))")
                .accessibilityIdentifier("annual-selected-group")
            }
        }
    }

    private var accessibilityChartValue: String {
        if let selectedData {
            return "Selected \(selectedData.group), \(formatHours(selectedData.totalHours)). Available: " +
                data.map { "\($0.group), \(formatHours($0.totalHours))" }.joined(separator: ". ")
        }
        return data.map { "\($0.group), \(formatHours($0.totalHours))" }.joined(separator: ". ")
    }
}
