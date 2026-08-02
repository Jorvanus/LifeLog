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
    @State private var now = Date.now
    @State private var snapshot = InsightsSnapshot.empty
    @State private var exportFile: TrendExportFile?

    private var interval: DateInterval { window.interval(containing: anchorDate) }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.lifeBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 22) {
                        controls
                        donutSection
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
                reloadInsights()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    now = .now
                    reloadInsights()
                }
            }
            .onChange(of: window) { _, _ in reloadInsights() }
            .onChange(of: anchorDate) { _, _ in reloadInsights() }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                Spacer()
                Button { choosingDate = true } label: {
                    VStack(spacing: 2) {
                        Text(periodTitle).font(.title3.bold()).foregroundStyle(.primary)
                        Text(periodSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").font(.title3.bold()) }
                    .disabled(isCurrentWindow)
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
                analysisInterval: snapshot.analysisInterval
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
                    .accessibilityLabel("\(slice.name), \(formatHours(slice.hours))")
                    .accessibilityHint(slice.isUnlogged ? "Add a visit" : "Review and edit visits")
                }
            }
        }
        .padding(18)
        .insightCard()
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
        .insightCard()
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
        .insightCard()
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
                                         category: pattern.topActivity,
                                         color: activityColor(pattern.topActivity))
                                .scaleEffect(0.68).frame(width: 30, height: 30)
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
        .insightCard()
    }

    private var topPlacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top places by time").font(.title2.bold())
            if snapshot.placeTotals.isEmpty {
                InsightEmptyRow(icon: "mappin.slash", title: "No places in this period", detail: "Choose another date or time window.")
            } else {
                ForEach(Array(snapshot.placeTotals.prefix(8).enumerated()), id: \.element.id) { index, place in
                    HStack(spacing: 13) {
                        Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        ActivityIcon(activity: place.activity, category: place.category,
                                     color: activityColor(place.activity)).scaleEffect(0.72).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name).font(.headline).lineLimit(1)
                            Text(place.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatHours(place.hours)).font(.subheadline.bold().monospacedDigit())
                    }
                    if index < min(snapshot.placeTotals.count, 8) - 1 { Divider().padding(.leading, 76) }
                }
            }
        }
        .padding(18)
        .insightCard()
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
            let activeDescriptor = FetchDescriptor<Visit>(
                predicate: #Predicate { $0.departure == nil },
                sortBy: [SortDescriptor(\.arrival)]
            )
            let existingIDs = Set(fetched.map { ObjectIdentifier($0) })
            fetched.append(contentsOf: try context.fetch(activeDescriptor).filter {
                !existingIDs.contains(ObjectIdentifier($0))
            })
            visits = fetched.sorted { $0.arrival < $1.arrival }
        } catch {
            visits = []
            Diagnostics.record(context, subsystem: "Insights",
                               message: "A date-scoped Insights fetch failed; no location or activity data was displayed.")
        }
        Diagnostics.performance(context, subsystem: "Insights", operation: "period fetch",
                                startedAt: fetchStartedAt, itemCount: visits.count)

        // Donut taps remain local to the chart and never rebuild history, trends,
        // place totals, or Map content.
        let startedAt = Date.now
        snapshot = InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now)
        Diagnostics.performance(context, subsystem: "Insights", operation: "snapshot rebuild",
                                startedAt: startedAt, itemCount: visits.count)
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

enum InsightWindow: String, CaseIterable, Identifiable, Hashable {
    case day, week, month, year
    var id: Self { self }
    var title: String { rawValue.capitalized }

    func interval(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        switch self {
        case .day:
            let start = calendar.startOfDay(for: date)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month: return calendar.dateInterval(of: .month, for: date)!
        case .year: return calendar.dateInterval(of: .year, for: date)!
        }
    }

    func move(_ date: Date, by value: Int) -> Date {
        let component: Calendar.Component = switch self { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year }
        return Calendar.current.date(byAdding: component, value: value, to: date) ?? date
    }

    func title(for interval: DateInterval) -> String {
        switch self {
        case .day: interval.start.formatted(.dateTime.day().month(.abbreviated))
        case .week: "Week of \(interval.start.formatted(.dateTime.day().month(.abbreviated)))"
        case .month: interval.start.formatted(.dateTime.month(.wide).year())
        case .year: interval.start.formatted(.dateTime.year())
        }
    }

