import SwiftUI
import Charts

struct AnnualLifeAreasChart: View {
    let months: [AnnualInsights.Month]

    var body: some View {
        Chart {
            ForEach(months) { month in
                ForEach(AnnualInsights.areas) { area in
                    BarMark(x: .value("Month", month.label), y: .value("Hours", month.hours[area.name] ?? 0))
                        .foregroundStyle(insightColor(for: area.category))
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { AxisMarks(values: .stride(by: 2)) }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Twelve month stacked chart of time spent across Home, Work, Travel, Sleep/Rest, Social, Health/Fitness, Food and drink, Errands, and Other")
        .accessibilityHint("Use the annual sections below to inspect places, travel, and milestones")
    }
}
