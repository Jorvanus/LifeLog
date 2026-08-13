import SwiftUI

/// Immutable values rendered by the daily review. Keeping these independent of
/// SwiftData means a Health refresh only changes the metric card that reads it.
struct DayInsightMetricPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let icon: String
    let title: String
    let value: String
}

struct DayCurrentActivityPresentation: Equatable, Sendable {
    let placeName: String
    let activity: String
    let startedAt: Date
    let elapsed: String
    let needsChecking: Bool
}

enum DayAttentionTarget: Hashable, Sendable {
    case visit(UUID)
    case gap(DateInterval)
}

struct DayAttentionPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let target: DayAttentionTarget
}

struct DayInsightsView: View {
    let currentActivity: DayCurrentActivityPresentation?
    let timelineSegments: [InsightSegment]
    let interval: DateInterval
    let now: Date
    let metrics: [DayInsightMetricPresentation]
    let attentionItems: [DayAttentionPresentation]
    let highlight: DayHighlight?
    let travel: TravelInsights.Summary
    let onOpenCurrentActivity: () -> Void
    let onOpenTimelineSegment: (InsightSegment) -> Void
    let onMetric: (String) -> Void
    let onAttention: (DayAttentionTarget) -> Void

    var body: some View {
        CurrentActivitySection(activity: currentActivity, onOpen: onOpenCurrentActivity)
        DayTimelineSection(segments: timelineSegments, interval: interval, now: now,
                           onOpen: onOpenTimelineSegment)
        DaySummarySection(metrics: metrics, onOpenMetric: onMetric)
        NeedsAttentionSection(items: attentionItems, onOpen: onAttention)
        DayHighlightSection(highlight: highlight)
        if travel.hasTravel {
            TravelInsightsCard(title: "Travel", summary: travel, period: interval)
        }
    }
}

private struct CurrentActivitySection: View {
    let activity: DayCurrentActivityPresentation?
    let onOpen: () -> Void

    var body: some View {
        if let activity {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(activity.placeName).font(.headline).lineLimit(1)
                            if activity.needsChecking {
                                Label("Needs checking", systemImage: "questionmark.circle.fill")
                                    .font(.caption2.bold()).foregroundStyle(.orange)
                                    .labelStyle(.iconOnly)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(activity.activity).font(.subheadline).foregroundStyle(.secondary)
                        Text("Since \(activity.startedAt.formatted(date: .omitted, time: .shortened)) · \(activity.elapsed)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding(20)
                .lifeCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insights-current-activity-card")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current activity: \(activity.placeName), \(activity.activity), since \(activity.startedAt.formatted(date: .omitted, time: .shortened)), \(activity.elapsed)\(activity.needsChecking ? ", needs checking" : "")")
            .accessibilityHint("Opens the editor for this visit")
        }
    }
}

private struct DayTimelineSection: View {
    let segments: [InsightSegment]
    let interval: DateInterval
    let now: Date
    let onOpen: (InsightSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your day").font(.title2.bold())
            DayTimelineBar(segments: segments, interval: interval, now: now, onSelect: onOpen)
            let pastUnloggedHours = segments.filter { $0.isUnlogged && $0.end <= now }
                .reduce(0) { $0 + $1.hours }
            if pastUnloggedHours > 0.25 {
                Text("\(formatHours(pastUnloggedHours)) of today so far is not logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-day-bar")
    }
}

private struct DaySummarySection: View {
    let metrics: [DayInsightMetricPresentation]
    let onOpenMetric: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today at a glance").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(metrics) { metric in
                    DayInsightMetricTile(icon: metric.icon, title: metric.title, value: metric.value,
                                         identifier: metric.id) {
                        onOpenMetric(metric.id)
                    }
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-day-summary")
    }
}

private struct NeedsAttentionSection: View {
    let items: [DayAttentionPresentation]
    let onOpen: (DayAttentionTarget) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Needs your attention").font(.headline)
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        Button { onOpen(item.target) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityHint(item.accessibilityHint)
                    }
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-needs-attention")
        }
    }
}

private struct DayHighlightSection: View {
    let highlight: DayHighlight?

    var body: some View {
        if let highlight {
            VStack(alignment: .leading, spacing: 12) {
                Text("One thing from today").font(.headline)
                HStack(spacing: 12) {
                    Image(systemName: highlight.symbol)
                        .font(.headline)
                        .foregroundStyle(highlight.isCelebration ? .orange : .blue)
                        .frame(width: 40, height: 40)
                        .background((highlight.isCelebration ? Color.orange : Color.blue).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlight.headline).font(.subheadline.bold())
                        Text(highlight.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("day-highlights")
            .accessibilityElement(children: .contain)
        }
    }
}
