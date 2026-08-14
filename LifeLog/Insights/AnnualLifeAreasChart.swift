import SwiftUI
import Charts

struct AnnualLifeAreaChartData: Identifiable {
    let area: AnnualInsights.LifeArea
    /// The real life areas folded into this displayed row. For a named row this
    /// is just `[area]`; for the synthetic "Other" row it is every area that
    /// didn't make the top-5 cut, which is why opening it must filter by all of
    /// these rather than by the literal `.other` case alone.
    let foldedAreas: [AnnualInsights.LifeArea]
    let monthlyHours: [Double]
    let totalHours: Double

    var id: String { area.id }
}

enum AnnualLifeAreaChartDataBuilder {
    /// Keeps the annual story legible: five meaningful areas get their own
    /// series and everything else is honest about its combined "Other" time.
    static func make(months: [AnnualInsights.Month]) -> [AnnualLifeAreaChartData] {
        let totals = Dictionary(uniqueKeysWithValues: AnnualInsights.areas.map { area in
            (area.name, months.reduce(0) { $0 + ($1.hours[area.name] ?? 0) })
        })
        let totalHours = totals.values.reduce(0, +)
        let meaningfulThreshold = totalHours > 0 ? max(1, totalHours * 0.01) : 0
        let other = AnnualInsights.areas.last!
        let namedAreas = AnnualInsights.areas.dropLast()
            .filter { totals[$0.name, default: 0] >= meaningfulThreshold }
            .sorted { totals[$0.name, default: 0] > totals[$1.name, default: 0] }
        let displayed = Array(namedAreas.prefix(5))
        let displayedNames = Set(displayed.map(\.name))
        let foldedIntoOther = AnnualInsights.areas.filter { !displayedNames.contains($0.name) }
        let otherMonthlyHours = months.map { month in
            month.hours.reduce(0) { partial, entry in
                displayedNames.contains(entry.key) ? partial : partial + entry.value
            }
        }
        let rows = displayed.map { area in
            AnnualLifeAreaChartData(area: area, foldedAreas: [area],
                                    monthlyHours: months.map { $0.hours[area.name] ?? 0 },
                                    totalHours: totals[area.name, default: 0])
        }
        let otherTotal = otherMonthlyHours.reduce(0, +)
        return rows + [AnnualLifeAreaChartData(area: other, foldedAreas: foldedIntoOther,
                                               monthlyHours: otherMonthlyHours,
                                               totalHours: otherTotal)]
    }
}

struct AnnualLifeAreasChart: View {
    let months: [AnnualInsights.Month]
    @Binding var selectedArea: AnnualInsights.LifeArea?
    let openArea: (AnnualLifeAreaChartData) -> Void

    private var data: [AnnualLifeAreaChartData] {
        AnnualLifeAreaChartDataBuilder.make(months: months)
    }

    private var monthLabels: [String] {
        months.enumerated().compactMap { index, month in
            months.count <= 6 || index.isMultiple(of: 2) ? month.label : nil
        }
    }

    private var selectedData: AnnualLifeAreaChartData? {
        guard let selectedArea else { return nil }
        return data.first { $0.area == selectedArea }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(months) { month in
                    ForEach(data) { row in
                        let monthIndex = months.firstIndex { $0.id == month.id } ?? 0
                        BarMark(x: .value("Month", month.label),
                                y: .value("Hours", row.monthlyHours[monthIndex]))
                            .foregroundStyle(by: .value("Life area", row.area.name))
                            .opacity(selectedArea == nil || selectedArea == row.area ? 1 : 0.24)
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
            .chartForegroundStyleScale(domain: data.map { $0.area.name },
                                       range: data.map { insightColor(for: $0.area.category) })
            .frame(height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Annual life-area chart")
            .accessibilityValue(accessibilityChartValue)
            .accessibilityIdentifier("annual-life-area-chart")

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(data) { row in
                    Button {
                        selectedArea = selectedArea == row.area ? nil : row.area
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(insightColor(for: row.area.category))
                                .frame(width: 10, height: 10)
                            Text(row.area.name)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                        }
                        .foregroundStyle(.primary)
                        .opacity(selectedArea == nil || selectedArea == row.area ? 1 : 0.48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.area.name), \(formatHours(row.totalHours))")
                    .accessibilityValue(selectedArea == row.area ? "Selected. Double tap to clear selection." : "Double tap to select")
                    .accessibilityIdentifier("annual-life-area-\(row.area.id)")
                }
            }

            if let selectedData {
                Button { openArea(selectedData) } label: {
                    HStack {
                        Label(selectedData.area.name, systemImage: insightSymbol(for: selectedData.area.category))
                        Spacer()
                        Text(formatHours(selectedData.totalHours))
                            .font(.subheadline.bold().monospacedDigit())
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel("Open \(selectedData.area.name) details, \(formatHours(selectedData.totalHours))")
                .accessibilityIdentifier("annual-selected-life-area")
            }
        }
    }

    private var accessibilityChartValue: String {
        if let selectedData {
            return "Selected \(selectedData.area.name), \(formatHours(selectedData.totalHours)). Available: " +
                data.map { "\($0.area.name), \(formatHours($0.totalHours))" }.joined(separator: ". ")
        }
        return data.map { "\($0.area.name), \(formatHours($0.totalHours))" }.joined(separator: ". ")
    }
}
