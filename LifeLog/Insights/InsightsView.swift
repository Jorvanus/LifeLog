import SwiftUI
import SwiftData
import Charts
import MapKit
import UIKit

struct InsightsView: View {
    @Environment(\.modelContext) private var context
    let activityData: ActivityDataService
    /// The saved place called Home, which is what "time away from Home" is measured
    /// against. Queried rather than matched by name — see `InsightsSnapshot.HomePlace`.
    @Query private var savedPlaces: [SavedPlace]
    @State private var visits: [Visit] = []
    @State private var window: InsightWindow = .day
    @State private var anchorDate = Date.now
    @State private var choosingDate = false
    @State private var selectedSlice: TimeSlice?
    @State private var selectedPlace: PlaceTotal?
    @State private var now = Date.now
    @State private var snapshot = InsightsSnapshot.empty
    @State private var exportFile: TrendExportFile?
    @State private var aggregationGeneration = 0
    @State private var snapshotCache = InsightsSnapshotCache()
    @State private var showAllActivities = false
    @State private var showingWeekdayChart = false
    @State private var highlights: [DayHighlight] = []
    @State private var highlightPage = 0
    @State private var highlightHeight: CGFloat = 52
    @State private var trendSeries: [InsightsTrendSeries] = []
    @State private var habits: [InsightsHabit] = []
    @State private var weeklyRhythm = WeekdayPattern.empty

