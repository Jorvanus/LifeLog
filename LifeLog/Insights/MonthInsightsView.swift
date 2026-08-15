import SwiftUI

private enum MonthlyPlaceSection: String, CaseIterable, Identifiable {
    case mostTime = "Most time"
    case mostVisits = "Most visits"
    case new = "New"
    case changed = "Changed"

    var id: String { rawValue }
}

struct MonthlyHeroMetric: Identifiable {
    let id: String
    let icon: String
    let title: String
    let value: String
    let detail: String
    var action: (() -> Void)?
}

/// Month answers "what changed in my life this month?" rather than presenting
/// the same long-term sections as Year. These cards all read the same
/// resolved current/previous segments as the donut.
struct MonthInsightsView: View {
    let insights: MonthlyInsights
    let comparisonSubtitle: String
    let heroMetrics: [MonthlyHeroMetric]
    let monthDays: [MonthlyInsights.Day]
    let periodTitle: String
    let analysisInterval: DateInterval
    let segments: [InsightSegment]
    let now: Date
    let onOpenCategory: (String) -> Void
    let onOpenComparison: (MonthlyInsights.ActivityChange) -> Void
    let onSelectDay: (Date) -> Void

    var body: some View {
        heroSection
        changesSection
        balanceSection
        placesSection
        calendarSection
    }

    @ViewBuilder private var heroSection: some View {
        if let headline = insights.headline, !heroMetrics.isEmpty {
            MonthlyHeroCard(headline: headline, subtitle: comparisonSubtitle, metrics: heroMetrics)
        } else if !heroMetrics.isEmpty {
            MonthlyHeroCard(headline: "A month in review", subtitle: comparisonSubtitle, metrics: heroMetrics)
        }
    }

    @ViewBuilder private var changesSection: some View {
        if !insights.changes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("What changed").font(.headline)
                ForEach(insights.changes.prefix(4)) { change in
                    Button { onOpenComparison(change) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: insightSymbol(for: change.category))
                                .foregroundStyle(insightColor(for: change.category))
                                .frame(width: 36, height: 36)
                                .background(insightColor(for: change.category).opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.category).font(.subheadline.weight(.medium))
                                Text(change.delta >= 0 ? "More time" : "Less time")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: change.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatHours(abs(change.delta)))
                                    .font(.subheadline.bold().monospacedDigit())
                                if let percentage = change.percentage {
                                    Text(Self.percentageText(percentage))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                } else {
                                    Text("New").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(change.category), \(change.delta >= 0 ? "more" : "less") \(formatHours(abs(change.delta))) than last month")
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-month-changes")
        }
    }

    private static func percentageText(_ percentage: Double) -> String {
        "\(Int((abs(percentage) * 100).rounded()))%"
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monthly balance").font(.headline)
            Text("Recorded time by group").font(.subheadline).foregroundStyle(.secondary)
            if insights.balance.isEmpty {
                InsightEmptyRow(icon: "chart.bar.xaxis", title: "Not enough recorded activity", detail: "These groups appear once the month has usable data.")
            } else {
                MonthlyBalanceVisual(items: insights.balance, onSelect: onOpenCategory)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-balance")
    }

    private var placesSection: some View {
        MonthlyPlaceStorySection(story: insights, periodTitle: periodTitle,
                                 interval: analysisInterval, segments: segments, now: now)
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-month-places")
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Month at a glance").font(.headline)
            MonthCalendarHeatmap(days: monthDays, onSelect: onSelectDay)
            MonthCalendarLegend()
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-calendar")
    }
}

private struct MonthCalendarLegend: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            legendItem(color: .secondary.opacity(0.12), title: "No data", swatchOpacity: 1)
            legendItem(color: insightColor(for: "Home"), title: "Mostly Home", swatchOpacity: 0.7)
            legendItem(color: insightColor(for: "Work"), title: "Activity", swatchOpacity: 0.7)
            legendItem(color: insightColor(for: "Travel"), title: "Away from Home", swatchOpacity: 0.7)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calendar colours: no data, mostly Home, activity, and away from Home")
        .accessibilityIdentifier("month-calendar-legend")
    }

    private func legendItem(color: Color, title: String, swatchOpacity: Double) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(swatchOpacity))
                .frame(width: 12, height: 12)
            Text(title)
        }
    }
}

private struct MonthlyHeroCard: View {
    let headline: String
    let subtitle: String
    let metrics: [MonthlyHeroMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This month").font(.title2.bold())
            Text(headline)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(metrics) { metric in
                    metricTile(metric)
                }
            }
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insights-month-hero")
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func metricTile(_ metric: MonthlyHeroMetric) -> some View {
        if let action = metric.action {
            Button(action: action) { tileContent(metric) }
                .buttonStyle(.plain)
        } else {
            tileContent(metric)
        }
    }

