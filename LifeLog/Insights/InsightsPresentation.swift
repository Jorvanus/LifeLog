import SwiftUI

/// Turning an activity or group into the colour, symbol and wording Insights shows.
func formatHours(_ hours: Double) -> String {
    let minutes = max(0, Int((hours * 60).rounded()))
    return formatDurationMinutes(minutes)
}

/// A compact human-scale duration used across Insights, Timeline, Places, and
/// Activities. Hours stop being useful once a total spans multiple days: "59d 19h"
/// is easier to understand than "1435h 43m", while short reviews retain their minutes.
func formatDurationMinutes(_ minutes: Int) -> String {
    let minutes = max(0, minutes)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 {
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
    let days = hours / 24
    let remainder = hours % 24
    return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
}

func formatSteps(_ count: Double) -> String {
    Int(max(0, count).rounded()).formatted(.number)
}

func insightColor(for value: String) -> Color {
    let text = value.lowercased()
    if !text.contains("unlogged") && !text.contains("uncategor") { return categoryColor(forCategory: value) }
    if text.contains("uncategor") { return .orange }
    if text.contains("home") { return .cyan }
    if text.contains("work") { return Color(red: 0.22, green: 0.40, blue: 0.52) }
    if text.contains("food") || text.contains("eat") || text.contains("beer") { return .orange }
    if text.contains("fitness") || text.contains("exercise") { return .pink }
    if text.contains("walk") || text.contains("run") { return .teal }
    if text.contains("cycl") { return .blue }
    if text.contains("sleep") { return Color(red: 0.22, green: 0.40, blue: 0.52) }
    if text.contains("shopping") { return .purple }
    if text.contains("travel") { return .blue }
    if text.contains("health") { return .red }
    if text.contains("social") { return .indigo }
    return .teal
}

func insightSymbol(for value: String) -> String {
    let text = value.lowercased()
    if text.contains("uncategor") { return "flag.fill" }
    if text.contains("commut") { return "car.fill" }
    if text.contains("home") { return "house.fill" }
    if text.contains("work") { return "building.2.fill" }
    if text.contains("food") || text.contains("eat") { return "fork.knife" }
    if text.contains("beer") { return "mug.fill" }
    if text.contains("fitness") || text.contains("exercise") { return "figure.run" }
    if text.contains("walk") { return "figure.walk" }
    if text.contains("run") { return "figure.run" }
    if text.contains("cycl") { return "bicycle" }
    if text.contains("sleep") { return "bed.double.fill" }
    if text.contains("shopping") { return "bag.fill" }
    if text.contains("travel") { return "car.fill" }
    if text.contains("health") { return "cross.case.fill" }
    return "mappin.circle.fill"
}
