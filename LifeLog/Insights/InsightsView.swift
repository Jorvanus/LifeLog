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

/// Navigation (the push stack and every sheet) and the selected period
/// (`window`/`anchorDate`/scope) live here, as does deciding *when* each
/// model below needs to reload. What happens on each reload — the bounded
/// fetch and snapshot cache, Health fetches, archive-scale retrospectives,
/// and the Day/Week/Month/Year presentation built from all three — lives in
/// `InsightsPeriodLoader`/`InsightsHealthState`/`InsightsArchiveRetrospectives`/
/// `InsightsPresentationState`, four narrow models this screen only
/// orchestrates. Split out because the coordinator itself had reached 1,366
/// lines, interleaving all of the above rather than merely being adjacent to it.
struct InsightsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let activityData: ActivityDataService
    /// The saved place called Home, which is what "time away from Home" is measured
    /// against. Queried rather than matched by name — see `InsightsSnapshot.HomePlace`.
    @Query private var savedPlaces: [SavedPlace]
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
    @State private var exportFile: TrendExportFile?
    @State private var aggregationGeneration = 0
    /// The selected period's own bounded fetch, snapshot cache, and Day/Week/
    /// Month segment breakdowns — see `InsightsPeriodLoader`'s own doc comment.
    @State private var periodLoader = InsightsPeriodLoader()
    /// Steps, sleep, and Health summary figures — see `InsightsHealthState`.
    @State private var healthState = InsightsHealthState()
    /// Place history, year-over-year, and Year's historical places — see
    /// `InsightsArchiveRetrospectives`.
    @State private var retrospectives = InsightsArchiveRetrospectives()
    /// Highlights, the rolling weekly baseline, Year's derived story, and the
    /// per-layout metric/attention rows — see `InsightsPresentationState`.
    @State private var presentationState = InsightsPresentationState()
    @State private var selectedDaySegment: InsightSegment?
    /// Shared by the Current Activity card and Needs Attention rows -- both are
    /// "open this one Visit," the same action `VisitEditor` already exists for.
    @State private var editingVisit: Visit?
    @State private var addVisitRange = DateInterval(start: .now, duration: 0)
    @State private var isAddingVisit = false
    @State private var isAskingLifeLog = false
    /// Set by Ask LifeLog's drill-down action, then pushed from the sheet's own
    /// `onDismiss` -- see the matching comment in `AskLifeLogView`.
    @State private var pendingAskLifeLogRoute: InsightsRoute?

    private var interval: DateInterval { window.interval(containing: anchorDate) }
    private var insightsScope: InsightsScope {
        InsightsScope(rawValue: scopeRawValue) ?? .allHistory
    }
    private var scopeSubtitle: String {
        "\(insightsScope.title) · \(formatHours(periodLoader.snapshot.loggedHours)) recorded hours"
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
                        if periodLoader.snapshot.segments.isEmpty {
                            if !periodLoader.archiveHasAnyVisits && insightsScope == .allHistory {
                                InsightsFirstRunCard(onAddVisit: { isAddingVisit = true })
                            } else {
                                InsightsNoDataCard(periodTitle: periodTitle,
                                                   detail: insightsScope.emptyState)
                            }
                        } else if window == .day {
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
            .toolbar {
                if periodLoader.archiveHasAnyVisits {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isAskingLifeLog = true } label: {
                            Image(systemName: "apple.intelligence")
                        }
                        .accessibilityLabel("Ask LifeLog")
                        .accessibilityIdentifier("insights-ask-lifelog-button")
                    }
                }
            }
            .sheet(isPresented: $isAskingLifeLog, onDismiss: {
                guard let route = pendingAskLifeLogRoute else { return }
                pendingAskLifeLogRoute = nil
                path.append(route)
            }) {
                AskLifeLogView(
                    context: .current(window: window, interval: interval, now: now, scope: insightsScope),
                    reader: retrospectives.archive(context: context),
                    repairActor: ArchiveRepairActor(modelContainer: context.container),
                    catalogue: ActivityCatalog.load(),
                    planner: askLifeLogPlanner(),
                    onDrillDown: { route in pendingAskLifeLogRoute = route }
                )
            }
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
                aggregationGeneration = InsightsAggregationActor.shared.currentGeneration()
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
                aggregationGeneration = InsightsAggregationActor.shared.currentGeneration()
                reloadInsights()
            }
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                Task {
                    aggregationGeneration = InsightsAggregationActor.shared.currentGeneration()
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
        await healthState.reloadHealthSummary(activityData: activityData, interval: interval, now: now,
                                              window: window, scope: insightsScope,
                                              isStillCurrent: { requestKey == healthSummaryKey })
    }

    /// Rebuilds highlights only when its selected period or source data changes.
    ///
    /// `comparisons.count` alone is not enough: it only changes when a category
    /// appears or disappears, not when an *existing* one's hours change -- which
    /// is exactly what happens when a delayed HealthKit sync or a manual sleep
    /// entry resolves after the first load. `.task(id:)` only re-runs when the
    /// id string itself changes, so a stale "count" left the comparison for
    /// "Sleep" (and everything else) frozen at whatever it read on the first
    /// pass, even once the snapshot feeding the donut and glance tiles had moved
    /// on to the correct numbers. Summing each comparison's delta makes the key
    /// sensitive to the actual values, not just how many categories exist.
    private var highlightKey: String {
        let leadingPlace = periodLoader.snapshot.placeTotals.first
        // Minute precision, matching `formatHours`' own rounding elsewhere: fine
        // enough to catch a real change, coarse enough that floating-point noise
        // from re-deriving the same segments twice can't churn the key.
        let comparisonSignature = periodLoader.snapshot.comparisons
            .map { "\($0.name):\(Int(($0.hours * 60).rounded())):\(Int(($0.previousHours * 60).rounded()))" }
            .joined(separator: ",")
        return "\(window.rawValue)-\(insightsScope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(comparisonSignature)-\(leadingPlace?.id ?? "none")-\(leadingPlace?.hours ?? 0)"
    }

    private func reloadHighlights() async {
        let requestKey = highlightKey
        await presentationState.reloadHighlights(
            window: window, interval: interval, now: now, anchorDate: anchorDate, scope: insightsScope,
            snapshot: periodLoader.snapshot, daySegments: periodLoader.daySegments,
            activityData: activityData, health: healthState, retrospectives: retrospectives, context: context,
            isStillCurrent: { requestKey == highlightKey }
        )
    }

    /// Seeded UI tests switch onto `FakeAskLifeLogPlanner` the same way
    /// `UITestSeedData`/`UITestFailureInjection` gate deterministic behaviour
    /// behind a launch argument, rather than depending on live Apple Intelligence.
    private func askLifeLogPlanner() -> AskLifeLogPlanning {
        if InternalLaunchArguments.contains(FakeAskLifeLogPlanner.launchArgument) {
            return FakeAskLifeLogPlanner.uiTestPlanner()
        }
        return FoundationModelsAskLifeLogPlanner()
    }

    /// The donut's centre is intentionally non-interactive and geometry-constrained.
    /// Health recovery therefore belongs in an ordinary card where its action remains
    /// obvious, tappable, and readable at larger text sizes.
    @ViewBuilder private var healthSetupSection: some View {
        if insightsScope.includesHealthData &&
            (needsHealthSetup || activityData.ui.lastImport != nil || healthState.healthSummary?.hasData != nil) {
            if let healthSummary = healthState.healthSummary, healthSummary.hasData {
                HealthOverviewCard(summary: healthSummary, previous: healthState.previousHealthSummary,
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
        let matching = periodLoader.snapshot.segments.filter {
            !$0.isUnlogged && ($0.category.caseInsensitiveCompare(name) == .orderedSame ||
                               $0.activity.caseInsensitiveCompare(name) == .orderedSame)
        }
        let hours = matching.reduce(0) { $0 + $1.hours }
        guard hours > 0 else { return }
        path.append(InsightsRoute.activity(name: name, isUnlogged: false))
    }

    private func openSleep() {
        let hours = periodLoader.snapshot.segments.filter(\.isSleep).reduce(0) { $0 + $1.hours }
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

    private func reloadTrends() async {
        let requestKey = trendKey
        await presentationState.reloadTrends(now: now, scope: insightsScope, context: context,
                                             isStillCurrent: { requestKey == trendKey })
    }

    /// A practical daily-review screen, not a smaller period view: what's
    /// happening right now, the day so far at a glance, a short summary, what
    /// needs attention, and — last, not first — what stood out. The donut stays
    /// reachable (its tap-to-inspect interaction is unchanged) but is no longer
    /// the lead visual; the day bar is.
    @ViewBuilder private var dayLayout: some View {
        DayInsightsView(
            currentActivity: dayCurrentActivity,
            timelineSegments: periodLoader.daySegments,
            interval: interval,
            now: now,
            metrics: presentationState.dayMetricPresentations(
                snapshot: periodLoader.snapshot, daySegments: periodLoader.daySegments,
                todaySteps: healthState.todaySteps, lastNightSleep: healthState.lastNightSleep,
                healthSummary: healthState.healthSummary
            ),
            attentionItems: presentationState.dayAttentionPresentations(
                visits: periodLoader.visits, daySegments: periodLoader.daySegments, now: now
            ),
            highlight: presentationState.highlights.first,
            travel: TravelInsights.make(from: periodLoader.daySegments),
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
        recordingQualitySection
        routineStabilitySection
        WeekInsightsView(
            weekDays: periodLoader.weekDays, now: now, selectedDate: anchorDate,
            yourWeekMetrics: presentationState.weeklyYourWeekMetrics(
                snapshot: periodLoader.snapshot, now: now, interval: interval,
                weekSteps: healthState.weekSteps, weekAverageNightlySleep: healthState.weekAverageNightlySleep,
                healthSummary: healthState.healthSummary, openCategory: openCategory, openSleep: openSleep
            ),
            groupTotals: InsightsSnapshot.categoryHours(in: periodLoader.snapshot.segments),
            periodTitle: periodTitle, analysisInterval: periodLoader.snapshot.analysisInterval,
            segments: periodLoader.snapshot.segments,
            travel: periodLoader.snapshot.travel,
            commuteSummary: presentationState.weeklyCommuteSummary(
                visits: periodLoader.visits, savedPlaces: savedPlaces, now: now, interval: interval,
                homePlace: homePlace, workPlace: workPlace
            ),
            routineChanges: presentationState.weekRoutineChanges(interval: interval, snapshot: periodLoader.snapshot, now: now),
            onSelectDay: { date in anchorDate = date; window = .day }
        )
        donutSection
        healthSetupSection
    }

    /// Month answers "what changed in my life this month?" rather than presenting
    /// the same long-term sections as Year. These cards all read the same resolved
    /// current/previous segments as the donut.
    @ViewBuilder private var monthLayout: some View {
        let insights = presentationState.monthlyInsights(snapshot: periodLoader.snapshot, window: window, now: now)
        recordingQualitySection
        routineStabilitySection
        MonthInsightsView(
            insights: insights, comparisonSubtitle: insights.comparisonSubtitle,
            heroMetrics: presentationState.monthlyHeroMetrics(
                snapshot: periodLoader.snapshot, interval: interval, now: now,
                monthAverageNightlySleep: healthState.monthAverageNightlySleep, monthSteps: healthState.monthSteps,
                openCategory: openCategory, openSleep: openSleep
            ),
            monthDays: periodLoader.monthDays,
            periodTitle: periodTitle, analysisInterval: periodLoader.snapshot.analysisInterval,
            segments: periodLoader.snapshot.segments,
            now: periodLoader.snapshot.generatedAt, onOpenCategory: openCategory, onOpenComparison: openComparison,
            onSelectDay: { date in anchorDate = date; window = .day }
        )
        healthSetupSection
    }

    @ViewBuilder private var yearLayout: some View {
        YearInsightsView(insights: presentationState.annualInsights, openGroup: { row in
            guard row.totalHours > 0, !row.foldedGroups.isEmpty else { return }
            path.append(InsightsRoute.group(title: row.group, groups: row.foldedGroups))
        }, openPlace: { place in
            path.append(InsightsRoute.place(name: place.name))
        }, period: periodLoader.snapshot.analysisInterval, placesLoading: retrospectives.annualPlacesLoading)
        healthSetupSection
    }

    private var controls: some View {
        InsightsPeriodControls(
            window: window,
            periodTitle: periodTitle,
            periodSubtitle: periodSubtitle,
            scopeSubtitle: scopeSubtitle,
            recordedHours: periodLoader.snapshot.loggedHours,
            emptyState: periodLoader.snapshot.generatedAt != .distantPast && periodLoader.snapshot.loggedHours <= 0.01
                ? insightsScope.emptyState : nil,
            isCurrentWindow: isCurrentWindow,
            scopeRawValue: $scopeRawValue,
            selectedWindow: $window,
            onMove: move,
            onChooseDate: {
                draftAnchorDate = anchorDate
                choosingDate = true
            },
            onToday: { anchorDate = .now }
        )
    }

    private var donutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window == .day ? "Breakdown" : "How you spent your time")
                        .font(.headline)
                    Text(isCurrentWindow
                         ? "\(formatHours(periodLoader.snapshot.totalHours)) elapsed in this \(window.title.lowercased())"
                         : "All \(formatHours(periodLoader.snapshot.totalHours)) in this \(window.title.lowercased())")
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
                        exportFile = TrendExport.makeFile(format: "csv", visits: periodLoader.visits,
                                                          interval: periodLoader.snapshot.analysisInterval,
                                                          now: periodLoader.snapshot.generatedAt, scope: insightsScope)
                    }
                    Button("Export JSON") {
                        exportFile = TrendExport.makeFile(format: "json", visits: periodLoader.visits,
                                                          interval: periodLoader.snapshot.analysisInterval,
                                                          now: periodLoader.snapshot.generatedAt, scope: insightsScope)
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
                segments: periodLoader.snapshot.segments,
                loggedHours: periodLoader.snapshot.loggedHours,
                totalHours: periodLoader.snapshot.totalHours,
                analysisInterval: periodLoader.snapshot.analysisInterval,
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

    /// Coverage, gaps, provisional rows, and low-coverage days for the selected
    /// Week/Month period -- see `InsightsRecordingQuality`'s own doc comment for
    /// why this reads only the already-fetched period data.
    private var recordingQuality: InsightsRecordingQuality.Presentation {
        InsightsRecordingQuality.make(segments: periodLoader.snapshot.segments, visits: periodLoader.visits,
                                      interval: periodLoader.snapshot.analysisInterval, now: now,
                                      observationStart: RecordingObservation.startedAt())
    }

    /// Placed first in Week/Month, ahead of their own decorative charts -- see
    /// TODO.md's "recording-quality insight before another decorative chart."
    @ViewBuilder private var recordingQualitySection: some View {
        let quality = recordingQuality
        if quality.hasSignal {
            InsightRecordingQualityCard(
                quality: quality, periodTitle: periodTitle,
                onOpenGaps: { path.append(InsightsRoute.unloggedTime) },
                onOpenProvisional: { path.append(InsightsRoute.provisionalRows) },
                onOpenDay: { date in anchorDate = date; window = .day }
            )
        }
    }

    /// Season-wide (not period-bound, unlike Recording Quality): the same
    /// `InsightsTrendAggregator` fetch the Week rolling baseline already reads,
    /// off the main actor -- see `InsightsPresentationState.reloadTrends` and
    /// `InsightsRoutineStability`'s own doc comment.
    @ViewBuilder private var routineStabilitySection: some View {
        let routine = presentationState.routineStability
        // Shown once the season fetch has completed at least once -- before that,
        // `sampleWindow` is still the placeholder `.distantPast` interval
        // `InsightsPresentationState` starts with, and there is nothing yet to
        // suppress or show a conclusion for.
        if routine.sampleWindow.duration > 0 {
            InsightRoutineStabilityCard(routine: routine)
        }
    }

    /// This is intentionally period- and scope-bounded. The archive-repair
    /// browser remains the place to inspect every historical gap, whereas this
    /// link answers the question raised by the selected Insights breakdown.
    private var unloggedSegments: [InsightSegment] {
        periodLoader.snapshot.segments.filter { $0.isUnlogged && $0.end <= periodLoader.snapshot.generatedAt && $0.hours > 0.01 }
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
        return periodLoader.visits.first { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored && $0.departure == nil }
    }

    /// Timeline already shows the current stay unconditionally, so Insights only
    /// surfaces this card when there's actually something to act on -- otherwise
    /// it duplicates Timeline's own card without adding anything new.
    private var dayCurrentActivity: DayCurrentActivityPresentation? {
        guard let visit = currentVisit, visit.needsCategorisation || visit.needsConfirmation else { return nil }
        return DayCurrentActivityPresentation(
            placeName: visit.displayPlaceName,
            activity: visit.suspectedActivity,
            startedAt: visit.arrival,
            needsChecking: true
        )
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
        case .visit(let stableID): editingVisit = periodLoader.visits.first { $0.stableID == stableID }
        case .gap(let interval):
            addVisitRange = interval
            isAddingVisit = true
        }
    }

    private func reloadAnnualHealth() async {
        let requestKey = annualKey
        await presentationState.reloadAnnualHealth(
            window: window, interval: interval, now: now, scope: insightsScope,
            snapshot: periodLoader.snapshot, activityData: activityData, health: healthState,
            retrospectives: retrospectives, aggregationGeneration: aggregationGeneration, context: context,
            isStillCurrent: { requestKey == annualKey }
        )
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
            let rows = isUnlogged ? [] : InsightsSnapshot.sliceRows(forCategory: name, segments: periodLoader.snapshot.segments,
                                                                    interval: periodLoader.snapshot.analysisInterval, now: periodLoader.snapshot.generatedAt)
            InsightActivityDetailView(activity: name, periodTitle: periodTitle,
                                      interval: periodLoader.snapshot.analysisInterval, rows: rows, isUnlogged: isUnlogged)
        case .sleep:
            InsightSleepDetailView(periodTitle: periodTitle, interval: periodLoader.snapshot.analysisInterval,
                                   segments: periodLoader.snapshot.segments, activityData: activityData)
        case let .group(title, groups):
            InsightGroupDetailView(title: title, groups: groups, periodTitle: periodTitle,
                                   interval: periodLoader.snapshot.analysisInterval, segments: periodLoader.snapshot.segments)
        case let .place(name):
            let rows = InsightsSnapshot.sliceRows(forPlace: name, segments: periodLoader.snapshot.segments,
                                                  interval: periodLoader.snapshot.analysisInterval, now: periodLoader.snapshot.generatedAt)
            InsightPlaceHistoryView(placeName: name, periodTitle: periodTitle,
                                    interval: periodLoader.snapshot.analysisInterval, rows: rows)
        case let .comparison(name, hours, previousHours, delta):
            InsightComparisonDetailView(
                comparison: TrendComparison(name: name, hours: hours, previousHours: previousHours, delta: delta),
                periodTitle: periodTitle, baselineTitle: "last \(window.title.lowercased())")
        case .unloggedTime:
            InsightUnloggedTimeList(gaps: unloggedSegments, periodTitle: periodTitle,
                                    onVisitSaved: { reloadInsights() })
        case .provisionalRows:
            InsightProvisionalRowsList(rows: recordingQuality.provisionalRows, periodTitle: periodTitle,
                                       interval: periodLoader.snapshot.analysisInterval)
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

    private func reloadInsights(reason: InsightsSnapshotRefreshReason = .storeGenerationChanged) {
        guard reason.rebuildsSnapshot else { return }
        // Capture the clock only for a real data/period refresh. A periodic text
        // update must not change this input or invalidate the complete snapshot.
        now = .now
        let home = InsightsSnapshot.HomePlace(homePlace)
        periodLoader.reload(window: window, anchorDate: anchorDate, scope: insightsScope, now: now,
                            home: home, savedPlaces: savedPlaces, aggregationGeneration: aggregationGeneration,
                            context: context)
        if window == .year {
            // Render the current year's story immediately; archive-derived place
            // history is filled by the deferred annual task after the first frame.
            retrospectives.annualPlacesLoading = true
            presentationState.beginYearPlaceholder(snapshot: periodLoader.snapshot, interval: interval, now: now,
                                                    annualHealth: healthState.annualHealth)
        }
    }
}

private struct InsightsFirstRunCard: View {
    let onAddVisit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your timeline starts here", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("LifeLog will build your days from this point forward. Time before you started using LifeLog is not treated as missing.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Location access enables background visits. You can also begin with a visit entered manually.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onAddVisit) {
                Label("Add your first visit", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("insights-first-run-add-visit")
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insights-first-run-card")
    }
}

private struct InsightsNoDataCard: View {
    let periodTitle: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No LifeLog history for \(periodTitle)", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insights-period-no-data")
    }
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