    func subtitle(for interval: DateInterval) -> String {
        switch self {
        case .day: interval.start.formatted(.dateTime.weekday(.wide).year())
        case .week: "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: "\(Int(interval.duration / 86400)) days"
        case .year: "January – December"
        }
    }
}

@MainActor
private struct InsightsSnapshot {
    let generatedAt: Date
    let analysisInterval: DateInterval
    let segments: [InsightSegment]
    let slices: [TimeSlice]
    let placeTotals: [PlaceTotal]
    let comparisons: [TrendComparison]
    let loggedHours: Double
    let totalHours: Double
    let mappablePlaces: [PlaceTotal]
    let mapRegion: MKCoordinateRegion
    let mapID: Int
    let weekdayPatterns: [WeekdayPattern]

    static let empty = InsightsSnapshot(
        generatedAt: .distantPast,
        analysisInterval: DateInterval(start: .distantPast, duration: 0),
        segments: [], slices: [], placeTotals: [], comparisons: [],
        loggedHours: 0, totalHours: 0, mappablePlaces: [],
        mapRegion: MKCoordinateRegion(
            center: .init(latitude: -27.47, longitude: 153.03),
            span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2)
        ),
        mapID: 0, weekdayPatterns: WeekdayPattern.empty
    )

    static func make(visits: [Visit], window: InsightWindow, anchorDate: Date, now: Date) -> InsightsSnapshot {
        let interval = window.interval(containing: anchorDate)
        // Current periods end “now”; otherwise future time would dominate the donut as unlogged.
        let analysisInterval = interval.contains(now)
            ? DateInterval(start: interval.start, end: min(interval.end, now))
            : interval
        let previousStart = interval.start.addingTimeInterval(-interval.duration)
        let previousInterval = DateInterval(
            start: previousStart,
            end: min(interval.start, previousStart.addingTimeInterval(analysisInterval.duration))
        )

        // Location visits are prepared once and reused by both periods. This avoids an
        // all-history scan for each individual walking or travel record.
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let segments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: analysisInterval,
            now: now
        )
        let previousSegments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: previousInterval,
            now: now
        )
        let slices = makeSlices(from: segments)
        let previousSlices = makeSlices(from: previousSegments)
        let placeTotals = makePlaceTotals(visits: visits, range: analysisInterval, now: now)
        let mappablePlaces = placeTotals.filter { $0.latitude != 0 || $0.longitude != 0 }
        let loggedHours = segments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }

        return InsightsSnapshot(
            generatedAt: now,
            analysisInterval: analysisInterval,
            segments: segments,
            slices: slices,
            placeTotals: placeTotals,
            comparisons: makeComparisons(current: slices, previous: previousSlices),
            loggedHours: loggedHours,
            totalHours: analysisInterval.duration / 3600,
            mappablePlaces: mappablePlaces,
            mapRegion: makeMapRegion(for: mappablePlaces),
            mapID: makeMapID(for: mappablePlaces),
            weekdayPatterns: makeWeekdayPatterns(from: segments)
        )
    }

    private static func makeSegments(visits: [Visit], locationVisits: [Visit],
                                     range: DateInterval, now: Date) -> [InsightSegment] {
        let orderedVisits = visits
            .filter { $0.overlaps(range, now: now) && !$0.isIgnored }
            .filter { ActivityLocationPolicy.shouldShow($0, locationVisits: locationVisits, now: now) }
            .sorted { $0.arrival < $1.arrival }
        var result: [InsightSegment] = []
        var cursor = range.start
        var gapIndex = 0

        for visit in orderedVisits {
            let clippedStart = max(visit.arrival, range.start)
            let clippedEnd = min(visit.departure ?? now, range.end)
            guard clippedEnd > clippedStart else { continue }
            if clippedStart > cursor {
                result.append(.unlogged(index: gapIndex, from: cursor, to: clippedStart))
                gapIndex += 1
            }
            let visibleStart = max(clippedStart, cursor)
            if clippedEnd > visibleStart {
                result.append(.visit(visit, visibleFrom: visibleStart, visibleTo: clippedEnd, now: now))
            }
            cursor = max(cursor, clippedEnd)
        }
        if cursor < range.end {
            result.append(.unlogged(index: gapIndex, from: cursor, to: range.end))
        }
        return result
    }

    private static func makeSlices(from segments: [InsightSegment]) -> [TimeSlice] {
        let grouped = Dictionary(grouping: segments.filter { !$0.isUnlogged }, by: \.category)
        var values = grouped.map { name, items in
            TimeSlice(name: name, hours: items.reduce(0) { $0 + $1.hours },
                      color: insightColor(for: name), symbol: insightSymbol(for: name), isUnlogged: false)
        }
        .filter { $0.hours > 0.01 }
        .sorted { $0.hours > $1.hours }
        let unlogged = segments.filter(\.isUnlogged).reduce(0) { $0 + $1.hours }
        if unlogged > 0.01 {
            values.append(TimeSlice(name: "Unlogged", hours: unlogged, color: .gray.opacity(0.35),
                                    symbol: "moon.zzz.fill", isUnlogged: true))
        }
        return values
    }

    private static func makePlaceTotals(visits: [Visit], range: DateInterval, now: Date) -> [PlaceTotal] {
        Dictionary(
            grouping: visits.filter {
                $0.overlaps(range, now: now) && ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored
            },
            by: \.displayPlaceName
        ).compactMap { name, items in
            guard let first = items.first else { return nil }
            return PlaceTotal(
                name: name, category: first.insightCategory, activity: first.suspectedActivity,
                latitude: first.latitude, longitude: first.longitude,
                hours: items.reduce(0) { $0 + $1.duration(in: range, now: now) } / 3600
            )
        }.sorted { $0.hours > $1.hours }
    }

    private static func makeComparisons(current: [TimeSlice], previous: [TimeSlice]) -> [TrendComparison] {
        let currentValues = Dictionary(uniqueKeysWithValues: current.filter { !$0.isUnlogged }.map { ($0.name, $0.hours) })
        let previousValues = Dictionary(uniqueKeysWithValues: previous.filter { !$0.isUnlogged }.map { ($0.name, $0.hours) })
        return Set(currentValues.keys).union(previousValues.keys).map { name in
            TrendComparison(
                name: name,
                hours: currentValues[name, default: 0],
                previousHours: previousValues[name, default: 0],
                delta: currentValues[name, default: 0] - previousValues[name, default: 0]
            )
        }
        .filter { abs($0.delta) >= 0.25 }
        .sorted { abs($0.delta) > abs($1.delta) }
    }

    private static func makeWeekdayPatterns(from segments: [InsightSegment]) -> [WeekdayPattern] {
        let calendar = Calendar.current
        var totals = Array(repeating: 0.0, count: 7)
        var activities = Array(repeating: [String: Double](), count: 7)
        for segment in segments where !segment.isUnlogged {
            let weekday = max(1, min(7, calendar.component(.weekday, from: segment.start))) - 1
            totals[weekday] += segment.hours
            activities[weekday][segment.activity, default: 0] += segment.hours
        }
        return (0..<7).map { index in
            let top = activities[index].max { $0.value < $1.value }
            return WeekdayPattern(weekday: index + 1, hours: totals[index],
                                  topActivity: top?.key ?? "Visiting", topHours: top?.value ?? 0)
        }
    }

    private static func makeMapRegion(for places: [PlaceTotal]) -> MKCoordinateRegion {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            return empty.mapRegion
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.01, (maxLat - minLat) * 1.5),
                        longitudeDelta: max(0.01, (maxLon - minLon) * 1.5))
        )
    }

    private static func makeMapID(for places: [PlaceTotal]) -> Int {
        var hasher = Hasher()
        for place in places {
            hasher.combine(place.name)
            hasher.combine(place.latitude)
            hasher.combine(place.longitude)
        }
        return hasher.finalize()
    }
}

