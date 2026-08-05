import SwiftUI
import SwiftData
import Charts
import MapKit

struct TrendsView: View {
    @Environment(\.modelContext) private var context
    let activityData: ActivityDataService
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
                        donutSection
                        if window == .day { dailyTimelineSection }
                        awayFromHomeSection
                        activityChangesSection
                        dataQualitySection
                        trendsSection
                        weekdayPatternsSection
                        placesSection
                        topPlacesSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .accessibilityIdentifier("insights-screen")
            .navigationTitle("Insights")
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

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(snapshot.slices.filter { $0.hours > 0 }) { slice in
                    Button { selectedSlice = slice } label: {
                        HStack(spacing: 9) {
                            Circle().fill(slice.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(slice.name).font(.subheadline).lineLimit(1)
                                Text(formatHours(slice.hours)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(slice.name), \(formatHours(slice.hours)), category colour \(categoryColorHex(forCategory: slice.name))")
                    .accessibilityHint(slice.isUnlogged ? "Add a visit" : "Review and edit visits")
                }
            }
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

    private var dailyTimelineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your day").font(.title2.bold())
            Text("A 24-hour view of where your time went").font(.subheadline).foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(snapshot.segments) { segment in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segment.color)
                            .frame(width: max(3, proxy.size.width * segment.hours / max(snapshot.totalHours, 0.01)))
                            .accessibilityLabel("\(segment.activity), \(formatHours(segment.hours))")
                    }
                }
            }
            .frame(height: 34)
            HStack { Text("12am"); Spacer(); Text("6am"); Spacer(); Text("12pm"); Spacer(); Text("6pm"); Spacer(); Text("Now") }
                .font(.caption2).foregroundStyle(.secondary)
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

    private var activityChangesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity changes").font(.title2.bold())
            if snapshot.comparisons.isEmpty {
                InsightEmptyRow(icon: "chart.bar.xaxis", title: "Not enough history", detail: "Changes appear after two comparable periods.")
            } else {
                let maximum = max(snapshot.comparisons.map { abs($0.delta) }.max() ?? 0, 0.01)
                ForEach(snapshot.comparisons.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(item.name).font(.subheadline.bold()); Spacer(); Text("\(item.delta >= 0 ? "+" : "−")\(formatHours(abs(item.delta)))").foregroundStyle(item.delta >= 0 ? .orange : .blue) }
                        GeometryReader { proxy in
                            Capsule().fill((item.delta >= 0 ? Color.orange : Color.blue).opacity(0.8))
                                .frame(width: max(4, proxy.size.width * abs(item.delta) / maximum))
                        }.frame(height: 8)
                    }
                }
            }
        }.padding(20).lifeCard()
    }

    private var dataQualitySection: some View {
        Group {
            if snapshot.provisionalCount > 0 || snapshot.supersededCount > 0 || snapshot.unloggedHours > 0.25 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline quality").font(.title2.bold())
                    if snapshot.provisionalCount > 0 { Label("\(snapshot.provisionalCount) location callbacks need review", systemImage: "questionmark.circle") }
                    if snapshot.supersededCount > 0 { Label("\(snapshot.supersededCount) duplicate callbacks resolved", systemImage: "checkmark.circle") }
                    if snapshot.unloggedHours > 0.25 { Label("\(formatHours(snapshot.unloggedHours)) is not logged", systemImage: "clock.badge.questionmark") }
                }.padding(20).lifeCard()
            }
        }
    }

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

    private var weekdayPatternsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your weekly rhythm").font(.title2.bold())
            Text("The activity that takes up the most time on each day")
                .font(.subheadline).foregroundStyle(.secondary)
            if snapshot.weekdayPatterns.allSatisfy({ $0.topHours == 0 }) {
                InsightEmptyRow(icon: "calendar", title: "Not enough activity history", detail: "Your usual weekday activities will appear here as visits accumulate.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(snapshot.weekdayPatterns) { pattern in
                        HStack(spacing: 9) {
                            ActivityIcon(activity: pattern.topActivity,
                                         color: activityColor(pattern.topActivity), size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pattern.shortName).font(.caption.bold()).foregroundStyle(.secondary)
                                if pattern.topHours > 0 {
                                    Text(pattern.topActivity).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(formatHours(pattern.topHours)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                } else {
                                    Text("No activity yet").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
        }
        .padding(18)
        .lifeCard()
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
        let fetchStart = currentInterval.start.addingTimeInterval(-currentInterval.duration)
        let fetchEnd = currentInterval.contains(now) ? now : currentInterval.end
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
        Diagnostics.performance(context, subsystem: "Insights", operation: "period fetch",
                                startedAt: fetchStartedAt, itemCount: visits.count)
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) period fetch",
                           startedAt: fetchStartedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)

        // Donut taps remain local to the chart and never rebuild history, trends,
        // place totals, or Map content.
        let startedAt = Date.now
        // The generation is captured with the input. A write arriving during
        // aggregation will post invalidation and trigger a fresh rebuild.
        let cacheKey = "\(window.rawValue)|\(anchorDate.timeIntervalSinceReferenceDate)|\(Int(now.timeIntervalSinceReferenceDate / 60))|\(visits.count)"
        snapshot = snapshotCache.snapshot(key: cacheKey, generation: aggregationGeneration) {
            InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now)
        }
        Diagnostics.performance(context, subsystem: "Insights", operation: "snapshot rebuild",
                                startedAt: startedAt, itemCount: visits.count)
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
