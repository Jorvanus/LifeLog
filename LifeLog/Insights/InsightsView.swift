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
    @State private var draftAnchorDate = Date.now
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
    /// The day's segments over the full, uncapped 24-hour interval -- unlike
    /// `snapshot.segments`, which stops at `now` for today. Only populated for
    /// `window == .day`; the day bar is the only thing that reads it.
    @State private var daySegments: [InsightSegment] = []
    @State private var selectedDaySegment: InsightSegment?
    /// Shared by the Current Activity card and Needs Attention rows -- both are
    /// "open this one Visit," the same action `VisitEditor` already exists for.
    @State private var editingVisit: Visit?
    @State private var addVisitRange = DateInterval(start: .now, duration: 0)
    @State private var isAddingVisit = false
    @State private var todaySteps: Double?
    @State private var lastNightSleep: SleepSummary?
    /// Up to `InsightsTrends.habitWeeks` of completed weeks' per-category hours,
    /// the same fetch `trendSeries`/`habits` already use -- never includes the
    /// in-progress week (`InsightsTrends.range` ends before it), which is what
    /// keeps the Week rolling baseline from comparing a partial week as if it
    /// were whole.
    @State private var weeklyBaselineTotals: [WeeklyTotals] = []
    @State private var weekSteps: Double?
    @State private var weekAverageNightlySleep: TimeInterval?
    @State private var monthSteps: Double?
    @State private var monthAverageNightlySleep: TimeInterval?
    @State private var weekDays: [WeeklyStrip.Day] = []
    @State private var monthDays: [MonthlyInsights.Day] = []
    @State private var annualInsights = AnnualInsights.make(current: [], previous: [],
                                                             yearInterval: DateInterval(start: .distantPast, duration: 0), now: .now)
    @State private var annualHealth = AnnualInsights.HealthMetrics.empty

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
                        if window == .day {
                            dayLayout
                        } else if window == .week {
                            weekLayout
                        } else if window == .month {
                            monthLayout
                        } else {
                            yearLayout
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .accessibilityIdentifier("insights-screen")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosingDate) {
                NavigationStack {
                    DatePicker("Choose date", selection: $draftAnchorDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle("Choose Date")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { choosingDate = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    anchorDate = draftAnchorDate
                                    choosingDate = false
                                }
                            }
                        }
                }.presentationDetents([.medium])
            }
            .sheet(isPresented: $showingWeekdayChart) { weekdayChartSheet }
            .sheet(item: $selectedSlice, onDismiss: reloadInsights) { slice in
                let rows = sliceRows(for: slice)
                // Skip straight to the editor only when there is exactly one row
                // and it is a real Visit — a lone commute row has no record to open.
                if rows.count == 1, let visit = rows.first?.visit {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    InsightSliceEditor(slice: slice, rows: rows, interval: snapshot.analysisInterval)
                        .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $selectedPlace, onDismiss: reloadInsights) { place in
                let rows = sliceRows(for: place)
                if rows.count == 1, let visit = rows.first?.visit {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    // Reuse the category slice editor for a single place: it already
                    // handles "one visit -> edit directly" vs "many visits -> pick one".
                    InsightSliceEditor(
                        slice: TimeSlice(name: place.name, hours: place.hours,
                                         color: activityColor(place.activity),
                                         symbol: insightSymbol(for: place.category), isUnlogged: false),
                        rows: rows,
                        interval: snapshot.analysisInterval
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $selectedDaySegment, onDismiss: reloadInsights) { segment in
                if let visit = segment.visit {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    ManualVisitView(range: DateInterval(start: segment.start, end: segment.end))
                }
            }
            .sheet(item: $editingVisit, onDismiss: reloadInsights) { visit in
                NavigationStack { VisitEditor(visit: visit) }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isAddingVisit, onDismiss: reloadInsights) {
                ManualVisitView(range: addVisitRange)
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
                // Historical month/year sleep is already represented by imported
                // Health visits. Re-querying and re-importing the entire period while
                // changing tabs delays the first useful frame, so refresh only the
                // short windows where a newly synced night can affect the screen.
                guard window == .day || window == .week else { return }
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
            .task(id: trendKey) {
                guard window != .day else {
                    trendSeries = []
                    habits = []
                    weeklyRhythm = WeekdayPattern.empty
                    return
                }
                await reloadTrends()
            }
            .task(id: annualKey) {
                guard window == .year else { return }
                await reloadAnnualHealth()
            }
        }
    }

    /// The trends only move when the week does, so stepping through days inside one
    /// week never re-reads a season of history.
    private var trendKey: String {
        "\(window.rawValue)-\(InsightsTrends.range(endingAt: now).start.timeIntervalSinceReferenceDate)"
    }

    private var annualKey: String {
        "\(window.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(Int(now.timeIntervalSinceReferenceDate / 3600))"
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
            weekSteps = nil
            weekAverageNightlySleep = nil
            // Stashed here, not re-queried by the Day summary card: this is
            // already the one place Insights asks HealthKit for today's steps
            // and last night's sleep.
            let steps = await activityData.stepCount(for: dayInterval)
            todaySteps = steps
            if let steps {
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
            let night = await activityData.sleepSummary(for: dayInterval)
            lastNightSleep = night
            if let night,
               let average = await activityData.averageNightlySleep(before: interval.start, nights: 14),
               let highlight = DayHighlights.sleep(lastNight: night.totalSleep, averageNight: average) {
                found.append(highlight)
            }
        } else if window == .week {
            todaySteps = nil
            lastNightSleep = nil
            // Same one-call-per-metric shape as Day's steps/sleep above, just
            // over the week's own interval -- `stepCount`/`averageNightlySleep`
            // already accept an arbitrary span, so this is not seven daily calls.
            weekSteps = await activityData.stepCount(for: dayInterval)
            weekAverageNightlySleep = await activityData.averageNightlySleep(before: interval.end, nights: 7)
            monthSteps = nil
            monthAverageNightlySleep = nil
        } else if window == .month {
            todaySteps = nil
            lastNightSleep = nil
            weekSteps = nil
            weekAverageNightlySleep = nil
            // Query the month once per metric for the scorecard. The day count
            // used for the displayed average is capped at elapsed days below,
            // so a current month is not diluted by future dates.
            monthSteps = await activityData.stepCount(for: dayInterval)
            let elapsedSeconds = max(0, dayInterval.duration)
            let elapsedNights = max(1, Int(ceil(elapsedSeconds / 86_400)))
            monthAverageNightlySleep = await activityData.averageNightlySleep(
                before: dayInterval.end, nights: elapsedNights
            )
        } else {
            todaySteps = nil
            lastNightSleep = nil
            weekSteps = nil
            weekAverageNightlySleep = nil
            monthSteps = nil
            monthAverageNightlySleep = nil
        }
        if let highlight = DayHighlights.activity(from: snapshot.comparisons, window: window) {
            found.append(highlight)
        }
        if let place = snapshot.placeTotals.first {
            if let highlight = DayHighlights.leadingPlace(place, window: window) {
                found.append(highlight)
            }
            let history = placeHistory(matching: place.name)
            if let highlight = ArchiveRetrospectives.firstVisitToPlace(
                place, history: history, windowStart: interval.start, window: window
            ) {
                found.append(highlight)
            }
            if let highlight = ArchiveRetrospectives.longestAbsenceFromPlace(
                place, history: history, windowStart: interval.start
            ) {
                found.append(highlight)
            }
        }
        if let highlight = yearOverYearHighlight() {
            found.append(highlight)
        }
        guard !Task.isCancelled else { return }
        // Day's carousel is capped at three, deliberately -- a daily review
        // screen names what stood out, it does not repeat every comparison
        // available. Week/Month/Year are unchanged.
        let ordered = variedHighlights(found)
        highlights = window == .day ? Array(ordered.prefix(3)) : ordered
        highlightPage = min(highlightPage, max(0, highlights.count - 1))
    }

    /// Every visit to places matching this name, unscoped by date — the archive
    /// retrospectives need to know what happened before the window being looked
    /// at, not just within it. Automatic/manual only, the same location-visit
    /// sources `leadingPlace` itself is built from; device activity carries no
    /// place worth matching against.
    private func placeHistory(matching name: String) -> [Visit] {
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { NameKey.matching($0.placeName) == NameKey.matching(name) }
    }

    /// This period's total against the same period a year ago. A fetch of its own,
    /// scoped tightly to that one historical window rather than the whole archive.
    private func yearOverYearHighlight() -> DayHighlight? {
        guard let yearAgoAnchor = Calendar.current.date(byAdding: .year, value: -1, to: anchorDate) else { return nil }
        let yearAgoInterval = window.interval(containing: yearAgoAnchor)
        let start = yearAgoInterval.start
        let end = yearAgoInterval.end
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" && $0.arrival < end && ($0.departure ?? end) >= start }
        )
        guard let visits = try? context.fetch(descriptor) else { return nil }
        let yearAgoHours = InsightsSnapshot.categoryHours(visits: visits, range: yearAgoInterval, now: now)
            .values.reduce(0, +)
        return ArchiveRetrospectives.yearOverYear(loggedHours: snapshot.loggedHours,
                                                   yearAgoHours: yearAgoHours, window: window)
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

    /// Loads the season of trend-line history, and the year of it `habits` needs to
    /// make an honest "first this year" claim.
    ///
    /// A fetch of its own, deliberately separate from `reloadInsights`. That one is
    /// scoped tightly to the selected period and re-runs on every tap of the date
    /// arrows; this one reaches back up to a year and must not be dragged along with
    /// it. It is keyed to the week, so stepping through days never refetches.
    ///
    /// Runs entirely inside `InsightsTrendAggregator`, off the main actor — a year of
    /// history and its per-week segmenting no longer has to fit inside the
    /// interaction path the way it did when this ran inline here.
    private func reloadTrends() async {
        let startedAt = Date.now
        let container = context.container
        let capturedNow = now
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try await InsightsTrendAggregator(modelContainer: container).load(endingAt: capturedNow)
            }.value
            guard !Task.isCancelled else { return }
            let allWeeks = data.weeklyTotals
            let displayWeeks = Array(allWeeks.suffix(InsightsTrends.weeks))
            trendSeries = [
                InsightsTrends.series(for: "Home", title: "Home", symbol: "house.fill", weeks: displayWeeks),
                InsightsTrends.series(for: "Sleep", title: "Sleep", symbol: "bed.double.fill", weeks: displayWeeks)
            ].filter { !$0.isEmpty }
            habits = InsightsTrends.habits(from: allWeeks)
            weeklyRhythm = data.weekdayPatterns
            // Already the completed-weeks-only fetch Week's rolling baseline needs
            // -- `InsightsTrends.range` ends before the in-progress week, so this
            // can never include a partial week. Kept as the full fetched span
            // (not sliced to a fixed count here) so the Week section can choose
            // its own baseline width without a second fetch.
            weeklyBaselineTotals = allWeeks
            Diagnostics.performance(context, subsystem: "Insights", operation: "trend history",
                                    startedAt: startedAt, itemCount: data.itemCount)
        } catch {
            // The rest of Insights is unaffected, so a trend that cannot be built is
            // simply not drawn rather than taken as a failure of the screen.
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "trend history fetch", severity: "warning")
            trendSeries = []
            habits = []
            weeklyRhythm = WeekdayPattern.empty
            weeklyBaselineTotals = []
        }
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

    /// Week/Month/Year's existing section list, unchanged. Day gets a different
    /// shape entirely -- see `dayLayout` -- because a single day answers a
    /// different question ("how did today go, what needs a look") than a period
    /// answers ("what changed, what's the pattern").
    @ViewBuilder private var standardLayout: some View {
        highlightsSection
        healthSetupSection
        donutSection
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

    /// A practical daily-review screen, not a smaller period view: what's
    /// happening right now, the day so far at a glance, a short summary, what
    /// needs attention, and — last, not first — what stood out. The donut stays
    /// reachable (its tap-to-inspect interaction is unchanged) but is no longer
    /// the lead visual; the day bar is.
    @ViewBuilder private var dayLayout: some View {
        currentActivitySection
        dayTimelineBarSection
        donutSection
        daySummarySection
        TravelInsightsCard(title: "Travel", summary: TravelInsights.make(from: daySegments))
        needsAttentionSection
        highlightsSection
        healthSetupSection
    }

    /// "How did this week compare with usual" — a different question from
    /// Month/Year's "what's the pattern," so a different layout, not a smaller
    /// one: the seven days at a glance, a scorecard, what actually changed
    /// against a rolling baseline (not just the single preceding week), and a
    /// commute summary when there's a real one to show. The donut stays
    /// reachable but demoted, same as Day.
    @ViewBuilder private var weekLayout: some View {
        weeklyStripSection
        weeklyScorecardSection
        TravelInsightsCard(title: "Travel", summary: snapshot.travel)
        weeklyRoutineChangesSection
        weeklyCommuteSection
        donutSection
        healthSetupSection
    }

    /// Month answers "what changed in my life this month?" rather than presenting
    /// the same long-term sections as Year. These cards all read the same resolved
    /// current/previous segments as the donut.
    @ViewBuilder private var monthLayout: some View {
        monthlyHeadlineSection
        monthlyScorecardSection
        TravelInsightsCard(title: "Travel", summary: snapshot.travel)
        monthlyChangesSection
        monthlyBalanceSection
        monthlyPlacesSection
        monthlyCalendarSection
        healthSetupSection
    }

    @ViewBuilder private var yearLayout: some View {
        YearInsightsView(insights: annualInsights) { area in
            let hours = annualInsights.months.reduce(0) { $0 + ($1.hours[area.name] ?? 0) }
            guard hours > 0 else { return }
            selectedSlice = TimeSlice(name: area.category, hours: hours,
                                       color: insightColor(for: area.category),
                                       symbol: insightSymbol(for: area.category), isUnlogged: false)
        }
        healthSetupSection
    }

    private var monthlyInsights: MonthlyInsights {
        MonthlyInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                             currentInterval: interval,
                             previousInterval: window.previousComparisonInterval(for: interval), now: now)
    }

    /// The Month counterpart to Week's scorecard: a short set of useful totals
    /// that stays grounded in the same resolved segments as the rest of Month
    /// Insights. Health rows remain absent when Health data is unavailable.
    private var monthlyScorecardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Month scorecard").font(.title2.bold())
            VStack(spacing: 10) {
                daySummaryRow(icon: "house.fill", label: "At Home",
                             value: formatHours(max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)))
                let categoryHours = InsightsSnapshot.categoryHours(in: snapshot.segments)
                let workHours = categoryHours["Work"] ?? 0
                if workHours > 0.01 {
                    daySummaryRow(icon: "briefcase.fill", label: "At Work", value: formatHours(workHours))
                }
                let travel = InsightsSnapshot.travelHours(in: snapshot.segments)
                if travel > 0.01 {
                    daySummaryRow(icon: "car.fill", label: "Travelling", value: formatHours(travel))
                }
                if let monthAverageNightlySleep, monthAverageNightlySleep > 0 {
                    daySummaryRow(icon: "bed.double.fill", label: "Sleep average",
                                 value: formatHours(monthAverageNightlySleep / 3600))
                }
                if let monthSteps, monthSteps > 0 {
                    let elapsedSeconds = min(now, interval.end).timeIntervalSince(interval.start)
                    let elapsedDays = max(1, Int(ceil(elapsedSeconds / 86_400)))
                    daySummaryRow(icon: "shoeprints.fill", label: "Steps",
                                 value: "\(Int(monthSteps).formatted()) total · \(Int(monthSteps / Double(elapsedDays)).formatted())/day avg")
                }
                let exercise = InsightsSnapshot.fitnessHours(in: snapshot.segments)
                if exercise > 0.01 {
                    daySummaryRow(icon: "figure.run", label: "Exercise", value: formatHours(exercise))
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-scorecard")
    }

    @ViewBuilder private var monthlyHeadlineSection: some View {
        if let headline = monthlyInsights.headline {
            VStack(alignment: .leading, spacing: 7) {
                Text("This month").font(.title2.bold())
                Text(headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Compared with last month").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-month-headline")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This month. \(headline). Compared with last month")
        }
    }

    @ViewBuilder private var monthlyChangesSection: some View {
        let changes = monthlyInsights.changes
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("What changed").font(.title2.bold())
                Text("Meaningful differences from last month").font(.subheadline).foregroundStyle(.secondary)
                ForEach(changes.prefix(6)) { change in
                    HStack(spacing: 12) {
                        Image(systemName: insightSymbol(for: change.category))
                            .foregroundStyle(insightColor(for: change.category))
                            .frame(width: 36, height: 36)
                            .background(insightColor(for: change.category).opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.category).font(.subheadline.weight(.medium))
                            Text(change.delta >= 0 ? "\(formatHours(change.delta)) more" : "\(formatHours(abs(change.delta))) less")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let percentage = change.percentage {
                            Text(monthlyPercentageText(percentage))
                                .font(.subheadline.bold().monospacedDigit())
                        } else {
                            Text("New").font(.caption.bold())
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(change.category), \(change.delta >= 0 ? "more" : "less") \(formatHours(abs(change.delta))) than last month")
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-month-changes")
        }
    }

    private func monthlyPercentageText(_ percentage: Double) -> String {
        "\(Int((abs(percentage) * 100).rounded()))%"
    }

    private var monthlyBalanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monthly balance").font(.title2.bold())
            Text("Time grouped from your activity definitions").font(.subheadline).foregroundStyle(.secondary)
            if monthlyInsights.balance.isEmpty {
                InsightEmptyRow(icon: "chart.bar.xaxis", title: "Not enough recorded activity", detail: "These groups appear once the month has usable data.")
            } else {
                ForEach(monthlyInsights.balance) { item in
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 26)
                        Text(item.name).font(.subheadline)
                        Spacer()
                        Text(formatHours(item.hours)).font(.subheadline.bold().monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name), \(formatHours(item.hours))")
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-balance")
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
                Button {
                    draftAnchorDate = anchorDate
                    choosingDate = true
                } label: {
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

    /// The Saved Place explicitly given the Home role. A fact the owner stated, not
    /// a name match — so "Homemaker Centre" was never mistaken for it, and a home
    /// saved under any other name still counts.
    private var homePlace: SavedPlace? {
        savedPlaces.first { $0.homeWorkRole == .home }
    }

    /// Mirrors `homePlace`. The Week commute summary only shows once both
    /// roles are configured — commute detection has nothing to anchor either
    /// end to otherwise.
    private var workPlace: SavedPlace? {
        savedPlaces.first { $0.homeWorkRole == .work }
    }

    /// The same live-stay concept Timeline's own current-activity card already
    /// uses (`TimelineView.current`), not a second definition of "current" —
    /// only meaningful when looking at today, since a past day has nothing
    /// still open.
    private var currentVisit: Visit? {
        guard isCurrentWindow else { return nil }
        return visits.first { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored && $0.departure == nil }
    }

    /// A compact summary, not Timeline's full card: place, activity, elapsed
    /// time, and — only when the same flags Timeline already checks say so — a
    /// "Needs checking" flag. Absent entirely rather than showing a placeholder
    /// when there is nothing currently open, the same way Timeline shows nothing
    /// extra beyond its own "waiting" state rather than a duplicate live card.
    @ViewBuilder private var currentActivitySection: some View {
        if let visit = currentVisit {
            Button { editingVisit = visit } label: {
                HStack(spacing: 14) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(visit.displayPlaceName).font(.headline).lineLimit(1)
                            if visit.needsCategorisation || visit.needsConfirmation {
                                Label("Needs checking", systemImage: "questionmark.circle.fill")
                                    .font(.caption2.bold()).foregroundStyle(.orange)
                                    .labelStyle(.iconOnly)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(visit.suspectedActivity).font(.subheadline).foregroundStyle(.secondary)
                        Text("Since \(visit.arrival.formatted(date: .omitted, time: .shortened)) · \(formattedDuration(now.timeIntervalSince(visit.arrival)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding(18)
                .lifeCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insights-current-activity-card")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Current activity: \(visit.displayPlaceName), \(visit.suspectedActivity), "
                + "since \(visit.arrival.formatted(date: .omitted, time: .shortened)), "
                + formattedDuration(now.timeIntervalSince(visit.arrival))
                + (visit.needsCategorisation || visit.needsConfirmation ? ", needs checking" : "")
            )
            .accessibilityHint("Opens the editor for this visit")
        }
    }

    /// The day's primary visual: every post-resolution segment at its true
    /// position on a fixed 24-hour scale. `daySegments` (built in
    /// `reloadInsights`) is the uncapped counterpart of `snapshot.segments`, so
    /// this bar shows the whole day, not just what has elapsed so far.
    private var dayTimelineBarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your day").font(.title2.bold())
            Text("Tap any part of the day to open it").font(.subheadline).foregroundStyle(.secondary)
            DayTimelineBar(segments: daySegments, interval: interval, now: now) { segment in
                // A commute segment has no backing Visit and nothing recorded to
                // add — the same "nothing to open" `InsightSliceEditor` already
                // treats it as for a category slice.
                guard segment.visit != nil || segment.isUnlogged else { return }
                selectedDaySegment = segment
            }
            let pastUnloggedHours = daySegments
                .filter { $0.isUnlogged && $0.end <= now }
                .reduce(0) { $0 + $1.hours }
            if pastUnloggedHours > 0.25 {
                // The honest caveat on every number on this screen, kept where the day
                // is rather than filed under the app's own plumbing. Only what has
                // already passed counts here -- the rest of today is not "unlogged",
                // it just hasn't happened.
                Text("\(formatHours(pastUnloggedHours)) of today so far is not logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-day-bar")
    }

    /// A short, factual roll-up — not a second copy of `awayFromHomeSection`'s
    /// big-number treatment, which Week/Month/Year still get. Steps and sleep
    /// are read from the `todaySteps`/`lastNightSleep` `reloadHighlights` already
    /// fetched; travel and exercise are summed straight from `daySegments`, no
    /// second HealthKit call. A value simply has no row when there's nothing to
    /// show it — no "0 steps" when Health isn't connected.
    private var daySummarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Day summary").font(.title2.bold())
            VStack(spacing: 10) {
                daySummaryRow(icon: "house.fill", label: "At Home",
                             value: formatHours(max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)))
                daySummaryRow(icon: "figure.walk.departure", label: "Away from Home",
                             value: formatHours(snapshot.awayFromHomeHours))
                let travel = InsightsSnapshot.travelHours(in: daySegments)
                if travel > 0.01 {
                    daySummaryRow(icon: "car.fill", label: "Travelling", value: formatHours(travel))
                }
                if let todaySteps, todaySteps > 0 {
                    daySummaryRow(icon: "shoeprints.fill", label: "Steps", value: Int(todaySteps).formatted())
                }
                if let lastNightSleep, lastNightSleep.totalSleep > 0 {
                    daySummaryRow(icon: "bed.double.fill", label: "Last night’s sleep",
                                 value: formatHours(lastNightSleep.totalSleep / 3600))
                }
                let workout = InsightsSnapshot.fitnessHours(in: daySegments)
                if workout > 0.01 {
                    daySummaryRow(icon: "figure.run", label: "Exercise", value: formatHours(workout))
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-day-summary")
    }

    private func daySummaryRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private enum NeedsAttentionItem: Identifiable {
        case review(ReviewQueue.Entry)
        case gap(InsightSegment)

        var id: String {
            switch self {
            case .review(let entry): "review-\(entry.id)"
            case .gap(let segment): "gap-\(segment.start.timeIntervalSinceReferenceDate)"
            }
        }
    }

    /// Two existing detection paths, not new ones: `ReviewQueue.entries` is the
    /// exact function/ordering Timeline's own review card already uses, and
    /// `InsightsSnapshot.meaningfulGaps` reads the same `daySegments` the day bar
    /// draws. Capped short — this names what needs a look, it does not replace
    /// the day bar as the place to browse everything.
    private var needsAttentionItems: [NeedsAttentionItem] {
        let review = ReviewQueue.entries(in: visits, now: now).prefix(3).map { NeedsAttentionItem.review($0) }
        let gaps = InsightsSnapshot.meaningfulGaps(in: daySegments, before: now).prefix(2).map { NeedsAttentionItem.gap($0) }
        return Array((review + gaps).prefix(4))
    }

    @ViewBuilder private var needsAttentionSection: some View {
        let items = needsAttentionItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Needs your attention").font(.title2.bold())
                VStack(spacing: 10) {
                    ForEach(items) { needsAttentionRow($0) }
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-needs-attention")
        }
    }

    @ViewBuilder
    private func needsAttentionRow(_ item: NeedsAttentionItem) -> some View {
        switch item {
        case .review(let entry):
            Button { editingVisit = entry.visit } label: {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.visit.displayPlaceName).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(entry.reason.prompt).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.visit.displayPlaceName), \(entry.reason.prompt)")
            .accessibilityHint("Opens the editor for this visit")
        case .gap(let segment):
            Button {
                addVisitRange = DateInterval(start: segment.start, end: segment.end)
                isAddingVisit = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing logged").font(.subheadline.weight(.medium))
                        Text("\(segment.start.formatted(date: .omitted, time: .shortened))–\(segment.end.formatted(date: .omitted, time: .shortened)) · \(formatHours(segment.hours))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Nothing logged, \(formatHours(segment.hours)), from \(segment.start.formatted(date: .omitted, time: .shortened)) to \(segment.end.formatted(date: .omitted, time: .shortened))")
            .accessibilityHint("Add a visit for this time")
        }
    }

    /// The seven-day glance: tapping a column reuses the window picker
    /// `InsightsView` already has (`window = .day`, `anchorDate = <that day>`)
    /// rather than pushing a second screen for what is already reachable from
    /// this one.
    private var weeklyStripSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This week").font(.title2.bold())
            Text("Tap a day to open it in Day Insights").font(.subheadline).foregroundStyle(.secondary)
            WeeklyStrip(days: weekDays, today: now) { date in
                anchorDate = date
                window = .day
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-weekly-strip")
    }

    /// Reuses `daySummaryRow` from the Day layout — the same label/value row
    /// style, just a different set of facts. A row is simply absent when
    /// there's nothing to show it (no Health access, nothing at Work this
    /// week) rather than a placeholder zero.
    private var weeklyScorecardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Week scorecard").font(.title2.bold())
            VStack(spacing: 10) {
                daySummaryRow(icon: "house.fill", label: "At Home",
                             value: formatHours(max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)))
                let categoryHours = InsightsSnapshot.categoryHours(in: snapshot.segments)
                let workHours = categoryHours["Work"] ?? 0
                if workHours > 0.01 {
                    daySummaryRow(icon: "briefcase.fill", label: "At Work", value: formatHours(workHours))
                }
                let travel = InsightsSnapshot.travelHours(in: snapshot.segments)
                if travel > 0.01 {
                    daySummaryRow(icon: "car.fill", label: "Travelling", value: formatHours(travel))
                }
                if let weekAverageNightlySleep, weekAverageNightlySleep > 0 {
                    daySummaryRow(icon: "bed.double.fill", label: "Sleep average",
                                 value: formatHours(weekAverageNightlySleep / 3600))
                }
                if let weekSteps, weekSteps > 0 {
                    // Divided by the days actually elapsed in the week so far,
                    // not always 7 -- a Tuesday viewing of the current week
                    // shouldn't have its daily average diluted by Wed–Sun,
                    // which haven't happened yet.
                    let elapsedSeconds = min(now, interval.end).timeIntervalSince(interval.start)
                    let elapsedDays = max(1, min(7, Int(ceil(elapsedSeconds / 86_400))))
                    daySummaryRow(icon: "shoeprints.fill", label: "Steps",
                                 value: "\(Int(weekSteps).formatted()) total · \(Int(weekSteps / Double(elapsedDays)).formatted())/day avg")
                }
                let exercise = InsightsSnapshot.fitnessHours(in: snapshot.segments)
                if exercise > 0.01 {
                    daySummaryRow(icon: "figure.run", label: "Exercise", value: formatHours(exercise))
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-week-scorecard")
    }

    /// How many of `weeklyBaselineTotals`' completed weeks count as "usual" —
    /// within the requested 6–8, fixed rather than adaptive so the comparison
    /// basis stated in the section subtitle is always literally true.
    private static let weekBaselineWeeks = 8
    /// Sleep already has its own scorecard row; Home is deliberately *not*
    /// excluded here even though `InsightsTrends.habitExclusions` excludes it
    /// from the habits card — that exclusion is about presence never being
    /// news ("everyone is home every week"), but a change in *how much* time
    /// was spent at Home is exactly what this section exists to say.
    private static let weekRoutineChangeExclusions: Set<String> = ["Sleep", "Unlogged", "Uncategorised"]

    private struct WeekRoutineChange: Identifiable {
        let category: String
        let latest: Double
        let baseline: Double
        var id: String { category }
        var delta: Double { latest - baseline }
    }

    /// This week's per-category hours appended to the rolling baseline and
    /// run through the exact same `InsightsTrends.series` math the trend
    /// lines already use — the same "mean of the *nonzero* earlier weeks"
    /// baseline, so one quiet holiday week can't silently drag a category's
    /// usual down without it showing up as a real change either.
    private var weekRoutineChanges: [WeekRoutineChange] {
        guard !weeklyBaselineTotals.isEmpty else { return [] }
        let thisWeek = WeeklyTotals(weekStart: interval.start, hours: InsightsSnapshot.categoryHours(in: snapshot.segments))
        let combined = Array(weeklyBaselineTotals.suffix(Self.weekBaselineWeeks)) + [thisWeek]
        guard combined.count > 1 else { return [] }
        let categories = Set(combined.flatMap { $0.hours.keys }).subtracting(Self.weekRoutineChangeExclusions)
        let changes = categories.compactMap { category -> WeekRoutineChange? in
            let series = InsightsTrends.series(for: category, title: category,
                                               symbol: insightSymbol(for: category), weeks: combined)
            guard series.baseline > 0 else { return nil }
            let change = abs(series.latest - series.baseline) / series.baseline
            guard change >= InsightsTrends.noticeableChange else { return nil }
            return WeekRoutineChange(category: category, latest: series.latest, baseline: series.baseline)
        }
        return Array(changes.sorted { abs($0.delta) > abs($1.delta) }.prefix(3))
    }

    @ViewBuilder private var weeklyRoutineChangesSection: some View {
        let changes = weekRoutineChanges
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("What changed").font(.title2.bold())
                Text("Compared with your last \(Self.weekBaselineWeeks) weeks")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    ForEach(changes) { change in
                        HStack(spacing: 14) {
                            Image(systemName: change.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.headline).foregroundStyle(change.delta >= 0 ? .orange : .blue)
                                .frame(width: 36, height: 36)
                                .background((change.delta >= 0 ? Color.orange : Color.blue).opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.category).font(.subheadline.weight(.medium))
                                Text("\(formatHours(change.latest)) vs usual \(formatHours(change.baseline))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(change.category), \(formatHours(change.latest)) this week, usually \(formatHours(change.baseline))")
                    }
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-week-routine-changes")
        }
    }

    /// `nil` whenever there isn't a real commute to summarise: no Home/Work
    /// roles configured, or the week's own confidence gate
    /// (`InsightsSnapshot.weekCommuteSummary`) isn't met. `commutes` is
    /// recomputed here rather than cached — it runs over `visits`, already
    /// bounded to this period, the same cost `CommuteDetection` already pays
    /// elsewhere on this screen.
    private var weeklyCommuteSummary: InsightsSnapshot.WeekCommuteSummary? {
        guard homePlace != nil, workPlace != nil else { return nil }
        let commutes = CommuteDetection.commutes(in: visits, savedPlaces: savedPlaces, now: now)
        let baselineWeeks = Array(weeklyBaselineTotals.suffix(Self.weekBaselineWeeks))
        let nonzero = baselineWeeks.map { $0.hours[CommuteDetection.categoryName] ?? 0 }.filter { $0 > 0 }
        let baselineHours = nonzero.isEmpty ? nil : nonzero.reduce(0, +) / Double(nonzero.count)
        return InsightsSnapshot.weekCommuteSummary(commutes: commutes, weekInterval: interval, baselineHours: baselineHours)
    }

    @ViewBuilder private var weeklyCommuteSection: some View {
        if let summary = weeklyCommuteSummary {
            VStack(alignment: .leading, spacing: 14) {
                Text("Commute").font(.title2.bold())
                VStack(spacing: 10) {
                    daySummaryRow(icon: "calendar", label: "Commute days", value: "\(summary.days)")
                    daySummaryRow(icon: "clock.fill", label: "Total time", value: formatHours(summary.totalHours))
                    daySummaryRow(icon: "gauge.medium", label: "Average", value: "\(Int(summary.averageMinutes.rounded()))m")
                    if let change = summary.changeFromUsual {
                        let direction = change >= 0 ? "more" : "less"
                        daySummaryRow(
                            icon: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                            label: "Vs usual", value: "\(formatHours(abs(change))) \(direction)"
                        )
                    }
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-week-commute")
        }
    }

    private var monthlyPlacesSection: some View {
        let story = monthlyInsights
        return VStack(alignment: .leading, spacing: 16) {
            Text("Place story").font(.title2.bold())
            monthlyPlaceList(title: "Most time", places: story.placesByTime) { formatHours($0.hours) }
            monthlyPlaceList(title: "Most visits", places: story.placesByVisits) { "\($0.visits) \($0.visits == 1 ? "visit" : "visits")" }
            monthlyPlaceList(title: "New this month", places: story.newPlaces,
                             empty: "No new places with enough recorded history.") { formatHours($0.hours) }
            if let place = story.biggestPlaceChange {
                monthlyPlaceList(title: "Biggest change from last month", places: [place]) {
                    "\($0.delta >= 0 ? "+" : "−")\(formatHours(abs($0.delta))) vs last month"
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-places")
    }

    @ViewBuilder private func monthlyPlaceList(title: String, places: [MonthlyInsights.PlaceStory],
                                               empty: String = "No places recorded yet.",
                                               detail: @escaping (MonthlyInsights.PlaceStory) -> String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            if places.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(places) { place in
                    NavigationLink { PlaceHistoryDetail(placeName: place.name) } label: {
                        HStack(spacing: 10) {
                            ActivityIcon(activity: place.activity, context: place.name,
                                         color: insightColor(for: place.category), size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(place.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(detail(place)).font(.caption.bold().monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(place.name), \(detail(place))")
                }
            }
        }
    }

    private var monthlyCalendarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Month at a glance").font(.title2.bold())
            Text("Tap any day to open Day Insights").font(.subheadline).foregroundStyle(.secondary)
            MonthCalendarHeatmap(days: monthDays) { date in
                anchorDate = date
                window = .day
            }
            HStack(spacing: 8) {
                Circle().fill(.secondary.opacity(0.12)).frame(width: 10, height: 10)
                Text("Little or nothing recorded").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-month-calendar")
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

    private func reloadAnnualHealth() async {
        guard window == .year else { return }
        // Let the Year shell render before its archive-scale place-history work.
        await Task.yield()
        let historical = annualHistoricalPlaces()
        annualInsights = makeAnnualInsights(health: annualHealth, historicalOverride: historical)
        let year = interval
        let calendar = Calendar.current
        var sleep: [Double?] = []
        var steps: [Double?] = []
        var cursor = year.start
        var hasHealthData = false
        while cursor < year.end {
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            let monthEnd = min(next, min(year.end, now))
            if monthEnd <= cursor {
                sleep.append(nil)
                steps.append(nil)
            } else {
                let month = DateInterval(start: cursor, end: monthEnd)
                let sleepValue: Double?
                if let summary = await activityData.sleepSummary(for: month) {
                    sleepValue = summary.totalSleep / max(1, month.duration / 86_400) / 3600
                } else {
                    sleepValue = nil
                }
                let stepValue = await activityData.stepCount(for: month)
                sleep.append(sleepValue)
                steps.append(stepValue)
                hasHealthData = hasHealthData || sleepValue != nil || stepValue != nil
            }
            cursor = next
        }
        annualHealth = AnnualInsights.HealthMetrics(monthlySleepHours: sleep,
                                                    monthlySteps: steps,
                                                    healthDataAvailable: hasHealthData)
        annualInsights = makeAnnualInsights(health: annualHealth, historicalOverride: historical)
    }

    private func annualHistoricalPlaces() -> [Visit] {
        guard window == .year else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival < interval.start },
            sortBy: [SortDescriptor(\.arrival)]
        ))) ?? []
        let locationVisits = all.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        return all.filter {
            $0.arrival < interval.start &&
            ActivityLocationPolicy.shouldShowInInsights($0, locationVisits: locationVisits, now: now)
        }
    }

    private func makeAnnualInsights(health: AnnualInsights.HealthMetrics,
                                   historicalOverride: [Visit]? = nil) -> AnnualInsights {
        let historical = historicalOverride ?? annualHistoricalPlaces()
        return AnnualInsights.make(current: snapshot.segments,
                                   previous: snapshot.previousSegments,
                                   yearInterval: interval, now: now,
                                   historicalPlaceVisits: historical, health: health)
    }

    private func reloadInsights() {
        // Fetch only the selected and comparison periods. Keeping the nine-year journal
        // archive out of memory is substantially cheaper than trimming useful history.
        let currentInterval = window.interval(containing: anchorDate)
        let fetchEnd = currentInterval.contains(now) ? now : currentInterval.end
        let analysisInterval = DateInterval(start: currentInterval.start, end: fetchEnd)
        let comparisonBasis = window == .month && currentInterval.contains(now) ? currentInterval : analysisInterval
        let fetchStart = window.previousComparisonInterval(for: comparisonBasis).start
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
        // Commute detection now reads every roled place, not just Home — moving Work
        // or clearing its role changes what counts as commuting just as much as Home
        // moving does, and a stale snapshot would not know either.
        let rolesKey = savedPlaces.compactMap { place -> String? in
            guard let role = place.homeWorkRole else { return nil }
            return "\(role.rawValue):\(place.latitude),\(place.longitude),\(place.radius)"
        }.sorted().joined(separator: "|")
        let cacheKey = "\(window.rawValue)|\(anchorDate.timeIntervalSinceReferenceDate)|\(Int(now.timeIntervalSinceReferenceDate / 60))|\(visits.count)|\(homeKey)|\(rolesKey)"
        snapshot = snapshotCache.snapshot(key: cacheKey, generation: aggregationGeneration) {
            InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now,
                                  home: home, savedPlaces: savedPlaces)
        }
        if window == .year {
            // Render the current year's story immediately; archive-derived place
            // history is filled by the deferred annual task after the first frame.
            annualInsights = makeAnnualInsights(health: annualHealth, historicalOverride: [])
        }
        Diagnostics.budget(context, subsystem: "Insights", operation: "\(window.rawValue) snapshot rebuild",
                           startedAt: startedAt,
                           budget: Diagnostics.PerformanceBudget.insights(window: window),
                           itemCount: visits.count)

        // The day bar's own segments, over the *uncapped* calendar day rather
        // than `snapshot.analysisInterval` (which stops at `now` for today) --
        // built from the exact same `InsightsSnapshot.makeSegments` the donut
        // and header total already use, just given the full range. Nothing
        // beyond `now` has a visit yet, so that portion resolves to trailing
        // `.unlogged` segments on its own; the bar renders those distinctly
        // rather than reporting them as missing time.
        if window == .day {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            daySegments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                        range: interval, now: now, savedPlaces: savedPlaces)
        } else {
            daySegments = []
        }

        // The weekly strip's seven columns, one `makeSegments` call each, all
        // over `visits` already fetched for this period -- no new query. Each
        // day's segments are exactly what opening that day in Day Insights
        // would build, so the strip can never disagree with the screen it
        // links to.
        if window == .week {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            let calendar = Calendar.current
            var days: [WeeklyStrip.Day] = []
            var dayStart = interval.start
            while dayStart < interval.end {
                let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? interval.end, interval.end)
                guard dayEnd > dayStart else { break }
                let dayInterval = DateInterval(start: dayStart, end: dayEnd)
                let segments = InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                             range: dayInterval, now: now, savedPlaces: savedPlaces)
                days.append(WeeklyStrip.Day(date: dayStart, segments: segments))
                dayStart = dayEnd
            }
            weekDays = days
        } else {
            weekDays = []
        }

        if window == .month {
            let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            monthDays = MonthlyInsights.daySummaries(
                segments: InsightsSnapshot.makeSegments(visits: visits, locationVisits: locationVisits,
                                                        range: interval, now: now, savedPlaces: savedPlaces),
                interval: interval, now: now
            )
        } else {
            monthDays = []
        }
    }

    // Both derived from `snapshot.segments` -- the exact post-resolution slivers
    // the donut and its header total are built from -- rather than re-filtering
    // raw visits. See InsightsSnapshot.sliceRows for why: a raw Visit.duration
    // can overlap another record's, and summing those independently is what let
    // the row list disagree with the header it sits under.
    private func sliceRows(for slice: TimeSlice) -> [SliceRow] {
        guard !slice.isUnlogged else { return [] }
        return InsightsSnapshot.sliceRows(forCategory: slice.name, segments: snapshot.segments,
                                          interval: snapshot.analysisInterval, now: snapshot.generatedAt)
    }

    private func sliceRows(for place: PlaceTotal) -> [SliceRow] {
        InsightsSnapshot.sliceRows(forPlace: place.name, segments: snapshot.segments,
                                   interval: snapshot.analysisInterval, now: snapshot.generatedAt)
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