    private func tileContent(_ metric: MonthlyHeroMetric) -> some View {
        let detailColor: Color = metric.detail == "This month" ? .secondary : .blue
        return VStack(alignment: .leading, spacing: 6) {
            Label(metric.title, systemImage: metric.icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(metric.value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(metric.detail)
                .font(.caption)
                .foregroundStyle(detailColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title): \(metric.value), \(metric.detail)")
    }
}

private struct MonthlyBalanceVisual: View {
    let items: [MonthlyInsights.Balance]
    let onSelect: (String) -> Void
    @State private var selectedName: String?

    private var totalHours: Double {
        items.reduce(0) { $0 + $1.hours }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.color.opacity(selectedName == nil || selectedName == item.name ? 1 : 0.28))
                            .frame(width: max(2, proxy.size.width * item.hours / max(totalHours, 0.01)))
                            .overlay {
                                if selectedName == item.name {
                                    RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 1.5)
                                }
                            }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 18)
            .accessibilityElement()
            .accessibilityLabel("Monthly balance")
            .accessibilityValue(items.map { "\($0.name), \(formatHours($0.hours))" }.joined(separator: ". "))

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(items) { item in
                    Button { selectedName = selectedName == item.name ? nil : item.name } label: {
                        HStack(spacing: 7) {
                            Circle().fill(item.color).frame(width: 9, height: 9)
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                            Text(formatHours(item.hours))
                                .font(.caption.bold().monospacedDigit())
                        }
                        .foregroundStyle(.primary)
                        .opacity(selectedName == nil || selectedName == item.name ? 1 : 0.42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.name), \(formatHours(item.hours))")
                    .accessibilityValue(selectedName == item.name ? "Selected. Double tap to clear selection." : "Double tap to select")
                }
            }

            if let selectedName, let selected = items.first(where: { $0.name == selectedName }) {
                Button { onSelect(selected.name) } label: {
                    HStack {
                        Label(selected.name, systemImage: insightSymbol(for: selected.name))
                        Spacer()
                        Text(formatHours(selected.hours)).font(.subheadline.bold().monospacedDigit())
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel("Open \(selected.name) details, \(formatHours(selected.hours))")
                .accessibilityIdentifier("month-selected-balance")
            }
        }
    }
}

private struct MonthlyPlaceStorySection: View {
    let story: MonthlyInsights
    @State private var selection: MonthlyPlaceSection = .mostTime
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]
    let now: Date

    private var selectedPlaces: [MonthlyInsights.PlaceStory] {
        switch selection {
        case .mostTime: return story.placesByTime
        case .mostVisits: return story.placesByVisits
        case .new: return story.newPlaces
        case .changed: return story.biggestPlaceChange.map { [$0] } ?? []
        }
    }

    private var selectedEmptyMessage: String {
        switch selection {
        case .mostTime: return "No places recorded in this period."
        case .mostVisits: return "No visits recorded in this period."
        case .new: return "No new places with enough recorded history."
        case .changed: return "No meaningful place change to show yet."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Place story").font(.headline)
            Picker("Place story", selection: $selection) {
                ForEach(MonthlyPlaceSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("month-place-story-picker")

            if selectedPlaces.isEmpty {
                Text(selectedEmptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(selectedPlaces.prefix(5)) { place in
                    MonthlyPlaceStoryRow(place: place, detail: detail(for: place), periodTitle: periodTitle,
                                         interval: interval, segments: segments, now: now)
                }
            }

            if story.allPlaces.count > 5 {
                NavigationLink {
                    MonthlyPlaceStoryList(places: story.allPlaces, periodTitle: periodTitle,
                                          interval: interval, segments: segments, now: now)
                } label: {
                    Label("See all places", systemImage: "list.bullet")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("month-see-all-places")
            }
        }
    }

    private func detail(for place: MonthlyInsights.PlaceStory) -> String {
        switch selection {
        case .mostTime: return formatHours(place.hours)
        case .mostVisits: return "\(place.visits) \(place.visits == 1 ? "visit" : "visits")"
        case .new: return formatHours(place.hours)
        case .changed:
            return "\(place.delta >= 0 ? "+" : "−")\(formatHours(abs(place.delta))) vs last month"
        }
    }
}

private struct MonthlyPlaceStoryList: View {
    let places: [MonthlyInsights.PlaceStory]
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]
    let now: Date

    var body: some View {
        List {
            Section("All places in this period") {
                ForEach(places) { place in
                    MonthlyPlaceStoryRow(place: place, detail: "\(formatHours(place.hours)) · \(place.visits) \(place.visits == 1 ? "visit" : "visits")",
                                          periodTitle: periodTitle, interval: interval, segments: segments, now: now)
                }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("month-all-places")
    }
}

private struct MonthlyPlaceStoryRow: View {
    let place: MonthlyInsights.PlaceStory
    let detail: String
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]
    let now: Date

    var body: some View {
        NavigationLink {
            InsightPlaceHistoryView(placeName: place.name, periodTitle: periodTitle, interval: interval,
                                    rows: InsightsSnapshot.sliceRows(forPlace: place.name, segments: segments,
                                                                      interval: interval, now: now))
        } label: {
            HStack(spacing: 10) {
                ActivityIcon(activity: place.activity, context: place.name,
                             color: insightColor(for: place.category), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(place.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(detail).font(.caption.bold().monospacedDigit()).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(place.name), \(detail)")
        .accessibilityIdentifier("month-place-\(place.id)")
    }
}