private struct InsightsDonutChart: View {
    let activityData: ActivityDataService
    let segments: [InsightSegment]
    let loggedHours: Double
    let totalHours: Double
    let analysisInterval: DateInterval
    @State private var selectedAngle: Double?
    @State private var focusedSegmentID: InsightSegmentID?
    @State private var sleepSummary: SleepSummary?
    @State private var stepCount: Double?

    private var focusedSegment: InsightSegment? {
        guard let focusedSegmentID else { return nil }
        return segments.first { $0.id == focusedSegmentID }
    }

    var body: some View {
        ZStack {
            Chart(segments) { segment in
                let selected = focusedSegmentID == segment.id
                let hasSelection = focusedSegment != nil
                SectorMark(
                    angle: .value("Hours", segment.hours),
                    innerRadius: .ratio(0.56),
                    outerRadius: .ratio(selected ? 1 : 0.95),
                    angularInset: 2
                )
                .cornerRadius(6)
                .foregroundStyle(segment.color.opacity(hasSelection && !selected ? 0.2 : 1))
                .annotation(position: .overlay) {
                    if !hasSelection && segment.hours / max(totalHours, 1) > 0.08 {
                        VStack(spacing: 2) {
                            Image(systemName: segment.symbol)
                            Text(formatHours(segment.hours)).font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .chartLegend(.hidden)
            // Keep the binding for the selected data value, but explicitly forward each touch
            // through ChartProxy. The zero-distance drag recognises both taps and short touches
            // repeatedly, while ChartProxy handles the polar-to-data-angle conversion.
            .chartAngleSelection(value: $selectedAngle)
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let angle = proxy.angle(at: value.location)
                                    let angleValue = angle.degrees
                                    guard let segment = segment(at: angleValue) else { return }
                                    if focusedSegmentID == segment.id {
                                        // A second tap on the focused slice restores the
                                        // neutral donut and brings every slice back to full opacity.
                                        focusedSegmentID = nil
                                        selectedAngle = nil
                                    } else {
                                        focusedSegmentID = segment.id
                                        selectedAngle = angleValue
                                    }
                                }
                        )
                }
            }
            .onChange(of: selectedAngle) { _, angle in
                guard let angle, let segment = segment(at: angle) else { return }
                // Apply immediately so the previous focus cannot flash during a new tap.
                focusedSegmentID = segment.id
            }
            .onChange(of: segments.map(\.id)) { _, ids in
                if let focusedSegmentID, !ids.contains(focusedSegmentID) {
                    self.focusedSegmentID = nil
                    selectedAngle = nil
                }
            }
            .accessibilityHint("Highlight this entry and show its check-in, check-out, and duration")
            .task(id: sleepSummaryKey) {
                sleepSummary = nil
                guard let segment = focusedSegment, segment.isSleep else { return }
                sleepSummary = await activityData.sleepSummary(
                    for: DateInterval(start: segment.start, end: segment.end)
                )
            }

            if let focusedSegment {
                Group {
                    if focusedSegment.isSleep {
                        sleepCenter(for: focusedSegment)
                    } else {
                        focusedCenter(for: focusedSegment)
                    }
                }
                    // The centre label is visual output; it must never intercept chart taps.
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 2) {
                    if let stepCount {
                        Text(formatSteps(stepCount)).font(.title.bold()).monospacedDigit()
                        Text("steps").font(.subheadline).foregroundStyle(.secondary)
                        Text("Apple Health").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("—").font(.title.bold()).monospacedDigit()
                        Text("steps").font(.subheadline).foregroundStyle(.secondary)
                        Text("Connect Apple Health").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 330)
        .accessibilityIdentifier("insights-donut-chart")
        .task(id: stepCountKey) {
            // Let the chart render before asking HealthKit for samples. This keeps
            // navigation responsive on devices with a large Health history.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            stepCount = await activityData.stepCount(for: analysisInterval)
        }
    }

    private var stepCountKey: String {
        "\(analysisInterval.start.timeIntervalSinceReferenceDate)-\(analysisInterval.end.timeIntervalSinceReferenceDate)"
    }

    private func segment(at angle: Double) -> InsightSegment? {
        guard angle.isFinite, angle >= 0 else { return nil }
        var upperBound = 0.0
        for segment in segments {
            upperBound += segment.hours
            if angle <= upperBound { return segment }
        }
        return segments.last
    }

    private var sleepSummaryKey: String? {
        guard let focusedSegment, focusedSegment.isSleep else { return nil }
        return "\(focusedSegment.start.timeIntervalSinceReferenceDate)-\(focusedSegment.end.timeIntervalSinceReferenceDate)"
    }

    private func sleepCenter(for segment: InsightSegment) -> some View {
        VStack(spacing: 3) {
            if let sleepSummary {
                Text("\(sleepSummary.estimatedScore)")
                    .font(.title.bold()).monospacedDigit().foregroundStyle(.blue)
                Text("LifeLog sleep estimate").font(.caption.bold())
                Text("Asleep  \(formatHours(sleepSummary.totalSleep / 3600))")
                Text("In bed  \(formatHours(sleepSummary.timeInBed / 3600))")
                Text("Deep \(formatHours(sleepSummary.deep / 3600))  •  REM \(formatHours(sleepSummary.rem / 3600))")
                    .font(.caption2)
                Text("Awake \(formatHours(sleepSummary.awake / 3600))  •  \(sleepSummary.interruptions) interruptions")
                    .font(.caption2)
            } else {
                ProgressView()
                Text("Loading sleep data…").font(.caption)
            }
            Text("Apple Health sleep stages").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .frame(width: 190)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep details")
    }

    private func focusedCenter(for segment: InsightSegment) -> some View {
        VStack(spacing: 3) {
            Image(systemName: segment.symbol).font(.title3.bold()).foregroundStyle(segment.color)
            Text(segment.activity).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            if let placeName = segment.placeName, placeName != segment.activity {
                Text(placeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider().padding(.vertical, 2)
            Text("In  \(timeLabel(segment.start))")
            Text("Out  \(segment.isLive ? "Now" : timeLabel(segment.end))")
            Text(formatHours(segment.end.timeIntervalSince(segment.start) / 3600))
                .font(.subheadline.bold().monospacedDigit()).padding(.top, 2)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.primary)
        .frame(width: 176)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.activity), \(segment.placeName ?? ""), in \(timeLabel(segment.start)), out \(segment.isLive ? "now" : timeLabel(segment.end)), duration \(formatHours(segment.end.timeIntervalSince(segment.start) / 3600))")
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct InsightsPlacesMap: View {
    let places: [PlaceTotal]
    let region: MKCoordinateRegion

    var body: some View {
        Map(initialPosition: .region(region)) {
            ForEach(places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.blue)
                        Text(place.name).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule()).lineLimit(1)
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

private struct TimeSlice: Identifiable {
    var id: String { "\(isUnlogged ? "gap" : "logged"):\(name)" }
    let name: String
    let hours: Double
    let color: Color
    let symbol: String
    let isUnlogged: Bool
}

private enum InsightSegmentID: Hashable {
    case visit(ObjectIdentifier)
    case unlogged(Int)
}

private struct InsightSegment: Identifiable {
    let id: InsightSegmentID
    let visit: Visit?
    let category: String
    let activity: String
    let placeName: String?
    let start: Date
    let end: Date
    let hours: Double
    let color: Color
    let symbol: String
    let isUnlogged: Bool
    let isLive: Bool

    var isSleep: Bool {
        category.localizedCaseInsensitiveContains("sleep") || activity.localizedCaseInsensitiveContains("sleep")
    }

    static func visit(_ visit: Visit, visibleFrom: Date, visibleTo: Date, now: Date) -> InsightSegment {
        let category = visit.insightCategory
        let end = visit.departure ?? now
        return InsightSegment(
            id: .visit(ObjectIdentifier(visit)), visit: visit, category: category,
            activity: visit.suspectedActivity, placeName: visit.displayPlaceName,
            start: visit.arrival, end: end,
            hours: visibleTo.timeIntervalSince(visibleFrom) / 3600,
            color: insightColor(for: category), symbol: insightSymbol(for: category),
            isUnlogged: false, isLive: visit.departure == nil
        )
    }

    static func unlogged(index: Int, from start: Date, to end: Date) -> InsightSegment {
        InsightSegment(
            id: .unlogged(index), visit: nil, category: "Unlogged",
            activity: "Unlogged", placeName: nil, start: start, end: end,
            hours: end.timeIntervalSince(start) / 3600,
            color: .gray.opacity(0.35), symbol: "moon.zzz.fill",
            isUnlogged: true, isLive: false
        )
    }
}

private struct InsightSliceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let slice: TimeSlice
    let visits: [Visit]
    let interval: DateInterval
    @State private var addingVisit = false

    var body: some View {
        NavigationStack {
            Group {
                if slice.isUnlogged {
                    ContentUnavailableView {
                        Label("Unlogged time", systemImage: "clock.badge.questionmark")
                    } description: {
                        Text("There isn’t a visit to edit for this time yet. Add one to fill the gap in your insights.")
                    } actions: {
                        Button("Add Visit") { addingVisit = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if visits.isEmpty {
                    ContentUnavailableView("No matching visits", systemImage: "mappin.slash",
                                           description: Text("This insight changed while it was open."))
                } else {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                Image(systemName: slice.symbol)
                                    .font(.title2.bold()).foregroundStyle(.white)
                                    .frame(width: 48, height: 48).background(slice.color.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(formatHours(slice.hours)).font(.title3.bold()).monospacedDigit()
                                    Text("across \(visits.count) \(visits.count == 1 ? "entry" : "entries")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("Tap an entry to edit") {
                            ForEach(visits) { visit in
                                NavigationLink { VisitEditor(visit: visit) } label: {
                                    HStack(spacing: 12) {
                                        ActivityIcon(activity: visit.activity, category: visit.placeCategory,
                                                     color: activityColor(visit.activity))
                                            .scaleEffect(0.72).frame(width: 42, height: 42)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(visit.placeName).font(.headline).lineLimit(1)
                                            Text(entryTime(for: visit)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(formatHours(visit.duration(in: interval) / 3600))
                                            .font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(slice.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .sheet(isPresented: $addingVisit) { ManualVisitView() }
    }

    private func entryTime(for visit: Visit) -> String {
        let start = max(visit.arrival, interval.start)
        let end = min(visit.departure ?? .now, interval.end)
        let date = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) · \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

private struct PlaceTotal: Identifiable {
    var id: String { name }
    let name: String
    let category: String
    let activity: String
    let latitude: Double
    let longitude: Double
    let hours: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private struct TrendComparison: Identifiable {
    var id: String { name }
    let name: String
    let hours: Double
    let previousHours: Double
    let delta: Double
    func message(window: InsightWindow) -> String {
        let direction = delta >= 0 ? "more" : "less"
        let percentage = previousHours > 0 ? " (\(Int((abs(delta) / previousHours * 100).rounded()))%)" : " (new)"
        return "You spent \(formatHours(abs(delta)))\(percentage) \(direction) on \(name.lowercased()) this \(window.title.lowercased())."
    }
}

private struct WeekdayPattern: Identifiable {
    let weekday: Int
    let hours: Double
    let topActivity: String
    let topHours: Double
    var id: Int { weekday }
    var shortName: String {
        Calendar.current.shortWeekdaySymbols[(weekday - 1) % 7]
    }
    static let empty = (1...7).map { WeekdayPattern(weekday: $0, hours: 0, topActivity: "Visiting", topHours: 0) }
}

private struct InsightEmptyRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension Visit {
    func overlaps(_ range: DateInterval, now: Date = .now) -> Bool {
        arrival < range.end && (departure ?? now) > range.start
    }
    func duration(in range: DateInterval, now: Date = .now) -> TimeInterval {
        max(0, min(departure ?? now, range.end).timeIntervalSince(max(arrival, range.start)))
    }
}

private extension View {
    func insightCard() -> some View {
        background(Color.lifeCard, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
    }
}

private func formatHours(_ hours: Double) -> String {
    let minutes = max(0, Int((hours * 60).rounded()))
    if minutes < 60 { return "\(minutes)m" }
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

private func formatSteps(_ count: Double) -> String {
    Int(max(0, count).rounded()).formatted(.number)
}

private func insightColor(for value: String) -> Color {
    let text = value.lowercased()
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

private func insightSymbol(for value: String) -> String {
    let text = value.lowercased()
    if text.contains("uncategor") { return "flag.fill" }
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
