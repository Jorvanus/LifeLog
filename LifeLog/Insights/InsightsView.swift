import SwiftUI
import SwiftData
import Charts
import MapKit
import UIKit

/// The full Insights snapshot is driven by data and the selected period, never by
/// a presentation-only clock tick. Live elapsed labels use their own small view.
enum InsightsSnapshotRefreshReason: Sendable {
    case initial
    case selectedWindowChanged
    case selectedDateChanged
    case scopeChanged
    case storeGenerationChanged
    case healthGenerationChanged
    case currentDayForeground
    case minuteClockTick

    var rebuildsSnapshot: Bool {
        switch self {
        case .minuteClockTick:
            false
        case .initial, .selectedWindowChanged, .selectedDateChanged, .scopeChanged,
             .storeGenerationChanged, .healthGenerationChanged, .currentDayForeground:
            true
        }
    }
}

struct InsightsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let activityData: ActivityDataService
    /// The saved place called Home, which is what "time away from Home" is measured
    /// against. Queried rather than matched by name — see `InsightsSnapshot.HomePlace`.
    @Query private var savedPlaces: [SavedPlace]
    @State private var visits: [Visit] = []
    @State private var window: InsightWindow = .day
    @AppStorage(InsightsScope.storageKey) private var scopeRawValue = InsightsScope.allHistory.rawValue
    @State private var anchorDate = Date.now
    @State private var choosingDate = false
    @State private var draftAnchorDate = Date.now
    /// Every "browse deeper" push -- activity, sleep, group, place, comparison,
    /// visit -- goes through this one path and `InsightsRoute`, instead of the
    /// per-destination `@State selected…` + `.sheet` pairs this replaced. The
    /// period (`window`/`anchorDate`) and the scroll position both live above this
    /// on `InsightsView` itself, which a push never tears down, so returning from
    /// any depth lands back on the same period and roughly the same scroll offset
    /// for free -- see `InsightsRoute`'s own doc comment for the sheet-inside-sheet
    /// problem this replaces.
    @State private var path = NavigationPath()
    @State private var now = Date.now
    @State private var snapshot = InsightsSnapshot.empty
    @State private var exportFile: TrendExportFile?
    @State private var aggregationGeneration = 0
    @State private var snapshotCache = InsightsSnapshotCache()
    /// The one archive-wide reader every retrospective (place history, year-over-
    /// year, Year's historical places) goes through, so that work runs off the
    /// main actor instead of blocking the interaction path.
    @State private var archiveReader: VisitArchiveReader?
    /// True while Year's "new this year"/"not visited this year" comparison is
    /// still reading the archive — see `YearPlaceStoryCard.placesLoading`.
    @State private var annualPlacesLoading = false
    @State private var highlights: [DayHighlight] = []
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
    @State private var healthSummary: HealthInsightsSummary?
    @State private var previousHealthSummary: HealthInsightsSummary?

    private var interval: DateInterval { window.interval(containing: anchorDate) }
    private var insightsScope: InsightsScope {
        InsightsScope(rawValue: scopeRawValue) ?? .allHistory
    }
    private var scopeSubtitle: String {
        "\(insightsScope.title) · \(formatHours(snapshot.loggedHours)) recorded hours"
    }
    private var sleepRefreshKey: String {
        "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
    }
    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: InsightsRoute.self) { route in
                routeDestination(route)
            }
            .sheet(item: $selectedDaySegment, onDismiss: { reloadInsights() }) { segment in
                if let visit = segment.visit {
                    NavigationStack { VisitEditor(visit: visit) }
                        .presentationDetents([.large])
                } else {
                    NavigationStack {
                        InsightGapDetailView(gap: segment, periodTitle: periodTitle)
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $editingVisit, onDismiss: { reloadInsights() }) { visit in
                NavigationStack { VisitEditor(visit: visit) }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isAddingVisit, onDismiss: { reloadInsights() }) {
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
                reloadInsights(reason: .initial)
            }
            .task(id: sleepRefreshKey) {
                // Historical month/year sleep is already represented by imported
                // Health visits. Re-querying and re-importing the entire period while
                // changing tabs delays the first useful frame, so refresh only the
                // short windows where a newly synced night can affect the screen.
                guard insightsScope.includesHealthData, window == .day || window == .week else { return }
                let queryEnd = interval.contains(now) ? now : interval.end
                let queryInterval = DateInterval(start: interval.start, end: queryEnd)
                _ = await activityData.refreshSleep(for: queryInterval, context: context)
                guard !Task.isCancelled else { return }
                aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration()
                reloadInsights()
            }
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                Task {
                    aggregationGeneration = await InsightsAggregationActor.shared.currentGeneration()
                    reloadInsights(reason: .storeGenerationChanged)
                }
            }
            .onChange(of: window) { _, _ in reloadInsights(reason: .selectedWindowChanged) }
            .onChange(of: anchorDate) { _, _ in reloadInsights(reason: .selectedDateChanged) }
            .onChange(of: scopeRawValue) { _, _ in reloadInsights(reason: .scopeChanged) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, window == .day,
                      Calendar.current.isDate(anchorDate, inSameDayAs: .now) else { return }
                // The foreground is the one time a current-day total can legitimately
                // have changed without a store notification (for example across midnight).
                reloadInsights(reason: .currentDayForeground)
            }
            .task(id: highlightKey) { await reloadHighlights() }
            .task(id: trendKey) {
                guard window != .day else { return }
                await reloadTrends()
            }
            .task(id: annualKey) {
                guard window == .year else { return }
                await reloadAnnualHealth()
            }
            .task(id: healthSummaryKey) {
                guard window != .year else { return }
                await reloadHealthSummary()
            }
        }
    }

    /// The trends only move when the week does, so stepping through days inside one
    /// week never re-reads a season of history.
    private var trendKey: String {
        "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(aggregationGeneration)"
    }

    private var annualKey: String {
        "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(aggregationGeneration)"
    }

    private var healthSummaryKey: String {
        "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(aggregationGeneration)"
    }

    private func reloadHealthSummary() async {
        let requestKey = healthSummaryKey
        guard insightsScope.includesHealthData else {
            healthSummary = nil
            previousHealthSummary = nil
            return
        }
        let end = interval.contains(now) ? now : interval.end
        let current = DateInterval(start: interval.start, end: max(interval.start, end))
        let summary = await activityData.healthSummary(for: current)
        guard !Task.isCancelled, requestKey == healthSummaryKey else { return }
        healthSummary = summary
        if window == .month {
            let previous = window.previousComparisonInterval(for: interval)
            let previousSummary = await activityData.healthSummary(for: previous)
            guard !Task.isCancelled, requestKey == healthSummaryKey else { return }
            previousHealthSummary = previousSummary
        } else {
            previousHealthSummary = nil
        }
    }

    /// Rebuilds highlights only when its selected period or source data changes.
    private var highlightKey: String {
        let leadingPlace = snapshot.placeTotals.first
        return "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(snapshot.comparisons.count)-\(leadingPlace?.id ?? "none")-\(leadingPlace?.hours ?? 0)"
    }

    private func reloadHighlights() async {
        let requestKey = highlightKey
        var found: [DayHighlight] = []
        let queryEnd = interval.contains(now) ? now : interval.end
        let dayInterval = DateInterval(start: interval.start, end: max(interval.start, queryEnd))

        if window == .day {
            weekSteps = nil
            weekAverageNightlySleep = nil
            // Stashed here, not re-queried by the Day summary card: this is
            // already the one place Insights asks HealthKit for today's steps
            // and last night's sleep.
            let steps = insightsScope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
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
            let night = insightsScope.includesHealthData ? await activityData.sleepSummary(for: dayInterval) : nil
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
            weekSteps = insightsScope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
            weekAverageNightlySleep = insightsScope.includesHealthData
                ? await activityData.averageNightlySleep(before: interval.end, nights: 7)
                : nil
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
            monthSteps = insightsScope.includesHealthData ? await activityData.stepCount(for: dayInterval) : nil
            let elapsedSeconds = max(0, dayInterval.duration)
            let elapsedNights = max(1, Int(ceil(elapsedSeconds / 86_400)))
            monthAverageNightlySleep = insightsScope.includesHealthData
                ? await activityData.averageNightlySleep(before: dayInterval.end, nights: elapsedNights)
                : nil
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
            let history = await placeHistory(matching: place.name)
            guard !Task.isCancelled, requestKey == highlightKey else { return }
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
        if let highlight = await yearOverYearHighlight() {
            found.append(highlight)
        }
        guard !Task.isCancelled, requestKey == highlightKey else { return }
        // Only `dayLayout` ever reads this (`highlights.first`), and only for
        // `window == .day` -- capped at three deliberately, a daily review
        // screen names what stood out rather than repeating every comparison
        // available. Still computed for every window, unread the rest of the
        // time; the underlying fetches already run off the main actor and are
        // bounded, so this is left alone rather than gating it on `window`.
        let ordered = variedHighlights(found)
        highlights = window == .day ? Array(ordered.prefix(3)) : ordered
    }

    private func archive() -> VisitArchiveReader {
        let reader = archiveReader ?? VisitArchiveReader(modelContainer: context.container)
        archiveReader = reader
        return reader
    }

    /// Every visit at places matching this name, unscoped by date — the archive
    /// retrospectives need to know what happened before the window being looked
    /// at, not just within it. Bounded to history before the selected period,
    /// scoped the same way as the visible place story, and run on the shared
    /// archive-reader actor so this stays off the interaction path regardless
    /// of how far back a match goes.
    private func placeHistory(matching name: String) async -> [PlaceVisitOccurrence] {
        do {
            return try await archive().placeOccurrences(matching: name, before: interval.end, scope: insightsScope)
        } catch is CancellationError {
            return []
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "place retrospective fetch", severity: "warning")
            return []
        }
    }

    /// This period's total against the same period a year ago. Already a narrow,
    /// date-scoped fetch rather than a whole-archive one; run on the archive
    /// actor so it never blocks the interaction path even so.
    private func yearOverYearHighlight() async -> DayHighlight? {
        guard let yearAgoAnchor = Calendar.current.date(byAdding: .year, value: -1, to: anchorDate) else { return nil }
        let yearAgoInterval = window.interval(containing: yearAgoAnchor)
        do {
            let yearAgoHours = try await archive().loggedHours(in: yearAgoInterval, scope: insightsScope, now: now)
            return ArchiveRetrospectives.yearOverYear(loggedHours: snapshot.loggedHours,
                                                       yearAgoHours: yearAgoHours, window: window)
        } catch is CancellationError {
            return nil
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "year-over-year fetch", severity: "warning")
            return nil
        }
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
        if insightsScope.includesHealthData &&
            (needsHealthSetup || activityData.ui.lastImport != nil || healthSummary?.hasData != nil) {
            if let healthSummary, healthSummary.hasData {
                HealthOverviewCard(summary: healthSummary, previous: previousHealthSummary,
                                   interval: interval, periodTitle: periodTitle, activityData: activityData)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Apple Health", systemImage: "heart.text.square")
                        .font(.headline)
                    Text(needsHealthSetup
                         ? "Connect Apple Health to add steps, sleep, and workouts to Insights."
                         : "Apple Health is connected, but there is no data for this period.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let lastImport = activityData.ui.lastImport {
                        Text("Last successful Health import: \(lastImport.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !activityData.ui.unaskedTypes.isEmpty {
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
                .padding(20)
                .lifeCard()
                .accessibilityIdentifier("insights-health-setup")
            }
        }
    }

    private var needsHealthSetup: Bool {
        activityData.ui.authorizationStatus != "Connected" && activityData.ui.authorizationStatus != "Unavailable on this device"
    }

    private func openAppleHealth() {
        guard let healthURL = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(healthURL) { opened in
            if !opened, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
        }
    }

    private func openCategory(_ name: String) {
        let matching = snapshot.segments.filter {
            !$0.isUnlogged && ($0.category.caseInsensitiveCompare(name) == .orderedSame ||
                               $0.activity.caseInsensitiveCompare(name) == .orderedSame)
        }
        let hours = matching.reduce(0) { $0 + $1.hours }
        guard hours > 0 else { return }
        path.append(InsightsRoute.activity(name: name, isUnlogged: false))
    }

    private func openSleep() {
        let hours = snapshot.segments.filter(\.isSleep).reduce(0) { $0 + $1.hours }
        guard hours > 0 else { return }
        path.append(InsightsRoute.sleep)
    }

    /// The donut's own selection: unlike `openCategory`/`openSleep`, which are
    /// reached from a named button and already know which of the two they mean,
    /// a tapped wedge only carries a display name, so this keeps the
    /// name-contains-"sleep" branch the old `$selectedSlice` sheet used to have.
    private func pushSlice(_ slice: TimeSlice) {
        guard !slice.isUnlogged else { return }
        if slice.name.localizedCaseInsensitiveContains("sleep") {
            path.append(InsightsRoute.sleep)
        } else {
            path.append(InsightsRoute.activity(name: slice.name, isUnlogged: slice.isUnlogged))
        }
    }

    private func openComparison(_ change: MonthlyInsights.ActivityChange) {
        path.append(InsightsRoute.comparison(name: change.category, hours: change.hours,
                                             previousHours: change.previousHours, delta: change.delta))
    }

    /// Loads the season of trend history Week's rolling baseline needs.
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
        let requestKey = trendKey
        let container = context.container
        let capturedNow = now
        let capturedScope = insightsScope
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try await InsightsTrendAggregator(modelContainer: container).load(
                    endingAt: capturedNow, scope: capturedScope
                )
            }.value
            guard !Task.isCancelled, requestKey == trendKey else { return }
            // Already the completed-weeks-only fetch Week's rolling baseline needs
            // -- `InsightsTrends.range` ends before the in-progress week, so this
            // can never include a partial week. Kept as the full fetched span
            // (not sliced to a fixed count here) so the Week section can choose
            // its own baseline width without a second fetch.
            weeklyBaselineTotals = data.weeklyTotals
            Diagnostics.performance(context, subsystem: "Insights", operation: "trend history",
                                    startedAt: startedAt, itemCount: data.itemCount)
        } catch {
            // The rest of Insights is unaffected, so a trend that cannot be built is
            // simply not drawn rather than taken as a failure of the screen.
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "trend history fetch", severity: "warning")
            weeklyBaselineTotals = []
        }
    }

    /// A practical daily-review screen, not a smaller period view: what's
    /// happening right now, the day so far at a glance, a short summary, what
    /// needs attention, and — last, not first — what stood out. The donut stays
    /// reachable (its tap-to-inspect interaction is unchanged) but is no longer
    /// the lead visual; the day bar is.
    @ViewBuilder private var dayLayout: some View {
        DayInsightsView(
            currentActivity: dayCurrentActivity,
            timelineSegments: daySegments,
            interval: interval,
            now: now,
            metrics: dayMetricPresentations,
            attentionItems: dayAttentionPresentations,
            highlight: highlights.first,
            travel: TravelInsights.make(from: daySegments),
            onOpenCurrentActivity: { editingVisit = currentVisit },
            onOpenTimelineSegment: openDayTimelineSegment,
            onMetric: openDayMetric,
            onAttention: openDayAttention
        )
        donutSection
        unloggedTimeReviewLink
        healthSetupSection
    }

    /// "How did this week compare with usual" — a different question from
    /// Month/Year's "what's the pattern," so a different layout, not a smaller
    /// one: the seven days at a glance, a scorecard, what actually changed
    /// against a rolling baseline (not just the single preceding week), and a
    /// commute summary when there's a real one to show. The donut stays
    /// reachable but demoted, same as Day.
    @ViewBuilder private var weekLayout: some View {
        WeekInsightsView(
            weekDays: weekDays, now: now, selectedDate: anchorDate,
            yourWeekMetrics: weeklyYourWeekMetrics, groupTotals: InsightsSnapshot.categoryHours(in: snapshot.segments),
            periodTitle: periodTitle, analysisInterval: snapshot.analysisInterval, segments: snapshot.segments,
            travel: snapshot.travel, commuteSummary: weeklyCommuteSummary, routineChanges: weekRoutineChanges,
            onSelectDay: { date in anchorDate = date; window = .day }
        )
        donutSection
        unloggedTimeReviewLink
        healthSetupSection
    }

    /// Month answers "what changed in my life this month?" rather than presenting
    /// the same long-term sections as Year. These cards all read the same resolved
    /// current/previous segments as the donut.
    @ViewBuilder private var monthLayout: some View {
        MonthInsightsView(
            insights: monthlyInsights, comparisonSubtitle: monthlyComparisonSubtitle,
            heroMetrics: monthlyHeroMetrics, monthDays: monthDays,
            periodTitle: periodTitle, analysisInterval: snapshot.analysisInterval, segments: snapshot.segments,
            now: snapshot.generatedAt, onOpenCategory: openCategory, onOpenComparison: openComparison,
            onSelectDay: { date in anchorDate = date; window = .day }
        )
        healthSetupSection
    }

    @ViewBuilder private var yearLayout: some View {
        YearInsightsView(insights: annualInsights, openGroup: { row in
            guard row.totalHours > 0, !row.foldedGroups.isEmpty else { return }
            path.append(InsightsRoute.group(title: row.group, groups: row.foldedGroups))
        }, openPlace: { place in
            path.append(InsightsRoute.place(name: place.name))
        }, period: snapshot.analysisInterval, placesLoading: annualPlacesLoading)
        healthSetupSection
    }

    private var monthlyInsights: MonthlyInsights {
        MonthlyInsights.make(current: snapshot.segments, previous: snapshot.previousSegments,
                             currentInterval: interval,
                             previousInterval: window.previousComparisonInterval(for: interval), now: now)
    }

    private var monthlyComparisonSubtitle: String {
        let previous = window.previousComparisonInterval(for: interval)
        return "Compared with \(previous.start.formatted(.dateTime.month(.wide)))"
    }

    private func monthlyChangeDetail(current: Double, previous: Double, unit: String = "") -> String {
        guard previous > 0 else { return "This month" }
        let delta = current - previous
        guard abs(delta) >= MonthlyInsights.minimumAbsoluteChange,
              abs(delta) / previous >= MonthlyInsights.minimumPercentageChange else {
            return "This month"
        }
        let direction = delta >= 0 ? "more" : "less"
        return "\(formatHours(abs(delta)))\(unit) \(direction) than last month"
    }

    private var monthAverageDailySteps: Double? {
        guard let monthSteps, monthSteps > 0 else { return nil }
        let queryEnd = interval.contains(now) ? now : interval.end
        let elapsedDays = max(1, Int(ceil(max(0, queryEnd.timeIntervalSince(interval.start)) / 86_400)))
        return monthSteps / Double(elapsedDays)
    }

    private var monthlyHeroMetrics: [MonthlyHeroMetric] {
        let currentCategories = InsightsSnapshot.categoryHours(in: snapshot.segments)
        let previousCategories = InsightsSnapshot.categoryHours(in: snapshot.previousSegments)
        let currentLogged = snapshot.loggedHours
        let previousLogged = snapshot.previousSegments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let currentAway = max(0, currentLogged - currentCategories["Home", default: 0])
        let previousAway = max(0, previousLogged - previousCategories["Home", default: 0])
        var metrics: [MonthlyHeroMetric] = []

        if currentAway > 0.01 {
            metrics.append(.init(id: "away", icon: "figure.walk.departure", title: "Away from Home",
                                 value: formatHours(currentAway), detail: monthlyChangeDetail(current: currentAway, previous: previousAway)))
        }
        if let work = currentCategories["Work"], work > 0.01 {
            metrics.append(.init(id: "work", icon: "briefcase.fill", title: "Work", value: formatHours(work),
                                 detail: monthlyChangeDetail(current: work, previous: previousCategories["Work", default: 0]),
                                 action: { openCategory("Work") }))
        }
        if snapshot.travel.totalHours > 0.01 {
            let previousTravel = TravelInsights.make(from: snapshot.previousSegments).totalHours
            metrics.append(.init(id: "travel", icon: "car.fill", title: "Travel", value: formatHours(snapshot.travel.totalHours),
                                 detail: monthlyChangeDetail(current: snapshot.travel.totalHours, previous: previousTravel)))
        }
        if let sleep = monthAverageNightlySleep, sleep > 0 {
            metrics.append(.init(id: "sleep", icon: "bed.double.fill", title: "Sleep · Apple Health",
                                 value: formatHours(sleep / 3600), detail: "Nightly average", action: { openSleep() }))
        } else if let steps = monthAverageDailySteps, steps > 0 {
            metrics.append(.init(id: "steps", icon: "shoeprints.fill", title: "Steps · Apple Health",
                                 value: "\(Int(steps.rounded()).formatted())/day", detail: "Daily average"))
        }

        let meaningful = metrics.filter { $0.detail != "This month" }
        return Array((meaningful + metrics.filter { $0.detail == "This month" }).prefix(4))
    }


    private var controls: some View {
        InsightsPeriodControls(
            window: window,
            periodTitle: periodTitle,
            periodSubtitle: periodSubtitle,
            scopeSubtitle: scopeSubtitle,
            recordedHours: snapshot.loggedHours,
            emptyState: snapshot.generatedAt != .distantPast && snapshot.loggedHours <= 0.01
                ? insightsScope.emptyState : nil,
            isCurrentWindow: isCurrentWindow,
            scopeRawValue: $scopeRawValue,
            selectedWindow: $window,
            onMove: move,
            onChooseDate: {
                draftAnchorDate = anchorDate
                choosingDate = true
            }
        )
    }

    private var donutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window == .day ? "Breakdown" : "How you spent your time")
                        .font(.headline)
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
                    Button("Export CSV") {
                        exportFile = TrendExport.makeFile(format: "csv", visits: visits,
                                                          interval: snapshot.analysisInterval,
                                                          now: snapshot.generatedAt, scope: insightsScope)
                    }
                    Button("Export JSON") {
                        exportFile = TrendExport.makeFile(format: "json", visits: visits,
                                                          interval: snapshot.analysisInterval,
                                                          now: snapshot.generatedAt, scope: insightsScope)
                    }
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
                onSelectEntry: pushSlice
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
        .padding(20)
        .lifeCard()
    }

    private var unloggedTimeReviewLink: some View {
        InsightsUnloggedTimeReviewLink(
            gapCount: unloggedSegments.count,
            totalHours: unloggedSegments.reduce(0) { $0 + $1.hours },
            onOpen: { path.append(InsightsRoute.unloggedTime) }
        )
    }

    /// This is intentionally period- and scope-bounded. The archive-repair
    /// browser remains the place to inspect every historical gap, whereas this
    /// link answers the question raised by the selected Insights breakdown.
    private var unloggedSegments: [InsightSegment] {
        snapshot.segments.filter { $0.isUnlogged && $0.end <= snapshot.generatedAt && $0.hours > 0.01 }
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

    private var dayCurrentActivity: DayCurrentActivityPresentation? {
        guard let visit = currentVisit else { return nil }
        return DayCurrentActivityPresentation(
            placeName: visit.displayPlaceName,
            activity: visit.suspectedActivity,
            startedAt: visit.arrival,
            needsChecking: visit.needsCategorisation || visit.needsConfirmation
        )
    }

    private var dayMetricPresentations: [DayInsightMetricPresentation] {
        var metrics: [DayInsightMetricPresentation] = []
        let atHome = max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)
        if atHome > 0.01 {
            metrics.append(.init(id: "day-metric-home", icon: "house.fill", title: "At Home", value: formatHours(atHome)))
        }
        if snapshot.awayFromHomeHours > 0.01 {
            metrics.append(.init(id: "day-metric-away", icon: "figure.walk.departure", title: "Away from Home", value: formatHours(snapshot.awayFromHomeHours)))
        }
        if let steps = todaySteps ?? healthSummary?.steps, steps > 0 {
            metrics.append(.init(id: "day-metric-steps", icon: "shoeprints.fill", title: "Steps", value: Int(steps).formatted()))
        }
        if let lastNightSleep, lastNightSleep.totalSleep > 0 {
            metrics.append(.init(id: "day-metric-sleep", icon: "bed.double.fill", title: "Last night’s sleep", value: formatHours(lastNightSleep.totalSleep / 3600)))
        }
        if let exercise = healthSummary?.exerciseMinutes, exercise > 0 {
            metrics.append(.init(id: "day-metric-exercise", icon: "figure.run", title: "Exercise", value: "\(Int(exercise.rounded())) min"))
        } else if let workoutCount = healthSummary?.workoutCount, workoutCount > 0 {
            metrics.append(.init(id: "day-metric-exercise", icon: "figure.run.circle.fill", title: "Workouts", value: "\(workoutCount) · \(Int(healthSummary?.workoutMinutes.rounded() ?? 0)) min"))
        } else {
            let workout = InsightsSnapshot.fitnessHours(in: daySegments)
            if workout > 0.01 {
                metrics.append(.init(id: "day-metric-exercise", icon: "figure.run", title: "Exercise", value: formatHours(workout)))
            }
        }
        let travel = TravelInsights.make(from: daySegments)
        if travel.hasTravel {
            metrics.append(.init(id: "day-metric-travel", icon: "car.fill", title: "Travel", value: formatHours(travel.totalHours)))
        }
        return metrics
    }

    private var dayAttentionPresentations: [DayAttentionPresentation] {
        needsAttentionItems.map { item in
            switch item {
            case .review(let entry):
                return DayAttentionPresentation(
                    id: "review-\(entry.id)", title: entry.visit.displayPlaceName,
                    detail: entry.reason.prompt, icon: "questionmark.circle.fill",
                    accessibilityLabel: "\(entry.visit.displayPlaceName), \(entry.reason.prompt)",
                    accessibilityHint: "Opens the editor for this visit", target: .visit(entry.visit.stableID)
                )
            case .gap(let segment):
                let detail = "\(segment.start.formatted(date: .omitted, time: .shortened))–\(segment.end.formatted(date: .omitted, time: .shortened)) · \(formatHours(segment.hours))"
                return DayAttentionPresentation(
                    id: "gap-\(segment.start.timeIntervalSinceReferenceDate)", title: "Nothing logged",
                    detail: detail, icon: "clock.badge.questionmark",
                    accessibilityLabel: "Nothing logged, \(formatHours(segment.hours)), from \(segment.start.formatted(date: .omitted, time: .shortened)) to \(segment.end.formatted(date: .omitted, time: .shortened))",
                    accessibilityHint: "Add a visit for this time", target: .gap(DateInterval(start: segment.start, end: segment.end))
                )
            }
        }
    }

    private func openDayTimelineSegment(_ segment: InsightSegment) {
        guard segment.visit != nil || segment.isUnlogged else { return }
        selectedDaySegment = segment
    }

    private func openDayMetric(_ identifier: String) {
        switch identifier {
        case "day-metric-home": openCategory("Home")
        case "day-metric-sleep": openSleep()
        case "day-metric-exercise": openCategory("Fitness")
        default: break
        }
    }

    private func openDayAttention(_ target: DayAttentionTarget) {
        switch target {
        case .visit(let stableID): editingVisit = visits.first { $0.stableID == stableID }
        case .gap(let interval):
            addVisitRange = interval
            isAddingVisit = true
        }
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

    private func formatHealthDistance(_ meters: Double) -> String {
        let kilometres = meters / 1_000
        return kilometres >= 1 ? String(format: "%.1f km", kilometres) : "\(Int(meters.rounded())) m"
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

    /// The seven-day glance: tapping a column reuses the window picker
    /// `InsightsView` already has (`window = .day`, `anchorDate = <that day>`)
    /// rather than pushing a second screen for what is already reachable from
    /// this one.
    /// The Week layout's per-metric facts, built from the same fetched health
    /// values and resolved segments as the rest of this screen — the presentation
    /// prep `WeekInsightsView` itself must not repeat, since it receives no
    /// SwiftData/health state, only this already-resolved array.
    private var weeklyYourWeekMetrics: [WeeklyYourWeekMetric] {
        let categoryHours = InsightsSnapshot.categoryHours(in: snapshot.segments)
        let atHome = max(0, snapshot.loggedHours - snapshot.awayFromHomeHours)
        let workHours = categoryHours["Work"] ?? 0
        let travelHours = InsightsSnapshot.travelHours(in: snapshot.segments)
        let elapsedSeconds = min(now, interval.end).timeIntervalSince(interval.start)
        let elapsedDays = max(1, min(7, Int(ceil(elapsedSeconds / 86_400))))
        var metrics: [WeeklyYourWeekMetric] = [
            .init(id: "home", icon: "house.fill", title: "At Home", value: formatHours(atHome), action: { openCategory("Home") })
        ]
        if workHours > 0.01 {
            metrics.append(.init(id: "work", icon: "briefcase.fill", title: "At Work", value: formatHours(workHours)))
        }
        if travelHours > 0.01 {
            metrics.append(.init(id: "travel", icon: "car.fill", title: "Travelling", value: formatHours(travelHours)))
        }
        if let weekAverageNightlySleep, weekAverageNightlySleep > 0 {
            metrics.append(.init(id: "sleep", icon: "bed.double.fill", title: "Sleep average",
                                 value: formatHours(weekAverageNightlySleep / 3600), action: { openSleep() }))
        }
        if let steps = weekSteps ?? healthSummary?.steps, steps > 0 {
            metrics.append(.init(id: "steps", icon: "shoeprints.fill", title: "Steps · Apple Health",
                                 value: "\(Int(steps).formatted()) total · \(Int(steps / Double(elapsedDays)).formatted())/day avg"))
        }
        if let exercise = healthSummary?.exerciseMinutes, exercise > 0 {
            metrics.append(.init(id: "exercise", icon: "figure.run", title: "Exercise · Apple Health",
                                 value: "\(Int(exercise.rounded())) min"))
        }
        if let workouts = healthSummary?.workoutCount, workouts > 0 {
            metrics.append(.init(id: "workouts", icon: "figure.run.circle.fill", title: "Workouts · Apple Health",
                                 value: "\(workouts) · \(Int(healthSummary?.workoutMinutes.rounded() ?? 0)) min"))
        }
        return metrics
    }

    /// This week's per-category hours appended to the rolling baseline and run
    /// through `InsightsTrends.series` — see `WeekRoutineChange.changes` for the
    /// math, kept beside its type in `WeekInsightsView.swift` and unit-tested
    /// there. Still a coordinator property because it needs `weeklyBaselineTotals`,
    /// which only this screen's own trend fetch (`reloadTrends`) populates.
    private var weekRoutineChanges: [WeekRoutineChange] {
        WeekRoutineChange.changes(currentWeekStart: interval.start, currentSegments: snapshot.segments,
                                  baselineTotals: weeklyBaselineTotals)
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
        let baselineWeeks = Array(weeklyBaselineTotals.suffix(WeekRoutineChange.baselineWeekCount))
        let nonzero = baselineWeeks.map { $0.hours[CommuteDetection.categoryName] ?? 0 }.filter { $0 > 0 }
        let baselineHours = nonzero.isEmpty ? nil : nonzero.reduce(0, +) / Double(nonzero.count)
        return InsightsSnapshot.weekCommuteSummary(commutes: commutes, weekInterval: interval, baselineHours: baselineHours)
    }

    private func reloadAnnualHealth() async {
        guard window == .year else { return }
        let requestKey = annualKey
        // Let the Year shell render before its archive-scale place-history work.
        await Task.yield()
        guard !Task.isCancelled, requestKey == annualKey else { return }
        let historical = await annualHistoricalPlaces()
        guard !Task.isCancelled, requestKey == annualKey else { return }
        annualPlacesLoading = false
        guard insightsScope.includesHealthData else {
            guard requestKey == annualKey else { return }
            annualHealth = .empty
            annualInsights = makeAnnualInsights(health: annualHealth, historicalPlaceNames: historical)
            return
        }
        annualInsights = makeAnnualInsights(health: annualHealth, historicalPlaceNames: historical)
        let year = interval
        let calendar = Calendar.current
        var sleep: [Double?] = []
        var steps: [Double?] = []
        var walking: [Double?] = []
        var energy: [Double?] = []
        var exercise: [Double?] = []
        var workouts: [Double?] = []
        var stand: [Double?] = []
        var cursor = year.start
        var hasHealthData = false
        while cursor < year.end {
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            let monthEnd = min(next, min(year.end, now))
            if monthEnd <= cursor {
                sleep.append(nil)
                steps.append(nil)
                walking.append(nil); energy.append(nil); exercise.append(nil); workouts.append(nil); stand.append(nil)
            } else {
                let month = DateInterval(start: cursor, end: monthEnd)
                let summary = await activityData.healthSummary(for: month)
                let monthSteps = await activityData.stepCount(for: month)
                guard !Task.isCancelled, requestKey == annualKey else { return }
                let sleepValue = summary?.sleep.map { $0.totalSleep / max(1, month.duration / 86_400) / 3600 }
                sleep.append(sleepValue)
                steps.append(monthSteps.map { $0 / max(1, month.duration / 86_400) })
                walking.append(summary?.walkingRunningMeters.map { $0 / 1_000 })
                energy.append(summary?.activeEnergyKilocalories)
                exercise.append(summary?.exerciseMinutes)
                workouts.append(summary.flatMap { $0.workouts.isEmpty ? nil : $0.workoutMinutes })
                stand.append(summary?.standHours)
                hasHealthData = hasHealthData || summary?.hasData == true
            }
            cursor = next
        }
        annualHealth = AnnualInsights.HealthMetrics(monthlySleepHours: sleep,
                                                    monthlySteps: steps,
                                                    monthlyWalkingKilometres: walking,
                                                    monthlyActiveEnergy: energy,
                                                    monthlyExerciseMinutes: exercise,
                                                    monthlyWorkoutMinutes: workouts,
                                                    monthlyStandHours: stand,
                                                    healthDataAvailable: hasHealthData)
        annualInsights = makeAnnualInsights(health: annualHealth, historicalPlaceNames: historical)
    }

    /// Distinct display names of places visited before this year, scoped the
    /// same way as the visible story. Runs on the shared archive-reader actor
    /// — this used to be a synchronous whole-archive fetch on the main actor,
    /// exactly the "unbounded history read on the interaction path" this
    /// screen otherwise avoids. See `VisitArchiveReader.historicalPlaceNames`
    /// for why it stays a full scan rather than a paged query: a complete
    /// distinct-names answer has no natural early stop, and the 32,000-row
    /// measurement in `VisitArchiveReaderTests` is what justifies running it
    /// as a background full scan instead of adding a persisted index.
    private func annualHistoricalPlaces() async -> Set<String> {
        guard window == .year else { return [] }
        do {
            return try await archive().historicalPlaceNames(before: interval.start, scope: insightsScope,
                                                             generation: aggregationGeneration)
        } catch is CancellationError {
            return []
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "annual historical places fetch", severity: "warning")
            return []
        }
    }

    private func makeAnnualInsights(health: AnnualInsights.HealthMetrics,
                                   historicalPlaceNames: Set<String>) -> AnnualInsights {
        AnnualInsights.make(current: snapshot.segments,
                           previous: snapshot.previousSegments,
                           yearInterval: interval, now: now,
                           historicalPlaceNames: historicalPlaceNames, health: health)
    }

    private func reloadInsights(reason: InsightsSnapshotRefreshReason = .storeGenerationChanged) {
        guard reason.rebuildsSnapshot else { return }
        // Capture the clock only for a real data/period refresh. A periodic text
        // update must not change this input or invalidate the complete snapshot.
        now = .now
        // Fetch only the selected and comparison periods. Keeping the nine-year journal
        // archive out of memory is substantially cheaper than trimming useful history.
        let scope = insightsScope
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
            var fetched = scope.filtering(try context.fetch(descriptor))
            // Preserve a current multi-day location whose arrival predates the comparison
            // range without widening the main archive query.
            do {
                let activeDescriptor = FetchDescriptor<Visit>(
                    predicate: #Predicate { $0.departure == nil },
                    sortBy: [SortDescriptor(\.arrival)]
                )
                let existingIDs = Set(fetched.map { ObjectIdentifier($0) })
                fetched.append(contentsOf: try context.fetch(activeDescriptor).filter(scope.includes).filter {
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
            // Do not turn a predicate-translation problem into a synchronous archive
            // scan. The empty state is preferable to blocking an Insights interaction;
            // the next invalidation retries the same bounded query.
            visits = []
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "date-scoped fetch", severity: "warning")
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
        let cacheKey = "\(window.rawValue)|\(scope.rawValue)|\(anchorDate.timeIntervalSinceReferenceDate)|\(visits.count)|\(homeKey)|\(rolesKey)"
        snapshot = snapshotCache.snapshot(key: cacheKey, generation: aggregationGeneration) {
            InsightsSnapshot.make(visits: visits, window: window, anchorDate: anchorDate, now: now,
                                  home: home, savedPlaces: savedPlaces)
        }
        if window == .year {
            // Render the current year's story immediately; archive-derived place
            // history is filled by the deferred annual task after the first frame.
            annualPlacesLoading = true
            annualInsights = makeAnnualInsights(health: annualHealth, historicalPlaceNames: [])
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

    /// Builds every pushed destination fresh from the current `snapshot` rather than
    /// from a value captured when the route was pushed -- see `InsightsRoute`'s doc
    /// comment. `@ViewBuilder` rather than a `switch` over view types directly in
    /// `.navigationDestination` because the six cases return six different concrete
    /// view types.
    @ViewBuilder
    private func routeDestination(_ route: InsightsRoute) -> some View {
        switch route {
        case let .activity(name, isUnlogged):
            let rows = isUnlogged ? [] : InsightsSnapshot.sliceRows(forCategory: name, segments: snapshot.segments,
                                                                    interval: snapshot.analysisInterval, now: snapshot.generatedAt)
            InsightActivityDetailView(activity: name, periodTitle: periodTitle,
                                      interval: snapshot.analysisInterval, rows: rows, isUnlogged: isUnlogged)
        case .sleep:
            InsightSleepDetailView(periodTitle: periodTitle, interval: snapshot.analysisInterval,
                                   segments: snapshot.segments, activityData: activityData)
        case let .group(title, groups):
            InsightGroupDetailView(title: title, groups: groups, periodTitle: periodTitle,
                                   interval: snapshot.analysisInterval, segments: snapshot.segments)
        case let .place(name):
            let rows = InsightsSnapshot.sliceRows(forPlace: name, segments: snapshot.segments,
                                                  interval: snapshot.analysisInterval, now: snapshot.generatedAt)
            InsightPlaceHistoryView(placeName: name, periodTitle: periodTitle,
                                    interval: snapshot.analysisInterval, rows: rows)
        case let .comparison(name, hours, previousHours, delta):
            InsightComparisonDetailView(
                comparison: TrendComparison(name: name, hours: hours, previousHours: previousHours, delta: delta),
                periodTitle: periodTitle, baselineTitle: "last \(window.title.lowercased())")
        case .unloggedTime:
            InsightUnloggedTimeList(gaps: unloggedSegments, periodTitle: periodTitle,
                                    onVisitSaved: { reloadInsights() })
        case let .visit(stableID):
            InsightVisitDestination(stableID: stableID)
        }
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

/// A compact Day Summary tile. Health-backed values are omitted by the parent
/// when unavailable, while the tile itself keeps one stable label/value layout
/// for Dynamic Type and VoiceOver.
struct DayInsightMetricTile: View {
    let icon: String
    let title: String
    let value: String
    let identifier: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
            } else {
                content
            }
        }
        .buttonStyle(.plain)
        // Combine first, then identify. Applied the other way round the identifier
        // lands on a container whose children are still separate elements, so it
        // propagates to each of them -- the tile then matches three times (Button,
        // its Text, its Image) and `.tap()` fails with "Multiple matching elements"
        // rather than resolving one. Combining first makes the tile a single
        // element, which is also what it is to a person reading it aloud.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title): \(value)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // No identifier here: `body` already carries it for the whole tile, and
        // setting it on the content too is the other half of the duplicate-match
        // failure -- the button and the thing inside it both answered to the name.
    }
}