    private var interval: DateInterval { window.interval(containing: anchorDate) }
    private var sleepRefreshKey: String {
        "\(window.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
    }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.lifeBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 22) {
                        controls
                        highlightsSection
                        healthSetupSection
                        donutSection
                        if window == .day { dailyTimelineSection }
                        awayFromHomeSection
                        activityChangesSection
                        trendsSection
                        weekdayPatternsSection
                        habitsSection
                        trendLinesSection
                        topActivitiesSection
                        placesSection
                        topPlacesSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .accessibilityIdentifier("insights-screen")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosingDate) {
                NavigationStack {
                    DatePicker("Choose date", selection: $anchorDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle("Choose Date")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingDate = false } } }
                }.presentationDetents([.medium])
            }
            .sheet(isPresented: $showingWeekdayChart) { weekdayChartSheet }
            .sheet(item: $selectedSlice, onDismiss: reloadInsights) { slice in
                let entries = visits(for: slice)
                if entries.count == 1, let visit = entries.first {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    InsightSliceEditor(slice: slice, visits: entries, interval: snapshot.analysisInterval)
                        .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $selectedPlace, onDismiss: reloadInsights) { place in
                let entries = visits(for: place)
                if entries.count == 1, let visit = entries.first {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    // Reuse the category slice editor for a single place: it already
                    // handles "one visit -> edit directly" vs "many visits -> pick one".
                    InsightSliceEditor(
                        slice: TimeSlice(name: place.name, hours: place.hours,
                                         color: activityColor(place.activity),
                                         symbol: insightSymbol(for: place.category), isUnlogged: false),
                        visits: entries,
                        interval: snapshot.analysisInterval
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $exportFile) { file in
                NavigationStack {
                    VStack(spacing: 18) {
                        Image(systemName: "doc.badge.arrow.up").font(.largeTitle).foregroundStyle(.blue)
                        Text("Your \(file.format) export is ready").font(.headline)
                        ShareLink(item: file.url) { Label("Share \(file.format) file", systemImage: "square.and.arrow.up") }
                    }
                    .padding()
                    .navigationTitle("Export Trends")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
            .task {
                aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration()
                reloadInsights()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    now = .now
                    aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration()
                    reloadInsights()
                }
            }
            .task(id: sleepRefreshKey) {
                let queryEnd = interval.contains(now) ? now : interval.end
                let queryInterval = DateInterval(start: interval.start, end: queryEnd)
                _ = await activityData.refreshSleep(for: queryInterval, context: context)
                guard !Task.isCancelled else { return }
                aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration()
                reloadInsights()
            }
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                Task { aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration(); reloadInsights() }
            }
            .onChange(of: window) { _, _ in reloadInsights() }
            .onChange(of: anchorDate) { _, _ in reloadInsights() }
            .task(id: highlightKey) { await reloadHighlights() }
            .task(id: trendKey) { reloadTrends() }
        }
    }

    /// The trends only move when the week does, so stepping through days inside one
    /// week never re-reads a season of history.
    private var trendKey: Double {
        InsightsTrends.range(endingAt: now).start.timeIntervalSinceReferenceDate
    }

    /// Rebuilds the highlights only when the day being looked at changes. Without an
    /// identity of its own this would re-query HealthKit on every snapshot rebuild,
    /// which happens once a minute while the screen is open.
    private var highlightKey: String {
        let leadingPlace = snapshot.placeTotals.first
        return "\(window.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(snapshot.comparisons.count)-\(leadingPlace?.id ?? "none")-\(leadingPlace?.hours ?? 0)"
    }

    private func reloadHighlights() async {
        var found: [DayHighlight] = []
        let queryEnd = interval.contains(now) ? now : interval.end
        let dayInterval = DateInterval(start: interval.start, end: max(interval.start, queryEnd))

        if window == .day {
            if let steps = await activityData.stepCount(for: dayInterval) {
                let baseline = await activityData.stepHistory(
                    forSameWeekdayAs: interval.start,
                    through: interval.contains(now) ? now : nil,
                    weeks: 4
                )
                let weekday = interval.start.formatted(.dateTime.weekday(.wide))
                if let highlight = DayHighlights.steps(today: steps, weekdayBaseline: baseline,
                                                       weekdayName: weekday) {
                    found.append(highlight)
                }
            }
            if let night = await activityData.sleepSummary(for: dayInterval),
               let average = await activityData.averageNightlySleep(before: interval.start, nights: 14),
               let highlight = DayHighlights.sleep(lastNight: night.totalSleep, averageNight: average) {
                found.append(highlight)
            }
        }
        if let highlight = DayHighlights.activity(from: snapshot.comparisons, window: window) {
            found.append(highlight)
        }
        if let place = snapshot.placeTotals.first,
           let highlight = DayHighlights.leadingPlace(place, window: window) {
            found.append(highlight)
        }
        guard !Task.isCancelled else { return }
        highlights = variedHighlights(found)
        highlightPage = min(highlightPage, max(0, found.count - 1))
    }

    /// Keep the strongest comparison first, but rotate supporting cards by the
    /// selected period. This gives the carousel variety without it jumping around
    /// every time SwiftUI refreshes the screen.
    private func variedHighlights(_ candidates: [DayHighlight]) -> [DayHighlight] {
        guard candidates.count > 2, let primary = candidates.first else { return candidates }
        let supporting = Array(candidates.dropFirst())
        let periodNumber = Int(interval.start.timeIntervalSinceReferenceDate / (24 * 60 * 60))
        let offset = abs(periodNumber) % supporting.count
        let rotated = Array(supporting[offset...]) + Array(supporting[..<offset])
        return [primary] + rotated
    }

    /// The donut's centre is intentionally non-interactive and geometry-constrained.
    /// Health recovery therefore belongs in an ordinary card where its action remains
    /// obvious, tappable, and readable at larger text sizes.
    @ViewBuilder private var healthSetupSection: some View {
        if needsHealthSetup {
            VStack(alignment: .leading, spacing: 10) {
                Label("Apple Health", systemImage: "heart.text.square")
                    .font(.headline)
                Text("Connect Apple Health to add steps, sleep, and Apple Watch workouts to Insights.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !activityData.unaskedHealthTypes.isEmpty {
                    Button("Connect Apple Health") {
                        Task { await activityData.requestHealthAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connect-health-from-insights")
                } else {
                    Button("Open Apple Health") { openAppleHealth() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("open-health-from-insights")
                    Text("In Health, go to Sharing → Apps → LifeLog to review what LifeLog can read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .lifeCard()
            .accessibilityIdentifier("insights-health-setup")
        }
    }

    private var needsHealthSetup: Bool {
        activityData.healthStatus != "Connected" && activityData.healthStatus != "Unavailable on this device"
    }

    private func openAppleHealth() {
        guard let healthURL = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(healthURL)
    }

    /// Loads the season of history the trend lines are drawn from.
    ///
    /// A fetch of its own, deliberately separate from `reloadInsights`. That one is
    /// scoped tightly to the selected period and re-runs on every tap of the date
    /// arrows; this one reaches back twelve weeks and must not be dragged along with
    /// it. It is keyed to the week, so stepping through days never refetches.
    private func reloadTrends() {
        let span = InsightsTrends.range(endingAt: now)
        let start = span.start
        let end = span.end
        let startedAt = Date.now
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival < end && ($0.departure ?? end) >= start },
            sortBy: [SortDescriptor(\.arrival)]
        )
        let history: [Visit]
        do {
            history = try context.fetch(descriptor)
        } catch {
            // The rest of Insights is unaffected, so a trend that cannot be built is
            // simply not drawn rather than taken as a failure of the screen.
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "trend history fetch", severity: "warning")
            trendSeries = []
            habits = []
            weeklyRhythm = WeekdayPattern.empty
            return
        }
        // Resolved once; the lines and the habits are both read out of this.
        let weeks = InsightsTrends.weeklyTotals(visits: history, now: now)
        trendSeries = [
            InsightsTrends.series(for: "Home", title: "Home", symbol: "house.fill", weeks: weeks),
            InsightsTrends.series(for: "Sleep", title: "Sleep", symbol: "bed.double.fill", weeks: weeks)
        ].filter { !$0.isEmpty }
        habits = InsightsTrends.habits(from: weeks)
        weeklyRhythm = InsightsSnapshot.weekdayPatterns(visits: history, range: span, now: now)
        Diagnostics.performance(context, subsystem: "Insights", operation: "trend history",
                                startedAt: startedAt, itemCount: history.count)
    }

    /// The card the day opens with: what stood out, against the days like it.
    /// Hidden entirely when nothing can be said — an empty card that admits it has
    /// no comparison yet is worse than the screen simply starting at the ring.
    @ViewBuilder private var highlightsSection: some View {
        if !highlights.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $highlightPage) {
                    ForEach(Array(highlights.enumerated()), id: \.element.id) { index, highlight in
                        highlightRow(highlight)
                            .padding(.horizontal, 16)
                            .tag(index)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(highlight.headline). \(highlight.detail)")
                    }
                }
                // The built-in page dots are an overlay drawn over the content at the
                // bottom of the pager's frame, not a row beneath it — no amount of extra
                // height moves them out of the way, they just sit further down the same
                // text. Own dots, in their own row, are the only way they stop landing
                // on the sentence they are meant to be indexing.
                .tabViewStyle(.page(indexDisplayMode: .never))
                // A paged TabView has no intrinsic height at all — left alone it takes the
                // whole screen. So the rows are laid out once, unseen, at this card's width
                // and the tallest is measured; the pager is then told exactly what it needs.
                // A fixed number here would either clip the two-line message on a small
                // phone or leave a band of empty card on a large one.
                .frame(height: highlightHeight)
                .background(
                    ZStack {
                        ForEach(highlights) { highlight in
                            highlightRow(highlight).padding(.horizontal, 16)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: HighlightHeightKey.self, value: proxy.size.height)
                    })
                    .hidden()
                )
                .onPreferenceChange(HighlightHeightKey.self) { measured in
                    if measured > 0 { highlightHeight = measured }
                }

                if highlights.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(highlights.indices, id: \.self) { index in
                            Circle()
                                .fill(index == highlightPage ? Color.primary : Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                    // The pager already announces its position; a second reading of the
                    // same thing as seven unlabelled dots is noise.
                    .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .lifeCard()
            .accessibilityIdentifier("day-highlights")
        }
    }

    private func highlightRow(_ highlight: DayHighlight) -> some View {
        HStack(spacing: 12) {
            Image(systemName: highlight.symbol)
                .font(.headline)
                .foregroundStyle(highlight.isCelebration ? .orange : .blue)
                .frame(width: 40, height: 40)
                .background((highlight.isCelebration ? Color.orange : Color.blue)
                    .opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.headline).font(.subheadline.bold())
                Text(highlight.detail)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack {
                // A bare glyph only takes the tap area of the symbol itself, which
                // left these primary controls well under the 44pt minimum target.
                Button { move(-1) } label: {
                    Image(systemName: "chevron.left").font(.title3.bold())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Previous \(window.title.lowercased())")
                Spacer()
                Button { choosingDate = true } label: {
                    VStack(spacing: 2) {
                        Text(periodTitle).font(.title3.bold()).foregroundStyle(.primary)
                        Text(periodSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                // Without this the button tints its own label, and `.primary` and
                // `.secondary` are read as shades of the accent colour rather than of
                // the foreground. In dark mode that rendered the date as dark blue on
                // black — the least readable thing on the screen, and the one telling
                // you which day you are looking at.
                .buttonStyle(.plain)
                .accessibilityLabel("\(periodTitle), \(periodSubtitle)")
                .accessibilityHint("Choose a different date")
                .accessibilityIdentifier("insights-period-picker")
                Spacer()
                Button { move(1) } label: {
                    Image(systemName: "chevron.right").font(.title3.bold())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isCurrentWindow)
                .accessibilityLabel("Next \(window.title.lowercased())")
            }
            Picker("Time window", selection: $window) {
                ForEach(InsightWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.top, 8)
    }

    private var donutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How you spent your time").font(.title2.bold())
                    Text(isCurrentWindow
                         ? "\(formatHours(snapshot.totalHours)) elapsed in this \(window.title.lowercased())"
                         : "All \(formatHours(snapshot.totalHours)) in this \(window.title.lowercased())")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                // A card heading naming the card it is on. At the largest accessibility
                // sizes it and its subtitle took six lines and pushed the chart they
                // introduce off the bottom of a 6.9" screen, so the person had to scroll
                // past the label to reach the thing being labelled.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                Spacer()
                Menu {
                    Button("Export CSV") { exportFile = TrendExport.makeFile(format: "csv", visits: visits, interval: snapshot.analysisInterval, now: snapshot.generatedAt) }
                    Button("Export JSON") { exportFile = TrendExport.makeFile(format: "json", visits: visits, interval: snapshot.analysisInterval, now: snapshot.generatedAt) }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.title3.bold())
                }
                .accessibilityLabel("Export trends")
            }

            // Selection state lives inside this child so highlighting one sector does not
            // invalidate trends, place aggregation, or the Map below it.
            InsightsDonutChart(
                activityData: activityData,
                segments: snapshot.segments,
                loggedHours: snapshot.loggedHours,
                totalHours: snapshot.totalHours,
                analysisInterval: snapshot.analysisInterval,
                onSelectEntry: { selectedSlice = $0 }
            )

            // The legend grid that sat here is gone. Each wedge already carries its icon
            // and its hours, and tapping one names it in the middle of the ring and turns
            // that centre into a button onto the same visits the legend rows opened — so
            // nothing is unreachable, and the card is a chart rather than a chart plus a
            // list of what the chart just said.
            //
            // It is not free: a wedge too thin for a label is now an unidentified colour
            // until it is tapped, where before there was always a key underneath. The
            // threshold for showing an icon is set low to keep that rare.
        }
        .padding(18)
        .lifeCard()
    }

    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trends").font(.title2.bold())
            if snapshot.comparisons.isEmpty {
                InsightEmptyRow(icon: "chart.line.uptrend.xyaxis", title: "Not enough history yet",
                                detail: "Trends appear after LifeLog has visits in two comparable periods.")
            } else {
                ForEach(snapshot.comparisons.prefix(4)) { comparison in
                    HStack(spacing: 14) {
                        Image(systemName: comparison.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.headline).foregroundStyle(comparison.delta >= 0 ? .orange : .blue)
                            .frame(width: 42, height: 42)
                            .background((comparison.delta >= 0 ? Color.orange : Color.blue).opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comparison.message(window: window)).font(.headline)
                            Text("Compared with the previous \(window.title.lowercased())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(18)
        .lifeCard()
    }

    /// Space between blocks in the day bar. Named because the widths have to be
    /// divided over what is left *after* the gaps are taken out.
    private static let dayBarGap: CGFloat = 2

    /// The place the person themselves named Home. An exact name match rather than a
    /// contains, so "Homemaker Centre" is not mistaken for it.
    private var homePlace: SavedPlace? {
        savedPlaces.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Home") == .orderedSame }
    }

    private var dailyTimelineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your day").font(.title2.bold())
            Text("A 24-hour view of where your time went").font(.subheadline).foregroundStyle(.secondary)
            GeometryReader { proxy in
                // Each block used to take its share of the *full* width, and then the
                // HStack added a gap between every pair on top of that, so the bar
                // overran the card by two points per block — worse the more broken up
                // the day was. The gaps come out of the width first now.
                let segments = snapshot.segments
                let gaps = Self.dayBarGap * CGFloat(max(segments.count - 1, 0))
                let available = max(proxy.size.width - gaps, 1)
                HStack(spacing: Self.dayBarGap) {
                    ForEach(segments) { segment in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segment.color)
                            .frame(width: available * segment.hours / max(snapshot.totalHours, 0.01))
                            .accessibilityLabel("\(segment.activity), \(formatHours(segment.hours))")
                    }
                }
            }
            .frame(height: 34)
            HStack { Text("12am"); Spacer(); Text("6am"); Spacer(); Text("12pm"); Spacer(); Text("6pm"); Spacer(); Text("Now") }
                .font(.caption2).foregroundStyle(.secondary)
            // The grouped-by-activity bar that sat here is gone. It said the same thing
            // as the donut below — largest first, same colours — in a second shape, and
            // the donut says it better because it is labelled.
            if snapshot.unloggedHours > 0.25 {
                // The honest caveat on every number on this screen, kept where the day
                // is rather than filed under the app's own plumbing.
                Text("\(formatHours(snapshot.unloggedHours)) of the day is not logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).lifeCard()
    }

    private var awayFromHomeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time away from Home").font(.title2.bold())
            Text(formatHours(snapshot.awayFromHomeHours))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            ProgressView(value: snapshot.awayFromHomeHours, total: max(snapshot.loggedHours, 0.01)).tint(.blue)
            Text("\(Int((snapshot.awayFromHomeHours / max(snapshot.loggedHours, 0.01) * 100).rounded()))% of logged time")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(20).lifeCard()
    }

    /// The colour this activity wears everywhere else on the screen.
    ///
    /// Taken from the slice rather than recomputed, so the bar here cannot end up a
    /// different shade from the same activity in the donut above it. A name that only
    /// existed in the previous period has no slice, and falls back to its group.
    private func changeColor(for name: String) -> Color {
        snapshot.slices.first { $0.name == name }?.color
            ?? categoryColor(forCategory: ActivityCatalog.category(for: name))
    }

    private var activityChangesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity changes").font(.title2.bold())
            if snapshot.comparisons.isEmpty {
                InsightEmptyRow(icon: "chart.bar.xaxis", title: "Not enough history", detail: "Changes appear after two comparable periods.")
            } else {
                let maximum = max(snapshot.comparisons.map { abs($0.delta) }.max() ?? 0, 0.01)
                ForEach(snapshot.comparisons.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.name).font(.subheadline.bold())
                            Spacer()
                            // The sign carries the direction. These used to be orange
                            // for up and blue for down, which put a second colour
                            // language on a screen where colour already means activity
                            // — Home read as orange here and green in the bar above it.
                            Text("\(item.delta >= 0 ? "+" : "−")\(formatHours(abs(item.delta)))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        GeometryReader { proxy in
                            Capsule().fill(changeColor(for: item.name).opacity(0.85))
                                .frame(width: max(4, proxy.size.width * abs(item.delta) / maximum))
                        }.frame(height: 8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name), \(item.delta >= 0 ? "up" : "down") \(formatHours(abs(item.delta)))")
                }
            }
        }.padding(20).lifeCard()
    }

    // The "Timeline quality" card lived here. It reported the app's own plumbing —
    // callbacks reviewed, duplicates resolved — on a screen that answers where the
    // time went, and it rendered narrower than every other card because it was the
    // only one with nothing full-width inside it to stretch it. Those counts are in
    // Settings → Diagnostics now. The one line that was about the day rather than the
    // app, unlogged time, is a footnote under the day bar.

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Places").font(.title2.bold())
            Text(placeSummary).font(.headline)
            if snapshot.mappablePlaces.isEmpty {
                InsightEmptyRow(icon: "map", title: "No mapped visits", detail: "Places recorded with a location will appear here.")
            } else {
                InsightsPlacesMap(places: snapshot.mappablePlaces, region: snapshot.mapRegion)
                    .id(snapshot.mapID)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(18)
        .lifeCard()
    }

    private var weekdayPatterns: [WeekdayPattern] { weeklyRhythm.inWeekOrder }

    private var weekdayPatternsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your weekly rhythm").font(.title2.bold())
            Text("Waking hours on each day, by activity. Sleep is counted separately.")
                .font(.subheadline).foregroundStyle(.secondary)
            if weeklyRhythm.allSatisfy({ $0.hours == 0 }) {
                InsightEmptyRow(icon: "calendar", title: "Not enough activity history", detail: "Your usual weekday activities will appear here as visits accumulate.")
            } else {
                weekdayChart(height: 190)
                Button { showingWeekdayChart = true } label: {
                    Text("View full chart").font(.subheadline.bold())
                }
                .accessibilityHint("Opens a larger chart with each day's activities listed")
            }
        }
        .padding(18)
        .lifeCard()
    }

    /// The bars themselves, shared by the card and the full-screen sheet so the two
    /// cannot drift apart. Stacked by category in the donut's colours, so a band means
    /// the same thing everywhere on the screen.
    private func weekdayChart(height: CGFloat) -> some View {
        Chart {
            ForEach(weekdayPatterns) { pattern in
                ForEach(pattern.activities) { entry in
                    BarMark(
                        x: .value("Day", pattern.shortName),
                        y: .value("Hours", entry.hours)
                    )
                    .foregroundStyle(entry.color)
                }
            }
        }
        // Without an explicit domain the scale is inferred from the marks, so a week
        // with nothing recorded on Monday simply has no Monday — the bars slide across
        // and a quiet day reads as a missing one. The rhythm is only legible against
        // the whole week, including the days that were empty.
        .chartXScale(domain: weekdayPatterns.map(\.shortName))
        .chartXAxis {
            AxisMarks(values: weekdayPatterns.map(\.shortName)) { value in
                AxisValueLabel {
                    if let name = value.as(String.self) { Text(name).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(Int(hours))h").font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        // Fixed-height chart furniture: the axis labels cannot grow without pushing
        // the plot area away entirely, the same reason the donut's centre is capped.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityIdentifier("weekly-rhythm-chart")
        .accessibilityLabel("Waking hours by weekday")
        .accessibilityValue(weekdayPatterns
            .map { "\($0.fullName), \(formatHours($0.hours))" }
            .joined(separator: ". "))
    }

    private var weekdayChartSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    weekdayChart(height: 260)
                    ForEach(weekdayPatterns) { pattern in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(pattern.fullName).font(.headline)
                                Spacer()
                                Text(formatHours(pattern.hours))
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if pattern.activities.isEmpty {
                                Text("No activity yet").font(.caption).foregroundStyle(.tertiary)
                            } else {
                                ForEach(pattern.activities) { entry in
                                    HStack(spacing: 9) {
                                        Circle().fill(entry.color).frame(width: 10, height: 10)
                                        Text(entry.category).font(.subheadline)
                                        Spacer()
                                        Text(formatHours(entry.hours))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
                .padding(18)
            }
            .background(Color.lifeBackground)
            .navigationTitle("Your weekly rhythm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingWeekdayChart = false }
                }
            }
        }
    }

    /// What the recent weeks noticed: something taken up again, a new high, a run.
    ///
    /// Shown only when there is something to say. A standing card reading "no habits
    /// yet" would be on screen for the whole first season of use, which teaches the
    /// person to scroll past the place these appear.
    @ViewBuilder private var habitsSection: some View {
        if !habits.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recurring habits").font(.title2.bold())
                ForEach(habits) { habit in
                    HStack(spacing: 13) {
                        // The habit names a category, not an activity, so it carries its
                        // own symbol. ActivityIcon looks activities up by name and falls
                        // back to a map pin for anything it cannot find — which is every
                        // category, so each habit arrived wearing the same generic marker.
                        Image(systemName: habit.symbol)
                            .font(.headline)
                            .foregroundStyle(insightColor(for: habit.category))
                            .frame(width: 42, height: 42)
                            .background(insightColor(for: habit.category).opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(habit.headline).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(habit.detail)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(habit.headline). \(habit.detail)")
                }
            }
            .padding(18)
            .lifeCard()
            .accessibilityIdentifier("insights-habits")
        }
    }

    /// The long view: where home and sleep have been heading over recent weeks.
    ///
    /// Independent of the selected period on purpose. Every other card answers
    /// "what about this day/week?"; this one answers "what about lately", and
    /// re-cutting it to the chosen window would leave one week with one point.
    @ViewBuilder private var trendLinesSection: some View {
        if !trendSeries.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent months").font(.title2.bold())
                    Text("The last \(InsightsTrends.weeks) weeks, a point per week")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(trendSeries) { series in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(series.title, systemImage: series.symbol)
                            .font(.headline)
                            .foregroundStyle(insightColor(for: series.title))
                        trendChart(series)
                        Text(series.message)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .lifeCard()
            .accessibilityIdentifier("insights-trend-lines")
        }
    }

    private func trendChart(_ series: InsightsTrendSeries) -> some View {
        let color = insightColor(for: series.title)
        return Chart {
            // The usual week, drawn behind the line so a point can be read against it
            // at a glance. This is the number the sentence underneath quotes.
            if series.baseline > 0 {
                RuleMark(y: .value("Usual", series.baseline))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            ForEach(series.points) { point in
                LineMark(
                    x: .value("Week", point.weekStart),
                    y: .value("Hours", point.hours)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                AreaMark(
                    x: .value("Week", point.weekStart),
                    y: .value("Hours", point.hours)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color.opacity(0.12))
            }
        }
        .chartXAxis {
            // Labelled by month rather than by week: twelve week-beginning dates is a
            // row of unreadable numbers, and the question these lines answer is which
            // month things changed in.
            AxisMarks(values: .stride(by: .month)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(Int(hours))h").font(.caption2)
                    }
                }
            }
        }
        .frame(height: 150)
        // Fixed-height chart furniture, capped for the same reason the ring is.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel("\(series.title) hours per week over the last \(InsightsTrends.weeks) weeks")
        .accessibilityValue(series.message)
    }

    private var activitySlices: [TimeSlice] {
        snapshot.slices.filter { $0.hours > 0 && !$0.isUnlogged }
    }

    private var topActivitiesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top Activities").font(.title2.bold())
            if activitySlices.isEmpty {
                InsightEmptyRow(icon: "list.bullet", title: "No activity yet", detail: "Logged time will appear here as visits accumulate.")
            } else {
                let shown = showAllActivities ? activitySlices : Array(activitySlices.prefix(3))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, slice in
                    Button { selectedSlice = slice } label: {
                        HStack(spacing: 13) {
                            ActivityIcon(activity: slice.name, color: slice.color, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(slice.name).font(.headline).lineLimit(1)
                                Text(formatHours(slice.hours)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(activityPercentage(slice))%").font(.subheadline.bold().monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(slice.name), \(formatHours(slice.hours)), \(activityPercentage(slice)) percent of logged time")
                    .accessibilityHint("Review and edit visits")
                    if index < shown.count - 1 { Divider().padding(.leading, 55) }
                }
                if activitySlices.count > 3 {
                    Button { showAllActivities.toggle() } label: {
                        Text(showAllActivities ? "Show less" : "View all activities")
                            .font(.subheadline.bold())
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(18)
        .lifeCard()
    }

    private func activityPercentage(_ slice: TimeSlice) -> Int {
        Int((slice.hours / max(snapshot.loggedHours, 0.01) * 100).rounded())
    }

    private var topPlacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top places by time").font(.title2.bold())
            if snapshot.placeTotals.isEmpty {
                InsightEmptyRow(icon: "mappin.slash", title: "No places in this period", detail: "Choose another date or time window.")
            } else {
                ForEach(Array(snapshot.placeTotals.prefix(8).enumerated()), id: \.element.id) { index, place in
                    Button { selectedPlace = place } label: {
                        HStack(spacing: 13) {
                            Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                            ActivityIcon(activity: place.activity, context: place.name,
                                         color: activityColor(place.activity), size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.name).font(.headline).lineLimit(1)
                                Text(place.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatHours(place.hours)).font(.subheadline.bold().monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Review and edit visits to \(place.name)")
                    if index < min(snapshot.placeTotals.count, 8) - 1 { Divider().padding(.leading, 76) }
                }
            }
        }
        .padding(18)
        .lifeCard()
    }

    private var placeSummary: String {
        let count = snapshot.placeTotals.count
        if count == 0 { return "No places recorded for this \(window.title.lowercased())." }
        return "This \(window.title.lowercased()), you visited \(count) \(count == 1 ? "place" : "places") and logged \(formatHours(snapshot.loggedHours))."
    }

    private func reloadInsights() {
        // Fetch only the selected and comparison periods. Keeping the nine-year journal
        // archive out of memory is substantially cheaper than trimming useful history.
        let currentInterval = window.interval(containing: anchorDate)
        let fetchEnd = currentInterval.contains(now) ? now : currentInterval.end
        let analysisInterval = DateInterval(start: currentInterval.start, end: fetchEnd)
        let fetchStart = window.previousComparisonInterval(for: analysisInterval).start
        let fetchStartedAt = Date.now
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                visit.arrival >= fetchStart && visit.arrival < fetchEnd
            },
            sortBy: [SortDescriptor(\.arrival)]
        )
        do {
            var fetched = try context.fetch(descriptor)
            // Preserve a current multi-day location whose arrival predates the comparison
            // range without widening the main archive query.
            do {
                let activeDescriptor = FetchDescriptor<Visit>(
                    predicate: #Predicate { $0.departure == nil },
                    sortBy: [SortDescriptor(\.arrival)]
                )
                let existingIDs = Set(fetched.map { ObjectIdentifier($0) })
                fetched.append(contentsOf: try context.fetch(activeDescriptor).filter {
                    !existingIDs.contains(ObjectIdentifier($0))
                })
            } catch {
                // The period data is still valid if the optional-date supplement is
                // unavailable on a particular protected-store/runtime combination.
                Diagnostics.record(error, context: context, subsystem: "Insights",
                                   operation: "active visit supplement", severity: "info")
            }
            visits = fetched.sorted { $0.arrival < $1.arrival }
        } catch {
            // Keep Insights usable if a protected-store/runtime predicate cannot be
            // translated on a particular iOS build. This slower fallback is only used
            // after the narrow fetch fails and is itself filtered in memory.
            do {
                let fallback = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
                visits = fallback.filter {
                    ($0.arrival >= fetchStart && $0.arrival < fetchEnd) || $0.departure == nil
                }
                Diagnostics.record(error, context: context, subsystem: "Insights",
                                   operation: "date-scoped fetch", severity: "warning")
            } catch {
                visits = []
                Diagnostics.record(error, context: context, subsystem: "Insights",
                                   operation: "Insights fallback fetch")
            }
        }
        // `budget` records this same elapsed time unconditionally, and against the
        // window's own limit rather than a flat 250 ms — which a year view is expected
        // to exceed. The `performance` sample beside it wrote a second row calling that
        // "Slow" while the budget row called the same measurement a pass.
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) period fetch",
                           startedAt: fetchStartedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)

        // Donut taps remain local to the chart and never rebuild history, trends,
        // place totals, or Map content.
        let startedAt = Date.now
        // The generation is captured with the input. A write arriving during
        // aggregation will post invalidation and trigger a fresh rebuild.
        // Home is part of the key: moving or resizing the saved place changes what
        // counts as time away from it, and a stale snapshot would not know.
        let home = InsightsSnapshot.HomePlace(homePlace)
        let homeKey = home.map { "\($0.latitude),\($0.longitude),\($0.radius)" } ?? "none"
        let cacheKey = "\(window.rawValue)|\(anchorDate.timeIntervalSinceReferenceDate)|\(Int(now.timeIntervalSinceReferenceDate / 60))|\(visits.count)|\(homeKey)"
        snapshot = snapshotCache.snapshot(key: cacheKey, generation: aggregationGeneration) {
            InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now, home: home)
        }
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) snapshot rebuild",
                           startedAt: startedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)
    }

    private func visits(for slice: TimeSlice) -> [Visit] {
        guard !slice.isUnlogged else { return [] }
        return visits
            .filter { $0.overlaps(snapshot.analysisInterval, now: snapshot.generatedAt) }
            .filter { sliceName(for: $0) == slice.name }
            .sorted { $0.arrival > $1.arrival }
    }

    private func sliceName(for visit: Visit) -> String {
        visit.insightCategory
    }

    private func visits(for place: PlaceTotal) -> [Visit] {
        // Mirrors the same filters InsightsSnapshot.makePlaceTotals used to build
        // `place`, so the entries shown here match the hours displayed in the row.
        visits
            .filter { $0.overlaps(snapshot.analysisInterval, now: snapshot.generatedAt) }
            .filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            .filter { $0.displayPlaceName == place.name }
            .sorted { $0.arrival > $1.arrival }
    }

    private func move(_ amount: Int) {
        anchorDate = window.move(anchorDate, by: amount)
    }

    private var isCurrentWindow: Bool { window.interval(containing: now).contains(anchorDate) }
    private var periodTitle: String {
        if window.interval(containing: now).contains(anchorDate) { return window == .day ? "Today" : "This \(window.title)" }
        return window.title(for: interval)
    }
    private var periodSubtitle: String { window.subtitle(for: interval) }
}

/// Carries the tallest highlight row's height up from the hidden measuring pass.
private struct HighlightHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
